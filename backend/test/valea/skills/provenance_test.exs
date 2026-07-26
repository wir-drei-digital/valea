defmodule Valea.Skills.ProvenanceTest do
  use ExUnit.Case, async: true

  alias Valea.Skills.Provenance

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-skillprov-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp seed!(dir) do
    File.write!(Path.join(dir, "SKILL.md"), "---\nname: x\n---\nbody\n")
    File.mkdir_p!(Path.join(dir, "references"))
    File.write!(Path.join(dir, "references/core.md"), "core\n")
  end

  test "hash_tree hashes every file recursively, excluding the sidecar", %{dir: dir} do
    seed!(dir)
    File.write!(Path.join(dir, ".provenance.yaml"), "{}")

    assert {:ok, manifest} = Provenance.hash_tree(dir)
    assert Map.keys(manifest) |> Enum.sort() == ["SKILL.md", "references/core.md"]

    expected = :crypto.hash(:sha256, "core\n") |> Base.encode16(case: :lower)
    assert manifest["references/core.md"] == expected
  end

  test "hash_tree refuses a symlink inside the tree", %{dir: dir} do
    seed!(dir)
    File.ln_s!("/etc/hosts", Path.join(dir, "link.md"))
    assert {:error, {:symlink, "link.md"}} = Provenance.hash_tree(dir)
  end

  test "write!/read round-trip", %{dir: dir} do
    seed!(dir)

    :ok =
      Provenance.write!(dir, %{
        skill: "icm-architect",
        version: "abc123",
        source_url: "https://github.com/RinDig/icm-architect"
      })

    assert {:ok, prov} = Provenance.read(dir)
    assert prov.skill == "icm-architect"
    assert prov.version == "abc123"
    assert prov.files["SKILL.md"]
    refute Map.has_key?(prov.files, ".provenance.yaml")
  end

  test "the written sidecar is valid YAML (JSON subset) and carries format: 1", %{dir: dir} do
    seed!(dir)
    :ok = Provenance.write!(dir, %{skill: "s", version: "v", source_url: "u"})

    assert {:ok, doc} = YamlElixir.read_from_file(Path.join(dir, ".provenance.yaml"))
    assert doc["format"] == 1
    assert doc["installed_by"] == "valea"
  end

  test "read on a missing or unparseable sidecar is :error", %{dir: dir} do
    assert :error = Provenance.read(dir)
    File.write!(Path.join(dir, ".provenance.yaml"), ": [")
    assert :error = Provenance.read(dir)
  end
end
