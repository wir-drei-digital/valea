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

  ## Audit — every mount is a boundary change

  Since every mounted ICM is by-reference, declaring, undeclaring,
  enabling, or disabling one changes what filesystem locations OUTSIDE the
  workspace an agent session can read. `declare_external/3` audits
  `mount_declared`, `undeclare/2` audits `mount_undeclared`, and
  `set_enabled/2` audits `mount_enabled`/`mount_disabled`. Every audit
  entry carries the mount's best-effort RESOLVED absolute path (`nil` only
  when the ref was never absolute/`~`-based at all) alongside the mount
  `name`, so the audit trail names the real location being granted or
  revoked, not just the config key.
  """

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

  @doc """
  Sets `mounts.<name>.enabled` in the current workspace's
  `config/workspace.yaml`, writing atomically. Preserves `version`, `id`,
  and every other key on every mount entry (including this one) — so
  hand-added or by-reference-mount fields like `kind`/`ref` survive.

  Rejects a `name` containing `/`, `..`, or a C0 control character/DEL
  (defense in depth: a mount name is a safe directory basename).

  Audits `mount_enabled`/`mount_disabled` with `name` and the mount's
  best-effort resolved path — but ONLY when `name` names an EXTERNAL
  (`kind: "path"`) entry; toggling an embedded mount stays unaudited (see
  moduledoc, "Audit — external mounts are boundary changes").
  """
  @spec set_enabled(name :: String.t(), boolean()) :: :ok | {:error, term()}
  def set_enabled(name, enabled) when is_binary(name) and is_boolean(enabled) do
    with :ok <- validate_mount_name(name),
         {:ok, ws} <- workspace_root(),
         {:ok, doc} <- read_workspace_config_for_write(ws) do
      mounts = doc |> Map.get("mounts") |> normalize_mounts()

      case write_workspace_config(ws, render_config(doc, name, enabled)) do
        :ok ->
          audit_toggle(ws, mounts, name, enabled)
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Declares a BY-REFERENCE (external) mount named `name` under `workspace`,
  validating `ref` via `Valea.Mounts.External.validate_ref/2` FIRST — a
  candidate that fails any guardrail or has no loadable manifest is
  rejected outright with the SAME error reason `validate_ref/2` returns,
  with NO config write at all.

  On success, writes `mounts.<name>: {kind: "path", ref: <ref>, enabled:
  true}` to `config/workspace.yaml`, preserving `version`, `id`, and every
  OTHER mount entry untouched — same atomic-write,
  preserve-everything-else contract as `set_enabled/2`. `ref` is written
  EXACTLY as given (a `~`-form ref stays `~`-form in the config) — the
  resolved absolute path this function returns (and audits) is derived
  fresh, never stored; keeping the config value in the user's own portable
  form is the whole point of a by-reference mount surviving a move to
  another machine where `~` resolves differently.

  Re-declaring an already-declared name overwrites that ONE entry with the
  new `kind`/`ref`/`enabled: true` (every other entry is still preserved)
  — there is no separate "update" operation.

  Rejects `name` the same way `set_enabled/2` does (a mount name is a
  config key / safe directory basename).

  Audits `mount_declared` with `name` and the resolved absolute path (see
  moduledoc).
  """
  @spec declare_external(workspace :: String.t(), name :: String.t(), ref :: String.t()) ::
          {:ok, resolved :: String.t()} | {:error, term()}
  def declare_external(workspace, name, ref)
      when is_binary(workspace) and is_binary(name) and is_binary(ref) do
    with :ok <- validate_mount_name(name),
         {:ok, resolved} <- External.validate_ref(workspace, ref),
         {:ok, doc} <- read_workspace_config_for_write(workspace) do
      case write_workspace_config(workspace, render_declare(doc, name, ref)) do
        :ok ->
          audit("mount_declared", %{"name" => name, "path" => resolved})
          {:ok, resolved}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Removes the EXTERNAL (`kind: "path"`) config entry named `name` from
  `workspace`'s `config/workspace.yaml` — config-only, NEVER touches any
  folder (neither the external target nor, obviously, any `mounts/<name>`
  directory — an embedded mount has no config entry to remove in the first
  place). Preserves `version`, `id`, and every other mount entry
  untouched.

  Rejects with `:mount_not_declared` when `name` has no config entry at
  all, OR when it has one that isn't `kind: "path"` (an embedded-only
  relational entry, e.g. a bare `{enabled: false}`, or a declared entry of
  some other `kind` altogether) — there is nothing external here to
  undeclare.

  Audits `mount_undeclared` with `name` and the mount's best-effort
  resolved path, captured BEFORE the entry is removed (see moduledoc);
  `nil` only when the ref was never absolute/`~`-based to begin with.
  """
  @spec undeclare(workspace :: String.t(), name :: String.t()) ::
          {:ok, resolved_path :: String.t() | nil} | {:error, term()}
  def undeclare(workspace, name) when is_binary(workspace) and is_binary(name) do
    with :ok <- validate_mount_name(name),
         {:ok, doc} <- read_workspace_config_for_write(workspace) do
      mounts = doc |> Map.get("mounts") |> normalize_mounts()

      case Map.get(mounts, name) do
        %{"kind" => "path"} ->
          path = external_root_for_audit(workspace, name)

          case write_workspace_config(workspace, render_undeclare(doc, name)) do
            :ok ->
              audit("mount_undeclared", %{"name" => name, "path" => path})
              {:ok, path}

            {:error, reason} ->
              {:error, reason}
          end

        _not_external ->
          {:error, :mount_not_declared}
      end
    end
  end

  @doc """
  Scaffolds a brand-new, empty mount under `workspace` — `mounts/<slug>`,
  where `<slug>` is `Scaffold.slugify/1` of `name` (the same slugging a
  fresh workspace scaffold gives its starter mount). `name` here is a
  DISPLAY name, not a directory basename — "Sales/Marketing" or
  "Ops (EU/APAC)" are legitimate business names — so it gets the narrower
  `validate_display_name/1` (non-blank, no C0 control chars/DEL), NOT
  `set_enabled/2`'s strict basename validator: the raw name only ever
  flows into `Scaffold.slugify/1` (which strips everything outside
  `[a-z0-9-]` before any filesystem use), `Manifest.render/1` (which
  `Valea.Yaml.escape/1`s it), and this module's own AGENTS.md skeleton
  heading — a single line, which is exactly why control chars stay
  rejected. It becomes the minted manifest's `name:` (the GIVEN name, not
  the slug).

  Mints a fresh manifest (uuid4 `id`, `name`, `description`) via
  `Manifest.write!/2`, and a minimal self-describing `AGENTS.md` +
  `CLAUDE.md` (`@AGENTS.md`) skeleton — the mount's ICM is empty at
  creation; the skeleton says so and invites it to grow. A directory
  collision (the slug already exists) is rejected outright
  (`{:error, :already_exists}`) rather than disambiguated, mirroring
  `Valea.ICM.create_page/2`'s stance on name collisions.

  Does NOT touch `config/workspace.yaml` (a freshly created mount is
  enabled by default — `config_enabled?/2`'s absent-means-true default
  already covers it) or regenerate `MOUNTS.md` — callers that need it
  refreshed (the `create_mount` RPC action) call
  `Valea.Mounts.MountsMd.regenerate/1` themselves, same as `set_enabled/2`'s
  callers already do.
  """
  @spec create(workspace :: String.t(), name :: String.t(), description :: String.t()) ::
          {:ok, mount} | {:error, term()}
  def create(workspace, name, description)
      when is_binary(workspace) and is_binary(name) and is_binary(description) do
    with :ok <- validate_display_name(name) do
      slug = Scaffold.slugify(name)
      dir = Path.join([workspace, "mounts", slug])

      if File.exists?(dir) do
        {:error, :already_exists}
      else
        do_create(dir, name, description, workspace)
      end
    end
  end

  # Display-name validator for `create/3` — deliberately NARROWER than
  # `validate_mount_name/1` (the directory-basename validator `set_enabled/2`
  # keeps): a display name may legitimately contain `/` or `..`
  # ("Sales/Marketing"), since `Scaffold.slugify/1` strips everything outside
  # [a-z0-9-] before the name ever touches the filesystem and
  # `Manifest.render/1` Yaml.escape's it. Control chars/DEL stay rejected
  # (the raw name lands single-line in the AGENTS.md skeleton heading), and
  # a blank (all-whitespace) name is rejected too — it would slugify to the
  # "mount" fallback and mint a manifest that `Manifest.load/1` immediately
  # degrades ("name must not be blank").
  defp validate_display_name(name) do
    if String.trim(name) == "" or control_chars?(name) do
      {:error, :invalid_mount_name}
    else
      :ok
    end
  end

  defp do_create(dir, name, description, workspace) do
    File.mkdir_p!(dir)

    Manifest.write!(dir, %{id: Ecto.UUID.generate(), name: name, description: description})
    File.write!(Path.join(dir, "AGENTS.md"), agents_md_skeleton(name, description))
    File.write!(Path.join(dir, "CLAUDE.md"), "@AGENTS.md\n")

    {:ok, build_mount(dir, read_config_mounts(workspace))}
  end

  defp agents_md_skeleton(name, description) do
    body = if String.trim(description) == "", do: "No description yet.", else: description

    """
    # This mount: #{name}

    #{body}

    This mount is new and empty — it has no pages yet. As Clients, Offers,
    Workflows, or other pages are added here, describe them in this file
    the way another mount's own AGENTS.md does, so an agent reading this
    file knows what it can rely on.
    """
  end

  # -- discovery ---------------------------------------------------------

  defp build_mount(dir, config_mounts) do
    name = Path.basename(dir)

    if control_chars?(name) do
      degraded_basename_mount(dir, name, config_mounts)
    else
      {manifest, degraded} = load_manifest(dir)

      %{
        name: name,
        rel_root: Path.join("mounts", name),
        root: Path.expand(dir),
        manifest: manifest,
        enabled: config_enabled?(config_mounts, name),
        degraded: degraded
      }
    end
  end

  # A directory basename carrying a C0 control char or DEL (e.g. a newline)
  # is quarantined unconditionally — degraded regardless of whether its
  # icm.yaml is otherwise valid, so it can never reach `effective?/1` (never
  # enabled) or `MountsMd`'s enabled/deactivated render paths, which both
  # interpolate `rel_root` RAW into a live `@`-import line. `rel_root` here
  # is built from a SANITIZED display name (control-char runs collapsed to a
  # single space, mirroring `MountsMd`'s own `sanitize/1`) rather than the
  # raw basename: `rel_root` is the one field a degraded mount still renders
  # into MOUNTS.md (the "Needs attention" line), so this is the layer where
  # that value must already be safe — the renderer cannot fix it without
  # corrupting the real `@`-import path for legitimately-named mounts. `name`
  # stays the raw basename (round-trips identification; MountsMd's own
  # `sanitize/1` already neutralizes it at that render site), and `root`
  # stays the real, unsanitized absolute path — filesystem calls, unlike
  # text rendered into a routing file, don't care about control chars.
  defp degraded_basename_mount(dir, name, config_mounts) do
    %{
      name: name,
      rel_root: Path.join("mounts", sanitize_display(name)),
      root: Path.expand(dir),
      manifest: nil,
      enabled: config_enabled?(config_mounts, name),
      degraded: "invalid mount directory name"
    }
  end

  defp control_chars?(name), do: Regex.match?(~r/[\x00-\x1F\x7F]/, name)

  defp sanitize_display(name), do: String.replace(name, ~r/[\x00-\x1F\x7F]+/, " ")

  defp load_manifest(dir) do
    case Manifest.load(dir) do
      {:ok, manifest} -> {manifest, nil}
      {:error, :missing} -> {nil, "icm.yaml is missing"}
      {:error, {:invalid, reason}} -> {nil, reason}
    end
  end

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
  # LEGACY `mounts:` section (still used by the not-yet-retargeted
  # `declare_external/3`/`undeclare/2`/`create/3` below) — kept as a
  # SEPARATE reader rather than repointing that shared function, so this
  # rewrite does not disturb `Valea.Mounts.External`'s own `mounts:`-based
  # read path (`External.declared/1` and its test suite).
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

  # -- relationship-state config (config/workspace.yaml `mounts:`) -------

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
  # would make `set_enabled/2` atomically overwrite a real (if currently
  # unreadable) config, discarding `version`/`id` and anything else in it.
  # Callers must treat this as a hard stop, not a fail-open default.
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
  # the same `mounts:` section this module's own discovery reads, keyed by
  # config name, string keys/values as parsed by YamlElixir. Not part of the
  # public contract — do not call from outside the `Valea.Mounts` namespace.
  @spec read_config_mounts(workspace :: String.t()) :: map()
  def read_config_mounts(workspace) do
    case read_workspace_config(workspace) do
      {:ok, doc} -> normalize_mounts(Map.get(doc, "mounts"))
    end
  end

  defp normalize_mounts(mounts) when is_map(mounts), do: mounts
  defp normalize_mounts(_not_a_map), do: %{}

  defp config_enabled?(config_mounts, name) do
    case config_mounts[name] do
      %{"enabled" => false} -> false
      _ -> true
    end
  end

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

  # -- audit (see moduledoc, "Audit — external mounts are boundary changes")

  # `set_enabled/2`'s audit gate — fires `mount_enabled`/`mount_disabled`
  # ONLY when `name` names an EXTERNAL (`kind: "path"`) entry in `mounts`
  # (the PRE-write config map — kind/ref never change on a plain
  # enable/disable toggle, so reading it before or after the write is
  # equivalent here). An embedded mount's toggle is a no-op for this
  # function, matching pre-A2 behavior.
  defp audit_toggle(workspace, mounts, name, enabled) do
    case Map.get(mounts, name) do
      %{"kind" => "path"} ->
        type = if enabled, do: "mount_enabled", else: "mount_disabled"
        audit(type, %{"name" => name, "path" => external_root_for_audit(workspace, name)})

      _not_external ->
        :ok
    end
  end

  # The currently-declared EXTERNAL mount named `name`'s best-effort
  # resolved `root`, or `nil` — reuses this module's own `list/1` (embedded
  # ∪ external, the SAME degrade-tolerant resolution
  # `Valea.Mounts.External` performs) rather than re-validating, so a
  # BOUNDARY-VIOLATING or currently-missing ref still yields its resolved
  # path for the audit trail (see `Valea.Mounts.External`'s moduledoc:
  # `root` survives even a degraded mount). Only a ref that was never
  # absolute/`~`-based at all resolves to the empty-string sentinel, which
  # becomes `nil` here. Must be called BEFORE any config write that would
  # remove the entry (`undeclare/2`) — `list/1` only sees what's still on
  # disk.
  defp external_root_for_audit(workspace, name) do
    workspace
    |> list()
    |> Enum.find(&(&1.name == name and &1.rel_root == nil))
    |> case do
      nil -> nil
      %{root: ""} -> nil
      %{root: root} -> root
    end
  end

  defp audit(type, fields) do
    if Process.whereis(Valea.Audit), do: Valea.Audit.append(type, fields)
    :ok
  end

  # -- rendering: preserves version/id + every key on every mount entry --

  defp render_config(doc, name, enabled) do
    mounts =
      doc
      |> Map.get("mounts")
      |> normalize_mounts()
      |> put_enabled(name, enabled)

    render_doc(doc, mounts)
  end

  # `declare_external/3`'s writer — replaces (never merges) the ONE entry
  # named `name` with its full new declared shape, preserving every OTHER
  # entry untouched. `ref` is stored EXACTLY as given (see
  # `declare_external/3`'s @doc for why raw/`~`-form survives).
  defp render_declare(doc, name, ref) do
    mounts =
      doc
      |> Map.get("mounts")
      |> normalize_mounts()
      |> Map.put(name, %{"kind" => "path", "ref" => ref, "enabled" => true})

    render_doc(doc, mounts)
  end

  # `undeclare/2`'s writer — drops the entry named `name` entirely,
  # preserving every other entry untouched.
  defp render_undeclare(doc, name) do
    mounts = doc |> Map.get("mounts") |> normalize_mounts() |> Map.delete(name)
    render_doc(doc, mounts)
  end

  defp render_doc(doc, mounts) do
    header = [top_level_line(doc, "version"), top_level_line(doc, "id")] |> Enum.reject(&is_nil/1)
    lines = header ++ render_mounts_section(mounts)
    Enum.join(lines, "\n") <> "\n"
  end

  defp put_enabled(mounts, name, enabled) do
    entry =
      case Map.get(mounts, name) do
        m when is_map(m) -> m
        _absent_or_invalid -> %{}
      end

    Map.put(mounts, name, Map.put(entry, "enabled", enabled))
  end

  defp top_level_line(doc, key) do
    case Map.fetch(doc, key) do
      {:ok, value} -> "#{key}: #{render_scalar(value)}"
      :error -> nil
    end
  end

  defp render_mounts_section(mounts) when map_size(mounts) == 0, do: ["mounts: {}"]

  defp render_mounts_section(mounts) do
    entries =
      mounts
      |> Enum.sort_by(fn {name, _entry} -> name end)
      |> Enum.flat_map(fn {name, entry} ->
        ["  #{yaml_key(name)}:" | render_entry_lines(entry)]
      end)

    ["mounts:" | entries]
  end

  defp render_entry_lines(entry) when map_size(entry) == 0, do: ["    {}"]

  defp render_entry_lines(entry) do
    entry
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, value} -> "    #{yaml_key(key)}: #{render_scalar(value)}" end)
  end

  defp yaml_key(key) when is_binary(key), do: Yaml.escape(key)
  defp yaml_key(key), do: Yaml.escape(to_string(key))

  defp render_scalar(value) when is_binary(value), do: Yaml.escape(value)
  defp render_scalar(value) when is_boolean(value), do: to_string(value)
  defp render_scalar(value) when is_integer(value), do: Integer.to_string(value)
  defp render_scalar(value) when is_float(value), do: to_string(value)
  defp render_scalar(nil), do: "null"
  defp render_scalar(value), do: Yaml.escape(inspect(value))
end
