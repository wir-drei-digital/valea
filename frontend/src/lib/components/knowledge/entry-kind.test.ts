import { describe, expect, it } from 'vitest';
import { startSessionLabel, referenceNoun, type EntryKind } from './entry-kind';

describe('startSessionLabel', () => {
  it('says "file" for a non-.md file leaf', () => {
    expect(startSessionLabel('file')).toBe('Start a session with this file');
  });

  it('keeps the original page wording for a page', () => {
    expect(startSessionLabel('page')).toBe('Start a session with this page');
  });

  it('falls back to the page wording for a folder (never rendered there)', () => {
    expect(startSessionLabel('folder')).toBe('Start a session with this page');
  });
});

describe('referenceNoun', () => {
  it('names a file target a file', () => {
    expect(referenceNoun('file')).toBe('file');
  });

  it('names a page target a page', () => {
    expect(referenceNoun('page')).toBe('page');
  });

  it('falls back to page for a folder (folders skip the reference lookup)', () => {
    expect(referenceNoun('folder')).toBe('page');
  });

  it('covers every kind', () => {
    const kinds: EntryKind[] = ['folder', 'page', 'file'];
    expect(kinds.map(referenceNoun)).toEqual(['page', 'page', 'file']);
  });
});
