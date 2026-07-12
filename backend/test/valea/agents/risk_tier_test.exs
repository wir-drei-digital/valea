defmodule Valea.Agents.RiskTierTest do
  use ExUnit.Case, async: false

  alias Valea.Agents.RiskTier
  alias Valea.Workspace.Manager

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-app-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    System.put_env("VALEA_APP_DIR", dir)
    Manager.close()
    {:ok, ws} = Manager.create(Path.join(dir, "workspaces"), "Primary")

    on_exit(fn ->
      Manager.close()
      File.rm_rf!(dir)
      System.delete_env("VALEA_APP_DIR")
    end)

    %{workspace: ws.path}
  end

  test "knowledge page in a mount is medium", %{workspace: ws} do
    assert RiskTier.classify(ws, "mounts/primary/Pricing/Current Pricing.md") == "medium"
  end

  test "behavior-bearing mount files are high", %{workspace: ws} do
    assert RiskTier.classify(ws, "mounts/primary/Workflows/New Inquiry Triage.md") == "high"
    assert RiskTier.classify(ws, "mounts/primary/AGENTS.md") == "high"
    assert RiskTier.classify(ws, "mounts/primary/CLAUDE.md") == "high"
    assert RiskTier.classify(ws, "mounts/primary/icm.yaml") == "high"
  end

  test "shell paths are nil", %{workspace: ws} do
    assert RiskTier.classify(ws, "AGENTS.md") == nil
    assert RiskTier.classify(ws, "sources/mail/inbox.md") == nil
    assert RiskTier.classify(ws, "queue/pending/x.json") == nil
  end

  test "absolute path into an embedded mount classifies", %{workspace: ws} do
    abs = Path.join(ws, "mounts/primary/Workflows/New Inquiry Triage.md")
    assert RiskTier.classify(ws, abs) == "high"
  end

  test "non-binary and unattributable input is nil", %{workspace: ws} do
    assert RiskTier.classify(ws, nil) == nil
    assert RiskTier.classify(ws, "/somewhere/else/entirely.md") == nil
  end
end
