defmodule ValeaWeb.OAuthCallbackController do
  @moduledoc """
  The mailbox sign-in redirect target (mail full-client plan, M6 task 16):
  `GET /oauth/callback?code=…&state=…` on the loopback endpoint.

  Deliberately token-EXEMPT from the control token — an OAuth2 provider
  redirects a BROWSER here and cannot send headers — exactly the arrangement
  `/calendar/feed.ics` already uses. Its credential is the `state` token:
  minted per flow by `Valea.Mail.Engine.start_oauth/1`, compared
  constant-time, single-use, TTL-bounded, and inherently bound to the account
  that minted it (one pending slot per Engine).

  ## What this endpoint can and cannot do

  It RENDERS a page. It never redirects: there is no caller-supplied URL
  anywhere in this module, so it cannot be turned into an open redirect. The
  page is a fixed string with no interpolation of anything from the request,
  so nothing from the query can reach the markup.

  The authorization code is spent server-side (`Valea.Mail.OAuth.exchange_code/3`
  over HTTPS with pinned verification), and the resulting refresh token goes
  straight into the account's Engine — RAM only — plus a `mail_oauth` push
  asking the desktop client to persist it in the OS keychain. Nothing about
  the exchange touches this workspace's files.

  ## Secrets and logging

  The query string of a request here IS a credential. Three things keep it out
  of the log:

    * the route carries `log: false`, which suppresses
      `Phoenix.Logger`'s route-dispatch line — the one that inspects
      `conn.params`. The endpoint-level line still records `GET
      /oauth/callback`, which has no query string in it;
    * `config :phoenix, :filter_parameters` names `code`/`state` and every
      token field anyway, so even a future logging path masks them;
    * no failure this module reports names a parameter, and the whole action
      is wrapped in a rescue that renders the same generic failure page —
      an exception here must not reach `Plug.Debugger`, which renders params.

  ## Failure posture

  Unlike the calendar feed's uniform 404, this page is for a HUMAN who just
  clicked "allow" and deserves to know whether it worked. So the outcomes are
  distinguishable in COPY but never in detail: a provider-side refusal (the
  `error` parameter), a state that didn't match or had aged out, and a failed
  code exchange each render an honest sentence and a 400. Every one of them
  first CONSUMES the pending flow, so a failed or replayed redirect can never
  be retried against a still-live authorization.
  """
  use Phoenix.Controller, formats: []

  alias Valea.Mail.Engine
  alias Valea.Mail.OAuth

  def callback(conn, params) do
    case outcome(params) do
      :ok -> render_page(conn, 200, success_page())
      {:error, reason} -> render_page(conn, 400, failure_page(reason))
    end
  rescue
    # Nothing is logged and nothing is re-raised: a stack trace from this
    # action can quote the request, and in dev `Plug.Debugger` would render
    # the params outright.
    _error -> render_page(conn, 400, failure_page(:failed))
  end

  # The whole decision, in the order the checks have to happen: a redirect
  # without a usable `state` cannot be attributed to any account at all, so it
  # is refused before anything else — including a provider `error`, which is
  # only actionable once we know which flow to clear.
  defp outcome(params) do
    with {:ok, state} <- fetch_state(params),
         {:ok, flow} <- claim(state, params),
         {:ok, code} <- fetch_param(params, "code"),
         {:ok, tokens} <- exchange(flow, code) do
      store(flow, tokens)
    end
  end

  # A redirect with no usable `state` is indistinguishable, from here, from one
  # whose state matches nothing: either way Valea cannot attribute it to a
  # pending authorization, which is what the `:no_flow` page says.
  defp fetch_state(params) do
    case fetch_param(params, "state") do
      {:ok, state} -> {:ok, state}
      {:error, :missing} -> {:error, :no_flow}
    end
  end

  # Consuming the flow is the FIRST thing done with a matched state, before the
  # provider's own `error` parameter is even looked at: whatever else this
  # redirect turns out to be, that authorization is spent.
  defp claim(state, params) do
    with {:ok, flow} <- Engine.claim_oauth_flow(state) do
      case fetch_param(params, "error") do
        {:ok, _provider_error} -> {:error, :denied}
        {:error, :missing} -> {:ok, flow}
      end
    end
  end

  defp exchange(flow, code) do
    case OAuth.exchange_code(flow, code) do
      {:ok, tokens} -> {:ok, tokens}
      {:error, _reason} -> {:error, :failed}
    end
  end

  defp store(flow, tokens) do
    case Engine.store_oauth_refresh_token(flow.account, tokens.refresh_token) do
      :ok -> :ok
      # The Engine went away between the claim and the store (a workspace
      # close). There is nothing to store the token in, and nothing durable
      # was written, so this is an honest failure rather than a silent one.
      {:error, :not_found} -> {:error, :failed}
    end
  end

  defp fetch_param(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _absent -> {:error, :missing}
    end
  end

  # -- the page ---------------------------------------------------------------

  defp render_page(conn, status, body) do
    conn
    |> put_resp_content_type("text/html")
    |> put_resp_header("x-content-type-options", "nosniff")
    # A page rendered off a URL that carried a credential must not be cached
    # or kept in the browser's back/forward store.
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> send_resp(status, body)
  end

  defp success_page do
    page("Signed in", "Signed in — you can return to Valea.", "This window can be closed.")
  end

  defp failure_page(:denied),
    do:
      page(
        "Sign-in cancelled",
        "Sign-in was not completed.",
        "Your mail provider did not grant access. Return to Valea and try again."
      )

  defp failure_page(:expired),
    do:
      page(
        "Sign-in expired",
        "This sign-in took too long.",
        "Return to Valea and start the sign-in again."
      )

  defp failure_page(:no_flow),
    do:
      page(
        "Sign-in not recognized",
        "Valea is not waiting for this sign-in.",
        "It may already have been completed, or been started in another window. Return to Valea and check the account."
      )

  defp failure_page(_reason),
    do:
      page(
        "Sign-in failed",
        "Sign-in could not be completed.",
        "Return to Valea and try again."
      )

  # A FIXED page: every argument is a literal from this module, so no request
  # value is ever interpolated into markup. Self-contained — no script, no
  # external stylesheet, no image, nothing to fetch.
  defp page(title, heading, detail) do
    """
    <!DOCTYPE html>
    <html lang="en"><head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Valea — #{title}</title>
    <style>
      body { margin: 0; min-height: 100vh; display: flex; align-items: center; justify-content: center;
             background: #faf9f7; color: #26231f;
             font: 15px/1.55 ui-sans-serif, system-ui, -apple-system, "Segoe UI", sans-serif; }
      main { max-width: 26rem; padding: 2rem; text-align: center; }
      h1 { margin: 0 0 .5rem; font-size: 1.25rem; font-weight: 600; }
      p { margin: 0; color: #6b655e; }
      @media (prefers-color-scheme: dark) {
        body { background: #1b1a18; color: #ece8e3; }
        p { color: #a8a29a; }
      }
    </style>
    </head><body><main>
    <h1>#{heading}</h1>
    <p>#{detail}</p>
    </main></body></html>
    """
  end
end
