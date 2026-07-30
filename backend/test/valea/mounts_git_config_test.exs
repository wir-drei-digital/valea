defmodule Valea.MountsGitConfigTest do
  # async: false — `Valea.AgentCase.open_workspace!/1` mutates the global
  # VALEA_APP_DIR and opens the process-global workspace Manager.
  use ExUnit.Case, async: false

  alias Valea.AgentCase
  alias Valea.Mounts

  setup do
    ws = AgentCase.open_workspace!()
    mount = AgentCase.mount_test_icm!(ws.path, name: "Repo")
    %{ws: ws.path, mount: mount}
  end

  describe "git_config/2" do
    test "defaults to pull when the block is absent", %{ws: ws, mount: m} do
      assert %{sync: :pull, instructions: nil} = Mounts.git_config(ws, m.mount_key)
    end

    test "parses sync + instructions; a malformed sync degrades to pull", %{ws: ws, mount: m} do
      put_git_block!(
        ws,
        m.mount_key,
        ~s(    git:\n      sync: "yolo"\n      instructions: |\n        Merge, never rebase.\n)
      )

      assert %{sync: :pull, instructions: "Merge, never rebase."} =
               Mounts.git_config(ws, m.mount_key)
    end

    # Round-trips through the real writer rather than `put_git_block!/3`,
    # which only ever APPENDS (a second hand-written `git:` key would be a
    # duplicate YAML key, and the parser keeps the first).
    test "reads every valid mode back out", %{ws: ws, mount: m} do
      for mode <- ~w(full pull off) do
        assert :ok = Mounts.set_git_sync(ws, m.mount_key, mode)
        assert %{sync: parsed} = Mounts.git_config(ws, m.mount_key)
        assert Atom.to_string(parsed) == mode
      end
    end

    test "a non-map git: value degrades to the default rather than raising", %{ws: ws, mount: m} do
      put_git_block!(ws, m.mount_key, ~s(    git: "off"\n))
      assert %{sync: :pull, instructions: nil} = Mounts.git_config(ws, m.mount_key)
    end

    test "a blank or non-string instructions value reads as nil", %{ws: ws, mount: m} do
      put_git_block!(ws, m.mount_key, ~s(    git:\n      instructions: "   "\n))
      assert %{instructions: nil} = Mounts.git_config(ws, m.mount_key)

      put_git_block!(ws, m.mount_key, ~s(    git:\n      instructions: 7\n))
      assert %{instructions: nil} = Mounts.git_config(ws, m.mount_key)
    end

    test "an unknown mount reads as the default", %{ws: ws} do
      assert %{sync: :pull, instructions: nil} = Mounts.git_config(ws, "no-such-mount")
    end
  end

  describe "set_git_sync/3" do
    test "validates mode and mount", %{ws: ws, mount: m} do
      assert {:error, :invalid_git_sync} = Mounts.set_git_sync(ws, m.mount_key, "yolo")
      assert {:error, _} = Mounts.set_git_sync(ws, "no-such-mount", "pull")
      assert {:error, :invalid_mount_name} = Mounts.set_git_sync(ws, "../escape", "pull")
    end

    test "preserves instructions and every other entry key", %{ws: ws, mount: m} do
      put_git_block!(ws, m.mount_key, ~s(    git:\n      instructions: "keep both"\n))

      assert :ok = Mounts.set_git_sync(ws, m.mount_key, "off")
      assert %{sync: :off, instructions: "keep both"} = Mounts.git_config(ws, m.mount_key)

      mount = Enum.find(Mounts.list(ws), &(&1.name == m.mount_key))
      assert mount.enabled and mount.degraded == nil
      assert mount.root == m.root
    end

    test "writes the block when no git: key exists yet", %{ws: ws, mount: m} do
      assert :ok = Mounts.set_git_sync(ws, m.mount_key, "full")
      assert %{sync: :full, instructions: nil} = Mounts.git_config(ws, m.mount_key)
    end

    test "multiline instructions survive a config rewrite (block scalar)", %{ws: ws, mount: m} do
      put_git_block!(
        ws,
        m.mount_key,
        ~s(    git:\n      instructions: |\n        Never rebase.\n        Merge and keep both versions.\n)
      )

      assert :ok = Mounts.set_git_sync(ws, m.mount_key, "full")

      raw = File.read!(Path.join(ws, "config/workspace.yaml"))
      assert raw =~ "instructions: |"
      assert raw =~ "Never rebase."
      assert raw =~ "Merge and keep both versions."

      assert %{sync: :full, instructions: "Never rebase.\nMerge and keep both versions."} =
               Mounts.git_config(ws, m.mount_key)

      # And again — a second rewrite must not re-flatten or re-indent it.
      assert :ok = Mounts.set_git_sync(ws, m.mount_key, "pull")

      assert %{sync: :pull, instructions: "Never rebase.\nMerge and keep both versions."} =
               Mounts.git_config(ws, m.mount_key)
    end

    # A bare `|` makes the parser DETECT the block's indentation from the
    # first non-empty line, so a value whose own lines start with spaces
    # either loses them or (first line deepest) makes the whole document
    # unparseable — which `read_workspace_config/1` degrades to `%{}`,
    # i.e. every mount would vanish from `list/1`. The renderer emits an
    # explicit indicator for exactly this shape.
    test "indented instruction lines survive a rewrite without corrupting the config", %{
      ws: ws,
      mount: m
    } do
      indented = "  keep both versions\nRules:\n  - never rebase"
      body = indented |> String.split("\n") |> Enum.map_join("\n", &("        " <> &1))

      # Seeded with an explicit indicator so the FIXTURE itself parses; the
      # assertion below is about what the RENDERER writes back.
      put_git_block!(ws, m.mount_key, "    git:\n      instructions: |2\n" <> body <> "\n")

      assert :ok = Mounts.set_git_sync(ws, m.mount_key, "full")

      # The config still parses at all — the mount is still listed.
      assert Enum.any?(Mounts.list(ws), &(&1.name == m.mount_key))

      assert %{sync: :full, instructions: ^indented} = Mounts.git_config(ws, m.mount_key)
    end

    test "a single-line instructions value stays a quoted scalar", %{ws: ws, mount: m} do
      put_git_block!(ws, m.mount_key, ~s(    git:\n      instructions: "one liner"\n))
      assert :ok = Mounts.set_git_sync(ws, m.mount_key, "full")

      raw = File.read!(Path.join(ws, "config/workspace.yaml"))
      assert raw =~ ~s(instructions: "one liner")
      refute raw =~ "instructions: |"
    end

    test "preserves top-level keys the workspace config carries", %{ws: ws, mount: m} do
      before = YamlElixir.read_from_file!(Path.join(ws, "config/workspace.yaml"))
      assert :ok = Mounts.set_git_sync(ws, m.mount_key, "off")
      now = YamlElixir.read_from_file!(Path.join(ws, "config/workspace.yaml"))

      for key <- Map.keys(before) -- ["icms"] do
        assert Map.fetch!(now, key) == Map.fetch!(before, key)
      end
    end
  end

  # Appends yaml lines under the mount's `icms:` entry by rewriting the file:
  # find the "  <mount_key>:" line, drop past the entry's existing keys (the
  # two-space-deeper lines that follow it), splice the block in. Mirrors the
  # file shape `Valea.Mounts`'s own renderer writes.
  defp put_git_block!(ws, mount_key, yaml_block) do
    path = Path.join(ws, "config/workspace.yaml")
    lines = path |> File.read!() |> String.split("\n")
    idx = Enum.find_index(lines, &(&1 == "  #{mount_key}:"))
    refute is_nil(idx), "no `  #{mount_key}:` line in #{path}"

    rest = Enum.drop(lines, idx + 1)
    entry_len = Enum.count(Enum.take_while(rest, &String.starts_with?(&1, "    ")))
    {head, tail} = Enum.split(lines, idx + 1 + entry_len)

    File.write!(path, Enum.join(head ++ [String.trim_trailing(yaml_block, "\n")] ++ tail, "\n"))
  end
end
