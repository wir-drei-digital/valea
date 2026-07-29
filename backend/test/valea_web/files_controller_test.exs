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

  # A valid `config/mail.yaml` account — which is the whole trigger for
  # `Valea.Mounts.list/1` appending the synthetic `mail-<slug>` mount rooted
  # at `<ws>/sources/mail/<slug>` (see `Valea.Mounts.MailMountsTest`).
  # Returns the mount key.
  defp mount_mail!(workspace, slug) do
    path = Path.join(workspace, "config/mail.yaml")
    File.mkdir_p!(Path.dirname(path))

    File.write!(path, """
    version: 4
    accounts:
      #{slug}:
        imap:
          host: imap.fastmail.com
          port: 993
          username: #{slug}@example.com
    """)

    "mail-" <> slug
  end

  # Lands bytes where `Valea.Mail.Views` lands a real attachment, and returns
  # the MOUNT-relative path `/files/raw` addresses it by (the frontmatter's
  # own path minus the `sources/mail/<slug>/` the mount root already names).
  defp write_attachment!(workspace, slug, msg_id, filename, bytes) do
    dir = Path.join([workspace, "sources", "mail", slug, "views", "attachments", msg_id])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, filename), bytes)
    Path.join(["views", "attachments", msg_id, filename])
  end

  defp mint_ticket!(mount_key, path) do
    conn =
      build_conn()
      |> with_token()
      |> post("/files/ticket", %{"mount_key" => mount_key, "path" => path})

    %{"ticket" => ticket} = json_response(conn, 200)
    ticket
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

  # -- serve: mail attachments (mail full-client M1 task 4) ----------------

  # THE VERIFICATION this task turned on: before the carve-out below, a mail
  # attachment was not servable at ALL — `resolve_mount/3`'s ICM-only clause
  # 404s every `mail-<slug>` key. It is servable now, and only under a
  # credential: the image exemption deliberately does NOT follow it into a
  # mailbox, or a `.png` attachment would be readable by every other local
  # account and every 127.0.0.1-permitted browser extension on this listener.
  test "a mail attachment serves with the control token and 404s without one", %{workspace: ws} do
    mount_key = mount_mail!(ws, "mara")
    pdf = write_attachment!(ws, "mara", "msg-1", "invoice.pdf", "%PDF-1.4\n")
    png = write_attachment!(ws, "mara", "msg-1", "shot.png", "png bytes")

    assert raw_conn()
           |> get("/files/raw", %{"mount_key" => mount_key, "path" => pdf})
           |> response(200) == "%PDF-1.4\n"

    tokened_png = get(raw_conn(), "/files/raw", %{"mount_key" => mount_key, "path" => png})
    assert response(tokened_png, 200) == "png bytes"
    assert get_resp_header(tokened_png, "content-type") == ["image/png"]

    # The image half stops at the mount boundary: no token, no attachment,
    # whatever the extension.
    for path <- [pdf, png] do
      assert build_conn()
             |> get("/files/raw", %{"mount_key" => mount_key, "path" => path})
             |> response(404) == ""
    end
  end

  # The carve-out is `views/attachments/` and nothing else — the rest of a
  # mailbox (message views, drafts, the ops ledger, the `.fingerprints`
  # sidecars) stays unreachable through this route even for a token-bearing
  # caller, which is what keeps this an attachment route rather than a
  # mailbox one.
  test "the rest of a mail mount is unreachable even with the control token", %{workspace: ws} do
    mount_key = mount_mail!(ws, "mara")
    root = Path.join([ws, "sources", "mail", "mara"])

    File.mkdir_p!(Path.join([root, "views", "messages"]))
    File.write!(Path.join([root, "views", "messages", "msg-1.md"]), "---\nsubject: secret\n---\n")
    File.mkdir_p!(Path.join([root, "views", ".fingerprints"]))
    File.write!(Path.join([root, "views", ".fingerprints", "msg-1"]), "fingerprint")
    File.mkdir_p!(Path.join(root, "drafts"))
    File.write!(Path.join([root, "drafts", "d1.md"]), "draft body")

    for path <- ["views/messages/msg-1.md", "views/.fingerprints/msg-1", "drafts/d1.md"] do
      assert raw_conn()
             |> get("/files/raw", %{"mount_key" => mount_key, "path" => path})
             |> response(404) == ""
    end

    # …and `..` out of the attachments directory is the same 404 — the
    # boundary is enforced on the COLLAPSED path, not on how it was spelled.
    assert raw_conn()
           |> get("/files/raw", %{
             "mount_key" => mount_key,
             "path" => "views/attachments/msg-1/../../messages/msg-1.md"
           })
           |> response(404) == ""
  end

  test "a symlink inside a mail attachments dir cannot reach the rest of the mailbox", %{
    workspace: ws
  } do
    mount_key = mount_mail!(ws, "mara")
    root = Path.join([ws, "sources", "mail", "mara"])
    write_attachment!(ws, "mara", "msg-1", "real.pdf", "%PDF-1.4\n")

    File.mkdir_p!(Path.join([root, "views", "messages"]))
    File.write!(Path.join([root, "views", "messages", "msg-1.md"]), "secret view")

    File.ln_s!(
      Path.join([root, "views", "messages", "msg-1.md"]),
      Path.join([root, "views", "attachments", "msg-1", "escape.md"])
    )

    assert raw_conn()
           |> get("/files/raw", %{
             "mount_key" => mount_key,
             "path" => "views/attachments/msg-1/escape.md"
           })
           |> response(404) == ""
  end

  # Serving out of a mail mount must not make one WRITABLE: `resolve_mount/2`
  # (upload's arity) hard-codes the rejection, so no credential admits an
  # upload into a mailbox.
  test "upload still refuses a mail mount", %{conn: conn, workspace: ws} do
    mount_key = mount_mail!(ws, "mara")
    upload = %Plug.Upload{path: write_tmp_png!(), filename: "x.png", content_type: "image/png"}

    conn1 =
      conn
      |> with_token()
      |> post("/files/upload", %{
        "file" => upload,
        "mount_key" => mount_key,
        "page_path" => "views/attachments/msg-1/x.png"
      })

    assert json_response(conn1, 400) == %{"error" => "invalid_page_path"}
  end

  # -- serve: tickets ------------------------------------------------------

  # The reason tickets exist: a raw URL opened in a NEW TAB or handed to the
  # OS browser (the mail attachment chip) cannot send `x-valea-token`. A
  # ticket rides the query string instead and is redeemed with no headers at
  # all — the same arrangement as the calendar feed's `?token=`.
  test "a minted ticket serves a mail attachment with no headers at all", %{workspace: ws} do
    mount_key = mount_mail!(ws, "mara")
    pdf = write_attachment!(ws, "mara", "msg-1", "invoice.pdf", "%PDF-1.4\n")

    ticket = mint_ticket!(mount_key, pdf)

    conn =
      get(build_conn(), "/files/raw", %{
        "mount_key" => mount_key,
        "path" => pdf,
        "ticket" => ticket
      })

    assert response(conn, 200) == "%PDF-1.4\n"
    assert get_resp_header(conn, "content-type") == ["application/pdf"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
  end

  # A ticket is a per-FILE capability, not a spare control token: it is
  # signed over the exact pair it was minted for, so it cannot be replayed
  # against another path, another mount, or a mailbox file outside
  # attachments.
  test "a ticket is bound to the exact pair it was minted for", %{workspace: ws} do
    icm = mount_primary!(ws)
    mount_key = mount_mail!(ws, "mara")
    pdf = write_attachment!(ws, "mara", "msg-1", "invoice.pdf", "%PDF-1.4\n")
    other = write_attachment!(ws, "mara", "msg-2", "other.pdf", "other bytes")
    File.write!(Path.join(icm.root, "private.txt"), "private notes")

    ticket = mint_ticket!(mount_key, pdf)

    # Same ticket, different path — refused.
    assert build_conn()
           |> get("/files/raw", %{
             "mount_key" => mount_key,
             "path" => other,
             "ticket" => ticket
           })
           |> response(404) == ""

    # Same ticket, different mount — refused.
    assert build_conn()
           |> get("/files/raw", %{
             "mount_key" => icm.mount_key,
             "path" => "private.txt",
             "ticket" => ticket
           })
           |> response(404) == ""

    # Garbage and empty tickets are the same 404, never a crash.
    for bogus <- ["", "not-a-ticket", ticket <> "x"] do
      assert build_conn()
             |> get("/files/raw", %{
               "mount_key" => mount_key,
               "path" => pdf,
               "ticket" => bogus
             })
             |> response(404) == ""
    end
  end

  test "a ticket expires", %{workspace: ws} do
    mount_key = mount_mail!(ws, "mara")
    pdf = write_attachment!(ws, "mara", "msg-1", "invoice.pdf", "%PDF-1.4\n")

    stale =
      Phoenix.Token.sign(ValeaWeb.Endpoint, "valea:files-raw-ticket", {mount_key, pdf},
        signed_at: System.system_time(:second) - 10_000
      )

    assert build_conn()
           |> get("/files/raw", %{"mount_key" => mount_key, "path" => pdf, "ticket" => stale})
           |> response(404) == ""
  end

  # Minting is the gate. Without the control token there is no way to get a
  # ticket, which is what keeps the ticket from widening the unauthenticated
  # surface — the pipeline's 401, not the serve route's 404, because this
  # half of `/files` is the plug-gated one.
  test "minting a ticket requires the control token", %{workspace: ws} do
    mount_key = mount_mail!(ws, "mara")
    pdf = write_attachment!(ws, "mara", "msg-1", "invoice.pdf", "%PDF-1.4\n")

    assert build_conn()
           |> post("/files/ticket", %{"mount_key" => mount_key, "path" => pdf})
           |> response(401)

    assert build_conn()
           |> with_token()
           |> post("/files/ticket", %{"mount_key" => mount_key})
           |> json_response(400) == %{"error" => "invalid_ticket_params"}
  end

  # A ticket is a general alternative credential, not a mail-only one — it
  # reaches the same tokened half of the ICM surface `PlainTextView` and
  # `PdfView` use their header for. It still grants no more than the token
  # holder who minted it already had.
  test "a ticket also serves the credentialed half of an ICM mount", %{workspace: ws} do
    icm = mount_primary!(ws)
    File.write!(Path.join(icm.root, "private.txt"), "private notes")

    ticket = mint_ticket!(icm.mount_key, "private.txt")

    assert build_conn()
           |> get("/files/raw", %{
             "mount_key" => icm.mount_key,
             "path" => "private.txt",
             "ticket" => ticket
           })
           |> response(200) == "private notes"
  end

  # Containment outranks the ticket: a signed pair naming a path outside the
  # mount is still refused, so minting can stay the dumb signature it is.
  test "a ticket never substitutes for containment", %{workspace: ws} do
    icm = mount_primary!(ws)

    outside_dir =
      Path.join(
        System.tmp_dir!(),
        "valea-ticket-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(outside_dir)
    outside_file = Path.join(outside_dir, "secret.txt")
    File.write!(outside_file, "should never be served")

    for path <- [outside_file, "../../secrets/x.txt"] do
      ticket = mint_ticket!(icm.mount_key, path)

      assert build_conn()
             |> get("/files/raw", %{
               "mount_key" => icm.mount_key,
               "path" => path,
               "ticket" => ticket
             })
             |> response(404) == ""
    end
  end
end
