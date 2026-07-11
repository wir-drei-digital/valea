/**
 * Pure helpers for `InquiryTriageCard.svelte` (Task 18 generalized it from
 * one hardcoded Priya Nair instance to one card per mail review message,
 * all sharing the same `icm/Workflows/New Inquiry Triage.md` workflow) —
 * same "extract the logic, no component render harness" convention as
 * `components/mail/mail-shapes.ts`.
 */

/**
 * Defaults for the card's `{path, fromName, summary, sources}` props — the
 * seeded Priya Nair message (`backend/priv/workspace_template/sources/mail/
 * messages/2026-07-09-priya-nair-seed0001.md`) and the cockpit narrative's
 * matching prepared item (`Valea.Cockpit.today/0`). Used when
 * `cockpit.mail.configured` is `false`, so the unconfigured Today page
 * keeps rendering the ORIGINAL seed card exactly as before Task 18: the
 * rich hand-authored summary plus its four source chips — NOT the generic
 * templated line the configured multi-card path uses (real synced messages
 * have no seeded narrative to draw on). `routes/+page.svelte` prefers
 * passing the live cockpit payload's own summary/usedSources for the seed
 * card; these constants are the byte-identical fallback (and the pinned
 * contract in triage-card.test.ts) if that payload entry is ever absent.
 */
export const SEED_TRIAGE_PATH = 'sources/mail/messages/2026-07-09-priya-nair-seed0001.md';
export const SEED_TRIAGE_FROM_NAME = 'Priya Nair';
export const SEED_TRIAGE_SUMMARY =
  'Good-fit inquiry — she asked about leadership coaching, which matches your core offer. Draft leads with the discovery call, not the price.';
export const SEED_TRIAGE_SOURCES = [
  'her email',
  'Offers › Founder Coaching',
  'Tone guide',
  'Policies › No medical advice'
];

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
 * "<fromName> · new inquiry" — the card's title in every non-approval
 * state. With the default `fromName` this reproduces the ORIGINAL seed
 * title verbatim ("Priya Nair · new inquiry").
 */
export function triageTitle(fromName: string): string {
  return `${fromName} · new inquiry`;
}

/**
 * The generic one-line summary for a REAL review message's card (the
 * configured multi-card path on Today) — built from the message's subject,
 * since arbitrary synced messages carry no hand-authored narrative. The
 * seed card never uses this: its summary prop defaults to
 * `SEED_TRIAGE_SUMMARY` (see above).
 */
export function genericSummary(subject: string): string {
  const trimmed = subject.trim();
  return trimmed
    ? `New inquiry: "${trimmed}" — read it and prepare a reply.`
    : 'New inquiry — read it and prepare a reply.';
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
