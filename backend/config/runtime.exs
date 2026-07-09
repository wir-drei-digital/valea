import Config
import Dotenvy

env_dir = System.get_env("RELEASE_ROOT") || Path.expand(".")
source!([Path.join(env_dir, ".env"), System.get_env()])

if System.get_env("PHX_SERVER") do
  config :valea, ValeaWeb.Endpoint, server: true
end

if config_env() == :dev do
  config :valea, ValeaWeb.Endpoint, http: [port: env!("PORT", :integer, 4200)]
end

if config_env() == :prod do
  port = env!("PORT", :integer, 4817)

  config :valea, ValeaWeb.Endpoint,
    url: [host: "localhost", port: port, scheme: "http"],
    http: [ip: {127, 0, 0, 1}, port: port],
    check_origin: [
      "//localhost",
      "tauri://localhost",
      "http://tauri.localhost",
      "https://tauri.localhost"
    ],
    secret_key_base: env!("SECRET_KEY_BASE", :string)
end
