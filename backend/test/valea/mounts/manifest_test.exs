defmodule Valea.Mounts.ManifestTest do
  use ExUnit.Case, async: true

  alias Valea.Mounts.Manifest

  setup do
    root = Path.join(System.tmp_dir!(), "vmount-#{System.os_time(:nanosecond)}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  defp write_yaml!(root, contents) do
    File.write!(Path.join(root, "icm.yaml"), contents)
  end

  describe "load/1 — missing" do
    test "no icm.yaml in the mount dir", %{root: root} do
      assert Manifest.load(root) == {:error, :missing}
    end
  end

  describe "load/1 — invalid" do
    test "unparseable YAML", %{root: root} do
      write_yaml!(root, "name: [unterminated")
      assert {:error, {:invalid, _reason}} = Manifest.load(root)
    end

    test "not a mapping (a bare scalar)", %{root: root} do
      write_yaml!(root, "just a string")
      assert {:error, {:invalid, _reason}} = Manifest.load(root)
    end

    test "blank name", %{root: root} do
      write_yaml!(root, """
      id: 3f6a8f1e-9c2b-4e2a-9d3a-9a6a4c0f6a11
      name: "   "
      description: "notes"
      """)

      assert {:error, {:invalid, reason}} = Manifest.load(root)
      assert reason =~ "name"
    end

    test "non-string name", %{root: root} do
      write_yaml!(root, """
      id: 3f6a8f1e-9c2b-4e2a-9d3a-9a6a4c0f6a11
      name: 12345
      """)

      assert {:error, {:invalid, reason}} = Manifest.load(root)
      assert reason =~ "name"
    end

    test "missing name key", %{root: root} do
      write_yaml!(root, """
      id: 3f6a8f1e-9c2b-4e2a-9d3a-9a6a4c0f6a11
      description: "notes"
      """)

      assert {:error, {:invalid, reason}} = Manifest.load(root)
      assert reason =~ "name"
    end

    test "missing id key", %{root: root} do
      write_yaml!(root, """
      name: "Coaching"
      """)

      assert {:error, {:invalid, _reason}} = Manifest.load(root)
    end

    test "blank id", %{root: root} do
      write_yaml!(root, """
      id: "   "
      name: "Coaching"
      """)

      assert {:error, {:invalid, _reason}} = Manifest.load(root)
    end

    test "non-uuid id", %{root: root} do
      write_yaml!(root, """
      id: not-a-uuid
      name: "Coaching"
      """)

      assert {:error, {:invalid, _reason}} = Manifest.load(root)
    end

    test "rejects a manifest with no id or a non-uuid id", %{root: root} do
      write_yaml!(root, "format: 2\nname: \"Coaching\"\n")
      assert {:error, {:invalid, _}} = Manifest.load(root)

      write_yaml!(root, "format: 2\nid: not-a-uuid\nname: \"Coaching\"\n")
      assert {:error, {:invalid, _}} = Manifest.load(root)
    end
  end

  describe "load/1 — success" do
    test "loads format 2 with a valid uuid id", %{root: root} do
      write_yaml!(root, """
      format: 2
      id: 6f9f0c9e-3ccd-4fa5-a219-113a70618b55
      name: "Coaching"
      description: "x"
      """)

      assert {:ok,
              %Manifest{format: 2, id: "6f9f0c9e-3ccd-4fa5-a219-113a70618b55", name: "Coaching"}} =
               Manifest.load(root)
    end

    test "full manifest parses into the struct, preserving an explicit format", %{root: root} do
      write_yaml!(root, """
      format: 1
      id: 3f6a8f1e-9c2b-4e2a-9d3a-9a6a4c0f6a11
      name: "Research Notes"
      description: "Personal research ICM"
      """)

      assert Manifest.load(root) ==
               {:ok,
                %Manifest{
                  format: 1,
                  id: "3f6a8f1e-9c2b-4e2a-9d3a-9a6a4c0f6a11",
                  name: "Research Notes",
                  description: "Personal research ICM"
                }}
    end

    test "format defaults to 2 when absent", %{root: root} do
      write_yaml!(root, """
      id: 3f6a8f1e-9c2b-4e2a-9d3a-9a6a4c0f6a11
      name: "Research Notes"
      """)

      assert {:ok, %Manifest{format: 2}} = Manifest.load(root)
    end

    test "description defaults to \"\" when absent", %{root: root} do
      write_yaml!(root, """
      id: 3f6a8f1e-9c2b-4e2a-9d3a-9a6a4c0f6a11
      name: "Research Notes"
      """)

      assert {:ok, %Manifest{description: ""}} = Manifest.load(root)
    end

    test "unknown keys are ignored", %{root: root} do
      write_yaml!(root, """
      format: 2
      id: 3f6a8f1e-9c2b-4e2a-9d3a-9a6a4c0f6a11
      name: "Research Notes"
      description: "Personal research ICM"
      color: "blue"
      pinned: true
      """)

      assert {:ok, manifest} = Manifest.load(root)
      assert manifest.name == "Research Notes"
      refute Map.has_key?(manifest, :color)
      refute Map.has_key?(manifest, :pinned)
    end
  end

  describe "render/1" do
    test "emits the four keys" do
      rendered =
        Manifest.render(%{
          id: "3f6a8f1e-9c2b-4e2a-9d3a-9a6a4c0f6a11",
          name: "Research Notes",
          description: "Personal research ICM"
        })

      assert rendered =~ "format: 2"
      assert rendered =~ ~s(id: "3f6a8f1e-9c2b-4e2a-9d3a-9a6a4c0f6a11")
      assert rendered =~ ~s(name: "Research Notes")
      assert rendered =~ ~s(description: "Personal research ICM")
    end

    test "escapes a name that would otherwise break the YAML structure" do
      rendered =
        Manifest.render(%{
          id: "3f6a8f1e-9c2b-4e2a-9d3a-9a6a4c0f6a11",
          name: ~s(evil"name\ncolor: blue),
          description: ""
        })

      # The embedded quote and newline must not let the value escape the
      # quoted scalar or inject a sibling "color:" key.
      refute rendered =~ ~r/\ncolor: blue/
      assert {:ok, doc} = YamlElixir.read_from_string(rendered)
      refute Map.has_key?(doc, "color")
    end
  end

  describe "write!/2" do
    test "round-trips through load/1", %{root: root} do
      attrs = %{
        id: "3f6a8f1e-9c2b-4e2a-9d3a-9a6a4c0f6a11",
        name: "Research Notes",
        description: "Personal research ICM"
      }

      assert :ok = Manifest.write!(root, attrs)

      assert Manifest.load(root) ==
               {:ok,
                %Manifest{
                  format: 2,
                  id: attrs.id,
                  name: attrs.name,
                  description: attrs.description
                }}
    end

    test "writes to <icm_root>/icm.yaml", %{root: root} do
      :ok =
        Manifest.write!(root, %{
          id: "3f6a8f1e-9c2b-4e2a-9d3a-9a6a4c0f6a11",
          name: "Research Notes",
          description: ""
        })

      assert File.exists?(Path.join(root, "icm.yaml"))
    end

    test "is atomic: no stray .tmp file left behind", %{root: root} do
      :ok =
        Manifest.write!(root, %{
          id: "3f6a8f1e-9c2b-4e2a-9d3a-9a6a4c0f6a11",
          name: "Research Notes",
          description: ""
        })

      refute File.exists?(Path.join(root, "icm.yaml.tmp"))
    end

    test "a name containing a raw newline is escaped, not left to break the file", %{root: root} do
      :ok =
        Manifest.write!(root, %{
          id: "3f6a8f1e-9c2b-4e2a-9d3a-9a6a4c0f6a11",
          name: ~s(evil"name\ncolor: blue),
          description: ""
        })

      assert {:ok, manifest} = Manifest.load(root)
      refute manifest.name =~ "\n"
      assert manifest.name == ~s(evil"name color: blue)
    end

    test "does not crash on invalid UTF-8 input; scrubs to U+FFFD and round-trips", %{root: root} do
      :ok =
        Manifest.write!(root, %{
          id: "3f6a8f1e-9c2b-4e2a-9d3a-9a6a4c0f6a11",
          name: "abc" <> <<0xFF, 0xFE>> <> "def",
          description: ""
        })

      assert {:ok, manifest} = Manifest.load(root)
      assert String.valid?(manifest.name)
      assert manifest.name == "abc��def"
    end
  end
end
