defmodule ValeaWeb.OAuthCallbackControllerTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import ExUnit.CaptureLog
  import Plug.Conn, only: [get_resp_header: 2]

  @endpoint ValeaWeb.Endpoint

  alias Valea.Mail.Engine
  alias Valea.Mail.Settings
  alias Valea.Mail.Supervisor, as: MailSupervisor
  alias Valea.Workspace.Manager

  @client_id "valea-test.apps.googleusercontent.com"

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-app-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    System.put_env("VALEA_APP_DIR", dir)
    Manager.close()
    {:ok, %{path: ws}} = Manager.create("Primary")

    on_exit(fn ->
      Manager.close()
      File.rm_rf!(dir)
      System.delete_env("VALEA_APP_DIR")
      Application.delete_env(:valea, :mail_oauth_http_post)
    end)

    %{workspace: ws}
  end

  # An oauth2 account whose Engine is live — the same two steps
  # `setup_mail_account` performs.
  defp oauth_account!(ws, slug \\ "mara") do
    :ok =
      Settings.upsert_account!(ws, slug, %{
        host: "imap.gmail.com",
        port: 993,
        username: "#{slug}@gmail.com",
        auth: :oauth2,
        oauth_client_id: @client_id
      })

    :ok = MailSupervisor.reload_settings_all(ws)
    slug
  end

  # Starts a real authorization and returns the `state` token the provider
  # would redirect back with.
  defp start_flow!(slug) do
    assert {:ok, _url} = Engine.start_oauth(slug)
    :sys.get_state(GenServer.whereis(Engine.via(slug))).oauth_pending.state
  end

  defp stub_token_endpoint!(reply) do
    probe = self()

    Application.put_env(:valea, :mail_oauth_http_post, fn url, body ->
      send(probe, {:token_post, url, IO.iodata_to_binary(body)})
      reply
    end)
  end

  defp granted(fields \\ %{}) do
    {:ok, 200,
     Jason.encode!(
       Map.merge(
         %{"access_token" => "ya29.at", "expires_in" => 3600, "refresh_token" => "1//refresh"},
         fields
       )
     )}
  end

  defp callback(params), do: get(build_conn(), "/oauth/callback", params)

  test "the happy path exchanges the code, stores the refresh token, and says so", %{
    workspace: ws
  } do
    slug = oauth_account!(ws)
    state = start_flow!(slug)
    stub_token_endpoint!(granted())
    Phoenix.PubSub.subscribe(Valea.PubSub, "mail")

    conn = callback(%{"code" => "4/the-code", "state" => state})
    body = response(conn, 200)

    assert body =~ "Signed in — you can return to Valea."
    assert get_resp_header(conn, "content-type") |> hd() =~ "text/html"
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(conn, "cache-control") == ["no-store"]

    # The exchange really happened, server-side, with the flow's own verifier.
    assert_received {:token_post, "https://oauth2.googleapis.com/token", posted}
    params = URI.decode_query(posted)
    assert params["code"] == "4/the-code"
    assert params["grant_type"] == "authorization_code"
    assert params["client_id"] == @client_id
    assert params["redirect_uri"] == "http://127.0.0.1:4002/oauth/callback"
    assert String.length(params["code_verifier"]) == 43

    # ...and the token landed in the Engine plus on its way to the keychain.
    assert Engine.status(slug).credential == "present"
    assert_receive {:mail_oauth_token, ^slug, "1//refresh"}
  end

  test "the page never carries anything from the request, and nothing is logged", %{
    workspace: ws
  } do
    slug = oauth_account!(ws)
    state = start_flow!(slug)
    stub_token_endpoint!(granted())

    code = "4/UNIQUE-CODE-VALUE-abc"

    log =
      capture_log(fn ->
        body = response(callback(%{"code" => code, "state" => state}), 200)
        refute body =~ code
        refute body =~ state
      end)

    refute log =~ code
    refute log =~ state
    refute log =~ "1//refresh"
  end

  test "a state that matches nothing is refused, and never reaches the token endpoint", %{
    workspace: ws
  } do
    slug = oauth_account!(ws)
    live_state = start_flow!(slug)
    stub_token_endpoint!(granted())

    body = response(callback(%{"code" => "4/code", "state" => "not-the-state"}), 400)
    assert body =~ "Valea is not waiting for this sign-in."

    refute_received {:token_post, _url, _body}
    assert Engine.status(slug).credential == "missing"
    # A guess must not burn the real flow — it is still redeemable.
    assert {:ok, %{account: ^slug}} = Engine.claim_oauth_flow(live_state)
  end

  test "a redirect with no state at all is refused", %{workspace: ws} do
    oauth_account!(ws)
    stub_token_endpoint!(granted())

    assert response(callback(%{"code" => "4/code"}), 400) =~ "not waiting for this sign-in"
    refute_received {:token_post, _url, _body}
  end

  test "the provider's own error parameter is an honest refusal that CLEARS the flow", %{
    workspace: ws
  } do
    slug = oauth_account!(ws)
    state = start_flow!(slug)
    stub_token_endpoint!(granted())

    body =
      response(
        callback(%{
          "state" => state,
          "error" => "access_denied",
          "error_description" => "The user denied the request"
        }),
        400
      )

    assert body =~ "Sign-in was not completed."
    # No exchange was attempted...
    refute_received {:token_post, _url, _body}
    # ...and the authorization is spent, so it cannot be reused.
    assert Engine.claim_oauth_flow(state) == {:error, :no_flow}
    assert Engine.status(slug).credential == "missing"
  end

  test "an error parameter alongside a code still refuses (the error wins)", %{workspace: ws} do
    slug = oauth_account!(ws)
    state = start_flow!(slug)
    stub_token_endpoint!(granted())

    assert response(
             callback(%{"state" => state, "code" => "4/code", "error" => "invalid_scope"}),
             400
           ) =~ "Sign-in was not completed."

    refute_received {:token_post, _url, _body}
    assert Engine.status(slug).credential == "missing"
  end

  test "a failed code exchange is reported, stores nothing, and consumes the flow", %{
    workspace: ws
  } do
    slug = oauth_account!(ws)
    state = start_flow!(slug)
    stub_token_endpoint!({:ok, 400, Jason.encode!(%{"error" => "invalid_grant"})})

    assert response(callback(%{"code" => "4/stale", "state" => state}), 400) =~
             "Sign-in could not be completed."

    assert_received {:token_post, _url, _body}
    assert Engine.status(slug).credential == "missing"
    assert Engine.claim_oauth_flow(state) == {:error, :no_flow}
  end

  test "a grant with no refresh token is a failure, not a half-signed-in account", %{
    workspace: ws
  } do
    slug = oauth_account!(ws)
    state = start_flow!(slug)
    stub_token_endpoint!({:ok, 200, Jason.encode!(%{"access_token" => "a", "expires_in" => 60})})

    assert response(callback(%{"code" => "4/code", "state" => state}), 400) =~
             "Sign-in could not be completed."

    assert Engine.status(slug).credential == "missing"
  end

  test "an unreachable token endpoint is a failure page, not a crash", %{workspace: ws} do
    slug = oauth_account!(ws)
    state = start_flow!(slug)
    stub_token_endpoint!(:error)

    assert response(callback(%{"code" => "4/code", "state" => state}), 400) =~
             "Sign-in could not be completed."

    assert Engine.status(slug).credential == "missing"
  end

  test "a REPLAYED redirect finds nothing the second time", %{workspace: ws} do
    slug = oauth_account!(ws)
    state = start_flow!(slug)
    stub_token_endpoint!(granted())

    assert response(callback(%{"code" => "4/code", "state" => state}), 200) =~ "Signed in"

    assert response(callback(%{"code" => "4/code", "state" => state}), 400) =~
             "not waiting for this sign-in"
  end

  test "an EXPIRED flow is refused with its own copy, and consumed", %{workspace: ws} do
    slug = oauth_account!(ws)
    state = start_flow!(slug)
    stub_token_endpoint!(granted())

    # Age it rather than wait out the TTL (see `engine_test.exs` for the same
    # manoeuvre and why the arithmetic is relative).
    :sys.replace_state(GenServer.whereis(Engine.via(slug)), fn engine_state ->
      aged = System.monotonic_time(:millisecond) - 1
      %{engine_state | oauth_pending: %{engine_state.oauth_pending | expires_at: aged}}
    end)

    assert response(callback(%{"code" => "4/code", "state" => state}), 400) =~
             "This sign-in took too long."

    refute_received {:token_post, _url, _body}
    assert Engine.status(slug).credential == "missing"
  end

  test "the route is token-EXEMPT: no control token is sent, and it still answers", %{
    workspace: ws
  } do
    slug = oauth_account!(ws)
    state = start_flow!(slug)
    stub_token_endpoint!(granted())

    # `build_conn/0` sends no `x-valea-token` — a provider's browser redirect
    # cannot. A 401 here would make the whole flow unusable.
    conn = callback(%{"code" => "4/code", "state" => state})
    assert conn.status == 200
  end

  test "with no workspace open there is no Engine, so every redirect is refused" do
    Manager.close()
    stub_token_endpoint!(granted())

    assert response(callback(%{"code" => "4/code", "state" => "anything"}), 400) =~
             "not waiting for this sign-in"

    refute_received {:token_post, _url, _body}
  end
end
