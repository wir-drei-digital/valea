defmodule Valea.Skills.CatalogTest do
  use ExUnit.Case, async: true

  alias Valea.Skills.Catalog

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-skillcat-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    prev = Application.get_env(:valea, :skills_catalog_dir)
    Application.put_env(:valea, :skills_catalog_dir, dir)

    on_exit(fn ->
      File.rm_rf!(dir)

      if prev,
        do: Application.put_env(:valea, :skills_catalog_dir, prev),
        else: Application.delete_env(:valea, :skills_catalog_dir)
    end)

    %{dir: dir}
  end

  defp write_catalog!(dir, yaml), do: File.write!(Path.join(dir, "catalog.yaml"), yaml)

  test "the real priv catalog parses and its snapshot dirs exist" do
    Application.delete_env(:valea, :skills_catalog_dir)
    assert {:ok, skills} = Catalog.load()
    assert %{"icm-architect" => entry} = skills
    assert entry.name == "ICM Architect"
    assert entry.license == "MIT"
    assert entry.defect == nil
    assert File.exists?(Path.join(entry.snapshot_dir, "SKILL.md"))
  end

  test "an entry whose snapshot dir is missing is a defect, not a crash", %{dir: dir} do
    write_catalog!(dir, """
    version: 1
    skills:
      ghost:
        name: "Ghost"
        description: "d"
        source_url: "https://example.com"
        license: "MIT"
        pinned: "abc"
    """)

    assert {:ok, %{"ghost" => entry}} = Catalog.load()
    assert entry.defect == :snapshot_missing
  end

  test "unknown keys are ignored (forward compat)", %{dir: dir} do
    File.mkdir_p!(Path.join(dir, "x"))

    write_catalog!(dir, """
    version: 1
    future_top_level: true
    skills:
      x:
        name: "X"
        description: "d"
        source_url: "https://example.com"
        license: "MIT"
        pinned: "abc"
        future_key: 42
    """)

    assert {:ok, %{"x" => %{name: "X", defect: nil}}} = Catalog.load()
  end

  test "a missing or unparseable catalog file is an error, not a raise", %{dir: dir} do
    assert {:error, _} = Catalog.load()
    write_catalog!(dir, ": not yaml [")
    assert {:error, _} = Catalog.load()
  end

  test "an entry missing a required field is dropped with an error tuple", %{dir: dir} do
    write_catalog!(dir, """
    version: 1
    skills:
      bad:
        name: "No description"
    """)

    assert {:ok, skills} = Catalog.load()
    assert skills == %{}
  end
end
