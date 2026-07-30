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

  # -- XOAUTH2 (`auth: :oauth2`, M6 task 15) ----------------------------------

  # The exact line the client must put on the wire, as a golden: `user=user`,
  # SOH, `auth=Bearer ya29.TOKEN`, SOH, SOH — base64'd. Spelled out rather than
  # built with `Xoauth2.response/2` so the encoder and its test can never agree
  # on a wrong answer.
  @xoauth2_line "A1 AUTHENTICATE XOAUTH2 dXNlcj11c2VyAWF1dGg9QmVhcmVyIHlhMjkuVE9LRU4BAQ=="

  # The provider's failure payload: `{"status":"401",...}` base64'd. Its
  # CONTENT is never read by the client — only the fact of the continuation is.
  @xoauth2_error "eyJzdGF0dXMiOiI0MDEiLCJzY2hlbWVzIjoiQmVhcmVyIn0="

  defp oauth2_config(server), do: Map.put(config(server), :auth, :oauth2)

  test "oauth2: AUTHENTICATE XOAUTH2 replaces LOGIN, on the same tag, and AUTH=XOAUTH2 is detected" do
    # The AUTHENTICATE burns exactly ONE tag, so the post-login CAPABILITY
    # refresh is still A2 — a mechanism that consumed two would shift every
    # subsequent tag in every script this client is driven by.
    script = [
      {:send, "* OK ready"},
      {:expect, @xoauth2_line, then: ["A1 OK AUTHENTICATE completed"]},
      {:expect, "A2 CAPABILITY",
       then: ["* CAPABILITY IMAP4rev1 AUTH=XOAUTH2 MOVE", "A2 OK CAPABILITY completed"]}
    ]

    server = FakeImapServer.start(script, tls: true)

    assert {:ok, conn} = ImapClient.connect(oauth2_config(server), "ya29.TOKEN", connect_opts())
    assert ImapClient.supports?(conn, :xoauth2)
    refute ImapClient.supports?(conn, :uidplus)

    assert :ok = FakeImapServer.await(server)
  end

  test "oauth2: the failure round — server continuation, empty client line, tagged NO" do
    # A rejected token is NOT answered with a bare tagged NO: the mechanism
    # requires the client to acknowledge the `+ <base64 error>` continuation
    # with an empty line first. A client that skipped it would hang here until
    # its recv timeout on every expired token.
    script = [
      {:send, "* OK ready"},
      {:expect, @xoauth2_line, then: ["+ " <> @xoauth2_error]},
      {:expect, "", then: ["A1 NO SASL authentication failed"]}
    ]

    server = FakeImapServer.start(script, tls: true)

    assert {:error, :reauth_required} =
             ImapClient.connect(oauth2_config(server), "ya29.TOKEN", connect_opts())

    assert :ok = FakeImapServer.await(server)
  end

  test "oauth2: a bare tagged NO (no continuation) is also :reauth_required" do
    script = [
      {:send, "* OK ready"},
      {:expect, @xoauth2_line, then: ["A1 NO [AUTHENTICATIONFAILED] Invalid credentials"]}
    ]

    server = FakeImapServer.start(script, tls: true)

    assert {:error, :reauth_required} =
             ImapClient.connect(oauth2_config(server), "ya29.TOKEN", connect_opts())

    assert :ok = FakeImapServer.await(server)
  end

  test "oauth2: a tagged BAD is NOT :reauth_required — a new token cannot fix a refused command" do
    script = [
      {:send, "* OK ready"},
      {:expect, @xoauth2_line, then: ["A1 BAD Unrecognized authentication type"]}
    ]

    server = FakeImapServer.start(script, tls: true)

    assert {:error, {:bad, "Unrecognized authentication type"}} =
             ImapClient.connect(oauth2_config(server), "ya29.TOKEN", connect_opts())

    assert :ok = FakeImapServer.await(server)
  end

  test "oauth2: a server that drops the connection mid-SASL is NOT reported as :reauth_required" do
    # A dropped socket is not a refused token: reporting one as the other would
    # send the user through an OAuth re-consent over a network blip — and, worse,
    # park the account in a sticky state a fresh token cannot clear.
    script = [
      {:send, "* OK ready"},
      {:expect, @xoauth2_line, then: ["+ " <> @xoauth2_error]},
      :close
    ]

    server = FakeImapServer.start(script, tls: true)

    assert {:error, reason} =
             ImapClient.connect(oauth2_config(server), "ya29.TOKEN", connect_opts())

    refute reason == :reauth_required
    assert :ok = FakeImapServer.await(server)
  end

  test "oauth2: untagged chatter inside the exchange is read past, not mistaken for a result" do
    script = [
      {:send, "* OK ready"},
      {:expect, @xoauth2_line,
       then: ["* CAPABILITY IMAP4rev1 AUTH=XOAUTH2", "A1 OK AUTHENTICATE completed"]},
      {:expect, "A2 CAPABILITY", then: ["* CAPABILITY IMAP4rev1", "A2 OK CAPABILITY completed"]}
    ]

    server = FakeImapServer.start(script, tls: true)

    assert {:ok, conn} = ImapClient.connect(oauth2_config(server), "ya29.TOKEN", connect_opts())
    # The post-login refresh wins over the line flushed into the exchange —
    # same rule as the password path's greeting-vs-refresh test.
    refute ImapClient.supports?(conn, :xoauth2)

    assert :ok = FakeImapServer.await(server)
  end

  test "an 8-bit access token reaches the server inside the base64 response, never raising" do
    # `Wire.encode_arg`'s CR/LF/8-bit guard would raise on this value as a bare
    # argument — the SASL response is base64, so the bytes ride safely.
    token = <<0xFF, "tok">>
    expected = "A1 AUTHENTICATE XOAUTH2 dXNlcj11c2VyAWF1dGg9QmVhcmVyIP90b2sBAQ=="

    script = [
      {:send, "* OK ready"},
      {:expect, expected, then: ["A1 OK AUTHENTICATE completed"]},
      {:expect, "A2 CAPABILITY", then: ["* CAPABILITY IMAP4rev1", "A2 OK CAPABILITY completed"]}
    ]

    server = FakeImapServer.start(script, tls: true)

    assert {:ok, _conn} = ImapClient.connect(oauth2_config(server), token, connect_opts())
    assert :ok = FakeImapServer.await(server)
  end

  test "select parses UIDVALIDITY and UIDNEXT from untagged OK lines" do
    script =
      handshake_steps() ++
        [
          {:expect, ~r/^A3 SELECT "Sorted"$/,
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
             ImapClient.select(conn, "Sorted")

    assert :ok = FakeImapServer.await(server)
  end

  test "select also parses HIGHESTMODSEQ from an untagged OK line" do
    script =
      handshake_steps("IMAP4rev1 CONDSTORE") ++
        [
          {:expect, ~r/^A3 SELECT "Sorted"$/,
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
             ImapClient.select(conn, "Sorted")

    assert :ok = FakeImapServer.await(server)
  end

  test "examine/2 issues EXAMINE (read-only), never SELECT, and parses the same fields" do
    script =
      handshake_steps() ++
        [
          {:expect, ~r/^A3 EXAMINE "Archive"$/,
           then: [
             "* OK [UIDVALIDITY 55] UIDs valid",
             "* OK [UIDNEXT 9] Predicted",
             "A3 OK [READ-ONLY] EXAMINE completed"
           ]}
        ]

    server = FakeImapServer.start(script, tls: true)
    conn = connect!(server)

    assert {:ok, %{uidvalidity: 55, uidnext: 9, highestmodseq: nil}} =
             ImapClient.examine(conn, "Archive")

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
          {:expect, ~r/^A3 UID MOVE 7 "Archive"$/,
           then: ["A3 OK [COPYUID 9 7 77] MOVE completed"]}
        ]

    server = FakeImapServer.start(script, tls: true)
    conn = connect!(server)

    assert {:ok, %{dest_uid: 77}} = ImapClient.uid_move(conn, 7, "Archive")
    assert :ok = FakeImapServer.await(server)
  end

  test "move: MOVE capability but no COPYUID in the tagged OK -> dest_uid nil" do
    script =
      handshake_steps("IMAP4rev1 MOVE") ++
        [
          {:expect, ~r/^A3 UID MOVE 7 "Archive"$/, then: ["A3 OK MOVE completed"]}
        ]

    server = FakeImapServer.start(script, tls: true)
    conn = connect!(server)

    assert {:ok, %{dest_uid: nil}} = ImapClient.uid_move(conn, 7, "Archive")
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

    assert {:unsupported, reason} = ImapClient.uid_move(conn, 7, "Archive")
    assert is_binary(reason)

    assert {:ok, []} = ImapClient.list_folders(conn)
    assert :ok = FakeImapServer.await(server)
  end

  test "uid_copy issues UID COPY and parses dest_uid from tagged OK [COPYUID ...]" do
    script =
      handshake_steps() ++
        [
          {:expect, ~r/^A3 UID COPY 7 "Archive"$/,
           then: ["A3 OK [COPYUID 9 7 88] COPY completed"]}
        ]

    server = FakeImapServer.start(script, tls: true)
    conn = connect!(server)

    assert {:ok, %{dest_uid: 88}} = ImapClient.uid_copy(conn, 7, "Archive")
    assert :ok = FakeImapServer.await(server)
  end

  test "uid_copy: a COPYUID dest uid-set that is a range -> dest_uid nil, never truncated" do
    # `COPYUID 9 77 90:92` means the copy landed on destination UIDs 90-92
    # (a multi-message COPYUID can report a range/list, not just this
    # single-uid call's own uid). Truncating to the leading number (90)
    # would silently hand back a wrong-but-plausible-looking dest_uid, so an
    # unparseable (range/list) dest token must degrade to nil — the known-
    # unknown the caller (search-based confirmation) already handles.
    script =
      handshake_steps() ++
        [
          {:expect, ~r/^A3 UID COPY 7 "Archive"$/,
           then: ["A3 OK [COPYUID 9 77 90:92] COPY completed"]}
        ]

    server = FakeImapServer.start(script, tls: true)
    conn = connect!(server)

    assert {:ok, %{dest_uid: nil}} = ImapClient.uid_copy(conn, 7, "Archive")
    assert :ok = FakeImapServer.await(server)
  end

  test "uid_copy: a COPYUID dest uid-set that is a list (comma) -> dest_uid nil" do
    script =
      handshake_steps() ++
        [
          {:expect, ~r/^A3 UID COPY 7 "Archive"$/,
           then: ["A3 OK [COPYUID 9 77 90,92] COPY completed"]}
        ]

    server = FakeImapServer.start(script, tls: true)
    conn = connect!(server)

    assert {:ok, %{dest_uid: nil}} = ImapClient.uid_copy(conn, 7, "Archive")
    assert :ok = FakeImapServer.await(server)
  end

  test "append: an APPENDUID dest uid-set that is a range -> dest_uid nil, never truncated" do
    literal = "hello"

    script =
      handshake_steps("IMAP4rev1 UIDPLUS") ++
        [
          {:expect, ~r/^A3 APPEND "Drafts" \(\\Seen\) \{#{byte_size(literal)}\}$/,
           then: ["+ Ready"]},
          {:expect_literal, byte_size(literal),
           then: ["A3 OK [APPENDUID 9 101:103] APPEND completed"]}
        ]

    server = FakeImapServer.start(script, tls: true)
    conn = connect!(server)

    assert {:ok, %{dest_uid: nil}} = ImapClient.append(conn, "Drafts", ["\\Seen"], literal)
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
      handshake_steps("IMAP4rev1 X-GM-EXT-1 CONDSTORE") ++
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

  test "uid_fetch_flags omits MODSEQ (and reports modseq: nil) when the server lacks CONDSTORE" do
    # Some servers BAD the MODSEQ FETCH attribute outright when CONDSTORE
    # isn't advertised, so it must never be requested unconditionally.
    script =
      handshake_steps("IMAP4rev1") ++
        [
          {:expect, "A3 UID FETCH 1:* (UID FLAGS)",
           then: ["* 1 FETCH (UID 4 FLAGS (\\Seen))", "A3 OK FETCH completed"]}
        ]

    server = FakeImapServer.start(script, tls: true)
    conn = connect!(server)

    assert {:ok, [%{uid: 4, flags: ["\\Seen"], modseq: nil, gm_msgid: nil}]} =
             ImapClient.uid_fetch_flags(conn, "1:*")

    assert :ok = FakeImapServer.await(server)
  end

  test "uid_fetch_flags requests X-GM-MSGID without MODSEQ when gmail-capable but not CONDSTORE-capable" do
    script =
      handshake_steps("IMAP4rev1 X-GM-EXT-1") ++
        [
          {:expect, "A3 UID FETCH 5 (UID FLAGS X-GM-MSGID)",
           then: [
             "* 1 FETCH (UID 5 FLAGS (\\Seen) X-GM-MSGID 1278455344230334865)",
             "A3 OK FETCH completed"
           ]}
        ]

    server = FakeImapServer.start(script, tls: true)
    conn = connect!(server)

    assert {:ok, [%{uid: 5, flags: ["\\Seen"], modseq: nil, gm_msgid: "1278455344230334865"}]} =
             ImapClient.uid_fetch_flags(conn, "5")

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

  test "uid_store_flags: combined add+remove under unchangedsince + base_flags issues ONE atomic FLAGS replace" do
    # Splitting this into two guarded STOREs (+FLAGS then -FLAGS, both
    # UNCHANGEDSINCE-guarded) would have the first STORE's own successful
    # apply bump the message's modseq, making the second STORE deterministically
    # fail its own precondition against a baseline it just invalidated. The
    # only correct wire form is one atomic replace computed from the
    # caller-supplied current flag set (base_flags: \Seen \Answered), minus
    # \Seen (removed), plus \Flagged (added) -> \Answered \Flagged (sorted).
    script =
      handshake_steps("IMAP4rev1 CONDSTORE") ++
        [
          {:expect, ~r/^A3 UID STORE 5 \(UNCHANGEDSINCE 99\) FLAGS \(\\Answered \\Flagged\)$/,
           then: ["A3 OK STORE completed"]},
          # Proves exactly ONE STORE was issued: if uid_store_flags had
          # wrongly sent a second guarded STORE, its bytes would be sitting
          # in front of this LIST line and this regex would not match,
          # making `await/1` raise.
          {:expect, ~r/^A4 LIST "" \*$/, then: ["A4 OK LIST completed"]}
        ]

    server = FakeImapServer.start(script, tls: true)
    conn = connect!(server)

    assert {:ok, :applied} =
             ImapClient.uid_store_flags(conn, 5, ["\\Flagged"], ["\\Seen"],
               unchangedsince: 99,
               base_flags: ["\\Seen", "\\Answered"]
             )

    assert {:ok, []} = ImapClient.list_folders(conn)
    assert :ok = FakeImapServer.await(server)
  end

  test "uid_store_flags: combined add+remove atomic replace, MODIFIED -> {:ok, :modified}" do
    script =
      handshake_steps("IMAP4rev1 CONDSTORE") ++
        [
          {:expect, ~r/^A3 UID STORE 5 \(UNCHANGEDSINCE 99\) FLAGS \(\\Answered \\Flagged\)$/,
           then: ["A3 OK [MODIFIED 5] Conditional STORE failed"]}
        ]

    server = FakeImapServer.start(script, tls: true)
    conn = connect!(server)

    assert {:ok, :modified} =
             ImapClient.uid_store_flags(conn, 5, ["\\Flagged"], ["\\Seen"],
               unchangedsince: 99,
               base_flags: ["\\Seen", "\\Answered"]
             )

    assert :ok = FakeImapServer.await(server)
  end

  test "uid_store_flags: combined add+remove under unchangedsince WITHOUT base_flags raises, no connection use" do
    # No script steps beyond the handshake: if uid_store_flags used the
    # connection at all here, there is nothing left in the script to answer
    # it, and this test would hang/fail instead of cleanly raising.
    script = handshake_steps("IMAP4rev1 CONDSTORE")

    server = FakeImapServer.start(script, tls: true)
    conn = connect!(server)

    assert_raise ArgumentError, ~r/base_flags/, fn ->
      ImapClient.uid_store_flags(conn, 5, ["\\Flagged"], ["\\Seen"], unchangedsince: 99)
    end

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
          {:expect, ~r/^A3 CREATE "Custom\/Sub"$/, then: ["A3 OK CREATE completed"]}
        ]

    server = FakeImapServer.start(script, tls: true)
    conn = connect!(server)

    assert :ok = ImapClient.create_folder(conn, "Custom/Sub")
    assert :ok = FakeImapServer.await(server)
  end

  test "list_folders parses mailbox names out of untagged LIST lines" do
    script =
      handshake_steps() ++
        [
          {:expect, ~r/^A3 LIST "" \*$/,
           then: [
             "* LIST (\\HasNoChildren) \"/\" \"INBOX\"",
             "* LIST (\\HasNoChildren) \"/\" \"Sorted\"",
             "A3 OK LIST completed"
           ]}
        ]

    server = FakeImapServer.start(script, tls: true)
    conn = connect!(server)

    assert {:ok, ["INBOX", "Sorted"]} = ImapClient.list_folders(conn)
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

  # -- IDLE (RFC 2177) ------------------------------------------------------
  #
  # Handshake burns A1 (LOGIN) and A2 (CAPABILITY), so an IDLE issued as the
  # first real command is A3. `supports?(conn, :idle)` reads the same
  # post-login capability set every other gate does.

  defp idle_handshake_steps do
    handshake_steps("IMAP4rev1 IDLE") ++
      [
        {:expect, ~r/^A3 EXAMINE INBOX$/,
         then: [
           "* 3 EXISTS",
           "* OK [UIDVALIDITY 100] UIDs valid",
           "A3 OK [READ-ONLY] EXAMINE completed"
         ]}
      ]
  end

  test "supports?(conn, :idle) reflects the IDLE capability" do
    server = FakeImapServer.start(handshake_steps("IMAP4rev1 IDLE"), tls: true)
    assert ImapClient.supports?(connect!(server), :idle)
    assert :ok = FakeImapServer.await(server)

    plain = FakeImapServer.start(handshake_steps("IMAP4rev1 MOVE"), tls: true)
    refute ImapClient.supports?(connect!(plain), :idle)
    assert :ok = FakeImapServer.await(plain)
  end

  test "idle_start waits for the + continuation, and untagged pushes come back as events" do
    script =
      idle_handshake_steps() ++
        [
          {:expect, "A4 IDLE", then: ["+ idling"]},
          {:sleep, 40},
          {:send, "* 4 EXISTS"}
        ]

    server = FakeImapServer.start(script, tls: true)
    conn = connect!(server)

    assert {:ok, %{uidvalidity: 100}} = ImapClient.examine(conn, "INBOX")
    assert {:ok, idle} = ImapClient.idle_start(conn)

    # EXAMINE's own `* 3 EXISTS` belongs to that command's response, not to the
    # IDLE — the only event here is the one pushed after the continuation.
    assert {:ok, [{:exists, 4}], _idle} = ImapClient.idle_await(conn, idle, 2_000)
    assert :ok = FakeImapServer.await(server)
  end

  test "EXISTS, EXPUNGE, FETCH and a keepalive OK map to their own event shapes" do
    script =
      idle_handshake_steps() ++
        [
          {:expect, "A4 IDLE", then: ["+ idling"]},
          {:sleep, 40},
          {:send, "* 9 EXISTS"},
          {:send, "* 2 EXPUNGE"},
          {:send, ~s[* 5 FETCH (UID 77 FLAGS (\\Seen))]},
          {:send, "* OK Still here"}
        ]

    server = FakeImapServer.start(script, tls: true)
    conn = connect!(server)

    assert {:ok, _info} = ImapClient.examine(conn, "INBOX")
    assert {:ok, idle} = ImapClient.idle_start(conn)

    events = drain_events(conn, idle, 4)

    # A `* OK` heartbeat is `:other` — deliberately NOT a change (a server that
    # sends one every few minutes must not make a client resync every time).
    assert events == [{:exists, 9}, {:expunge, 2}, {:fetch, 5}, {:other, "OK Still here"}]
    assert :ok = FakeImapServer.await(server)
  end

  test "idle_await returns [] at its deadline, leaving the connection idling" do
    script =
      idle_handshake_steps() ++
        [
          {:expect, "A4 IDLE", then: ["+ idling"]},
          {:sleep, 150},
          {:send, "* 4 EXISTS"}
        ]

    server = FakeImapServer.start(script, tls: true)
    conn = connect!(server)

    assert {:ok, _info} = ImapClient.examine(conn, "INBOX")
    assert {:ok, idle} = ImapClient.idle_start(conn)

    # An empty list is a deadline, not a failure — and the SAME session then
    # picks the later push up.
    assert {:ok, [], idle} = ImapClient.idle_await(conn, idle, 20)
    assert {:ok, [{:exists, 4}], _idle} = ImapClient.idle_await(conn, idle, 2_000)
    assert :ok = FakeImapServer.await(server)
  end

  test "a response split across two reads is reassembled through the threaded session" do
    script =
      idle_handshake_steps() ++
        [
          {:expect, "A4 IDLE", then: ["+ idling"]},
          {:sleep, 40},
          # One record carrying a complete EXISTS plus HALF an EXPUNGE: the
          # first await must report the former and keep the fragment.
          {:send_raw, "* 7 EXISTS\r\n* 2 EXPU"},
          {:sleep, 60},
          {:send_raw, "NGE\r\n"}
        ]

    server = FakeImapServer.start(script, tls: true)
    conn = connect!(server)

    assert {:ok, _info} = ImapClient.examine(conn, "INBOX")
    assert {:ok, idle} = ImapClient.idle_start(conn)

    assert {:ok, [{:exists, 7}], idle} = ImapClient.idle_await(conn, idle, 2_000)
    assert {:ok, [{:expunge, 2}], _idle} = ImapClient.idle_await(conn, idle, 2_000)
    assert :ok = FakeImapServer.await(server)
  end

  test "idle_done sends DONE and reports events from inside the handshake window" do
    script =
      idle_handshake_steps() ++
        [
          {:expect, "A4 IDLE", then: ["+ idling"]},
          # A message landing between DONE leaving the client and the tagged
          # completion: the only notice of it is this reply.
          {:expect, "DONE", then: ["* 11 EXISTS", "A4 OK IDLE terminated"]},
          {:expect, "A5 IDLE", then: ["+ idling"]},
          {:expect, "DONE", then: ["A5 OK IDLE terminated"]}
        ]

    server = FakeImapServer.start(script, tls: true)
    conn = connect!(server)

    assert {:ok, _info} = ImapClient.examine(conn, "INBOX")
    assert {:ok, idle} = ImapClient.idle_start(conn)
    assert {:ok, [{:exists, 11}]} = ImapClient.idle_done(conn, idle)

    # Still in the selected state: a re-issue is just another idle_start.
    assert {:ok, idle} = ImapClient.idle_start(conn)
    assert {:ok, []} = ImapClient.idle_done(conn, idle)
    assert :ok = FakeImapServer.await(server)
  end

  test "an IDLE refused with a tagged NO is an error, not a hang" do
    script =
      idle_handshake_steps() ++
        [{:expect, "A4 IDLE", then: ["A4 NO mailbox is not idleable"]}]

    server = FakeImapServer.start(script, tls: true)
    conn = connect!(server)

    assert {:ok, _info} = ImapClient.examine(conn, "INBOX")
    assert {:error, {:no, "mailbox is not idleable"}} = ImapClient.idle_start(conn)
    assert :ok = FakeImapServer.await(server)
  end

  test "a tagged completion with no DONE sent reports the server ended the IDLE" do
    script =
      idle_handshake_steps() ++
        [
          {:expect, "A4 IDLE", then: ["+ idling"]},
          {:sleep, 40},
          {:send, "A4 OK IDLE terminated (server cutoff)"}
        ]

    server = FakeImapServer.start(script, tls: true)
    conn = connect!(server)

    assert {:ok, _info} = ImapClient.examine(conn, "INBOX")
    assert {:ok, idle} = ImapClient.idle_start(conn)

    assert {:error, {:idle_terminated, :ok, "IDLE terminated (server cutoff)"}} =
             ImapClient.idle_await(conn, idle, 2_000)

    assert :ok = FakeImapServer.await(server)
  end

  test "a dropped socket while idling surfaces as an error" do
    script =
      idle_handshake_steps() ++
        [
          {:expect, "A4 IDLE", then: ["+ idling"]},
          {:sleep, 40},
          :close
        ]

    server = FakeImapServer.start(script, tls: true)
    conn = connect!(server)

    assert {:ok, _info} = ImapClient.examine(conn, "INBOX")
    assert {:ok, idle} = ImapClient.idle_start(conn)
    assert {:error, :closed} = ImapClient.idle_await(conn, idle, 2_000)
    assert :ok = FakeImapServer.await(server)
  end

  # Awaits until `count` events have been collected — the pushes above may
  # arrive coalesced into one read or spread over several, and either is
  # correct wire behavior.
  defp drain_events(conn, idle, count, acc \\ []) do
    if length(acc) >= count do
      acc
    else
      {:ok, events, idle} = ImapClient.idle_await(conn, idle, 2_000)
      drain_events(conn, idle, count, acc ++ events)
    end
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
