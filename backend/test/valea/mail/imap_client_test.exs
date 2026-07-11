defmodule Valea.Mail.ImapClientTest do
  use ExUnit.Case, async: true

  alias Valea.Mail.ImapClient

  # Real TLS sockets against FakeImapServer (test/support/fake_imap_server.ex),
  # the fixture CA (test/fixtures/tls/ca.pem), on an ephemeral loopback port.
  # `verify_peer` stays ON; the fixture CA is injected via `tls_opts:` exactly
  # the way a real caller would inject nothing (defaults win) and the way a
  # test injects a non-default trust root — never by disabling verification.

  @cacertfile Path.expand("../../fixtures/tls/ca.pem", __DIR__)
  @login_re ~r/^A1 LOGIN "user" "pass"$/

  defp config(server), do: %{host: "localhost", port: server.port, username: "user"}

  defp connect_opts(extra \\ []), do: Keyword.merge([tls_opts: [cacertfile: @cacertfile]], extra)

  defp connect!(server, opts \\ []) do
    {:ok, conn} = ImapClient.connect(config(server), "pass", connect_opts(opts))
    conn
  end

  # Greeting + LOGIN (tag A1) + post-login CAPABILITY refresh (tag A2) —
  # every functional test needs this before its own command (tag A3+).
  defp handshake_steps(capability_line \\ "IMAP4rev1") do
    [
      {:send, "* OK ready"},
      {:expect, @login_re, then: ["A1 OK LOGIN completed"]},
      {:expect, "A2 CAPABILITY",
       then: ["* CAPABILITY #{capability_line}", "A2 OK CAPABILITY completed"]}
    ]
  end

  test "connect + login, and capabilities() reflects the post-login refresh, not the greeting" do
    # The greeting hints at a stale capability set (as some servers do via
    # `* OK [CAPABILITY ...] ready`, though this fixture just uses a plain
    # greeting) and the explicit post-login CAPABILITY reply advertises a
    # *different* set (MOVE + UIDPLUS gained). ImapClient must report the
    # latter, proving it never short-circuits on anything but the explicit
    # post-login refresh.
    script = [
      {:send, "* OK [CAPABILITY IMAP4rev1 STARTTLS] ready"},
      {:expect, @login_re, then: ["A1 OK LOGIN completed"]},
      {:expect, "A2 CAPABILITY",
       then: ["* CAPABILITY IMAP4rev1 MOVE UIDPLUS", "A2 OK CAPABILITY completed"]}
    ]

    server = FakeImapServer.start(script, tls: true)
    conn = connect!(server)

    assert {:ok, caps} = ImapClient.capabilities(conn)
    assert MapSet.new(caps) == MapSet.new(["IMAP4rev1", "MOVE", "UIDPLUS"])
    refute "STARTTLS" in caps

    assert :ok = FakeImapServer.await(server)
  end

  test "auth failure on a NO-tagged LOGIN returns {:error, :auth_failed}" do
    script = [
      {:send, "* OK ready"},
      {:expect, ~r/^A1 LOGIN "user" "wrong"$/, then: ["A1 NO LOGIN failed"]}
    ]

    server = FakeImapServer.start(script, tls: true)

    assert {:error, :auth_failed} =
             ImapClient.connect(config(server), "wrong", connect_opts())

    assert :ok = FakeImapServer.await(server)
  end

  test "select parses UIDVALIDITY and UIDNEXT from untagged OK lines" do
    script =
      handshake_steps() ++
        [
          {:expect, ~r/^A3 SELECT "AI\/Review"$/,
           then: [
             "* 5 EXISTS",
             "* OK [UIDVALIDITY 100] UIDs valid",
             "* OK [UIDNEXT 42] Predicted",
             "A3 OK [READ-WRITE] SELECT completed"
           ]}
        ]

    server = FakeImapServer.start(script, tls: true)
    conn = connect!(server)

    assert {:ok, %{uidvalidity: 100, uidnext: 42}} = ImapClient.select(conn, "AI/Review")
    assert :ok = FakeImapServer.await(server)
  end

  test "uid_search parses a SEARCH result line" do
    script =
      handshake_steps() ++
        [
          {:expect, "A3 UID SEARCH ALL", then: ["* SEARCH 4 7 9", "A3 OK SEARCH completed"]}
        ]

    server = FakeImapServer.start(script, tls: true)
    conn = connect!(server)

    assert {:ok, [4, 7, 9]} = ImapClient.uid_search(conn, "ALL")
    assert :ok = FakeImapServer.await(server)
  end

  test "uid_fetch_meta returns sizes for multiple uids" do
    script =
      handshake_steps() ++
        [
          {:expect, "A3 UID FETCH 4 (UID RFC822.SIZE)",
           then: ["* 1 FETCH (UID 4 RFC822.SIZE 120)", "A3 OK FETCH completed"]},
          {:expect, "A4 UID FETCH 7 (UID RFC822.SIZE)",
           then: ["* 2 FETCH (UID 7 RFC822.SIZE 555)", "A4 OK FETCH completed"]}
        ]

    server = FakeImapServer.start(script, tls: true)
    conn = connect!(server)

    assert {:ok, [%{uid: 4, size: 120}, %{uid: 7, size: 555}]} =
             ImapClient.uid_fetch_meta(conn, [4, 7])

    assert :ok = FakeImapServer.await(server)
  end

  test "uid_fetch_headers returns the header block for a uid" do
    header = "From: a@b\r\nSubject: hi\r\n\r\n"
    fetch_line = "* 1 FETCH (UID 9 BODY[HEADER] {#{byte_size(header)}}\r\n#{header})"

    script =
      handshake_steps() ++
        [
          {:expect, "A3 UID FETCH 9 (UID BODY.PEEK[HEADER])",
           then: [fetch_line, "A3 OK FETCH completed"]}
        ]

    server = FakeImapServer.start(script, tls: true)
    conn = connect!(server)

    assert {:ok, [%{uid: 9, header: ^header}]} = ImapClient.uid_fetch_headers(conn, [9])
    assert :ok = FakeImapServer.await(server)
  end

  test "uid_fetch_full parses a body containing ')' and embedded CRLFs via exact byte count" do
    body = "From: a@b\r\n\r\nhello)world"
    fetch_line = "* 1 FETCH (BODY[] {#{byte_size(body)}}\r\n#{body})"

    script =
      handshake_steps() ++
        [
          {:expect, "A3 UID FETCH 9 (BODY.PEEK[])", then: [fetch_line, "A3 OK FETCH completed"]}
        ]

    server = FakeImapServer.start(script, tls: true)
    conn = connect!(server)

    assert {:ok, ^body} = ImapClient.uid_fetch_full(conn, 9)
    assert :ok = FakeImapServer.await(server)
  end

  test "move ladder: MOVE capability -> UID MOVE" do
    script =
      handshake_steps("IMAP4rev1 MOVE") ++
        [
          {:expect, ~r/^A3 UID MOVE 7 "AI\/Processed"$/, then: ["A3 OK MOVE completed"]}
        ]

    server = FakeImapServer.start(script, tls: true)
    conn = connect!(server)

    assert :ok = ImapClient.uid_move(conn, 7, "AI/Processed")
    assert :ok = FakeImapServer.await(server)
  end

  test "move ladder: UIDPLUS only -> UID COPY + UID STORE +FLAGS + UID EXPUNGE (never bare EXPUNGE)" do
    script =
      handshake_steps("IMAP4rev1 UIDPLUS") ++
        [
          {:expect, ~r/^A3 UID COPY 7 "AI\/Processed"$/, then: ["A3 OK COPY completed"]},
          {:expect, ~r/^A4 UID STORE 7 \+FLAGS \(\\Deleted\)$/, then: ["A4 OK STORE completed"]},
          # The load-bearing assertion: this must be "UID EXPUNGE 7", never a
          # bare "EXPUNGE" (which would purge every \Deleted message in the
          # mailbox). A non-matching line here makes `await/1` raise.
          {:expect, ~r/^A5 UID EXPUNGE 7$/, then: ["A5 OK EXPUNGE completed"]}
        ]

    server = FakeImapServer.start(script, tls: true)
    conn = connect!(server)

    assert :ok = ImapClient.uid_move(conn, 7, "AI/Processed")
    assert :ok = FakeImapServer.await(server)
  end

  test "move ladder: neither MOVE nor UIDPLUS -> {:unsupported, _}, no STORE (or any command) issued" do
    script =
      handshake_steps("IMAP4rev1") ++
        [
          # If uid_move had wrongly issued COPY/STORE/EXPUNGE, those bytes
          # would already be sitting in front of this LIST line and the
          # regex below would not match, making `await/1` raise. This is
          # the harness-level proof that nothing was sent.
          {:expect, ~r/^A3 LIST "" \*$/, then: ["A3 OK LIST completed"]}
        ]

    server = FakeImapServer.start(script, tls: true)
    conn = connect!(server)

    assert {:unsupported, reason} = ImapClient.uid_move(conn, 7, "AI/Processed")
    assert is_binary(reason)

    assert {:ok, []} = ImapClient.list_folders(conn)
    assert :ok = FakeImapServer.await(server)
  end

  test "append sends a literal after the continuation and awaits the tagged OK" do
    literal = "hello"

    script =
      handshake_steps() ++
        [
          {:expect, ~r/^A3 APPEND "Drafts" \(\\Seen\) \{#{byte_size(literal)}\}$/,
           then: ["+ Ready"]},
          {:expect_literal, byte_size(literal), then: ["A3 OK APPEND completed"]}
        ]

    server = FakeImapServer.start(script, tls: true)
    conn = connect!(server)

    assert :ok = ImapClient.append(conn, "Drafts", ["\\Seen"], literal)
    assert :ok = FakeImapServer.await(server)
  end

  test "create_folder issues CREATE with a quoted mailbox name" do
    script =
      handshake_steps() ++
        [
          {:expect, ~r/^A3 CREATE "AI\/Custom"$/, then: ["A3 OK CREATE completed"]}
        ]

    server = FakeImapServer.start(script, tls: true)
    conn = connect!(server)

    assert :ok = ImapClient.create_folder(conn, "AI/Custom")
    assert :ok = FakeImapServer.await(server)
  end

  test "list_folders parses mailbox names out of untagged LIST lines" do
    script =
      handshake_steps() ++
        [
          {:expect, ~r/^A3 LIST "" \*$/,
           then: [
             "* LIST (\\HasNoChildren) \"/\" \"INBOX\"",
             "* LIST (\\HasNoChildren) \"/\" \"AI/Review\"",
             "A3 OK LIST completed"
           ]}
        ]

    server = FakeImapServer.start(script, tls: true)
    conn = connect!(server)

    assert {:ok, ["INBOX", "AI/Review"]} = ImapClient.list_folders(conn)
    assert :ok = FakeImapServer.await(server)
  end

  test "logout sends LOGOUT and always returns :ok" do
    script =
      handshake_steps() ++
        [
          {:expect, "A3 LOGOUT", then: ["* BYE later", "A3 OK done"]},
          :close
        ]

    server = FakeImapServer.start(script, tls: true)
    conn = connect!(server)

    assert :ok = ImapClient.logout(conn)
    assert :ok = FakeImapServer.await(server)
  end

  test "a silent server (no reply, no close) causes {:error, :timeout} within the configured recv_timeout" do
    script =
      handshake_steps() ++
        [
          # "INBOX" is all-uppercase, so Wire.encode leaves it bare (no
          # quotes) — see Wire's @unquoted_chars rule.
          {:expect, ~r/^A3 SELECT INBOX$/, then: []},
          # Kept blocked reading (rather than closing) so the client
          # experiences a genuine recv timeout rather than a closed-socket
          # error. This step is never satisfied; the server times out on its
          # own (long) internal recv well after this test's own assertions
          # are done, so we deliberately do not call `await/1` here.
          {:expect, ~r/.*/, then: []}
        ]

    server = FakeImapServer.start(script, tls: true)
    conn = connect!(server, recv_timeout: 200)

    assert {:error, :timeout} = ImapClient.select(conn, "INBOX")
  end
end
