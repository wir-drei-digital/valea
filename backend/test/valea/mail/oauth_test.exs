defmodule Valea.Mail.OAuthTest do
  use ExUnit.Case, async: true

  alias Valea.Mail.OAuth
  alias Valea.Mail.Settings

  # A `http_post` double: records the call on the test process and answers
  # with whatever the test scripted. The seam is `(url, body) -> {:ok, status,
  # body} | :error`, so a test can assert on the exact form-encoded body that
  # would have gone on the wire.
  defp recording_post(reply) do
    probe = self()

    fn url, body ->
      send(probe, {:token_post, url, IO.iodata_to_binary(body)})
      reply
    end
  end

  defp json(map), do: Jason.encode!(map)

  defp flow(overrides \\ %{}) do
    Map.merge(
      %{
        account: "mara",
        provider: :gmail,
        client_id: "123-abc.apps.googleusercontent.com",
        redirect_uri: "http://127.0.0.1:4002/oauth/callback",
        verifier: "the-verifier-value"
      },
      overrides
    )
  end

  describe "PKCE pair properties" do
    test "the verifier is 43 unpadded base64url characters (RFC 7636's 43..128 window)" do
      %{verifier: verifier} = OAuth.new_pkce()

      assert String.length(verifier) == 43
      assert byte_size(verifier) == 43
      refute String.contains?(verifier, "=")
      assert verifier =~ ~r/^[A-Za-z0-9_-]+$/
    end

    test "the challenge is base64url(sha256(verifier)), unpadded" do
      %{verifier: verifier, challenge: challenge} = OAuth.new_pkce()

      expected = :sha256 |> :crypto.hash(verifier) |> Base.url_encode64(padding: false)
      assert challenge == expected
      assert challenge == OAuth.challenge_for(verifier)
      refute String.contains?(challenge, "=")
      # The challenge must not BE the verifier — a plain-method flow in
      # disguise is exactly what S256 exists to rule out.
      refute challenge == verifier
    end

    test "every pair is fresh" do
      pairs = Enum.map(1..20, fn _ -> OAuth.new_pkce().verifier end)
      assert length(Enum.uniq(pairs)) == 20
    end

    test "state tokens are fresh, unpadded base64url" do
      states = Enum.map(1..20, fn _ -> OAuth.new_state() end)

      assert length(Enum.uniq(states)) == 20
      assert Enum.all?(states, &(&1 =~ ~r/^[A-Za-z0-9_-]{43}$/))
    end
  end

  describe "consent-URL construction" do
    test "gmail: endpoint, scope, PKCE and the offline/consent pair Google needs for a refresh token" do
      url =
        OAuth.authorize_url(:gmail, %{
          client_id: "cid:with/chars.apps",
          redirect_uri: "http://127.0.0.1:4200/oauth/callback",
          state: "st4te",
          challenge: "ch4llenge",
          login_hint: "mara@gmail.com"
        })

      assert String.starts_with?(url, "https://accounts.google.com/o/oauth2/v2/auth?")

      query = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

      assert query["client_id"] == "cid:with/chars.apps"
      assert query["redirect_uri"] == "http://127.0.0.1:4200/oauth/callback"
      assert query["response_type"] == "code"
      assert query["scope"] == "https://mail.google.com/"
      assert query["state"] == "st4te"
      assert query["code_challenge"] == "ch4llenge"
      assert query["code_challenge_method"] == "S256"
      assert query["login_hint"] == "mara@gmail.com"
      # Without BOTH of these Google issues no refresh token for an account
      # that has already consented once.
      assert query["access_type"] == "offline"
      assert query["prompt"] == "consent"
    end

    test "every value is form-encoded, so the `:` `/` `.` in ids and scopes survive" do
      url =
        OAuth.authorize_url(:gmail, %{
          client_id: "a b&c=d",
          redirect_uri: "http://127.0.0.1:4200/oauth/callback",
          state: "s+t",
          challenge: "c/h"
        })

      # The raw query string must carry escapes, not the literals.
      raw = url |> URI.parse() |> Map.fetch!(:query)
      refute String.contains?(raw, "a b&c=d")
      refute String.contains?(raw, "://mail")

      assert String.contains?(
               raw,
               "redirect_uri=http%3A%2F%2F127.0.0.1%3A4200%2Foauth%2Fcallback"
             )

      # ...and decode back to exactly what was passed in.
      query = URI.decode_query(raw)
      assert query["client_id"] == "a b&c=d"
      assert query["state"] == "s+t"
      assert query["code_challenge"] == "c/h"
    end

    test "microsoft: the common tenant, all three mail scopes, query response mode" do
      url =
        OAuth.authorize_url(:microsoft, %{
          client_id: "mcid",
          redirect_uri: "http://127.0.0.1:4817/oauth/callback",
          state: "st",
          challenge: "ch",
          login_hint: "mara@contoso.com"
        })

      assert String.starts_with?(
               url,
               "https://login.microsoftonline.com/common/oauth2/v2.0/authorize?"
             )

      query = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

      assert query["scope"] ==
               "offline_access https://outlook.office.com/IMAP.AccessAsUser.All https://outlook.office.com/SMTP.Send"

      assert query["response_mode"] == "query"
      assert query["code_challenge_method"] == "S256"
      # Microsoft carries `offline_access` as a scope; it takes no access_type.
      refute Map.has_key?(query, "access_type")
    end

    test "a nil/blank login hint is omitted rather than sent empty" do
      for hint <- [nil, ""] do
        query =
          OAuth.authorize_url(:gmail, %{
            client_id: "cid",
            redirect_uri: "http://127.0.0.1:4002/oauth/callback",
            state: "st",
            challenge: "ch",
            login_hint: hint
          })
          |> URI.parse()
          |> Map.fetch!(:query)
          |> URI.decode_query()

        refute Map.has_key?(query, "login_hint")
      end
    end

    test "an unknown provider builds no URL at all" do
      assert OAuth.authorize_url(:yahoo, %{
               client_id: "cid",
               redirect_uri: "http://127.0.0.1:4002/oauth/callback",
               state: "st",
               challenge: "ch"
             }) == nil
    end
  end

  describe "the redirect URI" do
    test "is the loopback IP on the endpoint's CONFIGURED port, never a hostname" do
      # `config/test.exs` pins 4002; the point is that it is read from config
      # rather than hardcoded, because dev/packaged builds differ (4200/4817).
      assert OAuth.redirect_uri() == "http://127.0.0.1:4002/oauth/callback"
    end
  end

  describe "client id resolution" do
    setup do
      previous = Application.get_env(:valea, :mail_oauth)
      on_exit(fn -> Application.put_env(:valea, :mail_oauth, previous) end)
      :ok
    end

    defp settings(provider, override \\ nil) do
      host =
        case provider do
          :gmail -> "imap.gmail.com"
          :microsoft -> "outlook.office365.com"
          :generic -> "imap.fastmail.com"
        end

      %Settings{
        slug: "mara",
        provider: provider,
        auth: :oauth2,
        oauth_client_id: override,
        imap: %{host: host, port: 993, username: "mara@example.com"}
      }
    end

    test "the account's own override wins over app config" do
      Application.put_env(:valea, :mail_oauth, gmail: [client_id: "from-config"])
      assert OAuth.client_id_for(settings(:gmail, "from-the-account")) == "from-the-account"
    end

    test "no override falls back to the provider's configured id" do
      Application.put_env(:valea, :mail_oauth, gmail: [client_id: "from-config"])
      assert OAuth.client_id_for(settings(:gmail)) == "from-config"
    end

    test "a blank override is no override" do
      Application.put_env(:valea, :mail_oauth, gmail: [client_id: "from-config"])
      assert OAuth.client_id_for(settings(:gmail, "   ")) == "from-config"
    end

    test "nil when the build ships no id for the provider" do
      Application.put_env(:valea, :mail_oauth, gmail: [client_id: nil])
      assert OAuth.client_id_for(settings(:gmail)) == nil
      assert OAuth.configured_client_id(:gmail) == nil
    end

    test "nil when nothing is configured for the provider at all" do
      Application.put_env(:valea, :mail_oauth, [])
      assert OAuth.configured_client_id(:microsoft) == nil
    end

    test "a generic mailbox has no preset, so no id — even with config present" do
      Application.put_env(:valea, :mail_oauth, gmail: [client_id: "from-config"])
      assert OAuth.provider_for(settings(:generic)) == nil
      assert OAuth.client_id_for(settings(:generic)) == nil
    end

    test "but a generic mailbox with an explicit override still resolves it" do
      # The override is the escape hatch for a host this build's table doesn't
      # know; whether a flow may START is a separate decision (the Engine's).
      assert OAuth.client_id_for(settings(:generic, "hand-edited")) == "hand-edited"
    end

    test "provider_for maps the two detected providers onto their presets" do
      assert OAuth.provider_for(settings(:gmail)) == :gmail
      assert OAuth.provider_for(settings(:microsoft)) == :microsoft
      assert Enum.sort(OAuth.providers()) == [:gmail, :microsoft]
    end
  end

  describe "the authorization_code grant" do
    test "posts a form-encoded body with the PKCE verifier, and returns the tokens" do
      reply =
        {:ok, 200,
         json(%{
           "access_token" => "ya29.access",
           "expires_in" => 3599,
           "refresh_token" => "1//refresh",
           "token_type" => "Bearer"
         })}

      assert {:ok, tokens} =
               OAuth.exchange_code(flow(), "4/code-value", http_post: recording_post(reply))

      assert tokens.access_token == "ya29.access"
      assert tokens.expires_in == 3599
      assert tokens.refresh_token == "1//refresh"

      assert_received {:token_post, url, body}
      assert url == "https://oauth2.googleapis.com/token"

      params = URI.decode_query(body)
      assert params["client_id"] == "123-abc.apps.googleusercontent.com"
      assert params["code"] == "4/code-value"
      assert params["code_verifier"] == "the-verifier-value"
      assert params["grant_type"] == "authorization_code"
      assert params["redirect_uri"] == "http://127.0.0.1:4002/oauth/callback"
      # A public client: no secret is ever sent.
      refute Map.has_key?(params, "client_secret")
      # ...and the values are encoded, not spliced raw.
      assert String.contains?(body, "code=4%2Fcode-value")
    end

    test "the microsoft flow posts to the common tenant's token endpoint" do
      reply =
        {:ok, 200, json(%{"access_token" => "a", "expires_in" => 3600, "refresh_token" => "r"})}

      assert {:ok, _} =
               OAuth.exchange_code(flow(%{provider: :microsoft}), "c",
                 http_post: recording_post(reply)
               )

      assert_received {:token_post, url, _body}
      assert url == "https://login.microsoftonline.com/common/oauth2/v2.0/token"
    end

    test "a grant with no refresh token is refused — the refresh token IS the credential" do
      reply = {:ok, 200, json(%{"access_token" => "a", "expires_in" => 3600})}

      assert OAuth.exchange_code(flow(), "c", http_post: recording_post(reply)) ==
               {:error, :no_refresh_token}
    end

    test "a blank refresh token counts as none" do
      reply =
        {:ok, 200, json(%{"access_token" => "a", "expires_in" => 3600, "refresh_token" => ""})}

      assert OAuth.exchange_code(flow(), "c", http_post: recording_post(reply)) ==
               {:error, :no_refresh_token}
    end

    test "invalid_grant is read off the payload, and no part of the body reaches the error" do
      reply =
        {:ok, 400,
         json(%{
           "error" => "invalid_grant",
           "error_description" => "Bad Request: the-code-was 4/code-value"
         })}

      assert OAuth.exchange_code(flow(), "4/code-value", http_post: recording_post(reply)) ==
               {:error, :invalid_grant}
    end

    test "every other failure is the same opaque :token_request_failed" do
      bodies = [
        {:ok, 500, "upstream exploded, token=ya29.leaked"},
        {:ok, 400, json(%{"error" => "invalid_request"})},
        {:ok, 200, "not json at all"},
        {:ok, 200, json(%{"access_token" => "a"})},
        {:ok, 200, json(%{"access_token" => 42, "expires_in" => 10})},
        {:ok, 200, json(%{"expires_in" => 10})},
        # A 200-shaped payload arriving with a non-2xx status is not a grant.
        {:ok, 401, json(%{"access_token" => "a", "expires_in" => 10, "refresh_token" => "r"})},
        :error
      ]

      for reply <- bodies do
        assert OAuth.exchange_code(flow(), "c", http_post: recording_post(reply)) ==
                 {:error, :token_request_failed},
               "expected an opaque failure for #{inspect(reply)}"
      end
    end

    test "an unknown provider never reaches the network" do
      assert OAuth.exchange_code(flow(%{provider: :yahoo}), "c",
               http_post: recording_post({:ok, 200, "{}"})
             ) == {:error, :unknown_provider}

      refute_received {:token_post, _url, _body}
    end
  end

  describe "the refresh_token grant" do
    defp refresh_params(overrides \\ %{}) do
      Map.merge(
        %{provider: :gmail, client_id: "cid", refresh_token: "1//stored-refresh"},
        overrides
      )
    end

    test "posts the stored refresh token and returns a fresh access token" do
      reply = {:ok, 200, json(%{"access_token" => "fresh", "expires_in" => 3599})}

      assert {:ok, tokens} = OAuth.refresh(refresh_params(), http_post: recording_post(reply))
      assert tokens.access_token == "fresh"
      assert tokens.expires_in == 3599
      # Google does not rotate: nil means "keep the one you have".
      assert tokens.refresh_token == nil

      assert_received {:token_post, "https://oauth2.googleapis.com/token", body}
      params = URI.decode_query(body)
      assert params["grant_type"] == "refresh_token"
      assert params["refresh_token"] == "1//stored-refresh"
      assert params["client_id"] == "cid"
      refute Map.has_key?(params, "client_secret")
      refute Map.has_key?(params, "code")
    end

    test "a ROTATED refresh token comes back so the caller can replace the stored one" do
      reply =
        {:ok, 200,
         json(%{"access_token" => "fresh", "expires_in" => 3600, "refresh_token" => "rotated"})}

      assert {:ok, %{refresh_token: "rotated"}} =
               OAuth.refresh(refresh_params(%{provider: :microsoft}),
                 http_post: recording_post(reply)
               )
    end

    test "invalid_grant is distinguishable from every transient failure" do
      dead =
        {:ok, 400, json(%{"error" => "invalid_grant", "error_description" => "token revoked"})}

      assert OAuth.refresh(refresh_params(), http_post: recording_post(dead)) ==
               {:error, :invalid_grant}

      for transient <- [
            {:ok, 503, "try later"},
            {:ok, 400, json(%{"error" => "temporarily_unavailable"})},
            :error
          ] do
        assert OAuth.refresh(refresh_params(), http_post: recording_post(transient)) ==
                 {:error, :token_request_failed}
      end
    end

    test "a negative expires_in is floored rather than trusted" do
      reply = {:ok, 200, json(%{"access_token" => "fresh", "expires_in" => -5})}

      assert {:ok, %{expires_in: 0}} =
               OAuth.refresh(refresh_params(), http_post: recording_post(reply))
    end
  end

  describe "the application-env HTTP seam" do
    test "a configured :mail_oauth_http_post is used when no opts are passed" do
      probe = self()

      Application.put_env(:valea, :mail_oauth_http_post, fn _url, body ->
        send(probe, {:env_post, IO.iodata_to_binary(body)})
        {:ok, 200, Jason.encode!(%{"access_token" => "a", "expires_in" => 60})}
      end)

      on_exit(fn -> Application.delete_env(:valea, :mail_oauth_http_post) end)

      assert {:ok, %{access_token: "a"}} =
               OAuth.refresh(%{provider: :gmail, client_id: "cid", refresh_token: "r"})

      assert_received {:env_post, body}
      assert URI.decode_query(body)["refresh_token"] == "r"
    end
  end
end
