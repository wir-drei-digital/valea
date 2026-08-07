import { describe, it, expect } from 'vitest';
import { GRAMMARS, isGrammar, grammarForFilename, grammarForFence } from './languages';

describe('grammarForFilename', () => {
  it('maps source extensions', () => {
    expect(grammarForFilename('session_server.ex')).toBe('elixir');
    expect(grammarForFilename('client.ts')).toBe('typescript');
    expect(grammarForFilename('main.rs')).toBe('rust');
  });

  it('reads the basename, so a dotted folder is not mistaken for an extension', () => {
    expect(grammarForFilename('notes/v1.2/README')).toBeNull();
    expect(grammarForFilename('notes/v1.2/main.py')).toBe('python');
  });

  it('is case-insensitive', () => {
    expect(grammarForFilename('Config.YAML')).toBe('yaml');
  });

  it('matches well-known extension-less basenames', () => {
    expect(grammarForFilename('Dockerfile')).toBe('dockerfile');
    expect(grammarForFilename('backend/Makefile')).toBe('makefile');
    expect(grammarForFilename('Justfile')).toBe('makefile');
  });

  it('returns null for a dotfile, an unknown extension, and an empty name', () => {
    expect(grammarForFilename('.gitignore')).toBeNull();
    expect(grammarForFilename('archive.bin')).toBeNull();
    expect(grammarForFilename('')).toBeNull();
  });

  it('never returns a grammar outside GRAMMARS', () => {
    const answer = grammarForFilename('a.svelte');
    expect(answer).not.toBeNull();
    expect(isGrammar(answer as string)).toBe(true);
  });
});

describe('grammarForFence', () => {
  it('accepts a grammar id verbatim', () => {
    expect(grammarForFence('elixir')).toBe('elixir');
  });

  it('accepts extensions and common fence aliases', () => {
    expect(grammarForFence('ts')).toBe('typescript');
    expect(grammarForFence('sh')).toBe('bash');
    expect(grammarForFence('shell')).toBe('bash');
    expect(grammarForFence('console')).toBe('bash');
  });

  it('reads only the first word, and ignores case and surrounding space', () => {
    expect(grammarForFence('  TS  title=foo.ts ')).toBe('typescript');
  });

  it('returns null for an empty or unknown fence', () => {
    expect(grammarForFence('')).toBeNull();
    expect(grammarForFence('brainfuck')).toBeNull();
    expect(grammarForFence('text')).toBeNull();
  });
});

describe('GRAMMARS', () => {
  it('has no duplicates', () => {
    expect(new Set(GRAMMARS).size).toBe(GRAMMARS.length);
  });
});
