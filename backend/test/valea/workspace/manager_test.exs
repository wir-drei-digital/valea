defmodule Valea.Workspace.ManagerTest do
  use ExUnit.Case, async: false

  alias Valea.Workspace.Manager

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-app-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    System.put_env("VALEA_APP_DIR", dir)
    Manager.close()

    on_exit(fn ->
      Manager.close()
      File.rm_rf!(dir)
      System.delete_env("VALEA_APP_DIR")
    end)

    :ok
  end

  test "no workspace open by default" do
    assert {:error, :no_workspace} = Manager.current()
  end

  test "create scaffolds, opens, starts repo, records config" do
    Phoenix.PubSub.subscribe(Valea.PubSub, "workspace")
    assert {:ok, %{name: "Mara Coaching"} = info} = Manager.create("Mara Coaching")
    assert {:ok, ^info} = Manager.current()
    assert File.exists?(Path.join(info.path, "app.sqlite"))
    assert Process.whereis(Valea.Repo)
    last_opened_id = Valea.App.Config.read()["last_opened"]
    assert is_binary(last_opened_id)
    registered = Valea.App.Config.workspace_by_id(last_opened_id)
    assert registered["path"] == info.path
    assert_receive {:workspace_opened, ^info, generation}
    assert generation == Manager.generation()
  end

  test "open rejects a known id whose on-disk folder isn't a valid workspace" do
    bogus = Path.join(System.tmp_dir!(), "valea-bogus-#{System.os_time(:nanosecond)}")
    File.mkdir_p!(bogus)

    Valea.App.Config.record_opened(%{id: "bogus-id", name: "Bogus", slug: "bogus", path: bogus})

    assert {:error, :not_a_workspace} = Manager.open("bogus-id")
    assert {:error, :no_workspace} = Manager.current()
  end

  test "close stops the repo and clears current" do
    {:ok, _} = Manager.create("W")
    Phoenix.PubSub.subscribe(Valea.PubSub, "workspace")
    :ok = Manager.close()
    assert {:error, :no_workspace} = Manager.current()
    refute Process.whereis(Valea.Repo)
    assert_receive {:workspace_closed}
  end

  test "reopen after close works (repo restart)" do
    {:ok, info} = Manager.create("W")
    :ok = Manager.close()
    assert {:ok, ^info} = Manager.open(info.id)
  end

  test "migration failure reaps the started repo instead of orphaning it" do
    real_migrations_path = Application.get_env(:valea, :migrations_path)

    bad_migrations_dir =
      Path.join(
        System.tmp_dir!(),
        "valea-bad-migrations-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(bad_migrations_dir)

    File.write!(Path.join(bad_migrations_dir, "20990101000000_bad_migration.exs"), """
    defmodule Valea.BadMigration do
      use Ecto.Migration
      def up, do: raise "boom"
      def down, do: :ok
    end
    """)

    on_exit(fn ->
      Application.put_env(:valea, :migrations_path, real_migrations_path)
      File.rm_rf!(bad_migrations_dir)
    end)

    Application.put_env(:valea, :migrations_path, bad_migrations_dir)

    assert {:error, {:migration_failed, _}} = Manager.create("Bad")
    assert Process.whereis(Valea.Repo) == nil
    assert {:error, :no_workspace} = Manager.current()

    Application.put_env(:valea, :migrations_path, real_migrations_path)

    assert {:ok, %{name: "Good"} = info} = Manager.create("Good")
    assert {:ok, ^info} = Manager.current()

    assert [[_seq, _name, file_path]] = Valea.Repo.query!("PRAGMA database_list").rows
    assert Path.basename(Path.dirname(file_path)) == Path.basename(info.path)
    assert Path.basename(file_path) == "app.sqlite"
  end

  test "generation increments per open and is nil when closed" do
    # `Manager` is a long-lived singleton, so the counter is monotonic across
    # the whole test run, not per-test — assert relative movement, not an
    # absolute value.
    assert Manager.generation() == nil

    {:ok, a} = Manager.create("A")
    first_gen = Manager.generation()
    assert is_integer(first_gen)

    :ok = Manager.close()
    assert Manager.generation() == nil

    assert {:ok, ^a} = Manager.open(a.id)
    assert Manager.generation() == first_gen + 1
  end

  test "check_generation returns workspace_changed for a stale generation" do
    {:ok, _} = Manager.create("A")
    gen = Manager.generation()

    assert :ok = Manager.check_generation(gen)
    assert {:error, :workspace_changed} = Manager.check_generation(gen - 1)

    :ok = Manager.close()
    assert {:error, :workspace_changed} = Manager.check_generation(gen)
  end

  test "switching workspaces stops the previous runtime processes" do
    {:ok, _a} = Manager.create("A")
    watcher_pid = Process.whereis(Valea.ICM.Watcher)
    assert watcher_pid

    {:ok, _b} = Manager.create("B")
    refute Process.alive?(watcher_pid)

    new_watcher_pid = Process.whereis(Valea.ICM.Watcher)
    assert new_watcher_pid
    assert new_watcher_pid != watcher_pid
  end

  test "failed switch reports no workspace, not the stale one" do
    # Open workspace A cleanly.
    {:ok, a} = Manager.create("A")
    assert {:ok, ^a} = Manager.current()
    assert Process.whereis(Valea.Repo)

    # Scaffold a valid target B on disk, then force its open to fail AFTER
    # A is closed by making migrations blow up.
    Manager.close()
    {:ok, b} = Manager.create("B")
    Manager.close()

    real_migrations_path = Application.get_env(:valea, :migrations_path)

    bad_migrations_dir =
      Path.join(
        System.tmp_dir!(),
        "valea-bad-migrations-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(bad_migrations_dir)

    File.write!(Path.join(bad_migrations_dir, "20990101000000_bad_migration.exs"), """
    defmodule Valea.BadSwitchMigration do
      use Ecto.Migration
      def up, do: raise "boom"
      def down, do: :ok
    end
    """)

    on_exit(fn ->
      Application.put_env(:valea, :migrations_path, real_migrations_path)
      File.rm_rf!(bad_migrations_dir)
    end)

    # Re-open A cleanly (real migrations), then switch to B with broken ones.
    assert {:ok, ^a} = Manager.open(a.id)
    assert {:ok, ^a} = Manager.current()

    Application.put_env(:valea, :migrations_path, bad_migrations_dir)
    Phoenix.PubSub.subscribe(Valea.PubSub, "workspace")

    assert {:error, {:migration_failed, _}} = Manager.open(b.id)

    # The Manager must NOT still claim A (or B) is open with dead children.
    assert {:error, :no_workspace} = Manager.current()
    assert Process.whereis(Valea.Repo) == nil
    # A was truthfully closed on the way into the failed switch.
    assert_receive {:workspace_closed}

    # Recovery: reopening A with real migrations succeeds.
    Application.put_env(:valea, :migrations_path, real_migrations_path)
    assert {:ok, ^a} = Manager.open(a.id)
    assert {:ok, ^a} = Manager.current()
    assert Process.whereis(Valea.Repo)
  end

  # -- id-based create(name) / open(id) -------------------------------------

  describe "create(name)/open(id) — id-based, app-owned v5 workspaces" do
    test "create(name) places the workspace under the app-owned hidden dir" do
      {:ok, ws} = Manager.create("Coaching business")
      assert String.starts_with?(ws.path, Valea.App.Config.workspaces_dir())
      assert Path.basename(ws.path) |> String.starts_with?("coaching-business-")
      assert ws.name == "Coaching business"
      assert is_binary(ws.id)
      assert {:ok, %{id: id, name: "Coaching business"}} = Manager.current()
      assert id == ws.id
    end

    test "open(id) reopens a previously created workspace by id" do
      {:ok, ws} = Manager.create("Legal")
      :ok = Manager.close()
      {:ok, reopened} = Manager.open(ws.id)
      assert reopened.id == ws.id
      assert reopened.path == ws.path
    end

    test "open(unknown id) errors" do
      assert {:error, :unknown_workspace} = Manager.open("nope")
    end

    test "reopening the same workspace reuses its id rather than double-registering" do
      {:ok, ws} = Manager.create("Reused")
      :ok = Manager.close()
      {:ok, reopened} = Manager.open(ws.id)
      assert reopened.id == ws.id

      known = Valea.App.Config.read()["known_workspaces"]
      assert Enum.count(known, &(&1["id"] == ws.id)) == 1
    end

    # A fresh v5 workspace carries no agent-routing files at all — no stray
    # `.claude/settings.json` — and its version marker stays 5.
    test "create(name) opens a v5 workspace without running legacy migration side effects" do
      {:ok, ws} = Manager.create("X")

      refute File.exists?(Path.join(ws.path, ".claude/settings.json"))

      yaml = File.read!(Path.join(ws.path, "config/workspace.yaml"))
      assert yaml =~ "version: 5"
    end
  end

  describe "switch_preflight/1" do
    test "unknown target id errors" do
      assert {:error, :unknown_workspace} = Manager.switch_preflight("nope")
    end

    test "no live sessions in the current workspace -> empty list" do
      {:ok, _a} = Manager.create("A")

      Valea.App.Config.record_opened(%{
        id: "preflight-target-empty",
        name: "B",
        slug: "b",
        path: "/tmp/valea-preflight-target-empty"
      })

      assert {:ok, %{live_sessions: [], target_id: "preflight-target-empty"}} =
               Manager.switch_preflight("preflight-target-empty")
    end

    test "reports the current workspace's live sessions" do
      {:ok, a} = Manager.create("A")
      Valea.AgentCase.mount_test_icm!(a.path, name: "Primary")
      {:ok, %{id: sid}} = Valea.AgentCase.start_session(a.path, "happy")

      Valea.App.Config.record_opened(%{
        id: "preflight-target-live",
        name: "B",
        slug: "b",
        path: "/tmp/valea-preflight-target-live"
      })

      assert {:ok, %{live_sessions: live, target_id: "preflight-target-live"}} =
               Manager.switch_preflight("preflight-target-live")

      assert [%{id: ^sid}] = live
    end
  end
end
