defmodule Valea.Agents.RiskTierTest do
  use ExUnit.Case, async: true

  alias Valea.Agents.RiskTier
  alias Valea.Icm.Locator

  @icm_id "11111111-1111-4111-8111-111111111111"

  test "instruction-spine basenames are high at any depth" do
    for path <- [
          "AGENTS.md",
          "CLAUDE.md",
          "CONTEXT.md",
          "clients/CONTEXT.md",
          "a/b/c/AGENTS.md",
          "deep/CLAUDE.md"
        ] do
      assert RiskTier.classify(Locator.icm(@icm_id, path)) == "high", path
    end
  end

  test "root icm.yaml is high; a nested icm.yaml is not special" do
    assert RiskTier.classify(Locator.icm(@icm_id, "icm.yaml")) == "high"
    assert RiskTier.classify(Locator.icm(@icm_id, "vendor/icm.yaml")) == "medium"
  end

  test "the deleted Workflows/ prefix rule no longer applies" do
    assert RiskTier.classify(Locator.icm(@icm_id, "Workflows/anything.md")) == "medium"
    assert RiskTier.classify(Locator.icm(@icm_id, "notWorkflows/x.md")) == "medium"
  end

  test "ordinary pages are medium" do
    assert RiskTier.classify(Locator.icm(@icm_id, "clients/kita/prep.md")) == "medium"
  end

  test "workspace locators and malformed input are nil" do
    assert RiskTier.classify(Locator.workspace("sources/mail/mara/views/messages/x.md")) == nil
    assert RiskTier.classify(%{}) == nil
    assert RiskTier.classify(nil) == nil
  end
end
