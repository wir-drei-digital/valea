import Config
import Dotenvy

env_dir = System.get_env("RELEASE_ROOT") || Path.expand(".")
source!([Path.join(env_dir, ".env"), System.get_env()])

if System.get_env("PHX_SERVER") do
  config :valea, ValeaWeb.Endpoint, server: true
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
