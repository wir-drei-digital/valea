defmodule Valea.Api.Agents do
  @moduledoc """
  Data-layer-less Ash resource exposing agent sessions and the harness
  doctor over RPC: `create_session`, `list_sessions` (internal),
  `list_recent_sessions_by_icm`, `list_sessions_for`, `create_follow_up`,
  and `harness_doctor`.

  Wraps `Valea.Agents` and `Valea.Agents.Doctor`. Every action here follows
  `Valea.Api.ICM`'s `constraints fields: [...]` pattern so ash_typescript
  emits typed TS interfaces (see that module's moduledoc for the full
  rationale and the typed-vs-unconstrained-map casing caveat).

  The mutating actions (`create_session`, `create_follow_up`) take a
  `generation` argument and guard against a stale generation (workspace
  closed/reopened/switched under the caller) BEFORE touching anything — a
  stale generation surfaces as `workspace_changed` rather than silently
  acting against the wrong workspace (`create_session` via
  `SessionScope.resolve/1`'s own first gate; `create_follow_up` via
  `Valea.Agents.create_follow_up/2`).
  """
  use Ash.Resource, domain: Valea.Api, extensions: [AshTypescript.Resource]

  typescript do
    type_name("Agents")
  end

  alias Valea.Agents.SessionScope
  alias Valea.Api.Error
  alias Valea.Workspace.Manager

  # Shared `constraints fields:` shape for a session summary (Task 6.2's
  # `list_recent_sessions_by_icm`/`list_sessions_for`, both trimmed to
  # exactly this shape by `Valea.Agents.trim_summary/1`) — a module
  # attribute rather than a helper function since these DSL blocks expand
  # at compile time, before any of this module's own functions exist yet;
  # an attribute read is resolved by the Elixir compiler itself first.
  @session_summary_fields [
    id: [type: :string, allow_nil?: false],
    kind: [type: :string, allow_nil?: false],
    title: [type: :string, allow_nil?: false],
    workflow: [type: :string, allow_nil?: true],
    run_id: [type: :string, allow_nil?: true],
    started_at: [type: :string, allow_nil?: false],
    status: [type: :string, allow_nil?: false],
    live: [type: :boolean, allow_nil?: false]
  ]

  actions do
    action :create_session, :map do
      constraints fields: [
                    id: [type: :string, allow_nil?: false],
                    input_path: [type: :string, allow_nil?: true]
                  ]

      argument :mount_key, :string, allow_nil?: false
      argument :generation, :integer, allow_nil?: false
      # Spec D §B: both optional, both raw string-keyed locator maps
      # (unconstrained :map — same convention the deleted workflow-run action
      # used for input_locator; the FE sends "kind"/"icm_id"/"path" verbatim).
      argument :context_doc, :map, allow_nil?: true
      argument :input, :map, allow_nil?: true
      # Task 14 (mail spec §"Mount & containment") + Spec F Task 5
      # (calendar spec §"Mounts and policy"): synthetic non-ICM mount keys
      # (`mail-<slug>`, `calendar`) to include in the session's scope,
      # default `[]`. Each must name an existing, enabled, non-degraded
      # mount of a synthetic, non-ICM kind — `SessionScope.resolve/1`
      # rejects an ICM key as `include_not_mail` and anything unavailable
      # as `mail_unavailable` (the atoms predate the calendar kind and
      # stay wire-stable), fail-closed, before any session starts.
      argument :include_mounts, {:array, :string}, allow_nil?: true

      # Task 5.5 / Task 9 (Spec D §B): `create_session` resolves `mount_key`
      # — the session's PRIMARY ICM, chosen by the caller (for now, the
      # frontend defaults to the first enabled ICM until Phase 9's sidebar
      # `+` supplies a real choice). The `kind` ARGUMENT is gone — the
      # server always creates a `chat` session now (the field stays on the
      # session schema/summaries; `Valea.Agents.create_follow_up/2` still
      # threads a session's own recorded `kind` through for a follow-up).
      # The id is generated HERE (not inside `start_session/1`) so
      # `SessionScope.resolve/1` — which needs a `session_id` up front to
      # derive `managed_context`'s path — can run BEFORE the session
      # starts; `start_session/1` is then handed the same id plus the
      # resolved `scope`, never a raw `policy_ctx`/`workspace` pair.
      #
      # `context_doc`/`input` resolve FIRST, against the open workspace —
      # fail-closed: a locator that doesn't resolve to a real file aborts
      # creation entirely (`:context_doc_unavailable`/`:input_unavailable`)
      # rather than starting a session that silently lacks its context.
      # `context_doc` gets NO extra grant — it lives inside the primary (or
      # a related) ICM, already covered by `SessionScope.resolve/1`'s own
      # read roots. `input` is granted as ONE exact read path via
      # `read_paths` — `SessionScope.resolve/1` folds it into both the
      # managedSettings `Read(<path>)` allow and the ACP `additional_roots`.
      # `Manager.check_generation/1` runs FIRST, before either locator is
      # touched, so a stale generation surfaces as `workspace_changed`
      # exactly like before (`SessionScope.resolve/1`'s own later check is
      # a harmless double-check on the same guard).
      run fn input, _ctx ->
        %{mount_key: mount_key, generation: generation} = input.arguments
        context_doc = Map.get(input.arguments, :context_doc)
        input_locator = Map.get(input.arguments, :input)
        include_mounts = Map.get(input.arguments, :include_mounts) || []
        id = Valea.Agents.generate_session_id()

        with :ok <- Manager.check_generation(generation),
             {:ok, %{path: workspace}} <- Manager.current(),
             {:ok, context_doc} <- resolve_context_doc(context_doc, workspace),
             {:ok, input_abs} <- resolve_session_input(input_locator, workspace),
             {:ok, scope} <-
               SessionScope.resolve(%{
                 kind: "chat",
                 mount_key: mount_key,
                 generation: generation,
                 session_id: id,
                 read_paths: if(input_abs, do: [input_abs], else: []),
                 include_mounts: include_mounts
               }),
             {:ok, %{id: id}} <-
               Valea.Agents.start_session(%{
                 id: id,
                 kind: "chat",
                 title: "New session",
                 scope: scope,
                 run: nil,
                 initial_prompt: nil,
                 on_turn_end: nil,
                 context_doc: context_doc,
                 input: input_locator,
                 include_mounts: include_mounts
               }) do
          Valea.Audit.append("session_started", %{
            "session_id" => id,
            "mount_key" => mount_key,
            "context_doc" => context_doc,
            "input" => input_locator,
            "include_mounts" => include_mounts
          })

          {:ok, %{id: id, input_path: input_abs}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :list_sessions, :map do
      constraints fields: [
                    sessions: [
                      type: {:array, :map},
                      allow_nil?: false,
                      constraints: [
                        items: [
                          fields: [
                            id: [type: :string, allow_nil?: false],
                            kind: [type: :string, allow_nil?: false],
                            title: [type: :string, allow_nil?: false],
                            workflow: [type: :string, allow_nil?: true],
                            run_id: [type: :string, allow_nil?: true],
                            started_at: [type: :string, allow_nil?: false],
                            status: [type: :string, allow_nil?: false],
                            live: [type: :boolean, allow_nil?: false]
                          ]
                        ]
                      ]
                    ]
                  ]

      run fn _input, _ctx ->
        {:ok, sessions} = Valea.Agents.list_sessions()
        {:ok, %{sessions: Enum.map(sessions, &atomize_session/1)}}
      end
    end

    # Task 6.2 — grouped-by-ICM recent-session feed for the sidebar's
    # project groups. `groups` wraps the bare list `Valea.Agents.
    # list_recent_sessions_by_icm/1` returns (this domain's generic `:map`
    # actions always need a named top-level field for ash_typescript's
    # `constraints fields:` selection — mirrors `list_agent_sessions`'s
    # `sessions`). No `generation` argument: a read, not a mutation
    # (mirrors `list_sessions`).
    action :list_recent_sessions_by_icm, :map do
      constraints fields: [
                    groups: [
                      type: {:array, :map},
                      allow_nil?: false,
                      constraints: [
                        items: [
                          fields: [
                            mount_key: [type: :string, allow_nil?: false],
                            icm_name: [type: :string, allow_nil?: false],
                            sessions: [
                              type: {:array, :map},
                              allow_nil?: false,
                              constraints: [items: [fields: @session_summary_fields]]
                            ]
                          ]
                        ]
                      ]
                    ]
                  ]

      argument :limit, :integer, allow_nil?: false

      run fn input, _ctx ->
        {:ok, %{groups: Valea.Agents.list_recent_sessions_by_icm(input.arguments.limit)}}
      end
    end

    # Task 6.2 — full filtered history for a single ICM (the sidebar
    # group's "Show all…"), paged via `Valea.Agents.list_sessions_for/2`.
    # External RPC name `list_sessions` (spec C9's `list_sessions(mount_key,
    # cursor)`) — distinct from `list_agent_sessions`, this resource's
    # existing workspace-wide listing (`:list_sessions` internal action
    # name), so both coexist under different external names (see
    # `Valea.Api`). No `generation` argument, same reasoning as
    # `list_recent_sessions_by_icm` above.
    action :list_sessions_for, :map do
      constraints fields: [
                    sessions: [
                      type: {:array, :map},
                      allow_nil?: false,
                      constraints: [items: [fields: @session_summary_fields]]
                    ],
                    next_cursor: [type: :string, allow_nil?: true]
                  ]

      argument :mount_key, :string, allow_nil?: false
      argument :cursor, :string, allow_nil?: true

      run fn input, _ctx ->
        %{mount_key: mount_key} = input.arguments
        cursor = Map.get(input.arguments, :cursor)
        {:ok, Valea.Agents.list_sessions_for(mount_key, cursor)}
      end
    end

    # Task 6.3 — follow-up inherits the ORIGINAL session's own primary ICM
    # (never a caller-supplied `mount_key`); see `Valea.Agents.
    # create_follow_up/2`'s moduledoc for the full error-mapping rationale
    # (`original_not_found` / `icm_unavailable` / `workspace_changed`, all
    # covered for free by `error_for/1`'s generic atom clause below).
    action :create_follow_up, :map do
      constraints fields: [id: [type: :string, allow_nil?: false]]

      argument :session_id, :string, allow_nil?: false
      argument :generation, :integer, allow_nil?: false

      run fn input, _ctx ->
        %{session_id: session_id, generation: generation} = input.arguments

        case Valea.Agents.create_follow_up(session_id, generation) do
          {:ok, %{id: id}} -> {:ok, %{id: id}}
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :harness_doctor, :map do
      constraints fields: [
                    ok: [type: :boolean, allow_nil?: false],
                    checks: [
                      type: {:array, :map},
                      allow_nil?: false,
                      constraints: [
                        items: [
                          fields: [
                            id: [type: :string, allow_nil?: false],
                            status: [type: :string, allow_nil?: false],
                            detail: [type: :string, allow_nil?: false],
                            remedy: [type: :string, allow_nil?: true]
                          ]
                        ]
                      ]
                    ]
                  ]

      run fn _input, _ctx ->
        {:ok, %{checks: checks, ok: ok}} = Valea.Agents.Doctor.run()
        # STRING keys at the TOP level (not atom, unlike every other action
        # in this file) — ash_typescript 0.17.3's generic-action result
        # extraction resolves no field-mapping module for `:map`-returning
        # actions, so it falls through to its untyped-map path, whose
        # `Map.get(value, field_atom) || Map.get(value, to_string(field_atom))`
        # treats a legitimate `false` as "absent" and nulls it out UNLESS the
        # atom lookup misses entirely (i.e. the map has no atom key at all)
        # and the string lookup is what actually finds the value. `ok` is the
        # one field here that can genuinely be `false` (adapter/auth checks
        # failing) — see `Valea.Api.Mail`'s moduledoc (`mail_doctor`'s `ok`)
        # for the identical note.
        {:ok, %{"ok" => ok, "checks" => Enum.map(checks, &atomize_check/1)}}
      end
    end
  end

  @doc false
  # Central error mapping for every action in this resource — mirrors
  # `Valea.Api.ICM.error_for/1`. `:no_workspace` becomes the frontend's
  # `"workspace_not_open"`; every other atom this resource's dependencies can
  # return (`:workspace_changed`, `:harness_unavailable`, `:input_unavailable`,
  # `:input_not_found`, `:not_found`, ...) already stringifies to the exact
  # code the frontend expects, so the generic atom clause covers them without
  # individual case clauses.
  def error_for(:no_workspace), do: Error.new("workspace_not_open")
  def error_for(reason) when is_atom(reason), do: Error.new(to_string(reason))
  def error_for(reason), do: Error.new(inspect(reason))

  # Spec D §B fail-closed resolution: a named context that cannot be
  # resolved to a real file aborts session creation with a stable atom the
  # FE renders inline — never a session that silently lacks its context.
  defp resolve_session_input(nil, _workspace), do: {:ok, nil}

  defp resolve_session_input(locator, workspace) do
    case Valea.Icm.Locator.resolve(workspace, locator) do
      {:ok, abs} -> if File.regular?(abs), do: {:ok, abs}, else: {:error, :input_unavailable}
      {:error, _reason} -> {:error, :input_unavailable}
    end
  end

  defp resolve_context_doc(nil, _workspace), do: {:ok, nil}

  defp resolve_context_doc(locator, workspace) do
    case Valea.Icm.Locator.resolve(workspace, locator) do
      {:ok, abs} ->
        if File.regular?(abs), do: {:ok, locator}, else: {:error, :context_doc_unavailable}

      {:error, _reason} ->
        {:error, :context_doc_unavailable}
    end
  end

  # `Valea.Agents.list_sessions/0` returns string-keyed maps (built for JSON
  # transcript metadata); typed action returns need atom keys matching the
  # `constraints fields:` declaration above (see `Valea.Api.ICM.references/1`
  # for the same pattern).
  defp atomize_session(s) do
    %{
      id: s["id"],
      kind: s["kind"],
      title: s["title"],
      workflow: s["workflow"],
      run_id: s["run_id"],
      started_at: s["started_at"],
      status: s["status"],
      live: s["live"]
    }
  end

  defp atomize_check(%{"id" => id, "status" => status, "detail" => detail, "remedy" => remedy}) do
    %{id: id, status: status, detail: detail, remedy: remedy}
  end
end
