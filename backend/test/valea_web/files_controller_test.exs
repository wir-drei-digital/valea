defmodule ValeaWeb.FilesControllerTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Plug.Conn

  @endpoint ValeaWeb.Endpoint

  alias Valea.AgentCase
  alias Valea.Mounts
  alias Valea.Workspace.Manager

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-app-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    System.put_env("VALEA_APP_DIR", dir)
    Manager.close()
    {:ok, %{path: ws}} = Manager.create("Primary")

    on_exit(fn ->
      Manager.close()
      File.rm_rf!(dir)
      System.delete_env("VALEA_APP_DIR")
    end)

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

  # Mounts a real EXTERNAL ICM carrying a `Clients/Julia Steiner.md` page --
  # task 4.4 re-key: `page_path` sent to `/files/upload`/`/files/raw` is now
  # ICM-RELATIVE (never a `mounts/<name>/...` literal, never the ICM's
  # absolute physical root), attributed by the accompanying `mount_key`. See
  # `Valea.AgentCase.mount_test_icm!/2`'s moduledoc.
  defp mount_primary!(workspace) do
    AgentCase.mount_test_icm!(workspace,
      name: "Primary",
      pages: %{"Clients/Julia Steiner.md" => "# Julia Steiner\n"}
    )
  end

  test "upload lands in Assets and serve returns it", %{conn: conn, workspace: ws} do
    icm = mount_primary!(ws)

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
        "mount_key" => icm.mount_key,
        "page_path" => "Clients/Julia Steiner.md"
      })

    assert %{"path" => path, "rel_from_page" => rel} = json_response(conn1, 200)

    assert path =~ ~r|^Assets/julia-steiner-[0-9a-f]{8}\.png$|
    assert rel == "../Assets/" <> Path.basename(path)
    assert File.exists?(Path.join(icm.root, path))

    conn2 = get(build_conn(), "/files/raw", %{"mount_key" => icm.mount_key, "path" => path})
    assert response(conn2, 200)
    assert get_resp_header(conn2, "content-type") |> hd() =~ "image/png"
  end

  test "uploading from a top-level page computes rel_from_page without a spurious ../", %{
    conn: conn,
    workspace: ws
  } do
    icm = mount_primary!(ws)

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
        "mount_key" => icm.mount_key,
        "page_path" => "Welcome.md"
      })

    assert %{"path" => path, "rel_from_page" => rel} = json_response(conn1, 200)
    assert path =~ ~r|^Assets/welcome-[0-9a-f]{8}\.png$|
    assert rel == path
  end

  test "re-uploading identical bytes is idempotent (same name, still succeeds)", %{
    conn: conn,
    workspace: ws
  } do
    icm = mount_primary!(ws)
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
        "mount_key" => icm.mount_key,
        "page_path" => "Clients/Julia Steiner.md"
      })

    assert %{"path" => path1} = json_response(conn1, 200)

    conn2 =
      conn
      |> with_token()
      |> post("/files/upload", %{
        "file" => upload.(),
        "mount_key" => icm.mount_key,
        "page_path" => "Clients/Julia Steiner.md"
      })

    assert %{"path" => path2} = json_response(conn2, 200)
    assert path1 == path2
  end

  test "upload without token is 401; bad type is 400; traversal serve is 404", %{
    conn: conn,
    workspace: ws
  } do
    icm = mount_primary!(ws)
    upload = %Plug.Upload{path: write_tmp_png!(), filename: "x.png", content_type: "image/png"}

    assert conn
           |> post("/files/upload", %{
             "file" => upload,
             "mount_key" => icm.mount_key,
             "page_path" => "a.md"
           })
           |> response(401)

    bad = %Plug.Upload{path: write_tmp_png!(), filename: "x.svg", content_type: "image/svg+xml"}

    conn3 =
      conn
      |> with_token()
      |> post("/files/upload", %{
        "file" => bad,
        "mount_key" => icm.mount_key,
        "page_path" => "Clients/Julia Steiner.md"
      })

    assert json_response(conn3, 400)

    assert build_conn()
           |> get("/files/raw", %{"mount_key" => icm.mount_key, "path" => "../../secrets/x.png"})
           |> response(404)

    assert build_conn()
           |> get("/files/raw", %{"mount_key" => "no-such-mount", "path" => "x.png"})
           |> response(404)
  end

  test "an oversized upload is rejected 413", %{conn: conn, workspace: ws} do
    icm = mount_primary!(ws)
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
        "mount_key" => icm.mount_key,
        "page_path" => "Clients/Julia Steiner.md"
      })

    assert json_response(conn1, 413)
  end

  test "content_type/extension mismatch is rejected 400", %{conn: conn, workspace: ws} do
    icm = mount_primary!(ws)

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
        "mount_key" => icm.mount_key,
        "page_path" => "Clients/Julia Steiner.md"
      })

    assert json_response(conn1, 400)
  end

  test "upload targeting a disabled mount is rejected 400", %{conn: conn, workspace: ws} do
    icm = AgentCase.mount_test_icm!(ws, name: "Other", enabled: false)

    upload = %Plug.Upload{path: write_tmp_png!(), filename: "x.png", content_type: "image/png"}

    conn1 =
      conn
      |> with_token()
      |> post("/files/upload", %{
        "file" => upload,
        "mount_key" => icm.mount_key,
        "page_path" => "a.md"
      })

    assert json_response(conn1, 400)
  end

  test "upload is rejected 400 for an unknown mount_key and for a page_path escaping the mount",
       %{conn: conn, workspace: ws} do
    icm = mount_primary!(ws)

    upload = fn ->
      %Plug.Upload{path: write_tmp_png!(), filename: "x.png", content_type: "image/png"}
    end

    conn1 =
      conn
      |> with_token()
      |> post("/files/upload", %{
        "file" => upload.(),
        "mount_key" => "no-such-mount",
        "page_path" => "a.md"
      })

    assert json_response(conn1, 400)

    conn2 =
      conn
      |> with_token()
      |> post("/files/upload", %{
        "file" => upload.(),
        "mount_key" => icm.mount_key,
        "page_path" => "../../secrets/x.md"
      })

    assert json_response(conn2, 400)
  end

  test "serve rejects a non-image extension inside a real mount (404, not 500)", %{
    workspace: ws
  } do
    icm = mount_primary!(ws)
    File.write!(Path.join(icm.root, "app.sqlite"), "not an image")

    assert build_conn()
           |> get("/files/raw", %{"mount_key" => icm.mount_key, "path" => "app.sqlite"})
           |> response(404)

    assert build_conn()
           |> get("/files/raw", %{
             "mount_key" => icm.mount_key,
             "path" => "Clients/Julia Steiner.md"
           })
           |> response(404)
  end

  test "serve rejects a symlink inside Assets escaping the mount", %{workspace: ws} do
    icm = mount_primary!(ws)

    outside_dir =
      Path.join(
        System.tmp_dir!(),
        "valea-outside-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(outside_dir)
    File.write!(Path.join(outside_dir, "evil.png"), "not really an image, but has the ext")

    assets_dir = Path.join(icm.root, "Assets")
    File.mkdir_p!(assets_dir)
    File.ln_s!(Path.join(outside_dir, "evil.png"), Path.join(assets_dir, "escape.png"))

    assert build_conn()
           |> get("/files/raw", %{"mount_key" => icm.mount_key, "path" => "Assets/escape.png"})
           |> response(404)
  end

  test "serve rejects a symlinked Assets DIRECTORY escaping the mount", %{workspace: ws} do
    icm = mount_primary!(ws)

    outside_dir =
      Path.join(
        System.tmp_dir!(),
        "valea-outside-dir-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(outside_dir)
    File.write!(Path.join(outside_dir, "x.png"), "outside bytes")

    # "Assets" ITSELF is a symlink pointing outside the mount root, not just
    # a file inside it — resolve_real must walk through the directory
    # component too, not just the leaf.
    File.ln_s!(outside_dir, Path.join(icm.root, "Assets"))

    assert build_conn()
           |> get("/files/raw", %{"mount_key" => icm.mount_key, "path" => "Assets/x.png"})
           |> response(404)
  end

  test "serve rejects an absolute-path escape attempt", %{workspace: ws} do
    icm = mount_primary!(ws)

    outside_dir =
      Path.join(
        System.tmp_dir!(),
        "valea-abs-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(outside_dir)
    outside_file = Path.join(outside_dir, "secret.png")
    File.write!(outside_file, "should never be served")

    # An absolute `path`, even paired with a valid `mount_key`, must never
    # be honored — only a path relative to that mount's own root is.
    assert build_conn()
           |> get("/files/raw", %{"mount_key" => icm.mount_key, "path" => outside_file})
           |> response(404)

    assert build_conn()
           |> get("/files/raw", %{"mount_key" => icm.mount_key, "path" => "/etc/passwd"})
           |> response(404)

    # Absolute path INSIDE the workspace but outside the mount's own ICM
    # root must 404 too — same extension as a legitimate asset, so this
    # actually exercises containment rather than just the extension
    # allowlist.
    workspace_root_png = Path.join(ws, "shadow.png")
    File.write!(workspace_root_png, "not under any mount")

    assert build_conn()
           |> get("/files/raw", %{"mount_key" => icm.mount_key, "path" => workspace_root_png})
           |> response(404)
  end

  test "serve rejects a URL-encoded traversal attempt", %{workspace: ws} do
    icm = mount_primary!(ws)

    # Plug/Phoenix's router already percent-decodes the query string before
    # `params` reaches the controller, so an encoded ".." arrives identical
    # to a literal one — this asserts that decoding doesn't create a second,
    # unguarded code path.
    conn =
      build_conn()
      |> get("/files/raw?mount_key=#{icm.mount_key}&path=%2e%2e%2f%2e%2e%2fsecrets%2Fx.png")

    assert response(conn, 404)
  end

  test "serve includes anti-MIME-sniffing headers and no charset in content-type", %{
    conn: conn,
    workspace: ws
  } do
    icm = mount_primary!(ws)

    upload = %Plug.Upload{
      path: write_tmp_png!(),
      filename: "test.png",
      content_type: "image/png"
    }

    conn1 =
      conn
      |> with_token()
      |> post("/files/upload", %{
        "file" => upload,
        "mount_key" => icm.mount_key,
        "page_path" => "Clients/Julia Steiner.md"
      })

    assert %{"path" => path} = json_response(conn1, 200)

    conn2 = get(build_conn(), "/files/raw", %{"mount_key" => icm.mount_key, "path" => path})
    assert response(conn2, 200)

    # Assert x-content-type-options: nosniff header
    assert get_resp_header(conn2, "x-content-type-options") == ["nosniff"]

    # Assert content-disposition: inline header
    assert get_resp_header(conn2, "content-disposition") == ["inline"]

    # Assert content-type has no charset (should be exactly "image/png", not "image/png; charset=utf-8")
    content_type = get_resp_header(conn2, "content-type") |> hd()
    assert content_type == "image/png"
  end

  test "Mounts.mount_by_key/2 is what upload/serve attribute against — a disabled mount via set_enabled/3 also 400s",
       %{conn: conn, workspace: ws} do
    icm = mount_primary!(ws)
    :ok = Mounts.set_enabled(ws, icm.mount_key, false)

    upload = %Plug.Upload{path: write_tmp_png!(), filename: "x.png", content_type: "image/png"}

    conn1 =
      conn
      |> with_token()
      |> post("/files/upload", %{
        "file" => upload,
        "mount_key" => icm.mount_key,
        "page_path" => "Clients/Julia Steiner.md"
      })

    assert json_response(conn1, 400)

    assert build_conn()
           |> get("/files/raw", %{
             "mount_key" => icm.mount_key,
             "path" => "Clients/Julia Steiner.md"
           })
           |> response(404)
  end
end
