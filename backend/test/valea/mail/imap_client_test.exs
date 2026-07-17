defmodule Valea.Mail.ImapClientTest do
  use ExUnit.Case, async: true

  alias Valea.Mail.ImapClient

  # Real TLS sockets against FakeImapServer (test/support/fake_imap_server.ex),
  # the fixture CA (test/fixtures/tls/ca.pem), on an ephemeral loopback port.
  # `verify_peer` stays ON; the fixture CA is injected via `tls_opts:` exactly
  # the way a real caller would inject nothing (defaults win) and the way a
  # test injects a non-default trust root — never by disabling verification.

  @cacertfile Path.expand("../../fixtures/tls/ca.pem", __DIR__)
  # LOGIN now sends username + password as IMAP literals, so the fake server
  # reassembles the logical command with the bare (unquoted) argument bytes.
  @login_re ~r/^A1 LOGIN user pass$/

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
      {:expect_command, @login_re, then: ["A1 OK LOGIN completed"]},
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
      {:expect_command, @login_re, then: ["A1 OK LOGIN completed"]},
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
      {:expect_command, ~r/^A1 LOGIN user wrong$/, then: ["A1 NO LOGIN failed"]}
    ]

    server = FakeImapServer.start(script, tls: true)

    assert {:error, :auth_failed} =
             ImapClient.connect(config(server), "wrong", connect_opts())

    assert :ok = FakeImapServer.await(server)
  end

  test "logs in with a non-ASCII password sent as an IMAP literal" do
    # A password with 8-bit bytes would raise inside Wire.encode_arg's CR/LF/
    # 8-bit guard if quoted; sent as a literal it must reach the server byte
    # for byte and authenticate cleanly.
    password = "pä55wörd"

    script = [
      {:send, "* OK ready"},
      {:expect_command, ~r/^A1 LOGIN user #{Regex.escape(password)}$/,
       then: ["A1 OK LOGIN completed"]},
      {:expect, "A2 CAPABILITY", then: ["* CAPABILITY IMAP4rev1", "A2 OK CAPABILITY completed"]}
    ]

    server = FakeImapServer.start(script, tls: true)

    assert {:ok, conn} = ImapClient.connect(config(server), password, connect_opts())
    assert {:ok, ["IMAP4rev1"]} = ImapClient.capabilities(conn)
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

    assert {:ok, %{uidvalidity: 100, uidnext: 42, highestmodseq: nil}} =
             ImapClient.select(conn, "AI/Review")

    assert :ok = FakeImapServer.await(server)
  end

  test "select also parses HIGHESTMODSEQ from an untagged OK line" do
    script =
      handshake_steps("IMAP4rev1 CONDSTORE") ++
        [
          {:expect, ~r/^A3 SELECT "AI\/Review"$/,
           then: [
             "* 5 EXISTS",
             "* OK [UIDVALIDITY 100] UIDs valid",
             "* OK [UIDNEXT 42] Predicted",
             "* OK [HIGHESTMODSEQ 715194045007] Highest",
             "A3 OK [READ-WRITE] SELECT completed"
           ]}
        ]

    server = FakeImapServer.start(script, tls: true)
    conn = connect!(server)

    assert {:ok, %{uidvalidity: 100, uidnext: 42, highestmodseq: 715_194_045_007}} =
             ImapClient.select(conn, "AI/Review")

    assert :ok = FakeImapServer.await(server)
  end

  test "examine/2 issues EXAMINE (read-only), never SELECT, and parses the same fields" do
    script =
      handshake_steps() ++
        [
          {:expect, ~r/^A3 EXAMINE "AI\/Processed"$/,
           then: [
             "* OK [UIDVALIDITY 55] UIDs valid",
             "* OK [UIDNEXT 9] Predicted",
             "A3 OK [READ-ONLY] EXAMINE completed"
           ]}
        ]

    server = FakeImapServer.start(script, tls: true)
    conn = connect!(server)

    assert {:ok, %{uidvalidity: 55, uidnext: 9, highestmodseq: nil}} =
             ImapClient.examine(conn, "AI/Processed")

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

  test "move: MOVE capability -> UID MOVE, dest_uid parsed from tagged OK [COPYUID ...]" do
    script =
      handshake_steps("IMAP4rev1 MOVE") ++
        [
          {:expect, ~r/^A3 UID MOVE 7 "AI\/Processed"$/,
           then: ["A3 OK [COPYUID 9 7 77] MOVE completed"]}
        ]

    server = FakeImapServer.start(script, tls: true)
    conn = connect!(server)

    assert {:ok, %{dest_uid: 77}} = ImapClient.uid_move(conn, 7, "AI/Processed")
    assert :ok = FakeImapServer.await(server)
  end

  test "move: MOVE capability but no COPYUID in the tagged OK -> dest_uid nil" do
    script =
      handshake_steps("IMAP4rev1 MOVE") ++
        [
          {:expect, ~r/^A3 UID MOVE 7 "AI\/Processed"$/, then: ["A3 OK MOVE completed"]}
        ]

    server = FakeImapServer.start(script, tls: true)
    conn = connect!(server)

    assert {:ok, %{dest_uid: nil}} = ImapClient.uid_move(conn, 7, "AI/Processed")
    assert :ok = FakeImapServer.await(server)
  end

  test "move: no MOVE capability -> {:unsupported, _}, NO UID COPY fallback issued (UIDPLUS present)" do
    # UIDPLUS is advertised but MUST NOT trigger any client-side COPY+STORE+
    # EXPUNGE fallback ladder — that ladder moved out to the ops executor
    # (Task 13). If uid_move had wrongly issued COPY/STORE/EXPUNGE, those
    # bytes would already be sitting in front of this LIST line and the
    # regex below would not match, making `await/1` raise — the
    # harness-level proof that no UID COPY (or anything else) was sent.
    script =
      handshake_steps("IMAP4rev1 UIDPLUS") ++
        [
          {:expect, ~r/^A3 LIST "" \*$/, then: ["A3 OK LIST completed"]}
        ]

    server = FakeImapServer.start(script, tls: true)
    conn = connect!(server)

    assert {:unsupported, reason} = ImapClient.uid_move(conn, 7, "AI/Processed")
    assert is_binary(reason)

    assert {:ok, []} = ImapClient.list_folders(conn)
    assert :ok = FakeImapServer.await(server)
  end

  test "uid_copy issues UID COPY and parses dest_uid from tagged OK [COPYUID ...]" do
    script =
      handshake_steps() ++
        [
          {:expect, ~r/^A3 UID COPY 7 "AI\/Processed"$/,
           then: ["A3 OK [COPYUID 9 7 88] COPY completed"]}
        ]

    server = FakeImapServer.start(script, tls: true)
    conn = connect!(server)

    assert {:ok, %{dest_uid: 88}} = ImapClient.uid_copy(conn, 7, "AI/Processed")
    assert :ok = FakeImapServer.await(server)
  end

  test "uid_mark_deleted issues exactly UID STORE <uid> +FLAGS (\\Deleted)" do
    script =
      handshake_steps() ++
        [
          {:expect, ~r/^A3 UID STORE 7 \+FLAGS \(\\Deleted\)$/, then: ["A3 OK STORE completed"]}
        ]

    server = FakeImapServer.start(script, tls: true)
    conn = connect!(server)

    assert :ok = ImapClient.uid_mark_deleted(conn, 7)
    assert :ok = FakeImapServer.await(server)
  end

  test "uid_expunge issues a targeted UID EXPUNGE <uid>, never bare EXPUNGE" do
    script =
      handshake_steps() ++
        [
          {:expect, ~r/^A3 UID EXPUNGE 7$/, then: ["A3 OK EXPUNGE completed"]}
        ]

    server = FakeImapServer.start(script, tls: true)
    conn = connect!(server)

    assert :ok = ImapClient.uid_expunge(conn, 7)
    assert :ok = FakeImapServer.await(server)
  end

  test "uid_fetch_flags issues UID FETCH <set> (UID FLAGS MODSEQ) and parses every FETCH line" do
    script =
      handshake_steps("IMAP4rev1 CONDSTORE") ++
        [
          {:expect, "A3 UID FETCH 1:* (UID FLAGS MODSEQ)",
           then: [
             "* 1 FETCH (UID 4 FLAGS (\\Seen) MODSEQ (100))",
             "* 2 FETCH (UID 7 FLAGS () MODSEQ (105))",
             "A3 OK FETCH completed"
           ]}
        ]

    server = FakeImapServer.start(script, tls: true)
    conn = connect!(server)

    assert {:ok,
            [
              %{uid: 4, flags: ["\\Seen"], modseq: 100, gm_msgid: nil},
              %{uid: 7, flags: [], modseq: 105, gm_msgid: nil}
            ]} = ImapClient.uid_fetch_flags(conn, "1:*")

    assert :ok = FakeImapServer.await(server)
  end

  test "uid_fetch_flags requests X-GM-MSGID too and parses it when the server is X-GM-EXT-1 capable" do
    script =
      handshake_steps("IMAP4rev1 X-GM-EXT-1") ++
        [
          {:expect, "A3 UID FETCH 5,9,12 (UID FLAGS MODSEQ X-GM-MSGID)",
           then: [
             "* 1 FETCH (UID 5 FLAGS (\\Seen) MODSEQ (100) X-GM-MSGID 1278455344230334865)",
             "A3 OK FETCH completed"
           ]}
        ]

    server = FakeImapServer.start(script, tls: true)
    conn = connect!(server)

    assert {:ok, [%{uid: 5, flags: ["\\Seen"], modseq: 100, gm_msgid: "1278455344230334865"}]} =
             ImapClient.uid_fetch_flags(conn, "5,9,12")

    assert :ok = FakeImapServer.await(server)
  end

  test "uid_store_flags without unchangedsince issues plain UID STORE +FLAGS" do
    script =
      handshake_steps() ++
        [
          {:expect, ~r/^A3 UID STORE 5 \+FLAGS \(\\Seen\)$/, then: ["A3 OK STORE completed"]}
        ]

    server = FakeImapServer.start(script, tls: true)
    conn = connect!(server)

    assert {:ok, :applied} = ImapClient.uid_store_flags(conn, 5, ["\\Seen"], [], [])
    assert :ok = FakeImapServer.await(server)
  end

  test "uid_store_flags with unchangedsince: tagged OK (no MODIFIED) -> {:ok, :applied}" do
    script =
      handshake_steps("IMAP4rev1 CONDSTORE") ++
        [
          {:expect, ~r/^A3 UID STORE 5 \(UNCHANGEDSINCE 99\) \+FLAGS \(\\Seen\)$/,
           then: ["A3 OK STORE completed"]}
        ]

    server = FakeImapServer.start(script, tls: true)
    conn = connect!(server)

    assert {:ok, :applied} =
             ImapClient.uid_store_flags(conn, 5, ["\\Seen"], [], unchangedsince: 99)

    assert :ok = FakeImapServer.await(server)
  end

  test "uid_store_flags with unchangedsince: tagged OK [MODIFIED ...] -> {:ok, :modified}" do
    script =
      handshake_steps("IMAP4rev1 CONDSTORE") ++
        [
          {:expect, ~r/^A3 UID STORE 5 \(UNCHANGEDSINCE 99\) \+FLAGS \(\\Seen\)$/,
           then: ["A3 OK [MODIFIED 5] Conditional STORE failed"]}
        ]

    server = FakeImapServer.start(script, tls: true)
    conn = connect!(server)

    assert {:ok, :modified} =
             ImapClient.uid_store_flags(conn, 5, ["\\Seen"], [], unchangedsince: 99)

    assert :ok = FakeImapServer.await(server)
  end

  test "uid_store_flags with only a remove list issues UID STORE -FLAGS" do
    script =
      handshake_steps() ++
        [
          {:expect, ~r/^A3 UID STORE 5 -FLAGS \(\\Seen\)$/, then: ["A3 OK STORE completed"]}
        ]

    server = FakeImapServer.start(script, tls: true)
    conn = connect!(server)

    assert {:ok, :applied} = ImapClient.uid_store_flags(conn, 5, [], ["\\Seen"], [])
    assert :ok = FakeImapServer.await(server)
  end

  test "append sends a literal after the continuation and returns dest_uid nil without APPENDUID" do
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

    assert {:ok, %{dest_uid: nil}} = ImapClient.append(conn, "Drafts", ["\\Seen"], literal)
    assert :ok = FakeImapServer.await(server)
  end

  test "append parses dest_uid from tagged OK [APPENDUID ...] (UIDPLUS)" do
    literal = "hello"

    script =
      handshake_steps("IMAP4rev1 UIDPLUS") ++
        [
          {:expect, ~r/^A3 APPEND "Drafts" \(\\Seen\) \{#{byte_size(literal)}\}$/,
           then: ["+ Ready"]},
          {:expect_literal, byte_size(literal),
           then: ["A3 OK [APPENDUID 9 101] APPEND completed"]}
        ]

    server = FakeImapServer.start(script, tls: true)
    conn = connect!(server)

    assert {:ok, %{dest_uid: 101}} = ImapClient.append(conn, "Drafts", ["\\Seen"], literal)
    assert :ok = FakeImapServer.await(server)
  end

  test "supports?/2 probes each named capability off the post-login capability set" do
    script = handshake_steps("IMAP4rev1 MOVE UIDPLUS CONDSTORE X-GM-EXT-1")

    server = FakeImapServer.start(script, tls: true)
    conn = connect!(server)

    assert ImapClient.supports?(conn, :move)
    assert ImapClient.supports?(conn, :uidplus)
    assert ImapClient.supports?(conn, :condstore)
    assert ImapClient.supports?(conn, :gmail)
    refute ImapClient.supports?(conn, :qresync)

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
