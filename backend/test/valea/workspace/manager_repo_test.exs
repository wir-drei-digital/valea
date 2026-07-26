defmodule Valea.Workspace.ManagerRepoTest do
  # async: false — opens a real workspace, which starts the singleton
  # `Valea.Repo` (same constraint as `manager_test.exs`).
  use ExUnit.Case, async: false

  alias Valea.Workspace.Manager

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-manager-repo-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
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

  # The sqlite settings the Manager hands `Valea.Repo` are what make the
  # shared `app.sqlite` safe under CONCURRENCY: several mail Engines (one
  # process per account) write the pending-ops ledger while the UI reads it.
  # In rollback mode one writer blocks every reader for its whole
  # transaction; and with no busy timeout a genuine writer collision fails
  # instantly with SQLITE_BUSY instead of waiting.
  #
  # Only WAL is asserted, and only through the pragma — the one honest proof
  # it is really in effect on the opened workspace's database (`Repo.config/0`
  # re-derives from the app env and never shows `start_link` options). The
  # companion `busy_timeout: 5000` has NO observable getter: exqlite applies
  # it through a custom busy handler (`Exqlite.Sqlite3.set_busy_timeout/2`)
  # precisely to avoid `PRAGMA busy_timeout`, which reports 0 here and
  # destroys that handler on read.
  test "an opened workspace's repo runs in WAL" do
    assert {:ok, _info} = Manager.create("Mara Coaching")

    assert %{rows: [["wal"]]} = Valea.Repo.query!("PRAGMA journal_mode")
  end
end
