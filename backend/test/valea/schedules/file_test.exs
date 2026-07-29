defmodule Valea.Schedules.FileTest do
  use ExUnit.Case, async: true

  alias Valea.Schedules.Cron
  alias Valea.Schedules.Entry

  # `Valea.Schedules.File` is never aliased here: the bare `File` in this module
  # has to stay Elixir's, because the fixtures write the ledger by hand.
  @subject Valea.Schedules.File

  setup do
    root = Path.join(System.tmp_dir!(), "schedules-icm-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    %{root: root}
  end

  # -- helpers ----------------------------------------------------------------

  defp write!(root, schedules) when is_list(schedules) do
    doc = %{"readme" => "Schedules for this ICM.", "schedules" => schedules}
    File.write!(Path.join(root, "schedules.json"), Jason.encode!(doc))
  end

  # The spec's example entry, with `overrides` merged over it. `:absent` as a
  # value removes the field, which is a different test case from a null.
  defp schedule(overrides \\ %{}) do
    %{
      "id" => "s-morning",
      "title" => "Morning inbox brief",
      "cron" => "30 7 * * 1-5",
      "timezone" => "Europe/Zurich",
      "payload" => %{"kind" => "prompt", "prompt" => "Work the inbox."},
      "paused" => false,
      "catchup" => false,
      "created_by" => "agent"
    }
    |> Map.merge(overrides)
    |> Map.reject(fn {_field, value} -> value == :absent end)
  end

  defp load_one(root, overrides) do
    write!(root, [schedule(overrides)])
    assert %{status: :ok, entries: [entry]} = @subject.load(root)
    entry
  end

  defp refused(root, overrides) do
    entry = load_one(root, overrides)
    assert entry.disposition == :not_executable
    entry.reason
  end

  defp doc_reason(root, context_doc) do
    payload = %{"kind" => "prompt", "prompt" => "Work it.", "context_doc" => context_doc}
    refused(root, %{"payload" => payload})
  end

  describe "load/1 file status" do
    test "an absent file is :absent, not an error", %{root: root} do
      assert @subject.load(root) == %{status: :absent, entries: [], hash: nil}
    end

    test "a malformed file yields no entries — nothing fires from it", %{root: root} do
      File.write!(Path.join(root, "schedules.json"), "{not json")
      assert @subject.load(root) == %{status: :unreadable, entries: [], hash: nil}
    end

    test "a non-object top level is unreadable", %{root: root} do
      File.write!(Path.join(root, "schedules.json"), ~s([{"id":"s-1"}]))
      assert %{status: :unreadable, entries: []} = @subject.load(root)
    end

    test "a wrong-typed schedules key reads clean and empty", %{root: root} do
      File.write!(Path.join(root, "schedules.json"), ~s({"schedules":"nope"}))
      assert %{status: :ok, entries: [], hash: hash} = @subject.load(root)
      assert is_binary(hash)
    end

    test "non-map array members are dropped from the view", %{root: root} do
      write!(root, [42, schedule(), "junk"])
      assert %{status: :ok, entries: [entry]} = @subject.load(root)
      assert entry.id == "s-morning"
    end

    test "the hash is the ledger's content hash", %{root: root} do
      write!(root, [schedule()])
      bytes = File.read!(Path.join(root, "schedules.json"))

      assert %{hash: hash} = @subject.load(root)
      assert hash == :crypto.hash(:sha256, bytes)
    end
  end

  describe "load/1 executable entries" do
    test "a well-formed entry is executable and fully resolved", %{root: root} do
      entry = load_one(root, %{})

      assert entry.disposition == :executable
      assert entry.reason == nil
      assert entry.id == "s-morning"
      assert entry.title == "Morning inbox brief"
      assert entry.cron_raw == "30 7 * * 1-5"
      assert %Cron{} = entry.cron
      assert entry.timezone == "Europe/Zurich"
      assert entry.payload == %{kind: :prompt, prompt: "Work the inbox.", context_doc: nil}
      assert entry.paused == false
      assert entry.catchup == false
      assert entry.created_by == "agent"
      assert String.match?(entry.fingerprint, ~r/\A[0-9a-f]{64}\z/)
    end

    test "paused is a disposition of its own, not an error", %{root: root} do
      entry = load_one(root, %{"paused" => true})

      assert entry.disposition == :paused
      assert entry.paused == true
      assert entry.reason == nil
      assert %Cron{} = entry.cron
    end

    test "absent flags default to false", %{root: root} do
      entry = load_one(root, %{"paused" => :absent, "catchup" => :absent})

      assert entry.disposition == :executable
      assert entry.paused == false
      assert entry.catchup == false
    end

    test "catchup true survives validation", %{root: root} do
      assert load_one(root, %{"catchup" => true}).catchup == true
    end

    test "an absent timezone falls back to the host zone", %{root: root} do
      entry = load_one(root, %{"timezone" => :absent})

      assert entry.disposition == :executable
      assert entry.timezone == Valea.Calendar.Engine.host_zone()
    end

    test "a command payload normalizes its args", %{root: root} do
      payload = %{"kind" => "command", "command" => "python3", "args" => ["scripts/sync.py"]}
      entry = load_one(root, %{"payload" => payload})

      assert entry.disposition == :executable
      assert entry.payload == %{kind: :command, command: "python3", args: ["scripts/sync.py"]}
    end

    test "a command payload without args gets an empty list", %{root: root} do
      payload = %{"kind" => "command", "command" => "python3"}
      assert load_one(root, %{"payload" => payload}).payload.args == []
    end

    test "a relative context_doc is kept as written", %{root: root} do
      payload = %{
        "kind" => "prompt",
        "prompt" => "Work it.",
        "context_doc" => "communications/workflows/inbox-triage.md"
      }

      entry = load_one(root, %{"payload" => payload})

      assert entry.disposition == :executable
      assert entry.payload.context_doc == "communications/workflows/inbox-triage.md"
    end

    test "the entry as read is preserved, unknown fields included", %{root: root} do
      entry = load_one(root, %{"notes" => %{"anything" => [1, 2]}})

      assert entry.raw["notes"] == %{"anything" => [1, 2]}
      assert entry.disposition == :executable
    end
  end

  describe "load/1 strict execution fields" do
    test "a missing, blank or wrong-typed id", %{root: root} do
      assert refused(root, %{"id" => :absent}) == "missing id"
      assert refused(root, %{"id" => 42}) == "missing id"
      assert refused(root, %{"id" => ""}) == "missing id"
      assert refused(root, %{"id" => "  "}) == "missing id"
      assert refused(root, %{"id" => nil}) == "missing id"
    end

    test "an unparseable, missing or wrong-typed cron", %{root: root} do
      assert refused(root, %{"cron" => "61 * * * *"}) =~ "invalid cron"
      assert refused(root, %{"cron" => "* * *"}) =~ "invalid cron"
      assert refused(root, %{"cron" => :absent}) =~ "invalid cron"
      assert refused(root, %{"cron" => 42}) =~ "invalid cron"

      # The detail travels with the reason, so the row is repairable.
      assert refused(root, %{"cron" => "61 * * * *"}) =~ "minute"
    end

    test "an unknown or wrong-typed timezone", %{root: root} do
      assert refused(root, %{"timezone" => "Mars/Phobos"}) =~ "unknown timezone"
      assert refused(root, %{"timezone" => ""}) =~ "unknown timezone"
      assert refused(root, %{"timezone" => 42}) == "`timezone` is not a string"
      assert refused(root, %{"timezone" => nil}) == "`timezone` is not a string"
    end

    test "a malformed pause attempt NEVER yields a runnable entry", %{root: root} do
      for value <- ["true", "false", 1, 0, nil, %{}] do
        entry = load_one(root, %{"paused" => value})

        assert entry.disposition == :not_executable,
               "paused: #{inspect(value)} produced #{entry.disposition}"

        assert entry.reason == "`paused` is not a boolean"
      end
    end

    test "a wrong-typed catchup", %{root: root} do
      assert refused(root, %{"catchup" => "yes"}) == "`catchup` is not a boolean"
      assert refused(root, %{"catchup" => nil}) == "`catchup` is not a boolean"
    end

    test "a missing or unusable payload", %{root: root} do
      assert refused(root, %{"payload" => :absent}) =~ "invalid payload"
      assert refused(root, %{"payload" => "prompt"}) =~ "invalid payload"
      assert refused(root, %{"payload" => []}) =~ "invalid payload"
      assert refused(root, %{"payload" => nil}) =~ "invalid payload"
      assert refused(root, %{"payload" => %{}}) =~ "unknown kind"

      assert refused(root, %{"payload" => %{"kind" => "shell", "prompt" => "x"}}) =~
               "unknown kind"

      assert refused(root, %{"payload" => %{"kind" => 1}}) =~ "unknown kind"
    end

    test "a prompt payload without a usable prompt", %{root: root} do
      assert refused(root, %{"payload" => %{"kind" => "prompt"}}) =~ "`prompt`"
      assert refused(root, %{"payload" => %{"kind" => "prompt", "prompt" => 42}}) =~ "`prompt`"
      assert refused(root, %{"payload" => %{"kind" => "prompt", "prompt" => ""}}) =~ "`prompt`"
    end

    test "a command payload without a usable command or args", %{root: root} do
      assert refused(root, %{"payload" => %{"kind" => "command"}}) =~ "`command`"
      assert refused(root, %{"payload" => %{"kind" => "command", "command" => ""}}) =~ "`command`"

      command = %{"kind" => "command", "command" => "python3"}
      assert refused(root, %{"payload" => Map.put(command, "args", "sync.py")}) =~ "`args`"
      assert refused(root, %{"payload" => Map.put(command, "args", [42])}) =~ "`args`"
      assert refused(root, %{"payload" => Map.put(command, "args", [["x"]])}) =~ "`args`"
    end

    test "a context_doc that leaves the ICM, lexically", %{root: root} do
      for doc <- ["..", "../x", "a/../../x", "/etc/passwd", "a/..", "../"] do
        assert doc_reason(root, doc) == "context_doc escapes the ICM",
               "context_doc #{inspect(doc)} was not refused"
      end
    end

    test "a blank or wrong-typed context_doc", %{root: root} do
      assert doc_reason(root, "") =~ "blank"
      assert doc_reason(root, "   ") =~ "blank"
      assert doc_reason(root, 42) == "`context_doc` is not a string"
      assert doc_reason(root, nil) == "`context_doc` is not a string"
    end
  end

  describe "load/1 duplicate ids" do
    test "every carrier of a duplicate id is excluded", %{root: root} do
      write!(root, [
        schedule(%{"id" => "s-dup", "title" => "first"}),
        schedule(%{"id" => "s-solo"}),
        schedule(%{"id" => "s-dup", "title" => "second", "paused" => true})
      ])

      assert %{status: :ok, entries: [first, solo, second]} = @subject.load(root)

      assert first.disposition == :not_executable
      assert first.reason == "duplicate id"
      assert second.disposition == :not_executable
      assert second.reason == "duplicate id"
      assert solo.disposition == :executable
    end

    test "a duplicate id outranks the carrier's own defect", %{root: root} do
      write!(root, [schedule(%{"id" => "s-dup"}), schedule(%{"id" => "s-dup", "cron" => "nope"})])

      assert %{entries: [first, second]} = @subject.load(root)
      assert first.reason == "duplicate id"
      assert second.reason == "duplicate id"
    end

    test "entries without an id are each simply missing one, not duplicates", %{root: root} do
      write!(root, [schedule(%{"id" => :absent}), schedule(%{"id" => :absent})])

      assert %{entries: [first, second]} = @subject.load(root)
      assert first.reason == "missing id"
      assert second.reason == "missing id"
    end
  end

  describe "load/1 lenient display fields" do
    test "a missing or wrong-typed title falls back to untitled", %{root: root} do
      assert load_one(root, %{"title" => :absent}).title == "untitled"
      assert load_one(root, %{"title" => 42}).title == "untitled"
      assert load_one(root, %{"title" => ""}).title == "untitled"
      assert load_one(root, %{"title" => nil}).title == "untitled"
    end

    test "a wrong-typed created_by degrades to nil", %{root: root} do
      assert load_one(root, %{"created_by" => 42}).created_by == nil
      assert load_one(root, %{"created_by" => :absent}).created_by == nil
      assert load_one(root, %{"created_by" => "user"}).created_by == "user"
    end

    test "display leniency never rescues execution", %{root: root} do
      entry = load_one(root, %{"title" => 42, "cron" => "nope"})

      assert entry.title == "untitled"
      assert entry.disposition == :not_executable
    end

    test "a refused entry still shows what it could of itself", %{root: root} do
      entry = load_one(root, %{"cron" => "nope", "paused" => true})

      assert entry.id == "s-morning"
      assert entry.cron_raw == "nope"
      assert entry.cron == nil
      # The file says paused, so the row says paused — even though the entry is
      # refused for another reason and could not run either way.
      assert entry.paused == true
    end
  end

  describe "fingerprint/1" do
    test "covers exactly the execution-control fields" do
      base = schedule()

      for field <- ~w(title created_by id paused), value <- ["changed", 42] do
        assert Entry.fingerprint(Map.put(base, field, value)) == Entry.fingerprint(base),
               "#{field} must not move the fingerprint"
      end

      assert Entry.fingerprint(Map.put(base, "unknown_field", "x")) == Entry.fingerprint(base)
    end

    test "moves for cron, payload, timezone and catchup" do
      base = schedule()

      changed = [
        %{"cron" => "0 8 * * *"},
        %{"payload" => %{"kind" => "prompt", "prompt" => "Something else."}},
        %{"timezone" => "Europe/Berlin"},
        %{"catchup" => true}
      ]

      for override <- changed do
        assert Entry.fingerprint(Map.merge(base, override)) != Entry.fingerprint(base),
               "#{inspect(override)} must move the fingerprint"
      end

      assert Entry.fingerprint(Map.delete(base, "timezone")) != Entry.fingerprint(base)
    end

    test "is independent of key order, nested objects included" do
      one = ~s({"kind":"command","command":"python3","args":["a","b"]})
      two = ~s({"args":["a","b"],"command":"python3","kind":"command"})

      assert Entry.fingerprint(schedule(%{"payload" => Jason.decode!(one)})) ==
               Entry.fingerprint(schedule(%{"payload" => Jason.decode!(two)}))
    end

    test "is present on every entry, whatever its disposition", %{root: root} do
      for overrides <- [%{}, %{"paused" => true}, %{"cron" => "nope"}] do
        entry = load_one(root, overrides)

        assert String.match?(entry.fingerprint, ~r/\A[0-9a-f]{64}\z/)
        assert entry.fingerprint == Entry.fingerprint(entry.raw)
      end
    end
  end
end
