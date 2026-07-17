import { Socket, type Channel } from 'phoenix';

declare global {
  interface Window {
    __VALEA_CONTROL_TOKEN?: string;
  }
}

/**
 * Per-launch loopback control token. In production the desktop shell injects
 * `window.__VALEA_CONTROL_TOKEN` via an init script; in browser dev it comes
 * from the Vite env, falling back to the backend's fixed dev default. The
 * backend gates `/rpc/*` and the socket on it (see ValeaWeb.Plugs.ControlToken).
 */
export function controlToken(): string {
  return (
    (typeof window !== 'undefined' && window.__VALEA_CONTROL_TOKEN) ||
    import.meta.env.VITE_VALEA_CONTROL_TOKEN ||
    'valea-dev-token'
  );
}

/**
 * Lazily-connected singleton Phoenix socket at `/socket`. Carries the control
 * token as a connect param — Vite proxies `/socket` to the backend in dev.
 */
let socket: Socket | undefined;

export function connectSocket(): Socket {
  if (!socket) {
    socket = new Socket('/socket', { params: { token: controlToken() } });
    socket.connect();
  }
  return socket;
}

/**
 * Shared `ash_typescript_rpc:client` channel, joined once and reused by
 * `client.ts` for channel-transport RPC pushes. Returns `undefined` until the
 * join actually succeeds (or if it later errors/closes), so callers can fall
 * back to HTTP.
 */
let rpcChannel: Channel | undefined;
let rpcChannelJoinFailed = false;

export function getRpcChannel(): Channel | undefined {
  if (rpcChannel || rpcChannelJoinFailed) return rpcChannel;

  const sock = connectSocket();
  const channel = sock.channel('ash_typescript_rpc:client', {});

  channel
    .join()
    .receive('ok', () => {
      rpcChannel = channel;
    })
    .receive('error', () => {
      rpcChannelJoinFailed = true;
    });

  channel.onError(() => {
    rpcChannel = undefined;
  });
  channel.onClose(() => {
    rpcChannel = undefined;
  });

  return rpcChannel;
}

/**
 * Fresh channel at topic `agent_session:<id>`, one per session — unlike
 * `getRpcChannel`/`joinWorkspaceEvents`'s shared/singleton channels, callers
 * (see `AgentSessionStore`) legitimately need one live channel per open
 * session, so this always creates a new one rather than caching by id.
 *
 * Deliberately does NOT call `.join()` — `AgentSessionStore` needs to attach
 * its `.on(...)` listeners first, then call `.join().receive('ok', ...)`
 * itself to read the join reply's `{items, cursor, busy, status}` snapshot
 * (mirroring the donor `acpSession` module this is ported from). The caller
 * also owns `.leave()` (see `AgentSessionStore.dispose`) — this function
 * never closes a channel it opens.
 */
export function joinAgentSession(id: string): Channel {
  const sock = connectSocket();
  return sock.channel(`agent_session:${id}`, {});
}

export type WorkspaceEventPayload = { open: boolean; name?: string; path?: string; generation?: number };

/**
 * `mail_status` push payload (`ValeaWeb.WorkspaceEventsChannel`'s
 * `{:mail_status_changed, slug, status}` clause) — ONE account's
 * `Valea.Mail.Engine.status/1` map, string-keyed via the channel's own
 * `stringify/1` with the account slug added under `account`. Unlike every
 * other push handled here, this one is NOT camelCased by ash_typescript —
 * the channel builds this payload itself rather than relaying a generated
 * RPC result, so the field names stay exactly as
 * `Valea.Mail.Engine.build_status/1` writes them: snake_case (mirrors the
 * per-account entries of `mail_status`'s RPC `accounts` return — see
 * `MailStatusFields` in `api/ash_rpc.ts`). `credential` is `'present' |
 * 'missing'`; `state` is `'idle' | 'inactive' | 'syncing' | 'auth_failed' |
 * 'identity_mismatch' | 'mailbox_replaced'` — both left as plain `string`
 * here, same as the Elixir `@type status` moduledoc note (no
 * singleton-string literal type in Dialyzer, so the backend doesn't promise
 * a closed set at the type level either). `stores/mail.svelte.ts`'s
 * `normalizeMailAccountStatus` narrows/camelCases this into the app-facing
 * `MailAccountStatus` shape. Engines exist only for VALID config entries,
 * so pushes never carry the RPC's `valid: false`/`reason` variant.
 */
export type MailStatusPush = {
  account: string;
  configured: boolean;
  credential: string;
  state: string;
  last_sync_at: string | null;
  last_error: string | null;
  /** IMAP login (`imap.username`), distinct from `account` (the slug) — display only; the keychain key is slug-based. */
  username: string | null;
  workspace_id: string | null;
  pending_ops: number;
  held_folders: string[];
  backfill: Record<string, boolean> | null;
  notices: string[];
};

/** `mail_sync` push payload — `{:mail_sync_started, slug}` / `{:mail_sync_finished, slug, ...}`. */
export type MailSyncPush = { account: string; phase: 'started' | 'finished'; newMessages: number };

/** `mail_message` push payload — one account's message file was created/updated on disk (`SyncPass`). */
export type MailMessagePush = { account: string; path: string };

export function joinWorkspaceEvents(handlers: {
  onWorkspace?: (payload: WorkspaceEventPayload) => void;
  onIcmChanged?: () => void;
  onMountsChanged?: () => void;
  onMailStatus?: (payload: MailStatusPush) => void;
  onMailSync?: (payload: MailSyncPush) => void;
  onMailMessage?: (payload: MailMessagePush) => void;
}): Channel {
  const sock = connectSocket();
  const channel = sock.channel('workspace:events', {});

  if (handlers.onWorkspace) {
    channel.on('workspace', (payload: WorkspaceEventPayload) => handlers.onWorkspace?.(payload));
  }
  if (handlers.onIcmChanged) {
    channel.on('icm_changed', () => handlers.onIcmChanged?.());
  }
  if (handlers.onMountsChanged) {
    channel.on('mounts_changed', () => handlers.onMountsChanged?.());
  }
  if (handlers.onMailStatus) {
    channel.on('mail_status', (payload: MailStatusPush) => handlers.onMailStatus?.(payload));
  }
  if (handlers.onMailSync) {
    channel.on('mail_sync', (payload: MailSyncPush) => handlers.onMailSync?.(payload));
  }
  if (handlers.onMailMessage) {
    channel.on('mail_message', (payload: MailMessagePush) => handlers.onMailMessage?.(payload));
  }

  channel.join();
  return channel;
}
