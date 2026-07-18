defmodule ValeaWeb.CalendarFeedController do
  @moduledoc """
  The served Valea-calendar feed (calendar spec F, §The served feed):
  `GET /calendar/feed.ics?token=<plain token>` on the loopback endpoint.

  Deliberately token-EXEMPT from the control token — calendar apps
  cannot send headers — so the feed carries its OWN credential: the
  request token's sha256 hex is compared constant-time
  (`Plug.Crypto.secure_compare/2`) against the hash `config/
  calendar.yaml` stores (`Valea.Calendar.Settings` — this controller
  only READS the stored hash; generation/rotation happen exclusively
  through `Settings.generate_feed_token/1`). The plain token is never
  persisted, so possession of the config file alone never authenticates.

  Serves ONLY the rendered VALID `valea/events/*.md` files
  (`Valea.Calendar.Local.list/1` → `Valea.Calendar.Render.feed/1`) —
  external mirrors are never served, so the endpoint cannot become an
  exfiltration path for the user's provider data. NO other parameters
  are honored: a request carrying anything besides exactly `token` is
  refused. EVERY failure — no workspace, absent config, invalid config,
  no token configured, missing/malformed/wrong token — is the same
  404 with an empty body, no detail.
  """
  use Phoenix.Controller, formats: []

  alias Valea.Calendar.Local
  alias Valea.Calendar.Render
  alias Valea.Calendar.Settings
  alias Valea.Workspace.Manager

  def feed(conn, params) do
    with {:ok, token} <- sole_token_param(params),
         {:ok, ws} <- workspace_root(),
         {:ok, %Settings{feed_token_hash: stored}} when is_binary(stored) <- Settings.load(ws),
         true <- Plug.Crypto.secure_compare(sha256_hex(token), stored) do
      %{valid: events} = Local.list(ws)

      conn
      |> put_resp_content_type("text/calendar")
      |> send_resp(200, Render.feed(events))
    else
      _any_failure -> send_resp(conn, 404, "")
    end
  rescue
    # A feed endpoint never explains itself — any unexpected error is the
    # same empty 404 as a bad token.
    _error -> send_resp(conn, 404, "")
  end

  # Exactly ONE parameter, exactly `token`, exactly a binary — the route
  # takes no other parameters, so extra ones refuse rather than being
  # silently ignored.
  defp sole_token_param(%{"token" => token} = params)
       when is_binary(token) and map_size(params) == 1,
       do: {:ok, token}

  defp sole_token_param(_params), do: :error

  defp sha256_hex(token),
    do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

  defp workspace_root do
    case Manager.current() do
      {:ok, %{path: ws}} -> {:ok, ws}
      {:error, :no_workspace} -> {:error, :no_workspace}
    end
  end
end
