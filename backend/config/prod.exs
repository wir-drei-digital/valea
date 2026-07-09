import Config

# Force using SSL in production. This also sets the "strict-security-transport" header,
# known as HSTS. If you have a health check endpoint, you may want to exclude it below.
# Note `:force_ssl` is required to be set at compile-time.
config :valea, ValeaWeb.Endpoint,
  force_ssl: [
    rewrite_on: [:x_forwarded_proto],
    # Keep loopback excluded from the HTTPS redirect — the desktop app runs
    # the prod release over plain HTTP on localhost.
    exclude: [hosts: ["localhost", "127.0.0.1"]]
  ]

# Do not print debug messages in production
config :logger, level: :info

# Runtime production configuration, including reading
# of environment variables, is done on config/runtime.exs.
