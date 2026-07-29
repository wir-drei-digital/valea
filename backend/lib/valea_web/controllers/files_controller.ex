defmodule ValeaWeb.FilesController do
  @moduledoc """
  HTTP file-serving surface for page images and the Knowledge file viewers:
  an upload endpoint (token-gated, writes into a mount's `Assets/` folder)
  and a read-only raw-serve endpoint whose token gate is PARTIAL — images
  are exempt, every other format is not. See "The serve route's split
  credential" below; the router's `:serve` scope carries the short version.

  Both actions address content by `(mount_key, mount-relative path)` — the
  same vocabulary `Valea.ICM` uses (task 4.4 re-key) — never a raw
  workspace-relative or bare absolute path. `resolve_mount/3` looks
  `mount_key` up via `Valea.Mounts.mount_by_key/2` and requires it to be
  ENABLED and non-degraded; `contain/3` then re-expands the relative path
  against THAT mount's own root and re-checks it via
  `Valea.Paths.resolve_real/2` (symlink-aware containment — a symlink
  planted inside the mount can't smuggle either action outside its root).
  Never trust a lexically-constructed path for filesystem I/O without
  running it back through containment.

  ## The serve route's split credential (side-panes pass)

  `GET /files/raw` is only PARTLY token-exempt, and the split is exactly
  the shape of the exemption's own justification. The exemption exists
  because an `<img>` tag cannot send headers — true of `ImageView` and of
  the editor's inline images, and of nothing else. The viewers added in the
  side-panes pass CAN carry a credential (`PlainTextView` fetches;
  `PdfView` hands pdf.js `httpHeaders`), so they do:

    * extension in `@allowed_types` (the image formats) — served
      token-free, and ONLY out of an `:icm` mount. The pre-existing
      unauthenticated surface, unchanged.
    * everything else (`.pdf`, and every extension that falls to the text
      bucket) — requires a CREDENTIAL: either the `x-valea-token` control
      token (the same credential, read from the same header and compared
      with the same `Plug.Crypto.secure_compare/2`, as
      `ValeaWeb.Plugs.ControlToken` enforces for `/rpc/*` and
      `/files/upload`) or a `ticket` (see below).

  Only the FAILURE shape differs from that plug. It answers 401; this
  route answers its usual empty 404 for everything, so a missing token, a
  wrong token, a path outside the mount and a file that does not exist are
  indistinguishable — no oracle for "exists but unauthorized". The check
  also runs BEFORE any filesystem work (ticket verification is pure
  crypto over the query params), so an unauthorized request cannot learn
  about a file by how long the 404 took.

  ## Tickets — a credential for a request that cannot send headers (mail pass)

  `POST /files/ticket` (control-token gated, same pipeline as
  `/files/upload`) mints a `Phoenix.Token` signed over the exact
  `{mount_key, path}` pair being asked for, and `GET /files/raw` accepts
  `?ticket=` in place of the header. It exists because a raw URL handed
  to a NEW TAB or to the OS browser (`openExternal` — the mail
  attachment-chip open) cannot carry a header, exactly the situation the
  calendar feed's own `?token=` solves for subscription fetchers.

  A ticket is not a widening of the unauthenticated surface: minting one
  requires the control token, and a token-bearing caller could already
  read the same bytes through the header. What it grants is deliberately
  the NARROWEST thing that makes the open work — ONE `{mount_key, path}`
  pair (a ticket for another file simply fails the `^mount_key`/`^path`
  match), for `@ticket_max_age` seconds, with no ambient authority of any
  kind. `secret_key_base` is the signing key, so a ticket cannot be
  forged without it and cannot be turned back into the control token.

  ## Mail attachments (mail full-client M1 task 4)

  Synthetic `kind: :mail` mounts were, and outside this one carve-out
  still are, rejected outright (see `resolve_mount/3`). The carve-out:
  a CREDENTIALED request may serve out of a mail mount, and only from its
  `views/attachments/` subtree (`Valea.Mail.Views.attachments_mount_rel_dir/0`
  — the layout lives there, not here). Everything else under
  `sources/mail/<slug>` — the message views, the drafts, the ops ledger,
  the `.fingerprints` sidecars, the index — stays unreachable through
  this route.

  Both halves of that sentence carry weight. CREDENTIALED, because the
  image exemption must not follow: a `.png` attachment served token-free
  would put the user's mail within reach of every other local account and
  every `127.0.0.1`-permitted browser extension, which is precisely the
  reach the exemption is scoped to avoid. And ATTACHMENTS ONLY, because
  the reason to reach into a mailbox from an HTTP file route at all is
  the one file the human just clicked — an attachment they are already
  reading the message of — not the mailbox.

  Why this matters on a loopback listener: 127.0.0.1 is not user-scoped.
  "Only files a local process could already read" is true of the user's
  OWN processes and imprecise as a blanket claim — every other local
  account on the machine can reach this port, as can any browser extension
  holding a `127.0.0.1` host permission (which is not subject to CORS).
  Those principals could previously pull image-extension files out of a
  mount and nothing else; keeping the untokened surface at exactly the
  image formats keeps that true after the widening below.

  ## Two allowlists, deliberately different (side-panes pass)

  UPLOAD is the narrow one and is UNCHANGED: `@allowed_types` gates on
  extension AND the client-declared `content_type`, and the two must
  agree — deliberately no SVG (scriptable), no PDF, no content sniffing
  beyond that pair. What Valea is willing to WRITE into a user's ICM stays
  images-only.

  SERVE is gated by the credential above and by CONTAINMENT, not by
  extension: any regular file that survives the token split,
  `resolve_mount/2` and `contain/2` is served, because the Knowledge
  viewers (pdf.js for `.pdf`, read-only text for everything without a
  dedicated viewer) read arbitrary mount files through this endpoint, and
  a token-bearing caller is by definition the app itself, which already
  reads any mount file it likes through `Valea.ICM`. The extension no
  longer decides ADMISSION at all; it picks the `content-type`, and every
  type it can
  pick is a FIXED LITERAL compiled into this module: `@serve_types` (the
  image map plus `application/pdf`) or, for anything else — including no
  extension at all — the fixed `text/plain` + `utf-8`. Nothing
  client-supplied or stored is ever echoed into `content-type`, so a
  mismatched upload still cannot make the serve path emit an
  attacker-chosen type, and there is still no sniffing anywhere.

  The scriptable formats are why that fallback is a literal and not a
  lookup: `.svg`, `.html` and `.js` all land in the `text/plain` bucket,
  and every response carries `x-content-type-options: nosniff` (plus
  `content-disposition: inline`), so the browser must honor `text/plain`
  and none of them can execute as markup or script in Valea's origin. SVG
  is never served as `image/svg+xml`, exactly as it is never accepted for
  upload. The corollary of dropping the extension gate is that containment
  is now the ONLY thing standing between a request and a mount's bytes —
  treat `contain/2` and `resolve_mount/2` accordingly.

  ## The Assets/ stance (locked in review, task 4.4)

  Writing an uploaded image into the external ICM's `Assets/` folder is a
  deliberate, reviewed exception to "Valea-generated runtime/settings files
  never land inside a user-owned ICM" (spec invariant 9) — but it is not
  actually in tension with that invariant, because the image being written
  is not a Valea-generated runtime/settings artifact at all. It is USER
  CONTENT: bytes the human pasted or dropped into their own note, which
  they are asking Valea to store alongside that note, in the same ICM the
  note itself lives in. Invariant 9 targets Valea's own logs/settings/db
  (things Valea writes for ITS OWN operational purposes); a pasted image is
  the moral equivalent of typing a paragraph of text into the page — the
  ICM is exactly where it belongs.

  This is also why `upload/2` correctly does NOT pass through the agent
  `Valea.Agents.PermissionPolicy` ask-gate: that gate exists to mediate
  writes an AGENT initiates on the human's behalf, where the human isn't
  the one physically performing the action and needs a chance to approve
  it first. An image paste/drop is the opposite shape — a human, sitting at
  the editor, directly performing the write via an explicit UI gesture. The
  human IS the approver; there is no agent decision here to gate. State
  this asymmetry so it reads as a decision, not an oversight: agent writes
  are ask-gated because the agent isn't the user; this endpoint is
  ungated because the user IS the one calling it.
  """
  use Phoenix.Controller, formats: [:json]

  alias Valea.Mail.Views
  alias Valea.Mounts
  alias Valea.Paths
  alias Valea.Workspace.Manager

  # Business cap enforced explicitly via `File.stat/1` on the upload's tmp
  # path — the parser's `length:` (endpoint.ex) is only the transport
  # backstop and is set higher to give this check headroom to run first.
  @max_upload_bytes 10_000_000

  # UPLOAD allowlist — what Valea will write into a user's ICM. Images only.
  @allowed_types %{
    ".png" => "image/png",
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".gif" => "image/gif",
    ".webp" => "image/webp"
  }

  # SERVE type map — a strict superset of the upload one, read ONLY by
  # `serve_content_type/1`. Adding a type here widens what `content-type`
  # the serve path can emit; it does NOT widen what uploads accept.
  @serve_types Map.merge(@allowed_types, %{".pdf" => "application/pdf"})

  # Ticket signing (see the moduledoc's "Tickets" section). The salt is a
  # fixed domain separator; the max age is a click's worth of time — long
  # enough for a cold OS browser to launch and fetch, short enough that a
  # ticket left behind in browser history is dead by the time anyone reads
  # it there.
  @ticket_salt "valea:files-raw-ticket"
  @ticket_max_age 120

  # -- POST /files/upload --------------------------------------------------

  def upload(conn, %{
        "file" => %Plug.Upload{} = upload,
        "mount_key" => mount_key,
        "page_path" => page_path
      })
      when is_binary(mount_key) and is_binary(page_path) do
    do_upload(conn, upload, mount_key, page_path)
  rescue
    _ -> bad_request(conn, "upload_failed")
  end

  def upload(conn, _params), do: bad_request(conn, "invalid_upload_params")

  defp do_upload(conn, %Plug.Upload{} = upload, mount_key, page_path) do
    with {:ok, ws} <- workspace_root(),
         {:ok, mount} <- resolve_mount(ws, mount_key),
         {:ok, _page_abs} <- contain(mount.root, page_path),
         {:ok, %File.Stat{size: size}} <- File.stat(upload.path),
         :ok <- check_size(size),
         ext <- ext_of(upload.filename),
         {:ok, expected_content_type} <- allowed_ext(ext),
         :ok <- check_content_type(upload.content_type, expected_content_type),
         {:ok, bytes} <- File.read(upload.path) do
      write_and_respond(conn, mount, page_path, ext, bytes)
    else
      {:error, :no_workspace} ->
        bad_request(conn, "no_workspace")

      {:error, reason} when reason in [:invalid_mount_key, :outside_mount] ->
        bad_request(conn, "invalid_page_path")

      {:error, :too_large} ->
        conn |> put_status(413) |> json(%{error: "file_too_large"})

      {:error, :bad_type} ->
        bad_request(conn, "unsupported_file_type")

      {:error, _posix} ->
        bad_request(conn, "upload_failed")
    end
  end

  defp write_and_respond(conn, mount, page_path, ext, bytes) do
    filename = "#{slugify(page_slug(page_path))}-#{hash8(bytes)}#{ext}"
    dest_rel = Path.join("Assets", filename)

    case contain(mount.root, dest_rel) do
      {:ok, dest_abs} ->
        File.mkdir_p!(Path.dirname(dest_abs))
        tmp_abs = dest_abs <> ".tmp"
        File.write!(tmp_abs, bytes)
        File.rename!(tmp_abs, dest_abs)

        rel_from_page = Paths.relative(page_dir(page_path), dest_rel)

        json(conn, %{"path" => dest_rel, "rel_from_page" => rel_from_page})

      {:error, _} ->
        bad_request(conn, "invalid_destination")
    end
  end

  defp page_slug(page_path), do: Path.basename(page_path, ".md")

  # `Path.dirname/1` returns "." for a bare top-level filename ("Welcome.md")
  # — but `Paths.relative/2` (and the frontend's `joinRelative`/`dirnameOf`
  # inverse, see `image-upload.ts`) treats a top-level page's directory as
  # the EMPTY string, not ".". Normalizing here keeps a root-level page's
  # `rel_from_page` correct (`"Assets/x.png"`, not `"../Assets/x.png"`).
  defp page_dir(page_path) do
    case Path.dirname(page_path) do
      "." -> ""
      dir -> dir
    end
  end

  defp slugify(name) do
    slug =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")

    if slug == "", do: "asset", else: slug
  end

  defp hash8(bytes) do
    :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower) |> binary_part(0, 8)
  end

  defp check_size(size) when size <= @max_upload_bytes, do: :ok
  defp check_size(_size), do: {:error, :too_large}

  defp check_content_type(content_type, content_type), do: :ok
  defp check_content_type(_actual, _expected), do: {:error, :bad_type}

  # -- POST /files/ticket ---------------------------------------------------

  # Deliberately does NO authority work of its own — no workspace, no mount
  # lookup, no containment, no existence check. A ticket is a SIGNATURE over
  # what was asked for, not a promise that it can be served: `serve/2`
  # re-runs every gate on redemption, so validating here would only
  # duplicate that (and hand an oracle to a caller who, holding the control
  # token, could simply ask `/files/raw` directly). The control-token
  # pipeline on this route is the whole gate.
  def ticket(conn, %{"mount_key" => mount_key, "path" => path})
      when is_binary(mount_key) and is_binary(path) do
    json(conn, %{"ticket" => Phoenix.Token.sign(conn, @ticket_salt, {mount_key, path})})
  end

  def ticket(conn, _params), do: bad_request(conn, "invalid_ticket_params")

  # -- GET /files/raw -------------------------------------------------------

  def serve(conn, %{"mount_key" => mount_key, "path" => path} = params)
      when is_binary(mount_key) and is_binary(path) do
    do_serve(conn, params, mount_key, path)
  rescue
    _ -> not_found(conn)
  end

  def serve(conn, _params), do: not_found(conn)

  # The extension no longer decides admission by ITSELF (it did, while this
  # endpoint only ever fed `<img>` tags) — it decides whether a credential is
  # required. Everything below that is authority: workspace, an enabled
  # non-degraded mount (an ICM one, or — credentialed only — a mail one),
  # both containment layers, and a regular file. Anything reaching
  # `send_file/3` is a file inside a mount the user has enabled, requested
  # either with a credential or for one of the image formats.
  #
  # `credentialed?` is computed FIRST and threaded onward rather than
  # re-derived: it is what keeps the credential decision ahead of every
  # filesystem touch (the moduledoc's no-timing-oracle property), and it is
  # the same fact `resolve_mount/3` needs to decide whether a mail mount may
  # resolve at all.
  defp do_serve(conn, params, mount_key, path) do
    ext = ext_of(path)
    credentialed? = credentialed?(conn, params, mount_key, path)

    with true <- credentialed? or Map.has_key?(@allowed_types, ext),
         {:ok, ws} <- workspace_root(),
         {:ok, mount} <- resolve_mount(ws, mount_key, credentialed?),
         {:ok, abs} <- contain_for_serve(mount, path),
         true <- regular_file?(abs) do
      {content_type, charset} = serve_content_type(ext)

      conn
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("content-disposition", "inline")
      |> put_resp_content_type(content_type, charset)
      |> send_file(200, abs)
    else
      _ -> not_found(conn)
    end
  end

  # The two credentials this route accepts, in the order they cost: the
  # header token (a comparison) then a ticket (a signature verification).
  # Either one means "a caller that already holds the control token asked
  # for this", which is what every gate downstream is entitled to assume.
  defp credentialed?(conn, params, mount_key, path) do
    valid_control_token?(conn) or valid_ticket?(conn, params, mount_key, path)
  end

  # Same header, same constant-time comparison, same source of truth as
  # `ValeaWeb.Plugs.ControlToken` — this is that plug's check inlined so the
  # failure can be this route's opaque 404 instead of the plug's 401, and so
  # it can apply to only half the surface. `ControlToken.expected/0` raises
  # when the token is unset, which `serve/2`'s rescue turns into the same
  # 404: a misconfigured boot fails CLOSED here.
  defp valid_control_token?(conn) do
    case get_req_header(conn, "x-valea-token") do
      [token] when is_binary(token) ->
        Plug.Crypto.secure_compare(token, ValeaWeb.ControlToken.expected())

      _ ->
        false
    end
  end

  # A `?ticket=` is honored ONLY for the exact pair it was signed over —
  # the pins do the work: a ticket minted for one file cannot be replayed
  # against another, so this stays a per-file capability rather than a
  # second, weaker way to hold the control token. Age is bounded by
  # `Phoenix.Token`'s own `max_age`, and the signature by
  # `secret_key_base`; anything malformed, expired, forged or for a
  # different pair lands in the same `false` as no ticket at all.
  defp valid_ticket?(conn, %{"ticket" => ticket}, mount_key, path) when is_binary(ticket) do
    case Phoenix.Token.verify(conn, @ticket_salt, ticket, max_age: @ticket_max_age) do
      {:ok, {^mount_key, ^path}} -> true
      _otherwise -> false
    end
  end

  defp valid_ticket?(_conn, _params, _mount_key, _path), do: false

  # Total by construction: `{content_type, charset}`, both always fixed
  # literals from this module (see the moduledoc's serve paragraph). The
  # mapped binary types keep a nil charset — a charset is meaningless on
  # image/PDF bytes and the existing header test pins its absence — while
  # the text fallback declares utf-8 so viewers decode consistently instead
  # of guessing per browser.
  defp serve_content_type(ext) do
    case Map.fetch(@serve_types, ext) do
      {:ok, content_type} -> {content_type, nil}
      :error -> {"text/plain", "utf-8"}
    end
  end

  defp regular_file?(abs) do
    case File.stat(abs) do
      {:ok, %File.Stat{type: :regular}} -> true
      _ -> false
    end
  end

  # -- shared containment (mirrors `Valea.ICM`'s `resolve_mount/1` +
  # `contain/2`) ------------------------------------------------------------

  # `mount_key` must name a currently ENABLED, non-degraded mount — a
  # disabled/degraded/unknown mount key is folded into one error, same
  # posture `Valea.ICM.resolve_mount/1` takes (an editor-authority
  # chokepoint, not a config lookup).
  #
  # `allow_mail?` is the ONE carve-out from the blanket rejection its two
  # siblings (`Valea.ICM.resolve_mount/1`, `Valea.Api.ICM.find_mount`) still
  # apply to synthetic `kind: :mail` mounts, and it is false everywhere but
  # a CREDENTIALED serve. Upload never passes it — `resolve_mount/2` hard-
  # codes `false`, so what Valea will WRITE stays ICM-only no matter what
  # credential the writer holds — and neither does the route's untokened
  # image half, which is what keeps a `.png` attachment out of reach of the
  # other principals on the loopback listener. `contain_for_serve/2` then
  # narrows a mail mount to attachments; this only decides that a mail mount
  # may resolve at all.
  defp resolve_mount(ws, mount_key), do: resolve_mount(ws, mount_key, false)

  defp resolve_mount(ws, mount_key, allow_mail?) do
    case Mounts.mount_by_key(ws, mount_key) do
      %{enabled: true, degraded: nil, kind: :icm} = mount -> {:ok, mount}
      %{enabled: true, degraded: nil, kind: :mail} = mount when allow_mail? -> {:ok, mount}
      _ -> {:error, :invalid_mount_key}
    end
  end

  # Where a mount's servable subtree starts. An ICM mount is servable whole
  # (the Knowledge viewers read arbitrary mount files); a mail mount is
  # servable ONLY under `views/attachments/`, and gets containment TWICE to
  # say so: once against the mount root — the gate every mount passes, which
  # a symlinked `attachments` directory pointing out of the mailbox would
  # fail — and once against the attachments directory itself, which is what
  # rules out the message views, drafts, ledger and sidecars sitting beside
  # it. Both calls return the same lexical path, so the second's is the one
  # that matters and either one's rejection is the whole request's.
  defp contain_for_serve(%{kind: :mail, root: root}, path) do
    with {:ok, _abs} <- contain(root, path) do
      contain(root, path, Path.join(root, Views.attachments_mount_rel_dir()))
    end
  end

  defp contain_for_serve(%{root: root}, path), do: contain(root, path)

  # Containment has two layers, both required: LEXICAL (the `..`-collapsed
  # expansion of `rel_path` against `root` must fall STRICTLY under
  # `boundary` as a string — the boundary itself is not a servable file) and
  # REAL (`Valea.Paths.resolve_real/2` walks the path the way
  # the OS would, so a symlink planted inside the mount can't smuggle
  # authority to somewhere else entirely). Returns the LEXICAL absolute
  # path on success — every caller does I/O on the path named, exactly as
  # requested; `resolve_real/2` here is a gate, not a rewrite.
  #
  # `boundary` defaults to `root` and is only ever narrowed (never widened)
  # by a caller: `rel_path` stays relative to the MOUNT root in every case —
  # one addressing vocabulary, per the moduledoc — while both layers can be
  # asked to hold against a subtree of it instead. See `contain_for_serve/2`.
  defp contain(root, rel_path), do: contain(root, rel_path, root)

  defp contain(root, rel_path, boundary) do
    # Normalized at construction: `Path.expand/2` is host-native and OTP's
    # win32 `filename` functions DOWNCASE the drive letter, while `root` is
    # already in `Paths` vocabulary (UPPERCASE drive). Without this the
    # strict-child guard below can never be false on Windows.
    abs = Paths.normalize(Path.expand(rel_path, root))
    limit = Paths.normalize(boundary)

    if Paths.ancestor?(limit, abs) and not Paths.same_path?(abs, limit) do
      case Paths.resolve_real(abs, limit) do
        {:ok, _real} -> {:ok, abs}
        {:error, _reason} -> {:error, :outside_mount}
      end
    else
      {:error, :outside_mount}
    end
  end

  # -- shared helpers ---------------------------------------------------

  defp ext_of(name), do: name |> Path.extname() |> String.downcase()

  # UPLOAD-only gate (the serve path resolves a type instead, via
  # `serve_content_type/1`) — an extension outside `@allowed_types` is a
  # rejected upload, never a served file's type.
  defp allowed_ext(ext) do
    case Map.fetch(@allowed_types, ext) do
      {:ok, content_type} -> {:ok, content_type}
      :error -> {:error, :bad_type}
    end
  end

  defp workspace_root do
    case Manager.current() do
      {:ok, %{path: ws}} -> {:ok, ws}
      {:error, :no_workspace} -> {:error, :no_workspace}
    end
  end

  defp bad_request(conn, error) do
    conn |> put_status(400) |> json(%{error: error})
  end

  defp not_found(conn) do
    send_resp(conn, 404, "")
  end
end
