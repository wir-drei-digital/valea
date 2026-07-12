defmodule Valea.Workspace.MigrationV1ToV4AgentsTest do
  @moduledoc """
  Final-review finding #5(b): a v1 workspace (this is the ONLY path that
  exercises `ensure_v2`'s `copy_missing!/2` for `AGENTS.md`, since every
  other migration test in this suite starts from v2+ with `AGENTS.md`
  already decided one way or the other) has its root `AGENTS.md` filled by
  `ensure_v2` from whatever the CURRENT template is — today, that's
  already the post-mounts, rules-only, `@MOUNTS.md`-routing version, not
  the frozen pre-mounts v3 fixture `migrate_root_agents!/1` (running
  later, in the v3->v4 step) knows how to recognize as "pristine and safe
  to replace" via its hardcoded `@v3_root_agents_sha`.

  Before the fix, `migrate_root_agents!/1` saw a file that existed and
  didn't match the frozen v3 hash, and fell through to the "user-modified"
  branch — audit-logging a false claim ("kept (user-modified); it still
  routes via icm/ rather than @MOUNTS.md") about a file the migration
  itself had *just* written moments earlier, byte-identical to the
  template, never touched by any user.

  This is a dedicated file (not folded into
  `MigrationV3AuditTest`) because a v1 workspace needs its OWN
  `Valea.Audit` process — `Valea.Audit` is a named singleton, and
  `MigrationV3AuditTest`'s module-level `setup` already starts one for
  every test in that module (its fixture starts every workspace at v2, so
  it never observes this branch).
  """

  # async: false — starts the named Valea.Audit GenServer.
  use ExUnit.Case, async: false

  alias Valea.Workspace.Migration
  alias Valea.Workspace.Scaffold

  setup do
    root = Path.join(System.tmp_dir!(), "vmig-v1v4-agents-#{System.os_time(:nanosecond)}")

    for d <- [
          "icm/Offers",
          "workflows",
          "queue/pending",
          "logs",
          "config",
          "sources/mail/normalized"
        ] do
      File.mkdir_p!(Path.join(root, d))
    end

    {:ok, audit} = Valea.Audit.start_link(%{root: root, generation: 1})

    on_exit(fn ->
      if Process.alive?(audit), do: GenServer.stop(audit)
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "the freshly-copied-current root AGENTS.md is not falsely flagged user-modified", %{
    root: root
  } do
    refute File.exists?(Path.join(root, "config/workspace.yaml"))
    refute File.exists?(Path.join(root, "AGENTS.md"))

    assert {:ok, 4} = Migration.migrate(root)

    assert File.read!(Path.join(root, "AGENTS.md")) ==
             File.read!(Path.join(Scaffold.template_dir(), "AGENTS.md"))

    {:ok, entries} = Valea.Audit.entries(20)
    refute Enum.any?(entries, &(&1["note"] =~ "root AGENTS.md kept"))
  end
end
