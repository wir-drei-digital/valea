/**
 * Pure helpers for the "Distill recent decisions" action (Task B13) —
 * `routes/+page.svelte`'s Today page and `routes/workflows/+page.svelte`'s
 * Distill Decisions card both drive the same reflection workflow
 * (`api.distillDecisions`, Task B8) through this one button-state helper,
 * same "extract the logic, no component render harness" convention as
 * `today/triage-card.ts`.
 *
 * Unlike the triage card, this action has no per-run reconciliation to do:
 * the queue items a distill run produces show up wherever queue items are
 * already rendered, via the existing `queue_changed` refetch — this module
 * only tracks the button's own idle/running/empty/error presentation.
 */

export type DistillPhase = 'idle' | 'running' | 'empty' | 'error';

export type DistillButtonState = {
  visible: boolean;
  label: string;
  disabled: boolean;
  note?: string;
};

/** Minimal shape this module needs off `CockpitToday` — avoids importing the whole cockpit type. */
export type DistillTodayLike = { distillWorkflowPath: string | null };

const IDLE_LABEL = 'Distill recent decisions';
const RUNNING_LABEL = 'Distilling…';
const EMPTY_NOTE = 'No decisions in the last 30 days yet.';
const DEFAULT_ERROR_NOTE = 'Could not start the assistant. Please try again.';

/**
 * Derives the button's visible/label/disabled/note from the cockpit
 * payload's `distillWorkflowPath` and the caller's local run phase.
 *
 * `distillWorkflowPath === null` (no enabled mount seeds a Distill
 * Decisions contract yet — expected until Task B9's starter-mount content
 * lands on a given workspace) hides the action entirely, same "no dead
 * link" convention `triageButtonState`-equivalent logic uses for the
 * triage card's `triageWorkflowPath`.
 *
 * `errorMessage` is only consulted for `phase === 'error'` — callers map
 * the RPC's error code to copy via `distillErrorMessage` below and pass
 * the result through here as the note. A `no_recent_decisions` error is
 * NOT an "error" phase — callers map it to `'empty'` instead, whose note
 * is the fixed calm copy above (not an error).
 */
export function distillButtonState(
  today: DistillTodayLike | null | undefined,
  phase: DistillPhase,
  errorMessage?: string
): DistillButtonState {
  if (!today?.distillWorkflowPath) {
    return { visible: false, label: IDLE_LABEL, disabled: true };
  }

  switch (phase) {
    case 'running':
      return { visible: true, label: RUNNING_LABEL, disabled: true };
    case 'empty':
      return { visible: true, label: IDLE_LABEL, disabled: false, note: EMPTY_NOTE };
    case 'error':
      return { visible: true, label: IDLE_LABEL, disabled: false, note: errorMessage || DEFAULT_ERROR_NOTE };
    case 'idle':
    default:
      return { visible: true, label: IDLE_LABEL, disabled: false };
  }
}

/**
 * Maps `api.distillDecisions`'s error vocabulary (`Valea.Api.Agents`'s
 * `distill_decisions` action — `workflow_not_found`, plus the same
 * generation/harness codes `run_workflow` shares) to calm copy. Mirrors
 * `triage-card.ts`'s `runWorkflowErrorMessage`. `no_recent_decisions` is
 * deliberately absent — callers route that code to the `'empty'` phase
 * instead of calling this function.
 */
export function distillErrorMessage(code: string): string {
  switch (code) {
    case 'workflow_not_found':
      return 'No Distill Decisions workflow is set up yet.';
    case 'harness_unavailable':
      return 'The assistant harness is not ready yet.';
    case 'workflow_disabled':
      return 'This workflow is turned off.';
    case 'workspace_changed':
      return 'Your workspace changed. Reopen it and try again.';
    case 'workspace_not_open':
      return 'No workspace is open.';
    default:
      return DEFAULT_ERROR_NOTE;
  }
}
