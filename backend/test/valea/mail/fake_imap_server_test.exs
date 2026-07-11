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

  defp read_until_closed(socket, tls?, acc \\ "") do
    case recv(socket, tls?) do
      {:ok, data} -> read_until_closed(socket, tls?, acc <> data)
      {:error, :closed} -> acc
    end
  end
end
