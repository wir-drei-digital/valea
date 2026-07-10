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

export function joinWorkspaceEvents(handlers: {
  onWorkspace?: (payload: WorkspaceEventPayload) => void;
  onIcmChanged?: () => void;
}): Channel {
  const sock = connectSocket();
  const channel = sock.channel('workspace:events', {});

  if (handlers.onWorkspace) {
    channel.on('workspace', (payload: WorkspaceEventPayload) => handlers.onWorkspace?.(payload));
  }
  if (handlers.onIcmChanged) {
    channel.on('icm_changed', () => handlers.onIcmChanged?.());
  }

  channel.join();
  return channel;
}
