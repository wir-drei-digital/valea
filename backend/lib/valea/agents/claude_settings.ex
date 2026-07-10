defmodule Valea.Agents.ClaudeSettings do
  @moduledoc """
  Writes the MANAGED `.claude/settings.json` into a workspace. ACP agents
  only *may* ask permission — Claude Code auto-approves reads and anything
  its own rules allow before Valea's callback ever fires. This file forces
  writes/Bash to `ask` (so they reach the ACP permission request) and
  hard-denies the protected paths. Regenerated at every session start;
  the workspace gitignore excludes `.claude/`.
  """

  @protected ["secrets", "logs", ".claude", ".git"]
  @db_globs ["app.sqlite", "app.sqlite-wal", "app.sqlite-shm"]

  def content do
    deny =
      Enum.flat_map(@protected, fn dir ->
        ["Read(./#{dir}/**)", "Edit(./#{dir}/**)", "Write(./#{dir}/**)"]
      end) ++
        Enum.flat_map(@db_globs, fn f -> ["Read(./#{f})", "Edit(./#{f})", "Write(./#{f})"] end) ++
        ["WebFetch", "WebSearch"]

    %{
      "permissions" => %{
        "deny" => deny,
        "ask" => ["Write", "Edit", "Bash"],
        "allow" => ["Read"]
      }
    }
  end

  def write!(workspace_root) do
    dir = Path.join(workspace_root, ".claude")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "settings.json"), Jason.encode!(content(), pretty: true) <> "\n")
    :ok
  end
end
