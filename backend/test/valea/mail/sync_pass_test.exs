defmodule Valea.Mail.SyncPassTest do
  use ExUnit.Case, async: false

  alias Valea.Mail.Store
  alias Valea.Mail.SyncPass
  alias Valea.Mail.Store.UidOutcome

  require Ash.Query

  @fixtures_dir Path.expand("../../fixtures/mail", __DIR__)

  defp fixture(name), do: File.read!(Path.join(@fixtures_dir, name))

  # The header block a real `uid_fetch_headers` would return — everything up
  # to (and including) the blank separator line.
  defp header_block(raw) do
    case :binary.split(raw, ["\r\n\r\n", "\n\n"]) do
      [headers, _body] -> headers
      [only] -> only
    end
  end

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-syncpass-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    root = Path.join(dir, "workspace")
    File.mkdir_p!(Path.join(root, "sources/mail/messages"))

    # pool_size: 1 — same rationale as store_test/index_test: one sequential
    # test process, and it dodges the brand-new-sqlite "database is locked"
    # startup race.
    start_supervised!({Valea.Repo, database: Path.join(dir, "app.sqlite"), pool_size: 1})

    migrations_path =
      Application.get_env(:valea, :migrations_path) || Ecto.Migrator.migrations_path(Valea.Repo)

    previous_compiler_options = Code.compiler_options(ignore_module_conflict: true)
    Ecto.Migrator.run(Valea.Repo, migrations_path, :up, all: true)
    Code.compiler_options(previous_compiler_options)

    start_supervised!({FakeMailTransport, []})

    on_exit(fn -> File.rm_rf!(dir) end)

    %{root: root, dir: dir}
  end

  # TEMP v3-bridge: removed in Task 9 — `Valea.Mail.Settings` is now a v4
  # per-account struct with no `account`/`folders.review`/
  # `sync.inbox_index_limit` fields, so `SyncPass`'s ctx.settings is (for now)
  # this plain v3-shaped map, not a real `%Settings{}`. See
  # `Valea.Mail.Engine`'s `load_settings/1`.
  defp settings(overrides \\ %{}) do
    sync =
      Map.merge(
        %{interval_minutes: 5, max_message_bytes: 10_485_760, inbox_index_limit: 200},
        Map.get(overrides, :sync, %{})
      )

    %{
      account: "mara@example.com",
      imap: %{host: "imap.example.test", port: 993, username: "mara@example.com"},
      folders: %{review: "AI/Review", processed: "AI/Processed", drafts: "Drafts"},
      sync: sync
    }
  end

  defp run(root, settings) do
    SyncPass.run(%{
      root: root,
      settings: settings,
      credential: fn -> "app-password" end,
      transport: FakeMailTransport
    })
  end

  defp message_files(root), do: Path.wildcard(Path.join(root, "sources/mail/messages/*.md"))

  test "first pass lands review messages, writes attachments, builds inbox.md", %{root: root} do
    plain = fixture("plain.eml")
    b64 = fixture("base64_attachment.eml")

    FakeMailTransport.script([
      {:connect, :_, {:ok, FakeMailTransport}},
      {:select, fn [_c, f] -> f == "AI/Review" end, {:ok, %{uidvalidity: 100, uidnext: 20}}},
      {:select, fn [_c, f] -> f == "INBOX" end, {:ok, %{uidvalidity: 200, uidnext: 5}}},
      {:uid_search, :_, {:ok, [10, 11]}},
      {:uid_fetch_meta, :_,
       {:ok, [%{uid: 10, size: byte_size(plain)}, %{uid: 11, size: byte_size(b64)}]}},
      {:uid_fetch_full, fn [_c, uid] -> uid == 10 end, {:ok, plain}},
      {:uid_fetch_full, fn [_c, uid] -> uid == 11 end, {:ok, b64}},
      {:uid_fetch_headers, :_,
       {:ok, [%{uid: 10, header: header_block(plain)}, %{uid: 11, header: header_block(b64)}]}},
      {:logout, :_, :ok}
    ])

    Phoenix.PubSub.subscribe(Valea.PubSub, "mail")

    assert {:ok, %{new_messages: 2, errors: []}} = run(root, settings())

    # two review message files landed
    files = message_files(root)
    assert length(files) == 2

    # the attachment landed under its message's dir with correct bytes
    attachments = Path.wildcard(Path.join(root, "sources/mail/attachments/**/notes.txt"))
    assert [attachment_path] = attachments
    assert File.read!(attachment_path) == "Meeting notes: discuss Q3 roadmap.\n"

    # inbox.md regenerated with a row per header
    inbox = File.read!(Path.join(root, "sources/mail/inbox.md"))
    assert inbox =~ "| date | from | subject |"
    assert inbox =~ "Question about leadership coaching"
    assert inbox =~ "Notes attached"

    # message index populated; each landing emitted an upsert
    assert length(Store.list_messages()) == 2
    assert_receive {:mail_message_upserted, %{path: "sources/mail/messages/" <> _}}
    assert_receive {:mail_message_upserted, %{path: "sources/mail/messages/" <> _}}
  end

  test "second pass over the same UIDs is idempotent: 0 new, no duplicate files", %{root: root} do
    plain = fixture("plain.eml")

    script = fn ->
      FakeMailTransport.script([
        {:connect, :_, {:ok, FakeMailTransport}},
        {:select, fn [_c, f] -> f == "AI/Review" end, {:ok, %{uidvalidity: 100, uidnext: 20}}},
        {:select, fn [_c, f] -> f == "INBOX" end, {:ok, %{uidvalidity: 200, uidnext: 5}}},
        {:uid_search, :_, {:ok, [10]}},
        {:uid_fetch_meta, :_, {:ok, [%{uid: 10, size: byte_size(plain)}]}},
        {:uid_fetch_full, :_, {:ok, plain}},
        {:uid_fetch_headers, :_, {:ok, [%{uid: 10, header: header_block(plain)}]}},
        {:logout, :_, :ok}
      ])
    end

    script.()
    assert {:ok, %{new_messages: 1, errors: []}} = run(root, settings())
    assert length(message_files(root)) == 1

    script.()
    assert {:ok, %{new_messages: 0, errors: []}} = run(root, settings())
    assert length(message_files(root)) == 1
  end

  test "UIDVALIDITY change clears folder state and re-lands dedupe by Message-ID (no dup file)",
       %{root: root} do
    plain = fixture("plain.eml")

    # A live Audit records the resync so we can assert the reset happened.
    start_supervised!({Valea.Audit, %{root: root, generation: 1}})

    FakeMailTransport.script([
      {:connect, :_, {:ok, FakeMailTransport}},
      {:select, fn [_c, f] -> f == "AI/Review" end, {:ok, %{uidvalidity: 100, uidnext: 20}}},
      {:select, fn [_c, f] -> f == "INBOX" end, {:ok, %{uidvalidity: 200, uidnext: 5}}},
      {:uid_search, :_, {:ok, [10]}},
      {:uid_fetch_meta, :_, {:ok, [%{uid: 10, size: byte_size(plain)}]}},
      {:uid_fetch_full, :_, {:ok, plain}},
      {:uid_fetch_headers, :_, {:ok, [%{uid: 10, header: header_block(plain)}]}},
      {:logout, :_, :ok}
    ])

    assert {:ok, %{new_messages: 1, errors: []}} = run(root, settings())
    assert [file] = message_files(root)
    before_bytes = File.read!(file)

    # Second pass: Review's UIDVALIDITY changed -> clean resync (ALL) but the
    # same message re-lands and must dedupe on Message-ID, not re-write.
    FakeMailTransport.script([
      {:connect, :_, {:ok, FakeMailTransport}},
      {:select, fn [_c, f] -> f == "AI/Review" end, {:ok, %{uidvalidity: 999, uidnext: 30}}},
      {:select, fn [_c, f] -> f == "INBOX" end, {:ok, %{uidvalidity: 200, uidnext: 5}}},
      {:uid_search, :_, {:ok, [10]}},
      {:uid_fetch_meta, :_, {:ok, [%{uid: 10, size: byte_size(plain)}]}},
      {:uid_fetch_full, :_, {:ok, plain}},
      {:uid_fetch_headers, :_, {:ok, [%{uid: 10, header: header_block(plain)}]}},
      {:logout, :_, :ok}
    ])

    assert {:ok, %{new_messages: 0, errors: []}} = run(root, settings())

    # exactly one file, byte-identical (dedupe, never re-written)
    assert message_files(root) == [file]
    assert File.read!(file) == before_bytes

    # the resync was audited
    Valea.Audit.append_sync("__flush__", %{})
    audit = File.read!(Path.join(root, "logs/audit.jsonl"))
    assert audit =~ "mail_folder_resync"
  end

  test "oversized message lands a headers-only file with a truncation note", %{root: root} do
    plain = fixture("plain.eml")

    FakeMailTransport.script([
      {:connect, :_, {:ok, FakeMailTransport}},
      {:select, fn [_c, f] -> f == "AI/Review" end, {:ok, %{uidvalidity: 100, uidnext: 20}}},
      {:select, fn [_c, f] -> f == "INBOX" end, {:ok, %{uidvalidity: 200, uidnext: 5}}},
      {:uid_search, fn [_c, crit] -> crit == "ALL" end, {:ok, [10]}},
      # size exceeds the (tiny) cap -> oversize path
      {:uid_fetch_meta, :_, {:ok, [%{uid: 10, size: 5_000_000}]}},
      {:uid_fetch_headers, :_, {:ok, [%{uid: 10, header: header_block(plain)}]}},
      {:logout, :_, :ok}
    ])

    assert {:ok, %{new_messages: 1, errors: []}} =
             run(root, settings(%{sync: %{max_message_bytes: 100}}))

    assert [file] = message_files(root)
    contents = File.read!(file)
    assert contents =~ "truncation_note:"
    # headers-only: the sender's subject is present, the body is not
    assert contents =~ "Question about leadership coaching"
    refute contents =~ "I found your work through a colleague"

    # recorded as skipped_oversize, not synced
    assert [%{outcome: "skipped_oversize"}] =
             UidOutcome
             |> Ash.Query.filter(folder == "AI/Review" and uid == 10)
             |> Ash.read!()
  end

  test "a single message that errors is recorded failed; the pass continues", %{root: root} do
    plain = fixture("plain.eml")

    FakeMailTransport.script([
      {:connect, :_, {:ok, FakeMailTransport}},
      {:select, fn [_c, f] -> f == "AI/Review" end, {:ok, %{uidvalidity: 100, uidnext: 20}}},
      {:select, fn [_c, f] -> f == "INBOX" end, {:ok, %{uidvalidity: 200, uidnext: 5}}},
      {:uid_search, :_, {:ok, [10, 11]}},
      {:uid_fetch_meta, :_,
       {:ok, [%{uid: 10, size: byte_size(plain)}, %{uid: 11, size: byte_size(plain)}]}},
      {:uid_fetch_full, fn [_c, uid] -> uid == 10 end, {:ok, plain}},
      # uid 11 fails to fetch -> recorded failed, pass keeps going
      {:uid_fetch_full, fn [_c, uid] -> uid == 11 end, {:error, :boom}},
      {:uid_fetch_headers, :_, {:ok, []}},
      {:logout, :_, :ok}
    ])

    assert {:ok, %{new_messages: 1, errors: [error]}} = run(root, settings())
    assert error =~ "11"

    # uid 10 landed; uid 11 is retryable (failed, attempts < 3)
    assert length(message_files(root)) == 1
    assert Store.outcomes("AI/Review").retryable == [11]
  end

  test "auth failure propagates verbatim", %{root: root} do
    FakeMailTransport.script([
      {:connect, :_, {:error, :auth_failed}}
    ])

    assert {:error, :auth_failed} = run(root, settings())
    assert message_files(root) == []
  end

  test "a skipped_oversize outcome alone prevents re-fetch, without any high-water mark",
       %{root: root} do
    # Only the outcome row exists — no sync state, so high_water is nil and
    # the search is a fresh "ALL" that returns the UID again. Exclusion must
    # come from outcomes.skipped, not from the watermark.
    Store.record_outcome("AI/Review", 10, :skipped_oversize, "prior-msg-id")

    FakeMailTransport.script([
      {:connect, :_, {:ok, FakeMailTransport}},
      {:select, :_, {:ok, %{uidvalidity: 100, uidnext: 20}}},
      {:uid_search, fn [_c, crit] -> crit == "ALL" end, {:ok, [10]}},
      # INBOX (same "ALL" search result) still fetches its headers
      {:uid_fetch_headers, :_, {:ok, []}},
      {:logout, :_, :ok}
    ])

    assert {:ok, %{new_messages: 0, errors: []}} = run(root, settings())

    # the oversized UID was never a candidate: no meta/full fetch happened
    refute Enum.any?(FakeMailTransport.calls(), &match?({:uid_fetch_meta, _}, &1))
    refute Enum.any?(FakeMailTransport.calls(), &match?({:uid_fetch_full, _}, &1))
    assert message_files(root) == []

    # and the review watermark still hasn't advanced — the exclusion does
    # not rest on high-water
    assert {:ok, %{high_water_uid: nil}} = Store.get_sync_state("AI/Review")
  end

  test "inbox header fetch failure keeps the watermark; the next pass retries", %{root: root} do
    plain = fixture("plain.eml")

    # Park the Review folder behind a watermark so its search criteria
    # ("UID 51:*") is distinguishable from INBOX's fresh "ALL".
    Store.put_sync_state("AI/Review", 100, 50)

    script = fn headers_result ->
      FakeMailTransport.script([
        {:connect, :_, {:ok, FakeMailTransport}},
        {:select, :_, {:ok, %{uidvalidity: 100, uidnext: 20}}},
        {:uid_search, fn [_c, crit] -> crit == "UID 51:*" end, {:ok, []}},
        {:uid_search, fn [_c, crit] -> crit == "ALL" end, {:ok, [5]}},
        {:uid_fetch_headers, :_, headers_result},
        {:logout, :_, :ok}
      ])
    end

    script.({:error, :timeout})
    assert {:ok, %{new_messages: 0, errors: [error]}} = run(root, settings())
    assert error =~ "inbox header fetch failed"

    # the INBOX watermark did NOT advance past the unfetched header
    assert {:ok, %{high_water_uid: nil}} = Store.get_sync_state("INBOX")

    # next pass retries the same UID and succeeds
    script.({:ok, [%{uid: 5, header: header_block(plain)}]})
    assert {:ok, %{new_messages: 0, errors: []}} = run(root, settings())

    inbox = File.read!(Path.join(root, "sources/mail/inbox.md"))
    assert inbox =~ "Question about leadership coaching"
    assert {:ok, %{high_water_uid: 5}} = Store.get_sync_state("INBOX")
  end

  test "a write-stage raise records failed and the pass continues", %{root: root} do
    plain = fixture("plain.eml")
    b64 = fixture("base64_attachment.eml")

    # Block the attachment landing dir with a plain file: uid 11's
    # attachment write raises (mkdir_p! through a file), uid 10 (no
    # attachments) is unaffected.
    File.write!(Path.join(root, "sources/mail/attachments"), "not a directory")

    FakeMailTransport.script([
      {:connect, :_, {:ok, FakeMailTransport}},
      {:select, :_, {:ok, %{uidvalidity: 100, uidnext: 20}}},
      {:uid_search, :_, {:ok, [10, 11]}},
      {:uid_fetch_meta, :_,
       {:ok, [%{uid: 10, size: byte_size(plain)}, %{uid: 11, size: byte_size(b64)}]}},
      {:uid_fetch_full, fn [_c, uid] -> uid == 10 end, {:ok, plain}},
      {:uid_fetch_full, fn [_c, uid] -> uid == 11 end, {:ok, b64}},
      {:uid_fetch_headers, :_, {:ok, []}},
      {:logout, :_, :ok}
    ])

    assert {:ok, %{new_messages: 1, errors: [error]}} = run(root, settings())
    assert error =~ "uid 11"

    # uid 10 landed; uid 11 failed mid-write and is retryable
    assert length(message_files(root)) == 1
    assert Store.outcomes("AI/Review").retryable == [11]
  end
end
