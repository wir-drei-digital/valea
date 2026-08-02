import { describe, it, expect } from 'vitest';
import { originLabel } from './origin-label';

// Spec 2026-08-02 §"the attachment chip". The chip is the only visible
// evidence that a new-session composer is pointed at a source, so the fallback
// chain has exactly two ways to fail: it can render a BLANK chip (an icon with
// nothing beside it — broken), or it can render nothing when something was
// displayable. Every step therefore trims and falls through on a falsy result,
// and `null` — which suppresses the chip entirely — is reserved for "there is
// genuinely nothing to say".
describe('originLabel', () => {
  it('prefers the label', () => {
    expect(originLabel({ kind: 'mail-message', path: 'INBOX/42', label: 'Invoice #3' })).toBe(
      'Invoice #3'
    );
  });

  it('trims the label rather than rendering its padding', () => {
    expect(originLabel({ kind: 'page', path: 'notes/CONTEXT.md', label: '  Context  ' })).toBe(
      'Context'
    );
  });

  // `parseOrigin` only rejects a FALSY label, so a whitespace-only one survives
  // parsing and reaches here. `??` would render it as a blank chip.
  it('falls through a whitespace-only label to the path', () => {
    expect(originLabel({ kind: 'page', path: 'notes/CONTEXT.md', label: '   ' })).toBe('CONTEXT.md');
  });

  it('falls back to the basename when there is no label at all', () => {
    expect(originLabel({ kind: 'file', path: 'notes/invoice.pdf' })).toBe('invoice.pdf');
  });

  // A hand-written trailing-slash path (`mail-message/INBOX%2F`) makes the last
  // segment `''`. Dropping empty segments reads it as "INBOX" — a basename a
  // human can use — instead of falling all the way through to the full path.
  it('reads a trailing-slash path as its last real segment', () => {
    expect(originLabel({ kind: 'mail-message', path: 'INBOX/' })).toBe('INBOX');
  });

  it('ignores whitespace-only segments when picking the basename', () => {
    expect(originLabel({ kind: 'file', path: 'notes/   /invoice.pdf' })).toBe('invoice.pdf');
    expect(originLabel({ kind: 'file', path: 'notes/invoice.pdf/   ' })).toBe('invoice.pdf');
  });

  it('uses the whole path when it has no separators to split on', () => {
    expect(originLabel({ kind: 'page', path: 'CONTEXT.md' })).toBe('CONTEXT.md');
  });

  // Nothing displayable anywhere in the chain: no chip at all, which is honest
  // — a blank one is just broken.
  it('is null for a whitespace-only path', () => {
    expect(originLabel({ kind: 'page', path: '   ' })).toBeNull();
  });

  // A path of only slashes has no non-empty segment, so the basename step
  // yields `undefined` and the chain lands on the LAST rung — the whole path,
  // which trims to a non-empty `'///'`. Documenting the real behaviour rather
  // than an assumed `null`: the chip is degenerate but not blank, and the
  // guarantee this chain owes the UI is only that it is never blank.
  it('shows a slashes-only path verbatim — the last rung of the chain, and not blank', () => {
    expect(originLabel({ kind: 'mail-message', path: '///' })).toBe('///');
  });

  it('trims the whole-path rung too', () => {
    expect(originLabel({ kind: 'page', path: ' / ', label: ' ' })).toBe('/');
  });

  it('is null when the composer has no origin', () => {
    expect(originLabel(null)).toBeNull();
  });

  // THE INVARIANT: never an empty string. An empty string renders the
  // paperclip with nothing beside it; `null` renders no chip at all. Whatever
  // the origin, the chip either says something or does not exist.
  it('never returns a blank string for any degenerate origin', () => {
    for (const path of ['', ' ', '/', '///', ' / / ', '\t\n', 'a//b']) {
      for (const label of [undefined, '', '   ', '\t']) {
        const result = originLabel({
          kind: 'page',
          path,
          ...(label === undefined ? {} : { label })
        });
        expect(result === null || result.trim() !== '').toBe(true);
      }
    }
  });
});
