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
