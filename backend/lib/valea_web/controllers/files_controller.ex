defmodule ValeaWeb.FilesController do
  @moduledoc """
  HTTP file-serving surface for page images: an upload endpoint (token-gated,
  writes into a mount's `Assets/` folder) and a read-only raw-serve endpoint
  (token-EXEMPT — an `<img>` tag cannot send headers; this is a 127.0.0.1
  listener serving only files local processes could already read).

  Both actions attribute the requested path to an ENABLED, non-degraded
  mount and contain it via `Valea.Workflows.MemoryProposal.check_target/2`
  (lexical prefix + `Valea.Paths.resolve_real/2` symlink-aware containment
  under the mount root) — the same shape the memory-update write path uses.
  Never trust a lexically-constructed path for filesystem I/O without
  running it back through containment: `check_target/2`'s `resolve_real`
  is what defeats a symlink planted inside a mount's `Assets/` folder.

  The image allowlist is extension AND `content_type` — deliberately no
  SVG (scriptable) and no content sniffing beyond that pair; the serve
  action always sets `content-type` from the (allowlisted) file EXTENSION,
  never from anything client-supplied or stored, so a mismatched upload
  can never cause the serve path to emit an attacker-chosen content-type.
  """
  use Phoenix.Controller, formats: [:json]

  alias Valea.Paths
  alias Valea.Workflows.MemoryProposal
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

  def upload(conn, %{"file" => %Plug.Upload{} = upload, "page_path" => page_path})
      when is_binary(page_path) do
    do_upload(conn, upload, page_path)
  rescue
    _ -> bad_request(conn, "upload_failed")
  end

  def upload(conn, _params), do: bad_request(conn, "invalid_upload_params")

  defp do_upload(conn, %Plug.Upload{} = upload, page_path) do
    with {:ok, ws} <- workspace_root(),
         {:ok, %{mount: mount}} <- MemoryProposal.check_target(ws, page_path),
         {:ok, %File.Stat{size: size}} <- File.stat(upload.path),
         :ok <- check_size(size),
         ext <- ext_of(upload.filename),
         {:ok, expected_content_type} <- allowed_ext(ext),
         :ok <- check_content_type(upload.content_type, expected_content_type),
         {:ok, bytes} <- File.read(upload.path) do
      write_and_respond(conn, ws, mount, page_path, ext, bytes)
    else
      {:error, :no_workspace} ->
        bad_request(conn, "no_workspace")

      {:error, reason} when reason in [:not_in_mount, :mount_not_enabled, :outside_mount] ->
        bad_request(conn, "invalid_page_path")

      {:error, :too_large} ->
        conn |> put_status(413) |> json(%{error: "file_too_large"})

      {:error, :bad_type} ->
        bad_request(conn, "unsupported_file_type")

      {:error, _posix} ->
        bad_request(conn, "upload_failed")
    end
  end

  defp write_and_respond(conn, ws, mount, page_path, ext, bytes) do
    filename = "#{slugify(page_slug(page_path))}-#{hash8(bytes)}#{ext}"
    dest_tree_path = Path.join([mount_tree_root(mount), "Assets", filename])

    case MemoryProposal.check_target(ws, dest_tree_path) do
      {:ok, %{abs: dest_abs}} ->
        File.mkdir_p!(Path.dirname(dest_abs))
        tmp_abs = dest_abs <> ".tmp"
        File.write!(tmp_abs, bytes)
        File.rename!(tmp_abs, dest_abs)

        rel_from_page = Paths.relative(Path.dirname(page_path), dest_tree_path)

        json(conn, %{"path" => dest_tree_path, "rel_from_page" => rel_from_page})

      {:error, _} ->
        bad_request(conn, "invalid_destination")
    end
  end

  defp page_slug(page_path), do: Path.basename(page_path, ".md")

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

  def serve(conn, %{"path" => path}) when is_binary(path) do
    do_serve(conn, path)
  rescue
    _ -> not_found(conn)
  end

  def serve(conn, _params), do: not_found(conn)

  defp do_serve(conn, path) do
    with ext <- ext_of(path),
         {:ok, content_type} <- allowed_ext(ext),
         {:ok, ws} <- workspace_root(),
         {:ok, %{abs: abs}} <- MemoryProposal.check_target(ws, path),
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

  # -- shared helpers ---------------------------------------------------

  defp ext_of(name), do: name |> Path.extname() |> String.downcase()

  defp allowed_ext(ext) do
    case Map.fetch(@allowed_types, ext) do
      {:ok, content_type} -> {:ok, content_type}
      :error -> {:error, :bad_type}
    end
  end

  defp mount_tree_root(%{rel_root: rel}) when is_binary(rel), do: rel
  defp mount_tree_root(%{root: root}), do: root

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
