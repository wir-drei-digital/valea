import { describe, expect, it } from 'vitest';
import { derivePermissionView } from './permission-view';

describe('derivePermissionView', () => {
  it('builds an edit diff from old_string/new_string', () => {
    const v = derivePermissionView({
      title: 'Edit file',
      rawInput: { file_path: '/w/mounts/m/Pricing.md', old_string: 'a\nb', new_string: 'a\nc' },
      risk_tier: 'medium'
    });
    expect(v.diff?.mode).toBe('edit');
    expect(v.diff?.path).toBe('/w/mounts/m/Pricing.md');
    expect(v.tier).toBe('medium');
    expect(v.diff?.rows.some((r) => r.type === 'del' && r.text === 'b')).toBe(true);
  });

  it('builds an all-add preview for Write content', () => {
    const v = derivePermissionView({
      title: 'Write file',
      rawInput: { file_path: '/w/mounts/m/AGENTS.md', content: 'x\ny' },
      risk_tier: 'high'
    });
    expect(v.diff?.mode).toBe('write');
    expect(v.diff?.rows.every((r) => r.type === 'add')).toBe(true);
    expect(v.tier).toBe('high');
  });

  it('falls back to command-only for non-file tools', () => {
    const v = derivePermissionView({ title: 'Run command', command: 'ls', rawInput: { command: 'ls' } });
    expect(v.diff).toBeUndefined();
    expect(v.command).toBe('ls');
  });

  it('hides whitespace-only commands', () => {
    const v = derivePermissionView({
      title: 'Run',
      command: '   ',
      rawInput: { command: '   ' }
    });
    expect(v.command).toBeUndefined();
  });
});
