import { describe, expect, it } from 'vitest';
import { envelopeInputPath, idleCopy, runWorkflowErrorMessage } from './triage-card';

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

describe('idleCopy', () => {
  it('builds the title from fromName, reproducing the original seed title verbatim', () => {
    const { title } = idleCopy('Priya Nair', 'Question about leadership coaching');
    expect(title).toBe('Priya Nair · new inquiry');
  });

  it('quotes the subject in the summary when present', () => {
    const { summary } = idleCopy('Priya Nair', 'Question about leadership coaching');
    expect(summary).toBe('New inquiry: "Question about leadership coaching" — read it and prepare a reply.');
  });

  it('falls back to a subject-less summary when blank', () => {
    const { summary } = idleCopy('Someone', '   ');
    expect(summary).toBe('New inquiry — read it and prepare a reply.');
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
