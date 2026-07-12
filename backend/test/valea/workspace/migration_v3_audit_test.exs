defmodule Valea.Workspace.MigrationV3AuditTest do
  # async: false — starts the named Valea.Audit GenServer, so it must not run
  # concurrently with any other test that does the same.
  use ExUnit.Case, async: false

  alias Valea.Workspace.Migration

  @fixtures_dir Path.expand("../../fixtures/workspace_v2", __DIR__)
  @triage_path "icm/Workflows/New Inquiry Triage.md"

  defp fixture(name), do: File.read!(Path.join(@fixtures_dir, name))

  setup do
    root = Path.join(System.tmp_dir!(), "vmig3-audit-#{System.os_time(:nanosecond)}")

    for d <- ["config", "icm/Workflows", "sources/mail/normalized", "logs"] do
      File.mkdir_p!(Path.join(root, d))
    end

    File.write!(Path.join(root, "config/workspace.yaml"), "version: 2\n")
    File.write!(Path.join(root, "config/mail.yaml"), fixture("mail.yaml"))

    File.write!(
      Path.join(root, "sources/mail/normalized/priya-nair-inquiry.json"),
      fixture("priya-nair-inquiry.json")
    )

    {:ok, audit} = Valea.Audit.start_link(%{root: root, generation: 1})

    on_exit(fn ->
      if Process.alive?(audit), do: GenServer.stop(audit)
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "a user-modified triage page is kept (then relocated byte-preserving into the mount) and the note is audited",
       %{root: root} do
    modified_page = "---\nenabled: true\n---\n# My own triage\n\nHand-edited.\n"
    File.write!(Path.join(root, @triage_path), modified_page)
    slug = Valea.Workspace.Scaffold.slugify(Path.basename(root))

    assert {:ok, 4} = Migration.migrate(root)

    # page content untouched, just relocated into the mount
    assert File.read!(Path.join([root, "mounts", slug, "Workflows", "New Inquiry Triage.md"])) ==
             modified_page

    # the migration_note is on the audit trail
    {:ok, entries} = Valea.Audit.entries(20)
    note = Enum.find(entries, &(&1["type"] == "migration_note"))
    assert note
    assert note["note"] =~ "triage workflow page kept (user-modified)"
  end

  test "a pristine triage page is overwritten and no note is audited for it", %{root: root} do
    File.write!(Path.join(root, @triage_path), fixture("New Inquiry Triage.md"))
    slug = Valea.Workspace.Scaffold.slugify(Path.basename(root))

    assert {:ok, 4} = Migration.migrate(root)

    template =
      File.read!(
        Path.join(
          Application.app_dir(:valea, "priv/migration_fixtures/v3"),
          "New Inquiry Triage.md"
        )
      )

    assert File.read!(Path.join([root, "mounts", slug, "Workflows", "New Inquiry Triage.md"])) ==
             template

    {:ok, entries} = Valea.Audit.entries(20)
    refute Enum.any?(entries, &(&1["type"] == "migration_note"))
  end

  test "a user-modified root AGENTS.md is kept and a migration_note is audited", %{root: root} do
    modified = "# My Own Root Instructions\n\nHand-edited.\n"
    File.write!(Path.join(root, "AGENTS.md"), modified)

    assert {:ok, 4} = Migration.migrate(root)

    assert File.read!(Path.join(root, "AGENTS.md")) == modified

    {:ok, entries} = Valea.Audit.entries(20)
    note = Enum.find(entries, &(&1["note"] =~ "root AGENTS.md kept"))
    assert note
  end

  test "an absent root AGENTS.md is filled from the current template, no note audited", %{
    root: root
  } do
    refute File.exists?(Path.join(root, "AGENTS.md"))

    assert {:ok, 4} = Migration.migrate(root)

    assert File.read!(Path.join(root, "AGENTS.md")) ==
             File.read!(Path.join(Valea.Workspace.Scaffold.template_dir(), "AGENTS.md"))

    {:ok, entries} = Valea.Audit.entries(20)
    refute Enum.any?(entries, &(&1["note"] =~ "root AGENTS.md kept"))
  end
end
