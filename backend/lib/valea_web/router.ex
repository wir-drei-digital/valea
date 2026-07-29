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

  # PARTLY token-exempt, which is why it cannot use `ValeaWeb.Plugs.
  # ControlToken` as a pipeline plug: the controller performs that same
  # check itself, for image extensions ONLY it skips it (an `<img>` tag
  # cannot send headers), and every failure is the route's opaque 404
  # rather than the plug's 401. See `ValeaWeb.FilesController`'s moduledoc
  # — "The serve route's split credential" — plus the containment story.
  scope "/files", ValeaWeb do
    pipe_through :api
    get "/raw", FilesController, :serve
  end

  # Deliberately token-EXEMPT — a calendar app's subscription fetcher
  # cannot send headers; the feed carries its own credential (`?token=`,
  # hash-compared constant-time by the controller) on the 127.0.0.1
  # listener. Same arrangement as the files `:serve` scope above, minus
  # `:accepts` — subscription clients send `Accept: text/calendar` (or
  # nothing), and the response type is fixed server-side. See
  # `ValeaWeb.CalendarFeedController`.
  scope "/calendar", ValeaWeb do
    get "/feed.ics", CalendarFeedController, :feed
  end

  # SPA catch-all (static build baked into priv/static in `just build`).
  scope "/", ValeaWeb do
    get "/*path", SpaController, :index
  end
end
