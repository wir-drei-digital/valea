import { describe, it, expect } from 'vitest';
import { pageViewState } from './page-view-state';

// Issue #2 §4: MarkdownPageView rendered "This page doesn't exist anymore."
// for ANY icm_page failure — a channel timeout on a perfectly healthy page
// read as a deletion. Only the backend's explicit `not_found` may claim
// non-existence; every other failure is "couldn't load" + retry.
describe('pageViewState', () => {
  it('is loading while the fetch is in flight', () => {
    expect(pageViewState({ loading: true, loadError: null, hasContent: false })).toBe('loading');
  });

  it('is loading before the first fetch has done anything', () => {
    expect(pageViewState({ loading: false, loadError: null, hasContent: false })).toBe('loading');
  });

  it("claims non-existence ONLY for the backend's explicit not_found", () => {
    expect(pageViewState({ loading: false, loadError: 'not_found', hasContent: false })).toBe('gone');
  });

  it('treats a channel timeout as a load failure, never as a deletion', () => {
    expect(pageViewState({ loading: false, loadError: 'channel_timeout', hasContent: false })).toBe(
      'load-failed'
    );
  });

  it('treats any other error (workspace_changed, unknown_error) as a load failure too', () => {
    expect(pageViewState({ loading: false, loadError: 'workspace_changed', hasContent: false })).toBe(
      'load-failed'
    );
    expect(pageViewState({ loading: false, loadError: 'unknown_error', hasContent: false })).toBe(
      'load-failed'
    );
  });

  it('is ready once content arrived cleanly', () => {
    expect(pageViewState({ loading: false, loadError: null, hasContent: true })).toBe('ready');
  });
});
