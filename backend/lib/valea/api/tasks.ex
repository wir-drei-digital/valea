defmodule Valea.Api.Tasks do
  @moduledoc """
  The task-ledger RPC (tasks+schedules spec §RPC surface): `list_tasks`,
  `create_task`, `mutate_task`, `archive_done`, merged across the enabled ICMs.

  Wraps `Valea.Tasks`. Conventions, all of them deliberate:

    * **Every action guards `Valea.Workspace.Manager.check_generation/1`
      FIRST** (`verified/2`), like every other workspace RPC — a stale
      generation surfaces as `workspace_changed` instead of acting against the
      wrong workspace. The reads are guarded too: a listing rendered from the
      previous workspace's ICMs is a lie the UI would happily draw.
    * **String keys throughout**, top level included. The payloads ARE the
      user's file content (`Valea.Tasks.list/1` returns entries as read), and
      task fields like `"today": false` are legitimately falsy — the
      ash_typescript 0.17.3 generic-action extraction nulls an atom-keyed
      `false` (see `Valea.Api.Agents.harness_doctor`), so the whole surface
      stays string-keyed rather than mixing conventions.
    * **`tasks` is an UNCONSTRAINED `{:array, :map}`** (the
      `list_calendar_events` precedent): entries round-trip unknown fields by
      contract, and a `constraints fields:` list would silently drop exactly
      the keys the leniency contract promises to preserve.
    * **`fields`/`patch` are unconstrained `:map` arguments** whose keys are
      the FILE's own snake_case names, passed through verbatim (the
      `create_session` `context_doc`/`input` locator precedent — no camelCase
      translation happens on an unconstrained map).
    * **The caller cannot forge identity or timestamps**: `id`, `created_at`,
      `updated_at`, `done_at` and `created_by` are dropped from both
      `fields` and `patch`; a task created here is stamped `created_by:
      "user"`, because this RPC is only reachable from the control-token-gated
      UI socket (agents have no RPC path at all — spec §RPC surface).
    * **UI mutations are audited** (`task_created` / `task_updated` /
      `task_archived`, with `mount_key` + id), and agent file edits
      deliberately are not (spec §Audit: transcript territory).

  ## Why a mutation can answer `workspace_not_open`

  `Valea.Tasks`' mutating half runs inside `Valea.Ledger.Writer.exec/1`, and
  the writer is a workspace-runtime child (`Valea.Schedules.Supervisor`). With
  no workspace open — or one mid-close — that `GenServer.call/3` EXITS. Every
  action here runs inside `verified/2`, which catches exactly the
  call-shaped exits and maps them to the shared vocabulary
  (`workspace_not_open` / `workspace_changed`) rather than letting a 500 out.
  """
  use Ash.Resource, domain: Valea.Api, extensions: [AshTypescript.Resource]

  typescript do
    type_name("Tasks")
  end

  alias Valea.Api.Error
  alias Valea.Mounts
  alias Valea.Workspace.Manager

  # Fields Valea owns: identity and the timestamp discipline `Valea.Tasks`
  # keeps (`updated_at` current, `done_at` consistent with `status`).
  @valea_owned ~w(id created_at updated_at done_at created_by)

  @icm_row_fields [
    mount_key: [type: :string, allow_nil?: false],
    icm_name: [type: :string, allow_nil?: false],
    status: [type: :string, allow_nil?: false],
    tasks: [type: {:array, :map}, allow_nil?: false]
  ]

  actions do
    # Per-ICM parse status alongside the entries, so the frontend can render
    # the spec's calm malformed-file note per ICM instead of an error state:
    # "ok" | "absent" | "unreadable" (`Valea.Tasks.list/1`'s own statuses).
    action :list_tasks, :map do
      constraints fields: [
                    icms: [
                      type: {:array, :map},
                      allow_nil?: false,
                      constraints: [items: [fields: @icm_row_fields]]
                    ]
                  ]

      argument :generation, :integer, allow_nil?: false

      run fn input, _ctx ->
        verified(input.arguments.generation, fn ws ->
          {:ok, %{"icms" => Enum.map(icm_mounts(ws), &tasks_row/1)}}
        end)
      end
    end

    action :create_task, :map do
      constraints fields: [task: [type: :map, allow_nil?: false]]

      argument :mount_key, :string, allow_nil?: false
      argument :fields, :map, allow_nil?: false
      argument :generation, :integer, allow_nil?: false

      run fn input, _ctx ->
        %{mount_key: mount_key, fields: fields, generation: generation} = input.arguments

        verified(generation, fn ws ->
          with {:ok, mount} <- icm_mount(ws, mount_key),
               {:ok, task} <- Valea.Tasks.create(mount.root, user_fields(fields, "user")) do
            audit("task_created", mount_key, task["id"])
            {:ok, %{"task" => task}}
          end
        end)
      end
    end

    action :mutate_task, :map do
      constraints fields: [task: [type: :map, allow_nil?: false]]

      argument :mount_key, :string, allow_nil?: false
      argument :task_id, :string, allow_nil?: false
      argument :patch, :map, allow_nil?: false
      argument :generation, :integer, allow_nil?: false

      run fn input, _ctx ->
        %{mount_key: mount_key, task_id: task_id, patch: patch, generation: generation} =
          input.arguments

        verified(generation, fn ws ->
          with {:ok, mount} <- icm_mount(ws, mount_key),
               {:ok, task} <- Valea.Tasks.patch(mount.root, task_id, user_fields(patch, nil)) do
            audit("task_updated", mount_key, task_id)
            {:ok, %{"task" => task}}
          end
        end)
      end
    end

    # The UI's "Clear done", per ICM (`mount_key`) or across every enabled ICM
    # (`mount_key: nil` — the "Clear done everywhere" affordance).
    #
    # `archived` counts ARCHIVE LINES written, `pruned` the entries that
    # actually left the ledger — they differ when an entry was edited inside
    # the window (the prune is snapshot-conditional), and `archived` can also
    # exceed what `Valea.Tasks.archive_entries/1` shows, since that view
    # dedupes byte-identical snapshots by hash. Both numbers are reported and
    # neither implies the other.
    #
    # A per-ICM failure is a per-ICM `status` ("unreadable" / "conflict"),
    # never a failed sweep: one broken ledger must not stop the others.
    action :archive_done, :map do
      constraints fields: [
                    archived: [type: :integer, allow_nil?: false],
                    pruned: [type: :integer, allow_nil?: false],
                    icms: [
                      type: {:array, :map},
                      allow_nil?: false,
                      constraints: [
                        items: [
                          fields: [
                            mount_key: [type: :string, allow_nil?: false],
                            status: [type: :string, allow_nil?: false],
                            archived: [type: :integer, allow_nil?: false],
                            pruned: [type: :integer, allow_nil?: false]
                          ]
                        ]
                      ]
                    ]
                  ]

      argument :mount_key, :string, allow_nil?: true
      argument :generation, :integer, allow_nil?: false

      run fn input, _ctx ->
        mount_key = Map.get(input.arguments, :mount_key)

        verified(input.arguments.generation, fn ws ->
          with {:ok, mounts} <- archive_targets(ws, mount_key) do
            rows = Enum.map(mounts, &archive_row/1)

            {:ok,
             %{
               "archived" => rows |> Enum.map(& &1["archived"]) |> Enum.sum(),
               "pruned" => rows |> Enum.map(& &1["pruned"]) |> Enum.sum(),
               "icms" => rows
             }}
          end
        end)
      end
    end
  end

  # -- rows --------------------------------------------------------------------

  defp tasks_row(mount) do
    %{status: status, tasks: tasks} = Valea.Tasks.list(mount.root)

    %{
      "mount_key" => mount.name,
      "icm_name" => mount.manifest.name,
      "status" => to_string(status),
      "tasks" => tasks
    }
  end

  defp archive_row(mount) do
    {status, archived, pruned} =
      case Valea.Tasks.archive_done(mount.root) do
        {:ok, %{archived: archived, pruned: pruned}} -> {"ok", archived, pruned}
        {:error, reason} -> {to_string(reason), 0, 0}
      end

    if archived > 0 do
      Valea.Audit.append("task_archived", %{
        "mount_key" => mount.name,
        "archived" => archived,
        "pruned" => pruned
      })
    end

    %{"mount_key" => mount.name, "status" => status, "archived" => archived, "pruned" => pruned}
  end

  defp archive_targets(ws, nil), do: {:ok, icm_mounts(ws)}

  defp archive_targets(ws, mount_key) do
    with {:ok, mount} <- icm_mount(ws, mount_key), do: {:ok, [mount]}
  end

  # -- shared plumbing ---------------------------------------------------------

  # The enabled ICM content mounts, in `Valea.Mounts.enabled/1` order. Task
  # ledgers are ICM files, so the synthetic mail/calendar mounts (no manifest,
  # no ICM root the user edits) are never listed — the same filter
  # `Valea.Cockpit`'s sections use.
  defp icm_mounts(ws) do
    ws |> Mounts.enabled() |> Enum.filter(&(&1.kind == :icm))
  end

  # A mutation target must be an ENABLED, non-degraded ICM mount: a disabled or
  # degraded mount is not something the UI is showing, and a degraded one has no
  # trustworthy manifest or root.
  defp icm_mount(ws, mount_key) do
    case Mounts.mount_by_key(ws, mount_key) do
      %{kind: :icm, enabled: true, degraded: nil} = mount -> {:ok, mount}
      _missing_disabled_degraded_or_synthetic -> {:error, :icm_unavailable}
    end
  end

  # Caller-supplied fields, normalized to string keys, stripped of everything
  # Valea owns, and optionally stamped with a `created_by` this RPC gets to
  # assert (a creation is the user acting; a patch leaves the existing
  # provenance — including `agent` — alone).
  defp user_fields(fields, created_by) when is_map(fields) do
    fields
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.drop(@valea_owned)
    |> then(fn stripped ->
      if created_by, do: Map.put(stripped, "created_by", created_by), else: stripped
    end)
  end

  defp audit(type, mount_key, id) do
    Valea.Audit.append(type, %{"mount_key" => mount_key, "id" => id})
  end

  # The generation guard + workspace resolution every action shares, plus the
  # error mapping — the `Valea.Api.Calendar.verified_lifecycle/2` posture minus
  # the lifecycle serializer (ledger writes serialize inside
  # `Valea.Ledger.Writer`, which needs no wrapper here).
  #
  # The `catch` clauses are the writer-is-gone contract: `Writer.exec/1` is a
  # `GenServer.call/3` to a workspace-runtime child, so a mutation with no
  # workspace open exits `:noproc` and one racing a close exits `:shutdown`/
  # `:normal`. Both are workspace-lifecycle facts, not bugs — they map to the
  # shared vocabulary instead of surfacing as a 500. A `:timeout` is
  # deliberately NOT caught: the writer's own 30 s bound is a
  # "something is very wrong" signal, and swallowing it would hide a jam.
  defp verified(generation, fun) when is_function(fun, 1) do
    result =
      with :ok <- Manager.check_generation(generation),
           {:ok, %{path: ws}} <- Manager.current() do
        fun.(ws)
      end

    case result do
      {:error, reason} -> {:error, error_for(reason)}
      {:ok, payload} -> {:ok, payload}
    end
  catch
    :exit, {:noproc, {GenServer, :call, _args}} ->
      {:error, error_for(:no_workspace)}

    :exit, {:normal, {GenServer, :call, _args}} ->
      {:error, error_for(:workspace_changed)}

    :exit, {:shutdown, {GenServer, :call, _args}} ->
      {:error, error_for(:workspace_changed)}

    :exit, {{:shutdown, _reason}, {GenServer, :call, _args}} ->
      {:error, error_for(:workspace_changed)}
  end

  @doc false
  # Central error mapping — the `Valea.Api.Icms.error_for/1` vocabulary.
  # `:not_found` (unknown task id), `:conflict` (a foreign writer kept winning
  # the optimistic race) and `:unreadable` (a ledger Valea will not clobber)
  # already stringify to the codes the frontend renders.
  #
  # Public (`@doc false`) like `Valea.Api.Agents.error_for/1` and
  # `Valea.Api.Calendar.error_for/1`, for one specific reason: `:conflict` is
  # the one code no test can drive through an action. It needs a foreign writer
  # to land inside the microseconds between `Valea.Tasks`' read and its write,
  # three times over, and the only hook for that is `Valea.Tasks.patch/4`'s
  # `:before_write` seam — which the RPC deliberately does not thread (a
  # test-only argument has no business on the wire). The BEHAVIOR is pinned in
  # `Valea.TasksTest` ("persistent contention is :conflict with nothing
  # written"); what this exposes is the mapping from that atom to the code the
  # frontend switches on.
  def error_for(:no_workspace), do: Error.new("workspace_not_open")
  def error_for(reason) when is_atom(reason), do: Error.new(to_string(reason))
  def error_for(reason), do: Error.new(inspect(reason))
end
