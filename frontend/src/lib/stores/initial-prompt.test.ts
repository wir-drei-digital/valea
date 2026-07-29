import { describe, expect, test } from 'vitest';
import {
  setInitialPrompt,
  takeInitialPrompt,
  pageSessionPrompt,
  fileSessionPrompt
} from './initial-prompt';

describe('initial prompt handoff', () => {
  test('take returns the pending prompt exactly once', () => {
    setInitialPrompt('s1', 'hello');
    expect(takeInitialPrompt('s1')).toBe('hello');
    expect(takeInitialPrompt('s1')).toBeNull();
  });

  test('unknown session id yields null', () => {
    expect(takeInitialPrompt('nope')).toBeNull();
  });

  test('pageSessionPrompt references the cwd-relative path', () => {
    expect(pageSessionPrompt('finances/workflows/inbox-triage.md')).toContain(
      '`finances/workflows/inbox-triage.md`'
    );
  });

  test('fileSessionPrompt references the cwd-relative path of a non-.md file', () => {
    expect(fileSessionPrompt('finances/receipts/2026-Q1.pdf')).toContain(
      '`finances/receipts/2026-Q1.pdf`'
    );
  });

  test('fileSessionPrompt drops the page-specific "follow it" opening', () => {
    const prompt = fileSessionPrompt('Assets/logo.png');
    expect(prompt).not.toContain('follow it');
    expect(prompt).toContain("tell me what's in it");
    // The execute-a-workflow branch survives — a plain .txt runbook is
    // still a runbook.
    expect(prompt).toContain('execute it step by step');
  });
});
