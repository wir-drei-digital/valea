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
          optional(:write_roots) => [String.t()]
        }

  @spec resolve(opts) :: {:ok, map()} | {:error, term()}
  def resolve(
        %{kind: kind, mount_key: mount_key, generation: generation, session_id: session_id} = opts
      ) do
    with :ok <- Manager.check_generation(generation),
         {:ok, workspace} <- Manager.current(),
         {:ok, primary} <- resolve_primary(workspace.path, mount_key) do
      {:ok, build_scope(workspace, primary, kind, generation, session_id, opts)}
    end
  end

  defp resolve_primary(workspace_root, mount_key) do
    case Mounts.mount_by_key(workspace_root, mount_key) do
      %{enabled: true, degraded: nil} = mount -> {:ok, mount}
      _unavailable -> {:error, :icm_unavailable}
    end
  end

  defp build_scope(workspace, primary, kind, generation, session_id, opts) do
    %{related: related, issues: issues} = Context.resolve(workspace.path, primary)
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
