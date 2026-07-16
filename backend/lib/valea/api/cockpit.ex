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

  `sections[].ok` and `recent_sessions[].live` are NESTED typed booleans
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
                            ok: [type: :boolean, allow_nil?: false],
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
                            open_loops: [
                              type: {:array, :map},
                              allow_nil?: false,
                              constraints: [
                                items: [
                                  fields: [
                                    title: [type: :string, allow_nil?: true],
                                    source: [type: :string, allow_nil?: true]
                                  ]
                                ]
                              ]
                            ]
                          ]
                        ]
                      ]
                    ],
                    mail: [
                      type: :map,
                      allow_nil?: false,
                      constraints: [
                        fields: [
                          review_count: [type: :integer, allow_nil?: false],
                          inbox_count: [type: :integer, allow_nil?: false],
                          configured: [type: :boolean, allow_nil?: false]
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
                    ]
                  ]

      run fn _input, _ctx ->
        {:ok, today} = Valea.Cockpit.today()
        {:ok, today}
      end
    end
  end
end
