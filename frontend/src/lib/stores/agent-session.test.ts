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

  it('an in-place update keeps an item at its FIRST-seen position', () => {
    const fake = fakeChannel();
    const store = new AgentSessionStore('s1', {}, () => fake.channel);
    fake.resolveJoinOk({ items: [], cursor: 0, busy: false, status: 'running' });

    // A tool announced BEFORE the agent speaks, completing AFTER it — the
    // shape every long-running tool produces. The completion update must not
    // relocate the card below the message that came out while it ran.
    fake.emit('event', { seq: 1, item: { id: 'tool-a', type: 'tool', status: 'in_progress' } });
    fake.emit('event', { seq: 2, item: { id: 'msg-1', type: 'message', text: 'working on it' } });
    fake.emit('event', { seq: 3, item: { id: 'tool-a', type: 'tool', status: 'completed' } });

    expect(store.items.map((i) => i.id)).toEqual(['tool-a', 'msg-1']);
  });

  it('live items append after snapshot items, which keep their replay order', () => {
    const fake = fakeChannel();
    const store = new AgentSessionStore('s1', {}, () => fake.channel);

    // Snapshot items carry no per-item seq (see the store's class doc); their
    // order IS the backend timeline order and must survive verbatim.
    fake.resolveJoinOk({
      items: [
        { id: 'a', type: 'message', text: 'first' },
        { id: 'b', type: 'tool' }
      ],
      cursor: 7,
      busy: false,
      status: 'running'
    });

    fake.emit('event', { seq: 8, item: { id: 'c', type: 'message', text: 'live' } });
    // …and an update to a SNAPSHOT item leaves it where the replay put it.
    fake.emit('event', { seq: 9, item: { id: 'b', type: 'tool', status: 'completed' } });

    expect(store.items.map((i) => i.id)).toEqual(['a', 'b', 'c']);
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

  it('takes busy from the server push', () => {
    const fake = fakeChannel();
    const store = new AgentSessionStore('s', {}, () => fake.channel);
    fake.resolveJoinOk({ items: [], cursor: 0, busy: false });

    fake.emit('busy', { busy: true });
    expect(store.busy).toBe(true);

    fake.emit('busy', { busy: false });
    expect(store.busy).toBe(false);
  });

  // The bug this whole change exists for: a subtask's tool update landing
  // after its turn completed used to re-raise busy with no `turn` item left
  // to come, stranding the composer's working indicator until a reload.
  it('a tool update arriving after the turn ended does not re-arm busy', () => {
    const fake = fakeChannel();
    const store = new AgentSessionStore('s', {}, () => fake.channel);
    fake.resolveJoinOk({ items: [], cursor: 0, busy: false });

    fake.emit('busy', { busy: true });
    fake.emit('event', { seq: 1, item: { id: 'turn-1', type: 'turn', stop_reason: 'end_turn' } });
    fake.emit('busy', { busy: false });

    fake.emit('event', {
      seq: 2,
      item: { id: 'tool-late', type: 'tool', title: 'Task', status: 'completed' }
    });

    expect(store.busy).toBe(false);
  });

  it('the client queue drains on the turn item, and busy simply follows the server through the handoff', () => {
    const fake = fakeChannel();
    const store = new AgentSessionStore('s', {}, () => fake.channel);
    fake.resolveJoinOk({ items: [], cursor: 0, busy: false });

    fake.emit('busy', { busy: true });
    store.send('queued one');
    expect(store.queued).toHaveLength(1);

    fake.emit('event', { seq: 1, item: { id: 'turn-1', type: 'turn', stop_reason: 'end_turn' } });

    // The turn item flushes the held message out as a real `prompt` push.
    expect(store.queued).toHaveLength(0);
    expect(fake.pushed.some((p) => p.event === 'prompt')).toBe(true);

    // `busy` isn't touched by any of the above (see `#upsert`/`#flushQueue`)
    // — it just tracks whatever the server pushes next: false for the turn
    // that just ended, then true once the flushed prompt's new turn starts.
    fake.emit('busy', { busy: false });
    expect(store.busy).toBe(false);

    fake.emit('busy', { busy: true });
    expect(store.busy).toBe(true);
  });

  it('busy seeds from the join reply LAST, overriding a turn item already in the snapshot', () => {
    const fake = fakeChannel();
    const store = new AgentSessionStore('s1', {}, () => fake.channel);

    // The snapshot's own `turn` item no longer touches `busy` at all (see
    // `#upsert`) — this just pins that the join reply's `busy: true` (a new
    // turn already in flight on reconnect) is what the store ends up with.
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

  const configItem = (wireId: string, current: string, options: string[]) => ({
    id: `config-${wireId}`,
    type: 'config',
    config_id: wireId,
    name: wireId,
    current,
    options: options.map((id) => ({ id, name: id }))
  });

  it('applies a staged option once the config item arrives', () => {
    const fake = fakeChannel();
    new AgentSessionStore('s', { applyConfig: { model: 'opus' } }, () => fake.channel);
    fake.resolveJoinOk({ items: [], cursor: 0, busy: false });

    fake.emit('event', { seq: 1, item: configItem('model', 'sonnet', ['sonnet', 'opus']) });

    expect(fake.pushed).toContainEqual({
      event: 'set_config_option',
      payload: { config_id: 'model', value: 'opus' }
    });
  });

  it('pushes each staged option at most once', () => {
    const fake = fakeChannel();
    new AgentSessionStore('s', { applyConfig: { model: 'opus' } }, () => fake.channel);
    fake.resolveJoinOk({ items: [], cursor: 0, busy: false });

    fake.emit('event', { seq: 1, item: configItem('model', 'sonnet', ['sonnet', 'opus']) });
    fake.emit('event', { seq: 2, item: configItem('model', 'opus', ['sonnet', 'opus']) });

    expect(fake.pushed.filter((p) => p.event === 'set_config_option')).toHaveLength(1);
  });

  it('says nothing when the option already matches', () => {
    const fake = fakeChannel();
    new AgentSessionStore('s', { applyConfig: { model: 'opus' } }, () => fake.channel);
    fake.resolveJoinOk({ items: [], cursor: 0, busy: false });

    fake.emit('event', { seq: 1, item: configItem('model', 'opus', ['sonnet', 'opus']) });

    expect(fake.pushed.filter((p) => p.event === 'set_config_option')).toHaveLength(0);
  });

  it('drops a remembered value the adapter no longer offers', () => {
    const fake = fakeChannel();
    new AgentSessionStore('s', { applyConfig: { model: 'retired-model' } }, () => fake.channel);
    fake.resolveJoinOk({ items: [], cursor: 0, busy: false });

    fake.emit('event', { seq: 1, item: configItem('model', 'sonnet', ['sonnet', 'opus']) });

    expect(fake.pushed.filter((p) => p.event === 'set_config_option')).toHaveLength(0);
  });

  it('leaves config alone when nothing was staged', () => {
    const fake = fakeChannel();
    new AgentSessionStore('s', {}, () => fake.channel);
    fake.resolveJoinOk({ items: [], cursor: 0, busy: false });

    fake.emit('event', { seq: 1, item: configItem('model', 'sonnet', ['sonnet', 'opus']) });

    expect(fake.pushed.filter((p) => p.event === 'set_config_option')).toHaveLength(0);
  });

  it('dispose leaves the channel', () => {
    const fake = fakeChannel();
    const store = new AgentSessionStore('s1', {}, () => fake.channel);

    store.dispose();

    expect(fake.channel.leave).toHaveBeenCalledTimes(1);
  });
});

describe('AgentSessionStore prompt queue', () => {
  function runningStore() {
    const fake = fakeChannel();
    const store = new AgentSessionStore('s1', {}, () => fake.channel);
    fake.resolveJoinOk({ items: [], cursor: 0, busy: false, status: 'running' });
    return { fake, store };
  }

  it('send while idle prompts immediately', () => {
    const { fake, store } = runningStore();

    store.send('hello');

    expect(fake.pushed).toEqual([{ event: 'prompt', payload: { content: 'hello' } }]);
    expect(store.queued).toEqual([]);
    expect(store.busy).toBe(true);
  });

  it('send while busy queues instead of pushing; the turn end flushes in order', () => {
    const { fake, store } = runningStore();

    store.send('first');
    store.send('second');
    store.send('third');

    // Only the first went over the wire; the rest are held client-side.
    expect(fake.pushed).toEqual([{ event: 'prompt', payload: { content: 'first' } }]);
    expect(store.queued.map((m) => m.text)).toEqual(['second', 'third']);

    fake.emit('event', { seq: 1, item: { id: 't1', type: 'turn', stop_reason: 'end_turn' } });

    // Flushed in order; busy is up again (the first flushed prompt's rising edge).
    expect(fake.pushed.map((p) => (p.payload as { content: string }).content)).toEqual([
      'first',
      'second',
      'third'
    ]);
    expect(store.queued).toEqual([]);
    expect(store.busy).toBe(true);
  });

  it('queued messages can be edited and dismissed before the flush', () => {
    const { fake, store } = runningStore();

    store.send('first');
    store.send('second');
    store.send('third');

    const [a, b] = store.queued;
    store.updateQueued(a.id, 'second, revised');
    store.dismissQueued(b.id);

    fake.emit('event', { seq: 1, item: { id: 't1', type: 'turn', stop_reason: 'end_turn' } });

    expect(fake.pushed.map((p) => (p.payload as { content: string }).content)).toEqual([
      'first',
      'second, revised'
    ]);
  });

  it('sendQueuedNow cancels the in-flight turn and prompts that one message; the rest stay queued', () => {
    const { fake, store } = runningStore();

    store.send('first');
    store.send('second');
    store.send('third');

    const jumpAhead = store.queued[1];
    store.sendQueuedNow(jumpAhead.id);

    expect(fake.pushed).toEqual([
      { event: 'prompt', payload: { content: 'first' } },
      { event: 'cancel', payload: {} },
      { event: 'prompt', payload: { content: 'third' } }
    ]);
    expect(store.queued.map((m) => m.text)).toEqual(['second']);
  });

  // `turnStartedAt` shares `#setBusy` with `busy` itself, so it anchors on
  // the SAME two sources: `prompt/1`'s optimistic raise, and the server's
  // `busy` push (a server-side queued turn starting without a client push
  // is exactly what produces a push with no preceding local `prompt/1`).
  it('turnStartedAt anchors on the busy rising edge and clears on the busy push going false', () => {
    const { fake, store } = runningStore();
    expect(store.turnStartedAt).toBeNull();

    store.prompt('go');
    const anchored = store.turnStartedAt;
    expect(anchored).not.toBeNull();

    // Mid-turn items must not re-anchor the timer.
    fake.emit('event', { seq: 1, item: { id: 'm1', type: 'thought', text: 'hmm' } });
    expect(store.turnStartedAt).toBe(anchored);

    fake.emit('busy', { busy: false });
    expect(store.turnStartedAt).toBeNull();
  });
});
