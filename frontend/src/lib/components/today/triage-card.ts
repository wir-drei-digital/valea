/**
 * Pure helpers for `InquiryTriageCard.svelte` (Task 18 generalized it from
 * one hardcoded Priya Nair instance to one card per mail review message,
 * all sharing the same `icm/Workflows/New Inquiry Triage.md` workflow) —
 * same "extract the logic, no component render harness" convention as
 * `components/mail/mail-shapes.ts`.
 */

/**
 * Defaults for the card's `{path, fromName, subject}` props — the seeded
 * Priya Nair message (`backend/priv/workspace_template/sources/mail/messages/
 * 2026-07-09-priya-nair-seed0001.md`), used verbatim when
 * `cockpit.mail.configured` is `false` (`routes/+page.svelte` renders
 * exactly one card, with no props, in that branch).
 */
export const SEED_TRIAGE_PATH = 'sources/mail/messages/2026-07-09-priya-nair-seed0001.md';
export const SEED_TRIAGE_FROM_NAME = 'Priya Nair';
export const SEED_TRIAGE_SUBJECT = 'Question about leadership coaching';

/**
 * A pending queue item's full envelope carries the workflow's input path
 * under `input` (`QueueItemEnvelope.input`, written by
 * `Valea.Workflows.Runner.write_pending!/4`) — the disambiguator that lets
 * ONE card among several (each running the SAME workflow against a
 * DIFFERENT message) recognize "this pending item is mine" after a reload,
 * when no locally-tracked `runId` from this card's own `prepareReply()`
 * call survives. Defensive against a malformed/missing value rather than
 * trusting the declared `QueueItemEnvelope` type blindly — this feeds a UI
 * decision, never crash on a shape drift.
 */
export function envelopeInputPath(raw: unknown): string | null {
  if (!raw || typeof raw !== 'object') return null;
  const value = (raw as Record<string, unknown>).input;
  return typeof value === 'string' ? value : null;
}

/**
 * The idle card's title/summary, built generically from the reviewed
 * message's from/subject — Task 18 replaced the single hand-authored
 * cockpit-seed copy ("Good-fit inquiry — she asked about leadership
 * coaching...") with this, since arbitrary review messages have no such
 * narrative to draw on. `title` reproduces the ORIGINAL seed title
 * verbatim for the default props ("Priya Nair · new inquiry").
 */
export function idleCopy(fromName: string, subject: string): { title: string; summary: string } {
  const title = `${fromName} · new inquiry`;
  const trimmedSubject = subject.trim();
  const summary = trimmedSubject
    ? `New inquiry: "${trimmedSubject}" — read it and prepare a reply.`
    : 'New inquiry — read it and prepare a reply.';
  return { title, summary };
}

/** Unchanged from the pre-Task-18 card — `api.runWorkflow`'s error vocabulary. */
export function runWorkflowErrorMessage(code: string): string {
  switch (code) {
    case 'harness_unavailable':
      return 'The assistant harness is not ready yet.';
    case 'workflow_disabled':
      return 'This workflow is turned off.';
    case 'input_not_found':
      return 'The inquiry email is missing.';
    case 'workspace_changed':
      return 'Your workspace changed. Reopen it and try again.';
    case 'workspace_not_open':
      return 'No workspace is open.';
    default:
      return 'Could not start the assistant. Please try again.';
  }
}
