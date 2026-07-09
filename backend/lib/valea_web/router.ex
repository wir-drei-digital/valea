defmodule ValeaWeb.Router do
  use Phoenix.Router, helpers: false

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", ValeaWeb do
    pipe_through :api
    get "/health", HealthController, :show
  end

  # ash_typescript RPC routes added in Task 11.

  # SPA catch-all (static build baked into priv/static in `just build`).
  scope "/", ValeaWeb do
    get "/*path", SpaController, :index
  end
end
