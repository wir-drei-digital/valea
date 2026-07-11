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
    assert {:ok, 3} = Migration.migrate(root)

    assert File.exists?(Path.join(root, "AGENTS.md"))
    assert File.read!(Path.join(root, "CLAUDE.md")) =~ "@AGENTS.md"
    assert File.dir?(Path.join(root, "queue/staging"))
    assert File.dir?(Path.join(root, "queue/processing"))
    assert File.exists?(Path.join(root, ".claude/settings.json"))
    # a v1 workspace is brought all the way to the current version (v3),
    # gaining the persistent workspace id along the way
    workspace_yaml = File.read!(Path.join(root, "config/workspace.yaml"))
    assert workspace_yaml =~ "version: 3"
    assert workspace_yaml =~ ~r/^id: [0-9a-f-]{36}$/m

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
    assert {:ok, 3} = Migration.migrate(root)

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
    {:ok, 3} = Migration.migrate(root)
    snapshot = snapshot(root)
    {:ok, 3} = Migration.migrate(root)
    assert snapshot(root) == snapshot
  end

  test "does not overwrite an existing converted page or existing AGENTS.md" do
    root = v1_workspace!()
    File.mkdir_p!(Path.join(root, "icm/Workflows"))
    File.write!(Path.join(root, "icm/Workflows/New Inquiry Triage.md"), "user content")
    File.write!(Path.join(root, "AGENTS.md"), "user agents")
    {:ok, 3} = Migration.migrate(root)
    assert File.read!(Path.join(root, "icm/Workflows/New Inquiry Triage.md")) == "user content"
    assert File.read!(Path.join(root, "AGENTS.md")) == "user agents"
  end

  test "fresh v3 workspace (from template) migrates to a no-op" do
    root = Path.join(System.tmp_dir!(), "vmig-#{System.os_time(:nanosecond)}")
    on_exit(fn -> File.rm_rf!(root) end)
    :ok = Valea.Workspace.Scaffold.create(root)
    snapshot = snapshot(root)
    {:ok, 3} = Migration.migrate(root)
    # settings.json is (re)written but byte-identical; everything else untouched
    assert snapshot(root) == snapshot
  end

  # -- v2 → v3 -------------------------------------------------------------

  @fixtures_dir Path.expand("../../fixtures/workspace_v2", __DIR__)
  @priya_json_path "sources/mail/normalized/priya-nair-inquiry.json"
  @triage_path "icm/Workflows/New Inquiry Triage.md"
  @mail_yaml_path "config/mail.yaml"
  @seed_message_path "sources/mail/messages/2026-07-09-priya-nair-seed0001.md"
  @archive_dir "logs/migrations/v3"

  defp fixture(name), do: File.read!(Path.join(@fixtures_dir, name))
  defp template(rel), do: File.read!(Path.join(Valea.Workspace.Scaffold.template_dir(), rel))

  # Builds a pristine v2 workspace from the byte-exact v2 template files (the
  # ones this task deleted/rewrote), captured under test/fixtures/workspace_v2.
  # `overrides` swaps in user-modified bytes for a given relative path.
  defp v2_workspace!(overrides \\ %{}) do
    root = Path.join(System.tmp_dir!(), "vmig3-#{System.os_time(:nanosecond)}")

    for d <- ["config", "icm/Workflows", "sources/mail/normalized", "logs", "queue/pending"] do
      File.mkdir_p!(Path.join(root, d))
    end

    files = %{
      "config/workspace.yaml" => "version: 2\n",
      "config/mail.yaml" => fixture("mail.yaml"),
      @priya_json_path => fixture("priya-nair-inquiry.json"),
      @triage_path => fixture("New Inquiry Triage.md")
    }

    Enum.each(Map.merge(files, overrides), fn {rel, bytes} ->
      path = Path.join(root, rel)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, bytes)
    end)

    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  test "fresh scaffold: v3 marker + persistent uuid + seed message, no legacy JSON" do
    root = Path.join(System.tmp_dir!(), "vmig3-scaffold-#{System.os_time(:nanosecond)}")
    on_exit(fn -> File.rm_rf!(root) end)
    :ok = Valea.Workspace.Scaffold.create(root)

    yaml = File.read!(Path.join(root, "config/workspace.yaml"))
    assert yaml =~ "version: 3"
    assert [uuid] = Regex.run(~r/^id: ([0-9a-f-]{36})$/m, yaml, capture: :all_but_first)
    refute uuid == "TEMPLATE"

    assert File.exists?(Path.join(root, @seed_message_path))

    assert {:ok, _} =
             Valea.Mail.MessageFile.parse(File.read!(Path.join(root, @seed_message_path)))

    refute File.exists?(Path.join(root, @priya_json_path))
    refute File.dir?(Path.join(root, "sources/mail/normalized"))
  end

  test "pristine v2 → transformed and archived" do
    root = v2_workspace!()
    assert {:ok, 3} = Migration.migrate(root)

    # workspace.yaml gains version 3 + a fresh uuid
    yaml = File.read!(Path.join(root, "config/workspace.yaml"))
    assert yaml =~ "version: 3"
    assert yaml =~ ~r/^id: [0-9a-f-]{36}$/m

    # pristine mail.yaml replaced in place with the v3 template (not archived)
    assert File.read!(Path.join(root, @mail_yaml_path)) == template(@mail_yaml_path)
    refute File.exists?(Path.join([root, @archive_dir, "mail.yaml"]))

    # pristine triage page overwritten with the v3 template page
    assert File.read!(Path.join(root, @triage_path)) == template(@triage_path)

    # pristine JSON moved into the archive; gone from normalized/; seed present
    refute File.exists?(Path.join(root, @priya_json_path))

    assert File.read!(Path.join([root, @archive_dir, "priya-nair-inquiry.json"])) ==
             fixture("priya-nair-inquiry.json")

    assert File.read!(Path.join(root, @seed_message_path)) == template(@seed_message_path)

    # new mail dirs exist
    assert File.dir?(Path.join(root, "sources/mail/messages"))
    assert File.dir?(Path.join(root, "sources/mail/attachments"))
  end

  test "modified mail.yaml: values preserved, smtp/ssl dropped, original archived" do
    modified = """
    account: real@fastmail.example
    imap:
      host: imap.fastmail.example
      port: 1993
      ssl: true
      username_env: MAIL_USERNAME
      password_env: MAIL_APP_PASSWORD
    smtp:
      host: smtp.fastmail.example
      port: 587
    folders:
      review: "Team/Review"
      processed: "Team/Done"
      drafted: "Team/Drafted"
    safety:
      send_directly: false
      create_drafts_only: true
    """

    root = v2_workspace!(%{@mail_yaml_path => modified})
    assert {:ok, 3} = Migration.migrate(root)

    # original archived verbatim (append-only)
    assert File.read!(Path.join([root, @archive_dir, "mail.yaml"])) == modified

    # rewritten file is valid v3 with the user's values preserved
    bytes = File.read!(Path.join(root, @mail_yaml_path))
    refute bytes =~ "smtp:"
    refute bytes =~ "ssl:"
    refute bytes =~ "_env"

    assert {:ok, settings} = Valea.Mail.Settings.load(root)
    assert settings.account == "real@fastmail.example"
    assert settings.imap.host == "imap.fastmail.example"
    assert settings.imap.port == 1993
    # v2 had no username value (only username_env) → falls back to account
    assert settings.imap.username == "real@fastmail.example"
    # user folders preserved; drafted dropped, drafts added
    assert settings.folders.review == "Team/Review"
    assert settings.folders.processed == "Team/Done"
    assert settings.folders.drafts == "Drafts"
  end

  test "modified priya JSON is a user file: left in place, never archived" do
    modified_json = ~s({"id":"email_priya_nair_inquiry","note":"hand-edited"}\n)
    root = v2_workspace!(%{@priya_json_path => modified_json})
    assert {:ok, 3} = Migration.migrate(root)

    # user's modified JSON stays exactly where it is
    assert File.read!(Path.join(root, @priya_json_path)) == modified_json
    refute File.exists?(Path.join([root, @archive_dir, "priya-nair-inquiry.json"]))
    # seed message is still written alongside
    assert File.exists?(Path.join(root, @seed_message_path))
  end

  test "modified triage page is untouched" do
    modified_page = "---\nenabled: true\n---\n# My own triage\n\nHand-edited by the user.\n"
    root = v2_workspace!(%{@triage_path => modified_page})
    assert {:ok, 3} = Migration.migrate(root)

    assert File.read!(Path.join(root, @triage_path)) == modified_page
  end

  test "v2 → v3 is idempotent — second run changes nothing" do
    root = v2_workspace!()
    {:ok, 3} = Migration.migrate(root)
    snapshot = snapshot(root)
    {:ok, 3} = Migration.migrate(root)
    assert snapshot(root) == snapshot
  end

  test "does not write the seed message if one already exists" do
    root = v2_workspace!()
    File.mkdir_p!(Path.join(root, "sources/mail/messages"))
    File.write!(Path.join(root, @seed_message_path), "user seed content")
    {:ok, 3} = Migration.migrate(root)
    assert File.read!(Path.join(root, @seed_message_path)) == "user seed content"
  end

  test "preserves an existing workspace id defensively (never regenerates)" do
    root = v2_workspace!(%{"config/workspace.yaml" => "version: 2\nid: keep-me-1234\n"})
    {:ok, 3} = Migration.migrate(root)
    yaml = File.read!(Path.join(root, "config/workspace.yaml"))
    assert yaml =~ "version: 3"
    assert yaml =~ "id: keep-me-1234"
  end

  defp snapshot(root) do
    root
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Map.new(fn f -> {f, File.read!(f)} end)
  end
end
