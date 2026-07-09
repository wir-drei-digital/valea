defmodule Valea.Workspace.ManagerTest do
  use ExUnit.Case, async: false

  alias Valea.Workspace.Manager

  setup do
    dir = Path.join(System.tmp_dir!(), "valea-app-#{System.unique_integer([:positive])}")
    System.put_env("VALEA_APP_DIR", dir)
    Manager.close()

    on_exit(fn ->
      Manager.close()
      System.delete_env("VALEA_APP_DIR")
    end)

    %{parent: Path.join(dir, "workspaces")}
  end

  test "no workspace open by default" do
    assert {:error, :no_workspace} = Manager.current()
  end

  test "create scaffolds, opens, starts repo, records config", %{parent: parent} do
    Phoenix.PubSub.subscribe(Valea.PubSub, "workspace")
    assert {:ok, %{name: "Mara Coaching"} = info} = Manager.create(parent, "Mara Coaching")
    assert {:ok, ^info} = Manager.current()
    assert File.exists?(Path.join(info.path, "app.sqlite"))
    assert Process.whereis(Valea.Repo)
    assert Valea.App.Config.read()["last_opened"] == info.path
    assert_receive {:workspace_opened, ^info}
  end

  test "open rejects a non-workspace folder", %{parent: parent} do
    bogus = Path.join(parent, "bogus")
    File.mkdir_p!(bogus)
    assert {:error, :not_a_workspace} = Manager.open(bogus)
    assert {:error, :no_workspace} = Manager.current()
  end

  test "close stops the repo and clears current", %{parent: parent} do
    {:ok, _} = Manager.create(parent, "W")
    Phoenix.PubSub.subscribe(Valea.PubSub, "workspace")
    :ok = Manager.close()
    assert {:error, :no_workspace} = Manager.current()
    refute Process.whereis(Valea.Repo)
    assert_receive {:workspace_closed}
  end

  test "reopen after close works (repo restart)", %{parent: parent} do
    {:ok, info} = Manager.create(parent, "W")
    :ok = Manager.close()
    assert {:ok, ^info} = Manager.open(info.path)
  end

  test "migration failure reaps the started repo instead of orphaning it", %{parent: parent} do
    real_migrations_path = Application.get_env(:valea, :migrations_path)

    bad_migrations_dir =
      Path.join(System.tmp_dir!(), "valea-bad-migrations-#{System.unique_integer([:positive])}")

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

    assert {:error, {:migration_failed, _}} = Manager.create(parent, "Bad")
    assert Process.whereis(Valea.Repo) == nil
    assert {:error, :no_workspace} = Manager.current()

    Application.put_env(:valea, :migrations_path, real_migrations_path)

    assert {:ok, %{name: "Good"} = info} = Manager.create(parent, "Good")
    assert {:ok, ^info} = Manager.current()

    assert [[_seq, _name, file_path]] = Valea.Repo.query!("PRAGMA database_list").rows
    assert Path.basename(Path.dirname(file_path)) == "Good"
    assert Path.basename(file_path) == "app.sqlite"
  end
end
