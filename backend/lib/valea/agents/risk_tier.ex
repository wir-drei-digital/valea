defmodule Valea.Agents.RiskTier do
  @moduledoc """
  Server-derived risk tier for a `Valea.Icm.Locator`: "high" for
  behavior-bearing files (the ICM's instruction spine and its workflow
  contracts — an approved edit changes future agent behavior), "medium"
  for everything else inside the same ICM, nil for a workspace locator
  (content that does not belong to any ICM at all). The tier is display +
  envelope metadata, never an access decision.

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

  @behavior_files ["AGENTS.md", "CLAUDE.md", "icm.yaml"]

  @doc """
  Classifies an ICM locator's `path` against the behavior-file allowlist
  and the `Workflows/` prefix. A workspace locator (or anything else that
  isn't a well-formed ICM locator) is nil — it never attributes to any
  ICM, so it carries no risk tier at all.
  """
  @spec classify(map()) :: String.t() | nil
  def classify(%{"kind" => "icm", "path" => path}) when is_binary(path) do
    if path in @behavior_files or String.starts_with?(path, "Workflows/") do
      "high"
    else
      "medium"
    end
  end

  def classify(_locator), do: nil
end
