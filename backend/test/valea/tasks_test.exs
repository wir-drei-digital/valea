defmodule Valea.TasksTest do
  # async: false — `Valea.Ledger.Writer` registers under its module name
  # (one writer for the open workspace), so two test modules starting one
  # concurrently would clash on the name.
  use ExUnit.Case, async: false

  alias Valea.Tasks

  @readme "Task ledger for this ICM. Managed by Valea and agents. Contract: .valea/briefing.md"

  setup do
    start_supervised!(Valea.Ledger.Writer)

    root = Path.join(System.tmp_dir!(), "tasks-icm-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    %{root: root}
  end

  # -- helpers ----------------------------------------------------------------

  defp read_doc(root), do: root |> Tasks.tasks_path() |> File.read!() |> Jason.decode!()

  defp write_doc!(root, doc), do: File.write!(Tasks.tasks_path(root), Jason.encode!(doc))

  # An agent-style write from outside Valea's writer: read what's on disk,
  # append an entry, write it back compactly. Changes the content hash, which
  # is what makes the in-flight Valea patch conflict.
  defp external_add!(root, entry) do
    doc = read_doc(root)
    write_doc!(root, Map.put(doc, "tasks", doc["tasks"] ++ [entry]))
  end

  defp external_remove!(root, id) do
    doc = read_doc(root)
    write_doc!(root, Map.put(doc, "tasks", Enum.reject(doc["tasks"], &(&1["id"] == id))))
  end

  defp task(root, id), do: Enum.find(Tasks.list(root).tasks, &(&1["id"] == id))

  defp ids(root), do: Tasks.list(root).tasks |> Enum.map(& &1["id"])

  defp days_ago(days) do
    DateTime.utc_now()
    |> DateTime.add(-days * 86_400, :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp archive_lines(root) do
    root
    |> Tasks.archive_path()
    |> File.read!()
    |> String.split("\n", trim: true)
  end

  # -- create -----------------------------------------------------------------

  describe "create/2" do
    test "on an absent file materializes the spec skeleton", %{root: root} do
      assert {:ok, entry} = Tasks.create(root, %{"title" => "Send Kita offer follow-up"})

      doc = read_doc(root)
      assert doc["readme"] == @readme
      assert Map.keys(doc) |> Enum.sort() == ["readme", "tasks"]
      assert doc["tasks"] == [entry]
      assert File.read!(Tasks.tasks_path(root)) |> String.ends_with?("\n")
    end

    test "stamps id, status, created_by and timestamps", %{root: root} do
      assert {:ok, entry} = Tasks.create(root, %{"title" => "x"})

      assert entry["id"] =~ ~r/^t-[0-9a-f]{6}$/
      assert entry["title"] == "x"
      assert entry["status"] == "open"
      assert entry["created_by"] == "user"
      assert entry["done_at"] == nil
      assert entry["created_at"] == entry["updated_at"]
      assert {:ok, %DateTime{}, 0} = DateTime.from_iso8601(entry["created_at"])
      assert String.ends_with?(entry["created_at"], "Z")
    end

    test "caller-provided fields win over the defaults", %{root: root} do
      fields = %{
        "id" => "t-abc123",
        "title" => "agent task",
        "status" => "in_progress",
        "created_by" => "agent",
        "assignee" => "agent",
        "custom" => %{"a" => 1}
      }

      assert {:ok, entry} = Tasks.create(root, fields)
      assert entry["id"] == "t-abc123"
      assert entry["status"] == "in_progress"
      assert entry["created_by"] == "agent"
      assert entry["assignee"] == "agent"
      assert entry["custom"] == %{"a" => 1}
      assert task(root, "t-abc123")["custom"] == %{"a" => 1}
    end

    test "atom-keyed fields are normalized to string keys", %{root: root} do
      assert {:ok, entry} = Tasks.create(root, %{title: "atoms", priority: "high"})
      assert entry["title"] == "atoms"
      assert entry["priority"] == "high"
      assert read_doc(root)["tasks"] == [entry]
    end

    test "appends to an existing ledger, preserving unknown keys and junk members",
         %{root: root} do
      write_doc!(root, %{
        "readme" => "hand written",
        "schema_version" => 7,
        "tasks" => [%{"id" => "t-old", "title" => "old"}, 42]
      })

      assert {:ok, entry} = Tasks.create(root, %{"title" => "new"})

      doc = read_doc(root)
      assert doc["readme"] == "hand written"
      assert doc["schema_version"] == 7
      assert doc["tasks"] == [%{"id" => "t-old", "title" => "old"}, 42, entry]
      # the non-map member is dropped from the view but never from the file
      assert ids(root) == ["t-old", entry["id"]]
    end

    test "materializes the list key on a doc that has none", %{root: root} do
      write_doc!(root, %{"readme" => "no list yet"})

      assert {:ok, entry} = Tasks.create(root, %{"title" => "first"})
      assert read_doc(root)["tasks"] == [entry]
      assert read_doc(root)["readme"] == "no list yet"
    end

    test "generated ids do not collide with an existing entry", %{root: root} do
      {:ok, a} = Tasks.create(root, %{"title" => "a"})
      {:ok, b} = Tasks.create(root, %{"title" => "b"})
      refute a["id"] == b["id"]
    end

    test "malformed ledger is :unreadable and left untouched", %{root: root} do
      File.write!(Tasks.tasks_path(root), "{not json")

      assert Tasks.create(root, %{"title" => "x"}) == {:error, :unreadable}
      assert File.read!(Tasks.tasks_path(root)) == "{not json"
    end

    test "wrong-typed list key is :unreadable and left untouched", %{root: root} do
      write_doc!(root, %{"tasks" => "nope"})

      assert Tasks.create(root, %{"title" => "x"}) == {:error, :unreadable}
      assert read_doc(root)["tasks"] == "nope"
    end

    test "re-applies against a file that changed mid-write", %{root: root} do
      {:ok, _first} = Tasks.create(root, %{"title" => "first"})

      hook = fn
        1 -> external_add!(root, %{"id" => "t-ext", "title" => "from an agent"})
        _later_attempt -> :ok
      end

      assert {:ok, entry} = Tasks.create(root, %{"title" => "mine"}, before_write: hook)
      assert "t-ext" in ids(root)
      assert entry["id"] in ids(root)
      assert length(ids(root)) == 3
    end

    test "gives up with :conflict when contention persists", %{root: root} do
      {:ok, first} = Tasks.create(root, %{"title" => "first"})
      hook = fn attempt -> external_add!(root, %{"id" => "t-ext#{attempt}"}) end

      assert Tasks.create(root, %{"title" => "mine"}, before_write: hook) == {:error, :conflict}
      assert ids(root) == [first["id"], "t-ext1", "t-ext2", "t-ext3"]
    end
  end

  # -- list -------------------------------------------------------------------

  describe "list/1" do
    test "absent ledger", %{root: root} do
      assert Tasks.list(root) == %{status: :absent, tasks: []}
    end

    test "malformed ledger", %{root: root} do
      File.write!(Tasks.tasks_path(root), "{not json")
      assert Tasks.list(root) == %{status: :unreadable, tasks: []}
    end

    test "drops non-map members, keeps unknown fields and file order", %{root: root} do
      write_doc!(root, %{
        "tasks" => [%{"id" => "t-2", "custom" => true}, "junk", %{"id" => "t-1"}]
      })

      assert %{status: :ok, tasks: [a, b]} = Tasks.list(root)
      assert a == %{"id" => "t-2", "custom" => true}
      assert b == %{"id" => "t-1"}
    end
  end

  # -- patch ------------------------------------------------------------------

  describe "patch/3" do
    test "merges fields, bumps updated_at, preserves unknown fields", %{root: root} do
      write_doc!(root, %{
        "tasks" => [
          %{
            "id" => "t-1",
            "title" => "old",
            "status" => "open",
            "custom" => %{"a" => 1},
            "created_at" => days_ago(3),
            "updated_at" => days_ago(3)
          }
        ]
      })

      assert {:ok, entry} = Tasks.patch(root, "t-1", %{"title" => "new", "priority" => "high"})

      assert entry["title"] == "new"
      assert entry["priority"] == "high"
      assert entry["custom"] == %{"a" => 1}
      assert entry["created_at"] == days_ago(3)
      refute entry["updated_at"] == days_ago(3)
      assert {:ok, %DateTime{}, 0} = DateTime.from_iso8601(entry["updated_at"])
      assert task(root, "t-1") == entry
    end

    test "entering a completed status stamps done_at; leaving one clears it", %{root: root} do
      {:ok, t} = Tasks.create(root, %{"title" => "x"})
      id = t["id"]

      assert {:ok, done} = Tasks.patch(root, id, %{"status" => "done"})
      assert done["status"] == "done"
      assert is_binary(done["done_at"])

      assert {:ok, still} = Tasks.patch(root, id, %{"title" => "renamed"})
      assert still["done_at"] == done["done_at"]

      assert {:ok, reopened} = Tasks.patch(root, id, %{"status" => "open"})
      assert reopened["done_at"] == nil

      assert {:ok, dropped} = Tasks.patch(root, id, %{"status" => "dropped"})
      assert is_binary(dropped["done_at"])
    end

    test "an explicit done_at in the patch wins", %{root: root} do
      {:ok, t} = Tasks.create(root, %{"title" => "x"})
      stamp = days_ago(20)

      assert {:ok, entry} =
               Tasks.patch(root, t["id"], %{"status" => "done", "done_at" => stamp})

      assert entry["done_at"] == stamp
    end

    test "unknown id, absent file and malformed file", %{root: root} do
      assert Tasks.patch(root, "t-nope", %{"status" => "done"}) == {:error, :not_found}

      {:ok, _t} = Tasks.create(root, %{"title" => "x"})
      assert Tasks.patch(root, "t-nope", %{"status" => "done"}) == {:error, :not_found}

      File.write!(Tasks.tasks_path(root), "{not json")
      assert Tasks.patch(root, "t-nope", %{"status" => "done"}) == {:error, :unreadable}
    end

    test "duplicate ids: the first occurrence wins and the other is untouched", %{root: root} do
      write_doc!(root, %{
        "tasks" => [
          %{"id" => "t-dup", "title" => "first"},
          %{"id" => "t-dup", "title" => "second"}
        ]
      })

      assert {:ok, entry} = Tasks.patch(root, "t-dup", %{"status" => "done"})
      assert entry["title"] == "first"

      assert [first, second] = Tasks.list(root).tasks
      assert first["status"] == "done"
      assert second == %{"id" => "t-dup", "title" => "second"}
    end

    test "a patch after an external rewrite lands and keeps the external sibling",
         %{root: root} do
      {:ok, t} = Tasks.create(root, %{"title" => "mine"})
      external_add!(root, %{"id" => "t-ext", "title" => "from an agent"})

      assert {:ok, entry} = Tasks.patch(root, t["id"], %{"status" => "in_progress"})
      assert entry["status"] == "in_progress"
      assert ids(root) == [t["id"], "t-ext"]
      assert task(root, "t-ext")["title"] == "from an agent"
    end

    test "re-applies the patch against a file that changed mid-write", %{root: root} do
      {:ok, t} = Tasks.create(root, %{"title" => "mine"})

      hook = fn
        1 -> external_add!(root, %{"id" => "t-ext", "title" => "from an agent"})
        _later_attempt -> :ok
      end

      assert {:ok, entry} =
               Tasks.patch(root, t["id"], %{"status" => "done"}, before_write: hook)

      assert entry["status"] == "done"
      assert task(root, t["id"])["status"] == "done"
      assert task(root, "t-ext")["title"] == "from an agent"
    end

    test "an entry that vanishes under the retry is :not_found", %{root: root} do
      {:ok, t} = Tasks.create(root, %{"title" => "mine"})

      hook = fn
        1 ->
          external_add!(root, %{"id" => "t-ext"})
          external_remove!(root, t["id"])

        _later_attempt ->
          :ok
      end

      assert Tasks.patch(root, t["id"], %{"status" => "done"}, before_write: hook) ==
               {:error, :not_found}

      assert ids(root) == ["t-ext"]
    end

    test "persistent contention is :conflict with nothing written", %{root: root} do
      {:ok, t} = Tasks.create(root, %{"title" => "mine"})
      hook = fn attempt -> external_add!(root, %{"id" => "t-ext#{attempt}"}) end

      assert Tasks.patch(root, t["id"], %{"status" => "done"}, before_write: hook) ==
               {:error, :conflict}

      assert ids(root) == [t["id"], "t-ext1", "t-ext2", "t-ext3"]
      assert task(root, t["id"])["status"] == "open"
    end
  end

  # -- snapshot_hash ----------------------------------------------------------

  describe "snapshot_hash/1" do
    test "is lowercase hex sha256, independent of key order", %{root: _root} do
      a = %{"id" => "t-1", "title" => "x", "nested" => %{"b" => 2, "a" => [1, %{"z" => 1}]}}
      b = %{"nested" => %{"a" => [1, %{"z" => 1}], "b" => 2}, "title" => "x", "id" => "t-1"}

      hash = Tasks.snapshot_hash(a)
      assert hash =~ ~r/^[0-9a-f]{64}$/
      assert hash == Tasks.snapshot_hash(b)
    end

    test "changes with any nested value" do
      base = %{"id" => "t-1", "nested" => %{"a" => 1}}

      refute Tasks.snapshot_hash(base) ==
               Tasks.snapshot_hash(%{"id" => "t-1", "nested" => %{"a" => 2}})
    end
  end

  # -- archive_done -----------------------------------------------------------

  describe "archive_done/1" do
    test "appends the archive line then prunes the ledger", %{root: root} do
      {:ok, keep} = Tasks.create(root, %{"title" => "open one"})
      {:ok, t} = Tasks.create(root, %{"title" => "done one"})
      {:ok, done} = Tasks.patch(root, t["id"], %{"status" => "done"})

      assert {:ok, %{archived: 1, pruned: 1}} = Tasks.archive_done(root)

      assert [line] = archive_lines(root)
      entry = Jason.decode!(line)
      assert entry["task"] == done
      assert entry["snapshot_hash"] == Tasks.snapshot_hash(done)
      assert {:ok, _uuid} = Ecto.UUID.cast(entry["archive_event"])
      assert {:ok, %DateTime{}, 0} = DateTime.from_iso8601(entry["archived_at"])

      assert ids(root) == [keep["id"]]
    end

    test "archives dropped entries too, and leaves in_progress alone", %{root: root} do
      {:ok, a} = Tasks.create(root, %{"title" => "a", "status" => "dropped"})
      {:ok, b} = Tasks.create(root, %{"title" => "b", "status" => "in_progress"})

      assert {:ok, %{archived: 1, pruned: 1}} = Tasks.archive_done(root)
      assert ids(root) == [b["id"]]
      assert [line] = archive_lines(root)
      assert Jason.decode!(line)["task"]["id"] == a["id"]
    end

    test "nothing eligible: no archive file, no write", %{root: root} do
      {:ok, _t} = Tasks.create(root, %{"title" => "open"})
      before = File.read!(Tasks.tasks_path(root))

      assert Tasks.archive_done(root) == {:ok, %{archived: 0, pruned: 0}}
      refute File.exists?(Tasks.archive_path(root))
      assert File.read!(Tasks.tasks_path(root)) == before
    end

    test "absent ledger is a no-op; malformed ledger is :unreadable", %{root: root} do
      assert Tasks.archive_done(root) == {:ok, %{archived: 0, pruned: 0}}

      File.write!(Tasks.tasks_path(root), "{not json")
      assert Tasks.archive_done(root) == {:error, :unreadable}
    end

    test "prune is snapshot-conditional: an entry edited mid-archive survives", %{root: root} do
      {:ok, t} = Tasks.create(root, %{"title" => "x"})
      {:ok, done} = Tasks.patch(root, t["id"], %{"status" => "done"})

      # An agent edits the entry between the append and the prune.
      hook = fn ->
        doc = read_doc(root)
        edited = Enum.map(doc["tasks"], &Map.put(&1, "notes", "edited mid-archive"))
        write_doc!(root, Map.put(doc, "tasks", edited))
      end

      assert {:ok, %{archived: 1, pruned: 0}} = Tasks.archive_done(root, on_appended: hook)

      # The archive keeps the completed state it captured...
      assert [line] = archive_lines(root)
      assert Jason.decode!(line)["task"] == done
      # ...and the ledger keeps the entry, because it no longer matches.
      assert task(root, t["id"])["notes"] == "edited mid-archive"
    end

    test "snapshot-conditional prune: reopened task survives", %{root: root} do
      {:ok, t} = Tasks.create(root, %{"title" => "x"})
      {:ok, _} = Tasks.patch(root, t["id"], %{"status" => "done"})
      {:ok, %{archived: 1}} = Tasks.archive_done(root)
      # simulate crash-between: re-add same task as done, then edit before next archive
      {:ok, t2} = Tasks.create(root, %{"title" => "x"})
      {:ok, _} = Tasks.patch(root, t2["id"], %{"status" => "done"})
      # reopened
      {:ok, _} = Tasks.patch(root, t2["id"], %{"status" => "open"})
      {:ok, %{archived: 0}} = Tasks.archive_done(root)
      assert Enum.any?(Tasks.list(root).tasks, &(&1["id"] == t2["id"]))
    end

    test "an append starts on a fresh line after a partial trailing line", %{root: root} do
      File.mkdir_p!(Path.dirname(Tasks.archive_path(root)))
      File.write!(Tasks.archive_path(root), ~s({"archive_event":"x","snapshot))

      {:ok, t} = Tasks.create(root, %{"title" => "x"})
      {:ok, done} = Tasks.patch(root, t["id"], %{"status" => "done"})
      assert {:ok, %{archived: 1, pruned: 1}} = Tasks.archive_done(root)

      assert [partial, appended] = archive_lines(root)
      assert partial == ~s({"archive_event":"x","snapshot)
      assert Jason.decode!(appended)["task"] == done
      assert [entry] = Tasks.archive_entries(root)
      assert entry["task"] == done
    end

    test "junk members in the ledger are neither archived nor lost", %{root: root} do
      write_doc!(root, %{
        "tasks" => [42, %{"id" => "t-1", "status" => "done"}]
      })

      assert {:ok, %{archived: 1, pruned: 1}} = Tasks.archive_done(root)
      assert read_doc(root)["tasks"] == [42]
    end
  end

  # -- archive_entries --------------------------------------------------------

  describe "archive_entries/1" do
    test("absent archive", %{root: root}, do: assert(Tasks.archive_entries(root) == []))

    test "dedupes by snapshot_hash, keeps the first, tolerates junk lines", %{root: root} do
      task = %{"id" => "t-1", "status" => "done"}
      hash = Tasks.snapshot_hash(task)

      lines = [
        Jason.encode!(%{
          "archive_event" => "e1",
          "archived_at" => "2026-07-01T00:00:00Z",
          "snapshot_hash" => hash,
          "task" => task
        }),
        # a crash between append and prune re-appends the same snapshot
        Jason.encode!(%{
          "archive_event" => "e2",
          "archived_at" => "2026-07-02T00:00:00Z",
          "snapshot_hash" => hash,
          "task" => task
        }),
        "42",
        Jason.encode!(%{"archive_event" => "e3", "snapshot_hash" => "other", "task" => task}),
        ~s({"archive_event":"e4","snap)
      ]

      File.mkdir_p!(Path.dirname(Tasks.archive_path(root)))
      File.write!(Tasks.archive_path(root), Enum.join(lines, "\n"))

      assert [first, second] = Tasks.archive_entries(root)
      assert first["archive_event"] == "e1"
      assert second["archive_event"] == "e3"
    end
  end

  # -- sweep ------------------------------------------------------------------

  describe "sweep/2" do
    test "archives only done/dropped entries older than 14 days", %{root: root} do
      write_doc!(root, %{
        "tasks" => [
          %{"id" => "t-old-done", "status" => "done", "done_at" => days_ago(20)},
          %{"id" => "t-old-dropped", "status" => "dropped", "done_at" => days_ago(15)},
          %{"id" => "t-fresh-done", "status" => "done", "done_at" => days_ago(3)},
          %{"id" => "t-old-open", "status" => "open", "updated_at" => days_ago(90)}
        ]
      })

      assert {:ok, %{archived: 2, pruned: 2}} = Tasks.sweep(root)
      assert ids(root) == ["t-fresh-done", "t-old-open"]

      assert Tasks.archive_entries(root)
             |> Enum.map(& &1["task"]["id"])
             |> Enum.sort() == ["t-old-done", "t-old-dropped"]
    end

    test "falls back to updated_at when done_at is missing or unparseable", %{root: root} do
      write_doc!(root, %{
        "tasks" => [
          %{"id" => "t-fallback", "status" => "done", "updated_at" => days_ago(30)},
          %{"id" => "t-bad-stamp", "status" => "done", "done_at" => "whenever"},
          %{"id" => "t-no-stamp", "status" => "done"}
        ]
      })

      assert {:ok, %{archived: 1, pruned: 1}} = Tasks.sweep(root)
      assert ids(root) == ["t-bad-stamp", "t-no-stamp"]
    end

    test "the 14-day boundary is strict", %{root: root} do
      now = ~U[2026-07-29 12:00:00Z]

      write_doc!(root, %{
        "tasks" => [
          %{"id" => "t-exactly", "status" => "done", "done_at" => "2026-07-15T12:00:00Z"},
          %{"id" => "t-past", "status" => "done", "done_at" => "2026-07-15T11:59:59Z"}
        ]
      })

      assert {:ok, %{archived: 1, pruned: 1}} = Tasks.sweep(root, now: now)
      assert ids(root) == ["t-exactly"]
      assert [entry] = Tasks.archive_entries(root)
      assert entry["task"]["id"] == "t-past"
      assert entry["archived_at"] == "2026-07-29T12:00:00Z"
    end

    test "absent ledger is a no-op", %{root: root} do
      assert Tasks.sweep(root) == {:ok, %{archived: 0, pruned: 0}}
      refute File.exists?(Tasks.archive_path(root))
    end
  end
end
