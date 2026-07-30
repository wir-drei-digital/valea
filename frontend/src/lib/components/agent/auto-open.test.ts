import { describe, it, expect } from 'vitest';
import { turnCount, latestTurnAutoOpenPath } from './auto-open';
import type { AcpItemLike } from './item-shapes';

const user = (text: string): AcpItemLike => ({ id: 'u1', type: 'message', role: 'user', text });
const assistant = (id: string, text: string): AcpItemLike => ({ id, type: 'message', role: 'assistant', text });
const tool = (id: string): AcpItemLike => ({ id, type: 'tool', kind: 'read', status: 'completed' });
const turn = (id: string, stop: string, seq?: number): AcpItemLike =>
  seq === undefined
    ? { id, type: 'turn', stop_reason: stop }
    : { id, type: 'turn', stop_reason: stop, seq };

describe('turnCount', () => {
  it('counts turn items only', () => {
    expect(turnCount([])).toBe(0);
    expect(turnCount([user('hi'), assistant('m1', 'x'), turn('t1', 'end_turn', 5)])).toBe(1);
    expect(turnCount([turn('t1', 'end_turn'), turn('t2', 'error', 9)])).toBe(2);
  });
});

describe('latestTurnAutoOpenPath', () => {
  it('returns the single path of the latest live end_turn', () => {
    const items = [user('fetch it'), assistant('m1', 'It is `CONTEXT.md`.'), turn('t1', 'end_turn', 7)];
    expect(latestTurnAutoOpenPath(items)).toBe('CONTEXT.md');
  });

  it('skips tool/thought items between message and turn', () => {
    const items = [assistant('m1', 'See `notes/a.md`'), tool('x1'), turn('t1', 'end_turn', 3)];
    expect(latestTurnAutoOpenPath(items)).toBe('notes/a.md');
  });

  it('never fires for snapshot turns (no numeric seq)', () => {
    const items = [assistant('m1', 'See `CONTEXT.md`'), turn('t1', 'end_turn')];
    expect(latestTurnAutoOpenPath(items)).toBeUndefined();
  });

  it('never fires for non-end_turn stops', () => {
    const items = [assistant('m1', 'See `CONTEXT.md`'), turn('t1', 'error', 4)];
    expect(latestTurnAutoOpenPath(items)).toBeUndefined();
  });

  it('requires exactly one distinct path', () => {
    const two = [assistant('m1', '`a.md` or `b.md`'), turn('t1', 'end_turn', 4)];
    const none = [assistant('m1', 'no paths here'), turn('t1', 'end_turn', 4)];
    expect(latestTurnAutoOpenPath(two)).toBeUndefined();
    expect(latestTurnAutoOpenPath(none)).toBeUndefined();
  });

  it('uses only the LATEST turn and its own preceding assistant message', () => {
    const items = [
      assistant('m1', 'old `a.md`'),
      turn('t1', 'end_turn', 2),
      assistant('m2', 'new `b.md`'),
      turn('t2', 'end_turn', 6)
    ];
    expect(latestTurnAutoOpenPath(items)).toBe('b.md');
  });

  it('stops at the previous turn — a message-less turn never adopts its message', () => {
    const items = [
      assistant('m1', 'old `a.md`'),
      turn('t1', 'end_turn', 2),
      turn('t2', 'end_turn', 6)
    ];
    expect(latestTurnAutoOpenPath(items)).toBeUndefined();
  });

  it('returns undefined when the turn has no assistant message, or no turns exist', () => {
    expect(latestTurnAutoOpenPath([user('hello'), turn('t1', 'end_turn', 2)])).toBeUndefined();
    expect(latestTurnAutoOpenPath([assistant('m1', '`a.md`')])).toBeUndefined();
  });
});
