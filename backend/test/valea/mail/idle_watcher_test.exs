defmodule Valea.Mail.IdleWatcherTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Valea.Mail.IdleWatcher
  alias Valea.Mail.ImapClient
  alias Valea.Mail.Settings

  # The whole IDLE conversation, end to end: the REAL `ImapClient` over real
  # TLS against `FakeImapServer` (test/support/fake_imap_server.ex) on an
  # ephemeral loopback port, with the fixture CA injected exactly the way
  # `imap_client_test.exs` does — `verify_peer` never weakened.
  #
  # `engine: self()` throughout: the watcher's trigger is a plain
  # `GenServer.cast` (`Valea.Mail.Engine.idle_activity/1`), so the test process
  # receives OTP's own cast wire message. Asserting on that shape is what keeps
  # these tests honest about what actually reaches an Engine.

  @cacertfile Path.expand("../../fixtures/tls/ca.pem", __DIR__)
  @login_re ~r/^A1 LOGIN user pass$/
  @trigger {:"$gen_cast", :idle_activity}

  # Greeting + LOGIN (A1) + post-login CAPABILITY (A2) + the watcher's
  # read-only EXAMINE (A3). The EXAMINE reply carries an `* 3 EXISTS` of its
  # own, as real servers do — a line that belongs to that command and must
  # never be mistaken for IDLE activity. Every script below therefore starts
  # the IDLE itself at A4.
  #
  # A `SELECT` anywhere here would fail the script: the watcher must never take
  # write access to the mailbox it only wants to watch.
  defp handshake_steps(capability_line \\ "IMAP4rev1 IDLE") do
    [
      {:send, "* OK ready"},
      {:expect_command, @login_re, then: ["A1 OK LOGIN completed"]},
      {:expect, "A2 CAPABILITY",
       then: ["* CAPABILITY #{capability_line}", "A2 OK CAPABILITY completed"]},
      {:expect, ~r/^A3 EXAMINE INBOX$/,
       then: [
         "* 3 EXISTS",
         "* OK [UIDVALIDITY 1] UIDs valid",
         "A3 OK [READ-ONLY] EXAMINE completed"
       ]}
    ]
  end

  defp start_watcher!(server, opts \\ []) do
    args = %{
      account: "mara",
      engine: self(),
      settings: %Settings{
        slug: "mara",
        auth: Keyword.get(opts, :auth, :password),
        imap: %{host: "localhost", port: server.port, username: "user"}
      },
      transport: ImapClient,
      credential: Keyword.get(opts, :credential, fn -> "pass" end),
      connect_opts: [tls_opts: [cacertfile: @cacertfile]],
      reissue_ms: Keyword.get(opts, :reissue_ms, 5_000),
      debounce_ms: Keyword.get(opts, :debounce_ms, 60),
      backoff_ms: Keyword.get(opts, :backoff_ms, 20)
    }

    start_supervised!({IdleWatcher, args})
  end

  test "an oauth2 account's watcher authenticates with XOAUTH2, never LOGIN" do
    # The watcher holds its own connection with the SAME credential a sync pass
    # uses, so it has to authenticate the same WAY: its settings reach the
    # client through `Settings.imap_config/1` (M6 task 15). The script below
    # would fail outright on a `LOGIN` line — which is exactly the regression
    # worth catching, since a LOGIN here would put an access token in the
    # password field on every reconnect.
    script =
      [
        {:send, "* OK ready"},
        {:expect, "A1 AUTHENTICATE XOAUTH2 dXNlcj11c2VyAWF1dGg9QmVhcmVyIHBhc3MBAQ==",
         then: ["A1 OK AUTHENTICATE completed"]},
        {:expect, "A2 CAPABILITY",
         then: ["* CAPABILITY IMAP4rev1 IDLE AUTH=XOAUTH2", "A2 OK CAPABILITY completed"]},
        {:expect, ~r/^A3 EXAMINE INBOX$/,
         then: ["* OK [UIDVALIDITY 1] UIDs valid", "A3 OK [READ-ONLY] EXAMINE completed"]},
        {:expect, "A4 IDLE", then: ["+ idling"]},
        {:sleep, 50},
        {:send, "* 4 EXISTS"},
        {:expect, "DONE", then: ["A4 OK IDLE terminated"]},
        {:expect, "A5 IDLE", then: ["+ idling"]}
      ]

    server = FakeImapServer.start(script, tls: true)
    start_watcher!(server, auth: :oauth2, reissue_ms: 500)

    assert_receive @trigger, 2_000
    assert :ok = FakeImapServer.await(server)
  end

  test "an untagged EXISTS while idling triggers exactly one sync pass" do
    script =
      handshake_steps() ++
        [
          {:expect, "A4 IDLE", then: ["+ idling"]},
          {:sleep, 50},
          {:send, "* 4 EXISTS"},
          # The re-issue at the end proves the watcher stayed in its loop
          # rather than firing once and falling over.
          {:expect, "DONE", then: ["A4 OK IDLE terminated"]},
          {:expect, "A5 IDLE", then: ["+ idling"]}
        ]

    server = FakeImapServer.start(script, tls: true)
    start_watcher!(server, reissue_ms: 500)

    assert_receive @trigger, 2_000
    refute_receive @trigger, 200

    assert :ok = FakeImapServer.await(server)
  end

  test "a burst of untagged lines spread over time yields ONE trigger, not one per line" do
    script =
      handshake_steps() ++
        [
          {:expect, "A4 IDLE", then: ["+ idling"]},
          # Four change notifications, each arriving as its own read (the
          # sleeps are what make this a debounce test rather than a batching
          # one). 30ms gaps against the 400ms quiet window below: a >13x
          # margin, so a loaded scheduler stretching a sleep can't split the
          # burst in two and turn this into a false failure.
          {:sleep, 40},
          {:send, "* 4 EXISTS"},
          {:sleep, 30},
          {:send, "* 5 EXISTS"},
          {:sleep, 30},
          {:send, "* 2 EXPUNGE"},
          {:sleep, 30},
          {:send, ~s[* 6 FETCH (UID 12 FLAGS (\\Seen))]},
          {:expect, "DONE", then: ["A4 OK IDLE terminated"]},
          {:expect, "A5 IDLE", then: ["+ idling"]}
        ]

    server = FakeImapServer.start(script, tls: true)
    start_watcher!(server, debounce_ms: 400, reissue_ms: 1_500)

    assert_receive @trigger, 3_000
    refute_receive @trigger, 500

    assert :ok = FakeImapServer.await(server)
  end

  test "an untagged OK keepalive is not mailbox change: no trigger, still idling" do
    script =
      handshake_steps() ++
        [
          {:expect, "A4 IDLE", then: ["+ idling"]},
          {:sleep, 40},
          {:send, "* OK Still here"},
          {:expect, "DONE", then: ["A4 OK IDLE terminated"]},
          {:expect, "A5 IDLE", then: ["+ idling"]}
        ]

    server = FakeImapServer.start(script, tls: true)
    start_watcher!(server, reissue_ms: 300)

    # `await` returns once the re-issued IDLE is in — so the watcher demonstrably
    # SAW the keepalive and kept going; any trigger would already be queued.
    assert :ok = FakeImapServer.await(server)
    refute_received @trigger
  end

  test "re-issues at the deadline: DONE -> tagged OK -> IDLE under a fresh tag" do
    script =
      handshake_steps() ++
        [
          {:expect, "A4 IDLE", then: ["+ idling"]},
          {:expect, "DONE", then: ["A4 OK IDLE terminated"]},
          {:expect, "A5 IDLE", then: ["+ idling"]},
          {:expect, "DONE", then: ["A5 OK IDLE terminated"]},
          {:expect, "A6 IDLE", then: ["+ idling"]}
        ]

    server = FakeImapServer.start(script, tls: true)
    start_watcher!(server, reissue_ms: 80)

    assert :ok = FakeImapServer.await(server)
    refute_received @trigger
  end

  test "activity inside the DONE handshake window still triggers a pass" do
    script =
      handshake_steps() ++
        [
          {:expect, "A4 IDLE", then: ["+ idling"]},
          # A message landing between DONE leaving the client and the tagged
          # completion — the re-issue's own reply is the only notice of it.
          {:expect, "DONE", then: ["* 12 EXISTS", "A4 OK IDLE terminated"]},
          {:expect, "A5 IDLE", then: ["+ idling"]}
        ]

    server = FakeImapServer.start(script, tls: true)
    start_watcher!(server, reissue_ms: 60)

    assert_receive @trigger, 2_000
    assert :ok = FakeImapServer.await(server)
  end

  test "a connection that dies mid-burst still triggers the pass it already saw" do
    script =
      handshake_steps() ++
        [
          {:expect, "A4 IDLE", then: ["+ idling"]},
          {:sleep, 30},
          {:send, "* 4 EXISTS"},
          # Dropped INSIDE the debounce window: the change has been observed but
          # the burst hasn't been declared over yet. The mail is real and the
          # pass has its own connection, so the trigger must not be lost with
          # the socket.
          {:sleep, 20},
          :close
        ]

    server = FakeImapServer.start(script, tls: true)
    # A long backoff keeps the reconnect out of this test's way.
    start_watcher!(server, debounce_ms: 300, backoff_ms: 5_000)

    assert_receive @trigger, 2_000
    assert :ok = FakeImapServer.await(server)
  end

  test "reconnects after the server drops the connection, and watches again" do
    first =
      handshake_steps() ++
        [
          {:expect, "A4 IDLE", then: ["+ idling"]},
          {:sleep, 40},
          :close
        ]

    second =
      handshake_steps() ++
        [
          {:expect, "A4 IDLE", then: ["+ idling"]},
          {:sleep, 40},
          {:send, "* 8 EXISTS"},
          {:expect, "DONE", then: ["A4 OK IDLE terminated"]},
          {:expect, "A5 IDLE", then: ["+ idling"]}
        ]

    server = FakeImapServer.start_sequence([first, second], tls: true)
    start_watcher!(server, backoff_ms: 20, reissue_ms: 400)

    # Only the SECOND connection pushes anything, so the trigger can only have
    # come from a watcher that reconnected — and `await` only greens once both
    # scripts, the second one's full handshake included, have run.
    assert_receive @trigger, 3_000
    assert :ok = FakeImapServer.await(server)
  end

  test "an IDLE the server refuses is retried on a fresh connection, never a crash" do
    first =
      handshake_steps() ++
        [
          {:expect, "A4 IDLE", then: ["A4 NO cannot idle right now"]},
          {:expect, "A5 LOGOUT", then: ["* BYE later", "A5 OK done"]},
          :close
        ]

    second =
      handshake_steps() ++
        [
          {:expect, "A4 IDLE", then: ["+ idling"]},
          {:sleep, 40},
          {:send, "* 9 EXISTS"},
          {:expect, "DONE", then: ["A4 OK IDLE terminated"]},
          {:expect, "A5 IDLE", then: ["+ idling"]}
        ]

    server = FakeImapServer.start_sequence([first, second], tls: true)
    watcher = start_watcher!(server, backoff_ms: 20, reissue_ms: 400)

    assert_receive @trigger, 3_000
    # Same pid: the refusal was absorbed as a backoff, not paid for out of the
    # supervisor's restart budget.
    assert Process.alive?(watcher)
    assert :ok = FakeImapServer.await(server)
  end

  test "the retry/log path never resolves the credential closure a second time" do
    # Dev runs the logger at `:debug`, which is what makes `log/3` evaluate its
    # message closure at all — and for an `auth: :oauth2` account resolving the
    # credential inside it is a call into the Engine plus, on a cache miss, a
    # live HTTPS POST to the token endpoint. On a failure path that means firing
    # a token request from inside a log statement, blocking this process for a
    # round trip, over a line a non-`:debug` build discards. So the resolution
    # count is COUNTED here rather than reasoned about.
    previous = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous) end)

    probe = self()

    counting_credential = fn ->
      send(probe, :credential_resolved)
      "pass"
    end

    # The "IDLE refused" retry — one of the four paths that reach `log/3` —
    # followed by a connection that works.
    first =
      handshake_steps() ++
        [
          {:expect, "A4 IDLE", then: ["A4 NO cannot idle right now"]},
          {:expect, "A5 LOGOUT", then: ["* BYE later", "A5 OK done"]},
          :close
        ]

    second =
      handshake_steps() ++
        [
          {:expect, "A4 IDLE", then: ["+ idling"]},
          {:sleep, 40},
          {:send, "* 9 EXISTS"},
          {:expect, "DONE", then: ["A4 OK IDLE terminated"]},
          {:expect, "A5 IDLE", then: ["+ idling"]}
        ]

    server = FakeImapServer.start_sequence([first, second], tls: true)

    # Captured only to keep the two expected debug lines out of the suite's
    # output — the point of the test is that they FIRE (a `:debug` build's
    # condition) without resolving the closure again.
    log =
      capture_log(fn ->
        start_watcher!(server, backoff_ms: 20, reissue_ms: 400, credential: counting_credential)
        assert_receive @trigger, 3_000

        # Exactly ONE resolution per connect attempt: two connects, two calls. A
        # third would be the log statement on the retry between them. Checked
        # HERE, before the script ends and the watcher reconnects a third time.
        assert_receive :credential_resolved
        assert_receive :credential_resolved
        refute_received :credential_resolved

        assert :ok = FakeImapServer.await(server)
      end)

    # The log line really did fire — otherwise this test would pass for the
    # wrong reason (a `:debug` level that never reached the statement).
    assert log =~ "IDLE refused"
  end

  test "a server without the IDLE capability: LOGOUT, then a clean :normal exit" do
    script = [
      {:send, "* OK ready"},
      {:expect_command, @login_re, then: ["A1 OK LOGIN completed"]},
      {:expect, "A2 CAPABILITY",
       then: ["* CAPABILITY IMAP4rev1 MOVE", "A2 OK CAPABILITY completed"]},
      # No EXAMINE at all — the capability gate stops before the mailbox is
      # touched, and LOGOUT takes the A3 tag the EXAMINE would have had.
      {:expect, "A3 LOGOUT", then: ["* BYE later", "A3 OK done"]},
      :close
    ]

    server = FakeImapServer.start(script, tls: true)
    watcher = start_watcher!(server)
    ref = Process.monitor(watcher)

    # `:normal`, so `restart: :transient` makes it final: no reconnect loop
    # against a server whose answer cannot change.
    assert_receive {:DOWN, ^ref, :process, ^watcher, :normal}, 2_000
    assert :ok = FakeImapServer.await(server)
    refute_received @trigger
  end

  test "a server that never answers the connect is retried, not crashed" do
    # Nothing is listening on this port at all (the server is started only
    # after the watcher has already failed its first connects).
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)

    watcher =
      start_supervised!(
        {IdleWatcher,
         %{
           account: "mara",
           engine: self(),
           settings: %Settings{
             slug: "mara",
             imap: %{host: "localhost", port: port, username: "user"}
           },
           transport: ImapClient,
           credential: fn -> "pass" end,
           connect_opts: [tls_opts: [cacertfile: @cacertfile]],
           backoff_ms: 10
         }}
      )

    # Several backoff cycles later it is still the same, still-alive process:
    # an unreachable server is a latency cost, never a crash loop.
    Process.sleep(120)
    assert Process.alive?(watcher)
    refute_received @trigger
  end
end
