defmodule Valea.Mail.SmtpClientTest do
  use ExUnit.Case, async: true

  alias Valea.Mail.SmtpClient

  # Real TLS sockets against FakeSmtpServer (test/support/fake_smtp_server.ex),
  # the fixture CA (test/fixtures/tls/ca.pem), on an ephemeral loopback port.
  # `verify_peer` stays ON in every test here; the fixture CA is injected via
  # `tls_opts:` exactly the way a real caller injects nothing (defaults win) —
  # never by disabling verification.

  @cacertfile Path.expand("../../fixtures/tls/ca.pem", __DIR__)

  # AUTH PLAIN's SASL blob for user/pass, spelled out rather than recomputed
  # with the implementation's own expression: a golden, so an encoding bug
  # can't agree with itself.
  @auth_plain "AUTH PLAIN AHVzZXIAcGFzcw=="

  defp config(server, security) do
    %{host: "localhost", port: server.port, security: security, username: "user"}
  end

  defp opts(extra \\ []), do: Keyword.merge([tls_opts: [cacertfile: @cacertfile]], extra)

  defp envelope(rcpt \\ ["a@x.co"]), do: %{from: "mara@x.co", rcpt: rcpt}

  @message "Subject: hi\r\n\r\nbody line\r\n"

  # -- scripts ---------------------------------------------------------------

  # 465: TLS from the first byte, exactly ONE EHLO, STARTTLS never appears.
  defp implicit_prelude do
    [
      :implicit_tls,
      {:greet, "220 smtp.test ESMTP"},
      {:expect, "EHLO", "250-smtp.test\r\n250 AUTH PLAIN LOGIN"},
      {:expect, @auth_plain, "235 2.7.0 accepted"}
    ]
  end

  # 587: plaintext EHLO advertising STARTTLS (and NOT AUTH), upgrade, then a
  # second EHLO — the only one that may advertise AUTH.
  defp starttls_prelude do
    [
      {:greet, "220 smtp.test ESMTP"},
      {:expect, "EHLO", "250-smtp.test\r\n250 STARTTLS"},
      :starttls,
      {:expect, "EHLO", "250-smtp.test\r\n250 AUTH PLAIN LOGIN"},
      {:expect, @auth_plain, "235 2.7.0 accepted"}
    ]
  end

  defp envelope_steps(rcpt_replies \\ %{"a@x.co" => "250 2.1.5 ok"}) do
    [
      {:expect, "MAIL FROM:<mara@x.co>", "250 2.1.0 ok"},
      {:expect_rcpt, rcpt_replies}
    ]
  end

  # -- 465 implicit TLS -------------------------------------------------------

  test "465 implicit TLS: accepted, TLS before any command, exactly one EHLO, no STARTTLS" do
    server =
      FakeSmtpServer.start(
        implicit_prelude() ++
          envelope_steps() ++
          [
            {:expect, "DATA", "354 go ahead"},
            {:data_reply, "250 2.0.0 queued as ABC123"},
            :expect_quit
          ]
      )

    assert {:ok, :accepted} =
             SmtpClient.send(config(server, :tls), "pass", envelope(), @message, opts())

    log = FakeSmtpServer.await(server)

    # TLS is the FIRST thing on this connection — nothing precedes it.
    assert [{:tls, :implicit} | rest] = log
    assert Enum.count(rest, &ehlo?/1) == 1
    refute Enum.any?(log, &starttls?/1)
  end

  # -- 587 STARTTLS -----------------------------------------------------------

  test "587 STARTTLS: no AUTH before TLS, and a SECOND EHLO after the upgrade" do
    server =
      FakeSmtpServer.start(
        starttls_prelude() ++
          envelope_steps() ++
          [
            {:expect, "DATA", "354 go ahead"},
            {:data_reply, "250 2.0.0 queued"},
            :expect_quit
          ]
      )

    assert {:ok, :accepted} =
             SmtpClient.send(config(server, :starttls), "pass", envelope(), @message, opts())

    log = FakeSmtpServer.await(server)

    assert [
             "EHLO" <> _,
             "STARTTLS",
             {:tls, :starttls},
             "EHLO" <> _,
             @auth_plain,
             "MAIL FROM:<mara@x.co>" | _
           ] = log

    assert Enum.count(log, &ehlo?/1) == 2
  end

  test "587 STARTTLS: AUTH LOGIN fallback when the post-TLS EHLO does not advertise PLAIN" do
    server =
      FakeSmtpServer.start([
        {:greet, "220 smtp.test ESMTP"},
        {:expect, "EHLO", "250-smtp.test\r\n250 STARTTLS"},
        :starttls,
        {:expect, "EHLO", "250-smtp.test\r\n250 AUTH LOGIN"},
        {:expect, "AUTH LOGIN", "334 VXNlcm5hbWU6"},
        {:expect, "dXNlcg==", "334 UGFzc3dvcmQ6"},
        {:expect, "cGFzcw==", "235 2.7.0 accepted"},
        :expect_quit
      ])

    assert :ok = SmtpClient.check_auth(config(server, :starttls), "pass", opts())
    log = FakeSmtpServer.await(server)
    refute Enum.any?(log, &match?("AUTH PLAIN" <> _, &1))
  end

  # -- AUTH failure ------------------------------------------------------------

  test "AUTH rejected: {:error, {:auth_failed, _}}, nothing else attempted" do
    server =
      FakeSmtpServer.start(
        implicit_prelude()
        |> List.replace_at(3, {:expect, @auth_plain, "535 5.7.8 bad credentials"})
      )

    assert {:error, {:auth_failed, detail}} =
             SmtpClient.send(config(server, :tls), "pass", envelope(), @message, opts())

    assert detail =~ "535"

    log = FakeSmtpServer.await(server)
    refute Enum.any?(log, &match?("MAIL FROM" <> _, &1))
  end

  # -- XOAUTH2 (`auth: :oauth2`, M6 task 15) ------------------------------------

  # The exact line the client must put on the wire, as a golden: `user=user`,
  # SOH, `auth=Bearer ya29.TOKEN`, SOH, SOH — base64'd. Spelled out rather than
  # built with `Xoauth2.response/2`, so an encoding bug can't agree with itself.
  @auth_xoauth2 "AUTH XOAUTH2 dXNlcj11c2VyAWF1dGg9QmVhcmVyIHlhMjkuVE9LRU4BAQ=="

  # The provider's failure payload, base64'd — the client never reads its
  # CONTENT, only the fact that a 334 arrived.
  @xoauth2_error "eyJzdGF0dXMiOiI0MDEiLCJzY2hlbWVzIjoiQmVhcmVyIn0="

  defp oauth2_config(server, security) do
    Map.put(config(server, security), :auth, :oauth2)
  end

  test "587 STARTTLS oauth2: XOAUTH2 only, advertised only by the post-upgrade EHLO" do
    server =
      FakeSmtpServer.start(
        [
          {:greet, "220 smtp.test ESMTP"},
          # Pre-TLS: no AUTH advertised at all, so a client that read
          # mechanisms from this EHLO would have nothing to pick (RFC 3207).
          {:expect, "EHLO", "250-smtp.test\r\n250 STARTTLS"},
          :starttls,
          {:expect, "EHLO", "250-smtp.test\r\n250 AUTH XOAUTH2"},
          {:expect, @auth_xoauth2, "235 2.7.0 accepted"}
        ] ++
          envelope_steps() ++
          [
            {:expect, "DATA", "354 go ahead"},
            {:data_reply, "250 2.0.0 queued"},
            :expect_quit
          ]
      )

    assert {:ok, :accepted} =
             SmtpClient.send(
               oauth2_config(server, :starttls),
               "ya29.TOKEN",
               envelope(),
               @message,
               opts()
             )

    log = FakeSmtpServer.await(server)

    assert [
             "EHLO" <> _,
             "STARTTLS",
             {:tls, :starttls},
             "EHLO" <> _,
             @auth_xoauth2,
             "MAIL FROM:<mara@x.co>" | _
           ] = log

    # The token was never offered any other way.
    refute Enum.any?(log, &match?("AUTH PLAIN" <> _, &1))
    refute Enum.any?(log, &match?("AUTH LOGIN" <> _, &1))
  end

  test "465 oauth2: check_auth authenticates with XOAUTH2 and quits" do
    server =
      FakeSmtpServer.start([
        :implicit_tls,
        {:greet, "220 smtp.test ESMTP"},
        # PLAIN and LOGIN are on offer and must be ignored: the ACCOUNT's mode
        # decides the mechanism, not the advertisement.
        {:expect, "EHLO", "250-smtp.test\r\n250 AUTH PLAIN LOGIN XOAUTH2"},
        {:expect, @auth_xoauth2, "235 2.7.0 accepted"},
        :expect_quit
      ])

    assert :ok = SmtpClient.check_auth(oauth2_config(server, :tls), "ya29.TOKEN", opts())

    log = FakeSmtpServer.await(server)
    refute Enum.any?(log, &match?("AUTH PLAIN" <> _, &1))
    refute Enum.any?(log, &match?("AUTH LOGIN" <> _, &1))
  end

  test "oauth2 failure round: 334 continuation, empty client line, 535 → :reauth_required" do
    # A rejected token is not answered with a bare 535: the mechanism requires
    # the client to acknowledge the `334 <base64 error>` with an empty line
    # first, and only then does the rejection arrive.
    server =
      FakeSmtpServer.start([
        :implicit_tls,
        {:greet, "220 smtp.test ESMTP"},
        {:expect, "EHLO", "250-smtp.test\r\n250 AUTH XOAUTH2"},
        {:expect, @auth_xoauth2, "334 " <> @xoauth2_error},
        {:expect, "", "535 5.7.8 Username and Password not accepted"}
      ])

    assert {:error, {:reauth_required, detail}} =
             SmtpClient.send(
               oauth2_config(server, :tls),
               "ya29.TOKEN",
               envelope(),
               @message,
               opts()
             )

    assert detail =~ "535"

    log = FakeSmtpServer.await(server)
    # The empty acknowledgement line IS on the wire, and nothing after it.
    assert [{:tls, :implicit}, "EHLO" <> _, @auth_xoauth2, ""] = log
    refute Enum.any?(log, &match?("MAIL FROM" <> _, &1))
  end

  test "oauth2: a server that drops the connection mid-SASL is NOT :reauth_required" do
    # Same reasoning as the IMAP side: a dropped socket must not be dressed up
    # as a refused token. Both are pre-354, so both stay provably unsent.
    server =
      FakeSmtpServer.start([
        :implicit_tls,
        {:greet, "220 smtp.test ESMTP"},
        {:expect, "EHLO", "250-smtp.test\r\n250 AUTH XOAUTH2"},
        {:expect, @auth_xoauth2, "334 " <> @xoauth2_error},
        :close
      ])

    assert {:error, reason} =
             SmtpClient.send(
               oauth2_config(server, :tls),
               "ya29.TOKEN",
               envelope(),
               @message,
               opts()
             )

    refute match?({:reauth_required, _}, reason)
    FakeSmtpServer.await(server)
  end

  test "oauth2 never falls back: a server without XOAUTH2 gets no AUTH at all" do
    # The one failure this exists to prevent: offering the ACCESS TOKEN as an
    # AUTH PLAIN password because the server happened to advertise PLAIN.
    server =
      FakeSmtpServer.start([
        {:greet, "220 smtp.test ESMTP"},
        {:expect, "EHLO", "250-smtp.test\r\n250 STARTTLS"},
        :starttls,
        {:expect, "EHLO", "250-smtp.test\r\n250 AUTH PLAIN LOGIN"}
      ])

    assert {:error, {:auth_unsupported, ["PLAIN", "LOGIN"]}} =
             SmtpClient.check_auth(oauth2_config(server, :starttls), "ya29.TOKEN", opts())

    log = FakeSmtpServer.await(server)
    refute Enum.any?(log, &match?("AUTH" <> _, &1))
  end

  test "an 8-bit access token rides inside the base64 response, never raising" do
    token = <<0xFF, "tok">>

    server =
      FakeSmtpServer.start([
        :implicit_tls,
        {:greet, "220 smtp.test ESMTP"},
        {:expect, "EHLO", "250-smtp.test\r\n250 AUTH XOAUTH2"},
        {:expect, "AUTH XOAUTH2 dXNlcj11c2VyAWF1dGg9QmVhcmVyIP90b2sBAQ==", "235 2.7.0 accepted"},
        :expect_quit
      ])

    assert :ok = SmtpClient.check_auth(oauth2_config(server, :tls), token, opts())
    FakeSmtpServer.await(server)
  end

  # -- recipients (all-or-nothing) ----------------------------------------------

  test "one rejected RCPT: aborts with RSET before DATA, reports only the rejected address" do
    server =
      FakeSmtpServer.start(
        implicit_prelude() ++
          [
            {:expect, "MAIL FROM:<mara@x.co>", "250 2.1.0 ok"},
            {:expect_rcpt, %{"a@x.co" => "250 ok", "b@x.co" => "550 no"}},
            {:expect, "RSET", "250 2.0.0 flushed"},
            :expect_quit
          ]
      )

    assert {:error, {:rejected_recipients, [{"b@x.co", "550 no"}]}} =
             SmtpClient.send(
               config(server, :tls),
               "pass",
               envelope(["a@x.co", "b@x.co"]),
               @message,
               opts()
             )

    log = FakeSmtpServer.await(server)
    assert "RSET" in log
    refute Enum.any?(log, &match?("DATA" <> _, &1))
    refute Enum.any?(log, &match?({:data, _}, &1))
  end

  # -- the tri-state boundary around the terminating dot ------------------------

  test "final 550 after the dot: provably unsent {:error, {:refused, 550, _}}" do
    server =
      FakeSmtpServer.start(
        implicit_prelude() ++
          envelope_steps() ++
          [
            {:expect, "DATA", "354 go ahead"},
            {:data_reply, "550 5.7.1 message rejected"},
            :expect_quit
          ]
      )

    assert {:error, {:refused, 550, text}} =
             SmtpClient.send(config(server, :tls), "pass", envelope(), @message, opts())

    assert text =~ "rejected"
    FakeSmtpServer.await(server)
  end

  test "final 4xx after the dot is equally provably unsent, never unknown" do
    server =
      FakeSmtpServer.start(
        implicit_prelude() ++
          envelope_steps() ++
          [
            {:expect, "DATA", "354 go ahead"},
            {:data_reply, "451 4.3.0 try later"},
            :expect_quit
          ]
      )

    assert {:error, {:refused, 451, _}} =
             SmtpClient.send(config(server, :tls), "pass", envelope(), @message, opts())

    FakeSmtpServer.await(server)
  end

  test "connection dropped after the dot with no reply: {:unknown, :closed}" do
    server =
      FakeSmtpServer.start(
        implicit_prelude() ++
          envelope_steps() ++
          [{:expect, "DATA", "354 go ahead"}, :drop_after_data]
      )

    assert {:unknown, :closed} =
             SmtpClient.send(config(server, :tls), "pass", envelope(), @message, opts())

    log = FakeSmtpServer.await(server)
    assert Enum.any?(log, &match?({:data, _}, &1))
  end

  test "connection closed MID-BODY write: {:unknown, _} — a flushed dot may already be gone" do
    # 8 MB, so the client is provably still writing when the server drops:
    # far beyond any socket buffer, the write itself fails. Classifying that
    # as provably-unsent would let a human re-click duplicate a delivered
    # message, which is exactly what the tri-state contract forbids.
    big = "Subject: big\r\n\r\n" <> String.duplicate("x", 8_000_000) <> "\r\n"

    server =
      FakeSmtpServer.start(
        implicit_prelude() ++
          envelope_steps() ++
          [{:expect, "DATA", "354 go ahead"}, {:drop_after_bytes, 1024}]
      )

    assert {:unknown, _reason} =
             SmtpClient.send(config(server, :tls), "pass", envelope(), big, opts())

    FakeSmtpServer.await(server)
  end

  test "connection closed at the body/terminator boundary: {:unknown, _}" do
    # The server reads the WHOLE body and drops before the terminating
    # `.CRLF` — so the failure lands on the terminator write or on the reply
    # read. Both are after the 354 and both must be :unknown.
    server =
      FakeSmtpServer.start(
        implicit_prelude() ++
          envelope_steps() ++
          [
            {:expect, "DATA", "354 go ahead"},
            {:drop_after_bytes, byte_size(@message)}
          ]
      )

    assert {:unknown, _reason} =
             SmtpClient.send(config(server, :tls), "pass", envelope(), @message, opts())

    FakeSmtpServer.await(server)
  end

  test "garbage instead of a final reply: {:unknown, {:unparseable, _}}" do
    server =
      FakeSmtpServer.start(
        implicit_prelude() ++
          envelope_steps() ++
          [{:expect, "DATA", "354 go ahead"}, {:data_reply, "banana"}]
      )

    assert {:unknown, {:unparseable, "banana"}} =
             SmtpClient.send(config(server, :tls), "pass", envelope(), @message, opts())

    FakeSmtpServer.await(server)
  end

  test "dropped BEFORE the 354: provably unsent {:error, _}" do
    server =
      FakeSmtpServer.start(implicit_prelude() ++ envelope_steps() ++ [:close])

    assert {:error, reason} =
             SmtpClient.send(config(server, :tls), "pass", envelope(), @message, opts())

    refute match?({:refused, _, _}, reason)
    FakeSmtpServer.await(server)
  end

  # -- payload canonicalization --------------------------------------------------

  test "dot-stuffing golden: a body line starting with '.' arrives doubled, LF becomes CRLF" do
    data = "Subject: dots\n\n.hidden\nnormal\n"

    server =
      FakeSmtpServer.start(
        implicit_prelude() ++
          envelope_steps() ++
          [
            {:expect, "DATA", "354 go ahead"},
            {:data_reply, "250 queued"},
            :expect_quit
          ]
      )

    assert {:ok, :accepted} =
             SmtpClient.send(config(server, :tls), "pass", envelope(), data, opts())

    log = FakeSmtpServer.await(server)
    assert {:data, payload} = Enum.find(log, &match?({:data, _}, &1))
    assert payload == "Subject: dots\r\n\r\n..hidden\r\nnormal\r\n"
  end

  # -- check_auth/3 ----------------------------------------------------------------

  test "check_auth/3 authenticates and QUITs — it NEVER issues MAIL FROM" do
    server = FakeSmtpServer.start(implicit_prelude() ++ [:expect_quit])

    assert :ok = SmtpClient.check_auth(config(server, :tls), "pass", opts())

    log = FakeSmtpServer.await(server)
    refute Enum.any?(log, &match?("MAIL FROM" <> _, &1))
    refute Enum.any?(log, &match?("RCPT TO" <> _, &1))
    refute Enum.any?(log, &match?("DATA" <> _, &1))
    assert "QUIT" in log
  end

  test "check_auth/3 reports an auth failure distinguishably from a transport failure" do
    server =
      FakeSmtpServer.start(
        implicit_prelude()
        |> List.replace_at(3, {:expect, @auth_plain, "535 5.7.8 bad credentials"})
      )

    assert {:error, {:auth_failed, _}} =
             SmtpClient.check_auth(config(server, :tls), "pass", opts())

    FakeSmtpServer.await(server)
  end

  # -- config-pinned trust root (tls_cacert_file, e.g. ProtonMail Bridge) --------
  #
  # The production seam: `Settings.smtp_config/1` stamps the account's
  # `tls_cacert_file:` onto the config map as `cacertfile`, and every real
  # call site passes empty opts — so these tests do too.

  test "check_auth takes its trust root from the config cacertfile (no tls_opts) — implicit TLS" do
    server = FakeSmtpServer.start(implicit_prelude() ++ [:expect_quit])
    config = config(server, :tls) |> Map.put(:cacertfile, @cacertfile)

    assert :ok = SmtpClient.check_auth(config, "pass", [])
    FakeSmtpServer.await(server)
  end

  test "check_auth takes its trust root from the config cacertfile — STARTTLS upgrade" do
    server = FakeSmtpServer.start(starttls_prelude() ++ [:expect_quit])
    config = config(server, :starttls) |> Map.put(:cacertfile, @cacertfile)

    assert :ok = SmtpClient.check_auth(config, "pass", [])
    FakeSmtpServer.await(server)
  end

  test "check_auth verifies a pinned SELF-SIGNED certificate (the ProtonMail Bridge shape)" do
    # OTP refuses a self-signed PEER cert even when it sits in the trust
    # store (`selfsigned_peer`) — the pin must accept its exact bytes.
    selfsigned = Path.expand("../../fixtures/tls/selfsigned.pem", __DIR__)
    selfsigned_key = Path.expand("../../fixtures/tls/selfsigned.key", __DIR__)

    server =
      FakeSmtpServer.start(starttls_prelude() ++ [:expect_quit],
        certfile: selfsigned,
        keyfile: selfsigned_key
      )

    config = config(server, :starttls) |> Map.put(:cacertfile, selfsigned)

    assert :ok = SmtpClient.check_auth(config, "pass", [])
    FakeSmtpServer.await(server)
  end

  # -- TLS is mandatory and verified ---------------------------------------------

  test "verification is on by default: the fixture CA is NOT trusted without the override" do
    server = FakeSmtpServer.start(implicit_prelude())

    # No `tls_opts` → the system trust store, which never signed the fixture
    # cert. This must fail at the handshake, before any credential is sent.
    assert {:error, _reason} =
             SmtpClient.check_auth(config(server, :tls), "pass", [])
  end

  test "STARTTLS is required: a server that never advertises it is refused, credential unsent" do
    server =
      FakeSmtpServer.start([
        {:greet, "220 smtp.test ESMTP"},
        {:expect, "EHLO", "250-smtp.test\r\n250 SIZE 1000000"}
      ])

    assert {:error, :starttls_unsupported} =
             SmtpClient.check_auth(config(server, :starttls), "pass", opts())

    log = FakeSmtpServer.await(server)
    refute Enum.any?(log, &match?("AUTH" <> _, &1))
  end

  # -- credential never in an error term -------------------------------------------

  test "the credential never appears in an error term, even when the server echoes it" do
    secret = "hunter2-super-secret-XYZ"

    server =
      FakeSmtpServer.start(
        implicit_prelude()
        |> List.replace_at(
          3,
          {:expect, "AUTH PLAIN", "535 5.7.8 rejected password #{secret}"}
        )
      )

    assert {:error, reason} =
             SmtpClient.send(config(server, :tls), secret, envelope(), @message, opts())

    refute inspect(reason, limit: :infinity, printable_limit: :infinity) =~ secret
    FakeSmtpServer.await(server)
  end

  # -- helpers ---------------------------------------------------------------------

  defp ehlo?(entry), do: is_binary(entry) and String.starts_with?(entry, "EHLO")
  defp starttls?(entry), do: is_binary(entry) and String.starts_with?(entry, "STARTTLS")
end
