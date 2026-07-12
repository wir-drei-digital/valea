defmodule Valea.Api.Cockpit do
  @moduledoc """
  Data-layer-less Ash resource exposing the seeded Cockpit narrative over RPC.

  Wraps `Valea.Cockpit`; the underlying module returns a string-keyed,
  JSON-ready map, and `check_fields/2` (`Ash.Type.Map`'s constraint
  enforcement) accepts a string key wherever an atom key is declared here
  (`fetch_field/2` falls back from the atom to `to_string/1` of it) — so no
  extra stringify/atomize step is needed on either side of this boundary.

  `:today`'s return is FULLY `constraints fields: [...]`-typed (every field
  the seeded narrative carries, not just a subset) — same convention as
  `Valea.Api.ICM`/`Valea.Api.Queue`/`Valea.Api.Mail`: a fixed, known shape
  gets typed (and ash_typescript-camelCased); only genuinely
  heterogeneous/arbitrary content stays an unconstrained `:map` (none of
  which exists on this action). Ash's `Ash.Type.Map` `fields:` constraint
  is all-or-nothing per its own doc ("If constraints are specified, only
  those fields will be in the casted map") — so every top-level key
  `Valea.Cockpit.today/0` returns must be declared here, not only the new
  `mail` one Task 18 adds.

  `mail.configured` is a NESTED typed boolean (inside the `mail` sub-map's
  own `constraints fields: [...]`), so it's declared with a plain atom key
  like every other field here. The top-level generic-action boolean/falsy
  workaround documented in `Valea.Api.Queue.reject_item`/`Valea.Api.Mail`'s
  moduledoc (ash_typescript 0.17.3 nulls a top-level atom-keyed `false`) only
  applies to a field sitting directly on the ACTION's own returned map —
  `mail` itself is such a field (a map, never falsy), but `configured`
  nested inside it is not, so it needs no string-key trick.

  `triage_workflow_path` (Task A-T13) is a top-level, NILABLE `:string` —
  the falsy-map-field bug documented above is specific to `:boolean`'s
  `false` (ash_typescript's own generic-action result handling), not to a
  `nil` string, so this needs no string-key workaround either; it
  camelCases to `triageWorkflowPath` like every other field here.

  `distill_workflow_path` (Task B8) is the same shape, mirroring
  `triage_workflow_path` exactly — camelCases to `distillWorkflowPath`.
  """
  use Ash.Resource, domain: Valea.Api, extensions: [AshTypescript.Resource]

  typescript do
    type_name("Cockpit")
  end

  actions do
    action :today, :map do
      constraints fields: [
                    workspace: [type: :string, allow_nil?: false],
                    date_label: [type: :string, allow_nil?: false],
                    greeting: [type: :string, allow_nil?: false],
                    summary: [type: :string, allow_nil?: false],
                    schedule: [
                      type: {:array, :map},
                      allow_nil?: false,
                      constraints: [
                        items: [
                          fields: [
                            time: [type: :string, allow_nil?: false],
                            title: [type: :string, allow_nil?: false],
                            subtitle: [type: :string, allow_nil?: false],
                            status: [type: :string, allow_nil?: true]
                          ]
                        ]
                      ]
                    ],
                    prepared_items: [
                      type: {:array, :map},
                      allow_nil?: false,
                      constraints: [
                        items: [
                          fields: [
                            type: [type: :string, allow_nil?: false],
                            title: [type: :string, allow_nil?: false],
                            summary: [type: :string, allow_nil?: false],
                            used_sources: [type: {:array, :string}, allow_nil?: false],
                            primary_action: [type: :string, allow_nil?: false],
                            secondary_action: [type: :string, allow_nil?: true]
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
                            title: [type: :string, allow_nil?: false],
                            source: [type: :string, allow_nil?: false]
                          ]
                        ]
                      ]
                    ],
                    while_you_were_away: [type: {:array, :string}, allow_nil?: false],
                    triage_workflow_path: [type: :string, allow_nil?: true],
                    distill_workflow_path: [type: :string, allow_nil?: true],
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
                    ]
                  ]

      run fn _input, _ctx ->
        {:ok, today} = Valea.Cockpit.today()
        {:ok, today}
      end
    end
  end
end
