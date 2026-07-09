import { Socket, type Channel } from 'phoenix';

/**
 * Lazily-connected singleton Phoenix socket at `/socket`. Local-first app,
 * no auth params — Vite proxies `/socket` to the backend in dev.
 */
let socket: Socket | undefined;

export function connectSocket(): Socket {
  if (!socket) {
    socket = new Socket('/socket', {});
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

export type WorkspaceEventPayload = { open: boolean; name?: string; path?: string };

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
