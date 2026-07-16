defmodule Valea.Workflows.MemoryProposal do
  @moduledoc """
  Loading + validation for agent-staged memory-update proposal pairs
  (`proposals/<name>.json` manifest + sibling `<name>.md` content), and the
  server-owned target containment check. Trust boundary: everything here
  treats the pair as untrusted input; the manifest's claims are verified,
  never carried (risk tier is derived elsewhere, from the target path
  alone).

  Two DISTINCT containment checks live here, never merged into one:

    * `check_target/2` — general-purpose, scans EVERY mounted ICM
      (`Mounts.mount_for/2`) to attribute an arbitrary workspace-relative
      or absolute path to its owning mount. `Valea.Api.ICM`'s
      `paths_exist` action (editor dangling-link detection) is its sole
      caller — a bulk existence check over raw path strings that could
      each name a DIFFERENT ICM, so there is no single "owning ICM" to
      scope the search to.
    * `check_icm_target/2` (Task 7.3) — scoped to exactly ONE already-known
      ICM (a workflow run's OWN sidecar `icm_id`/`icm_root`, since the
      agent's session `cwd` for that run IS that ICM's root — Task 7.2).
      `Runner.finalize_pair/6` is its sole caller: a memory-update
      proposal's `target_path` is the agent's own ICM-relative path, never
      re-attributed across every mount, and the result is an ICM locator
      (`Valea.Icm.Locator`) rather than a physical path — the queue payload
      stores the LOCATOR so it survives the ICM being moved/re-mounted
      later (re-resolved at approval via `Locator.resolve/2`).

  Content size is capped at 1_000_000 bytes (agent-authored input, inlined
  into the envelope).
  """

  alias Valea.Icm.Locator
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

      %{enabled: true, degraded: nil, root: root} = mount ->
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

  @doc """
  Finalize-time containment for a memory-update target (Task 7.3):
  `target_path` is the agent's OWN ICM-relative path, relative to `run`'s
  `"icm_root"` — the workflow's OWNING ICM, captured in the Task 7.2 run
  sidecar (`Runner.start_run/6`'s `"icm_id"`/`"icm_root"` fields), since
  the agent's session `cwd` IS that root (Task 7.2). Unlike `check_target/2`
  below, this never re-attributes across every mounted ICM
  (`Mounts.mount_for/2`) — there is exactly ONE candidate, already known —
  so it is a direct `Valea.Paths.resolve_real/2` containment check against
  `run["icm_root"]` alone: `..` or a symlink escaping it is rejected the
  same way every other containment chokepoint in this codebase rejects it
  (create targets may not exist yet — `resolve_real` appends the missing
  remainder literally but still applies `..` physically).

  Returns the ICM locator built DIRECTLY from `run["icm_id"]` + the
  UNCHANGED `target_path` string — never converted to/through an absolute
  intermediate (`Valea.Icm.Locator`'s moduledoc: an icm locator's `path`
  is always relative to its own root already) — alongside the resolved
  absolute path. `run["icm_id"]`/`run["icm_root"]` missing or non-binary
  (the owning mount vanished in the narrow race window
  `Runner.icm_root_for/2` documents) is `:icm_unavailable`; anything that
  escapes containment is `:outside_mount`.
  """
  @spec check_icm_target(map(), term()) ::
          {:ok, %{locator: map(), abs: String.t()}}
          | {:error, :icm_unavailable | :outside_mount}
  def check_icm_target(%{"icm_id" => icm_id, "icm_root" => icm_root}, target_path)
      when is_binary(icm_id) and is_binary(icm_root) and is_binary(target_path) do
    case Valea.Paths.resolve_real(target_path, icm_root) do
      {:ok, abs} -> {:ok, %{locator: Locator.icm(icm_id, target_path), abs: abs}}
      {:error, _reason} -> {:error, :outside_mount}
    end
  end

  def check_icm_target(_run, _target_path), do: {:error, :icm_unavailable}

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

  defp target_abs(_workspace, "/" <> _ = abs), do: Path.expand(abs)
  defp target_abs(workspace, rel), do: Path.expand(rel, workspace)
end
