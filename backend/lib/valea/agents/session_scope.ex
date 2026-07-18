defmodule Valea.Agents.SessionScope do
  @moduledoc """
  Builds the C6 launch object every agent session is created from (spec
  §"Session scope and launch" / §"Introduce session-scope resolution") — the
  ONLY place mount-key lookup, direct related-ICM resolution, and
  read/write-root assembly live. `Valea.Api.Agents` never re-derives any of
  these rules; it calls `resolve/1` and uses the scope it returns.

  `resolve/1` is a strict pipeline, each step gating the next:

    1. `Valea.Workspace.Manager.check_generation/1` — a stale `generation`
       (the workspace closed/reopened/switched under the caller) fails
       FIRST, before any lookup, as `{:error, :workspace_changed}`.
    2. `Valea.Workspace.Manager.current/0` — the open workspace.
    3. `Valea.Mounts.mount_by_key/2` for `mount_key`, requiring ENABLED and
       non-degraded — anything else (unknown key, disabled, degraded) is
       `{:error, :icm_unavailable}` rather than a partially-formed scope.
    4. `Valea.Mounts.Context.resolve/2` for the primary's DIRECT related
       ICMs — issues (not-mounted/disabled/degraded/duplicate-id/escaping
       entrypoint) are attached as `scope.context_issues` for the UI/doctor
       rather than failing the whole scope: a chat session may still start
       with a visible degraded-context warning (a workflow's required-input
       check is a later phase's concern).
    5. `cwd` is always the primary ICM's root — never the workspace root,
       never a caller-supplied path (spec §"Process and ACP cwd").
    6. The harness adapter (`Valea.Harnesses.ClaudeCode.launch/2`, the only
       harness currently wired — mirrors `Valea.Agents.start_session/1`)
       materializes `context.md` under
       `<workspace>/runtime/sessions/<session_id>/` and computes the
       in-memory managed-settings posture; its launch directives are folded
       into the returned scope (`managed_settings`, `additional_roots`,
       `env`, `argv_extra`) so a later phase's process spawn never needs to
       re-derive them.

  Read/write grants (`read_paths`, `write_paths`, `write_roots`) are taken
  EXACTLY as given by the caller — a workflow run's validated, per-input
  grants, or `[]` for a plain chat session. This module never widens them.

  ## Synthetic mounts (mail — Task 14; calendar — Spec F Task 5)

  A synthetic, non-ICM mount joins a session's scope two ways, both
  landing in `scope.related_icms` with the SAME entry shape the related
  grammar produces (deduped by mount key):

    * the primary's own `CONTEXT.md` declaring a bare-string entry —
      `mail-<slug>` or `calendar` (resolved by `Context.resolve/2`);
    * the caller's `include_mounts` opt (spec: "entry points may include
      the mount explicitly for a session") — each entry MUST name an
      existing, enabled, non-degraded mount of a synthetic, non-ICM kind
      (`:mail` or `:calendar`); an ICM key is `{:error,
      :include_not_mail}`, anything else `{:error, :mail_unavailable}` —
      a session never starts with a silently-dropped grant.

  The scope also always carries `mail_roots_all` (every configured
  account's `sources/mail/<slug>` root, in or out of scope),
  `mail_roots_in_scope` (the `kind: :mail` related entries' roots), and
  `calendar_in_scope` (whether a `kind: :calendar` entry made it into
  `related_icms` — ONE mount, so a boolean, not a root list) —
  `SessionServer` threads them into the `PermissionPolicy` ctx, where
  unmounted mail AND unmounted calendar territory are DENIED, not asked.
  A synthetic mount can never be the session PRIMARY (`resolve_primary/2`
  requires `kind: :icm`).
  """

  alias Valea.Harnesses.ClaudeCode
  alias Valea.Mounts
  alias Valea.Mounts.Context
  alias Valea.Workspace.Manager

  @type opts :: %{
          required(:kind) => String.t(),
          required(:mount_key) => String.t(),
          required(:generation) => integer(),
          required(:session_id) => String.t(),
          optional(:read_paths) => [String.t()],
          optional(:write_paths) => [String.t()],
          optional(:write_roots) => [String.t()],
          optional(:include_mounts) => [String.t()]
        }

  @spec resolve(opts) :: {:ok, map()} | {:error, term()}
  def resolve(
        %{kind: kind, mount_key: mount_key, generation: generation, session_id: session_id} = opts
      ) do
    with :ok <- Manager.check_generation(generation),
         {:ok, workspace} <- Manager.current(),
         {:ok, primary} <- resolve_primary(workspace.path, mount_key),
         {:ok, includes} <-
           resolve_include_mounts(workspace.path, Map.get(opts, :include_mounts, [])) do
      {:ok, build_scope(workspace, primary, includes, kind, generation, session_id, opts)}
    end
  end

  defp resolve_primary(workspace_root, mount_key) do
    case Mounts.mount_by_key(workspace_root, mount_key) do
      %{enabled: true, degraded: nil, kind: :icm} = mount -> {:ok, mount}
      _unavailable -> {:error, :icm_unavailable}
    end
  end

  # Fail-closed include resolution: every entry must name an existing,
  # ENABLED, non-degraded mount of a synthetic, non-ICM kind (`:mail` —
  # Task 14 — or `:calendar` — Spec F Task 5). An ICM key is a caller
  # error, distinct from a mount that is merely unavailable
  # (unconfigured/degraded/shadowed), so the FE can render each precisely
  # (the error atoms predate the calendar kind and stay wire-stable).
  @include_kinds [:mail, :calendar]

  defp resolve_include_mounts(workspace_root, keys) when is_list(keys) do
    Enum.reduce_while(keys, {:ok, []}, fn key, {:ok, acc} ->
      case Mounts.mount_by_key(workspace_root, key) do
        %{kind: kind, enabled: true, degraded: nil, root: root} when kind in @include_kinds ->
          entry = %{
            mount_key: key,
            id: nil,
            root: root,
            entrypoint: nil,
            manifest: nil,
            kind: kind
          }

          {:cont, {:ok, acc ++ [entry]}}

        %{kind: :icm} ->
          {:halt, {:error, :include_not_mail}}

        _absent_or_degraded ->
          {:halt, {:error, :mail_unavailable}}
      end
    end)
  end

  defp build_scope(workspace, primary, includes, kind, generation, session_id, opts) do
    %{related: related, issues: issues} = Context.resolve(workspace.path, primary)
    related = Enum.uniq_by(related ++ includes, & &1.mount_key)

    mail_roots_all =
      workspace.path
      |> Mounts.list()
      |> Enum.filter(&(&1.kind == :mail))
      |> Enum.map(& &1.root)

    mail_roots_in_scope =
      related
      |> Enum.filter(&(&1.kind == :mail))
      |> Enum.map(& &1.root)

    # ONE calendar mount (Spec F Task 5) — in/out of scope is a boolean,
    # not a root list; the territory root is derived from the workspace
    # root by PermissionPolicy/SessionSettings themselves.
    calendar_in_scope = Enum.any?(related, &(&1.kind == :calendar))

    session_dir = Path.join([workspace.path, "runtime", "sessions", session_id])

    scope = %{
      workspace: %{
        id: workspace.id,
        root: workspace.path,
        name: workspace.name,
        generation: generation
      },
      primary_icm: %{
        mount_key: primary.name,
        id: primary.manifest.id,
        root: primary.root,
        manifest: primary.manifest
      },
      related_icms: related,
      context_issues: issues,
      cwd: primary.root,
      read_paths: Map.get(opts, :read_paths, []),
      write_paths: Map.get(opts, :write_paths, []),
      write_roots: Map.get(opts, :write_roots, []),
      mail_roots_all: mail_roots_all,
      mail_roots_in_scope: mail_roots_in_scope,
      calendar_in_scope: calendar_in_scope,
      managed_context: Path.join(session_dir, "context.md"),
      kind: kind
    }

    {:ok, launch} = ClaudeCode.launch(scope, session_dir)

    scope
    |> Map.put(:managed_settings, launch.managed_settings)
    |> Map.put(:additional_roots, launch.additional_roots)
    |> Map.put(:env, launch.env)
    |> Map.put(:argv_extra, launch.argv_extra)
  end
end
