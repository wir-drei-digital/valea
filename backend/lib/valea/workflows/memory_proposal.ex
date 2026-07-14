defmodule Valea.Workflows.MemoryProposal do
  @moduledoc """
  Loading + validation for agent-staged memory-update proposal pairs
  (`proposals/<name>.json` manifest + sibling `<name>.md` content), and
  the server-owned target containment check. Trust boundary: everything
  here treats the pair as untrusted input; the manifest's claims are
  verified, never carried (risk tier is derived elsewhere, from the
  target path alone).

  Content size is capped at 1_000_000 bytes (agent-authored input, inlined
  into the envelope).
  """

  alias Valea.Mounts

  @max_content_bytes 1_000_000

  @spec load_pairs(String.t()) :: [{String.t(), {:ok, map()} | {:error, atom()}}]
  def load_pairs(staging_dir) do
    dir = Path.join(staging_dir, "proposals")
    files = dir |> Path.join("*") |> Path.wildcard() |> Enum.map(&Path.basename/1)
    jsons = files |> Enum.filter(&String.ends_with?(&1, ".json")) |> Enum.sort()
    mds = files |> Enum.filter(&String.ends_with?(&1, ".md")) |> MapSet.new()

    claimed = MapSet.new(jsons, &(Path.rootname(&1) <> ".md"))

    pairs = Enum.map(jsons, fn json -> {json, load_pair(dir, json, mds)} end)

    orphans =
      for md <- Enum.sort(MapSet.to_list(mds)), not MapSet.member?(claimed, md) do
        {md, {:error, :orphaned_content}}
      end

    pairs ++ orphans
  end

  defp load_pair(dir, json, mds) do
    md = Path.rootname(json) <> ".md"

    with {:md, true} <- {:md, MapSet.member?(mds, md)},
         {:ok, bytes} <- File.read(Path.join(dir, json)),
         {:ok, %{} = manifest} <- Jason.decode(bytes),
         true <- valid_manifest?(manifest),
         {:ok, content} <- File.read(Path.join(dir, md)),
         {:size, true} <- {:size, byte_size(content) <= @max_content_bytes},
         true <- String.valid?(content) do
      {:ok, %{manifest: manifest, content: content}}
    else
      {:md, false} -> {:error, :missing_content}
      {:size, false} -> {:error, :content_too_large}
      false -> {:error, :invalid_manifest}
      _ -> {:error, :invalid_pair}
    end
  end

  defp valid_manifest?(m) do
    m["schema"] == "memory_update/v1" and
      nonempty?(m["target_path"]) and
      not String.ends_with?(m["target_path"], "/") and
      valid_base?(m["base_sha256"]) and
      nonempty?(m["reason"]) and
      is_list(m["sources"]) and Enum.all?(m["sources"], &is_binary/1)
  end

  defp valid_base?(nil), do: true
  defp valid_base?(b) when is_binary(b), do: b =~ ~r/\A[0-9a-f]{64}\z/
  defp valid_base?(_b), do: false

  defp nonempty?(s), do: is_binary(s) and String.trim(s) != ""

  @doc """
  Server-owned containment: the target must attribute to an ENABLED,
  non-degraded mount, and its physical resolution must stay inside that
  mount's root (create targets may not exist yet — resolve_real appends
  the missing remainder literally but still applies `..` physically).
  Returns the lexical absolute path to write.
  """
  @spec check_target(String.t(), String.t()) ::
          {:ok, %{mount: map(), abs: String.t()}}
          | {:error, :not_in_mount | :mount_not_enabled | :outside_mount}
  def check_target(workspace, target_path) do
    case find_mount(workspace, target_path) do
      nil ->
        {:error, :not_in_mount}

      %{enabled: true, degraded: nil} = mount ->
        root = mount_root_abs(workspace, mount)
        abs = target_abs(workspace, target_path)

        with true <- String.starts_with?(abs, root <> "/"),
             {:ok, _real} <- Valea.Paths.resolve_real(abs, root) do
          {:ok, %{mount: mount, abs: abs}}
        else
          _ -> {:error, :outside_mount}
        end

      _mount ->
        {:error, :mount_not_enabled}
    end
  end

  # `Mounts.mount_for/2` attributes a path ONLY among EFFECTIVE (enabled AND
  # non-degraded) mounts by design (see its own moduledoc) — a DISABLED
  # mount is filtered out right alongside a degraded one, so it can never
  # be the mount `mount_for/2` returns. That collapses the `_mount ->
  # {:error, :mount_not_enabled}` clause above into dead code: this
  # function needs to tell "names a real, healthy mount that happens to be
  # disabled" apart from "names no mount at all," which `mount_for/2`'s
  # contract cannot give it. So attribution here is independent —
  # `Mounts.list/1` filtered to non-degraded entries only (mirroring
  # `Mounts.mount_for/2`'s own segment-boundary, most-specific-root
  # logic), deliberately WITHOUT the `enabled` filter, so a disabled
  # mount is still attributed (and rejected with the specific
  # `:mount_not_enabled` reason above) rather than masquerading as
  # "not in any mount." A degraded mount's root stays excluded — same
  # untrusted-root reasoning as `Mounts.mount_for/2`.
  defp find_mount(workspace, target_path) do
    workspace
    |> Mounts.list()
    |> Enum.filter(&(&1.degraded == nil and mount_prefix?(target_path, &1.root)))
    |> most_specific_root()
  end

  defp most_specific_root([]), do: nil
  defp most_specific_root(matches), do: Enum.max_by(matches, &byte_size(&1.root))

  defp mount_prefix?(path, root) do
    root != "" and (path == root or String.starts_with?(path <> "/", root <> "/"))
  end

  defp mount_root_abs(workspace, %{rel_root: rel}) when is_binary(rel),
    do: Path.join(workspace, rel)

  defp mount_root_abs(_workspace, %{root: root}), do: root

  defp target_abs(_workspace, "/" <> _ = abs), do: Path.expand(abs)
  defp target_abs(workspace, rel), do: Path.expand(rel, workspace)
end
