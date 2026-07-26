defmodule Valea.SkillsTest do
  # async: false — the install/update/uninstall describe mounts a real
  # workspace via Valea.AgentCase, which mutates the global VALEA_APP_DIR.
  use ExUnit.Case, async: false

  alias Valea.Skills
  alias Valea.Skills.Provenance

  @entry %{
    id: "icm-architect",
    name: "ICM Architect",
    description: "d",
    source_url: "https://github.com/RinDig/icm-architect",
    license: "MIT",
    pinned: "sha-new",
    snapshot_dir: "unused-in-state-tests",
    defect: nil
  }

  describe "state/2" do
    setup do
      dir =
        Path.join(
          System.tmp_dir!(),
          "valea-skills-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
        )

      icm = Path.join(dir, "icm")
      File.mkdir_p!(icm)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{icm: icm}
    end

    defp install!(icm, version) do
      skill_dir = Path.join([icm, ".claude", "skills", "icm-architect"])
      File.mkdir_p!(skill_dir)
      File.write!(Path.join(skill_dir, "SKILL.md"), "---\nname: x\n---\n")

      :ok =
        Provenance.write!(skill_dir, %{
          skill: "icm-architect",
          version: version,
          source_url: @entry.source_url
        })

      skill_dir
    end

    test "no skill dir -> not_installed", %{icm: icm} do
      assert {:not_installed, %{installed_version: nil}} = Skills.state(@entry, icm)
    end

    test "dir present without a parseable sidecar -> foreign", %{icm: icm} do
      skill_dir = Path.join([icm, ".claude", "skills", "icm-architect"])
      File.mkdir_p!(skill_dir)
      File.write!(Path.join(skill_dir, "SKILL.md"), "someone else's\n")

      assert {:foreign, _meta} = Skills.state(@entry, icm)
    end

    test "hashes match + version matches -> installed", %{icm: icm} do
      install!(icm, "sha-new")
      assert {:installed, %{installed_version: "sha-new"}} = Skills.state(@entry, icm)
    end

    test "hashes match + older version -> update_available", %{icm: icm} do
      install!(icm, "sha-old")
      assert {:update_available, %{installed_version: "sha-old"}} = Skills.state(@entry, icm)
    end

    test "edited beats update_available: hash mismatch at an old version -> edited", %{icm: icm} do
      skill_dir = install!(icm, "sha-old")
      File.write!(Path.join(skill_dir, "SKILL.md"), "---\nname: x\n---\nuser edit\n")

      assert {:edited, %{installed_version: "sha-old"}} = Skills.state(@entry, icm)
    end

    test "edited at the current version -> edited", %{icm: icm} do
      skill_dir = install!(icm, "sha-new")
      File.write!(Path.join(skill_dir, "SKILL.md"), "edited\n")

      assert {:edited, _meta} = Skills.state(@entry, icm)
    end

    test "a file added by the user (not in manifest) -> edited", %{icm: icm} do
      skill_dir = install!(icm, "sha-new")
      File.write!(Path.join(skill_dir, "extra.md"), "new\n")

      assert {:edited, _meta} = Skills.state(@entry, icm)
    end

    test "a symlink planted inside the skill dir -> foreign (never hashed)", %{icm: icm} do
      skill_dir = install!(icm, "sha-new")
      File.ln_s!("/etc/hosts", Path.join(skill_dir, "link.md"))

      assert {:foreign, _meta} = Skills.state(@entry, icm)
    end
  end

  # -- install/update/uninstall ---------------------------------------------
  # These use a real workspace + mounted ICM (Valea.AgentCase) because the
  # ops resolve mounts by key and enforce containment against the real
  # filesystem. The module therefore becomes async: false.

  describe "install/update/uninstall" do
    setup do
      ws = Valea.AgentCase.open_workspace!("W")

      icm_path =
        Path.join(System.tmp_dir!(), "valea-skills-icm-#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf!(icm_path) end)

      {:ok, %{mount_key: mount_key}} = Valea.Mounts.create(ws.path, "Coaching", icm_path)

      # A fake vendored catalog so tests don't depend on the real snapshot.
      cat_dir =
        Path.join(System.tmp_dir!(), "valea-skills-cat-#{System.unique_integer([:positive])}")

      snap = Path.join(cat_dir, "icm-architect")
      File.mkdir_p!(Path.join(snap, "references"))
      File.write!(Path.join(snap, "SKILL.md"), "---\nname: icm-architect\n---\nv2\n")
      File.write!(Path.join(snap, "references/core.md"), "core v2\n")

      File.write!(Path.join(cat_dir, "catalog.yaml"), """
      version: 1
      skills:
        icm-architect:
          name: "ICM Architect"
          description: "d"
          source_url: "https://github.com/RinDig/icm-architect"
          license: "MIT"
          pinned: "sha-v2"
      """)

      prev = Application.get_env(:valea, :skills_catalog_dir)
      Application.put_env(:valea, :skills_catalog_dir, cat_dir)

      on_exit(fn ->
        File.rm_rf!(cat_dir)

        if prev,
          do: Application.put_env(:valea, :skills_catalog_dir, prev),
          else: Application.delete_env(:valea, :skills_catalog_dir)
      end)

      %{ws: ws.path, mount_key: mount_key, icm: icm_path}
    end

    test "install copies the snapshot, writes provenance, state becomes installed",
         %{ws: ws, mount_key: key, icm: icm} do
      assert :ok = Skills.install(ws, key, "icm-architect")

      dir = Path.join([icm, ".claude", "skills", "icm-architect"])
      assert File.read!(Path.join(dir, "SKILL.md")) =~ "v2"
      assert {:ok, prov} = Provenance.read(dir)
      assert prov.version == "sha-v2"

      assert {:ok, [row]} = Skills.list(ws, key)
      assert row.state == "installed"
    end

    test "install refuses when already installed, foreign, or unknown",
         %{ws: ws, mount_key: key, icm: icm} do
      :ok = Skills.install(ws, key, "icm-architect")
      assert {:error, :already_installed} = Skills.install(ws, key, "icm-architect")

      foreign = Path.join([icm, ".claude", "skills", "hand-rolled"])
      File.mkdir_p!(foreign)
      assert {:error, :unknown_skill} = Skills.install(ws, key, "hand-rolled")
      assert {:error, :unknown_skill} = Skills.install(ws, key, "nope")
    end

    test "install refuses on unknown/disabled mount", %{ws: ws, mount_key: key} do
      assert {:error, :icm_unavailable} = Skills.install(ws, "ghost", "icm-architect")
      :ok = Valea.Mounts.set_enabled(ws, key, false)
      assert {:error, :icm_unavailable} = Skills.install(ws, key, "icm-architect")
    end

    test "no partial skill dir is ever left at the live path (staged write)",
         %{ws: ws, mount_key: key, icm: icm} do
      :ok = Skills.install(ws, key, "icm-architect")
      skills_root = Path.join([icm, ".claude", "skills"])
      entries = File.ls!(skills_root)
      assert entries == ["icm-architect"], "stray staging entries: #{inspect(entries)}"
    end

    test "update on an unedited old install replaces content and version",
         %{ws: ws, mount_key: key, icm: icm} do
      :ok = Skills.install(ws, key, "icm-architect")
      dir = Path.join([icm, ".claude", "skills", "icm-architect"])
      # Simulate an old install: rewrite provenance at an older version.
      :ok =
        Provenance.write!(dir, %{skill: "icm-architect", version: "sha-v1", source_url: "u"})

      assert {:ok, [%{state: "update_available"}]} = Skills.list(ws, key)
      assert :ok = Skills.update(ws, key, "icm-architect")
      assert {:ok, [%{state: "installed", installed_version: "sha-v2"}]} = Skills.list(ws, key)
    end

    test "update refuses an edited install without force, replaces with force",
         %{ws: ws, mount_key: key, icm: icm} do
      :ok = Skills.install(ws, key, "icm-architect")
      dir = Path.join([icm, ".claude", "skills", "icm-architect"])
      File.write!(Path.join(dir, "SKILL.md"), "my edits\n")

      assert {:error, :edited} = Skills.update(ws, key, "icm-architect")
      assert :ok = Skills.update(ws, key, "icm-architect", force: true)
      assert File.read!(Path.join(dir, "SKILL.md")) =~ "v2"
    end

    test "update on a current install is up_to_date; on nothing, not_installed",
         %{ws: ws, mount_key: key} do
      assert {:error, :not_installed} = Skills.update(ws, key, "icm-architect")
      :ok = Skills.install(ws, key, "icm-architect")
      assert {:error, :up_to_date} = Skills.update(ws, key, "icm-architect")
    end

    test "uninstall removes the dir; refuses foreign and not_installed",
         %{ws: ws, mount_key: key, icm: icm} do
      assert {:error, :not_installed} = Skills.uninstall(ws, key, "icm-architect")

      :ok = Skills.install(ws, key, "icm-architect")
      assert :ok = Skills.uninstall(ws, key, "icm-architect")
      refute File.dir?(Path.join([icm, ".claude", "skills", "icm-architect"]))

      foreign = Path.join([icm, ".claude", "skills", "icm-architect"])
      File.mkdir_p!(foreign)
      File.write!(Path.join(foreign, "SKILL.md"), "hand-rolled\n")
      assert {:error, :foreign} = Skills.uninstall(ws, key, "icm-architect")
    end

    test "containment: a symlinked .claude escaping the root refuses every op",
         %{ws: ws, mount_key: key, icm: icm} do
      outside =
        Path.join(System.tmp_dir!(), "valea-skills-outside-#{System.unique_integer([:positive])}")

      File.mkdir_p!(outside)
      on_exit(fn -> File.rm_rf!(outside) end)
      File.ln_s!(outside, Path.join(icm, ".claude"))

      assert {:error, :containment} = Skills.install(ws, key, "icm-architect")
      assert {:error, :containment} = Skills.uninstall(ws, key, "icm-architect")
      assert File.ls!(outside) == []
    end

    test "list includes foreign on-disk dirs not in the catalog",
         %{ws: ws, mount_key: key, icm: icm} do
      foreign = Path.join([icm, ".claude", "skills", "hand-rolled"])
      File.mkdir_p!(foreign)

      assert {:ok, rows} = Skills.list(ws, key)
      assert Enum.any?(rows, &(&1.skill_id == "hand-rolled" and &1.state == "foreign"))
    end
  end
end
