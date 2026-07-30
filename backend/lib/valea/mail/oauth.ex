defmodule Valea.Mail.OAuth do
  @moduledoc """
  The OAuth2 half of modern mailbox sign-in (mail full-client plan, M6 task
  16): the two provider presets, the PKCE pair, the consent URL, and the two
  token-endpoint grants. Everything here is either pure or one HTTPS POST —
  no state, no process. Who HOLDS the resulting tokens is
  `Valea.Mail.Engine`'s job (RAM only, see its §Credentials), and who receives
  the redirect is `ValeaWeb.OAuthCallbackController`'s.

  ## Public clients, PKCE only

  Both presets are PUBLIC clients: there is no client secret anywhere in this
  codebase, in config, or on disk. A desktop app cannot keep one, and both
  providers support the public-client + PKCE (RFC 7636) shape that exists
  exactly for that case. `new_pkce/0` mints a 43-character base64url verifier
  from `:crypto.strong_rand_bytes/1` and its S256 challenge; the verifier
  never leaves the machine and is spent by exactly one `exchange_code/3`.

  ## Where the client ids come from

  A public client id is not a secret, but it IS per-installation: whoever
  ships or runs this build registers it with Google/Microsoft. `client_id_for/1`
  is the one resolution order:

    1. the account's own `oauth_client_id` in `config/mail.yaml` — the escape
       hatch that needs no rebuild, and the only way a user of a packaged
       build supplies their own;
    2. `config :valea, :mail_oauth, gmail: [client_id: ...], microsoft:
       [client_id: ...]` (`config/config.exs`), which ships `nil` — an
       unconfigured provider REFUSES to start a flow rather than sending the
       user to a consent screen that cannot work.

  ## Secrets and this module

  Nothing here logs, and no error this module returns carries a token, a
  code, a verifier, or a response body: every failure collapses to a bare
  atom (`:invalid_grant`, `:token_request_failed`, `:no_refresh_token`). That
  is deliberate — the token endpoint's error body can echo the credential it
  refused, and a `{:error, body}` would put it in whatever the caller does
  with an error (a `Logger.error`, a status `last_error` pushed to the UI).

  ## The HTTP seam

  `default_http_post/2` is the POST sibling of
  `Valea.Mail.Autoconfig.default_http_get/1` and carries the SAME TLS
  posture, deliberately spelled out rather than inherited from `:httpc`
  defaults: `verify: :verify_peer`, the system CA store
  (`:public_key.cacerts_get/0`), a depth limit, and the `:https` hostname
  match fun. Both grant functions take `opts[:http_post]` (the autoconfig
  convention) so tests drive them with no network; the default itself is
  overridable process-wide through `config :valea, :mail_oauth_http_post`,
  which is what the controller/engine suites use since they cannot pass opts
  through a real HTTP request.
  """

  @type provider :: :gmail | :microsoft

  @typedoc """
  Everything one in-flight authorization needs after its consent URL has been
  handed out — minted by the Engine, spent by the callback controller. The
  `state` token is deliberately NOT part of this: it has already done its
  single job (matching the redirect to this flow) by the time a caller holds
  one of these.
  """
  @type flow :: %{
          account: String.t(),
          provider: provider(),
          client_id: String.t(),
          redirect_uri: String.t(),
          verifier: String.t()
        }

  @typedoc """
  A successful grant. `refresh_token` is `nil` whenever the provider did not
  send one: Google omits it on every refresh (the original stays valid),
  while Microsoft ROTATES it on each refresh and the new one must replace the
  stored one or the next restart resupplies a dead token.
  """
  @type tokens :: %{
          access_token: String.t(),
          expires_in: non_neg_integer(),
          refresh_token: String.t() | nil
        }

  @http_timeout 8_000
  @connect_timeout 4_000

  # Google needs `access_type=offline` to issue a refresh token at all, and
  # `prompt=consent` so a re-authorization of an already-granted account gets
  # a fresh one rather than an access token alone. Microsoft asks for
  # `offline_access` as a SCOPE instead (see the preset) and needs nothing
  # extra here beyond pinning the response mode.
  @presets %{
    gmail: %{
      authorize_url: "https://accounts.google.com/o/oauth2/v2/auth",
      token_url: "https://oauth2.googleapis.com/token",
      scope: "https://mail.google.com/",
      authorize_extra: [{"access_type", "offline"}, {"prompt", "consent"}]
    },
    microsoft: %{
      authorize_url: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize",
      token_url: "https://login.microsoftonline.com/common/oauth2/v2.0/token",
      scope:
        "offline_access https://outlook.office.com/IMAP.AccessAsUser.All https://outlook.office.com/SMTP.Send",
      authorize_extra: [{"response_mode", "query"}]
    }
  }

  @doc "The two providers this build knows how to sign into."
  @spec providers() :: [provider()]
  def providers, do: Map.keys(@presets)

  @doc """
  The provider preset — endpoints, scope, and the provider-specific
  authorize parameters. `nil` for anything else, so a caller narrows before
  it can build a URL.
  """
  @spec preset(term()) :: map() | nil
  def preset(provider), do: Map.get(@presets, provider)

  @doc """
  Which preset an account can sign in with, from the provider
  `Valea.Mail.Settings.detect_provider/1` already resolved for it — `nil` for
  a `:generic` mailbox, which has no OAuth2 flow to offer.

  The host table itself deliberately lives in `Valea.Mail.Settings` (it also
  decides folder/sync defaults); this only narrows its answer to the presets
  above, so a future provider added there without a preset here is `nil`
  rather than a crash.
  """
  @spec provider_for(Valea.Mail.Settings.t()) :: provider() | nil
  def provider_for(%Valea.Mail.Settings{provider: provider}) do
    if Map.has_key?(@presets, provider), do: provider, else: nil
  end

  @doc """
  The public client id `account` authorizes with: its own `oauth_client_id`
  override when it has one, otherwise this build's configured id for its
  provider. `nil` when neither exists — the state in which no flow may start.

  THE resolution order (see the moduledoc), in one place, so the RPC path and
  the Engine's own token refresh can never disagree about which id an account
  is registered under — a refresh under a different client id than the
  authorization is an `invalid_grant`, i.e. a silently dead account.
  """
  @spec client_id_for(Valea.Mail.Settings.t()) :: String.t() | nil
  def client_id_for(%Valea.Mail.Settings{oauth_client_id: override} = settings) do
    case presence(override) do
      nil ->
        case provider_for(settings) do
          nil -> nil
          provider -> configured_client_id(provider)
        end

      client_id ->
        client_id
    end
  end

  @doc """
  The configured public client id for `provider` (`config :valea,
  :mail_oauth`), or `nil` when this build ships none. `client_id_for/1` is
  what callers want; this is its second step, public for tests.
  """
  @spec configured_client_id(provider()) :: String.t() | nil
  def configured_client_id(provider) when is_atom(provider) do
    :valea
    |> Application.get_env(:mail_oauth, [])
    |> Keyword.get(provider, [])
    |> Keyword.get(:client_id)
    |> presence()
  end

  @doc """
  A fresh PKCE pair (RFC 7636, S256). The verifier is 43 base64url characters
  — 32 `:crypto.strong_rand_bytes/1` bytes, unpadded — which is the spec's
  minimum length and well inside its 43..128 window; the challenge is the
  unpadded base64url of its SHA-256.
  """
  @spec new_pkce() :: %{verifier: String.t(), challenge: String.t()}
  def new_pkce do
    verifier = random_token()
    %{verifier: verifier, challenge: challenge_for(verifier)}
  end

  @doc "The S256 code challenge for `verifier` — `base64url(sha256(verifier))`, unpadded."
  @spec challenge_for(String.t()) :: String.t()
  def challenge_for(verifier) when is_binary(verifier) do
    :sha256 |> :crypto.hash(verifier) |> Base.url_encode64(padding: false)
  end

  @doc """
  A fresh `state` token — 256 bits of `:crypto.strong_rand_bytes/1`,
  base64url. Its comparison is the caller's job and must be constant-time
  (`Valea.Mail.Engine` uses `Plug.Crypto.secure_compare/2`).
  """
  @spec new_state() :: String.t()
  def new_state, do: random_token()

  @doc """
  The provider's consent URL for one flow. `params` carries the resolved
  `client_id`, the `redirect_uri` this build listens on, the minted `state`
  and PKCE `challenge`, and optionally a `login_hint` (the mailbox address —
  it only pre-fills the provider's account chooser).

  Every value is form-encoded (`URI.encode_query/1`), which matters:
  scopes and client ids carry `:` `/` `.`, and a raw interpolation would
  produce a URL the provider reads differently than intended.
  """
  @spec authorize_url(provider(), %{
          required(:client_id) => String.t(),
          required(:redirect_uri) => String.t(),
          required(:state) => String.t(),
          required(:challenge) => String.t(),
          optional(:login_hint) => String.t() | nil
        }) :: String.t() | nil
  def authorize_url(provider, params) do
    case preset(provider) do
      nil ->
        nil

      preset ->
        query =
          [
            {"client_id", params.client_id},
            {"redirect_uri", params.redirect_uri},
            {"response_type", "code"},
            {"scope", preset.scope},
            {"state", params.state},
            {"code_challenge", params.challenge},
            {"code_challenge_method", "S256"}
          ] ++ login_hint(Map.get(params, :login_hint)) ++ preset.authorize_extra

        preset.authorize_url <> "?" <> URI.encode_query(query)
    end
  end

  defp login_hint(hint) when is_binary(hint) and hint != "", do: [{"login_hint", hint}]
  defp login_hint(_hint), do: []

  @doc """
  The loopback redirect URI this build registers and listens on —
  `http://127.0.0.1:<port>/oauth/callback`, built at RUNTIME from the
  endpoint's configured port because the port is not fixed (dev 4200,
  packaged 4817, test 4002).

  Read from application config rather than `ValeaWeb.Endpoint.config/1` on
  purpose: this module has no business depending on the web layer, and the
  port is a config fact either way. `127.0.0.1` literally, never
  `localhost` — providers treat the loopback IP as the special case that may
  carry a dynamic port, and a name would also depend on the host's resolver.
  """
  @spec redirect_uri() :: String.t()
  def redirect_uri do
    "http://127.0.0.1:#{endpoint_port()}/oauth/callback"
  end

  defp endpoint_port do
    :valea
    |> Application.get_env(ValeaWeb.Endpoint, [])
    |> Keyword.get(:http, [])
    |> Keyword.get(:port, 4200)
  end

  @doc """
  Spends `code` against the token endpoint (the authorization_code grant,
  PKCE-verified). Returns the granted tokens; `{:error, :no_refresh_token}`
  when the provider granted an access token but no refresh token, which is
  useless to us — this app's whole durable credential IS the refresh token.

  Runs in the CALLER's process (the callback controller's request process),
  never inside a GenServer loop.
  """
  @spec exchange_code(flow(), String.t(), keyword()) ::
          {:ok, tokens()}
          | {:error,
             :invalid_grant | :no_refresh_token | :token_request_failed | :unknown_provider}
  def exchange_code(flow, code, opts \\ []) when is_binary(code) do
    body =
      URI.encode_query([
        {"client_id", flow.client_id},
        {"code", code},
        {"code_verifier", flow.verifier},
        {"grant_type", "authorization_code"},
        {"redirect_uri", flow.redirect_uri}
      ])

    with {:ok, tokens} <- post_token(flow.provider, body, opts) do
      if tokens.refresh_token, do: {:ok, tokens}, else: {:error, :no_refresh_token}
    end
  end

  @doc """
  Mints a fresh access token from a stored refresh token. `{:error,
  :invalid_grant}` is the PERMANENT answer — the refresh token has been
  revoked, expired or superseded, and only a new authorization fixes it;
  every other error is transient and must not throw the account's stored
  credential away.

  `refresh_token` in the result is `nil` for a provider that did not rotate
  it (Google) and the NEW token for one that did (Microsoft).

  Runs inside the Engine's monitored refresh Task, never in its loop.
  """
  @spec refresh(
          %{
            required(:provider) => provider(),
            required(:client_id) => String.t(),
            required(:refresh_token) => String.t()
          },
          keyword()
        ) ::
          {:ok, tokens()} | {:error, :invalid_grant | :token_request_failed | :unknown_provider}
  def refresh(params, opts \\ []) do
    body =
      URI.encode_query([
        {"client_id", params.client_id},
        {"grant_type", "refresh_token"},
        {"refresh_token", params.refresh_token}
      ])

    post_token(params.provider, body, opts)
  end

  # -- token endpoint ---------------------------------------------------------

  defp post_token(provider, body, opts) do
    case preset(provider) do
      nil -> {:error, :unknown_provider}
      preset -> decode_token_response(http_post(opts).(preset.token_url, body))
    end
  end

  # The response is parsed for exactly the three fields this app uses, and
  # NOTHING about it — not the body, not a decode failure's message — travels
  # in the returned error. `invalid_grant` is read off the PAYLOAD rather than
  # off the status code: both providers answer 400 for it, and a 400 alone
  # cannot tell "this refresh token is dead" (throw it away) from "the request
  # was malformed" (keep it, retry later).
  defp decode_token_response({:ok, status, body}) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => "invalid_grant"}} -> {:error, :invalid_grant}
      {:ok, payload} when is_map(payload) -> granted_tokens(payload, status)
      _undecodable -> {:error, :token_request_failed}
    end
  end

  defp decode_token_response(_failure), do: {:error, :token_request_failed}

  # `refresh_token` is optional in a way the other two are not: absent on
  # every Google refresh (the original stays valid), present on every
  # Microsoft one (rotation).
  defp granted_tokens(
         %{"access_token" => access_token, "expires_in" => expires_in} = payload,
         status
       )
       when is_binary(access_token) and is_integer(expires_in) and status in 200..299 do
    {:ok,
     %{
       access_token: access_token,
       expires_in: max(expires_in, 0),
       refresh_token: presence(Map.get(payload, "refresh_token"))
     }}
  end

  defp granted_tokens(_payload, _status), do: {:error, :token_request_failed}

  defp http_post(opts) do
    Keyword.get(opts, :http_post) ||
      Application.get_env(:valea, :mail_oauth_http_post) ||
      (&default_http_post/2)
  end

  @doc """
  The default token-endpoint POST: `application/x-www-form-urlencoded`, the
  same explicit TLS posture as `Valea.Mail.Autoconfig.default_http_get/1`
  (verify_peer, system CA store, `:https` hostname match), short timeouts.

  Returns `{:ok, status, body}` — the STATUS as well as the body, because an
  OAuth error is a 400 with a meaningful payload, not something to discard.
  `:error` for every transport-level failure; it never raises, and it never
  logs (the body it holds is a credential).
  """
  @spec default_http_post(String.t(), iodata()) :: {:ok, non_neg_integer(), binary()} | :error
  def default_http_post(url, body) do
    with {:ok, _} <- Application.ensure_all_started(:inets),
         {:ok, _} <- Application.ensure_all_started(:ssl),
         {:ok, cacerts} <- system_cacerts() do
      request =
        {String.to_charlist(url), [{~c"user-agent", ~c"valea-mail-oauth"}],
         ~c"application/x-www-form-urlencoded", body}

      http_opts = [
        ssl: [
          verify: :verify_peer,
          cacerts: cacerts,
          depth: 3,
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ]
        ],
        timeout: @http_timeout,
        connect_timeout: @connect_timeout
      ]

      case :httpc.request(:post, request, http_opts, body_format: :binary) do
        {:ok, {{_http, status, _reason}, _headers, response}} when is_binary(response) ->
          {:ok, status, response}

        _other ->
          :error
      end
    else
      _ -> :error
    end
  rescue
    # Nothing is logged here BY DESIGN: an exception raised out of `:httpc`
    # can quote the request body, which is the refresh token.
    _ -> :error
  catch
    :exit, _ -> :error
  end

  defp system_cacerts do
    {:ok, :public_key.cacerts_get()}
  rescue
    _ -> :error
  end

  defp random_token, do: 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      _kept -> value
    end
  end

  defp presence(_value), do: nil
end
