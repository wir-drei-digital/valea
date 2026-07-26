defmodule Valea.SkillsTest do
  use ExUnit.Case, async: true

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
