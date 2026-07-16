defmodule Valea.Agents.RiskTier do
  @moduledoc """
  Server-derived risk tier for a `Valea.Icm.Locator`: "high" for
  the ICM's instruction spine — `AGENTS.md`/`CLAUDE.md`/
  `CONTEXT.md` by basename at ANY depth (real ICMs route with nested
  CONTEXT.md files), plus the root `icm.yaml` identity file. Everything
  else in an ICM is "medium"; non-ICM locators carry no tier.

  Classification works DIRECTLY off the locator's own `path` — which is
  already relative to the ICM's root, by construction (`Locator.icm/2`,
  `Locator.for_path/2`) — never by re-attributing a workspace-relative or
  absolute physical path back to a mount via `Valea.Mounts.mount_for/2`.
  That attribution step is exactly what broke once an agent session's
  `cwd` became the ICM root itself (Task 5.4+): the agent's own
  self-reported paths (a memory-proposal `target_path`, a tool call's
  `rawInput.file_path`) are ICM-relative from the start, so re-deriving a
  workspace-relative form to feed `mount_for/2` could only ever miss —
  silently downgrading a behavior-changing edit to "medium". A locator
  sidesteps that entirely: whoever built it (`Runner.finalize_pair` from
  an already-resolved ICM identity, `SessionServer.enrich_item` via
  `Locator.for_path/2`) already did the one real attribution; this module
  just tiers the `path` it carries.
  """

  @behavior_basenames ["AGENTS.md", "CLAUDE.md", "CONTEXT.md"]

  @doc """
  "high" for the ICM's instruction spine — `AGENTS.md`/`CLAUDE.md`/
  `CONTEXT.md` by basename at ANY depth (real ICMs route with nested
  CONTEXT.md files), plus the root `icm.yaml` identity file. Everything
  else in an ICM is "medium"; non-ICM locators carry no tier.
  """
  @spec classify(map()) :: String.t() | nil
  def classify(%{"kind" => "icm", "path" => path}) when is_binary(path) do
    if Path.basename(path) in @behavior_basenames or path == "icm.yaml" do
      "high"
    else
      "medium"
    end
  end

  def classify(_locator), do: nil
end
