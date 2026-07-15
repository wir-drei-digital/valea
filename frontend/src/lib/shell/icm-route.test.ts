import { describe, expect, it } from 'vitest';
import { resolveIcmSelection, resolveActiveMountKey, filterByMountKey } from './icm-route';

describe('resolveIcmSelection', () => {
  it('returns the icm param verbatim when present, even if not in the enabled list', () => {
    expect(resolveIcmSelection('clients', ['primary'])).toBe('clients');
  });

  it('falls back to the first enabled mount (config order) when the param is absent', () => {
    expect(resolveIcmSelection(null, ['zeta', 'alpha'])).toBe('zeta');
  });

  it('returns null when there is no param and nothing enabled', () => {
    expect(resolveIcmSelection(null, [])).toBeNull();
  });
});

describe('resolveActiveMountKey', () => {
  it('reads the mount key from a /knowledge/<mountKey>/... deep link, ignoring ?icm', () => {
    const params = new URLSearchParams('icm=other');
    expect(resolveActiveMountKey('/knowledge/primary/Folder/Page.md', params, [])).toBe('primary');
  });

  it('decodes an encoded mount key from the path', () => {
    const params = new URLSearchParams();
    expect(resolveActiveMountKey('/knowledge/client%20notes', params, [])).toBe('client notes');
  });

  it('reads ?icm on the bare /knowledge index (no path segment)', () => {
    const params = new URLSearchParams('icm=clients');
    expect(resolveActiveMountKey('/knowledge', params, [])).toBe('clients');
  });

  it('returns null on /knowledge with no ?icm', () => {
    expect(resolveActiveMountKey('/knowledge', new URLSearchParams(), [])).toBeNull();
  });

  it('looks up a /chat?session= id in recentGroups to find its owning mount', () => {
    const params = new URLSearchParams('session=s1');
    const groups = [
      { mountKey: 'primary', sessions: [{ id: 's0' }] },
      { mountKey: 'clients', sessions: [{ id: 's1' }] }
    ];
    expect(resolveActiveMountKey('/chat', params, groups)).toBe('clients');
  });

  it('is null for a /chat?session= id not found in any group — never falls back to ?icm', () => {
    const params = new URLSearchParams('session=unknown&icm=primary');
    const groups = [{ mountKey: 'primary', sessions: [{ id: 's0' }] }];
    expect(resolveActiveMountKey('/chat', params, groups)).toBeNull();
  });

  it('reads ?icm on /chat when there is no session param', () => {
    const params = new URLSearchParams('icm=clients');
    expect(resolveActiveMountKey('/chat', params, [])).toBe('clients');
  });

  it('reads ?icm on /workflows', () => {
    const params = new URLSearchParams('icm=clients');
    expect(resolveActiveMountKey('/workflows', params, [])).toBe('clients');
  });

  it('is null on an unscoped route like / with no ?icm', () => {
    expect(resolveActiveMountKey('/', new URLSearchParams(), [])).toBeNull();
  });
});

describe('filterByMountKey', () => {
  const items = [{ mountKey: 'primary', n: 1 }, { mountKey: 'clients', n: 2 }];

  it('passes everything through when mountKey is null (no filter selected)', () => {
    expect(filterByMountKey(items, null)).toEqual(items);
  });

  it('filters down to the matching mountKey', () => {
    expect(filterByMountKey(items, 'clients')).toEqual([{ mountKey: 'clients', n: 2 }]);
  });

  it('returns [] when nothing matches', () => {
    expect(filterByMountKey(items, 'nope')).toEqual([]);
  });
});
