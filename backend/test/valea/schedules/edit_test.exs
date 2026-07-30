defmodule Valea.Schedules.EditTest do
  @moduledoc """
  `Valea.Schedules.Edit`'s write contract, mirroring `Valea.TasksTest`: a bare
  `Valea.Ledger.Writer` over a tmp ICM root, no workspace lifecycle. The RPC
  wiring lives in `Valea.Api.SchedulesTest`; what this pins is the file
  discipline — key preservation, trimmed-id addressing, the duplicate refusal,
  and the optimistic-concurrency retry driven through the `:before_write` seam.
  """
  # async: false — `Valea.Ledger.Writer` registers under its module name.
  use ExUnit.Case, async: false

  alias Valea.Schedules.Edit
  alias Valea.Schedules.File, as: SchedulesFile

  @readme "Schedules for this ICM. Fire only while Valea is running. Contract: .valea/briefing.md"

  setup do
    start_supervised!(Valea.Ledger.Writer)

    root = Path.join(System.tmp_dir!(), "schedules-icm-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    %{root: root}
  end

  defp read_doc(root),
    do: root |> SchedulesFile.schedules_path() |> File.read!() |> Jason.decode!()

  defp write_doc!(root, doc),
    do: File.write!(SchedulesFile.schedules_path(root), Jason.encode!(doc))

  # An agent-style write from outside Valea's writer — changes the content
  # hash, which is what makes an in-flight Valea patch conflict.
  defp external_add!(root, entry) do
    doc = read_doc(root)
    write_doc!(root, Map.put(doc, "schedules", doc["schedules"] ++ [entry]))
  end

  defp external_remove!(root, id) do
    doc = read_doc(root)
    write_doc!(root, Map.put(doc, "schedules", Enum.reject(doc["schedules"], &(&1["id"] == id))))
  end

  defp ids(root), do: read_doc(root)["schedules"] |> Enum.map(&(is_map(&1) && &1["id"]))

  describe "create/3" do
    test "materializes the spec skeleton and stamps id/created_by/created_at", %{root: root} do
      assert {:ok, entry} = Edit.create(root, %{"cron" => "@daily"})

      assert entry["id"] =~ ~r/^s-[0-9a-f]{6}$/
      assert entry["created_by"] == "user"
      assert entry["paused"] == false
      assert {:ok, _at, _off} = DateTime.from_iso8601(entry["created_at"])

      doc = read_doc(root)
      assert doc["readme"] == @readme
      assert doc["schedules"] == [entry]
    end

    test "caller fields win, including an explicit id", %{root: root} do
      assert {:ok, entry} =
               Edit.create(root, %{"id" => "s-morning-brief", "created_by" => "agent"})

      assert entry["id"] == "s-morning-brief"
      assert entry["created_by"] == "agent"
    end

    test "atom keys normalize to strings", %{root: root} do
      assert {:ok, entry} = Edit.create(root, %{title: "Nightly", cron: "@daily"})
      assert entry["title"] == "Nightly"
      assert entry["cron"] == "@daily"
    end

    test "unknown top-level keys and junk members survive", %{root: root} do
      write_doc!(root, %{"readme" => "mine", "future" => %{"x" => 1}, "schedules" => [42]})

      assert {:ok, entry} = Edit.create(root, %{"title" => "x"})

      doc = read_doc(root)
      assert doc["future"] == %{"x" => 1}
      assert doc["readme"] == "mine"
      assert doc["schedules"] == [42, entry]
    end

    test "a wrong-typed list key is :unreadable and left untouched", %{root: root} do
      write_doc!(root, %{"schedules" => "nope"})

      assert Edit.create(root, %{"title" => "x"}) == {:error, :unreadable}
      assert read_doc(root)["schedules"] == "nope"
    end

    test "malformed JSON is :unreadable and never clobbered", %{root: root} do
      File.write!(SchedulesFile.schedules_path(root), "{not json")

      assert Edit.create(root, %{"title" => "x"}) == {:error, :unreadable}
      assert File.read!(SchedulesFile.schedules_path(root)) == "{not json"
    end

    test "re-applies against a file that changed mid-write", %{root: root} do
      {:ok, _first} = Edit.create(root, %{"id" => "s-1"})

      hook = fn
        1 -> external_add!(root, %{"id" => "s-ext"})
        _later_attempt -> :ok
      end

      assert {:ok, entry} = Edit.create(root, %{"id" => "s-2"}, before_write: hook)
      assert ids(root) == ["s-1", "s-ext", entry["id"]]
    end

    test "gives up with :conflict when contention persists", %{root: root} do
      {:ok, _first} = Edit.create(root, %{"id" => "s-1"})
      hook = fn attempt -> external_add!(root, %{"id" => "s-ext#{attempt}"}) end

      assert Edit.create(root, %{"id" => "s-2"}, before_write: hook) == {:error, :conflict}
      assert ids(root) == ["s-1", "s-ext1", "s-ext2", "s-ext3"]
    end
  end

  describe "patch/4" do
    test "merges over the entry and preserves unknown fields", %{root: root} do
      write_doc!(root, %{
        "schedules" => [%{"id" => "s-1", "title" => "Brief", "mystery" => %{"a" => 1}}]
      })

      assert {:ok, entry} = Edit.patch(root, "s-1", %{"paused" => true})
      assert entry["paused"] == true
      assert entry["title"] == "Brief"
      assert entry["mystery"] == %{"a" => 1}
      assert read_doc(root)["schedules"] == [entry]
    end

    # `Valea.Schedules.Entry` trims the id it exposes, so the writer has to
    # match trimmed too — otherwise the UI shows a row it cannot address.
    test "addresses a padded file id by its TRIMMED form", %{root: root} do
      write_doc!(root, %{"schedules" => [%{"id" => "  s-1  ", "title" => "Brief"}]})

      assert {:ok, entry} = Edit.patch(root, "s-1", %{"paused" => true})
      assert entry["id"] == "  s-1  "
      assert entry["paused"] == true
    end

    test "an unknown id is :not_found with nothing written", %{root: root} do
      write_doc!(root, %{"schedules" => [%{"id" => "s-1"}]})
      before = read_doc(root)

      assert Edit.patch(root, "s-nope", %{"paused" => true}) == {:error, :not_found}
      assert read_doc(root) == before
    end

    # The spec's duplicate rule is "order never decides" — so a mutation
    # against an ambiguous id is refused, not resolved by position.
    test "a duplicate id is :duplicate_id with nothing written", %{root: root} do
      write_doc!(root, %{
        "schedules" => [%{"id" => "s-1", "title" => "A"}, %{"id" => " s-1", "title" => "B"}]
      })

      before = read_doc(root)
      assert Edit.patch(root, "s-1", %{"paused" => true}) == {:error, :duplicate_id}
      assert read_doc(root) == before
    end

    test "re-applies the patch against a file that changed mid-write", %{root: root} do
      write_doc!(root, %{"schedules" => [%{"id" => "s-1", "title" => "Brief"}]})

      hook = fn
        1 -> external_add!(root, %{"id" => "s-ext"})
        _later_attempt -> :ok
      end

      assert {:ok, entry} = Edit.patch(root, "s-1", %{"paused" => true}, before_write: hook)
      assert entry["paused"] == true
      assert ids(root) == ["s-1", "s-ext"]
      assert read_doc(root)["schedules"] |> hd() |> Map.get("paused") == true
    end

    test "an entry that vanishes under the retry is :not_found", %{root: root} do
      write_doc!(root, %{"schedules" => [%{"id" => "s-1"}]})

      hook = fn
        1 ->
          external_add!(root, %{"id" => "s-ext"})
          external_remove!(root, "s-1")

        _later_attempt ->
          :ok
      end

      assert Edit.patch(root, "s-1", %{"paused" => true}, before_write: hook) ==
               {:error, :not_found}

      assert ids(root) == ["s-ext"]
    end

    test "persistent contention is :conflict with nothing written", %{root: root} do
      write_doc!(root, %{"schedules" => [%{"id" => "s-1", "paused" => false}]})
      hook = fn attempt -> external_add!(root, %{"id" => "s-ext#{attempt}"}) end

      assert Edit.patch(root, "s-1", %{"paused" => true}, before_write: hook) ==
               {:error, :conflict}

      assert ids(root) == ["s-1", "s-ext1", "s-ext2", "s-ext3"]
      assert read_doc(root)["schedules"] |> hd() |> Map.get("paused") == false
    end
  end

  describe "delete/3" do
    test "removes exactly that entry, keeping the rest of the document", %{root: root} do
      write_doc!(root, %{
        "readme" => "mine",
        "schedules" => [%{"id" => "s-1"}, 42, %{"id" => "s-2"}]
      })

      assert {:ok, %{"id" => "s-1"}} = Edit.delete(root, "s-1")

      doc = read_doc(root)
      assert doc["readme"] == "mine"
      assert doc["schedules"] == [42, %{"id" => "s-2"}]
    end

    test "unknown and duplicate ids are refused with nothing written", %{root: root} do
      write_doc!(root, %{"schedules" => [%{"id" => "s-1"}, %{"id" => "s-1"}]})
      before = read_doc(root)

      assert Edit.delete(root, "s-1") == {:error, :duplicate_id}
      assert Edit.delete(root, "s-nope") == {:error, :not_found}
      assert read_doc(root) == before
    end

    test "re-applies against a file that changed mid-write", %{root: root} do
      write_doc!(root, %{"schedules" => [%{"id" => "s-1"}]})

      hook = fn
        1 -> external_add!(root, %{"id" => "s-ext"})
        _later_attempt -> :ok
      end

      assert {:ok, _entry} = Edit.delete(root, "s-1", before_write: hook)
      assert ids(root) == ["s-ext"]
    end
  end
end
