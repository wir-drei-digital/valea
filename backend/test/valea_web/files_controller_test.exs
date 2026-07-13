defmodule ValeaWeb.FilesControllerTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Plug.Conn

  @endpoint ValeaWeb.Endpoint

  alias Valea.Workspace.Manager

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-app-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    System.put_env("VALEA_APP_DIR", dir)
    Manager.close()
    # Naming the workspace "Primary" lands the scaffolded mount at exactly
    # `mounts/primary` (Valea.Workspace.Scaffold.slugify/1) — the path this
    # suite addresses throughout, matching icm_write_test.exs's convention.
    {:ok, %{path: ws}} = Manager.create(Path.join(dir, "workspaces"), "Primary")

    on_exit(fn ->
      Manager.close()
      File.rm_rf!(dir)
      System.delete_env("VALEA_APP_DIR")
    end)

    File.mkdir_p!(Path.join(ws, "mounts/primary/Clients"))

    File.write!(
      Path.join(ws, "mounts/primary/Clients/Julia Steiner.md"),
      "# Julia Steiner\n"
    )

    %{conn: build_conn(), workspace: ws}
  end

  # A few valid PNG magic bytes + payload — enough to round-trip as an
  # upload/serve pair; nothing here decodes the image, so it need not be a
  # structurally complete PNG.
  defp write_tmp_png!(bytes \\ <<137, 80, 78, 71, 13, 10, 26, 10>> <> "payload") do
    path =
      Path.join(
        System.tmp_dir!(),
        "valea-upload-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}.png"
      )

    File.write!(path, bytes)
    path
  end

  defp with_token(conn), do: put_req_header(conn, "x-valea-token", "valea-dev-token")

  test "upload lands in Assets and serve returns it", %{conn: conn, workspace: ws} do
    upload = %Plug.Upload{
      path: write_tmp_png!(),
      filename: "shot.png",
      content_type: "image/png"
    }

    conn1 =
      conn
      |> with_token()
      |> post("/files/upload", %{
        "file" => upload,
        "page_path" => "mounts/primary/Clients/Julia Steiner.md"
      })

    assert %{"path" => path, "rel_from_page" => rel} = json_response(conn1, 200)
    assert path =~ ~r|^mounts/primary/Assets/julia-steiner-[0-9a-f]{8}\.png$|
    assert rel == "../" <> String.replace_prefix(path, "mounts/primary/", "")
    assert File.exists?(Path.join(ws, path))

    conn2 = get(build_conn(), "/files/raw", %{"path" => path})
    assert response(conn2, 200)
    assert get_resp_header(conn2, "content-type") |> hd() =~ "image/png"
  end

  test "re-uploading identical bytes is idempotent (same name, still succeeds)", %{conn: conn} do
    bytes = write_tmp_png!() |> File.read!()

    upload = fn ->
      path = write_tmp_png!(bytes)
      %Plug.Upload{path: path, filename: "shot.png", content_type: "image/png"}
    end

    conn1 =
      conn
      |> with_token()
      |> post("/files/upload", %{
        "file" => upload.(),
        "page_path" => "mounts/primary/Clients/Julia Steiner.md"
      })

    assert %{"path" => path1} = json_response(conn1, 200)

    conn2 =
      conn
      |> with_token()
      |> post("/files/upload", %{
        "file" => upload.(),
        "page_path" => "mounts/primary/Clients/Julia Steiner.md"
      })

    assert %{"path" => path2} = json_response(conn2, 200)
    assert path1 == path2
  end

  test "upload without token is 401; bad type is 400; traversal serve is 404", %{conn: conn} do
    upload = %Plug.Upload{path: write_tmp_png!(), filename: "x.png", content_type: "image/png"}

    assert conn
           |> post("/files/upload", %{"file" => upload, "page_path" => "mounts/primary/a.md"})
           |> response(401)

    bad = %Plug.Upload{path: write_tmp_png!(), filename: "x.svg", content_type: "image/svg+xml"}

    conn3 =
      conn
      |> with_token()
      |> post("/files/upload", %{
        "file" => bad,
        "page_path" => "mounts/primary/Clients/Julia Steiner.md"
      })

    assert json_response(conn3, 400)

    assert build_conn()
           |> get("/files/raw", %{"path" => "mounts/primary/../../secrets/x.png"})
           |> response(404)

    assert build_conn() |> get("/files/raw", %{"path" => "logs/audit.jsonl"}) |> response(404)
  end

  test "an oversized upload is rejected 413", %{conn: conn} do
    oversized = String.duplicate("a", 10_000_001)

    upload = %Plug.Upload{
      path: write_tmp_png!(oversized),
      filename: "big.png",
      content_type: "image/png"
    }

    conn1 =
      conn
      |> with_token()
      |> post("/files/upload", %{
        "file" => upload,
        "page_path" => "mounts/primary/Clients/Julia Steiner.md"
      })

    assert json_response(conn1, 413)
  end

  test "content_type/extension mismatch is rejected 400", %{conn: conn} do
    upload = %Plug.Upload{
      path: write_tmp_png!("not actually a png"),
      filename: "shot.png",
      content_type: "text/plain"
    }

    conn1 =
      conn
      |> with_token()
      |> post("/files/upload", %{
        "file" => upload,
        "page_path" => "mounts/primary/Clients/Julia Steiner.md"
      })

    assert json_response(conn1, 400)
  end

  test "upload targeting a disabled mount is rejected 400", %{conn: conn, workspace: ws} do
    File.mkdir_p!(Path.join(ws, "mounts/other"))

    File.write!(
      Path.join(ws, "config/workspace.yaml"),
      "version: 4\nmounts:\n  other:\n    enabled: false\n"
    )

    upload = %Plug.Upload{path: write_tmp_png!(), filename: "x.png", content_type: "image/png"}

    conn1 =
      conn
      |> with_token()
      |> post("/files/upload", %{"file" => upload, "page_path" => "mounts/other/a.md"})

    assert json_response(conn1, 400)
  end

  test "serve rejects a non-image extension inside a real mount (404, not 500)", %{
    workspace: ws
  } do
    File.write!(Path.join(ws, "mounts/primary/app.sqlite"), "not an image")

    assert build_conn()
           |> get("/files/raw", %{"path" => "mounts/primary/app.sqlite"})
           |> response(404)

    assert build_conn()
           |> get("/files/raw", %{"path" => "mounts/primary/Clients/Julia Steiner.md"})
           |> response(404)
  end

  test "serve rejects a symlink inside Assets escaping the mount", %{workspace: ws} do
    outside_dir =
      Path.join(
        System.tmp_dir!(),
        "valea-outside-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(outside_dir)
    File.write!(Path.join(outside_dir, "evil.png"), "not really an image, but has the ext")

    assets_dir = Path.join(ws, "mounts/primary/Assets")
    File.mkdir_p!(assets_dir)
    File.ln_s!(Path.join(outside_dir, "evil.png"), Path.join(assets_dir, "escape.png"))

    assert build_conn()
           |> get("/files/raw", %{"path" => "mounts/primary/Assets/escape.png"})
           |> response(404)
  end
end
