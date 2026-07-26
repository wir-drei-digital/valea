defmodule Valea.Mail.AgentsFileTest do
  use ExUnit.Case, async: true

  alias Valea.Mail.AgentsFile

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-agentsfile-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    root = Path.join(dir, "workspace")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{root: root}
  end

  defp agents_path(root, slug), do: Path.join([root, "sources", "mail", slug, "AGENTS.md"])
  defp claude_path(root, slug), do: Path.join([root, "sources", "mail", slug, "CLAUDE.md"])

  describe "materialize!/2" do
    test "writes AGENTS.md from the template with {{account}} substituted", %{root: root} do
      assert :ok = AgentsFile.materialize!(root, "mara")

      content = File.read!(agents_path(root, "mara"))
      assert content =~ "Mail account `mara`"
      assert content =~ ~s(account: "mara")
      refute content =~ "{{account}}"
    end

    test "CLAUDE.md is a relative symlink to AGENTS.md", %{root: root} do
      :ok = AgentsFile.materialize!(root, "mara")

      assert File.read_link(claude_path(root, "mara")) == {:ok, "AGENTS.md"}
    end

    test "idempotent: a second call leaves both files' mtimes untouched", %{root: root} do
      :ok = AgentsFile.materialize!(root, "mara")

      agents = agents_path(root, "mara")
      old = 1_577_836_800
      File.touch!(agents, old)

      :ok = AgentsFile.materialize!(root, "mara")

      assert File.stat!(agents, time: :posix).mtime == old
    end

    test "stale content (an older app's render) is overwritten", %{root: root} do
      agents = agents_path(root, "mara")
      File.mkdir_p!(Path.dirname(agents))
      File.write!(agents, "# old template\n")

      :ok = AgentsFile.materialize!(root, "mara")

      assert File.read!(agents) =~ "Mail account `mara`"
    end

    test "replaces a symlinked AGENTS.md instead of writing through it", %{root: root} do
      agents = agents_path(root, "mara")
      File.mkdir_p!(Path.dirname(agents))
      target = Path.join(Path.dirname(agents), "elsewhere.md")
      File.write!(target, "untouched")
      File.ln_s!("elsewhere.md", agents)

      :ok = AgentsFile.materialize!(root, "mara")

      assert File.read_link(agents) == {:error, :einval}
      assert File.read!(agents) =~ "Mail account `mara`"
      assert File.read!(target) == "untouched"
    end
  end
end
