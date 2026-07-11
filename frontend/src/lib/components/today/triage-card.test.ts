import { describe, expect, it } from 'vitest';
import {
  SEED_TRIAGE_FROM_NAME,
  SEED_TRIAGE_PATH,
  SEED_TRIAGE_SOURCES,
  SEED_TRIAGE_SUMMARY,
  envelopeInputPath,
  genericSummary,
  runWorkflowErrorMessage,
  triageTitle
} from './triage-card';

describe('envelopeInputPath', () => {
  it('reads the string `input` field off a raw envelope', () => {
    expect(envelopeInputPath({ input: 'sources/mail/messages/x.md' })).toBe('sources/mail/messages/x.md');
  });

  it('returns null when `input` is missing or the wrong type', () => {
    expect(envelopeInputPath({})).toBeNull();
    expect(envelopeInputPath({ input: 42 })).toBeNull();
  });

  it('returns null for non-object input without throwing', () => {
    expect(envelopeInputPath(null)).toBeNull();
    expect(envelopeInputPath(undefined)).toBeNull();
    expect(envelopeInputPath('not an object')).toBeNull();
  });
});

// Pins the card's DEFAULT (unconfigured Today) render inputs to the exact
// pre-Task-18 seed experience: the cockpit narrative's hand-authored Priya
// summary and its four source chips, sourced from `Valea.Cockpit.today/0`'s
// seeded prepared item and the seed message file. If any of these drift,
// the unconfigured seed card silently stops matching the original — which
// is precisely the regression Task 18's review caught.
describe('seed defaults', () => {
  it('pin the original seed card copy verbatim', () => {
    expect(SEED_TRIAGE_PATH).toBe('sources/mail/messages/2026-07-09-priya-nair-seed0001.md');
    expect(SEED_TRIAGE_FROM_NAME).toBe('Priya Nair');
    expect(SEED_TRIAGE_SUMMARY).toBe(
      'Good-fit inquiry — she asked about leadership coaching, which matches your core offer. Draft leads with the discovery call, not the price.'
    );
    expect(SEED_TRIAGE_SOURCES).toEqual([
      'her email',
      'Offers › Founder Coaching',
      'Tone guide',
      'Policies › No medical advice'
    ]);
  });

  it('reproduce the original seed card title through triageTitle', () => {
    expect(triageTitle(SEED_TRIAGE_FROM_NAME)).toBe('Priya Nair · new inquiry');
  });
});

describe('triageTitle', () => {
  it('builds the title from fromName', () => {
    expect(triageTitle('Alex Kim')).toBe('Alex Kim · new inquiry');
  });
});

describe('genericSummary', () => {
  it('quotes the subject when present', () => {
    expect(genericSummary('Question about leadership coaching')).toBe(
      'New inquiry: "Question about leadership coaching" — read it and prepare a reply.'
    );
  });

  it('falls back to a subject-less line when blank', () => {
    expect(genericSummary('   ')).toBe('New inquiry — read it and prepare a reply.');
  });
});

describe('runWorkflowErrorMessage', () => {
  it('maps every known error code', () => {
    expect(runWorkflowErrorMessage('harness_unavailable')).toBe('The assistant harness is not ready yet.');
    expect(runWorkflowErrorMessage('workflow_disabled')).toBe('This workflow is turned off.');
    expect(runWorkflowErrorMessage('input_not_found')).toBe('The inquiry email is missing.');
    expect(runWorkflowErrorMessage('workspace_changed')).toBe('Your workspace changed. Reopen it and try again.');
    expect(runWorkflowErrorMessage('workspace_not_open')).toBe('No workspace is open.');
  });

  it('falls back to a generic message for an unknown code', () => {
    expect(runWorkflowErrorMessage('mystery')).toBe('Could not start the assistant. Please try again.');
  });
});
