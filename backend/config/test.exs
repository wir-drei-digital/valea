import Config
config :ash, policies: [show_policy_breakdowns?: true], disable_async?: true

# No repo/database config here — tests open tmp workspaces (Task 7) rather
# than relying on a static test database.

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :valea, ValeaWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "Ah8utsZhD3fwDbacHdFV9JhxgB93r3J2hAc2PdPj+KamedpC2m0J4Q98Nq3PWSmZ",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# IMAP IDLE off by default in test (`Valea.Mail.Engine`, §IMAP IDLE): an
# Engine that starts a `Valea.Mail.IdleWatcher` opens a SECOND connection
# through the same injected transport, which would perturb every suite that
# scripts that transport call-for-call or reports each connect to a probe pid.
# The tests that exercise IDLE turn it back on for themselves.
config :valea, mail_idle: false

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
