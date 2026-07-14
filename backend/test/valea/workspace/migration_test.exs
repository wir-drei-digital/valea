defmodule Valea.Workspace.MigrationTest do
  use ExUnit.Case, async: true

  alias Valea.Markdown.ProseMirror
  alias Valea.Mounts.Manifest
  alias Valea.Workspace.Migration
  alias Valea.Workspace.Scaffold

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
    assert {:ok, 4} = Migration.migrate(root)
    slug = Scaffold.slugify(Path.basename(root))

    assert File.exists?(Path.join(root, "AGENTS.md"))
    assert File.read!(Path.join(root, "CLAUDE.md")) =~ "@AGENTS.md"
    assert File.dir?(Path.join(root, "queue/staging"))
    assert File.dir?(Path.join(root, "queue/processing"))
    assert File.exists?(Path.join(root, ".claude/settings.json"))
    # a v1 workspace is brought all the way to the current version (v4),
    # gaining the persistent workspace id along the way
    workspace_yaml = File.read!(Path.join(root, "config/workspace.yaml"))
    assert workspace_yaml =~ "version: 4"
    assert workspace_yaml =~ ~r/^id: [0-9a-f-]{36}$/m

    # the old top-level icm/ tree is gone; its content now lives in the mount
    refute File.dir?(Path.join(root, "icm"))
    page = File.read!(Path.join([root, "mounts", slug, "Workflows", "New Inquiry Triage.md"]))
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
    assert {:ok, 4} = Migration.migrate(root)
    slug = Scaffold.slugify(Path.basename(root))

    bytes =
      File.read!(Path.join([root, "mounts", slug, "Workflows", "New Inquiry Triage.md"]))

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
    {:ok, 4} = Migration.migrate(root)
    snapshot = snapshot(root)
    {:ok, 4} = Migration.migrate(root)
    assert snapshot(root) == snapshot
  end

  test "does not overwrite an existing converted page or existing AGENTS.md" do
    root = v1_workspace!()
    File.mkdir_p!(Path.join(root, "icm/Workflows"))
    File.write!(Path.join(root, "icm/Workflows/New Inquiry Triage.md"), "user content")
    File.write!(Path.join(root, "AGENTS.md"), "user agents")
    {:ok, 4} = Migration.migrate(root)
    slug = Scaffold.slugify(Path.basename(root))

    assert File.read!(Path.join([root, "mounts", slug, "Workflows", "New Inquiry Triage.md"])) ==
             "user content"

    assert File.read!(Path.join(root, "AGENTS.md")) == "user agents"
  end

  test "fresh v4 workspace (from template) migrates to a no-op" do
    root = Path.join(System.tmp_dir!(), "vmig-#{System.os_time(:nanosecond)}")
    on_exit(fn -> File.rm_rf!(root) end)
    :ok = Scaffold.create(root)
    snapshot = snapshot(root)
    {:ok, 4} = Migration.migrate(root)
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
  defp template(rel), do: File.read!(Path.join(Scaffold.template_dir(), rel))

  defp migration_fixture_v3(name),
    do: File.read!(Path.join(Application.app_dir(:valea, "priv/migration_fixtures/v3"), name))

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

  test "fresh scaffold: v4 marker + persistent uuid + seed message, no legacy JSON" do
    root = Path.join(System.tmp_dir!(), "vmig3-scaffold-#{System.os_time(:nanosecond)}")
    on_exit(fn -> File.rm_rf!(root) end)
    :ok = Scaffold.create(root)

    yaml = File.read!(Path.join(root, "config/workspace.yaml"))
    assert yaml =~ "version: 4"
    assert [uuid] = Regex.run(~r/^id: ([0-9a-f-]{36})$/m, yaml, capture: :all_but_first)
    refute uuid == "TEMPLATE"

    assert File.exists?(Path.join(root, @seed_message_path))

    assert {:ok, _} =
             Valea.Mail.MessageFile.parse(File.read!(Path.join(root, @seed_message_path)))

    refute File.exists?(Path.join(root, @priya_json_path))
    refute File.dir?(Path.join(root, "sources/mail/normalized"))
  end

  test "pristine v2 → transformed and archived, then relocated into the mount at v4" do
    root = v2_workspace!()
    slug = Scaffold.slugify(Path.basename(root))
    assert {:ok, 4} = Migration.migrate(root)

    # workspace.yaml gains version 4 + a fresh uuid
    yaml = File.read!(Path.join(root, "config/workspace.yaml"))
    assert yaml =~ "version: 4"
    assert yaml =~ ~r/^id: [0-9a-f-]{36}$/m

    # pristine mail.yaml replaced in place with the v3 template (not archived;
    # config/mail.yaml is untouched by the v3→v4 icm/ → mounts/ relocation)
    assert File.read!(Path.join(root, @mail_yaml_path)) == template(@mail_yaml_path)
    refute File.exists?(Path.join([root, @archive_dir, "mail.yaml"]))

    # the old icm/ tree is gone entirely: its pristine triage page was
    # overwritten with the v3 replacement bytes (v2→v3), then the whole tree
    # was relocated byte-for-byte into the mount (v3→v4)
    refute File.dir?(Path.join(root, "icm"))
    mount_triage = Path.join([root, "mounts", slug, "Workflows", "New Inquiry Triage.md"])
    assert File.read!(mount_triage) == migration_fixture_v3("New Inquiry Triage.md")

    # pristine JSON moved into the archive; gone from normalized/; seed present
    refute File.exists?(Path.join(root, @priya_json_path))

    assert File.read!(Path.join([root, @archive_dir, "priya-nair-inquiry.json"])) ==
             fixture("priya-nair-inquiry.json")

    assert File.read!(Path.join(root, @seed_message_path)) == template(@seed_message_path)

    # new mail dirs exist
    assert File.dir?(Path.join(root, "sources/mail/messages"))
    assert File.dir?(Path.join(root, "sources/mail/attachments"))

    # the mount got a fresh manifest, and MOUNTS.md was regenerated
    mount_dir = Path.join([root, "mounts", slug])
    assert {:ok, manifest} = Manifest.load(mount_dir)
    assert manifest.name == Path.basename(root)
    assert File.exists?(Path.join(root, "MOUNTS.md"))
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
    assert {:ok, 4} = Migration.migrate(root)

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
    assert {:ok, 4} = Migration.migrate(root)

    # user's modified JSON stays exactly where it is
    assert File.read!(Path.join(root, @priya_json_path)) == modified_json
    refute File.exists?(Path.join([root, @archive_dir, "priya-nair-inquiry.json"]))
    # seed message is still written alongside
    assert File.exists?(Path.join(root, @seed_message_path))
  end

  test "modified triage page is untouched, then relocated (byte-preserving) into the mount" do
    modified_page = "---\nenabled: true\n---\n# My own triage\n\nHand-edited by the user.\n"
    root = v2_workspace!(%{@triage_path => modified_page})
    slug = Scaffold.slugify(Path.basename(root))
    assert {:ok, 4} = Migration.migrate(root)

    assert File.read!(Path.join([root, "mounts", slug, "Workflows", "New Inquiry Triage.md"])) ==
             modified_page
  end

  test "v2 → v4 is idempotent — second run changes nothing" do
    root = v2_workspace!()
    {:ok, 4} = Migration.migrate(root)
    snapshot = snapshot(root)
    {:ok, 4} = Migration.migrate(root)
    assert snapshot(root) == snapshot
  end

  test "does not write the seed message if one already exists" do
    root = v2_workspace!()
    File.mkdir_p!(Path.join(root, "sources/mail/messages"))
    File.write!(Path.join(root, @seed_message_path), "user seed content")
    {:ok, 4} = Migration.migrate(root)
    assert File.read!(Path.join(root, @seed_message_path)) == "user seed content"
  end

  test "preserves an existing workspace id defensively (never regenerates)" do
    root = v2_workspace!(%{"config/workspace.yaml" => "version: 2\nid: keep-me-1234\n"})
    {:ok, 4} = Migration.migrate(root)
    yaml = File.read!(Path.join(root, "config/workspace.yaml"))
    assert yaml =~ "version: 4"
    assert yaml =~ "id: keep-me-1234"
  end

  # -- v3 → v4 -------------------------------------------------------------

  @fixtures_v3_dir Path.expand("../../fixtures/workspace_v3", __DIR__)
  defp fixture_v3(name), do: File.read!(Path.join(@fixtures_v3_dir, name))

  # Builds a minimal v3-shaped (pre-mounts) workspace directly at version 3.
  # `ensure_v2`/`ensure_v3` both short-circuit at `v >= their own version`, so
  # this must independently create everything a real v1→v2→v3 climb would
  # have left behind that `ensure_v4` (or this section's assertions) cares
  # about: the top-level `icm/Workflows/` tree, a root AGENTS.md/CLAUDE.md,
  # and (to exercise the prompts-move step) a top-level `prompts/`.
  defp v3_workspace!(overrides \\ %{}) do
    root =
      Path.join(
        System.tmp_dir!(),
        "vmig4-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    for d <- ["config", "icm/Workflows", "prompts"] do
      File.mkdir_p!(Path.join(root, d))
    end

    files = %{
      "config/workspace.yaml" =>
        "version: 3\nid: v3fixture-#{System.unique_integer([:positive])}\n",
      "AGENTS.md" => fixture_v3("AGENTS.md"),
      "CLAUDE.md" => "@AGENTS.md\n",
      @triage_path => fixture("New Inquiry Triage.md"),
      "prompts/reply_writer.md" => "A reusable prompt fragment.\n"
    }

    Enum.each(Map.merge(files, overrides), fn {rel, bytes} ->
      path = Path.join(root, rel)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, bytes)
    end)

    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  test "v3 → v4: icm/ gone, mounts/<slug>/ minted (manifest + AGENTS.md + CLAUDE.md), " <>
         "prompts moved, root AGENTS.md replaced (pristine), MOUNTS.md present, version 4" do
    root = v3_workspace!()
    slug = Scaffold.slugify(Path.basename(root))

    assert {:ok, 4} = Migration.migrate(root)

    refute File.dir?(Path.join(root, "icm"))
    refute File.dir?(Path.join(root, "prompts"))

    mount_dir = Path.join([root, "mounts", slug])
    assert File.dir?(mount_dir)

    assert File.read!(Path.join(mount_dir, "Workflows/New Inquiry Triage.md")) ==
             fixture("New Inquiry Triage.md")

    assert {:ok, manifest} = Manifest.load(mount_dir)
    assert manifest.name == Path.basename(root)
    assert Regex.match?(~r/^[0-9a-f-]{36}$/, manifest.id)

    assert File.exists?(Path.join(mount_dir, "AGENTS.md"))
    assert File.read!(Path.join(mount_dir, "CLAUDE.md")) =~ "@AGENTS.md"

    assert File.read!(Path.join(mount_dir, "prompts/reply_writer.md")) ==
             "A reusable prompt fragment.\n"

    root_agents = File.read!(Path.join(root, "AGENTS.md"))
    assert root_agents == File.read!(Path.join(Scaffold.legacy_template_dir(), "AGENTS.md"))
    assert root_agents =~ "@MOUNTS.md"

    assert File.exists?(Path.join(root, "MOUNTS.md"))
    mounts_md = File.read!(Path.join(root, "MOUNTS.md"))

    # KNOWN FAILING (reported, not papered over — see the migration
    # report): the v3->v4 step mints this mount by RENAMING `icm/` to
    # `mounts/<slug>` (embedded, INSIDE the workspace) but never writes an
    # `icms:` config entry for it. `Valea.Mounts.list/1` is config truth
    # over `icms:` ONLY now, so `MountsMd.regenerate/1` (which reads
    # `Mounts.list/1`) can never see this mount — and even a hand-written
    # `icms:` entry pointing at it would be degraded on read by
    # `Valea.Mounts.External.check_boundaries/2`'s `:inside_workspace`
    # rule, which is unconditional and by design (every declared mount
    # must resolve OUTSIDE the workspace). Same root cause, same
    # resolution options, as the identical gap in
    # `test/valea/workspace/adopt_test.exs`'s "moves the folder into
    # mounts/<slug>..." test — fixing it needs a product decision above
    # this test's scope (either `Migration` mounts by reference instead of
    # renaming in place, or `Mounts` grows a legitimate in-workspace mount
    # concept, a change to the forbidden `lib/valea/mounts.ex` / its
    # `external.ex` boundary rules). Left failing rather than weakened.
    assert mounts_md =~ "@mounts/#{slug}/AGENTS.md"

    yaml = File.read!(Path.join(root, "config/workspace.yaml"))
    assert yaml =~ "version: 4"
  end

  test "v3 → v4 resumes correctly after a crash between the icm/ rename and the remaining steps" do
    root = v3_workspace!()
    slug = Scaffold.slugify(Path.basename(root))

    # Simulate a process that died right after `locate_or_create_mount!/2`
    # renamed icm/ → mounts/<slug>, but before minting the manifest or
    # bumping the version marker: config/workspace.yaml still says v3.
    File.mkdir_p!(Path.join(root, "mounts"))
    File.rename!(Path.join(root, "icm"), Path.join([root, "mounts", slug]))

    assert {:ok, 4} = Migration.migrate(root)

    # resumed into the SAME mount — no mounts/<slug>-2 duplicate was minted
    refute File.dir?(Path.join([root, "mounts", "#{slug}-2"]))
    mount_dir = Path.join([root, "mounts", slug])
    assert File.exists?(Path.join(mount_dir, "Workflows/New Inquiry Triage.md"))
    assert {:ok, manifest} = Manifest.load(mount_dir)
    assert manifest.name == Path.basename(root)

    yaml = File.read!(Path.join(root, "config/workspace.yaml"))
    assert yaml =~ "version: 4"
  end

  test "v3 → v4: a modified root AGENTS.md is left in place (not replaced)" do
    modified = "# My Own Root Instructions\n\nHand-edited.\n"
    root = v3_workspace!(%{"AGENTS.md" => modified})

    assert {:ok, 4} = Migration.migrate(root)

    assert File.read!(Path.join(root, "AGENTS.md")) == modified
  end

  test "v3 → v4 idempotent — second run changes nothing" do
    root = v3_workspace!()
    {:ok, 4} = Migration.migrate(root)
    snapshot = snapshot(root)
    {:ok, 4} = Migration.migrate(root)
    assert snapshot(root) == snapshot
  end

  test "v3 → v4 target-name collision appends -2" do
    root = v3_workspace!()
    slug = Scaffold.slugify(Path.basename(root))

    File.mkdir_p!(Path.join(root, "mounts"))
    collision_dir = Path.join([root, "mounts", slug])
    File.mkdir_p!(collision_dir)
    File.write!(Path.join(collision_dir, "keepme.txt"), "pre-existing, unrelated")

    assert {:ok, 4} = Migration.migrate(root)

    # the pre-existing directory at mounts/<slug> is untouched — never our tree
    assert File.read!(Path.join(collision_dir, "keepme.txt")) == "pre-existing, unrelated"
    refute File.exists?(Path.join(collision_dir, "icm.yaml"))

    # icm/ was relocated into mounts/<slug>-2 instead
    target = Path.join([root, "mounts", "#{slug}-2"])
    assert File.dir?(target)
    assert File.exists?(Path.join(target, "Workflows/New Inquiry Triage.md"))
    assert {:ok, _} = Manifest.load(target)

    refute File.dir?(Path.join(root, "icm"))
  end

  test "v3 → v4: prompts/ exists but icm/ is absent (hand-corrupted) → creates mount dir, migrates prompts" do
    root =
      Path.join(
        System.tmp_dir!(),
        "vmig4-prompts-only-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    for d <- ["config", "prompts"] do
      File.mkdir_p!(Path.join(root, d))
    end

    files = %{
      "config/workspace.yaml" =>
        "version: 3\nid: v3fixture-prompts-only-#{System.unique_integer([:positive])}\n",
      "AGENTS.md" => fixture_v3("AGENTS.md"),
      "CLAUDE.md" => "@AGENTS.md\n",
      "prompts/reply_writer.md" => "A reusable prompt fragment.\n"
    }

    Enum.each(files, fn {rel, bytes} ->
      path = Path.join(root, rel)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, bytes)
    end)

    on_exit(fn -> File.rm_rf!(root) end)
    slug = Scaffold.slugify(Path.basename(root))

    # This should succeed despite icm/ being absent — mkdir_p! happens before prompts move
    assert {:ok, 4} = Migration.migrate(root)

    # prompts/ is gone from root, now inside the mount
    refute File.dir?(Path.join(root, "prompts"))
    mount_dir = Path.join([root, "mounts", slug])

    assert File.read!(Path.join(mount_dir, "prompts/reply_writer.md")) ==
             "A reusable prompt fragment.\n"

    # mount manifest and AGENTS.md were created
    assert {:ok, manifest} = Manifest.load(mount_dir)
    assert manifest.name == Path.basename(root)
    assert File.exists?(Path.join(mount_dir, "AGENTS.md"))

    # version marker is set to v4
    yaml = File.read!(Path.join(root, "config/workspace.yaml"))
    assert yaml =~ "version: 4"
  end

  defp snapshot(root) do
    root
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Map.new(fn f -> {f, File.read!(f)} end)
  end
end
