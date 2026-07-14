defmodule Valea.Agents.RiskTierTest do
  use ExUnit.Case, async: false

  alias Valea.Agents.RiskTier
  alias Valea.AgentCase

  # Post-task-3.2, `Valea.Mounts.list/1` is config truth over `icms:` ONLY —
  # a freshly scaffolded workspace (`AgentCase.open_workspace!/1`) carries no
  # seeded mount, and every mount is EXTERNAL (`rel_root: nil`). This suite
  # mounts a REAL external ICM (`AgentCase.mount_test_icm!/2`) and classifies
  # paths against its `root` — the workspace-relative `"mounts/primary/..."`
  # literal `RiskTier.classify/2` used to accept for an embedded mount has no
  # meaning any more (see that module's moduledoc: "absolute path elsewhere
  # stays absolute — external-mount vocabulary").
  setup do
    ws = AgentCase.open_workspace!("Primary")
    icm = AgentCase.mount_test_icm!(ws.path, name: "Primary")
    %{workspace: ws.path, icm: icm}
  end

  test "knowledge page in a mount is medium", %{workspace: ws, icm: icm} do
    path = Path.join(icm.root, "Pricing/Current Pricing.md")
    assert RiskTier.classify(ws, path) == "medium"
  end

  test "behavior-bearing mount files are high", %{workspace: ws, icm: icm} do
    assert RiskTier.classify(ws, Path.join(icm.root, "Workflows/New Inquiry Triage.md")) ==
             "high"

    assert RiskTier.classify(ws, Path.join(icm.root, "AGENTS.md")) == "high"
    assert RiskTier.classify(ws, Path.join(icm.root, "CLAUDE.md")) == "high"
    assert RiskTier.classify(ws, Path.join(icm.root, "icm.yaml")) == "high"
  end

  test "shell paths are nil", %{workspace: ws} do
    assert RiskTier.classify(ws, "AGENTS.md") == nil
    assert RiskTier.classify(ws, "sources/mail/inbox.md") == nil
    assert RiskTier.classify(ws, "queue/pending/x.json") == nil
  end

  test "an absolute path into an external mount classifies", %{workspace: ws, icm: icm} do
    abs = Path.join(icm.root, "Workflows/New Inquiry Triage.md")
    assert RiskTier.classify(ws, abs) == "high"
  end

  test "non-binary and unattributable input is nil", %{workspace: ws} do
    assert RiskTier.classify(ws, nil) == nil
    assert RiskTier.classify(ws, "/somewhere/else/entirely.md") == nil
  end
end
