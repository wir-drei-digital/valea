import Config
import Dotenvy

env_dir = System.get_env("RELEASE_ROOT") || Path.expand(".")
source!([Path.join(env_dir, ".env"), System.get_env()])

if System.get_env("PHX_SERVER") do
  config :valea, ValeaWeb.Endpoint, server: true
end

# Test runs must never touch the developer's real app-data directory
# (~/Library/Application Support/valea on macOS): Valea.Workspace.Manager
# auto-opens whatever `last_opened` workspace is recorded there at boot, and
# a real leftover workspace from manual/browser-preview testing on the same
# machine collides with named-process tests (e.g. Valea.Workspace.Runtime,
# started under a fixed name) or simply makes the suite depend on host
# state. Default to a fresh ephemeral dir per test run unless the caller
# already set VALEA_APP_DIR explicitly (individual tests still override it
# per-case via System.put_env for App.Config-specific behavior).
if config_env() == :test and System.get_env("VALEA_APP_DIR") == nil do
  System.put_env(
    "VALEA_APP_DIR",
    Path.join(System.tmp_dir!(), "valea-test-app-dir-#{System.os_time(:nanosecond)}")
  )
end

# Per-launch control token (see ValeaWeb.Plugs.ControlToken). The desktop
# shell generates a fresh random token each launch and passes it in via env;
# dev/test fall back to a fixed value so browser dev keeps working. A missing
# token in prod is fatal — better to fail boot than accept every request.
control_token =
  System.get_env("VALEA_CONTROL_TOKEN") ||
    if config_env() == :prod do
      raise "VALEA_CONTROL_TOKEN must be set in production"
    else
      "valea-dev-token"
    end

config :valea,
  control_token: control_token,
  ready_nonce: System.get_env("VALEA_READY_NONCE")

if config_env() == :dev do
  config :valea, ValeaWeb.Endpoint, http: [port: env!("PORT", :integer, 4200)]
end

if config_env() == :prod do
  port = env!("PORT", :integer, 4817)

  config :valea, ValeaWeb.Endpoint,
    url: [host: "localhost", port: port, scheme: "http"],
    http: [ip: {127, 0, 0, 1}, port: port],
    # The desktop window loads the SPA same-origin from the sidecar, so
    # "//localhost" is what actually matches now; the tauri:// entries are kept
    # as harmless legacy origins.
    check_origin: [
      "//localhost",
      "tauri://localhost",
      "http://tauri.localhost",
      "https://tauri.localhost"
    ],
    secret_key_base: env!("SECRET_KEY_BASE", :string)
end
