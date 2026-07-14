defmodule ValeaWeb.FilesController do
  @moduledoc """
  HTTP file-serving surface for page images: an upload endpoint (token-gated,
  writes into a mount's `Assets/` folder) and a read-only raw-serve endpoint
  (token-EXEMPT — an `<img>` tag cannot send headers; this is a 127.0.0.1
  listener serving only files local processes could already read).

  Both actions address content by `(mount_key, ICM-relative path)` — the
  same vocabulary `Valea.ICM` uses (task 4.4 re-key) — never a raw
  workspace-relative or bare absolute path. `resolve_mount/2` looks
  `mount_key` up via `Valea.Mounts.mount_by_key/2` and requires it to be
  ENABLED and non-degraded; `contain/2` then re-expands the relative path
  against THAT mount's own root and re-checks it via
  `Valea.Paths.resolve_real/2` (symlink-aware containment — a symlink
  planted inside the mount can't smuggle either action outside its root).
  Never trust a lexically-constructed path for filesystem I/O without
  running it back through containment.

  The image allowlist is extension AND `content_type` — deliberately no
  SVG (scriptable) and no content sniffing beyond that pair; the serve
  action always sets `content-type` from the (allowlisted) file EXTENSION,
  never from anything client-supplied or stored, so a mismatched upload
  can never cause the serve path to emit an attacker-chosen content-type.

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

  alias Valea.Mounts
  alias Valea.Paths
  alias Valea.Workspace.Manager

  # Business cap enforced explicitly via `File.stat/1` on the upload's tmp
  # path — the parser's `length:` (endpoint.ex) is only the transport
  # backstop and is set higher to give this check headroom to run first.
  @max_upload_bytes 10_000_000

  @allowed_types %{
    ".png" => "image/png",
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".gif" => "image/gif",
    ".webp" => "image/webp"
  }

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

  # -- GET /files/raw -------------------------------------------------------

  def serve(conn, %{"mount_key" => mount_key, "path" => path})
      when is_binary(mount_key) and is_binary(path) do
    do_serve(conn, mount_key, path)
  rescue
    _ -> not_found(conn)
  end

  def serve(conn, _params), do: not_found(conn)

  defp do_serve(conn, mount_key, path) do
    with ext <- ext_of(path),
         {:ok, content_type} <- allowed_ext(ext),
         {:ok, ws} <- workspace_root(),
         {:ok, mount} <- resolve_mount(ws, mount_key),
         {:ok, abs} <- contain(mount.root, path),
         true <- regular_file?(abs) do
      conn
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("content-disposition", "inline")
      |> put_resp_content_type(content_type, nil)
      |> send_file(200, abs)
    else
      _ -> not_found(conn)
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
  defp resolve_mount(ws, mount_key) do
    case Mounts.mount_by_key(ws, mount_key) do
      %{enabled: true, degraded: nil} = mount -> {:ok, mount}
      _ -> {:error, :invalid_mount_key}
    end
  end

  # Containment has two layers, both required: LEXICAL (the `..`-collapsed
  # expansion of `rel_path` against `root` must fall under `root` as a
  # string) and REAL (`Valea.Paths.resolve_real/2` walks the path the way
  # the OS would, so a symlink planted inside the mount can't smuggle
  # authority to somewhere else entirely). Returns the LEXICAL absolute
  # path on success — every caller does I/O on the path named, exactly as
  # requested; `resolve_real/2` here is a gate, not a rewrite.
  defp contain(root, rel_path) do
    abs = Path.expand(rel_path, root)

    if String.starts_with?(abs, root <> "/") do
      case Paths.resolve_real(abs, root) do
        {:ok, _real} -> {:ok, abs}
        {:error, _reason} -> {:error, :outside_mount}
      end
    else
      {:error, :outside_mount}
    end
  end

  # -- shared helpers ---------------------------------------------------

  defp ext_of(name), do: name |> Path.extname() |> String.downcase()

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
