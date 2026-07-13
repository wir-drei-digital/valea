import { describe, expect, it } from 'vitest';
import { distillButtonState, distillErrorMessage } from './distill';

describe('distillButtonState', () => {
  it('hides the action when distillWorkflowPath is null', () => {
    expect(distillButtonState({ distillWorkflowPath: null }, 'idle')).toEqual({
      visible: false,
      label: 'Distill recent decisions',
      disabled: true
    });
  });

  it('hides the action when today has not loaded yet', () => {
    expect(distillButtonState(null, 'idle').visible).toBe(false);
    expect(distillButtonState(undefined, 'running').visible).toBe(false);
  });

  it('idle: visible, enabled, resting label, no note', () => {
    const state = distillButtonState(
      { distillWorkflowPath: 'mounts/primary/Workflows/Distill Decisions.md' },
      'idle'
    );
    expect(state).toEqual({ visible: true, label: 'Distill recent decisions', disabled: false });
  });

  it('running: visible, disabled, in-flight label, no note', () => {
    const state = distillButtonState({ distillWorkflowPath: 'p' }, 'running');
    expect(state).toEqual({ visible: true, label: 'Distilling…', disabled: true });
  });

  it('empty: visible, re-enabled, resting label, empty-window note', () => {
    const state = distillButtonState({ distillWorkflowPath: 'p' }, 'empty');
    expect(state).toEqual({
      visible: true,
      label: 'Distill recent decisions',
      disabled: false,
      note: 'No decisions in the last 30 days yet.'
    });
  });

  it('error: visible, re-enabled, resting label, note carries the supplied message', () => {
    const state = distillButtonState(
      { distillWorkflowPath: 'p' },
      'error',
      'Your workspace changed. Reopen it and try again.'
    );
    expect(state).toEqual({
      visible: true,
      label: 'Distill recent decisions',
      disabled: false,
      note: 'Your workspace changed. Reopen it and try again.'
    });
  });

  it('error: falls back to a generic note when no message is supplied', () => {
    const state = distillButtonState({ distillWorkflowPath: 'p' }, 'error');
    expect(state.note).toBe('Could not start the assistant. Please try again.');
  });
});

describe('distillErrorMessage', () => {
  it('maps every known distill error code', () => {
    expect(distillErrorMessage('workflow_not_found')).toBe('No Distill Decisions workflow is set up yet.');
    expect(distillErrorMessage('harness_unavailable')).toBe('The assistant harness is not ready yet.');
    expect(distillErrorMessage('workflow_disabled')).toBe('This workflow is turned off.');
    expect(distillErrorMessage('workspace_changed')).toBe('Your workspace changed. Reopen it and try again.');
    expect(distillErrorMessage('workspace_not_open')).toBe('No workspace is open.');
  });

  it('falls back to a generic message for an unknown code', () => {
    expect(distillErrorMessage('mystery')).toBe('Could not start the assistant. Please try again.');
  });
});
