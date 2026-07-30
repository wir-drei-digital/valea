defmodule Valea.Agents.RiskTier do
  @moduledoc """
  Server-derived risk tier for a `Valea.Icm.Locator`: "high" for
  the ICM's instruction spine — `AGENTS.md`/`CLAUDE.md`/
  `CONTEXT.md` by basename at ANY depth (real ICMs route with nested
  CONTEXT.md files), plus the root `icm.yaml` identity file, plus anything
  under a `.claude/` directory at any depth (skills and harness config
  change future agent behavior — ICM skills design spec, §Risk tier), plus
  the ROOT `schedules.json` (registering a schedule grants future unattended
  execution) and anything under a `.valea/` directory at any depth (Valea's
  materialized briefing — an instruction surface — and its task archive) —
  tasks/schedules spec §"Consent & containment posture". `tasks.json` stays
  "medium": the ledger is exactly what agents are asked to maintain.
  Everything else in an ICM is "medium"; non-ICM locators carry no tier.

  Classification works DIRECTLY off the locator's own `path` — which is
  already relative to the ICM's root, by construction (`Locator.icm/2`,
  `Locator.for_path/2`) — never by re-attributing a workspace-relative or
  absolute physical path back to a mount via `Valea.Mounts.mount_for/2`.
  That attribution step is exactly what broke once an agent session's
  `cwd` became the ICM root itself (Task 5.4+): the agent's own
  self-reported paths (a tool call's `rawInput.file_path`) are
  ICM-relative from the start, so re-deriving a workspace-relative form to
  feed `mount_for/2` could only ever miss — silently downgrading a
  behavior-changing edit to "medium". A locator sidesteps that entirely:
  whoever built it (`SessionServer.enrich_item` via `Locator.for_path/2`,
  from an already-resolved ICM identity) already did the one real
  attribution; this module just tiers the `path` it carries.

  The tier is display + envelope metadata, never an access decision — it
  labels a permission ask for the human deciding on it, but nothing in the
  approve/deny path reads or gates on it.
  """

  @behavior_basenames ["AGENTS.md", "CLAUDE.md", "CONTEXT.md"]

  @doc """
  "high" for the ICM's instruction spine — `AGENTS.md`/`CLAUDE.md`/
  `CONTEXT.md` by basename at ANY depth (real ICMs route with nested
  CONTEXT.md files), plus the root `icm.yaml` identity file, plus anything
  under a `.claude/` directory at any depth (skills and harness config
  change future agent behavior — ICM skills design spec, §Risk tier), plus
  the root `schedules.json` and anything under a `.valea/` directory at any
  depth (tasks/schedules spec §"Consent & containment posture").
  Everything else in an ICM is "medium"; non-ICM locators carry no tier.
  """
  @spec classify(map()) :: String.t() | nil
  def classify(%{"kind" => "icm", "path" => path}) when is_binary(path) do
    segments = Path.split(path)

    if Path.basename(path) in @behavior_basenames or path == "icm.yaml" or
         ".claude" in segments or ".valea" in segments or root_schedules?(segments) do
      "high"
    else
      "medium"
    end
  end

  def classify(_locator), do: nil

  # Locator paths are ICM-RELATIVE by construction, so the registry file at
  # the ICM root is exactly one segment — a basename test alone would also
  # stamp a nested `clients/kita/schedules.json`, which the spec keeps
  # ordinary ("at an enabled ICM root", matching PermissionPolicy's
  # root-exact ask tier). `tasks.json` is deliberately absent: the ledger is
  # what agents are asked to maintain.
  defp root_schedules?([only]), do: String.downcase(only) == "schedules.json"
  defp root_schedules?(_segments), do: false
end
