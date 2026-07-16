defmodule Valea.Agents.RiskTierTest do
  use ExUnit.Case, async: true

  alias Valea.Agents.RiskTier
  alias Valea.Icm.Locator

  # Task 7.5: `classify/1` takes a `Valea.Icm.Locator` directly and tiers
  # its `path` — no workspace, no `Valea.Mounts.mount_for/2` attribution.
  # A bare, unmounted icm_id is fine here: classification never resolves
  # the locator against a live mount table (that's `Locator.resolve/2`'s
  # job), it only reads the `path` the locator already carries.
  @icm_id "11111111-1111-1111-1111-111111111111"

  test "behavior-bearing files in an ICM are high" do
    assert RiskTier.classify(Locator.icm(@icm_id, "AGENTS.md")) == "high"
    assert RiskTier.classify(Locator.icm(@icm_id, "CLAUDE.md")) == "high"
    assert RiskTier.classify(Locator.icm(@icm_id, "icm.yaml")) == "high"
  end

  test "workflow contracts in an ICM are high" do
    assert RiskTier.classify(Locator.icm(@icm_id, "Workflows/contract.md")) == "high"
  end

  test "an ordinary knowledge page in an ICM is medium" do
    assert RiskTier.classify(Locator.icm(@icm_id, "Pricing/x.md")) == "medium"
  end

  test "a workspace locator is nil, even for a behavior-file-shaped path" do
    assert RiskTier.classify(Locator.workspace("sources/mail/1.md")) == nil
    assert RiskTier.classify(Locator.workspace("AGENTS.md")) == nil
  end

  test "malformed input is nil" do
    assert RiskTier.classify(%{}) == nil
    assert RiskTier.classify(nil) == nil
  end
end
