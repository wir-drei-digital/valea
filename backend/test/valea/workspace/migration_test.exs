defmodule Valea.Workspace.MigrationTest do
  use ExUnit.Case, async: true

  alias Valea.Markdown.ProseMirror
  alias Valea.Workspace.Migration

  defp v1_workspace! do
    root = Path.join(System.tmp_dir!(), "vmig-#{System.os_time(:nanosecond)}")

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

    File.write!(Path.join(root, "workflows/new_inquiry_triage.yaml"), """
    id: new_inquiry_triage
    name: New Inquiry Triage
    description: Classifies a new email inquiry and drafts a reply for review.
    enabled: true
    trigger:
      type: manual
      source: email.selected
    sources:
      - id: offer
        type: icm
        path: icm/Offers/Founder Coaching Package.md
    steps:
      - id: draft_reply
        instruction: Draft a warm reply.
    outputs:
      - type: approval_item
        schema: queue_item
    approval:
      required: true
      reason: Email replies must be reviewed before sending.
      actions:
        - create_email_draft
    risk_level: medium
    audit:
      log_sources: true
      log_inputs: true
      log_outputs: true
      log_agent: true
    """)

    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  test "migrates v1: layer files, converted workflow page, dirs, settings, marker" do
    root = v1_workspace!()
    assert {:ok, 2} = Migration.migrate(root)

    assert File.exists?(Path.join(root, "AGENTS.md"))
    assert File.read!(Path.join(root, "CLAUDE.md")) =~ "@AGENTS.md"
    assert File.dir?(Path.join(root, "queue/staging"))
    assert File.dir?(Path.join(root, "queue/processing"))
    assert File.exists?(Path.join(root, ".claude/settings.json"))
    assert File.read!(Path.join(root, "config/workspace.yaml")) =~ "version: 2"

    page = File.read!(Path.join(root, "icm/Workflows/New Inquiry Triage.md"))
    assert String.starts_with?(page, "---\n")
    assert page =~ "enabled: true"
    assert page =~ "icm/Offers/Founder Coaching Package.md"
    assert page =~ "# New Inquiry Triage"
    assert page =~ "Draft a warm reply."
    # the source yaml is preserved, never deleted
    assert File.exists?(Path.join(root, "workflows/new_inquiry_triage.yaml"))
  end

  test "generated workflow page is canonical (round-trips byte-identically)" do
    root = v1_workspace!()
    assert {:ok, 2} = Migration.migrate(root)

    bytes = File.read!(Path.join(root, "icm/Workflows/New Inquiry Triage.md"))
    {block, body} = Valea.ICM.split_frontmatter(bytes)

    assert block != "", "expected the generated page to carry a frontmatter block"

    refute String.starts_with?(body, "\n"),
           "body must not have a blank line right after the closing frontmatter delimiter"

    {:ok, pm} = ProseMirror.from_markdown(body)
    {:ok, roundtripped} = ProseMirror.to_markdown(pm)

    assert block <> roundtripped == bytes,
           "generated workflow page does not round-trip byte-identically; opening and " <>
             "saving it untouched in the editor would rewrite the file"
  end

  test "idempotent — second run changes nothing" do
    root = v1_workspace!()
    {:ok, 2} = Migration.migrate(root)
    snapshot = snapshot(root)
    {:ok, 2} = Migration.migrate(root)
    assert snapshot(root) == snapshot
  end

  test "does not overwrite an existing converted page or existing AGENTS.md" do
    root = v1_workspace!()
    File.mkdir_p!(Path.join(root, "icm/Workflows"))
    File.write!(Path.join(root, "icm/Workflows/New Inquiry Triage.md"), "user content")
    File.write!(Path.join(root, "AGENTS.md"), "user agents")
    {:ok, 2} = Migration.migrate(root)
    assert File.read!(Path.join(root, "icm/Workflows/New Inquiry Triage.md")) == "user content"
    assert File.read!(Path.join(root, "AGENTS.md")) == "user agents"
  end

  test "fresh v2 workspace (from template) migrates to a no-op" do
    root = Path.join(System.tmp_dir!(), "vmig-#{System.os_time(:nanosecond)}")
    on_exit(fn -> File.rm_rf!(root) end)
    :ok = Valea.Workspace.Scaffold.create(root)
    snapshot = snapshot(root)
    {:ok, 2} = Migration.migrate(root)
    # settings.json is (re)written but byte-identical; everything else untouched
    assert snapshot(root) == snapshot
  end

  defp snapshot(root) do
    root
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Map.new(fn f -> {f, File.read!(f)} end)
  end
end
