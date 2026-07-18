# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :valea, ecto_repos: [Valea.Repo]

config :ash,
  allow_forbidden_field_for_relationships_by_default?: true,
  include_embedded_source_by_default?: false,
  show_keysets_for_all_actions?: false,
  default_page_type: :keyset,
  policies: [no_filter_static_forbidden_reads?: false],
  keep_read_action_loads_when_loading?: false,
  default_actions_require_atomic?: true,
  read_action_after_action_hooks_in_order?: true,
  bulk_actions_default_to_errors?: true,
  transaction_rollback_on_error?: true,
  redact_sensitive_values_in_errors?: true

config :spark,
  formatter: [
    remove_parens?: true,
    "Ash.Resource": [
      section_order: [
        :json_api,
        :resource,
        :code_interface,
        :actions,
        :policies,
        :pub_sub,
        :preparations,
        :changes,
        :validations,
        :multitenancy,
        :attributes,
        :relationships,
        :calculations,
        :aggregates,
        :identities
      ]
    ],
    "Ash.Domain": [
      section_order: [:json_api, :resources, :policies, :authorization, :domain, :execution]
    ]
  ]

config :valea, ash_domains: [Valea.Api, Valea.Mail.Store, Valea.Calendar.Store]

config :ash_typescript,
  output_file: "../frontend/src/lib/api/ash_rpc.ts",
  run_endpoint: "/rpc/run",
  validate_endpoint: "/rpc/validate",
  input_field_formatter: :camel_case,
  output_field_formatter: :camel_case,
  generate_phx_channel_rpc_actions: true,
  phoenix_import_path: "phoenix"

# Configure the endpoint
config :valea, ValeaWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: ValeaWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Valea.PubSub,
  live_view: [signing_salt: "+JFtBCHL"]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Full IANA time-zone database for the calendar subsystem. TZID resolution,
# DST-transition determinism, and floating-time resolution against the host
# zone all go through Elixir's DateTime API, which needs a real database.
config :elixir, :time_zone_database, Tzdata.TimeZoneDatabase

# codepagex ships every code page it knows about behind a compile flag —
# without this, `mix compile` regenerates modules for all of them (slow,
# and pulls in a bunch of legacy encodings Valea never needs). The mail
# normalizer only ever falls back to Latin-1 / Windows-1252, so only those
# two encoding tables are compiled in.
config :codepagex, :encodings, [:iso_8859_1, "VENDORS/MICSFT/WINDOWS/CP1252"]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
