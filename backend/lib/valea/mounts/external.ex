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

  ## Guardrails — enforced on BOTH paths

  The boundary checks (`check_boundaries/2`) run in `validate_ref/2` (the
  future `declare_mount` RPC's pre-write gate, which rejects a candidate
  outright) AND in `declared/1`'s read path: a hand-edited config can put
  ANY ref on disk, and since a clean external mount's `root` becomes an
  agent read root later, the read path must degrade — never bless — a ref
  that fails containment. Unlike `validate_ref/2`, `declared/1` never
  drops an entry (a workspace moved, a drive unmounted, and so on are
  transient and should recover, not vanish): a guardrail-failing ref
  yields a DEGRADED mount, config preserved, excluded from any effective
  set by the shared `degraded != nil` convention.

  Comparisons are REALPATH-resolved on BOTH sides (the ref and the
  workspace root) with segment-boundary prefix logic — `/a/b` must not
  match a lexical-prefix check against `/a/bc`.

  `:home_or_root` is checked before the workspace-relationship guardrails:
  `$HOME` is very often itself an ancestor of the workspace (a workspace
  commonly lives under the user's home directory), so checking
  `:ancestor_of_workspace` first would mask the more specific, more useful
  `:home_or_root` reason for the single most likely fat-finger (declaring
  your entire home directory, or `/`, as a mount).

  A ref must be ABSOLUTE (`/...`) or `~`-based (`~`, `~/...`): a relative
  ref would anchor to the process CWD, which is nondeterministic in a
  release. `validate_ref/2` rejects one with `:not_absolute`; `declared/1`
  degrades it.
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

  The same boundary guardrails `validate_ref/2` enforces run here too: a
  ref that is relative, or resolves to `$HOME`/`/`, inside the workspace,
  or to an ancestor of the workspace, yields a DEGRADED mount (config
  preserved, never part of an effective set) — a hand-edited config must
  not be able to mint a clean mount that containment would later trust.
  """
  @spec declared(workspace :: String.t()) :: [Valea.Mounts.mount()]
  def declared(workspace) when is_binary(workspace) do
    ws_resolved = resolve_best_effort(workspace)

    workspace
    |> Mounts.read_config_mounts()
    |> Enum.filter(fn {_name, entry} -> path_kind?(entry) end)
    |> Enum.map(fn {name, entry} -> build_external_mount(name, entry, ws_resolved) end)
    |> Enum.sort_by(& &1.name)
  end

  @doc """
  Validates a candidate external ref for declaration — expands `~`,
  resolves symlinks realpath-style, and rejects it (without touching
  config) if it fails any guardrail or has no loadable manifest.

  Reasons: `:not_absolute` (the ref is neither absolute nor `~`-based — a
  relative ref would anchor to the process CWD, nondeterministic in a
  release), `:inside_workspace` (the resolved ref is under, or IS, the
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
    with :ok <- check_absolute(ref),
         resolved = resolve_best_effort(ref),
         :ok <- check_boundaries(resolved, resolve_best_effort(workspace)),
         :ok <- check_folder(resolved) do
      validate_manifest(resolved)
    end
  end

  @doc """
  The boundary guardrails shared by `validate_ref/2` and `declared/1`'s
  read path. BOTH arguments must already be REALPATH-resolved absolute
  paths (`~` expanded, symlinks walked) — this function only compares.

  Checked in order: `:home_or_root` (ref == resolved `$HOME` or `/`),
  `:inside_workspace` (ref under-or-equal the workspace root),
  `:ancestor_of_workspace` (workspace root under the ref). Comparisons use
  segment-boundary prefix logic, never a lexical string prefix.
  """
  @spec check_boundaries(resolved_ref :: String.t(), resolved_workspace :: String.t()) ::
          :ok | {:error, :home_or_root | :inside_workspace | :ancestor_of_workspace}
  def check_boundaries("/" <> _ = resolved_ref, "/" <> _ = resolved_workspace) do
    cond do
      home_or_root?(resolved_ref) -> {:error, :home_or_root}
      under?(resolved_ref, resolved_workspace) -> {:error, :inside_workspace}
      under?(resolved_workspace, resolved_ref) -> {:error, :ancestor_of_workspace}
      true -> :ok
    end
  end

  # A ref must be absolute or `~`-based; anything else would silently
  # anchor to the process CWD via `Path.expand/1` (nondeterministic in a
  # release). `~user` forms are rejected too — `Path.expand/1` does not do
  # per-user home lookup, so they'd fall back to a CWD-relative literal.
  defp check_absolute("/" <> _rest), do: :ok
  defp check_absolute("~"), do: :ok
  defp check_absolute("~/" <> _rest), do: :ok
  defp check_absolute(_relative), do: {:error, :not_absolute}

  defp check_folder(resolved) do
    if File.dir?(resolved), do: :ok, else: {:error, :not_found}
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

  defp build_external_mount(name, entry, ws_resolved) do
    enabled = config_enabled?(entry)

    case Map.get(entry, "ref") do
      ref when is_binary(ref) -> build_from_ref(name, ref, enabled, ws_resolved)
      _missing_or_invalid -> degraded_mount(name, "", enabled, "ref is missing or invalid")
    end
  end

  # The read-path twin of `validate_ref/2`: same absoluteness check, same
  # `check_boundaries/2` — but a failing ref DEGRADES (config preserved,
  # excluded from any effective set by `degraded != nil`) instead of being
  # rejected: the entry is already on disk, and a hand-edited config must
  # never mint a clean mount that containment would later trust as a read
  # root.
  defp build_from_ref(name, ref, enabled, ws_resolved) do
    case check_absolute(ref) do
      :ok ->
        resolved = resolve_best_effort(ref)

        case check_boundaries(resolved, ws_resolved) do
          :ok ->
            build_resolved(name, ref, resolved, enabled)

          {:error, boundary} ->
            degraded_mount(name, resolved, enabled, boundary_degrade_reason(boundary))
        end

      {:error, :not_absolute} ->
        degraded_mount(name, "", enabled, "ref must be an absolute path (or start with ~)")
    end
  end

  defp build_resolved(name, ref, resolved, enabled) do
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

  defp boundary_degrade_reason(:home_or_root),
    do: "ref points at the home directory or filesystem root — not mountable"

  defp boundary_degrade_reason(:inside_workspace),
    do: "ref points at or inside the workspace — not mountable"

  defp boundary_degrade_reason(:ancestor_of_workspace),
    do: "ref points at an ancestor of the workspace — not mountable"

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
