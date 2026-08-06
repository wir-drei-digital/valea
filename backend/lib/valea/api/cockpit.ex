defmodule Valea.Api.Cockpit do
  @moduledoc """
  Data-layer-less Ash resource exposing the Today cockpit payload over RPC.

  Wraps `Valea.Cockpit`; the underlying module returns a string-keyed,
  JSON-ready map, and `check_fields/2` (`Ash.Type.Map`'s constraint
  enforcement) accepts a string key wherever an atom key is declared here
  (`fetch_field/2` falls back from the atom to `to_string/1` of it) — so no
  extra stringify/atomize step is needed on either side of this boundary.

  `:today`'s return is FULLY `constraints fields: [...]`-typed (every field
  `Valea.Cockpit.today/0` carries) — same convention as
  `Valea.Api.ICM`/`Valea.Api.Mail`: a fixed, known shape
  gets typed (and ash_typescript-camelCased); only genuinely
  heterogeneous/arbitrary content stays an unconstrained `:map` (none of
  which exists on this action). Ash's `Ash.Type.Map` `fields:` constraint
  is all-or-nothing per its own doc ("If constraints are specified, only
  those fields will be in the casted map") — so every top-level key
  `Valea.Cockpit.today/0` returns must be declared here.

  `sections[].tasks` and `calendar` are the two NULLABLE nested maps: each is
  its own lenient read (`tasks.json`, the calendar query) whose failure
  degrades to `nil` instead of failing the payload — see `Valea.Cockpit`.

  One ash_typescript asymmetry the frontend has to know about (pinned by
  `test/valea_web/rpc_test.exs`): the runtime extraction renames fields of
  ARRAY items (`sections[].mount_key` → `mountKey`) but hands a nested plain
  `:map` back with its SOURCE keys — so `calendar` arrives as `events_today`
  and `tasks` as `due_today`/`in_progress`, even though the emitted TS types
  camelCase both. `lib/today/cockpit.ts` normalizes either spelling for
  exactly this reason; nothing here can fix it without giving up the typed
  declaration.

  `sections[].tasks.top[].today` and `recent_sessions[].live` are NESTED
  typed booleans
  (inside their own item's `constraints fields: [...]`), declared with a
  plain atom key like every other field here — the top-level generic-action
  boolean/falsy workaround documented in `Valea.Api.Mail`'s moduledoc
  (ash_typescript 0.17.3 nulls a top-level atom-keyed `false`) only applies to a field
  sitting directly on the ACTION's own returned map, not to a boolean
  nested inside an array item's map — so neither needs a string-key trick
  at THIS layer. The string-keyed source maps `Valea.Cockpit.today/0`
  builds are still what makes a legitimate `false` survive the underlying
  `check_fields/2` extraction in the first place (see that module's own
  moduledoc for why the source stays string-keyed throughout).
  """
  use Ash.Resource, domain: Valea.Api, extensions: [AshTypescript.Resource]

  typescript do
    type_name("Cockpit")
  end

  actions do
    action :today, :map do
      constraints fields: [
                    sections: [
                      type: {:array, :map},
                      allow_nil?: false,
                      constraints: [
                        items: [
                          fields: [
                            mount_key: [type: :string, allow_nil?: false],
                            icm_name: [type: :string, allow_nil?: false],
                            # Today/Tasks redesign (2026-08-06): the state of
                            # the ICM's `today.json` — "present" | "absent" |
                            # "unreadable" — which RETIRED the `ok` boolean.
                            # A section now exists for every enabled ICM, so
                            # the field says what happened to the briefing
                            # file instead of the section's existence saying
                            # it (and hiding the tasks line with it).
                            today_json: [type: :string, allow_nil?: false],
                            updated_at: [type: :string, allow_nil?: true],
                            notes: [type: :string, allow_nil?: true],
                            prepared: [
                              type: {:array, :map},
                              allow_nil?: false,
                              constraints: [
                                items: [
                                  fields: [
                                    title: [type: :string, allow_nil?: true],
                                    summary: [type: :string, allow_nil?: true],
                                    page: [type: :string, allow_nil?: true]
                                  ]
                                ]
                              ]
                            ],
                            # tasks+schedules spec §UI surfaces → Cockpit: the
                            # tasks line that REPLACED `open_loops`. Nullable
                            # BY DESIGN — a malformed `tasks.json` degrades to
                            # nil (the FE's calm note) while the section itself
                            # stays `ok`, exactly like the calendar line's own
                            # leniency.
                            tasks: [
                              type: :map,
                              allow_nil?: true,
                              constraints: [
                                fields: [
                                  due_today: [type: :integer, allow_nil?: false],
                                  overdue: [type: :integer, allow_nil?: false],
                                  in_progress: [type: :integer, allow_nil?: false],
                                  top: [
                                    type: {:array, :map},
                                    allow_nil?: false,
                                    constraints: [
                                      items: [
                                        fields: [
                                          id: [type: :string, allow_nil?: true],
                                          title: [type: :string, allow_nil?: true],
                                          due: [type: :string, allow_nil?: true],
                                          today: [type: :boolean, allow_nil?: false],
                                          priority: [type: :string, allow_nil?: true]
                                        ]
                                      ]
                                    ]
                                  ]
                                ]
                              ]
                            ]
                          ]
                        ]
                      ]
                    ],
                    # ICM git sync spec §UI (Today): the sync rows, UNTYPED
                    # on purpose. Their shape belongs to
                    # `Valea.Git.Engine.public_rows/1` — the same rows the
                    # `git_status` RPC and the `"git_status"` channel push
                    # carry — and restating fifteen fields here would give
                    # this layer a second, drifting copy of that contract for
                    # no gain: array items keep their source (snake_case)
                    # keys and their `false`s either way.
                    git: [type: {:array, :map}, allow_nil?: false],
                    mail: [
                      type: {:array, :map},
                      allow_nil?: false,
                      constraints: [
                        items: [
                          fields: [
                            account: [type: :string, allow_nil?: false],
                            configured: [type: :boolean, allow_nil?: false],
                            state: [type: :string, allow_nil?: false],
                            pending_ops: [type: :integer, allow_nil?: false],
                            notices: [
                              type: {:array, :string},
                              allow_nil?: false
                            ],
                            unread_count: [type: :integer, allow_nil?: false],
                            unread: [
                              type: {:array, :map},
                              allow_nil?: false,
                              constraints: [
                                items: [
                                  fields: [
                                    msg_id: [type: :string, allow_nil?: false],
                                    from_name: [type: :string, allow_nil?: true],
                                    from_email: [type: :string, allow_nil?: true],
                                    subject: [type: :string, allow_nil?: true],
                                    date: [type: :string, allow_nil?: true]
                                  ]
                                ]
                              ]
                            ]
                          ]
                        ]
                      ]
                    ],
                    # Spec F Task 6 (§UI, Today page): the calendar line.
                    # Nullable BY DESIGN — `Valea.Cockpit.calendar_summary/0`
                    # is lenient like "mail" and degrades to nil on any
                    # failure; `next` is nil when nothing timed is still
                    # ahead of now.
                    calendar: [
                      type: :map,
                      allow_nil?: true,
                      constraints: [
                        fields: [
                          events_today: [type: :integer, allow_nil?: false],
                          next: [
                            type: :map,
                            allow_nil?: true,
                            constraints: [
                              fields: [
                                time: [type: :string, allow_nil?: false],
                                title: [type: :string, allow_nil?: false]
                              ]
                            ]
                          ]
                        ]
                      ]
                    ],
                    recent_sessions: [
                      type: {:array, :map},
                      allow_nil?: false,
                      constraints: [
                        items: [
                          fields: [
                            id: [type: :string, allow_nil?: false],
                            title: [type: :string, allow_nil?: false],
                            started_at: [type: :string, allow_nil?: false],
                            status: [type: :string, allow_nil?: false],
                            live: [type: :boolean, allow_nil?: false]
                          ]
                        ]
                      ]
                    ],
                    # tasks+schedules spec §UI surfaces → Cockpit: notices ONLY
                    # for schedules (parked run, failed run, newly registered),
                    # never a "next run" line. No captured output rides here —
                    # `schedule_run_history` is the surface that carries it.
                    schedule_notices: [
                      type: {:array, :map},
                      allow_nil?: false,
                      constraints: [
                        items: [
                          fields: [
                            kind: [type: :string, allow_nil?: false],
                            mount_key: [type: :string, allow_nil?: true],
                            schedule_id: [type: :string, allow_nil?: false],
                            title: [type: :string, allow_nil?: false],
                            at: [type: :string, allow_nil?: true]
                          ]
                        ]
                      ]
                    ]
                  ]

      run fn _input, _ctx ->
        {:ok, today} = Valea.Cockpit.today()
        {:ok, today}
      end
    end
  end
end
