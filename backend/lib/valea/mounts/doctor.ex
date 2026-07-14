defmodule Valea.Mounts.Doctor do
  @moduledoc """
  The "Mounts" section of the doctor (icm-by-reference design, "Trust &
  product framing" + "Error handling"): per-mount health, same shape and
  spirit as `Valea.Agents.Doctor` / `Valea.Mail.Doctor` — a list of checks,
  each with a status and a copyable remedy — but this one runs over a
  VARIABLE number of subjects (every mount `Valea.Mounts.list/1` discovers:
  enabled + disabled + degraded) rather than a fixed pipeline, so each
  check's `"id"` is `"<check>:<mount key>"` — the mount-key qualifier keeps
  every check id disjoint across mounts when `run/1` flattens all of them
  into one list (and when a caller of `run/2` flattens several single-mount
  results together, e.g. the doctor panel fanning `icm_doctor` out across
  every mount — see `check_id/2`).

  Phase 8: config truth is EXTERNAL-ONLY (`Valea.Mounts.list/1`'s `rel_root`
  is always `nil` now) — there is no more embedded/external duality, so
  every mount runs the SAME six checks, in a single two-level gate:

    1. `path_resolves` — does the `icms:` entry's `path:` expand (`~`,
       symlinks) and resolve to a real, boundary-safe, permission-glob-safe
       folder? A degraded mount's `mount.degraded` reason is shown verbatim
       as this check's `detail` when the reason is PATH-level (see
       `path_level_failure?/1` for the exact classification of
       `Valea.Mounts`'s fixed reason vocabulary — manifest problems and
       duplicate ids are NOT path-level, they surface under
       `manifest_format2`/`unique_id` instead).
    2. `manifest_format2`, `unique_id`, `related_icms`, `secrets_hygiene`,
       `watcher_live` — only run when `path_resolves` is `"ok"` (mirroring
       `Valea.Mail.Doctor`'s `tls_ok` gating `login_ok`/`folders`/
       `move_capability`); when `path_resolves` fails, all five are
       `"unknown"` rather than probing a root that may not exist, may not
       be a folder, or may be an unsafe glob target.
       * `manifest_format2` — ok iff `Valea.Mounts.list/1` already loaded a
         valid format-2 manifest (`mount.manifest != nil` — a stable,
         validated UUID `id` and a non-blank `name`; see
         `Valea.Mounts.Manifest`'s moduledoc for why THAT validation, not a
         literal `format: 2` field, IS the format-2 contract). This field
         survives both of `Valea.Mounts.list/1`'s post-passes untouched
         (`degrade_duplicate_roots/1`/`degrade_duplicate_ids/1` only ever
         overwrite `degraded`, never clear an already-loaded `manifest`),
         so a mount degraded ONLY by a duplicate id still reports
         `manifest_format2: "ok"` — that reason belongs to `unique_id`
         alone.
       * `unique_id` — gated on `manifest_format2`; ok iff no OTHER
         ENABLED mount in the same `all_mounts` snapshot carries the same
         manifest `id`. Computed independently of
         `Valea.Mounts.degrade_duplicate_ids/1`'s own (enabled-blind)
         post-pass, deliberately narrower: a disabled twin sharing this id
         is not a LIVE conflict for an already-enabled mount, so it does
         not fail this mount's `unique_id` — but it does fail the disabled
         twin's own (a heads-up that enabling it would collide).
       * `related_icms` — every ICM this mount's OWN `CONTEXT.md` directly
         declares under `related_icms:` must resolve
         (`Valea.Mounts.Context.resolve/2`); any issue (`:not_mounted`,
         `:disabled`, `:degraded`, `:duplicate_id`, `:entrypoint_escapes`)
         fails this check with a WARN framing (Valea does not stop you
         mounting an ICM with a broken cross-reference — this only flags
         it). Gated on `path_resolves` alone (reads `CONTEXT.md` off the
         resolved root directly), NOT on `manifest_format2` — a mount can
         have a broken icm.yaml and a perfectly fine CONTEXT.md.

  `secrets_hygiene` is a WARNING-class check per the design spec ("the
  doctor warns, does not deny") — Valea's workspace deny-list does not
  reach into an external folder it doesn't own, so a `secrets/` directory
  or `.env`-like file sitting at the mount's root is worth flagging even
  though nothing here blocks agent access to it. It still reports
  `"status" => "failed"` (this codebase's status vocabulary has no distinct
  "warning" literal — see `Valea.Mail.Doctor`/`Valea.Agents.Doctor`, both
  strictly `"ok" | "failed" | "unknown"`); the WARNING framing lives entirely
  in the `detail`/`remedy` wording, same as every other non-fatal-but-worth-
  fixing check in this codebase.

  `watcher_live` asks `Valea.ICM.Watcher.watched_roots/0` (best-effort — an
  empty set, never a crash, when the watcher isn't running) whether this
  mount's resolved root is in the CURRENT watched set. A DISABLED mount is
  never in that set by design (the watcher only ever watches enabled,
  non-degraded roots), so `watcher_live` is `"unknown"` (not checked —
  nothing to fix, the mount is intentionally off) rather than `"failed"`
  for a disabled mount; only an ENABLED mount whose root the watcher
  currently is NOT covering reports `"failed"`.

  Never reads or leaks file CONTENTS — `secrets_hygiene` only lists
  directory ENTRY NAMES at the mount root (`File.ls/1`), never opens a
  file, and `related_icms` only reads `CONTEXT.md`'s own frontmatter
  (`Valea.Mounts.Context.resolve/2`), never any other file's body. Paths
  are fine to show throughout (they're user-declared, already visible in
  Settings).

  `run/1`/`run/2` never raise: every filesystem probe (`File.ls/1`,
  `File.read/1` via `Context.resolve/2`, `Watcher.watched_roots/0`) is
  either inherently non-raising or explicitly guarded, matching the "the
  doctor never crashes the caller" posture of its siblings. A degraded or
  disabled mount always gets a full report — its reason surfaces under
  whichever check owns it, plus a repair remedy — never an RPC error; only
  a `mount_key` with NO `icms:` entry at all is an error (`run/2`'s
  `:mount_not_found`), since there is nothing to report on.
  """

  alias Valea.ICM.Watcher
  alias Valea.Mounts
  alias Valea.Mounts.Context
  alias Valea.Workspace.Manager

  @type check :: %{String.t() => String.t() | nil}

  @gate_detail_path "not checked — this mount's path did not resolve (see path_resolves)."
  @gate_detail_manifest "not checked — this mount's manifest did not load (see manifest_format2)."

  @path_remedy "Check this mount's path in Settings — the folder may have moved, been " <>
                 "renamed, or unplugged, or the path itself isn't allowed (inside the " <>
                 "workspace, an ancestor of it, your home directory, the filesystem root, or " <>
                 "containing a permission-glob character)."
  @manifest_remedy "Add or fix icm.yaml at this mount's root — it must be valid YAML with a " <>
                     "UUID id and a non-blank name."
  @unique_id_remedy "Each mounted ICM needs a unique id — unmount one of the conflicting " <>
                      "mounts, or edit its icm.yaml to a fresh id (a new UUID)."
  @related_icms_remedy "Fix or remove the related_icms entry in this ICM's CONTEXT.md, or " <>
                         "mount and enable the ICM it points at."
  @secrets_remedy "Valea's workspace deny-list does not reach into external folders — move " <>
                    "secrets out of this mount's root, keep them elsewhere, or leave this " <>
                    "mount disabled while it holds them."
  @watcher_disabled_detail "not checked — this mount is disabled."
  @watcher_stale_remedy "If this mount was just enabled, give the watcher a moment to catch " <>
                          "up; otherwise reopen the workspace."

  @doc "Runs the mounts doctor against the currently open workspace (every mount)."
  @spec run() :: {:ok, %{checks: [check], ok: boolean}} | {:error, :no_workspace}
  def run do
    case Manager.current() do
      {:ok, %{path: ws}} -> run(ws)
      {:error, :no_workspace} -> {:error, :no_workspace}
    end
  end

  @doc """
  Pure form of `run/0` against an explicit `workspace` root — every mount
  `Valea.Mounts.list/1` discovers, flattened into one check list. Always
  succeeds; see the moduledoc for gating/status rules.
  """
  @spec run(workspace :: String.t()) :: {:ok, %{checks: [check], ok: boolean}}
  def run(workspace) when is_binary(workspace) do
    all_mounts = Mounts.list(workspace)
    checks = Enum.flat_map(all_mounts, &mount_checks(workspace, &1, all_mounts))
    {:ok, %{checks: checks, ok: Enum.all?(checks, &(&1["status"] == "ok"))}}
  end

  @doc """
  Runs the doctor for a single mount, addressed by `mount_key` (the
  `icms:` config key) — the per-ICM probe backing `icm_doctor`
  (`Valea.Api.Icms`). `{:error, :mount_not_found}` when `mount_key` names
  no `icms:` entry at all in `workspace`; otherwise always succeeds — see
  the moduledoc's closing paragraph for why a degraded/disabled mount is
  never an error here.
  """
  @spec run(workspace :: String.t(), mount_key :: String.t()) ::
          {:ok, %{mount_key: String.t(), checks: [check], ok: boolean}}
          | {:error, :mount_not_found}
  def run(workspace, mount_key) when is_binary(workspace) and is_binary(mount_key) do
    all_mounts = Mounts.list(workspace)

    case Enum.find(all_mounts, &(&1.name == mount_key)) do
      nil ->
        {:error, :mount_not_found}

      mount ->
        checks = mount_checks(workspace, mount, all_mounts)

        {:ok,
         %{mount_key: mount_key, checks: checks, ok: Enum.all?(checks, &(&1["status"] == "ok"))}}
    end
  end

  # -- per-mount check pipeline ------------------------------------------------

  defp mount_checks(workspace, mount, all_mounts) do
    path = path_resolves_check(mount)

    if path["status"] == "ok" do
      manifest = manifest_format2_check(mount)
      unique_id = unique_id_check(mount, all_mounts, manifest["status"] == "ok")
      related_icms = related_icms_check(workspace, mount)
      secrets = secrets_hygiene_check(mount)
      watcher = watcher_live_check(mount)
      [path, manifest, unique_id, related_icms, secrets, watcher]
    else
      [
        path,
        unknown(
          check_id(mount, "manifest_format2"),
          "#{mount.name}: manifest",
          @gate_detail_path
        ),
        unknown(check_id(mount, "unique_id"), "#{mount.name}: unique id", @gate_detail_path),
        unknown(
          check_id(mount, "related_icms"),
          "#{mount.name}: related ICMs",
          @gate_detail_path
        ),
        unknown(
          check_id(mount, "secrets_hygiene"),
          "#{mount.name}: secrets hygiene",
          @gate_detail_path
        ),
        unknown(check_id(mount, "watcher_live"), "#{mount.name}: watcher live", @gate_detail_path)
      ]
    end
  end

  # Mount-key-qualified check id: `"<check>:<mount key>"` — every mount is
  # external post-Phase-3 (no more embedded/external duality to disambiguate
  # via a kind infix), but a check id still has to stay unique once
  # flattened across every mount in `run/1`'s list (or across several
  # `run/2` results a caller flattens together), so the mount key itself is
  # the qualifier.
  defp check_id(%{name: name}, check_name), do: "#{check_name}:#{name}"

  # -- 1. path_resolves ---------------------------------------------------------

  defp path_resolves_check(mount) do
    id = check_id(mount, "path_resolves")
    label = "#{mount.name}: path resolves"

    if path_resolves_ok?(mount) do
      ok(id, label, "#{mount.root} resolves and is reachable.")
    else
      failed(id, label, mount.degraded, @path_remedy)
    end
  end

  defp path_resolves_ok?(%{degraded: nil}), do: true
  defp path_resolves_ok?(%{degraded: reason}), do: not path_level_failure?(reason)

  # `Valea.Mounts`'s fixed reason-string vocabulary for a path/location
  # failure (`icm_path/1`, `build_from_icm_path/4`'s `absolute_or_tilde?/1` +
  # `Valea.Mounts.External.check_boundaries/2`, `build_resolved_icm_mount/4`'s
  # `check_icm_glob_safety/1` + folder-exists check, and the
  # `degrade_duplicate_roots/1` post-pass — see that module's moduledoc for
  # the full list this mirrors). Anything NOT matching one of these prefixes
  # is a manifest/identity-level reason instead ("icm.yaml is missing", an
  # invalid-manifest message, or the `degrade_duplicate_ids/1` post-pass's
  # "ambiguous id: ...") and surfaces under `manifest_format2`/`unique_id`
  # instead. If `Valea.Mounts`'s wording ever changes, this list must move
  # with it — this module's own tests (built on real `Mounts.list/1` output,
  # not mocked reasons) will catch drift.
  @path_failure_prefixes [
    # icm_path/1 -- the `icms:` entry's `path:` key itself missing/invalid.
    "path is missing or invalid",
    # absolute_or_tilde?/1 rejecting a relative path.
    "path must be an absolute path",
    # External.check_boundaries/2 -- home_or_root, inside_workspace, ancestor_of_workspace
    "path points at",
    # check_icm_glob_safety/1
    "path contains characters unsafe for permission globs",
    # build_resolved_icm_mount/4's folder-exists check
    "folder not found at",
    # degrade_duplicate_roots/1 -- the same physical folder mounted twice
    # under different keys; a location problem, not a manifest one.
    "duplicate root:"
  ]

  defp path_level_failure?(reason) when is_binary(reason) do
    Enum.any?(@path_failure_prefixes, &String.starts_with?(reason, &1))
  end

  # -- 2a. manifest_format2 ------------------------------------------------------

  # Ok iff `Valea.Mounts.list/1` already loaded a manifest — that loader
  # (`Valea.Mounts.Manifest.load/1`) IS the format-2 validation (a stable,
  # validated UUID `id`, a non-blank `name`), and `mount.manifest` survives
  # both post-passes untouched (see moduledoc), so this reports `ok` even
  # for a mount later degraded ONLY by a duplicate root/id.
  defp manifest_format2_check(mount) do
    id = check_id(mount, "manifest_format2")
    label = "#{mount.name}: manifest"

    case mount.manifest do
      %{name: name} ->
        ok(id, label, "icm.yaml loads as a valid format-2 manifest (#{name}).")

      nil ->
        failed(id, label, mount.degraded, @manifest_remedy)
    end
  end

  # -- 2b. unique_id, gated on manifest_format2 ---------------------------------

  defp unique_id_check(mount, _all_mounts, false) do
    unknown(check_id(mount, "unique_id"), "#{mount.name}: unique id", @gate_detail_manifest)
  end

  defp unique_id_check(mount, all_mounts, true) do
    id = check_id(mount, "unique_id")
    label = "#{mount.name}: unique id"
    manifest_id = mount.manifest.id

    conflicts =
      all_mounts
      |> Enum.filter(fn other ->
        other.name != mount.name and other.enabled and other.manifest != nil and
          other.manifest.id == manifest_id
      end)
      |> Enum.map(& &1.name)
      |> Enum.sort()

    case conflicts do
      [] ->
        ok(id, label, "No other enabled mount shares this ICM's id.")

      keys ->
        failed(
          id,
          label,
          "This ICM's id is also used by the enabled mount(s): #{Enum.join(keys, ", ")}.",
          @unique_id_remedy
        )
    end
  end

  # -- 2c. related_icms, gated on path_resolves alone ---------------------------

  defp related_icms_check(workspace, mount) do
    id = check_id(mount, "related_icms")
    label = "#{mount.name}: related ICMs"

    case Context.resolve(workspace, mount) do
      %{issues: []} ->
        ok(id, label, "Every related ICM declared in this mount's CONTEXT.md resolves.")

      %{issues: issues} ->
        failed(id, label, related_icms_detail(issues), @related_icms_remedy)
    end
  end

  defp related_icms_detail(issues), do: Enum.map_join(issues, " ", &related_icm_issue_text/1)

  defp related_icm_issue_text(%{name: name, id: id, reason: reason}) do
    "#{related_icm_label(name, id)}: #{reason}."
  end

  defp related_icm_label(name, _id) when is_binary(name), do: "Related ICM \"#{name}\""
  defp related_icm_label(_name, id) when is_binary(id), do: "Related ICM #{id}"
  defp related_icm_label(_name, _id), do: "A declared related ICM"

  # -- 2d. secrets_hygiene -------------------------------------------------------

  defp secrets_hygiene_check(mount) do
    id = check_id(mount, "secrets_hygiene")
    label = "#{mount.name}: secrets hygiene"

    case secret_entries(mount.root) do
      [] ->
        ok(id, label, "No secrets/ folder or .env-like file at the mount root.")

      hits ->
        failed(
          id,
          label,
          "Found at the mount root: #{Enum.join(hits, ", ")}.",
          @secrets_remedy
        )
    end
  end

  # Direct children of `root` ONLY (per the design spec: "at its root") —
  # never recurses, never opens a file. A `secrets/` DIRECTORY (not a file
  # of that name) or a `.env`-like basename (`.env` exactly, or starting
  # with `.env.` -- `.env.local`, `.env.production`, ...) counts.
  defp secret_entries(root) do
    case File.ls(root) do
      {:ok, entries} -> entries |> Enum.filter(&secret_like?(root, &1)) |> Enum.sort()
      {:error, _reason} -> []
    end
  end

  defp secret_like?(root, "secrets"), do: File.dir?(Path.join(root, "secrets"))
  defp secret_like?(_root, entry), do: env_like?(entry)

  defp env_like?(".env"), do: true
  defp env_like?(name), do: String.starts_with?(name, ".env.")

  # -- 2e. watcher_live -----------------------------------------------------------

  defp watcher_live_check(mount) do
    id = check_id(mount, "watcher_live")
    label = "#{mount.name}: watcher live"

    cond do
      not mount.enabled ->
        unknown(id, label, @watcher_disabled_detail)

      MapSet.member?(Watcher.watched_roots(), mount.root) ->
        ok(id, label, "#{mount.root} is in the watcher's current root set.")

      true ->
        failed(
          id,
          label,
          "#{mount.root} is not currently in the watcher's root set.",
          @watcher_stale_remedy
        )
    end
  end

  # -- check builders (same shape as Valea.Mail.Doctor / Valea.Agents.Doctor) -

  defp ok(id, label, detail),
    do: %{"id" => id, "label" => label, "status" => "ok", "detail" => detail, "remedy" => nil}

  defp failed(id, label, detail, remedy),
    do: %{
      "id" => id,
      "label" => label,
      "status" => "failed",
      "detail" => detail,
      "remedy" => remedy
    }

  defp unknown(id, label, detail),
    do: %{
      "id" => id,
      "label" => label,
      "status" => "unknown",
      "detail" => detail,
      "remedy" => nil
    }
end
