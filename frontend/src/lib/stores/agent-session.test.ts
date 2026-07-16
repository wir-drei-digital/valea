import { describe, it, expect, vi } from 'vitest';
import { AgentSessionStore, type AcpItem } from './agent-session.svelte';
import type { Channel } from 'phoenix';

/**
 * Minimal fake `Channel` — mirrors `page-editor.test.ts`'s fake-api style
 * but for the Phoenix channel surface `AgentSessionStore` actually calls:
 * `.on`, `.join().receive(status, cb)` (chainable, like the real `Push`),
 * `.push`, `.leave`. Join resolution is NOT automatic on construction —
 * tests call `resolveJoinOk`/`resolveJoinError` explicitly so they can
 * control timing (including firing the same reply twice, to simulate a
 * Phoenix auto-rejoin redelivering the join reply through the same
 * `.receive('ok', ...)` callback).
 */
function fakeChannel() {
  const eventHandlers: Record<string, (payload: any) => void> = {};
  let okHandler: ((reply: any) => void) | null = null;
  let errorHandler: ((payload: any) => void) | null = null;
  const pushed: { event: string; payload: unknown }[] = [];

  const push = {
    receive(status: string, cb: (payload: any) => void) {
      if (status === 'ok') okHandler = cb;
      if (status === 'error') errorHandler = cb;
      return push;
    }
  };

  const channel = {
    on: (event: string, cb: (payload: any) => void) => {
      eventHandlers[event] = cb;
    },
    join: () => push,
    push: (event: string, payload: unknown) => {
      pushed.push({ event, payload });
    },
    leave: vi.fn()
  };

  return {
    channel: channel as unknown as Channel,
    pushed,
    emit: (event: string, payload: unknown) => eventHandlers[event]?.(payload),
    resolveJoinOk: (reply: unknown) => okHandler?.(reply),
    resolveJoinError: (payload: unknown) => errorHandler?.(payload)
  };
}

function findItem(items: AcpItem[], id: string) {
  return items.find((i) => i.id === id);
}

describe('AgentSessionStore', () => {
  it('joins via the injected join function, at the given id', () => {
    const fake = fakeChannel();
    const join = vi.fn(() => fake.channel);

    new AgentSessionStore('sess-1', {}, join);

    expect(join).toHaveBeenCalledWith('sess-1');
  });

  it('upsert dedup: an event at/behind cursor for a known id is dropped', () => {
    const fake = fakeChannel();
    const store = new AgentSessionStore('s1', {}, () => fake.channel);

    fake.resolveJoinOk({
      items: [{ id: 'a', type: 'msg', text: 'original' }],
      cursor: 5,
      busy: false,
      status: 'running'
    });

    // seq (3) <= cursor (5) and id 'a' is already known -> must be dropped,
    // not applied as a stale overwrite.
    fake.emit('event', { seq: 3, item: { id: 'a', type: 'msg', text: 'stale-overwrite' } });

    expect(store.items).toHaveLength(1);
    expect(findItem(store.items, 'a')?.text).toBe('original');

    // A genuinely new seq past the cursor still applies normally.
    fake.emit('event', { seq: 6, item: { id: 'a', type: 'msg', text: 'fresh-update' } });
    expect(findItem(store.items, 'a')?.text).toBe('fresh-update');
  });

  it('replay merge is idempotent across repeated join replies (simulated rejoin)', () => {
    const fake = fakeChannel();
    const store = new AgentSessionStore('s1', {}, () => fake.channel);
    const reply = {
      items: [
        { id: 'a', type: 'msg', text: 'hi' },
        { id: 'b', type: 'msg', text: 'yo' }
      ],
      cursor: 2,
      busy: false,
      status: 'running'
    };

    fake.resolveJoinOk(reply);
    expect(store.items).toHaveLength(2);

    // Phoenix redelivers the same join reply through the same `.receive`
    // callback on an auto-rejoin — re-applying the identical snapshot must
    // not duplicate or reorder items.
    fake.resolveJoinOk(reply);

    expect(store.items).toHaveLength(2);
    expect(store.items.map((i) => i.id)).toEqual(['a', 'b']);
    expect(store.items.map((i) => i.text)).toEqual(['hi', 'yo']);
  });

  it('pushes a provided initial prompt as the first user turn once the join succeeds', () => {
    const fake = fakeChannel();
    new AgentSessionStore('s1', { initialPrompt: 'Read `notes.md` and follow it.' }, () => fake.channel);

    // Not sent before the join resolves.
    expect(fake.pushed).toEqual([]);

    fake.resolveJoinOk({ items: [], cursor: 0, busy: false, status: 'running' });

    expect(fake.pushed).toEqual([{ event: 'prompt', payload: { content: 'Read `notes.md` and follow it.' } }]);
  });

  it('does not re-push the initial prompt on a redelivered join reply (simulated rejoin)', () => {
    const fake = fakeChannel();
    new AgentSessionStore('s1', { initialPrompt: 'hello' }, () => fake.channel);

    fake.resolveJoinOk({ items: [], cursor: 0, busy: false, status: 'running' });
    expect(fake.pushed).toHaveLength(1);

    // Phoenix redelivers the same join reply through the same `.receive`
    // callback on an auto-rejoin — the initial prompt must have been nulled
    // out after the first push, so it does not fire again.
    fake.resolveJoinOk({ items: [], cursor: 0, busy: false, status: 'running' });
    expect(fake.pushed).toHaveLength(1);
  });

  it('does nothing extra when no initial prompt is provided', () => {
    const fake = fakeChannel();
    new AgentSessionStore('s1', {}, () => fake.channel);

    fake.resolveJoinOk({ items: [], cursor: 0, busy: false, status: 'running' });

    expect(fake.pushed).toEqual([]);
  });

  it('busy flips false (falling edge) when a turn item arrives via an event push', () => {
    const fake = fakeChannel();
    const store = new AgentSessionStore('s1', {}, () => fake.channel);

    fake.resolveJoinOk({ items: [], cursor: 0, busy: false, status: 'running' });

    store.prompt('hello');
    expect(store.busy).toBe(true);

    fake.emit('event', { seq: 1, item: { id: 't1', type: 'turn', stop_reason: 'end_turn' } });

    expect(store.busy).toBe(false);
  });

  it('busy seeds from the join reply LAST, overriding a turn item already in the snapshot', () => {
    const fake = fakeChannel();
    const store = new AgentSessionStore('s1', {}, () => fake.channel);

    // The snapshot's own `turn` item would clear busy if seeding happened
    // BEFORE the replay loop — the server's busy: true (a new turn already
    // in flight on reconnect) must win.
    fake.resolveJoinOk({
      items: [{ id: 't0', type: 'turn', stop_reason: 'end_turn' }],
      cursor: 1,
      busy: true,
      status: 'running'
    });

    expect(store.busy).toBe(true);
    expect(store.status).toBe('running');
  });

  it('answerPermission pushes item_id/kind and does not locally mutate the item; only a server echo resolves it', () => {
    const fake = fakeChannel();
    const store = new AgentSessionStore('s1', {}, () => fake.channel);

    fake.resolveJoinOk({
      items: [{ id: 'perm1', type: 'permission', resolved: false }],
      cursor: 1,
      busy: false,
      status: 'running'
    });

    store.answerPermission('perm1', 'allow_once');

    expect(fake.pushed).toContainEqual({
      event: 'permission',
      payload: { item_id: 'perm1', kind: 'allow_once' }
    });
    // No optimistic local mutation.
    expect(findItem(store.items, 'perm1')?.resolved).toBe(false);

    // Server echoes the resolved item back over the event channel.
    fake.emit('event', { seq: 2, item: { id: 'perm1', type: 'permission', resolved: true } });

    expect(findItem(store.items, 'perm1')?.resolved).toBe(true);
  });

  it('prompt/cancel/setConfigOption/stop push the expected events and payloads', () => {
    const fake = fakeChannel();
    const store = new AgentSessionStore('s1', {}, () => fake.channel);
    fake.resolveJoinOk({ items: [], cursor: 0, busy: false, status: 'running' });

    store.prompt('do the thing');
    store.cancel();
    store.setConfigOption('model', 'sonnet');
    store.stop();

    expect(fake.pushed).toEqual([
      { event: 'prompt', payload: { content: 'do the thing' } },
      { event: 'cancel', payload: {} },
      { event: 'set_config_option', payload: { config_id: 'model', value: 'sonnet' } },
      { event: 'stop', payload: {} }
    ]);
  });

  it('status push and exit push update status; exit forces status to exited', () => {
    const fake = fakeChannel();
    const store = new AgentSessionStore('s1', {}, () => fake.channel);
    fake.resolveJoinOk({ items: [], cursor: 0, busy: false, status: 'starting' });

    fake.emit('status', { status: 'running' });
    expect(store.status).toBe('running');

    fake.emit('exit', { exit_code: 0 });
    expect(store.status).toBe('exited');
  });

  it('a join error sets status failed and records the reason', () => {
    const fake = fakeChannel();
    const store = new AgentSessionStore('s1', {}, () => fake.channel);

    fake.resolveJoinError({ reason: 'session_not_found' });

    expect(store.status).toBe('failed');
    expect(store.error).toBe('session_not_found');
  });

  it('dispose leaves the channel', () => {
    const fake = fakeChannel();
    const store = new AgentSessionStore('s1', {}, () => fake.channel);

    store.dispose();

    expect(fake.channel.leave).toHaveBeenCalledTimes(1);
  });
});
