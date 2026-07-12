defmodule Valea.Mounts.External do
  @moduledoc """
  Config model for BY-REFERENCE mounts — an ICM that lives OUTSIDE the
  workspace, declared in `config/workspace.yaml`'s `mounts:` section by a
  `kind: "path"` entry carrying a `ref:` (the external folder). This module
  only reads that declaration and resolves it; nothing consumes
  `declared/1`'s output until Plan A2 Task 2 merges it into the effective
  mount set.

  Shape parity with Plan A's embedded mounts: `declared/1` returns
  `Valea.Mounts.mount()` structs with `rel_root: nil` (the one field that
  distinguishes "outside the workspace" from `mounts/<name>` — an external
  mount has no workspace-relative path) and `root` set to the
  REALPATH-resolved absolute folder, mirroring `Valea.Mounts.list/1`'s
  degradation vocabulary (`degraded: <human-readable reason> | nil`) so
  every existing consumer of the shared `mount()` shape keeps working
  unmodified.

  ## Why REALPATH, here, now

  An external mount's `root` becomes an agent read root later (byte-for-byte
  the security boundary `Valea.Paths.resolve_real/2` enforces at containment
  time) — so the resolved value this module produces IS the security-
  relevant value. It is resolved the SAME way: symlinks walked fully
  (`Valea.Paths.resolve_real/2`, reused here via the `resolve_real(p, p)`
  self-base trick — since an external ref is not naturally contained in any
  existing base, resolving it against itself makes containment trivially
  satisfied and yields the fully-symlink-walked physical path), `~` expanded
  first via `Path.expand/1`.

  ## Guardrails (`validate_ref/2`)

  Used by the future `declare_mount` RPC BEFORE a ref is written to config —
  it rejects a candidate outright rather than degrading it, unlike
  `declared/1` (which must never drop an already-written entry: a workspace
  moved, a drive unmounted, and so on are transient and should recover, not
  vanish). Comparisons are REALPATH-resolved on BOTH sides (the ref and the
  workspace root) with segment-boundary prefix logic — `/a/b` must not
  match a lexical-prefix check against `/a/bc`.

  `:home_or_root` is checked before the workspace-relationship guardrails:
  `$HOME` is very often itself an ancestor of the workspace (a workspace
  commonly lives under the user's home directory), so checking
  `:ancestor_of_workspace` first would mask the more specific, more useful
  `:home_or_root` reason for the single most likely fat-finger (declaring
  your entire home directory, or `/`, as a mount).
  """

  alias Valea.Mounts
  alias Valea.Mounts.Manifest
  alias Valea.Paths

  @doc """
  Declared EXTERNAL mounts (`kind: "path"` entries) in `workspace`'s
  `config/workspace.yaml`, resolved to `Valea.Mounts.mount()` structs —
  `rel_root: nil`, `root` the realpath-resolved absolute folder, sorted by
  name. A declared ref that no longer resolves to a folder is DEGRADED with
  `:not_found` (not dropped: the config entry — and thus the chance to
  recover once the folder reappears — is preserved). A resolvable folder
  missing `icm.yaml` (or carrying an invalid one) degrades the same way
  `Valea.Mounts.list/1` degrades an embedded mount, for vocabulary parity.
  """
  @spec declared(workspace :: String.t()) :: [Valea.Mounts.mount()]
  def declared(workspace) when is_binary(workspace) do
    workspace
    |> Mounts.read_config_mounts()
    |> Enum.filter(fn {_name, entry} -> path_kind?(entry) end)
    |> Enum.map(fn {name, entry} -> build_external_mount(name, entry) end)
    |> Enum.sort_by(& &1.name)
  end

  @doc """
  Validates a candidate external ref for declaration — expands `~`,
  resolves symlinks realpath-style, and rejects it (without touching
  config) if it fails any guardrail or has no loadable manifest.

  Reasons: `:inside_workspace` (the resolved ref is under, or IS, the
  workspace root), `:ancestor_of_workspace` (the workspace root is under
  the ref — mounting an ancestor would recursively include the workspace
  itself), `:home_or_root` (ref resolves to `$HOME` or `/`), `:not_found`
  (no folder there — including a ref that resolves to a FILE, not a
  folder: the spec only ever speaks of folders), `:no_manifest` (a folder
  with no `icm.yaml`), `{:invalid_manifest, reason}` (a folder whose
  `icm.yaml` fails `Valea.Mounts.Manifest.load/1`).
  """
  @spec validate_ref(workspace :: String.t(), ref :: String.t()) ::
          {:ok, resolved_abs :: String.t()}
          | {:error, reason :: atom() | {:invalid_manifest, String.t()}}
  def validate_ref(workspace, ref) when is_binary(workspace) and is_binary(ref) do
    resolved = resolve_best_effort(ref)
    ws_resolved = resolve_best_effort(workspace)

    cond do
      home_or_root?(resolved) -> {:error, :home_or_root}
      under?(resolved, ws_resolved) -> {:error, :inside_workspace}
      under?(ws_resolved, resolved) -> {:error, :ancestor_of_workspace}
      not File.dir?(resolved) -> {:error, :not_found}
      true -> validate_manifest(resolved)
    end
  end

  defp validate_manifest(resolved) do
    case Manifest.load(resolved) do
      {:ok, _manifest} -> {:ok, resolved}
      {:error, :missing} -> {:error, :no_manifest}
      {:error, {:invalid, reason}} -> {:error, {:invalid_manifest, reason}}
    end
  end

  # -- resolution ----------------------------------------------------------

  # Fully resolve `path` (`~`-expanded, symlinks walked) with a safe
  # fallback to the lexically-expanded path on the (pathological — a
  # symlink cycle exceeding the 32-hop budget) resolution failure, so this
  # always returns a usable absolute string rather than an error tuple.
  defp resolve_best_effort(path) do
    expanded = Path.expand(path)

    case Paths.resolve_real(expanded, expanded) do
      {:ok, resolved} -> resolved
      {:error, _reason} -> expanded
    end
  end

  defp home_or_root?(resolved), do: resolved == "/" or resolved == home_real()

  defp home_real, do: resolve_best_effort(System.user_home!())

  # Segment-boundary "is `descendant` under (or equal to) `ancestor`?" — a
  # trailing-slash join, not a lexical string prefix, so `/a/b` never
  # matches an `/a/bc` ancestor. `/` is always an ancestor of everything.
  defp under?(_descendant, "/"), do: true

  defp under?(descendant, ancestor) do
    descendant == ancestor or String.starts_with?(descendant <> "/", ancestor <> "/")
  end

  # -- declared mount building ----------------------------------------------

  defp path_kind?(entry) when is_map(entry), do: Map.get(entry, "kind") == "path"
  defp path_kind?(_not_a_map), do: false

  defp build_external_mount(name, entry) do
    enabled = config_enabled?(entry)

    case Map.get(entry, "ref") do
      ref when is_binary(ref) -> build_from_ref(name, ref, enabled)
      _missing_or_invalid -> degraded_mount(name, "", enabled, "ref is missing or invalid")
    end
  end

  defp build_from_ref(name, ref, enabled) do
    resolved = resolve_best_effort(ref)

    if File.dir?(resolved) do
      mount_from_manifest(name, resolved, enabled)
    else
      # `ref` (the raw, un-resolved config value) is shown in the message —
      # `~`-form or whatever the user/RPC wrote — for readability; the
      # struct's `root` still carries the resolved (possibly nonexistent)
      # path, so it recovers automatically once the folder reappears there.
      degraded_mount(name, resolved, enabled, "folder not found at #{ref}")
    end
  end

  defp mount_from_manifest(name, resolved, enabled) do
    case Manifest.load(resolved) do
      {:ok, manifest} ->
        %{
          name: name,
          rel_root: nil,
          root: resolved,
          manifest: manifest,
          enabled: enabled,
          degraded: nil
        }

      {:error, :missing} ->
        degraded_mount(name, resolved, enabled, "icm.yaml is missing")

      {:error, {:invalid, reason}} ->
        degraded_mount(name, resolved, enabled, reason)
    end
  end

  defp degraded_mount(name, root, enabled, reason) do
    %{
      name: name,
      rel_root: nil,
      root: root,
      manifest: nil,
      enabled: enabled,
      degraded: reason
    }
  end

  defp config_enabled?(entry) do
    case entry do
      %{"enabled" => false} -> false
      _other -> true
    end
  end
end
