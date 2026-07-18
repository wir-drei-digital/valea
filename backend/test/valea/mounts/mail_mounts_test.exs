# Task 14 (mail-maildir spec §"Mount & containment"): synthetic per-account
# mail mounts. `Valea.Mounts.list/1` appends one `kind: :mail` mount per
# VALID configured account (`config/mail.yaml` v4) — key `mail-<slug>`,
# rooted at `<ws>/sources/mail/<slug>`, no manifest — while every ICM mount
# carries `kind: :icm`. Mail mounts are session-scope material ONLY: they
# are excluded from the Knowledge tree grouping (`Valea.Api.Icms.list_icms`,
# `Valea.ICM.tree_for/1`) and are NEVER writable targets for ICM mutations.
defmodule Valea.Mounts.MailMountsTest do
  use ExUnit.Case, async: false

  alias Valea.AgentCase
  alias Valea.Mounts
  alias Valea.Workspace.Manager

  setup do
    ws = AgentCase.open_workspace!("W")
    %{ws: ws.path, generation: Manager.generation()}
  end

  defp write_mail_yaml!(ws, accounts_block) do
    path = Path.join(ws, "config/mail.yaml")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "version: 4\naccounts:\n" <> accounts_block)
  end

  defp account_block(slug) do
    """
      #{slug}:
        imap:
          host: imap.fastmail.com
          port: 993
          username: #{slug}@example.com
    """
  end

  defp real!(path) do
    expanded = Path.expand(path)
    {:ok, resolved} = Valea.Paths.resolve_real(expanded, expanded)
    resolved
  end

  test "a valid configured account appends an enabled kind: :mail mount; ICM mounts carry kind: :icm",
       %{ws: ws} do
    icm = AgentCase.mount_test_icm!(ws, name: "Primary")
    write_mail_yaml!(ws, account_block("mara"))

    mounts = Mounts.list(ws)
    assert %{kind: :icm} = Enum.find(mounts, &(&1.name == icm.mount_key))

    mail_root = Path.join([real!(ws), "sources", "mail", "mara"])

    assert %{
             name: "mail-mara",
             root: ^mail_root,
             manifest: nil,
             enabled: true,
             degraded: nil,
             kind: :mail
           } = Enum.find(mounts, &(&1.name == "mail-mara"))

    assert Mounts.mount_by_key(ws, "mail-mara").kind == :mail
    assert "mail-mara" in Enum.map(Mounts.enabled(ws), & &1.name)
  end

  test "an invalid account produces no mail mount; no mail.yaml produces none either", %{ws: ws} do
    assert Enum.filter(Mounts.list(ws), &(&1.kind == :mail)) == []

    write_mail_yaml!(ws, """
      broken:
        imap:
          port: 993
    """)

    assert Enum.filter(Mounts.list(ws), &(&1.kind == :mail)) == []
  end

  test "mail mounts sort after ICM mounts and every mount map carries :kind", %{ws: ws} do
    AgentCase.mount_test_icm!(ws, name: "Zeta")
    write_mail_yaml!(ws, account_block("aaa") <> account_block("bbb"))

    # The template workspace ships `config/calendar.yaml`, so the synthetic
    # calendar mount (Spec F Task 5) is appended after the mail mounts.
    names = Enum.map(Mounts.list(ws), & &1.name)
    assert names == ["zeta", "mail-aaa", "mail-bbb", "calendar"]
    assert Enum.all?(Mounts.list(ws), &Map.has_key?(&1, :kind))
  end

  test "an Engine in identity_mismatch degrades the mount and drops it from enabled/1", %{
    ws: ws,
    generation: generation
  } do
    write_mail_yaml!(ws, account_block("mara"))

    # A pre-written `.account` with a DIFFERENT identity blocks activation —
    # the Engine lands in "identity_mismatch" (same fixture as
    # `Valea.Mail.EngineTest`'s identity-binding case; no Repo needed, the
    # mismatch path never reaches the index rebuild).
    :ok =
      Valea.Mail.Account.write_if_absent!(ws, "mara", %{
        host: "imap.other.com",
        username: "someone-else@example.com"
      })

    settings = %Valea.Mail.Settings{
      slug: "mara",
      provider: :generic,
      imap: %{host: "imap.fastmail.com", port: 993, username: "mara@example.com"},
      folders: %{drafts: "Drafts", sent: "Sent", archive: "Archive", trash: "Trash"},
      sync: %{
        window_days: 90,
        interval_minutes: 15,
        max_message_bytes: 26_214_400,
        exclude_folders: []
      }
    }

    start_supervised!(
      {Valea.Mail.Engine,
       %{root: ws, generation: generation, account: "mara", settings: settings}}
    )

    Phoenix.PubSub.broadcast(
      Valea.PubSub,
      "workspace",
      {:workspace_opened, %{path: ws, name: "W"}, generation}
    )

    assert Valea.Mail.Engine.status("mara").state == "identity_mismatch"

    assert %{kind: :mail, enabled: true, degraded: "identity_mismatch"} =
             Mounts.mount_by_key(ws, "mail-mara")

    refute "mail-mara" in Enum.map(Mounts.enabled(ws), & &1.name)
  end

  # -- Knowledge tree exclusion ---------------------------------------------

  test "mail mounts are excluded from the Knowledge tree grouping (list_icms) and from tree_for/1",
       %{ws: ws, generation: generation} do
    icm = AgentCase.mount_test_icm!(ws, name: "Primary")
    write_mail_yaml!(ws, account_block("mara"))

    assert {:ok, %{icms: icms}} =
             Valea.Api.Icms
             |> Ash.ActionInput.for_action(:list_icms, %{generation: generation})
             |> Ash.run_action()

    assert Enum.map(icms, & &1.mount_key) == [icm.mount_key]

    # The editor tree entry point refuses a mail mount key outright — same
    # error vocabulary as any other non-editor-addressable mount.
    assert {:error, :outside_workspace} = Valea.ICM.tree_for("mail-mara")
  end

  # (Mutation guards — mount/create/adopt/unmount/set_enabled against mail
  # keys and sources/mail roots — live in `mounts_mutation_test.exs`.)

  test "unique_mount_key/2 never mints a key inside the mail-* namespace", %{ws: ws} do
    refute String.starts_with?(Mounts.unique_mount_key(ws, "Mail Personal"), "mail-")
  end

  test "scoped_roots/2 (editor scan scope) never includes a mail mount", %{ws: ws} do
    icm = AgentCase.mount_test_icm!(ws, name: "Primary")
    write_mail_yaml!(ws, account_block("mara"))

    File.write!(Path.join(icm.root, "CONTEXT.md"), """
    ---
    format: 1
    related_icms:
      - mail-mara
    ---
    """)

    assert Enum.map(Mounts.scoped_roots(ws, icm.mount_key), & &1.name) == [icm.mount_key]
  end

  test "global editor search never sweeps a mail mount", %{ws: ws} do
    icm = AgentCase.mount_test_icm!(ws, name: "Primary")
    File.write!(Path.join(icm.root, "Notes.md"), "# Notes\nxylophone-needle here\n")

    write_mail_yaml!(ws, account_block("mara"))
    views = Path.join([ws, "sources", "mail", "mara", "views"])
    File.mkdir_p!(views)
    File.write!(Path.join(views, "note.md"), "xylophone-needle in mail\n")

    {:ok, %{results: results}} = Valea.ICM.Search.search(ws, "xylophone-needle")
    assert Enum.map(results, & &1.mount) == [icm.mount_key]
  end

  # -- the calendar mount (Spec F Task 5, calendar spec §"Mounts and policy") --
  #
  # ONE synthetic `kind: :calendar` mount covering `sources/calendar/`,
  # appended by `list/1` whenever `config/calendar.yaml` EXISTS — any
  # content (the template's v1-empty shape, a legacy placeholder, even an
  # invalid document): the mount keys on EXISTENCE; validity is status.
  # Follows every mail-mount exclusion (session-scope material only).
  describe "calendar mount" do
    test "a fresh template workspace carries the calendar mount (v1-empty config)", %{ws: ws} do
      cal_root = Path.join([real!(ws), "sources", "calendar"])

      assert %{
               name: "calendar",
               root: ^cal_root,
               manifest: nil,
               enabled: true,
               degraded: nil,
               kind: :calendar
             } = Mounts.mount_by_key(ws, "calendar")

      assert "calendar" in Enum.map(Mounts.enabled(ws), & &1.name)
    end

    test "the mount disappears when calendar.yaml is removed and reappears on ANY content", %{
      ws: ws
    } do
      yaml = Path.join(ws, "config/calendar.yaml")
      File.rm!(yaml)
      assert Mounts.mount_by_key(ws, "calendar") == nil
      assert Enum.filter(Mounts.list(ws), &(&1.kind == :calendar)) == []

      # Invalid content still mounts — validity is status, not availability.
      File.write!(yaml, "definitely: not-a-v1-calendar-config\n")

      assert %{kind: :calendar, enabled: true, degraded: nil} =
               Mounts.mount_by_key(ws, "calendar")
    end

    test "unique_mount_key/2 never mints the reserved calendar key", %{ws: ws} do
      refute Mounts.unique_mount_key(ws, "Calendar") == "calendar"
    end

    test "the calendar mount is excluded from list_icms and tree_for/1", %{
      ws: ws,
      generation: generation
    } do
      icm = AgentCase.mount_test_icm!(ws, name: "Primary")

      assert {:ok, %{icms: icms}} =
               Valea.Api.Icms
               |> Ash.ActionInput.for_action(:list_icms, %{generation: generation})
               |> Ash.run_action()

      assert Enum.map(icms, & &1.mount_key) == [icm.mount_key]
      assert {:error, :outside_workspace} = Valea.ICM.tree_for("calendar")
    end

    test "scoped_roots/2 (editor scan scope) never includes the calendar mount", %{ws: ws} do
      icm = AgentCase.mount_test_icm!(ws, name: "Primary")

      File.write!(Path.join(icm.root, "CONTEXT.md"), """
      ---
      format: 1
      related_icms:
        - calendar
      ---
      """)

      assert Enum.map(Mounts.scoped_roots(ws, icm.mount_key), & &1.name) == [icm.mount_key]
    end

    test "global editor search never sweeps the calendar mount", %{ws: ws} do
      icm = AgentCase.mount_test_icm!(ws, name: "Primary")
      File.write!(Path.join(icm.root, "Notes.md"), "# Notes\nquartz-needle here\n")

      views = Path.join([ws, "sources", "calendar", "mara", "views"])
      File.mkdir_p!(views)
      File.write!(Path.join(views, "ev-1.md"), "quartz-needle in calendar\n")

      {:ok, %{results: results}} = Valea.ICM.Search.search(ws, "quartz-needle")
      assert Enum.map(results, & &1.mount) == [icm.mount_key]
    end
  end
end
