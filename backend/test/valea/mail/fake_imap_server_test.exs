defmodule Valea.Mail.FakeImapServerTest do
  use ExUnit.Case, async: true

  # Self-test of the fake IMAP server harness (test/support/fake_imap_server.ex)
  # that Task 3's real socket client will be tested against. Drives the
  # server with a raw `:ssl.connect`/`:gen_tcp.connect` client here — on
  # purpose, so this suite never depends on `Valea.Mail.Imap.Wire`, keeping
  # the harness's correctness independent of the code under test.

  @cacertfile Path.expand("../../fixtures/tls/ca.pem", __DIR__)

  defp tls_connect!(port) do
    {:ok, socket} =
      :ssl.connect(~c"localhost", port, [
        :binary,
        packet: :raw,
        active: false,
        verify: :verify_peer,
        cacertfile: @cacertfile
      ])

    socket
  end

  defp send_line(socket, tls?, line) do
    if tls?, do: :ssl.send(socket, line <> "\r\n"), else: :gen_tcp.send(socket, line <> "\r\n")
  end

  defp recv(socket, tls?) do
    if tls?, do: :ssl.recv(socket, 0), else: :gen_tcp.recv(socket, 0)
  end

  defp close(socket, tls?) do
    if tls?, do: :ssl.close(socket), else: :gen_tcp.close(socket)
  end

  test "greeting -> expect LOGIN -> reply OK, over real TLS" do
    script = [
      {:send, "* OK ready"},
      {:expect, ~r/^A1 LOGIN "u" "p"$/, then: ["A1 OK done"]}
    ]

    server = FakeImapServer.start(script, tls: true)
    socket = tls_connect!(server.port)

    assert {:ok, "* OK ready\r\n"} = recv(socket, true)
    :ok = send_line(socket, true, "A1 LOGIN \"u\" \"p\"")
    assert {:ok, "A1 OK done\r\n"} = recv(socket, true)

    close(socket, true)
    assert :ok = FakeImapServer.await(server)
  end

  test "await/1 raises when the client sends a non-matching line" do
    script = [
      {:send, "* OK ready"},
      {:expect, ~r/^A1 LOGIN "u" "p"$/, then: ["A1 OK done"]}
    ]

    server = FakeImapServer.start(script, tls: true)
    socket = tls_connect!(server.port)

    assert {:ok, "* OK ready\r\n"} = recv(socket, true)
    :ok = send_line(socket, true, "A1 LOGIN \"wrong\" \"creds\"")

    assert_raise RuntimeError, fn -> FakeImapServer.await(server) end

    close(socket, true)
  end

  test "plain TCP (tls: false) exercises the same greeting/login roundtrip" do
    script = [
      {:send, "* OK ready"},
      {:expect, ~r/^A1 LOGIN "u" "p"$/, then: ["A1 OK done"]}
    ]

    server = FakeImapServer.start(script, tls: false)

    {:ok, socket} =
      :gen_tcp.connect(~c"localhost", server.port, [:binary, packet: :raw, active: false])

    assert {:ok, "* OK ready\r\n"} = recv(socket, false)
    :ok = send_line(socket, false, "A1 LOGIN \"u\" \"p\"")
    assert {:ok, "A1 OK done\r\n"} = recv(socket, false)

    close(socket, false)
    assert :ok = FakeImapServer.await(server)
  end

  test ":expect_literal reads exactly N raw bytes, independent of CRLF content" do
    # The literal payload below contains an embedded CRLF and a `)` — bytes
    # that would confuse a text/line scanner but must not confuse a harness
    # that reads by exact byte count.
    literal = "ab\r\ncd)ef"

    script = [
      {:send, "* OK ready"},
      {:expect, ~r/^A2 APPEND "Drafts" \{#{byte_size(literal)}\}$/, then: ["+ Ready"]},
      {:expect_literal, byte_size(literal), then: ["A2 OK APPEND completed"]}
    ]

    server = FakeImapServer.start(script, tls: true)
    socket = tls_connect!(server.port)

    assert {:ok, "* OK ready\r\n"} = recv(socket, true)
    :ok = send_line(socket, true, "A2 APPEND \"Drafts\" {#{byte_size(literal)}}")
    assert {:ok, "+ Ready\r\n"} = recv(socket, true)
    :ok = :ssl.send(socket, literal)
    assert {:ok, "A2 OK APPEND completed\r\n"} = recv(socket, true)

    close(socket, true)
    assert :ok = FakeImapServer.await(server)
  end

  test ":close step closes the socket after any scripted sends" do
    script = [
      {:send, "* OK ready"},
      {:expect, "A1 LOGOUT", then: ["* BYE later", "A1 OK done"]},
      :close
    ]

    server = FakeImapServer.start(script, tls: true)
    socket = tls_connect!(server.port)

    assert {:ok, "* OK ready\r\n"} = recv(socket, true)
    :ok = send_line(socket, true, "A1 LOGOUT")

    # Both `then:` lines may arrive coalesced into one TLS record, so read
    # until the peer closes rather than assuming one line per recv.
    assert read_until_closed(socket, true) == "* BYE later\r\nA1 OK done\r\n"

    assert :ok = FakeImapServer.await(server)
  end

  test ~s[an IDLE conversation scripts as plain steps: continuation, unsolicited push, DONE] do
    script = [
      {:send, "* OK ready"},
      {:expect, "A3 IDLE", then: ["+ idling"]},
      # The server speaking first, a moment later — no step needed for it
      # beyond `:send` (the sleep only keeps it out of the continuation's
      # record, so this test can assert on the two separately).
      {:sleep, 60},
      {:send, "* 4 EXISTS"},
      {:expect, "DONE", then: ["A3 OK IDLE terminated"]}
    ]

    server = FakeImapServer.start(script, tls: true)
    socket = tls_connect!(server.port)

    assert {:ok, "* OK ready\r\n"} = recv(socket, true)
    :ok = send_line(socket, true, "A3 IDLE")
    assert {:ok, "+ idling\r\n"} = recv(socket, true)
    assert {:ok, "* 4 EXISTS\r\n"} = recv(socket, true)
    :ok = send_line(socket, true, "DONE")
    assert {:ok, "A3 OK IDLE terminated\r\n"} = recv(socket, true)

    close(socket, true)
    assert :ok = FakeImapServer.await(server)
  end

  test "{:sleep, ms} spaces pushes out so they arrive as separate reads" do
    script = [
      {:send, "* OK ready"},
      {:sleep, 60},
      {:send, "* 1 EXISTS"},
      {:sleep, 60},
      {:send, "* 2 EXISTS"}
    ]

    server = FakeImapServer.start(script, tls: true)
    socket = tls_connect!(server.port)

    # Without the sleeps these three lines would be free to coalesce into one
    # TLS record; with them, each read returns exactly one.
    assert {:ok, "* OK ready\r\n"} = recv(socket, true)
    assert {:ok, "* 1 EXISTS\r\n"} = recv(socket, true)
    assert {:ok, "* 2 EXISTS\r\n"} = recv(socket, true)

    close(socket, true)
    assert :ok = FakeImapServer.await(server)
  end

  test "{:send_raw, bytes} sends verbatim — a response can be split across reads" do
    script = [
      {:send, "* OK ready"},
      {:sleep, 60},
      {:send_raw, "* 3 EXIS"},
      {:sleep, 60},
      {:send_raw, "TS\r\n"}
    ]

    server = FakeImapServer.start(script, tls: true)
    socket = tls_connect!(server.port)

    assert {:ok, "* OK ready\r\n"} = recv(socket, true)
    assert {:ok, "* 3 EXIS"} = recv(socket, true)
    assert {:ok, "TS\r\n"} = recv(socket, true)

    close(socket, true)
    assert :ok = FakeImapServer.await(server)
  end

  test "start_sequence/2 accepts a reconnect on the same port and runs the second script" do
    first = [
      {:send, "* OK first"},
      {:expect, "A1 NOOP", then: ["A1 OK done"]},
      :close
    ]

    second = [
      {:send, "* OK second"},
      {:expect, "A1 NOOP", then: ["A1 OK done"]}
    ]

    server = FakeImapServer.start_sequence([first, second], tls: true)

    for expected_greeting <- ["* OK first\r\n", "* OK second\r\n"] do
      socket = tls_connect!(server.port)
      assert {:ok, ^expected_greeting} = recv(socket, true)
      :ok = send_line(socket, true, "A1 NOOP")
      assert {:ok, "A1 OK done\r\n"} = recv(socket, true)
      close(socket, true)
    end

    # Only green once BOTH scripts ran: a client that never reconnects fails.
    assert :ok = FakeImapServer.await(server)
  end

  defp read_until_closed(socket, tls?, acc \\ "") do
    case recv(socket, tls?) do
      {:ok, data} -> read_until_closed(socket, tls?, acc <> data)
      {:error, :closed} -> acc
    end
  end

  test ":starttls step: plaintext greeting, tagged OK, TLS upgrade, then TLS-only steps" do
    script = [
      {:send, "* OK ready"},
      :starttls,
      {:expect, ~r/^A2 LOGIN "u" "p"$/, then: ["A2 OK done"]}
    ]

    server = FakeImapServer.start(script, tls: false)

    {:ok, plain} =
      :gen_tcp.connect(~c"localhost", server.port, [:binary, packet: :raw, active: false])

    assert {:ok, "* OK ready\r\n"} = recv(plain, false)
    :ok = send_line(plain, false, "A1 STARTTLS")
    assert {:ok, "A1 OK begin TLS\r\n"} = recv(plain, false)

    {:ok, socket} =
      :ssl.connect(plain, [verify: :verify_peer, cacertfile: @cacertfile], 5_000)

    :ok = send_line(socket, true, "A2 LOGIN \"u\" \"p\"")
    assert {:ok, "A2 OK done\r\n"} = recv(socket, true)

    close(socket, true)
    assert :ok = FakeImapServer.await(server)
  end

  test ":starttls step echoes the client's tag on the OK" do
    script = [
      {:send, "* OK ready"},
      :starttls
    ]

    server = FakeImapServer.start(script, tls: false)

    {:ok, plain} =
      :gen_tcp.connect(~c"localhost", server.port, [:binary, packet: :raw, active: false])

    assert {:ok, "* OK ready\r\n"} = recv(plain, false)
    :ok = send_line(plain, false, "V9 STARTTLS")
    assert {:ok, "V9 OK begin TLS\r\n"} = recv(plain, false)

    {:ok, socket} =
      :ssl.connect(plain, [verify: :verify_peer, cacertfile: @cacertfile], 5_000)

    close(socket, true)
    assert :ok = FakeImapServer.await(server)
  end
end
