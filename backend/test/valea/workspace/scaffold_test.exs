defmodule Valea.Workspace.ScaffoldTest do
  use ExUnit.Case, async: true

  alias Valea.Mounts.Manifest
  alias Valea.Workspace.Scaffold

  defp tmp_target do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-ws-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  test "create/2 scaffolds the full v4 (all-are-mounts) template tree" do
    target = tmp_target()
    assert :ok = Scaffold.create(target, "Acme Coaching")

    for dir <-
          ~w(mounts mounts/acme-coaching mounts/acme-coaching/Workflows
             mounts/acme-coaching/prompts queue/pending queue/approved queue/rejected
             queue/applied queue/staging queue/processing logs sources/mail/messages
             sources/mail/attachments config secrets) do
      assert File.dir?(Path.join(target, dir)), "missing #{dir}"
    end

    refute File.exists?(Path.join(target, "icm"))
    refute File.exists?(Path.join(target, "prompts"))

    assert File.exists?(
             Path.join(target, "mounts/acme-coaching/Offers/Founder Coaching Package.md")
           )

    assert File.exists?(Path.join(target, "mounts/acme-coaching/Workflows/New Inquiry Triage.md"))

    # v3: the legacy normalized JSON is gone, replaced by a seed markdown message
    assert File.exists?(
             Path.join(target, "sources/mail/messages/2026-07-09-priya-nair-seed0001.md")
           )

    refute File.exists?(Path.join(target, "sources/mail/normalized/priya-nair-inquiry.json"))
    assert File.exists?(Path.join(target, "logs/audit.jsonl"))
    assert File.exists?(Path.join(target, ".gitignore"))
    refute File.exists?(Path.join(target, "gitignore"))
  end

  test "the starter mount's icm.yaml gets a real uuid and the given workspace name" do
    target = tmp_target()
    assert :ok = Scaffold.create(target, "Acme Coaching")

    assert {:ok, manifest} = Manifest.load(Path.join(target, "mounts/acme-coaching"))
    assert manifest.format == 1
    assert manifest.name == "Acme Coaching"
    assert manifest.description != ""
    refute manifest.id == "TEMPLATE"
    assert Regex.match?(~r/^[0-9a-f-]{36}$/, manifest.id)

    # a second scaffold gets a different mount id
    other = tmp_target()
    :ok = Scaffold.create(other, "Acme Coaching")
    {:ok, other_manifest} = Manifest.load(Path.join(other, "mounts/acme-coaching"))
    refute other_manifest.id == manifest.id
  end

  test "create/2 slugifies the workspace name for the mount directory (lowercase, ascii-fold, dashed)" do
    target = tmp_target()
    assert :ok = Scaffold.create(target, "Café Löwen & Co.!!")

    assert File.dir?(Path.join(target, "mounts/cafe-lowen-co"))
    refute File.dir?(Path.join(target, "mounts/starter"))
  end

  test "create/2 falls back to a sane slug when the name has no alphanumeric characters" do
    target = tmp_target()
    assert :ok = Scaffold.create(target, "!!!")

    assert File.dir?(Path.join(target, "mounts/mount"))
  end

  test "create/1 names the workspace after the target directory's own basename" do
    parent =
      Path.join(
        System.tmp_dir!(),
        "valea-ws-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(parent) end)
    target = Path.join(parent, "My Workspace")

    assert :ok = Scaffold.create(target)

    assert {:ok, manifest} = Manifest.load(Path.join(target, "mounts/my-workspace"))
    assert manifest.name == "My Workspace"
  end

  test "root AGENTS.md is rules-only: routes to @MOUNTS.md, carries no knowledge-tree content" do
    target = tmp_target()
    :ok = Scaffold.create(target, "Acme Coaching")

    root_agents = File.read!(Path.join(target, "AGENTS.md"))
    assert root_agents =~ "@MOUNTS.md"
    assert root_agents =~ "proposal/v1"
    refute root_agents =~ "Founder Coaching Package"
    refute root_agents =~ "Best fit"
    refute root_agents =~ "icm/Offers"
  end

  test "root CLAUDE.md still imports AGENTS.md" do
    target = tmp_target()
    :ok = Scaffold.create(target, "Acme Coaching")
    assert File.read!(Path.join(target, "CLAUDE.md")) =~ "@AGENTS.md"
  end

  test "the starter mount's AGENTS.md is self-describing: its own taxonomy, not the shell rules" do
    target = tmp_target()
    :ok = Scaffold.create(target, "Acme Coaching")

    mount_agents = File.read!(Path.join(target, "mounts/acme-coaching/AGENTS.md"))
    assert mount_agents =~ "Offers/"
    assert mount_agents =~ "Workflows/"
    refute mount_agents =~ "@MOUNTS.md"
    refute mount_agents =~ "proposal/v1"

    assert File.read!(Path.join(target, "mounts/acme-coaching/CLAUDE.md")) =~ "@AGENTS.md"
  end

  test "MOUNTS.md is regenerated to list the real starter mount" do
    target = tmp_target()
    :ok = Scaffold.create(target, "Acme Coaching")

    mounts_md = File.read!(Path.join(target, "MOUNTS.md"))
    assert mounts_md =~ "Acme Coaching"
    assert mounts_md =~ "mounts/acme-coaching"
    assert mounts_md =~ "@mounts/acme-coaching/AGENTS.md"
  end

  test "create writes version 4 + a fresh workspace uuid (not the template placeholder)" do
    target = tmp_target()
    assert :ok = Scaffold.create(target)

    yaml = File.read!(Path.join(target, "config/workspace.yaml"))
    assert yaml =~ "version: 4"
    assert [uuid] = Regex.run(~r/^id: ([0-9a-f-]{36})$/m, yaml, capture: :all_but_first)
    refute uuid == "TEMPLATE"

    # a second scaffold gets a different id
    other = tmp_target()
    :ok = Scaffold.create(other)
    other_yaml = File.read!(Path.join(other, "config/workspace.yaml"))

    assert [other_uuid] =
             Regex.run(~r/^id: ([0-9a-f-]{36})$/m, other_yaml, capture: :all_but_first)

    refute other_uuid == uuid
  end

  test "the seed message is byte-identical to MessageFile.render output (parses cleanly)" do
    target = tmp_target()
    :ok = Scaffold.create(target)

    bytes =
      File.read!(Path.join(target, "sources/mail/messages/2026-07-09-priya-nair-seed0001.md"))

    assert {:ok, %{frontmatter: fm, body: body}} = Valea.Mail.MessageFile.parse(bytes)
    assert fm["id"] == "2026-07-09-priya-nair-seed0001"
    assert fm["message_id"] == "<seed-priya-nair-inquiry@valea.seed>"
    assert fm["source"] == "seed"
    assert fm["source_ref"] == "email://seed/priya-nair-inquiry"
    assert fm["status"] == "review"
    assert String.starts_with?(body, "Hi Mara,")

    # the file is exactly what the renderer produces — no drift between the
    # committed seed and Valea.Mail.MessageFile
    message = %Valea.Mail.Message{
      message_id: "<seed-priya-nair-inquiry@valea.seed>",
      from: %{name: "Priya Nair", email: "priya@example.com"},
      to: [%{name: "Mara Lindt", email: "mara@example.com"}],
      subject: "Question about leadership coaching",
      date: ~U[2026-07-09 06:58:00Z],
      body_text: body
    }

    rendered =
      Valea.Mail.MessageFile.render(message, %{
        msg_id: "2026-07-09-priya-nair-seed0001",
        uid: nil,
        status: "review",
        source: "seed",
        source_ref: "email://seed/priya-nair-inquiry",
        attachments: []
      })

    assert rendered == bytes
  end

  test "create refuses a non-empty target" do
    target = tmp_target()
    File.mkdir_p!(target)
    File.write!(Path.join(target, "existing.txt"), "x")
    assert {:error, :target_not_empty} = Scaffold.create(target)
  end

  test "valid? recognizes a scaffolded workspace and rejects others" do
    target = tmp_target()
    :ok = Scaffold.create(target)
    assert Scaffold.valid?(target)
    refute Scaffold.valid?(System.tmp_dir!())
  end

  test "valid? requires mounts/, not the legacy icm/" do
    target = tmp_target()
    :ok = Scaffold.create(target)
    File.rm_rf!(Path.join(target, "mounts"))
    refute Scaffold.valid?(target)
  end

  test "inspect_summary counts content across mounts" do
    target = tmp_target()
    :ok = Scaffold.create(target)
    summary = Scaffold.inspect_summary(target)
    assert summary.valid
    assert summary.icm_pages >= 12
    assert summary.workflows == 5
    assert summary.queue_pending == 0
    assert summary.has_audit_log
  end

  # Task B9: the starter mount seeds a Distill Decisions workflow contract
  # (the basename Valea.Workflows.distill_path/0 matches, Task B8), a
  # Decisions/2026.md seed page, and the root + mount AGENTS.md both carry
  # the memory-update contract's vocabulary.
  test "create/2 seeds the Distill Decisions contract, a decision log, and the memory-update contract" do
    target = tmp_target()
    :ok = Scaffold.create(target, "Acme Coaching")

    workflows = Valea.Workflows.list(target)

    distill =
      Enum.find(workflows, &(Path.basename(&1.path) == "Distill Decisions.md"))

    assert distill, "expected a Distill Decisions.md workflow contract"
    assert distill.name == "Distill Decisions"
    assert distill.enabled == true
    assert distill.risk_level == "medium"

    assert File.exists?(Path.join(target, "mounts/acme-coaching/Decisions/2026.md"))

    root_agents = File.read!(Path.join(target, "AGENTS.md"))
    assert root_agents =~ "memory_update/v1"

    mount_agents = File.read!(Path.join(target, "mounts/acme-coaching/AGENTS.md"))
    assert mount_agents =~ "Decisions/"
  end
end
