defmodule Valea.Workspace.Migration do
  @moduledoc """
  Idempotent, versioned workspace upgrades, run by the Manager on every
  open/create after the repo and runtime start and before the workspace is
  presented as open. Never deletes or overwrites user files; converted
  sources are left in place.

  Byte-preserving renames are permitted; the never-delete/never-overwrite
  contract forbids destroying or clobbering CONTENT, not relocating a tree
  (see `ensure_v4/2`, which relocates the whole legacy `icm/` tree into
  `mounts/<slug>/` without touching a single byte inside it).
  """

  alias Valea.Markdown.ProseMirror
  alias Valea.Mail.Settings
  alias Valea.Mounts.Manifest
  alias Valea.Mounts.MountsMd
  alias Valea.Workspace.Scaffold

  @current_version 4

  # SHA-256 of the pristine v2 template seed files this migration knows how to
  # transform. Computed from the v2 template bytes as they stood on `main`
  # BEFORE this task's edits, with:
  #
  #   shasum -a 256 priv/workspace_template/sources/mail/normalized/priya-nair-inquiry.json
  #   shasum -a 256 priv/workspace_template/config/mail.yaml
  #   shasum -a 256 "priv/workspace_template/icm/Workflows/New Inquiry Triage.md"
  #
  # Only a byte-identical file counts as pristine and is transformed in place;
  # a user-modified file is NEVER deleted or overwritten (see the moduledoc
  # contract) — it is left where it is (JSON, triage page) or archived first
  # (mail.yaml) before a value-preserving rewrite.
  @v2_priya_json_sha "cce5274405b9ede2a268b8337b8205579d75dc61b8af38241cdde3ada046fe2a"
  @v2_mail_yaml_sha "473de344164a1d778f4488d166d9846e0ba329af0532a0b63f9bbd985c0914eb"
  @v2_triage_sha "23ffbefe71c264c2f9ef945dc2fab269228789f19da47847d5f0bf6c01f9080f"

  # SHA-256 of the pristine v3 root AGENTS.md — the pre-mounts, `icm/`-routing
  # template as it stood immediately before the mounts-template task (T8)
  # rewrote it into the current, rules-only, `@MOUNTS.md`-routing version:
  #
  #   git show b8ebe7f:backend/priv/workspace_template/AGENTS.md | shasum -a 256
  #
  # (`b8ebe7f` is T8's parent commit.) Only a byte-identical file counts as
  # pristine and is replaced in place by `migrate_root_agents!/1`; a
  # user-modified root AGENTS.md is left exactly where it is.
  @v3_root_agents_sha "7cd9215c88f5edf9096e422e405b92aa4bd08fe3f006e7b9e2fd38b829e2240a"

  # Append-only archive for files the v2→v3 step moves or supersedes. Never
  # itself migrated; entries are only ever added, never clobbered.
  @archive_rel "logs/migrations/v3"
  @priya_json_rel "sources/mail/normalized/priya-nair-inquiry.json"
  @seed_message_rel "sources/mail/messages/2026-07-09-priya-nair-seed0001.md"
  @mail_yaml_rel "config/mail.yaml"
  @triage_rel "icm/Workflows/New Inquiry Triage.md"

  @spec migrate(String.t()) :: {:ok, integer()} | {:error, String.t()}
  def migrate(root) do
    with {:ok, v} <- ensure_v2(root, read_version(root)),
         {:ok, v} <- ensure_v3(root, v),
         {:ok, _} <- ensure_v4(root, v) do
      # Managed settings are regenerated on every open (and per session start).
      Valea.Agents.ClaudeSettings.write!(root)
      {:ok, @current_version}
    end
  rescue
    e -> {:error, "migration failed: #{Exception.message(e)}"}
  end

  defp read_version(root) do
    path = Path.join(root, "config/workspace.yaml")

    with true <- File.exists?(path),
         {:ok, %{"version" => v}} when is_integer(v) <- YamlElixir.read_from_file(path) do
      v
    else
      _ -> 1
    end
  end

  defp ensure_v2(_root, v) when v >= 2, do: {:ok, v}

  defp ensure_v2(root, _v) do
    copy_missing!(root, "AGENTS.md")
    copy_missing!(root, "CLAUDE.md")
    File.mkdir_p!(Path.join(root, "queue/staging"))
    File.mkdir_p!(Path.join(root, "queue/processing"))
    File.mkdir_p!(Path.join(root, "icm/Workflows"))
    convert_workflows!(root)
    ensure_gitignore_claude!(root)
    File.mkdir_p!(Path.join(root, "config"))
    File.write!(Path.join(root, "config/workspace.yaml"), "version: 2\n")
    {:ok, 2}
  end

  # v2 → v3 (mail design spec, §Seed & migration). Every step is idempotent
  # and safe to re-run after a mid-migration crash. `config/workspace.yaml`
  # (the version marker) is written LAST, so an interrupted run leaves the
  # workspace at v2 and the whole step runs again cleanly next open.
  defp ensure_v3(_root, v) when v >= 3, do: {:ok, v}

  defp ensure_v3(root, _v) do
    # Determine the persistent workspace id up front (preserve an existing one
    # defensively; a v2 workspace.yaml holds only `version:`, so this normally
    # mints a fresh UUID), but write it LAST.
    id = workspace_id_or_new(root)

    migrate_priya_seed!(root)
    migrate_mail_yaml!(root)
    migrate_triage_page!(root)

    File.mkdir_p!(Path.join(root, "sources/mail/messages"))
    File.mkdir_p!(Path.join(root, "sources/mail/attachments"))

    File.mkdir_p!(Path.join(root, "config"))
    File.write!(Path.join(root, "config/workspace.yaml"), "version: 3\nid: #{id}\n")
    {:ok, 3}
  end

  # v3 → v4 (mounts design spec, §Migration): the single top-level `icm/`
  # tree becomes a real mount at `mounts/<slug>/`. Every step is idempotent
  # and safe to re-run after a mid-migration crash — including a crash
  # between the `icm/` → `mounts/<slug>/` rename and the steps that follow
  # it, which relocate `locate_or_create_mount!/2`'s target from scratch
  # every call and land on the SAME directory again rather than minting a
  # second, empty one (see that function's doc). `config/workspace.yaml`
  # (the version marker) is written LAST, so an interrupted run leaves the
  # workspace at v3 and the whole step runs again cleanly next open.
  defp ensure_v4(_root, v) when v >= 4, do: {:ok, v}

  defp ensure_v4(root, _v) do
    id = workspace_id_or_new(root)
    slug = Scaffold.slugify(Path.basename(root))

    mount_dir = locate_or_create_mount!(root, slug)
    migrate_prompts_to_mount!(root, mount_dir)
    mint_migrated_mount_files!(root, mount_dir)
    migrate_root_agents!(root)

    MountsMd.regenerate(root)

    File.mkdir_p!(Path.join(root, "mounts"))
    File.write!(Path.join(root, "config/workspace.yaml"), "version: 4\nid: #{id}\n")
    {:ok, 4}
  end

  defp workspace_id_or_new(root) do
    path = Path.join(root, "config/workspace.yaml")

    with true <- File.exists?(path),
         {:ok, %{"id" => id}} when is_binary(id) <- YamlElixir.read_from_file(path),
         true <- id not in ["", "TEMPLATE"] do
      id
    else
      _ -> Ecto.UUID.generate()
    end
  end

  # Priya mock: the legacy JSON at sources/mail/normalized/ is superseded by a
  # seed markdown message. Pristine JSON → moved into the archive (removed from
  # normalized/, which is going away, but never destroyed). Modified JSON → a
  # user file; left exactly where it is. Either way the seed message is written
  # if absent, so the no-account demo loop keeps working.
  defp migrate_priya_seed!(root) do
    json_path = Path.join(root, @priya_json_rel)

    if File.exists?(json_path) and pristine?(json_path, @v2_priya_json_sha) do
      archive_into!(root, json_path, "priya-nair-inquiry.json")
    end

    write_seed_message_if_absent!(root)
  end

  defp write_seed_message_if_absent!(root) do
    target = Path.join(root, @seed_message_rel)

    unless File.exists?(target) do
      File.mkdir_p!(Path.dirname(target))
      File.cp!(Path.join(template_dir(), @seed_message_rel), target)
    end
  end

  # config/mail.yaml: pristine v2 seed → replaced in place with the v3 template
  # bytes (recoverable seed, so not archived). Missing → template. Already the
  # v3 template (fresh scaffold, or a crash re-run) → left alone. User-modified
  # → the original is archived (append-only, never clobbered), then the file is
  # rewritten preserving account / imap.host,port,username / folders while
  # dropping smtp, ssl, and the *_env keys.
  defp migrate_mail_yaml!(root) do
    path = Path.join(root, @mail_yaml_rel)
    template = Path.join(template_dir(), @mail_yaml_rel)

    cond do
      not File.exists?(path) -> File.cp!(template, path)
      File.read!(path) == File.read!(template) -> :ok
      pristine?(path, @v2_mail_yaml_sha) -> File.cp!(template, path)
      true -> rewrite_modified_mail_yaml!(root, path)
    end
  end

  defp rewrite_modified_mail_yaml!(root, path) do
    archive_copy!(root, path, "mail.yaml")
    File.write!(path, Settings.render(preserved_mail_settings(path)))
  end

  # Value-preserving v2→v3 projection. The v2 shape carried credentials only as
  # `*_env` names (no username value), so `imap.username` falls back to the
  # account. Folders keep the user's review/processed, drop the v2 `drafted`,
  # and gain `drafts: "Drafts"`; sync/safety take the v3 defaults.
  defp preserved_mail_settings(path) do
    doc =
      case YamlElixir.read_from_file(path) do
        {:ok, m} when is_map(m) -> m
        _ -> %{}
      end

    imap = as_map(doc["imap"])
    folders = as_map(doc["folders"])

    account = as_string(doc["account"])
    username = as_string(imap["username"])

    %Settings{
      account: account || username || "",
      imap: %{
        host: as_string(imap["host"]) || "",
        port: as_port(imap["port"]),
        username: username || account || ""
      },
      folders: %{
        review: as_string(folders["review"]) || "AI/Review",
        processed: as_string(folders["processed"]) || "AI/Processed",
        drafts: "Drafts"
      }
    }
  end

  # New Inquiry Triage page: pristine v2 seed → overwritten with the updated v3
  # template (input contract now names a sources/mail/messages/*.md file). A
  # user-modified page is left untouched, with an audited note that its input
  # contract may still point at the legacy JSON (the mail doctor surfaces the
  # same mismatch). Absent (shouldn't happen post-v2) → the template page.
  defp migrate_triage_page!(root) do
    path = Path.join(root, @triage_rel)
    template = Path.join(v3_fixtures_dir(), "New Inquiry Triage.md")

    cond do
      not File.exists?(path) ->
        File.mkdir_p!(Path.dirname(path))
        File.cp!(template, path)

      pristine?(path, @v2_triage_sha) ->
        File.cp!(template, path)

      true ->
        audit("migration_note", %{
          "note" =>
            "triage workflow page kept (user-modified); its input contract may still reference the legacy JSON"
        })
    end
  end

  # -- v4 helpers --------------------------------------------------------

  # Locates the mount that used to be the top-level `icm/` tree, renaming it
  # there if it still exists. Pre-mounts workspaces never had a `mounts/`
  # directory before this step runs, so while `icm/` is still present, every
  # `mounts/<slug-N>` found occupied is a genuine name collision (never our
  # own migrated tree) and the scan tries the next `-N` suffix. Once `icm/`
  # is gone — this run's rename already ran, or an earlier crashed run's
  # rename already ran — the migrated mount, if any, is identified by
  # carrying a `Workflows/` subdir (guaranteed present: `ensure_v2` always
  # creates `icm/Workflows`), so a retry after a crash between the rename
  # and the steps that follow it finds the SAME directory again rather than
  # minting a second, empty one.
  defp locate_or_create_mount!(root, slug) do
    mounts_dir = Path.join(root, "mounts")
    icm_dir = Path.join(root, "icm")
    File.mkdir_p!(mounts_dir)

    if File.dir?(icm_dir) do
      target = mount_slot(mounts_dir, slug, fn _ -> false end)
      File.rename!(icm_dir, target)
      target
    else
      mount_slot(mounts_dir, slug, &migrated_mount?/1)
    end
  end

  defp migrated_mount?(dir), do: File.dir?(Path.join(dir, "Workflows"))

  # First of `<slug>`, `<slug>-2`, `<slug>-3`, ... that is either free, or —
  # per `reuse?` — already ours to keep using rather than a real collision.
  defp mount_slot(mounts_dir, slug, reuse?, n \\ nil) do
    name = if n, do: "#{slug}-#{n}", else: slug
    candidate = Path.join(mounts_dir, name)

    cond do
      not File.exists?(candidate) -> candidate
      reuse?.(candidate) -> candidate
      true -> mount_slot(mounts_dir, slug, reuse?, (n || 1) + 1)
    end
  end

  # If root `prompts/` exists and the mount doesn't have its own yet, move it
  # in. A target that already exists is left alone — its source stays right
  # where it is too — the never-overwrite contract, not a failed rename.
  defp migrate_prompts_to_mount!(root, mount_dir) do
    prompts_dir = Path.join(root, "prompts")
    target = Path.join(mount_dir, "prompts")

    if File.dir?(prompts_dir) and not File.exists?(target) do
      File.rename!(prompts_dir, target)
    end
  end

  # Mints the migrated mount's own icm.yaml/AGENTS.md/CLAUDE.md — each only
  # if absent, so a re-run (or a mount a user already half-populated by
  # hand) never clobbers anything.
  defp mint_migrated_mount_files!(root, mount_dir) do
    File.mkdir_p!(mount_dir)

    manifest_path = Path.join(mount_dir, "icm.yaml")

    unless File.exists?(manifest_path) do
      Manifest.write!(mount_dir, %{
        id: Ecto.UUID.generate(),
        name: Path.basename(root),
        description: ""
      })
    end

    copy_missing_into!(mount_dir, "AGENTS.md", "mounts/starter/AGENTS.md")
    copy_missing_into!(mount_dir, "CLAUDE.md", "mounts/starter/CLAUDE.md")
  end

  defp copy_missing_into!(mount_dir, name, template_rel) do
    target = Path.join(mount_dir, name)

    unless File.exists?(target) do
      File.cp!(Path.join(Scaffold.template_dir(), template_rel), target)
    end
  end

  # Root AGENTS.md: pristine v3 seed (the pre-mounts, `icm/`-routing version)
  # → replaced with the current, rules-only, `@MOUNTS.md`-routing template.
  # User-modified → left in place, with an audited note — same posture as
  # the v2→v3 triage-page rule; surfacing this to the user is a doctor
  # concern (T13's territory), this only guarantees the audit trail exists.
  # Absent (shouldn't happen post-v2) → the template page.
  defp migrate_root_agents!(root) do
    path = Path.join(root, "AGENTS.md")
    template = Path.join(Scaffold.template_dir(), "AGENTS.md")

    cond do
      not File.exists?(path) ->
        File.cp!(template, path)

      pristine?(path, @v3_root_agents_sha) ->
        File.cp!(template, path)

      true ->
        audit("migration_note", %{
          "note" =>
            "root AGENTS.md kept (user-modified); it still routes via icm/ rather than @MOUNTS.md"
        })
    end
  end

  defp v3_fixtures_dir, do: Application.app_dir(:valea, "priv/migration_fixtures/v3")

  # -- v3 helpers ------------------------------------------------------------

  # Moves `src` into the archive under `name` (idempotent: a rename leaves no
  # source behind, so a re-run finds nothing to move).
  defp archive_into!(root, src, name) do
    dir = Path.join(root, @archive_rel)
    File.mkdir_p!(dir)
    File.rename!(src, Path.join(dir, name))
  end

  # Copies `src` into the archive under `name`, but never over an existing
  # archived file — the archive is append-only, so a crash re-run must not
  # overwrite the original it preserved on the first pass.
  defp archive_copy!(root, src, name) do
    dir = Path.join(root, @archive_rel)
    File.mkdir_p!(dir)
    dest = Path.join(dir, name)
    unless File.exists?(dest), do: File.cp!(src, dest)
  end

  defp pristine?(path, expected_sha) do
    case File.read(path) do
      {:ok, bytes} -> sha256(bytes) == expected_sha
      _ -> false
    end
  end

  defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  defp as_map(m) when is_map(m), do: m
  defp as_map(_), do: %{}

  defp as_string(s) when is_binary(s), do: s
  defp as_string(_), do: nil

  defp as_port(p) when is_integer(p) and p > 0, do: p
  defp as_port(_), do: 993

  # Audit only when the workspace's Audit process is up (mirrors the
  # Process.whereis guard in Runner/Queue/SyncPass): the migration runs after
  # the Runtime started it, but the guard keeps offline callers (and tests)
  # from crashing on :noproc.
  defp audit(type, fields) do
    if Process.whereis(Valea.Audit), do: Valea.Audit.append(type, fields)
  end

  defp copy_missing!(root, rel) do
    target = Path.join(root, rel)

    unless File.exists?(target) do
      File.cp!(Path.join(template_dir(), rel), target)
    end
  end

  defp template_dir, do: Application.app_dir(:valea, "priv/workspace_template")

  defp convert_workflows!(root) do
    root
    |> Path.join("workflows/*.yaml")
    |> Path.wildcard()
    |> Enum.each(fn yaml_path ->
      case YamlElixir.read_from_file(yaml_path) do
        {:ok, wf} when is_map(wf) ->
          name = wf["name"] || Path.basename(yaml_path, ".yaml")
          target = Path.join(root, "icm/Workflows/#{name}.md")
          unless File.exists?(target), do: File.write!(target, workflow_page(wf, name))

        _ ->
          :ok
      end
    end)
  end

  # Builds a canonical icm/Workflows page: `frontmatter_block <> body` where
  # `frontmatter_block` is exactly `---\n...\n---\n` (no blank line after,
  # matching `Valea.ICM.split_frontmatter/1`'s shape) and `body` is run
  # through the ProseMirror round-trip (from_markdown |> to_markdown) so it
  # is byte-identical to what the editor would produce for the same content
  # — one line per block, a blank line between blocks, no manual line-wrap,
  # no trailing newline. This keeps the determinism contract: opening and
  # saving an untouched generated page must write nothing.
  defp workflow_page(wf, name) do
    frontmatter =
      %{
        "enabled" => wf["enabled"] || false,
        "trigger" => wf["trigger"] || %{},
        "sources" => wf["sources"] || [],
        "risk_level" => wf["risk_level"] || "medium",
        "approval" => wf["approval"] || %{"required" => true},
        "audit" => wf["audit"] || %{}
      }

    frontmatter_block =
      "---\n" <> (frontmatter |> yaml_encode() |> String.trim_trailing()) <> "\n---\n"

    steps =
      (wf["steps"] || [])
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {step, i} ->
        "#{i}. #{String.trim(step["instruction"] || step["id"] || "")}"
      end)

    raw_body = """
    # #{name}

    #{String.trim(wf["description"] || "")}

    ## Inputs

    | Input | Where |
    | --- | --- |
    | Run input | named by the run |
    | Reference pages | listed under `sources` above |

    ## Process

    #{steps}

    ## Outputs

    One `proposal/v1` file at the exact path the run names. Do not send anything.
    """

    {:ok, pm} = ProseMirror.from_markdown(raw_body)
    {:ok, body} = ProseMirror.to_markdown(pm)

    frontmatter_block <> body
  end

  # Minimal YAML emitter for the known frontmatter shape (maps, lists,
  # scalars). yaml_elixir has no encoder; keep this private and dumb.
  # `sources` is the only key that nests a list at the top level, so it gets
  # block style; every other list (e.g. `approval.actions`) only ever
  # appears nested inside a flow map, so `yaml_value/1` emits lists in flow
  # style (`[a, b]`) to stay valid YAML there.
  defp yaml_encode(map) when is_map(map) do
    Enum.map_join(map, "\n", fn
      {"sources", v} when is_list(v) ->
        "sources:\n" <> Enum.map_join(v, "\n", fn item -> "  - #{yaml_value(item)}" end)

      {k, v} ->
        "#{k}: #{yaml_value(v)}"
    end)
  end

  defp yaml_value(v) when is_map(v) do
    inner = Enum.map_join(v, ", ", fn {k, val} -> "#{k}: #{yaml_value(val)}" end)
    "{ #{inner} }"
  end

  defp yaml_value(v) when is_list(v), do: "[" <> Enum.map_join(v, ", ", &yaml_value/1) <> "]"

  defp yaml_value(v) when is_binary(v) do
    if String.contains?(v, [":", "#", "*"]), do: ~s("#{v}"), else: v
  end

  defp yaml_value(v), do: to_string(v)

  defp ensure_gitignore_claude!(root) do
    path = Path.join(root, ".gitignore")
    current = if File.exists?(path), do: File.read!(path), else: ""

    unless String.contains?(current, ".claude/") do
      File.write!(path, current <> ".claude/\n")
    end
  end
end
