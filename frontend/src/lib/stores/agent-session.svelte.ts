import type { Channel } from 'phoenix';
import { joinAgentSession } from '../socket';
import { configCurrent, configOptions, configWireId } from '../components/agent/item-shapes';

/**
 * One rendered item in an agent session's timeline. Backend items are raw
 * string-keyed maps from `Valea.Acp.Connection` (always carry `id`/`type`,
 * plus type-specific fields) — `seq` is attached separately by the channel
 * transport (see class doc) rather than living on the item itself, so it's
 * optional here.
 */
export type AcpItem = { seq?: number; id: string; type: string; [k: string]: unknown };

export type AgentSessionStatus = 'connecting' | 'starting' | 'running' | 'exited' | 'failed' | 'ended';

/** The statuses that mean the session is over — no more `busy` pushes are coming. See the `busy` backstop in the class doc. */
const TERMINAL_STATUSES: ReadonlySet<AgentSessionStatus> = new Set(['exited', 'failed', 'ended']);

/** One client-side queued message, editable until it is actually sent. */
export type QueuedMessage = { id: string; text: string };

type JoinFn = (id: string) => Channel;

/**
 * Live view of one agent session, backed by `agent_session:<id>` (see
 * `ValeaWeb.AgentSessionChannel`). Ported from legend's `acpSession.svelte.ts`
 * donor to this project's channel contract and Svelte-5-class-store
 * convention (cf. `PageEditorStore`).
 *
 * Contract differences from the donor worth calling out:
 *  - The join reply's `items` (from `SessionServer.attach/1` or the
 *    transcript replay) do NOT carry a `seq` per item — only the reply's own
 *    top-level `cursor` does. Only live `event` pushes carry `{seq, item}`.
 *    `#upsert` therefore only dedups/advances the cursor off `item.seq` when
 *    it's actually present; snapshot items are merged unconditionally by id.
 *  - `busy` is the SERVER's answer, not an inference: seeded from
 *    `reply.busy` at join and updated by the `busy` push on every
 *    transition the server's own state machine actually makes
 *    (`maybe_broadcast_busy/1` in `SessionServer` pushes on CHANGE only).
 *    `prompt/1` still raises it optimistically so the box reacts to your own
 *    send without a round trip; ordinarily the next server push corrects it
 *    if that guess was ever wrong. But a session whose server-side `busy?`
 *    never became `true` in the first place — an adapter that fails its
 *    handshake before any turn starts is the case that bit — never gets a
 *    `false` push either, since there is no change to broadcast. A terminal
 *    `status` (`exited`/`failed`/`ended`) and the `exit` push are the
 *    client-side backstop for exactly that: whichever fires, `#setBusy(false)`
 *    clears an optimistic raise the server never learned about.
 *
 * Third constructor argument (`join`) is dependency injection purely for
 * tests — mirrors `PageEditorStore`/`WorkspaceStore` taking their API surface
 * as a constructor argument rather than importing a singleton, so tests can
 * hand this a fake `Channel` (fake `.on`/`.join`/`.push`/`.leave`) instead of
 * opening a real socket. Real call sites just do `new AgentSessionStore(id)`.
 *
 * Second constructor argument (`opts.initialPrompt`) is the "Start a
 * session with this page" handoff (`initial-prompt.ts`) — a composed
 * opening prompt to push as the first user turn the moment the join
 * succeeds. Pushed at most once per store instance: cleared to `null`
 * right after firing, so a Phoenix auto-rejoin (which redelivers the join
 * reply through the same `.receive('ok', ...)` callback — see
 * `agent-session.test.ts`'s "replay merge is idempotent" case) never
 * re-sends it.
 */
export class AgentSessionStore {
  items: AcpItem[] = $state([]);
  status: AgentSessionStatus = $state('connecting');
  busy = $state(false);
  error: string | null = $state(null);
  /**
   * Messages sent while a turn was in flight (`send/1`), held client-side so
   * they stay editable/dismissable until the turn ends — then flushed in
   * order (`#flushQueue`). The first flushed prompt starts the next turn;
   * the rest ride the server's own prompt queue
   * (`SessionServer.send_or_queue`), one turn at a time.
   */
  queued: QueuedMessage[] = $state([]);
  /** Epoch ms of the current turn's busy rising edge — drives the composer's turn timer. */
  turnStartedAt: number | null = $state(null);

  #channel: Channel;
  #byId = new Map<string, AcpItem>();
  /**
   * id -> the seq the item FIRST arrived at, which is its position in the
   * conversation. Items are upserted in place (a tool call announced, then
   * completed; a message accumulating chunks), and every such update carries
   * a fresh, higher seq — so ordering on the LATEST seq would drag an item
   * down the timeline every time it changed, dropping a long-running tool's
   * card below whatever the agent said while it ran. Snapshot items carry no
   * seq at all (see class doc) and record 0, which keeps them ahead of every
   * live push in their replayed (backend timeline) order.
   */
  #firstSeq = new Map<string, number>();
  #cursor = 0;
  #initialPrompt: string | null;
  #queueCounter = 0;
  /**
   * Config the caller wants this session to START with — the workspace's
   * remembered chips, staged at creation (`composer-options.svelte.ts`).
   * Keys are wire ids; each is applied at most once, the first time its
   * config item arrives, then removed. Empty for every session this client
   * did not just create, which is how a RESUMED session keeps its own
   * configuration.
   */
  #applyConfig: Record<string, string>;

  constructor(
    id: string,
    opts: { initialPrompt?: string | null; applyConfig?: Record<string, string> | null } = {},
    join: JoinFn = joinAgentSession
  ) {
    this.#initialPrompt = opts.initialPrompt ?? null;
    this.#applyConfig = { ...(opts.applyConfig ?? {}) };
    this.#channel = join(id);

    this.#channel.on('event', (payload: { seq: number; item: AcpItem }) => {
      this.#upsert({ ...payload.item, seq: payload.seq });
    });
    this.#channel.on('status', (payload: { status: string }) => {
      this.status = payload.status as AgentSessionStatus;
      // Backstop for an optimistic `prompt/1` raise the server never learned
      // about — see class doc. `maybe_broadcast_busy/1` only pushes on a
      // CHANGE, so a session that fails before its `busy?` ever became
      // `true` server-side (a handshake timeout is the case that bit) sends
      // this terminal status but no matching `busy: false`.
      if (TERMINAL_STATUSES.has(this.status)) this.#setBusy(false);
    });
    this.#channel.on('exit', () => {
      this.status = 'exited';
      // Same backstop as the terminal-status branch above, for the one
      // terminal transition that arrives on its own push instead of through
      // `status`.
      this.#setBusy(false);
    });
    // Authoritative (see the class doc). The join reply carries the value at
    // attach time; this carries every change after it.
    this.#channel.on('busy', (payload: { busy: boolean }) => {
      this.#setBusy(payload.busy === true);
    });

    this.#channel
      .join()
      .receive('ok', (reply: { items?: AcpItem[]; cursor?: number; busy?: boolean; status?: string }) => {
        for (const item of reply.items ?? []) this.#upsert(item);
        // Explicit assignment (not folded into #upsert's per-item max) since
        // snapshot items don't carry their own seq — see class doc.
        this.#cursor = Math.max(this.#cursor, reply.cursor ?? 0);
        // The server's answer at join time — see class doc. The replay loop
        // above no longer touches `busy` at all (see `#upsert`), so there is
        // nothing left for this seed to "win" over; it simply sets the
        // starting value.
        this.#setBusy(reply.busy ?? false);
        if (reply.status) this.status = reply.status as AgentSessionStatus;

        // Fire the handed-off opening prompt (see class doc) exactly once —
        // nulled immediately so a redelivered join reply on auto-rejoin
        // never re-sends it.
        if (this.#initialPrompt) {
          this.prompt(this.#initialPrompt);
          this.#initialPrompt = null;
        }
      })
      .receive('error', (payload: { reason?: string } | undefined) => {
        this.error = payload?.reason ?? 'join_failed';
        this.status = 'failed';
      });
  }

  /**
   * Merges one item into the timeline. Dedups a live `event` push against
   * one already applied (`item.seq <= cursor` for a known id) — the backend
   * itself only forwards `event` pushes with `seq > cursor-at-join`, so this
   * is defensive for the rejoin/reconnect case. Snapshot items (no `seq`)
   * always merge, which makes re-feeding the same snapshot on a rejoin
   * idempotent (same id -> same Map slot -> same rebuilt array).
   */
  #upsert(item: AcpItem): void {
    if (typeof item.seq === 'number' && item.seq <= this.#cursor && this.#byId.has(item.id)) return;

    if (!this.#firstSeq.has(item.id)) this.#firstSeq.set(item.id, item.seq ?? 0);
    this.#byId.set(item.id, item);
    if (typeof item.seq === 'number') this.#cursor = Math.max(this.#cursor, item.seq);

    // NOTHING here touches `busy` any more. Inferring it from item types is
    // exactly the bug this replaced: raising on any message/thought/tool
    // item meant a tool update that arrived AFTER its turn ended — a subtask
    // finishing out of band — re-raised it with no `turn` item left to lower
    // it, stranding the composer's working indicator until a rejoin. The
    // server broadcasts every transition (`SessionServer.maybe_broadcast_busy/1`).
    //
    // The `turn` item still drives the CLIENT QUEUE below: that is about
    // when locally-held messages may go, not about what the agent is doing.

    if (item.type === 'config') this.#applyStagedConfig(item);

    this.#rebuild();

    if (item.type === 'turn') this.#flushQueue();
  }

  /** Single writer for `busy`, so the turn timer's anchor stays in lockstep. */
  #setBusy(value: boolean): void {
    if (value && !this.busy) this.turnStartedAt = Date.now();
    if (!value) this.turnStartedAt = null;
    this.busy = value;
  }

  /**
   * Fires on the `turn` item that ends the previous turn. `busy` is
   * necessarily still `true` at this point — the server always appends that
   * item (and broadcasts it) BEFORE it broadcasts the matching `busy: false`
   * for the same turn, and that trailing push hasn't been processed yet when
   * this handler runs. So an optimistic `#setBusy(true)` on this path would
   * be a no-op (see `#setBusy`: raising an already-true value touches
   * nothing) — this pushes WITHOUT one, so that redundancy stays explicit
   * rather than silently relying on it, and `prompt/1` stays the ONE place
   * that actually raises optimistically. The server's own `busy` pushes are
   * the only thing that move `busy` on this path: `false` for the turn that
   * just ended, then `true` once the flushed prompt's new turn is under way.
   */
  #flushQueue(): void {
    if (this.queued.length === 0) return;
    const pending = this.queued;
    this.queued = [];
    for (const message of pending) this.#pushPrompt(message.text);
  }

  /** The wire push `prompt/1` and `#flushQueue` share — see both for why they raise `busy` differently around it. */
  #pushPrompt(content: string): void {
    this.#channel.push('prompt', { content });
  }

  /**
   * Pushes this session's staged value for `item`, if it still makes sense.
   *
   * Three gates, each of which has to hold or the push is dropped rather
   * than sent and refused: the wire id must be staged, the value must
   * actually differ from what the adapter already has, and it must still be
   * among the options this adapter offers — a model the harness has since
   * retired is forgotten here rather than pushed and rejected.
   *
   * The key is removed either way, so an option is attempted at most once
   * per session: `set_config_option` re-emits the item, and re-reading a
   * staged value on that echo would loop.
   */
  #applyStagedConfig(item: AcpItem): void {
    const wireId = configWireId(item);
    if (!(wireId in this.#applyConfig)) return;

    const wanted = this.#applyConfig[wireId];
    delete this.#applyConfig[wireId];

    if (wanted === configCurrent(item)) return;
    if (!configOptions(item).some((option) => option.id === wanted)) return;

    this.setConfigOption(wireId, wanted);
  }

  /**
   * Conversation order is FIRST-arrival order (`#firstSeq`), which is exactly
   * the order the backend's own timeline holds items in (`SessionServer`'s
   * `upsert/2` keeps an updated item in its original slot). The sort is
   * stable, so the seq-less snapshot items — all 0 — keep their replayed
   * order among themselves.
   */
  #rebuild(): void {
    this.items = [...this.#byId.values()].sort(
      (a, b) => (this.#firstSeq.get(a.id) ?? 0) - (this.#firstSeq.get(b.id) ?? 0)
    );
  }

  /**
   * Sends a prompt and raises `busy` immediately (not waiting for a server
   * echo) so the UI's busy->idle falling edge fires even for an instant
   * turn — the queue drains on turn completion (see `#upsert`), never
   * strands. Unlike `#flushQueue`'s push, this raise is NOT a no-op: a
   * direct call here (`send/1` while idle, `sendQueuedNow/1`) always starts
   * from `busy === false`, so `#setBusy(true)` genuinely flips it.
   */
  prompt(content: string): void {
    this.#setBusy(true);
    this.#pushPrompt(content);
  }

  /**
   * Queue-aware send — the composer's entry point. While a turn is in
   * flight the message joins `queued` (editable/dismissable, flushed on
   * turn end); otherwise it sends immediately.
   */
  send(content: string): void {
    if (this.busy) {
      this.queued = [...this.queued, { id: `q-${++this.#queueCounter}`, text: content }];
    } else {
      this.prompt(content);
    }
  }

  updateQueued(id: string, text: string): void {
    this.queued = this.queued.map((m) => (m.id === id ? { ...m, text } : m));
  }

  dismissQueued(id: string): void {
    this.queued = this.queued.filter((m) => m.id !== id);
  }

  /**
   * Sends one queued message immediately, disrupting the in-flight turn:
   * cancel rides ahead of the prompt on the same ordered channel, so the
   * agent interrupts, then picks this message up (directly, or via the
   * server's own queue if the cancel is still settling).
   */
  sendQueuedNow(id: string): void {
    const message = this.queued.find((m) => m.id === id);
    if (!message) return;
    this.queued = this.queued.filter((m) => m.id !== id);
    this.cancel();
    this.prompt(message.text);
  }

  cancel(): void {
    this.#channel.push('cancel', {});
  }

  /**
   * Answers a pending permission item. Deliberately does NOT mutate the item
   * locally — the item only reflects `resolved: true` once the server
   * echoes the updated item back over the `event` push (see `#upsert`),
   * so a rejected/failed push never leaves the UI showing a resolution that
   * didn't actually happen.
   */
  answerPermission(itemId: string, kind: string): void {
    this.#channel.push('permission', { item_id: itemId, kind });
  }

  setConfigOption(configId: string, value: unknown): void {
    this.#channel.push('set_config_option', { config_id: configId, value });
  }

  stop(): void {
    this.#channel.push('stop', {});
  }

  /** Caller-owned teardown — leaves the channel (see `joinAgentSession`). */
  dispose(): void {
    this.#channel.leave();
  }
}
