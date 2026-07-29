defmodule Valea.Mail.SearchTest do
  @moduledoc """
  The `mail_search` FTS5 index (M3 task 8): the three feed points that keep
  it in step with the view files on disk (`Valea.Mail.Views.land/4`,
  `Views.remove_occurrence/4`'s final removal, `Valea.Mail.Index.rebuild/2`),
  and `Valea.Mail.Store.search/3`'s query path — including what happens when
  the query string is hostile.
  """
  use ExUnit.Case, async: false

  alias Valea.Mail.Index
  alias Valea.Mail.Maildir
  alias Valea.Mail.Store
  alias Valea.Mail.Views

  # pool_size: 1 — see store_test.exs for why (avoids a transient
  # "database is locked" at pool startup against a brand-new sqlite file).
  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-search-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    root = Path.join(dir, "workspace")
    File.mkdir_p!(root)

    start_supervised!({Valea.Repo, database: Path.join(dir, "app.sqlite"), pool_size: 1})

    migrations_path =
      Application.get_env(:valea, :migrations_path) || Ecto.Migrator.migrations_path(Valea.Repo)

    # `ignore_module_conflict` avoids a "redefining module" warning: every
    # test recompiles the same migration file against a brand-new sqlite db.
    previous_compiler_options = Code.compiler_options(ignore_module_conflict: true)
    Ecto.Migrator.run(Valea.Repo, migrations_path, :up, all: true)
    Code.compiler_options(previous_compiler_options)

    on_exit(fn -> File.rm_rf!(dir) end)

    %{root: root}
  end

  # -- fixtures ---------------------------------------------------------------

  @roadmap """
  From: Priya Nair <priya@example.com>\r
  To: Mara Lindt <mara@example.com>\r
  Subject: Quarterly roadmap\r
  Date: Wed, 01 Jul 2026 09:00:00 +0000\r
  Message-ID: <roadmap@example.com>\r
  \r
  We should discuss the Q3 roadmap and the hiring budget.\r
  """

  @invoice """
  From: =?utf-8?Q?J=C3=BCrgen_M=C3=BCller?= <jm@example.de>\r
  To: Mara Lindt <mara@example.com>\r
  Subject: Rechnung Juli\r
  Date: Thu, 02 Jul 2026 09:00:00 +0000\r
  Message-ID: <invoice@example.com>\r
  MIME-Version: 1.0\r
  Content-Type: text/plain; charset=utf-8\r
  \r
  Die Rechnung ist beigefügt. Bitte prüfen.\r
  """

  @lunch """
  From: Sam Okafor <sam@example.net>\r
  To: Mara Lindt <mara@example.com>\r
  Subject: Lunch plans\r
  Date: Fri, 03 Jul 2026 09:00:00 +0000\r
  Message-ID: <lunch@example.com>\r
  \r
  Shall we meet at the bistro tomorrow?\r
  """

  defp maildir_root(root, account), do: Path.join([root, "sources", "mail", account, "maildir"])

  defp setup_folder!(mroot, dir_name, imap_name) do
    abs = Path.join(mroot, dir_name)
    Maildir.mailbox_dirs(abs)
    Maildir.write_folder_identity!(abs, imap_name)
    abs
  end

  defp hits(account, query, limit \\ 40),
    do: account |> Store.search(query, limit) |> Enum.map(& &1.msg_id)

  # -- Views.land -------------------------------------------------------------

  describe "Views.land/4 feeds the index" do
    test "a landed message is findable by subject, sender and body word", %{root: root} do
      {:ok, %{msg_id: msg_id}} = Views.land(root, "mara", @roadmap)

      assert hits("mara", "roadmap") == [msg_id]
      assert hits("mara", "quarterly") == [msg_id]
      assert hits("mara", "priya") == [msg_id]
      assert hits("mara", "priya@example.com") == [msg_id]
      assert hits("mara", "hiring") == [msg_id]
    end

    test "the hit carries a body snippet", %{root: root} do
      {:ok, _} = Views.land(root, "mara", @roadmap)

      assert [%{snippet: snippet}] = Store.search("mara", "roadmap")
      assert snippet =~ "hiring budget"
    end

    test "landing the same message twice is one row, not two", %{root: root} do
      {:ok, %{msg_id: msg_id}} = Views.land(root, "mara", @roadmap)
      {:ok, %{msg_id: ^msg_id}} = Views.land(root, "mara", @roadmap)

      assert hits("mara", "roadmap") == [msg_id]
      assert search_row_count() == 1
    end

    test "the index is per-account: one account's message never surfaces in another's", %{
      root: root
    } do
      {:ok, %{msg_id: msg_id}} = Views.land(root, "account-a", @roadmap)
      {:ok, _} = Views.land(root, "account-b", @lunch)

      assert hits("account-a", "roadmap") == [msg_id]
      assert hits("account-b", "roadmap") == []
    end

    test "refresh_folders/5 is a search no-op — a flag change re-indexes nothing", %{root: root} do
      {:ok, %{msg_id: msg_id}} = Views.land(root, "mara", @roadmap)
      :ok = Views.refresh_folders(root, "mara", msg_id, ["INBOX", "Archive"], "SF")

      assert hits("mara", "roadmap") == [msg_id]
      assert search_row_count() == 1
      # The patched frontmatter is not indexed text: a folder name is not a
      # search term.
      assert hits("mara", "Archive") == []
    end

    test "landing over an intact view whose sidecar was lost adds no second row", %{root: root} do
      {:ok, %{msg_id: msg_id}} = Views.land(root, "mara", @roadmap)
      File.rm!(Path.join([root, "sources", "mail", "mara", "views", ".fingerprints", msg_id]))

      {:ok, %{msg_id: ^msg_id}} = Views.land(root, "mara", @roadmap)

      assert hits("mara", "roadmap") == [msg_id]
      assert search_row_count() == 1
    end

    test "re-landing over a view file that went missing re-indexes exactly once", %{root: root} do
      {:ok, %{msg_id: msg_id}} = Views.land(root, "mara", @roadmap)
      File.rm!(Path.join(root, Views.view_rel_path("mara", msg_id)))

      {:ok, %{msg_id: ^msg_id}} = Views.land(root, "mara", @roadmap)

      assert hits("mara", "roadmap") == [msg_id]
      assert search_row_count() == 1
    end
  end

  # -- Views.remove_occurrence ------------------------------------------------

  describe "Views.remove_occurrence/4" do
    test "the FINAL removal drops the search row", %{root: root} do
      {:ok, %{msg_id: msg_id}} = Views.land(root, "mara", @roadmap)
      assert hits("mara", "roadmap") == [msg_id]

      assert :ok = Views.remove_occurrence(root, "mara", msg_id, 0)

      assert hits("mara", "roadmap") == []
      assert search_row_count() == 0
    end

    test "a message occurring in another folder stays searchable", %{root: root} do
      {:ok, %{msg_id: msg_id}} = Views.land(root, "mara", @roadmap)

      # One of two occurrences goes away: one is left, so the shared view —
      # and the shared search row — must survive.
      assert :ok = Views.remove_occurrence(root, "mara", msg_id, 1)

      assert hits("mara", "roadmap") == [msg_id]
    end

    test "removing a message that was never landed is not an error", %{root: root} do
      assert :ok = Views.remove_occurrence(root, "mara", "never-landed", 0)
      assert search_row_count() == 0
    end
  end

  # -- Index.rebuild ----------------------------------------------------------

  describe "Index.rebuild/2 truncate-and-refeed" do
    test "rebuilds the index after it is wiped, one row per message not per occurrence", %{
      root: root
    } do
      account = "mara"
      mroot = maildir_root(root, account)
      inbox_abs = setup_folder!(mroot, "INBOX", "INBOX")
      archive_abs = setup_folder!(mroot, "Archive", "Archive")

      {:ok, %{msg_id: msg_id}} = Views.land(root, account, @roadmap)

      Maildir.deliver!(
        inbox_abs,
        Maildir.encode_filename(msg_id, 10, MapSet.new(), ":"),
        @roadmap
      )

      Maildir.deliver!(
        archive_abs,
        Maildir.encode_filename(msg_id, 3, MapSet.new(), ":"),
        @roadmap
      )

      # Simulate the lost-app.sqlite case the rebuild exists for.
      :ok = Store.clear_search_rows(account)
      assert hits(account, "roadmap") == []

      assert {:ok, 2} = Index.rebuild(root, account)

      assert hits(account, "roadmap") == [msg_id]
      assert search_row_count() == 1
    end

    test "a stale row for a view that no longer exists is dropped", %{root: root} do
      {:ok, %{msg_id: msg_id}} = Views.land(root, "mara", @roadmap)
      :ok = Store.insert_search_row("mara", "ghost", %{body: "roadmap ghost row"})

      assert length(hits("mara", "roadmap")) == 2

      assert {:ok, 0} = Index.rebuild(root, "mara")

      assert hits("mara", "roadmap") == [msg_id]
    end

    test "re-running the rebuild does not duplicate rows", %{root: root} do
      account = "mara"
      mroot = maildir_root(root, account)
      inbox_abs = setup_folder!(mroot, "INBOX", "INBOX")

      {:ok, %{msg_id: msg_id}} = Views.land(root, account, @roadmap)
      Maildir.deliver!(inbox_abs, Maildir.encode_filename(msg_id, 1, MapSet.new(), ":"), @roadmap)

      assert {:ok, 1} = Index.rebuild(root, account)
      assert {:ok, 1} = Index.rebuild(root, account)

      assert hits(account, "roadmap") == [msg_id]
      assert search_row_count() == 1
    end

    test "another account's rows survive a rebuild", %{root: root} do
      {:ok, %{msg_id: other_id}} = Views.land(root, "other", @lunch)
      {:ok, _} = Views.land(root, "mara", @roadmap)

      assert {:ok, 0} = Index.rebuild(root, "mara")

      assert hits("other", "bistro") == [other_id]
    end
  end

  # -- query behaviour --------------------------------------------------------

  describe "Store.search/3 matching" do
    setup %{root: root} do
      {:ok, %{msg_id: roadmap}} = Views.land(root, "mara", @roadmap)
      {:ok, %{msg_id: invoice}} = Views.land(root, "mara", @invoice)
      {:ok, %{msg_id: lunch}} = Views.land(root, "mara", @lunch)

      %{roadmap: roadmap, invoice: invoice, lunch: lunch}
    end

    test "matches on a prefix, not just a whole word", %{roadmap: roadmap} do
      assert hits("mara", "road") == [roadmap]
      assert hits("mara", "roadm") == [roadmap]
      assert hits("mara", "roadmaps") == []
    end

    test "multiple terms are ANDed, in any order", %{roadmap: roadmap} do
      assert hits("mara", "roadmap budget") == [roadmap]
      assert hits("mara", "budget roadmap") == [roadmap]
      # "bistro" is in a different message: no row carries both.
      assert hits("mara", "roadmap bistro") == []
    end

    test "matching is case- and diacritic-insensitive", %{invoice: invoice} do
      assert hits("mara", "RECHNUNG") == [invoice]
      assert hits("mara", "Müller") == [invoice]
      assert hits("mara", "muller") == [invoice]
    end

    test "limit is honoured and clamped", %{root: _root} do
      # All three messages carry the sender's domain.
      assert length(hits("mara", "example")) == 3
      assert length(hits("mara", "example", 2)) == 2
      # Below the floor clamps up to 1, never to "no limit" or a SQL error.
      assert length(hits("mara", "example", 0)) == 1
      assert length(hits("mara", "example", -5)) == 1
      # Above the ceiling clamps down, and simply returns everything there is.
      assert length(hits("mara", "example", 1_000_000)) == 3
    end

    test "an empty or content-free query returns nothing" do
      assert hits("mara", "") == []
      assert hits("mara", "   ") == []
      assert hits("mara", "!!!") == []
      assert hits("mara", "***") == []
      assert hits("mara", "-") == []
    end

    test "an oversized query returns nothing rather than running" do
      assert hits("mara", String.duplicate("roadmap ", 200)) == []
    end
  end

  # -- hostile queries --------------------------------------------------------

  describe "Store.search/3 against hostile query strings" do
    setup %{root: root} do
      {:ok, %{msg_id: roadmap}} = Views.land(root, "mara", @roadmap)
      {:ok, %{msg_id: lunch}} = Views.land(root, "mara", @lunch)

      %{roadmap: roadmap, lunch: lunch}
    end

    test "FTS5 boolean and proximity keywords are literal words, not operators", %{
      roadmap: roadmap
    } do
      # As operators these would broaden the search to "roadmap or bistro"
      # and "roadmap near budget"; as literal terms they demand a message
      # containing the words "or"/"near", and no message does.
      assert hits("mara", "roadmap OR bistro") == []
      assert hits("mara", "roadmap NEAR budget") == []
      assert hits("mara", "roadmap AND NOT bistro") == []
      # The keyword alone is just a word nothing contains. (It stays a
      # PREFIX term, so the fixtures deliberately carry no token starting
      # with "or" — hence `example.net`, not `example.org`.)
      assert hits("mara", "OR") == []
      assert hits("mara", "NEAR") == []
      # ...and the terms around it still work on their own.
      assert hits("mara", "roadmap") == [roadmap]
    end

    test "a column filter is not a column filter", %{roadmap: roadmap} do
      # `subject:roadmap` as FTS5 syntax would restrict to the subject
      # column; as text it becomes "subject" AND "roadmap", and nothing
      # contains the word "subject".
      assert hits("mara", "subject:roadmap") == []
      assert hits("mara", "body:bistro") == []
      assert hits("mara", "{subject from_text}:roadmap") == []
      # A column name on its own is not privileged either.
      assert hits("mara", "roadmap") == [roadmap]
    end

    test "negation and initial-token operators are stripped to plain terms", %{roadmap: roadmap} do
      assert hits("mara", "-roadmap") == [roadmap]
      assert hits("mara", "^roadmap") == [roadmap]
      assert hits("mara", "+roadmap") == [roadmap]
    end

    test "embedded and unbalanced quotes cannot break out of the quoting", %{roadmap: roadmap} do
      # An unbalanced quote would be a syntax error if it reached FTS5.
      assert hits("mara", ~s["roadmap]) == [roadmap]
      assert hits("mara", ~s[roadmap"]) == [roadmap]
      assert hits("mara", ~s["""]) == []
      # A quote inside a term is a separator, exactly like it is to the
      # tokenizer: this asks for "road" AND "map", and "roadmap" is one token.
      assert hits("mara", ~s[road"map]) == []
      # The classic escape attempt: close the quote, inject an operator.
      assert hits("mara", ~s[roadmap" OR "bistro]) == []
    end

    test "parenthesised and nested expressions are literal terms", %{roadmap: roadmap} do
      assert hits("mara", ~s[roadmap AND bistro]) == []
      assert hits("mara", "roadmap*") == [roadmap]
      assert hits("mara", "((roadmap))") == [roadmap]
    end

    test "unicode, emoji and control characters are handled without error" do
      assert hits("mara", "日本語") == []
      assert hits("mara", "🙂🙃") == []
      assert hits("mara", "road map") == []
      assert hits("mara", "\n\t\r") == []
    end

    test "terms past the cap are dropped rather than searched", %{roadmap: roadmap} do
      # Sixteen matching terms, then one that matches nothing. Short enough
      # to clear the byte cap, so the ONLY thing that can be rejecting the
      # seventeenth term is the term cap — and if it were kept, the AND
      # would return nothing.
      query = String.duplicate("roadmap ", 16) <> "zzzznomatch"
      assert byte_size(query) <= 256
      assert hits("mara", query) == [roadmap]

      # Under both caps, every term really is ANDed: fifteen filler terms
      # nothing contains exclude the message that matches the first one.
      assert hits("mara", "roadmap " <> Enum.map_join(1..15, " ", &"zzzz#{&1}")) == []
    end
  end

  # -- the transform itself ---------------------------------------------------

  describe "Store.match_expression/1" do
    test "emits quoted prefix terms" do
      assert Store.match_expression("foo bar") == {:ok, ~s["foo"* "bar"*]}
      assert Store.match_expression("  foo   ") == {:ok, ~s["foo"*]}
    end

    test "never emits anything but quoted alphanumeric terms" do
      for hostile <- [
            ~s[foo" OR "bar],
            "subject:foo",
            "-foo NEAR/3 bar",
            "foo* ^bar (baz)",
            "{a b}:foo",
            "foo\"\"bar"
          ] do
        assert {:ok, expression} = Store.match_expression(hostile)

        assert Regex.match?(~r/^"[\p{L}\p{N}]+"\*( "[\p{L}\p{N}]+"\*)*$/u, expression),
               "unexpected MATCH expression for #{inspect(hostile)}: #{inspect(expression)}"
      end
    end

    test "no tokens and oversized input are :none" do
      assert Store.match_expression("") == :none
      assert Store.match_expression("  \t ") == :none
      assert Store.match_expression("-*:\"") == :none
      assert Store.match_expression(String.duplicate("a", 257)) == :none
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp search_row_count do
    %{rows: [[count]]} = Valea.Repo.query!("SELECT count(*) FROM mail_search", [])
    count
  end
end
