import type { Channel } from 'phoenix';
import { joinAgentSession } from '../socket';

/**
 * One rendered item in an agent session's timeline. Backend items are raw
 * string-keyed maps from `Valea.Acp.Connection` (always carry `id`/`type`,
 * plus type-specific fields) — `seq` is attached separately by the channel
 * transport (see class doc) rather than living on the item itself, so it's
 * optional here.
 */
export type AcpItem = { seq?: number; id: string; type: string; [k: string]: unknown };

export type AgentSessionStatus = 'connecting' | 'starting' | 'running' | 'exited' | 'failed' | 'ended';

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
 *  - `busy` is seeded from `reply.busy` AFTER the snapshot replay loop runs
 *    (which may itself have cleared `busy` via a completed `turn` item in the
 *    snapshot) — the server's `busy` flag is authoritative on every
 *    join/rejoin, exactly as the donor's own comment describes.
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

  #channel: Channel;
  #byId = new Map<string, AcpItem>();
  #cursor = 0;
  #initialPrompt: string | null;

  constructor(id: string, opts: { initialPrompt?: string | null } = {}, join: JoinFn = joinAgentSession) {
    this.#initialPrompt = opts.initialPrompt ?? null;
    this.#channel = join(id);

    this.#channel.on('event', (payload: { seq: number; item: AcpItem }) => {
      this.#upsert({ ...payload.item, seq: payload.seq });
    });
    this.#channel.on('status', (payload: { status: string }) => {
      this.status = payload.status as AgentSessionStatus;
    });
    this.#channel.on('exit', () => {
      this.status = 'exited';
    });

    this.#channel
      .join()
      .receive('ok', (reply: { items?: AcpItem[]; cursor?: number; busy?: boolean; status?: string }) => {
        for (const item of reply.items ?? []) this.#upsert(item);
        // Explicit assignment (not folded into #upsert's per-item max) since
        // snapshot items don't carry their own seq — see class doc.
        this.#cursor = Math.max(this.#cursor, reply.cursor ?? 0);
        // Seeded AFTER the replay loop above, so it wins over any `busy =
        // false` the loop applied for a completed `turn` item already in the
        // snapshot — see class doc.
        this.busy = reply.busy ?? false;
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

    this.#byId.set(item.id, item);
    if (typeof item.seq === 'number') this.#cursor = Math.max(this.#cursor, item.seq);

    // The backend emits a `turn` item on every turn completion (success and
    // error alike) — clearing busy only on that type is sufficient; no other
    // item type touches it (see AgentSessionStore.prompt for the raising
    // edge).
    if (item.type === 'turn') this.busy = false;

    this.#rebuild();
  }

  #rebuild(): void {
    this.items = [...this.#byId.values()].sort((a, b) => (a.seq ?? 0) - (b.seq ?? 0));
  }

  /**
   * Sends a prompt and raises `busy` immediately (not waiting for a server
   * echo) so the UI's busy->idle falling edge fires even for an instant
   * turn — the queue drains on turn completion (see `#upsert`), never
   * strands.
   */
  prompt(content: string): void {
    this.busy = true;
    this.#channel.push('prompt', { content });
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
