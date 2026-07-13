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

  # Image upload shares the RPC surface's token gate — mirrors the `:rpc`
  # pipeline (named separately since it lives in its own `/files` scope,
  # not `/rpc`).
  pipeline :files_upload do
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

  scope "/files", ValeaWeb do
    pipe_through :files_upload
    post "/upload", FilesController, :upload
  end

  # Deliberately token-EXEMPT — an `<img>` tag cannot send headers, and this
  # is a 127.0.0.1 listener serving only files local processes could already
  # read. See `ValeaWeb.FilesController` moduledoc for the containment story.
  scope "/files", ValeaWeb do
    pipe_through :api
    get "/raw", FilesController, :serve
  end

  # SPA catch-all (static build baked into priv/static in `just build`).
  scope "/", ValeaWeb do
    get "/*path", SpaController, :index
  end
end
