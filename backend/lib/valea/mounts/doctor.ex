defmodule Valea.Mounts.Doctor do
  @moduledoc """
  The "Mounts" section of the doctor (icm-by-reference design, "Trust &
  product framing" + "Error handling"): per-mount health, same shape and
  spirit as `Valea.Agents.Doctor` / `Valea.Mail.Doctor` — a list of checks,
  each with a status and a copyable remedy — but this one runs over a
  VARIABLE number of subjects (every mount `Valea.Mounts.list/1` discovers,
  embedded ∪ external, enabled + disabled + degraded) rather than a fixed
  pipeline, so each check's `"id"` is `"<check>:<mount name>"` for an
  EMBEDDED mount, or `"<check>:external:<mount name>"` for an EXTERNAL one
  — the kind qualifier keeps every external check id disjoint from an
  embedded one even in the one state where the same `<check>` name and the
  same mount `name` can otherwise coincide: an embedded/external name
  collision (see `manifest_ok_check/1`'s own doc) degrades BOTH entries,
  each surfacing its OWN `manifest_ok` check — without the qualifier
  they'd share the literal id `"manifest_ok:<name>"`, which is exactly the
  duplicate Svelte 5's keyed `{#each}` cannot tolerate (`each_key_duplicate`
  in dev). See `check_id/2`.

  Checks, per mount kind:

    * EMBEDDED (`rel_root` is `"mounts/<name>"`) gets one check:
      `manifest_ok` — is `icm.yaml` present and valid, and is the mount
      otherwise not degraded (e.g. a name collision with an external
      mount)? An embedded mount is always physically present the moment
      `Valea.Mounts.list/1` discovers it (it IS a directory under
      `mounts/`), so there is no analogous "does it exist" check to run
      first.
    * EXTERNAL (`rel_root: nil`) gets four, in a single gate:
      1. `ref_resolves` — does the declared reference resolve to a real
         folder AND pass `Valea.Mounts.External`'s boundary/glob guardrails?
         A degraded external mount's `mount.degraded` reason is shown
         verbatim as this check's `detail` when the reason is ref/path-level
         (see `ref_resolution_failure?/1` for the exact classification of
         `Valea.Mounts.External`'s fixed reason vocabulary — icm.yaml
         problems and name collisions are NOT ref-level, they surface under
         `manifest_ok` instead, same as embedded).
      2. `manifest_ok`, `secrets_hygiene`, `watcher_live` — independent
         siblings that only run when `ref_resolves` is `"ok"` (mirroring
         `Valea.Mail.Doctor`'s `tls_ok` gating `login_ok`/`folders`/
         `move_capability`); when `ref_resolves` fails, all three are
         `"unknown"` rather than probing a root that may not exist, may not
         be a folder, or may be an unsafe glob target.

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
  mount's resolved root is in the CURRENT watched set. A DISABLED external
  mount is never in that set by design (the watcher only ever watches
  enabled, non-degraded external roots), so `watcher_live` is `"unknown"`
  (not checked — nothing to fix, the mount is intentionally off) rather than
  `"failed"` for a disabled mount; only an ENABLED mount whose root the
  watcher currently is NOT covering reports `"failed"`.

  Never reads or leaks file CONTENTS — `secrets_hygiene` only lists
  directory ENTRY NAMES at the mount root (`File.ls/1`), never opens a file.
  Paths are fine to show throughout (they're user-declared, already visible
  in Settings/MOUNTS.md).

  `run/1` never raises: every filesystem probe (`File.ls/1`,
  `Watcher.watched_roots/0`) is either inherently non-raising or explicitly
  guarded, matching the "the doctor never crashes the caller" posture of its
  siblings.
  """

  alias Valea.ICM.Watcher
  alias Valea.Mounts
  alias Valea.Workspace.Manager

  @type check :: %{String.t() => String.t() | nil}

  @ref_gate_detail "not checked — this mount's reference did not resolve (see ref_resolves)."

  @ref_remedy "Check this mount's reference in Settings — the folder may have moved, been " <>
                "renamed, or unplugged, or the path itself isn't allowed (inside the " <>
                "workspace, an ancestor of it, your home directory, the filesystem root, or " <>
                "containing a permission-glob character)."
  @manifest_remedy "Add or fix icm.yaml at this mount's root — it must be valid YAML with a " <>
                     "non-blank name."
  @secrets_remedy "Valea's workspace deny-list does not reach into external folders — move " <>
                    "secrets out of this mount's root, keep them elsewhere, or leave this " <>
                    "mount disabled while it holds them."
  @watcher_disabled_detail "not checked — this mount is disabled."
  @watcher_stale_remedy "If this mount was just enabled, give the watcher a moment to catch " <>
                          "up; otherwise reopen the workspace."

  @doc "Runs the mounts doctor against the currently open workspace."
  @spec run() :: {:ok, %{checks: [check], ok: boolean}} | {:error, :no_workspace}
  def run do
    case Manager.current() do
      {:ok, %{path: ws}} -> run(ws)
      {:error, :no_workspace} -> {:error, :no_workspace}
    end
  end

  @doc "Pure form of `run/0` against an explicit `workspace` root — always succeeds."
  @spec run(workspace :: String.t()) :: {:ok, %{checks: [check], ok: boolean}}
  def run(workspace) when is_binary(workspace) do
    checks = workspace |> Mounts.list() |> Enum.flat_map(&mount_checks/1)
    {:ok, %{checks: checks, ok: Enum.all?(checks, &(&1["status"] == "ok"))}}
  end

  # -- per-mount dispatch ----------------------------------------------------

  defp mount_checks(%{rel_root: nil} = mount), do: external_checks(mount)
  defp mount_checks(%{rel_root: rel} = mount) when is_binary(rel), do: [manifest_ok_check(mount)]

  # Kind-qualified check id: `"<check>:<mount name>"` for an embedded mount
  # (bare — the historical, still-unique-on-its-own form), or
  # `"<check>:external:<mount name>"` for an external one. Applied to EVERY
  # external check (not just `manifest_ok`, the one that can actually
  # collide with an embedded mount's) so the id scheme is uniform — a
  # reader can tell a check's mount kind from its id alone, and no future
  # embedded-only check name can accidentally collide with an external one
  # either.
  defp check_id(%{rel_root: nil, name: name}, check_name), do: "#{check_name}:external:#{name}"
  defp check_id(%{name: name}, check_name), do: "#{check_name}:#{name}"

  # -- embedded + external shared: manifest_ok --------------------------------

  # Ok iff the mount is not degraded at all — `degraded == nil` implies a
  # loaded manifest for BOTH embedded and external mounts (see
  # `Valea.Mounts`/`Valea.Mounts.External`'s construction invariants), so a
  # degrade reason of ANY kind (missing/invalid icm.yaml, an invalid
  # directory basename, a name collision) surfaces here — for an embedded
  # mount this is the ONLY check, so every degrade reason has to land
  # somewhere; for an external mount this only runs once `ref_resolves` has
  # already confirmed the reason isn't ref/path-level. An embedded/external
  # NAME COLLISION degrades BOTH mount entries (see `Valea.Mounts`'s
  # `degrade_name_collisions/1`), so this same function is called once per
  # side with the SAME `mount.name` — `check_id/2`'s kind qualifier is what
  # keeps their two `manifest_ok` checks from colliding on id.
  defp manifest_ok_check(mount) do
    id = check_id(mount, "manifest_ok")
    label = "#{mount.name}: manifest"

    case mount.degraded do
      nil -> ok(id, label, "icm.yaml loads (#{mount.manifest.name}).")
      reason -> failed(id, label, reason, @manifest_remedy)
    end
  end

  # -- external: ref_resolves gates manifest_ok / secrets_hygiene / watcher_live

  defp external_checks(mount) do
    if ref_resolves_ok?(mount) do
      [
        ref_resolves_check(mount),
        manifest_ok_check(mount),
        secrets_hygiene_check(mount),
        watcher_live_check(mount)
      ]
    else
      [
        ref_resolves_check(mount),
        unknown(check_id(mount, "manifest_ok"), "#{mount.name}: manifest", @ref_gate_detail),
        unknown(
          check_id(mount, "secrets_hygiene"),
          "#{mount.name}: secrets hygiene",
          @ref_gate_detail
        ),
        unknown(check_id(mount, "watcher_live"), "#{mount.name}: watcher live", @ref_gate_detail)
      ]
    end
  end

  defp ref_resolves_check(mount) do
    id = check_id(mount, "ref_resolves")
    label = "#{mount.name}: reference resolves"

    if ref_resolves_ok?(mount) do
      ok(id, label, "#{mount.root} resolves and is reachable.")
    else
      failed(id, label, mount.degraded, @ref_remedy)
    end
  end

  defp ref_resolves_ok?(%{degraded: nil}), do: true
  defp ref_resolves_ok?(%{degraded: reason}), do: not ref_resolution_failure?(reason)

  # `Valea.Mounts.External`'s fixed reason-string vocabulary for a ref/path
  # failure (`check_absolute/1`, `check_boundaries/2`, `check_glob_safety/1`,
  # `check_folder/1` — see its moduledoc/@doc for the full list this
  # mirrors). Anything NOT matching one of these prefixes is a
  # manifest/collision-level reason instead ("icm.yaml is missing", an
  # invalid-manifest message, or "name used by both an embedded and an
  # external mount") and surfaces under `manifest_ok` instead. If
  # `Valea.Mounts.External`'s wording ever changes, this list must move with
  # it — this module's own tests (built on real `Mounts.list/1` output, not
  # mocked reasons) will catch drift.
  @ref_failure_prefixes [
    # check_absolute/1 rejecting a relative ref, and a config entry with the
    # `ref:` key itself missing/invalid.
    "ref is missing or invalid",
    "ref must be an absolute path",
    # check_boundaries/2 -- home_or_root, inside_workspace, ancestor_of_workspace
    "ref points at",
    # check_glob_safety/1
    "path contains characters unsafe for permission globs",
    # check_folder/1
    "folder not found at"
  ]

  defp ref_resolution_failure?(reason) when is_binary(reason) do
    Enum.any?(@ref_failure_prefixes, &String.starts_with?(reason, &1))
  end

  # -- external: secrets_hygiene ----------------------------------------------

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

  # -- external: watcher_live --------------------------------------------------

  defp watcher_live_check(mount) do
    id = check_id(mount, "watcher_live")
    label = "#{mount.name}: watcher live"

    cond do
      not mount.enabled ->
        unknown(id, label, @watcher_disabled_detail)

      MapSet.member?(Watcher.watched_roots(), mount.root) ->
        ok(id, label, "#{mount.root} is in the watcher's current external-root set.")

      true ->
        failed(
          id,
          label,
          "#{mount.root} is not currently in the watcher's external-root set.",
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
