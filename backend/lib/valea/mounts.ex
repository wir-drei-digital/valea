defmodule Valea.Mounts do
  @moduledoc """
  CONFIG TRUTH: the set of mounted ICMs in a workspace is exactly the
  `icms:` map in `config/workspace.yaml` — nothing is discovered by
  scanning the filesystem. Every mounted ICM is BY-REFERENCE (external):
  it lives OUTSIDE the workspace, at the `path:` an `icms:` entry names.
  There is no more embedded `mounts/<name>/` directory concept; `list/1`
  builds exactly one `mount()` per `icms:` entry.

  ## Compatibility shim

  The `mount()` map keeps its historical field set (`name`, `rel_root`,
  `root`, `manifest`, `enabled`, `degraded`), but `rel_root` is now ALWAYS
  `nil` — every mount is external. `name` is the workspace-local **mount
  key** (the `icms:` mapping key); `manifest.name` is the ICM's own
  display name. Every existing consumer that already branches on
  `rel_root` (`Valea.ICM`, `References`, `Search`, `ClaudeSettings`,
  `Workflows`, ...) transparently takes its external branch — the dead
  embedded branches are removed in a later phase, not here.

  ## Resolution and degradation

  For each `icms:` entry, `list/1` expands `~`, resolves symlinks
  (`Valea.Paths.resolve_real/2`, self-base trick — mirrors
  `Valea.Mounts.External`), boundary-validates the resolved path
  (`Valea.Mounts.External.check_boundaries/2`: not inside the workspace,
  not the home directory or filesystem root, not an ancestor of the
  workspace), checks it is free of Claude Code permission-glob
  metacharacters (`* ? [ ] { } ( )` — the resolved root is spliced into a
  `Read(<root>/**)` allow entry later), confirms a folder exists there,
  and loads its `icm.yaml` (`Valea.Mounts.Manifest.load/1`, format 2 —
  requires a validated UUID `id`). Any failure at any step DEGRADES the
  entry (`degraded: <reason>`) rather than dropping it — it stays listed
  (for the UI to show something is wrong and the user to repair or remove
  it) but is always excluded from `enabled/0,1` regardless of its config
  `enabled` flag.

  After every entry resolves, two post-passes catch cross-entry collisions
  a single-entry check cannot see: `degrade_duplicate_roots/1` degrades
  EVERY entry whose resolved root is shared by another entry (a physical
  ICM folder mounted twice under different keys), and
  `degrade_duplicate_ids/1` degrades every currently-healthy entry whose
  manifest `id` is shared by another currently-healthy entry (the same
  portable ICM — or an ambiguous clone of it — mounted twice). `list/1` is
  sorted by mount key (the `icms:` map key, `name` on the struct).

  ## Mutations

  `mount/2` registers an already-existing, already-healthy external ICM
  folder; `create/3` mints a brand-new one (seeding the portable
  `priv/icm_template/` tree) and then mounts it — the only mutation that
  writes into an ICM's own folder. `set_enabled/3` flips a mount's
  `enabled` flag; `unmount/2` removes its config entry (the folder is
  never touched). All four operate purely on `config/workspace.yaml`'s
  `icms:` map, preserving every other top-level key (`version`, `id`,
  `name`, and any unknown key — including a legacy `mounts:` section, if
  one is still present) byte-for-byte via a generic recursive YAML
  encoder (`render_icms_doc/2`). A mount's `path` is stored EXACTLY as
  given to `mount/2`/`create/3` (the user's own `~`-form survives) — the
  resolved absolute path this module computes is never persisted, only
  audited.

  ## Audit — every mount is a boundary change

  Since every mounted ICM is by-reference, mounting, unmounting, enabling,
  or disabling one changes what filesystem locations OUTSIDE the workspace
  an agent session can read. `mount/2` and `create/3` audit `icm_mounted`,
  `unmount/2` audits `icm_unmounted`, and `set_enabled/3` audits
  `icm_enabled`/`icm_disabled`. Every audit entry carries the mount's
  best-effort RESOLVED absolute path (`nil` only when the config `path`
  was never absolute/`~`-based at all) alongside the `mount_key`, so the
  audit trail names the real location being granted or revoked, not just
  the config key.
  """

  alias Valea.Mounts.Context
  alias Valea.Mounts.External
  alias Valea.Mounts.Manifest
  alias Valea.Paths
  alias Valea.Workspace.Manager
  alias Valea.Workspace.Scaffold
  alias Valea.Yaml

  # A resolved mount. `root` is the ABSOLUTE path; `rel_root` is
  # workspace-relative ("mounts/<name>") for embedded mounts and `nil` for
  # external (by-reference) mounts produced by `Valea.Mounts.External` — an
  # ICM outside the workspace has no workspace-relative path. `enabled` from
  # config. `degraded` carries a reason string when the manifest is
  # missing/broken (still listed for the UI, excluded from the effective
  # set).
  @type mount :: %{
          name: String.t(),
          rel_root: String.t() | nil,
          root: String.t(),
          manifest: %Valea.Mounts.Manifest{} | nil,
          enabled: boolean(),
          degraded: String.t() | nil
        }

  @doc """
  Every mount declared in the current workspace's `icms:` config (enabled +
  disabled + degraded) — sorted by mount key. See the moduledoc for
  resolution/degradation and the duplicate-root/duplicate-id rules.
  """
  @spec list() :: {:ok, [mount]} | {:error, :no_workspace}
  def list do
    with {:ok, ws} <- workspace_root() do
      {:ok, list(ws)}
    end
  end

  @doc """
  Pure form of `list/0` — one `mount()` per `icms:` entry in `workspace`'s
  `config/workspace.yaml`, resolved and degradation-checked (see
  moduledoc), sorted by mount key.
  """
  @spec list(workspace :: String.t()) :: [mount]
  def list(workspace) when is_binary(workspace) do
    ws_resolved = resolve_best_effort(workspace)

    workspace
    |> read_icms_config()
    |> Enum.map(fn {name, entry} -> build_icm_mount(name, entry, ws_resolved) end)
    |> degrade_duplicate_roots()
    |> degrade_duplicate_ids()
    |> Enum.sort_by(& &1.name)
  end

  @doc "Only enabled, non-degraded mounts in the current workspace — the effective composition set."
  @spec enabled() :: {:ok, [mount]} | {:error, :no_workspace}
  def enabled do
    with {:ok, ws} <- workspace_root() do
      {:ok, enabled(ws)}
    end
  end

  @doc "Pure form of `enabled/0` for `workspace`."
  @spec enabled(workspace :: String.t()) :: [mount]
  def enabled(workspace) when is_binary(workspace) do
    workspace |> list() |> Enum.filter(&effective?/1)
  end

  @doc """
  Resolves an ABSOLUTE path to the mount that owns it, in the current
  workspace. See `mount_for/2` for the full contract.

  Attribution only — it does not validate or contain the path. Callers
  that go on to do filesystem I/O with `path` must independently expand
  it and prefix-check it against the resolved mount's `root` (mirroring
  `Valea.ICM.contain/2`); this function only identifies which mount a path
  *names*, it does not authorize access to it.
  """
  @spec mount_for(path :: String.t()) :: {:ok, mount} | {:error, :not_in_mount | :no_workspace}
  def mount_for(path) when is_binary(path) do
    with {:ok, ws} <- workspace_root() do
      case mount_for(ws, path) do
        nil -> {:error, :not_in_mount}
        mount -> {:ok, mount}
      end
    end
  end

  @doc """
  Pure form of `mount_for/1` for `workspace` — the owning mount, or `nil`.

  Every mount is external (`rel_root: nil` always, see moduledoc), so
  attribution is by ABSOLUTE-root prefix alone: `path` attributes to
  whichever mount's `root` it falls under, segment-boundary (`/a/b` does
  not match a `/a/bc` root) — but ONLY among ENABLED, non-degraded mounts.
  A degraded mount's `root` may carry a resolved path a hand-edited config
  pointed at `$HOME`, `/`, or an ancestor of the workspace (preserved on
  the struct for recovery, never for trust); matching attribution against
  it would let a dangerous path masquerade as a legitimate mount, so it is
  excluded by construction. With NESTED mount roots (one mount's folder
  inside another's), the most-specific (longest) matching root wins. This
  function assumes the caller already resolved `path` to its real,
  physical form (mirrors how `root` itself is realpath-resolved) — it only
  compares, it does not resolve.

  Does not validate or contain the path — attribution only. Callers that
  go on to do filesystem I/O with the path must independently expand it
  and prefix-check it against the resolved mount's `root` (mirroring
  `Valea.ICM.contain/2`); this function only identifies which mount a path
  *names*, it does not authorize access to it.
  """
  @spec mount_for(workspace :: String.t(), path :: String.t()) :: mount | nil
  def mount_for(workspace, path) when is_binary(workspace) and is_binary(path) do
    workspace
    |> list()
    |> Enum.filter(&(effective?(&1) and path_under_root?(path, &1.root)))
    |> most_specific_root()
  end

  @doc """
  Direct lookup by the workspace-local mount key (the `icms:` mapping
  key) — the mount named `mount_key` regardless of its `enabled`/`degraded`
  state, or `nil` if no `icms:` entry has that key.
  """
  @spec mount_by_key(workspace :: String.t(), mount_key :: String.t()) :: mount | nil
  def mount_by_key(workspace, mount_key) when is_binary(workspace) and is_binary(mount_key) do
    workspace |> list() |> Enum.find(&(&1.name == mount_key))
  end

  @doc """
  Lookup by stable ICM id (`icm.yaml`'s `id:`) among HEALTHY mounts
  (`degraded == nil` — a degraded entry has no trustworthy `manifest` to
  match against) — `nil` if no healthy mount carries that id. Duplicate ids
  never reach here healthy: `degrade_duplicate_ids/1` degrades every
  mount sharing an id before `list/1` returns.
  """
  @spec mount_by_id(workspace :: String.t(), icm_id :: String.t()) :: mount | nil
  def mount_by_id(workspace, icm_id) when is_binary(workspace) and is_binary(icm_id) do
    workspace
    |> list()
    |> Enum.find(&(&1.degraded == nil and &1.manifest != nil and &1.manifest.id == icm_id))
  end

  @doc """
  The editor-time cross-ICM scan scope (search, backlinks, rename
  link-rewrite — spec decision (b), Task 5.6): `mount_key`'s own mount plus
  the mount of every ICM it DIRECTLY declares related via its own
  `CONTEXT.md` (`Valea.Mounts.Context.resolve/2`). A declared related entry
  that doesn't resolve (not mounted, disabled, degraded, duplicate id, or
  an escaping entrypoint) is silently excluded from the scope, exactly as
  `Context.resolve/2` excludes it from `related` (surfaced there instead as
  an `issue`, which this function does not carry — a caller that needs the
  issues, e.g. for a UI warning, calls `Context.resolve/2` itself). A
  malformed `CONTEXT.md` that declares the primary's OWN id back is
  excluded too — the primary is never duplicated in the returned scope.

  Returns full `mount()` structs, not bare root paths — every caller scans
  more than one ICM's worth of content and must attribute each hit/backlink
  back to the SPECIFIC ICM it lives in (that ICM's OWN `mount_key`, for
  `(mount_key, rel_path)` addressing), not just a physical directory; each
  related entry's `mount()` is synthesized from `Context.resolve/2`'s own
  resolved fields (already themselves sourced from a healthy, enabled
  mount — see that module's moduledoc) rather than re-queried.

  `[]` when `mount_key` does not name a currently ENABLED, non-degraded
  mount in `workspace` — callers that need to distinguish "unknown/disabled
  primary" from "a resolved primary with an empty declared-related list"
  resolve the primary themselves first (mirroring every other ICM RPC's own
  enabled+non-degraded gate, e.g. `Valea.ICM`'s own `resolve_mount/1`).
  """
  @spec scoped_roots(workspace :: String.t(), mount_key :: String.t()) :: [mount]
  def scoped_roots(workspace, mount_key)
      when is_binary(workspace) and is_binary(mount_key) do
    case mount_by_key(workspace, mount_key) do
      %{enabled: true, degraded: nil} = primary ->
        related =
          workspace
          |> Context.resolve(primary)
          |> Map.fetch!(:related)
          |> Enum.reject(&(&1.mount_key == primary.name))
          |> Enum.uniq_by(& &1.mount_key)
          |> Enum.map(&related_to_mount/1)

        [primary | related]

      _not_a_healthy_primary ->
        []
    end
  end

  # `Context.resolve/2`'s `resolved` shape already carries everything a
  # `mount()` needs except `rel_root`/`enabled`/`degraded` — every mount is
  # external (`rel_root: nil`, moduledoc), and `Context`'s own
  # `find_related_mount/2` already required `enabled: true` and healthy
  # (`degraded == nil`, via `mount_by_id/2`) before this entry ever reached
  # `related`.
  defp related_to_mount(%{mount_key: key, root: root, manifest: manifest}) do
    %{name: key, rel_root: nil, root: root, manifest: manifest, enabled: true, degraded: nil}
  end

  # With NESTED mount roots (one mount's folder inside another's), a path
  # in the inner mount is under BOTH -- the most-specific (longest) root
  # owns it, never whichever name happens to sort first.
  defp most_specific_root([]), do: nil
  defp most_specific_root(matches), do: Enum.max_by(matches, &byte_size(&1.root))

  # Segment-boundary "is `path` under (or equal to) `root`?" -- mirrors
  # `Valea.Mounts.External`'s own `under?/2`: a trailing-slash join, never a
  # lexical string prefix, so `/a/b` never matches an `/a/bc` root.
  defp path_under_root?(path, root) do
    root != "" and (path == root or String.starts_with?(path <> "/", root <> "/"))
  end

  # -- mutations: mount / create / set_enabled / unmount (icms:-only) ------

  @doc """
  Mounts a healthy, format-2 external ICM found at `path` into
  `workspace`'s `icms:` config — validates the folder (boundary,
  permission-glob safety, existence, a loadable format-2 `icm.yaml`),
  rejects it if its resolved physical root OR its manifest `id` is already
  mounted in this workspace (`:duplicate_root` / `:duplicate_id`), derives
  a unique mount key from the manifest's `name` (`unique_mount_key/2`),
  and writes `icms.<key> = %{path: <path>, enabled: true}` — `path` is
  stored EXACTLY as given (a `~`-form path stays `~`-form), never the
  resolved absolute form. Never copies, moves, or writes anything under
  `path` — that is `create/3`'s job alone.

  Audits `icm_mounted` with the mount key, the RESOLVED path, and the
  manifest id.
  """
  @spec mount(workspace :: String.t(), path :: String.t()) ::
          {:ok, %{mount_key: String.t(), id: String.t()}} | {:error, term()}
  def mount(workspace, path) when is_binary(workspace) and is_binary(path) do
    with {:ok, resolved, manifest} <- validate_mountable(workspace, path),
         :ok <- reject_duplicate_root(workspace, resolved),
         :ok <- reject_duplicate_id(workspace, manifest.id) do
      key = unique_mount_key(workspace, manifest.name)
      icms = workspace |> read_icms_config() |> Map.put(key, %{"path" => path, "enabled" => true})

      case write_icms(workspace, icms) do
        :ok ->
          audit("icm_mounted", %{"mount_key" => key, "path" => resolved, "id" => manifest.id})
          {:ok, %{mount_key: key, id: manifest.id}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Mints a brand-new external ICM at `path`: creates the folder if it
  doesn't exist, seeds the portable `priv/icm_template/` tree into it
  (substituting `{{name}}` in `AGENTS.md`/`CONTEXT.md` with `name`), writes
  a fresh format-2 `icm.yaml` (a new UUID `id`, `name`, empty
  `description`) over the template's placeholder one, then mounts it via
  `mount/2`. The ONLY mutation that writes into an ICM's own folder.

  Rejects `path` when it already holds an `icm.yaml` (`:already_exists` —
  refuses to clobber an existing ICM) or is an existing non-directory
  (`:not_a_directory`), same boundary/glob guardrails as `mount/2`.

  Audits `icm_mounted` (via `mount/2` — see its own @doc).
  """
  @spec create(workspace :: String.t(), name :: String.t(), path :: String.t()) ::
          {:ok, %{mount_key: String.t(), id: String.t()}} | {:error, term()}
  def create(workspace, name, path)
      when is_binary(workspace) and is_binary(name) and is_binary(path) do
    with :ok <- validate_display_name(name),
         :ok <- check_create_target(workspace, path) do
      resolved = resolve_best_effort(Path.expand(path))
      File.mkdir_p!(resolved)
      seed_template!(resolved, name)
      Manifest.write!(resolved, %{id: Ecto.UUID.generate(), name: name, description: ""})
      mount(workspace, path)
    end
  end

  @doc """
  Sets `icms.<mount_key>.enabled` in `workspace`'s `config/workspace.yaml`,
  preserving every other key on every entry (including this one) and every
  other top-level key in the document. Rejects `mount_key` the same way
  `unmount/2` does (a mount key is a safe config-key / directory-basename
  string: no `/`, no `..`, no C0 control char/DEL), and rejects a
  `mount_key` with no `icms:` entry at all (`:mount_not_found`).

  Audits `icm_enabled`/`icm_disabled` with `mount_key` and the mount's
  best-effort resolved path (see moduledoc).
  """
  @spec set_enabled(workspace :: String.t(), mount_key :: String.t(), enabled :: boolean()) ::
          :ok | {:error, term()}
  def set_enabled(workspace, mount_key, enabled)
      when is_binary(workspace) and is_binary(mount_key) and is_boolean(enabled) do
    with :ok <- validate_mount_name(mount_key),
         icms = read_icms_config(workspace),
         :ok <- ensure_icm_present(icms, mount_key) do
      path = icm_root_for_audit(workspace, mount_key)
      new_icms = Map.update!(icms, mount_key, &Map.put(&1, "enabled", enabled))

      case write_icms(workspace, new_icms) do
        :ok ->
          type = if enabled, do: "icm_enabled", else: "icm_disabled"
          audit(type, %{"mount_key" => mount_key, "path" => path})
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Removes the `icms.<mount_key>` config entry from `workspace`'s
  `config/workspace.yaml` — config-only, the ICM's own folder is NEVER
  touched. Preserves every other entry and every other top-level key.

  Rejects `mount_key` the same way `set_enabled/3` does, and rejects a
  `mount_key` with no `icms:` entry at all (`:mount_not_found`).

  Audits `icm_unmounted` with `mount_key` and the mount's best-effort
  resolved path, captured BEFORE the entry is removed (see moduledoc).
  """
  @spec unmount(workspace :: String.t(), mount_key :: String.t()) ::
          {:ok, path :: String.t() | nil} | {:error, term()}
  def unmount(workspace, mount_key) when is_binary(workspace) and is_binary(mount_key) do
    with :ok <- validate_mount_name(mount_key),
         icms = read_icms_config(workspace),
         :ok <- ensure_icm_present(icms, mount_key) do
      path = icm_root_for_audit(workspace, mount_key)
      new_icms = Map.delete(icms, mount_key)

      case write_icms(workspace, new_icms) do
        :ok ->
          audit("icm_unmounted", %{"mount_key" => mount_key, "path" => path})
          {:ok, path}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Derives a workspace-unique `icms:` mount key from a display `name`:
  `Valea.Workspace.Scaffold.slugify/1` of `name`, then a `-2`, `-3`, ...
  numeric suffix if the slug already names an existing `icms:` entry in
  `workspace`'s current config.
  """
  @spec unique_mount_key(workspace :: String.t(), name :: String.t()) :: String.t()
  def unique_mount_key(workspace, name) when is_binary(workspace) and is_binary(name) do
    existing = workspace |> read_icms_config() |> Map.keys() |> MapSet.new()
    base = Scaffold.slugify(name)
    unique_key(base, existing, 1)
  end

  defp unique_key(base, existing, n) do
    candidate = if n == 1, do: base, else: "#{base}-#{n}"
    if MapSet.member?(existing, candidate), do: unique_key(base, existing, n + 1), else: candidate
  end

  # Shared `mount/2` validation: absolute/`~`-based, boundary-safe,
  # glob-safe, an existing folder with a loadable format-2 manifest.
  # Returns the RESOLVED path (for audit/duplicate-checks) and the loaded
  # manifest.
  defp validate_mountable(workspace, path) do
    if absolute_or_tilde?(path) do
      resolved = resolve_best_effort(Path.expand(path))
      ws_resolved = resolve_best_effort(workspace)

      with :ok <- External.check_boundaries(resolved, ws_resolved),
           :ok <- check_icm_glob_safety(resolved),
           :ok <- check_folder_exists(resolved) do
        case Manifest.load(resolved) do
          {:ok, manifest} -> {:ok, resolved, manifest}
          {:error, :missing} -> {:error, :no_manifest}
          {:error, {:invalid, reason}} -> {:error, {:invalid_manifest, reason}}
        end
      end
    else
      {:error, :not_absolute}
    end
  end

  defp check_folder_exists(resolved) do
    if File.dir?(resolved), do: :ok, else: {:error, :not_found}
  end

  defp reject_duplicate_root(workspace, resolved) do
    if Enum.any?(list(workspace), &(&1.root == resolved)) do
      {:error, :duplicate_root}
    else
      :ok
    end
  end

  defp reject_duplicate_id(workspace, id) do
    if Enum.any?(list(workspace), &(&1.manifest != nil and &1.manifest.id == id)) do
      {:error, :duplicate_id}
    else
      :ok
    end
  end

  # `create/3`'s own guardrails: same absolute/boundary/glob checks
  # `mount/2` runs (via `validate_mountable/2`, called again inside the
  # `mount/2` this function ultimately delegates to), plus two that only
  # matter for a WRITE target: an existing non-directory can't become an
  # ICM folder, and an existing `icm.yaml` must never be clobbered.
  defp check_create_target(workspace, path) do
    if absolute_or_tilde?(path) do
      resolved = resolve_best_effort(Path.expand(path))
      ws_resolved = resolve_best_effort(workspace)

      with :ok <- External.check_boundaries(resolved, ws_resolved),
           :ok <- check_icm_glob_safety(resolved),
           :ok <- check_not_a_file(resolved),
           :ok <- check_not_already_an_icm(resolved) do
        :ok
      end
    else
      {:error, :not_absolute}
    end
  end

  defp check_not_a_file(resolved) do
    if File.exists?(resolved) and not File.dir?(resolved) do
      {:error, :not_a_directory}
    else
      :ok
    end
  end

  defp check_not_already_an_icm(resolved) do
    if File.exists?(Path.join(resolved, "icm.yaml")) do
      {:error, :already_exists}
    else
      :ok
    end
  end

  # Display-name validator for `create/3` — deliberately NARROWER than
  # `validate_mount_name/1` (the config-key validator `set_enabled/3` and
  # `unmount/2` keep): a display name may legitimately contain `/` or `..`
  # ("Sales/Marketing"), since `Scaffold.slugify/1` strips everything
  # outside `[a-z0-9-]` before the name ever touches the filesystem and
  # `Manifest.render/1` `Yaml.escape/1`s it. Control chars/DEL stay
  # rejected (the raw name lands single-line in the seeded `AGENTS.md`'s
  # heading), and a blank (all-whitespace) name is rejected too.
  defp validate_display_name(name) do
    if String.trim(name) == "" or control_chars?(name) do
      {:error, :invalid_mount_name}
    else
      :ok
    end
  end

  # Copies `priv/icm_template/` into `dest` (already an existing, empty-or-
  # new directory) and substitutes `{{name}}` in the two template files
  # that carry it. `icm.yaml` is deliberately NOT templated here — `create/3`
  # always overwrites it with a freshly minted manifest right after this
  # call.
  defp seed_template!(dest, name) do
    File.cp_r!(icm_template_dir(), dest)

    for rel <- ["AGENTS.md", "CONTEXT.md"] do
      path = Path.join(dest, rel)

      if File.exists?(path) do
        File.write!(path, path |> File.read!() |> String.replace("{{name}}", name))
      end
    end

    :ok
  end

  defp icm_template_dir, do: Application.app_dir(:valea, "priv/icm_template")

  defp ensure_icm_present(icms, key) do
    if Map.has_key?(icms, key), do: :ok, else: {:error, :mount_not_found}
  end

  # The currently-mounted ICM named `mount_key`'s best-effort resolved
  # `root`, or `nil` — reuses `list/1` (the SAME degrade-tolerant
  # resolution every consumer sees) rather than re-validating, so a
  # boundary-violating or currently-missing path still yields its resolved
  # path for the audit trail. Only a path that was never absolute/`~`-based
  # at all resolves to the empty-string sentinel, which becomes `nil` here.
  # Must be called BEFORE any config write that would remove the entry
  # (`unmount/2`) — `list/1` only sees what's still on disk.
  defp icm_root_for_audit(workspace, mount_key) do
    case mount_by_key(workspace, mount_key) do
      nil -> nil
      %{root: ""} -> nil
      %{root: root} -> root
    end
  end

  # -- discovery ---------------------------------------------------------

  defp effective?(%{enabled: true, degraded: nil}), do: true
  defp effective?(_), do: false

  # -- icms: resolution (config truth, external-only) ---------------------

  # One `icms:` entry -> one `mount()`. `enabled` reads the entry's own
  # `enabled` key (default true when absent) regardless of what follows;
  # every failure below DEGRADES (never drops) the entry, mirroring
  # `Valea.Mounts.External`'s degrade-tolerant read path.
  defp build_icm_mount(name, entry, ws_resolved) do
    enabled = icm_enabled?(entry)

    case icm_path(entry) do
      {:ok, path} -> build_from_icm_path(name, path, enabled, ws_resolved)
      :error -> degraded_icm_mount(name, "", enabled, "path is missing or invalid")
    end
  end

  defp icm_path(entry) when is_map(entry) do
    case Map.get(entry, "path") do
      path when is_binary(path) -> {:ok, path}
      _missing_or_invalid -> :error
    end
  end

  defp icm_path(_not_a_map), do: :error

  defp icm_enabled?(entry) when is_map(entry) do
    case Map.get(entry, "enabled") do
      false -> false
      _absent_or_true -> true
    end
  end

  defp icm_enabled?(_not_a_map), do: true

  # A `path` must be absolute or `~`-based; anything else would silently
  # anchor to the process CWD via `Path.expand/1` (nondeterministic in a
  # release) — mirrors `Valea.Mounts.External`'s own `check_absolute/1`
  # (private there, so duplicated here rather than exposed just for this).
  defp build_from_icm_path(name, path, enabled, ws_resolved) do
    if absolute_or_tilde?(path) do
      resolved = resolve_best_effort(Path.expand(path))

      case External.check_boundaries(resolved, ws_resolved) do
        :ok ->
          build_resolved_icm_mount(name, path, resolved, enabled)

        {:error, boundary} ->
          degraded_icm_mount(name, resolved, enabled, boundary_reason(boundary))
      end
    else
      degraded_icm_mount(name, "", enabled, "path must be an absolute path (or start with ~)")
    end
  end

  defp absolute_or_tilde?("/" <> _rest), do: true
  defp absolute_or_tilde?("~"), do: true
  defp absolute_or_tilde?("~/" <> _rest), do: true
  defp absolute_or_tilde?(_relative), do: false

  # Claude Code's permission globs (`Read(<root>/**)`, spliced in by
  # `Valea.Agents.ClaudeSettings`) are matched by ITS OWN glob engine, not
  # the filesystem — a resolved root containing a glob metacharacter would
  # change that allow entry's match semantics. Checked on the RESOLVED path
  # (post `~`-expansion, post symlink-walk), same guard
  # `Valea.Mounts.External` runs, duplicated here for the same
  # can't-call-a-private-function reason as `absolute_or_tilde?/1` above.
  @glob_metacharacters ["*", "?", "[", "]", "{", "}", "(", ")"]

  defp check_icm_glob_safety(resolved) do
    if String.contains?(resolved, @glob_metacharacters), do: {:error, :unsafe_path}, else: :ok
  end

  defp build_resolved_icm_mount(name, path, resolved, enabled) do
    case check_icm_glob_safety(resolved) do
      :ok ->
        if File.dir?(resolved) do
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
              degraded_icm_mount(name, resolved, enabled, "icm.yaml is missing")

            {:error, {:invalid, reason}} ->
              degraded_icm_mount(name, resolved, enabled, reason)
          end
        else
          degraded_icm_mount(name, resolved, enabled, "folder not found at #{path}")
        end

      {:error, :unsafe_path} ->
        degraded_icm_mount(
          name,
          resolved,
          enabled,
          "path contains characters unsafe for permission globs: *, ?, [, ], {, }, (, )"
        )
    end
  end

  defp boundary_reason(:home_or_root),
    do: "path points at the home directory or filesystem root — not mountable"

  defp boundary_reason(:inside_workspace),
    do: "path points at or inside the workspace — not mountable"

  defp boundary_reason(:ancestor_of_workspace),
    do: "path points at an ancestor of the workspace — not mountable"

  defp degraded_icm_mount(name, root, enabled, reason) do
    %{name: name, rel_root: nil, root: root, manifest: nil, enabled: enabled, degraded: reason}
  end

  # Fully resolve `path` (`~`-expanded — the caller already `Path.expand/1`s
  # — symlinks walked) with a safe fallback to the lexically-expanded path
  # on the (pathological — a symlink cycle exceeding the resolution budget)
  # resolution failure, so this always returns a usable absolute string
  # rather than an error tuple. The `resolve_real(p, p)` self-base trick:
  # an `icms:` path is not naturally contained in any existing base, so
  # resolving it against itself makes containment trivially satisfied and
  # yields the fully-symlink-walked physical path — mirrors
  # `Valea.Mounts.External`'s identically-named private helper.
  defp resolve_best_effort(path) do
    case Paths.resolve_real(path, path) do
      {:ok, resolved} -> resolved
      {:error, _reason} -> path
    end
  end

  # Post-pass 1: any resolved, non-empty root shared by more than one
  # `icms:` entry is ambiguous (the same physical folder mounted twice
  # under different keys) -- ALL entries sharing it are degraded, healthy
  # or not (a duplicate root is disqualifying on its own, regardless of
  # what else is wrong with either entry).
  defp degrade_duplicate_roots(mounts) do
    dup_roots =
      mounts
      |> Enum.filter(&(&1.root != ""))
      |> Enum.frequencies_by(& &1.root)
      |> Enum.filter(fn {_root, count} -> count > 1 end)
      |> Enum.into(MapSet.new(), fn {root, _count} -> root end)

    Enum.map(mounts, fn m ->
      if MapSet.member?(dup_roots, m.root) do
        %{m | degraded: "duplicate root: shared with another mounted ICM in this workspace"}
      else
        m
      end
    end)
  end

  # Post-pass 2: among entries still HEALTHY after the duplicate-root pass,
  # any manifest `id` shared by more than one is an ambiguous clone -- ALL
  # entries sharing it are degraded. Only healthy entries participate (a
  # degraded entry's `manifest` is `nil`, nothing to compare).
  defp degrade_duplicate_ids(mounts) do
    {healthy, other} = Enum.split_with(mounts, &(&1.degraded == nil))

    dup_ids =
      healthy
      |> Enum.frequencies_by(& &1.manifest.id)
      |> Enum.filter(fn {_id, count} -> count > 1 end)
      |> Enum.into(MapSet.new(), fn {id, _count} -> id end)

    degraded_healthy =
      Enum.map(healthy, fn m ->
        if MapSet.member?(dup_ids, m.manifest.id) do
          %{m | degraded: "ambiguous id: shared with another mounted ICM in this workspace"}
        else
          m
        end
      end)

    degraded_healthy ++ other
  end

  # `icms:` is a workspace-local map; `read_config_mounts/1` reads the
  # LEGACY `mounts:` section (still used by `Valea.Mounts.External`'s own
  # `mounts:`-based read path, `External.declared/1`, and its test suite)
  # — kept as a SEPARATE reader rather than repointing that shared
  # function, so this rewrite does not disturb it.
  defp read_icms_config(workspace) do
    case read_workspace_config(workspace) do
      {:ok, doc} -> normalize_mounts(Map.get(doc, "icms"))
    end
  end

  defp workspace_root do
    case Manager.current() do
      {:ok, %{path: ws}} -> {:ok, ws}
      {:error, :no_workspace} -> {:error, :no_workspace}
    end
  end

  # -- relationship-state config (config/workspace.yaml `icms:`) ---------

  defp config_path(workspace), do: Path.join(workspace, "config/workspace.yaml")

  defp read_workspace_config(workspace) do
    case YamlElixir.read_from_file(config_path(workspace)) do
      {:ok, doc} when is_map(doc) -> {:ok, doc}
      {:ok, _not_a_map} -> {:ok, %{}}
      {:error, %YamlElixir.FileNotFoundError{}} -> {:ok, %{}}
      {:error, _reason} -> {:ok, %{}}
    end
  end

  # Write-path variant of `read_workspace_config/1`. A missing file is safe
  # to treat as an empty config (there is nothing on disk to lose). Any
  # other failure to read an EXISTING file — parse error, or a document
  # that didn't parse to a map — must not fall through to `%{}`: doing so
  # would make a mutation atomically overwrite a real (if currently
  # unreadable) config, discarding `version`/`id`/`name` and anything else
  # in it. Callers must treat this as a hard stop, not a fail-open default.
  defp read_workspace_config_for_write(workspace) do
    case YamlElixir.read_from_file(config_path(workspace)) do
      {:ok, doc} when is_map(doc) -> {:ok, doc}
      {:error, %YamlElixir.FileNotFoundError{}} -> {:ok, %{}}
      {:ok, not_a_map} -> {:error, {:config_unreadable, {:not_a_map, not_a_map}}}
      {:error, reason} -> {:error, {:config_unreadable, reason}}
    end
  end

  @doc false
  # Internal-public for `Valea.Mounts.External` (BY-REFERENCE mounts): reads
  # the LEGACY `mounts:` section, keyed by config name, string keys/values
  # as parsed by YamlElixir. Not part of the public contract — do not call
  # from outside the `Valea.Mounts` namespace.
  @spec read_config_mounts(workspace :: String.t()) :: map()
  def read_config_mounts(workspace) do
    case read_workspace_config(workspace) do
      {:ok, doc} -> normalize_mounts(Map.get(doc, "mounts"))
    end
  end

  defp normalize_mounts(mounts) when is_map(mounts), do: mounts
  defp normalize_mounts(_not_a_map), do: %{}

  defp control_chars?(name), do: Regex.match?(~r/[\x00-\x1F\x7F]/, name)

  defp validate_mount_name(name) do
    if name == "" or String.contains?(name, "/") or String.contains?(name, "..") or
         control_chars?(name) do
      {:error, :invalid_mount_name}
    else
      :ok
    end
  end

  defp write_workspace_config(workspace, contents) do
    path = config_path(workspace)
    tmp = path <> ".tmp"

    with :ok <- File.write(tmp, contents) do
      File.rename(tmp, path)
    end
  end

  # Read-current-doc, rewrite-icms:, write-atomically — the one place every
  # `icms:` mutation (`mount/2`, `set_enabled/3`, `unmount/2`) funnels
  # through.
  defp write_icms(workspace, icms) do
    with {:ok, doc} <- read_workspace_config_for_write(workspace) do
      write_workspace_config(workspace, render_icms_doc(doc, icms))
    end
  end

  # -- audit (see moduledoc, "Audit — every mount is a boundary change") --

  defp audit(type, fields) do
    if Process.whereis(Valea.Audit), do: Valea.Audit.append(type, fields)
    :ok
  end

  # -- rendering: generic recursive YAML doc writer, preserves every key --

  # Rewrites `doc`'s `icms:` section to `icms` (a full replacement map),
  # preserving every OTHER top-level key (`version`, `id`, `name`, and any
  # unknown key — including a legacy `mounts:` section, if a workspace
  # still carries one) via the same generic recursive encoder. `version`,
  # `id`, `name` sort first (in that order) when present, for readability;
  # every other key follows alphabetically; `icms:` always renders last.
  defp render_icms_doc(doc, icms) do
    doc = Map.put(doc, "icms", icms)
    keys = Map.keys(doc)
    priority = Enum.filter(["version", "id", "name"], &(&1 in keys))
    rest = keys |> Kernel.--(["version", "id", "name", "icms"]) |> Enum.sort()
    ordered = priority ++ rest ++ ["icms"]

    ordered
    |> Enum.flat_map(fn key -> render_yaml_entry(key, Map.fetch!(doc, key), "") end)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  # A map value nests one indent level deeper (or renders `{}` inline when
  # empty); anything else (including a list — no config shape this module
  # writes ever nests one, so it falls through to `render_scalar/1`'s own
  # `inspect/1` catch-all rather than a dedicated branch) renders as a
  # single `key: scalar` line.
  defp render_yaml_entry(key, value, indent) when is_map(value) do
    if map_size(value) == 0 do
      ["#{indent}#{yaml_key(key)}: {}"]
    else
      ["#{indent}#{yaml_key(key)}:" | render_yaml_map(value, indent <> "  ")]
    end
  end

  defp render_yaml_entry(key, value, indent) do
    ["#{indent}#{yaml_key(key)}: #{render_scalar(value)}"]
  end

  defp render_yaml_map(map, indent) do
    map
    |> Enum.sort_by(fn {k, _v} -> to_string(k) end)
    |> Enum.flat_map(fn {k, v} -> render_yaml_entry(k, v, indent) end)
  end

  # Bare (unquoted) when `key` is a simple identifier — every structural key
  # this module writes (`version`, `id`, `name`, `icms`, `path`, `enabled`,
  # and every `Scaffold.slugify/1`-derived mount key) qualifies, matching
  # the human-authored style `priv/workspace_template/config/workspace.yaml`
  # ships with. Anything else (an arbitrary preserved unknown key, or a
  # legacy hand-edited one) falls back to `Yaml.escape/1`'s quoted,
  # injection-hardened form — never unsafe, just less pretty.
  defp yaml_key(key) when is_binary(key) do
    if Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_-]*$/, key), do: key, else: Yaml.escape(key)
  end

  defp yaml_key(key), do: yaml_key(to_string(key))

  defp render_scalar(value) when is_binary(value), do: Yaml.escape(value)
  defp render_scalar(value) when is_boolean(value), do: to_string(value)
  defp render_scalar(value) when is_integer(value), do: Integer.to_string(value)
  defp render_scalar(value) when is_float(value), do: to_string(value)
  defp render_scalar(nil), do: "null"
  defp render_scalar(value), do: Yaml.escape(inspect(value))
end
