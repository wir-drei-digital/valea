import { describe, expect, test } from 'vitest';
import { setInitialPrompt, takeInitialPrompt } from './initial-prompt';

describe('initial prompt handoff', () => {
  test('take returns the pending prompt exactly once', () => {
    setInitialPrompt('s1', 'hello');
    expect(takeInitialPrompt('s1')).toBe('hello');
    expect(takeInitialPrompt('s1')).toBeNull();
  });

  test('unknown session id yields null', () => {
    expect(takeInitialPrompt('nope')).toBeNull();
  });
});
