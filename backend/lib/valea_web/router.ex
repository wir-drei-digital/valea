defmodule ValeaWeb.Router do
  use Phoenix.Router, helpers: false

  pipeline :api do
    plug :accepts, ["json"]
  end

  # The control-plane RPC surface additionally requires the per-launch token.
  # `/api/health` and the SPA catch-all deliberately stay on the token-free
  # `:api`/default pipelines — health is the readiness probe, and the SPA is
  # what CARRIES the token to the client.
  pipeline :rpc do
    plug :accepts, ["json"]
    plug ValeaWeb.Plugs.ControlToken
  end

  scope "/api", ValeaWeb do
    pipe_through :api
    get "/health", HealthController, :show
  end

  scope "/rpc", ValeaWeb do
    pipe_through :rpc
    post "/run", RpcController, :run
    post "/validate", RpcController, :validate
  end

  # SPA catch-all (static build baked into priv/static in `just build`).
  scope "/", ValeaWeb do
    get "/*path", SpaController, :index
  end
end
