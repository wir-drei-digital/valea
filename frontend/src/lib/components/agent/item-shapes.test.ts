import { describe, it, expect } from 'vitest';
import {
  asString,
  asPresentString,
  permissionOptions,
  isRejectKind,
  toolDiff,
  diffLines,
  planEntries,
  planProgress,
  configOptions,
  configCurrent,
  configWireId,
  usageFields,
  contextUsage,
  sessionInfoTitle
} from './item-shapes';

describe('asString / asPresentString', () => {
  it('coerces non-strings to empty / undefined', () => {
    expect(asString(42)).toBe('');
    expect(asString(undefined)).toBe('');
    expect(asString('hi')).toBe('hi');
    expect(asPresentString('   ')).toBeUndefined();
    expect(asPresentString('')).toBeUndefined();
    expect(asPresentString('path/to/file')).toBe('path/to/file');
  });
});

describe('permissionOptions', () => {
  it('returns [] when options is missing or malformed', () => {
    expect(permissionOptions({ id: 'p', type: 'permission' })).toEqual([]);
    expect(permissionOptions({ id: 'p', type: 'permission', options: 'nope' })).toEqual([]);
  });

  it('parses the {optionId, name, kind} shape emitted by request_permission', () => {
    const options = permissionOptions({
      id: 'p',
      type: 'permission',
      options: [
        { optionId: 'opt-1', name: 'Allow once', kind: 'allow_once' },
        { optionId: 'opt-2', kind: 'reject_once' }
      ]
    });

    expect(options).toEqual([
      { optionId: 'opt-1', name: 'Allow once', kind: 'allow_once' },
      { optionId: 'opt-2', name: 'opt-2', kind: 'reject_once' } // falls back to optionId when name absent
    ]);
  });

  it('drops entries missing a string optionId', () => {
    expect(permissionOptions({ id: 'p', type: 'permission', options: [{ name: 'x' }, null, 42] })).toEqual([]);
  });
});

describe('isRejectKind', () => {
  it('flags reject_once/reject_always, not allow_*', () => {
    expect(isRejectKind('reject_once')).toBe(true);
    expect(isRejectKind('reject_always')).toBe(true);
    expect(isRejectKind('allow_once')).toBe(false);
    expect(isRejectKind('allow_always')).toBe(false);
  });
});

describe('toolDiff / diffLines', () => {
  it('returns undefined when diff is absent', () => {
    expect(toolDiff({ id: 't', type: 'tool' })).toBeUndefined();
  });

  it('takes only path/oldText/newText', () => {
    const diff = toolDiff({
      id: 't',
      type: 'tool',
      diff: { path: 'lib/foo.ex', oldText: 'a\nb\n', newText: 'a\nc\n', extra: 'ignored' }
    });
    expect(diff).toEqual({ path: 'lib/foo.ex', oldText: 'a\nb\n', newText: 'a\nc\n' });
  });

  it('splits on newlines and drops one trailing blank line', () => {
    expect(diffLines('a\nb\n')).toEqual(['a', 'b']);
    expect(diffLines('a\nb')).toEqual(['a', 'b']);
    expect(diffLines(undefined)).toEqual([]);
    expect(diffLines('')).toEqual([]);
  });
});

describe('planEntries / planProgress', () => {
  it('returns [] for a missing or malformed plan item', () => {
    expect(planEntries(undefined)).toEqual([]);
    expect(planEntries({ id: 'plan', type: 'plan' })).toEqual([]);
  });

  it('parses {text, status} entries', () => {
    const entries = planEntries({
      id: 'plan',
      type: 'plan',
      entries: [
        { text: 'Read the brief', status: 'completed' },
        { text: 'Build the components', status: 'in_progress' },
        { text: 'Run bun check', status: 'pending' }
      ]
    });
    expect(entries).toHaveLength(3);
    expect(entries[1]).toEqual({ text: 'Build the components', status: 'in_progress' });
  });

  it('computes done/total/current — current is the in_progress entry', () => {
    const entries = planEntries({
      id: 'plan',
      type: 'plan',
      entries: [
        { text: 'a', status: 'completed' },
        { text: 'b', status: 'in_progress' },
        { text: 'c', status: 'pending' }
      ]
    });
    expect(planProgress(entries)).toEqual({ done: 1, total: 3, current: { text: 'b', status: 'in_progress' } });
  });

  it('falls back to the first not-done entry when nothing is in_progress', () => {
    const entries = planEntries({
      id: 'plan',
      type: 'plan',
      entries: [
        { text: 'a', status: 'completed' },
        { text: 'b', status: 'pending' }
      ]
    });
    expect(planProgress(entries).current).toEqual({ text: 'b', status: 'pending' });
  });

  it('current is undefined once every entry is done', () => {
    const entries = planEntries({
      id: 'plan',
      type: 'plan',
      entries: [{ text: 'a', status: 'completed' }, { text: 'b', status: 'done' }]
    });
    expect(planProgress(entries)).toEqual({ done: 2, total: 2, current: undefined });
  });
});

describe('configOptions / configCurrent', () => {
  it('reads {value, name} pairs and falls back to id-as-name', () => {
    const options = configOptions({
      id: 'config-mode',
      type: 'config',
      options: [
        { value: 'default', name: 'Default' },
        { value: 'plan' }
      ]
    });
    expect(options).toEqual([
      { id: 'default', name: 'Default' },
      { id: 'plan', name: 'plan' }
    ]);
  });

  it('accepts an {id, name} fallback shape', () => {
    expect(configOptions({ id: 'c', type: 'config', options: [{ id: 'x', name: 'X' }] })).toEqual([
      { id: 'x', name: 'X' }
    ]);
  });

  it('configCurrent returns null when unset', () => {
    expect(configCurrent({ id: 'c', type: 'config' })).toBeNull();
    expect(configCurrent({ id: 'c', type: 'config', current: 'plan' })).toBe('plan');
  });

  // The wire id must be the RAW ACP configId — echoing the prefixed render
  // id made the adapter reject every composer model/effort/mode change as
  // `Unknown config option: config-<...>`.
  it('configWireId prefers item.config_id and never returns the prefixed render id', () => {
    expect(configWireId({ id: 'config-model', config_id: 'model', type: 'config' })).toBe('model');
  });

  it('configWireId strips the render prefix as a fallback for items without config_id', () => {
    expect(configWireId({ id: 'config-effort', type: 'config' })).toBe('effort');
    expect(configWireId({ id: 'mode', type: 'mode' })).toBe('mode'); // legacy item, no prefix
  });
});

describe('usageFields', () => {
  it('returns [] when there is no usage item', () => {
    expect(usageFields(undefined)).toEqual([]);
  });

  it('renders every present field, dropping id/type, formatting numbers and titling keys', () => {
    const fields = usageFields({
      id: 'usage',
      type: 'usage',
      inputTokens: 1234,
      outputTokens: 56,
      context_window: 200000
    });

    expect(fields).toEqual([
      { label: 'Input tokens', value: '1,234' },
      { label: 'Output tokens', value: '56' },
      { label: 'Context window', value: '200,000' }
    ]);
  });

  it('never invents a derived field — only echoes what the item carries', () => {
    const fields = usageFields({ id: 'usage', type: 'usage', inputTokens: 10 });
    expect(fields).toEqual([{ label: 'Input tokens', value: '10' }]);
  });
});

describe('contextUsage', () => {
  it('derives used/max/fraction from an explicit camelCase pair', () => {
    expect(contextUsage({ id: 'usage', type: 'usage', usedTokens: 50_000, maxTokens: 200_000 })).toEqual({
      used: 50_000,
      max: 200_000,
      fraction: 0.25
    });
  });

  it('accepts snake_case and contextWindow as the max', () => {
    expect(
      contextUsage({ id: 'usage', type: 'usage', used_tokens: 30, context_window: 100 })?.fraction
    ).toBe(0.3);
    expect(
      contextUsage({ id: 'usage', type: 'usage', usedTokens: 10, contextWindow: 100 })?.fraction
    ).toBe(0.1);
  });

  it('is undefined without an explicit used/max pair — no invented math over other counters', () => {
    expect(contextUsage(undefined)).toBeUndefined();
    expect(contextUsage({ id: 'usage', type: 'usage', inputTokens: 10, outputTokens: 5 })).toBeUndefined();
    expect(contextUsage({ id: 'usage', type: 'usage', usedTokens: 10 })).toBeUndefined();
    expect(contextUsage({ id: 'usage', type: 'usage', usedTokens: 10, maxTokens: 0 })).toBeUndefined();
  });

  it('clamps the fraction at 1', () => {
    expect(contextUsage({ id: 'usage', type: 'usage', usedTokens: 300, maxTokens: 100 })?.fraction).toBe(1);
  });
});

describe('sessionInfoTitle', () => {
  it('returns the agent-provided title from the session_info singleton', () => {
    const items = [
      { id: 'user-1', type: 'message' },
      { id: 'session_info', type: 'session_info', title: 'Fix the login flow' }
    ];
    expect(sessionInfoTitle(items)).toBe('Fix the login flow');
  });

  it('is undefined when no session_info item exists, or its title is empty/missing', () => {
    expect(sessionInfoTitle([])).toBeUndefined();
    expect(sessionInfoTitle([{ id: 'session_info', type: 'session_info' }])).toBeUndefined();
    expect(
      sessionInfoTitle([{ id: 'session_info', type: 'session_info', title: '   ' }])
    ).toBeUndefined();
    expect(
      sessionInfoTitle([{ id: 'session_info', type: 'session_info', title: 42 }])
    ).toBeUndefined();
  });

  it('reads the last session_info item when several are present', () => {
    const items = [
      { id: 'a', type: 'session_info', title: 'Old' },
      { id: 'b', type: 'session_info', title: 'New' }
    ];
    expect(sessionInfoTitle(items)).toBe('New');
  });
});
