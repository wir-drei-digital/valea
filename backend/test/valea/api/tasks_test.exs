defmodule Valea.Api.TasksTest do
  @moduledoc """
  Direct Ash-action coverage for `Valea.Api.Tasks` — the `Valea.Api.SkillsTest`
  style: each generic action straight through `Ash.ActionInput.for_action/3` +
  `Ash.run_action/1`, no RPC transport. `Valea.TasksTest` covers the ledger
  semantics in depth; this suite pins the ACTION wiring — argument plumbing,
  the string-keyed payload shapes, the error vocabulary, the generation guard
  and the audit entries the spec requires for UI mutations.
  """
  use ExUnit.Case, async: false

  alias Valea.AgentCase
  alias Valea.Api.Tasks, as: ApiTasks
  alias Valea.Workspace.Manager

  setup do
    ws = AgentCase.open_workspace!("W")
    icm = AgentCase.mount_test_icm!(ws.path, name: "Primary")
    %{ws: ws.path, icm: icm, key: icm.mount_key, generation: Manager.generation()}
  end

  defp run(action, input) do
    ApiTasks
    |> Ash.ActionInput.for_action(action, input)
    |> Ash.run_action()
  end

  defp write_tasks!(icm, tasks) do
    File.write!(
      Path.join(icm.root, "tasks.json"),
      Jason.encode!(%{"readme" => "keep me", "tasks" => tasks})
    )
  end

  defp read_tasks(icm) do
    icm.root |> Path.join("tasks.json") |> File.read!() |> Jason.decode!()
  end

  defp audit_types do
    {:ok, entries} = Valea.Audit.entries(50)
    Enum.map(entries, & &1["type"])
  end

  defp audit_entry(type) do
    {:ok, entries} = Valea.Audit.entries(50)
    Enum.find(entries, &(&1["type"] == type))
  end

  describe "list_tasks" do
    test "an ICM with no ledger reports status absent and no tasks", %{
      key: key,
      generation: generation
    } do
      assert {:ok, %{"icms" => [icm_row]}} = run(:list_tasks, %{generation: generation})
      assert icm_row["mount_key"] == key
      assert icm_row["icm_name"] == "Primary"
      assert icm_row["status"] == "absent"
      assert icm_row["tasks"] == []
    end

    test "entries come back VERBATIM — unknown fields included", %{
      icm: icm,
      generation: generation
    } do
      write_tasks!(icm, [
        %{"id" => "t-1", "title" => "Ship it", "status" => "open", "mystery" => %{"a" => 1}}
      ])

      assert {:ok, %{"icms" => [%{"status" => "ok", "tasks" => [task]}]}} =
               run(:list_tasks, %{generation: generation})

      assert task["id"] == "t-1"
      assert task["mystery"] == %{"a" => 1}
    end

    test "a malformed ledger degrades to status unreadable, never an error", %{
      icm: icm,
      generation: generation
    } do
      File.write!(Path.join(icm.root, "tasks.json"), "{not json")

      assert {:ok, %{"icms" => [%{"status" => "unreadable", "tasks" => []}]}} =
               run(:list_tasks, %{generation: generation})
    end

    test "disabled mounts are not listed", %{ws: ws, key: key, generation: generation} do
      :ok = Valea.Mounts.set_enabled(ws, key, false)
      assert {:ok, %{"icms" => []}} = run(:list_tasks, %{generation: generation})
    end
  end

  describe "create_task" do
    test "lands in the file with a generated id, created_by user, and audits", %{
      icm: icm,
      key: key,
      generation: generation
    } do
      assert {:ok, %{"task" => task}} =
               run(:create_task, %{
                 mount_key: key,
                 fields: %{"title" => "Send the offer", "due" => "2026-08-01", "today" => true},
                 generation: generation
               })

      assert task["title"] == "Send the offer"
      assert task["today"] == true
      assert task["status"] == "open"
      assert task["created_by"] == "user"
      assert task["id"] =~ ~r/^t-[0-9a-f]{6}$/

      assert %{"tasks" => [written]} = read_tasks(icm)
      assert written["id"] == task["id"]

      assert entry = audit_entry("task_created")
      assert entry["mount_key"] == key
      assert entry["id"] == task["id"]
    end

    test "the caller cannot forge id/created_by/timestamps", %{key: key, generation: generation} do
      assert {:ok, %{"task" => task}} =
               run(:create_task, %{
                 mount_key: key,
                 fields: %{
                   "title" => "x",
                   "id" => "t-forged",
                   "created_by" => "agent",
                   "created_at" => "1999-01-01T00:00:00Z",
                   "done_at" => "1999-01-01T00:00:00Z"
                 },
                 generation: generation
               })

      refute task["id"] == "t-forged"
      assert task["created_by"] == "user"
      refute task["created_at"] == "1999-01-01T00:00:00Z"
      assert task["done_at"] == nil
    end

    test "preserves the document's other keys", %{icm: icm, key: key, generation: generation} do
      write_tasks!(icm, [])

      assert {:ok, _created} =
               run(:create_task, %{
                 mount_key: key,
                 fields: %{"title" => "x"},
                 generation: generation
               })

      assert read_tasks(icm)["readme"] == "keep me"
    end

    test "an unknown mount is icm_unavailable", %{generation: generation} do
      assert {:error, error} =
               run(:create_task, %{
                 mount_key: "ghost",
                 fields: %{"title" => "x"},
                 generation: generation
               })

      assert %Valea.Api.Error{code: "icm_unavailable"} = error.errors |> hd()
    end

    test "a malformed ledger refuses the write with unreadable", %{
      icm: icm,
      key: key,
      generation: generation
    } do
      File.write!(Path.join(icm.root, "tasks.json"), "{not json")

      assert {:error, error} =
               run(:create_task, %{
                 mount_key: key,
                 fields: %{"title" => "x"},
                 generation: generation
               })

      assert %Valea.Api.Error{code: "unreadable"} = error.errors |> hd()
    end
  end

  describe "mutate_task" do
    test "patches the entry, stamps done_at, and audits", %{
      icm: icm,
      key: key,
      generation: generation
    } do
      write_tasks!(icm, [%{"id" => "t-1", "title" => "Ship it", "status" => "open"}])

      assert {:ok, %{"task" => task}} =
               run(:mutate_task, %{
                 mount_key: key,
                 task_id: "t-1",
                 patch: %{"status" => "done", "title" => "Shipped"},
                 generation: generation
               })

      assert task["status"] == "done"
      assert task["title"] == "Shipped"
      assert is_binary(task["done_at"])

      assert entry = audit_entry("task_updated")
      assert entry["mount_key"] == key
      assert entry["id"] == "t-1"
    end

    test "an unknown id is not_found and writes nothing", %{
      icm: icm,
      key: key,
      generation: generation
    } do
      write_tasks!(icm, [%{"id" => "t-1", "title" => "Ship it", "status" => "open"}])
      before = read_tasks(icm)

      assert {:error, error} =
               run(:mutate_task, %{
                 mount_key: key,
                 task_id: "t-nope",
                 patch: %{"status" => "done"},
                 generation: generation
               })

      assert %Valea.Api.Error{code: "not_found"} = error.errors |> hd()
      assert read_tasks(icm) == before
      refute "task_updated" in audit_types()
    end

    test "the caller cannot forge id/created_by through a patch", %{
      icm: icm,
      key: key,
      generation: generation
    } do
      write_tasks!(icm, [
        %{"id" => "t-1", "title" => "Ship it", "status" => "open", "created_by" => "agent"}
      ])

      assert {:ok, %{"task" => task}} =
               run(:mutate_task, %{
                 mount_key: key,
                 task_id: "t-1",
                 patch: %{"id" => "t-other", "created_by" => "user", "priority" => "high"},
                 generation: generation
               })

      assert task["id"] == "t-1"
      assert task["created_by"] == "agent"
      assert task["priority"] == "high"
    end
  end

  describe "archive_done" do
    test "one ICM: archives the completed entries and reports archived + pruned", %{
      icm: icm,
      key: key,
      generation: generation
    } do
      write_tasks!(icm, [
        %{"id" => "t-1", "title" => "open", "status" => "open"},
        %{"id" => "t-2", "title" => "done", "status" => "done"},
        %{"id" => "t-3", "title" => "dropped", "status" => "dropped"}
      ])

      assert {:ok, payload} = run(:archive_done, %{mount_key: key, generation: generation})
      assert payload["archived"] == 2
      assert payload["pruned"] == 2
      assert [%{"mount_key" => ^key, "archived" => 2, "pruned" => 2}] = payload["icms"]

      assert %{"tasks" => [remaining]} = read_tasks(icm)
      assert remaining["id"] == "t-1"
      assert length(Valea.Tasks.archive_entries(icm.root)) == 2

      assert entry = audit_entry("task_archived")
      assert entry["mount_key"] == key
      assert entry["archived"] == 2
    end

    test "no mount_key sweeps every enabled ICM", %{ws: ws, icm: icm, generation: generation} do
      other = AgentCase.mount_test_icm!(ws, name: "Second")
      write_tasks!(icm, [%{"id" => "t-1", "title" => "done", "status" => "done"}])
      write_tasks!(other, [%{"id" => "t-2", "title" => "done", "status" => "done"}])

      assert {:ok, payload} = run(:archive_done, %{generation: generation})
      assert payload["archived"] == 2

      assert Enum.map(payload["icms"], & &1["mount_key"]) |> Enum.sort() ==
               Enum.sort([icm.mount_key, other.mount_key])
    end

    test "an ICM with a malformed ledger reports its own status without failing the sweep", %{
      ws: ws,
      icm: icm,
      generation: generation
    } do
      other = AgentCase.mount_test_icm!(ws, name: "Second")
      File.write!(Path.join(icm.root, "tasks.json"), "{not json")
      write_tasks!(other, [%{"id" => "t-2", "title" => "done", "status" => "done"}])

      assert {:ok, payload} = run(:archive_done, %{generation: generation})
      assert payload["archived"] == 1

      broken = Enum.find(payload["icms"], &(&1["mount_key"] == icm.mount_key))
      assert broken["status"] == "unreadable"
      assert broken["archived"] == 0
    end
  end

  # The suite's stale-generation idiom (`Valea.Api.SkillsTest`): stale is
  # generation + 1, surfacing as a `%Valea.Api.Error{code: "workspace_changed"}`
  # at the head of `error.errors`.
  test "every action rejects a stale generation with workspace_changed", %{
    key: key,
    generation: generation
  } do
    stale = generation + 1

    for {action, input} <- [
          {:list_tasks, %{generation: stale}},
          {:create_task, %{mount_key: key, fields: %{"title" => "x"}, generation: stale}},
          {:mutate_task,
           %{mount_key: key, task_id: "t-1", patch: %{"status" => "done"}, generation: stale}},
          {:archive_done, %{mount_key: key, generation: stale}}
        ] do
      assert {:error, error} = run(action, input),
             "expected stale-generation refusal for #{action}"

      assert %Valea.Api.Error{code: "workspace_changed"} = error.errors |> hd()
    end
  end

  # Constraint from the branch's earlier review rounds: `Valea.Ledger.Writer`
  # is a workspace-runtime child (`Valea.Schedules.Supervisor`), so a mutation
  # attempted while it is gone EXITS inside `GenServer.call/3`. That must
  # surface as the shared `workspace_not_open` code, never a 500. Terminating
  # the child by id is what reproduces the window without racing a real
  # close/switch: a static supervisor does not restart a child it was asked to
  # terminate.
  test "a mutation with the ledger writer gone is workspace_not_open, not a crash", %{
    key: key,
    generation: generation
  } do
    :ok = Supervisor.terminate_child(Valea.Schedules.Supervisor, Valea.Ledger.Writer)
    on_exit(fn -> Supervisor.restart_child(Valea.Schedules.Supervisor, Valea.Ledger.Writer) end)
    assert Process.whereis(Valea.Ledger.Writer) == nil

    for {action, input} <- [
          {:create_task, %{mount_key: key, fields: %{"title" => "x"}, generation: generation}},
          {:mutate_task,
           %{
             mount_key: key,
             task_id: "t-1",
             patch: %{"status" => "done"},
             generation: generation
           }},
          {:archive_done, %{mount_key: key, generation: generation}}
        ] do
      assert {:error, error} = run(action, input)

      assert %Valea.Api.Error{code: "workspace_not_open"} = error.errors |> hd(),
             "expected workspace_not_open for #{action}"
    end
  end
end
