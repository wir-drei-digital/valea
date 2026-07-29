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

  # A serve request carrying the control token. Required for every format
  # OUTSIDE the image allowlist — see the controller moduledoc's
  # "split credential" section. A bare `build_conn()` is the untokened shape
  # an `<img>` tag produces, and is what the image tests deliberately use.
  defp raw_conn, do: build_conn() |> with_token()

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

  # Serve is gated by CONTAINMENT, not by extension (side-panes: the pdf.js
  # and plain-text viewers read arbitrary mount files through this endpoint).
  # This test used to assert 404 for both of these paths, back when the serve
  # action reused the image-only UPLOAD allowlist; the replacement pins the
  # posture that took its place — served, but as an inert fixed type.
  test "serve returns a non-image regular file inside the mount as inert text/plain", %{
    workspace: ws
  } do
    icm = mount_primary!(ws)
    File.write!(Path.join(icm.root, "app.sqlite"), "not an image")

    conn1 = get(raw_conn(), "/files/raw", %{"mount_key" => icm.mount_key, "path" => "app.sqlite"})

    assert response(conn1, 200) == "not an image"
    assert get_resp_header(conn1, "content-type") == ["text/plain; charset=utf-8"]

    conn2 =
      get(raw_conn(), "/files/raw", %{
        "mount_key" => icm.mount_key,
        "path" => "Clients/Julia Steiner.md"
      })

    assert response(conn2, 200) == "# Julia Steiner\n"
    assert get_resp_header(conn2, "content-type") == ["text/plain; charset=utf-8"]
  end

  # The `regular_file?/1` gate is what keeps the widened serve path from
  # 500-ing on a directory (or on a path that simply isn't there). Tokened so
  # the 404 can only be coming from that gate.
  test "serve 404s a directory and a missing file (404, not 500)", %{workspace: ws} do
    icm = mount_primary!(ws)

    assert raw_conn()
           |> get("/files/raw", %{"mount_key" => icm.mount_key, "path" => "Clients"})
           |> response(404)

    assert raw_conn()
           |> get("/files/raw", %{"mount_key" => icm.mount_key, "path" => "no-such-file.txt"})
           |> response(404)
  end

  test "serve returns a .pdf as application/pdf with the anti-sniffing headers", %{workspace: ws} do
    icm = mount_primary!(ws)
    bytes = "%PDF-1.4\nnot a structurally complete pdf, nothing here parses it\n"
    File.write!(Path.join(icm.root, "brochure.pdf"), bytes)

    conn =
      get(raw_conn(), "/files/raw", %{"mount_key" => icm.mount_key, "path" => "brochure.pdf"})

    assert response(conn, 200) == bytes
    assert get_resp_header(conn, "content-type") == ["application/pdf"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(conn, "content-disposition") == ["inline"]
  end

  test "serve returns a .txt as text/plain; charset=utf-8, byte-identical to disk", %{
    workspace: ws
  } do
    icm = mount_primary!(ws)
    bytes = "notes for the pane\nzweite Zeile — mit Umlauten\n"
    File.write!(Path.join(icm.root, "scratch.txt"), bytes)

    conn = get(raw_conn(), "/files/raw", %{"mount_key" => icm.mount_key, "path" => "scratch.txt"})

    assert response(conn, 200) == bytes
    assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(conn, "content-disposition") == ["inline"]
  end

  test "serve returns an extension-less file as text/plain", %{workspace: ws} do
    icm = mount_primary!(ws)
    File.write!(Path.join(icm.root, "LICENSE"), "MIT\n")

    conn = get(raw_conn(), "/files/raw", %{"mount_key" => icm.mount_key, "path" => "LICENSE"})

    assert response(conn, 200) == "MIT\n"
    assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
  end

  # The scriptable formats are the whole reason the fallback is a FIXED
  # literal rather than a lookup: with `nosniff`, a browser must honor
  # `text/plain`, so neither of these can execute in Valea's origin.
  test "serve never emits a scriptable content-type — .svg and .html are text/plain", %{
    workspace: ws
  } do
    icm = mount_primary!(ws)

    File.write!(
      Path.join(icm.root, "logo.svg"),
      "<svg xmlns=\"http://www.w3.org/2000/svg\"><script>alert(1)</script></svg>"
    )

    File.write!(Path.join(icm.root, "page.html"), "<h1>hi</h1><script>alert(1)</script>")

    svg = get(raw_conn(), "/files/raw", %{"mount_key" => icm.mount_key, "path" => "logo.svg"})
    assert response(svg, 200)
    assert get_resp_header(svg, "content-type") == ["text/plain; charset=utf-8"]
    refute get_resp_header(svg, "content-type") |> hd() =~ "svg"
    assert get_resp_header(svg, "x-content-type-options") == ["nosniff"]

    html = get(raw_conn(), "/files/raw", %{"mount_key" => icm.mount_key, "path" => "page.html"})
    assert response(html, 200)
    assert get_resp_header(html, "content-type") == ["text/plain; charset=utf-8"]
    refute get_resp_header(html, "content-type") |> hd() =~ "html"
    assert get_resp_header(html, "x-content-type-options") == ["nosniff"]
  end

  # The serve widening must not leak into the UPLOAD allowlist: what Valea is
  # willing to WRITE into a user's ICM stays images-only.
  test "a .pdf upload is still rejected as unsupported_file_type", %{conn: conn, workspace: ws} do
    icm = mount_primary!(ws)

    upload = %Plug.Upload{
      # `write_tmp_png!/1` is just "a tmp file holding these bytes" — the
      # allowlist keys off `filename`/`content_type`, not the tmp path.
      path: write_tmp_png!("%PDF-1.4\n"),
      filename: "doc.pdf",
      content_type: "application/pdf"
    }

    conn1 =
      conn
      |> with_token()
      |> post("/files/upload", %{
        "file" => upload,
        "mount_key" => icm.mount_key,
        "page_path" => "Clients/Julia Steiner.md"
      })

    assert json_response(conn1, 400) == %{"error" => "unsupported_file_type"}
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

    # Tokened: `/etc/passwd` has no extension, so it is on the credentialed
    # half of the surface — sending the token keeps this assertion pinned on
    # CONTAINMENT rather than passing for the trivial reason.
    assert raw_conn()
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

    # Tokened for the same reason as the absolute-path test above: `.md` is on
    # the credentialed half, and the assertion is about the MOUNT gate.
    assert raw_conn()
           |> get("/files/raw", %{
             "mount_key" => icm.mount_key,
             "path" => "Clients/Julia Steiner.md"
           })
           |> response(404)
  end

  # -- serve: the split credential ----------------------------------------

  # The route's token exemption exists because an `<img>` tag cannot send
  # headers. That is true of ImageView and the editor's inline images and of
  # nothing else — `PlainTextView` (fetch) and `PdfView` (pdf.js
  # `httpHeaders`) can and do send it, so the formats only THEY reach are
  # gated. Loopback is not user-scoped: other local accounts, and browser
  # extensions holding a 127.0.0.1 host permission (not subject to CORS),
  # reach this port too — this is what keeps what they can pull identical to
  # the pre-side-panes surface.
  test "serve requires the control token for non-image formats", %{workspace: ws} do
    icm = mount_primary!(ws)
    File.write!(Path.join(icm.root, "private.txt"), "private notes")
    File.write!(Path.join(icm.root, "brochure.pdf"), "%PDF-1.4\n")
    File.write!(Path.join(icm.root, "LICENSE"), "MIT\n")

    for path <- ["private.txt", "brochure.pdf", "LICENSE", "Clients/Julia Steiner.md"] do
      # No token at all — same opaque 404 as a missing file, no body.
      untokened = get(build_conn(), "/files/raw", %{"mount_key" => icm.mount_key, "path" => path})
      assert response(untokened, 404) == ""

      # A wrong token is not a different answer — no oracle separating
      # "exists but unauthorized" from "not there".
      wrong =
        build_conn()
        |> put_req_header("x-valea-token", "not-the-token")
        |> get("/files/raw", %{"mount_key" => icm.mount_key, "path" => path})

      assert response(wrong, 404) == ""

      # Same request, valid token → the bytes.
      assert raw_conn()
             |> get("/files/raw", %{"mount_key" => icm.mount_key, "path" => path})
             |> response(200)
    end
  end

  test "the image exemption survives — every image format serves without a token", %{
    workspace: ws
  } do
    icm = mount_primary!(ws)

    # One per entry in the upload allowlist: these are the extensions an
    # `<img>` src can still reach with no credential, and the set must not
    # drift from `@allowed_types`.
    for {name, expected} <- [
          {"a.png", "image/png"},
          {"b.jpg", "image/jpeg"},
          {"c.jpeg", "image/jpeg"},
          {"d.gif", "image/gif"},
          {"e.webp", "image/webp"}
        ] do
      File.write!(Path.join(icm.root, name), "bytes for #{name}")

      conn = get(build_conn(), "/files/raw", %{"mount_key" => icm.mount_key, "path" => name})

      assert response(conn, 200) == "bytes for #{name}"
      assert get_resp_header(conn, "content-type") == [expected]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    end
  end

  # An uppercase extension must not be a way around the credentialed half in
  # either direction: `ext_of/1` downcases, so `.PNG` is the image (untokened)
  # bucket and `.TXT` is the tokened one.
  test "the credential split follows the case-folded extension", %{workspace: ws} do
    icm = mount_primary!(ws)
    File.write!(Path.join(icm.root, "SHOUT.PNG"), "png bytes")
    File.write!(Path.join(icm.root, "SHOUT.TXT"), "txt bytes")

    png = get(build_conn(), "/files/raw", %{"mount_key" => icm.mount_key, "path" => "SHOUT.PNG"})
    assert response(png, 200) == "png bytes"
    assert get_resp_header(png, "content-type") == ["image/png"]

    assert build_conn()
           |> get("/files/raw", %{"mount_key" => icm.mount_key, "path" => "SHOUT.TXT"})
           |> response(404)

    assert raw_conn()
           |> get("/files/raw", %{"mount_key" => icm.mount_key, "path" => "SHOUT.TXT"})
           |> response(200) == "txt bytes"
  end
end
