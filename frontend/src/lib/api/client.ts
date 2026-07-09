// This is the ONLY module allowed to import `./ash_rpc` — every other module
// consumes the wrapped `api` object below (grep-able boundary).
import {
  getWorkspace as httpGetWorkspace,
  getWorkspaceChannel,
  createWorkspace as httpCreateWorkspace,
  createWorkspaceChannel,
  openWorkspace as httpOpenWorkspace,
  openWorkspaceChannel,
  recentWorkspaces as httpRecentWorkspaces,
  recentWorkspacesChannel,
  inspectWorkspace as httpInspectWorkspace,
  inspectWorkspaceChannel,
  icmTree as httpIcmTree,
  icmTreeChannel,
  icmPage as httpIcmPage,
  icmPageChannel,
  cockpitToday as httpCockpitToday,
  cockpitTodayChannel
} from './ash_rpc';
import type { AshRpcError } from './ash_types';
import { connectSocket, getRpcChannel } from '../socket';

export type ApiResult<T> = { ok: true; data: T } | { ok: false; error: string };

/**
 * Envelope shape shared by every generated RPC function/channel result:
 * `{ success: true, data }` or `{ success: false, errors: AshRpcError[] }`.
 */
type Envelope<T> = { success: true; data: T } | { success: false; errors: AshRpcError[] };

function toApiResult<T>(envelope: Envelope<T>): ApiResult<T> {
  if (envelope.success) return { ok: true, data: envelope.data };

  const first = envelope.errors[0];
  const error = first?.type || first?.message || 'unknown_error';
  return { ok: false, error };
}

/**
 * True when the socket is connected and the shared rpc channel has finished
 * joining — the only case where channel transport is usable. Everything else
 * (socket never connected, still joining, join failed) falls back to HTTP.
 */
function channelAvailable(): ReturnType<typeof getRpcChannel> | undefined {
  const socket = connectSocket();
  if (!socket.isConnected()) return undefined;

  const channel = getRpcChannel();
  return channel && channel.state === 'joined' ? channel : undefined;
}

/**
 * Runs an RPC action via the shared channel when available, otherwise falls
 * back to the HTTP variant. Both paths resolve to the same envelope shape, so
 * they're normalized once here.
 */
function runRpc<T>(
  runChannel: (channel: NonNullable<ReturnType<typeof channelAvailable>>) => Promise<Envelope<T>>,
  runHttp: () => Promise<Envelope<T>>
): Promise<ApiResult<T>> {
  const channel = channelAvailable();

  const promise = channel
    ? new Promise<Envelope<T>>((resolve) => {
        runChannel(channel).then(resolve);
      })
    : runHttp();

  return promise.then(toApiResult);
}

// The generated `*Channel` functions are push-and-callback style (they call
// `resultHandler`/`errorHandler` rather than returning a promise), so each is
// wrapped into a promise here to match the HTTP functions' shape.

function callGetWorkspaceChannel(channel: NonNullable<ReturnType<typeof channelAvailable>>) {
  return new Promise<Envelope<unknown>>((resolve) => {
    getWorkspaceChannel({ channel, resultHandler: resolve, errorHandler: (error) => resolve({ success: false, errors: [error] }) });
  });
}

function callCreateWorkspaceChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { parentDir: string; name: string }
) {
  return new Promise<Envelope<unknown>>((resolve) => {
    createWorkspaceChannel({ channel, input, resultHandler: resolve, errorHandler: (error) => resolve({ success: false, errors: [error] }) });
  });
}

function callOpenWorkspaceChannel(channel: NonNullable<ReturnType<typeof channelAvailable>>, input: { path: string }) {
  return new Promise<Envelope<unknown>>((resolve) => {
    openWorkspaceChannel({ channel, input, resultHandler: resolve, errorHandler: (error) => resolve({ success: false, errors: [error] }) });
  });
}

function callRecentWorkspacesChannel(channel: NonNullable<ReturnType<typeof channelAvailable>>) {
  return new Promise<Envelope<unknown>>((resolve) => {
    recentWorkspacesChannel({ channel, resultHandler: resolve, errorHandler: (error) => resolve({ success: false, errors: [error] }) });
  });
}

function callInspectWorkspaceChannel(channel: NonNullable<ReturnType<typeof channelAvailable>>, input: { path: string }) {
  return new Promise<Envelope<unknown>>((resolve) => {
    inspectWorkspaceChannel({ channel, input, resultHandler: resolve, errorHandler: (error) => resolve({ success: false, errors: [error] }) });
  });
}

function callIcmTreeChannel(channel: NonNullable<ReturnType<typeof channelAvailable>>) {
  return new Promise<Envelope<unknown>>((resolve) => {
    icmTreeChannel({ channel, resultHandler: resolve, errorHandler: (error) => resolve({ success: false, errors: [error] }) });
  });
}

function callIcmPageChannel(channel: NonNullable<ReturnType<typeof channelAvailable>>, input: { path: string }) {
  return new Promise<Envelope<unknown>>((resolve) => {
    icmPageChannel({ channel, input, resultHandler: resolve, errorHandler: (error) => resolve({ success: false, errors: [error] }) });
  });
}

function callCockpitTodayChannel(channel: NonNullable<ReturnType<typeof channelAvailable>>) {
  return new Promise<Envelope<unknown>>((resolve) => {
    cockpitTodayChannel({ channel, resultHandler: resolve, errorHandler: (error) => resolve({ success: false, errors: [error] }) });
  });
}

export const api = {
  getWorkspace: () => runRpc(callGetWorkspaceChannel, () => httpGetWorkspace({})),

  createWorkspace: (parentDir: string, name: string) =>
    runRpc(
      (channel) => callCreateWorkspaceChannel(channel, { parentDir, name }),
      () => httpCreateWorkspace({ input: { parentDir, name } })
    ),

  openWorkspace: (path: string) =>
    runRpc(
      (channel) => callOpenWorkspaceChannel(channel, { path }),
      () => httpOpenWorkspace({ input: { path } })
    ),

  recentWorkspaces: () => runRpc(callRecentWorkspacesChannel, () => httpRecentWorkspaces({})),

  inspectWorkspace: (path: string) =>
    runRpc(
      (channel) => callInspectWorkspaceChannel(channel, { path }),
      () => httpInspectWorkspace({ input: { path } })
    ),

  icmTree: () => runRpc(callIcmTreeChannel, () => httpIcmTree({})),

  icmPage: (path: string) =>
    runRpc(
      (channel) => callIcmPageChannel(channel, { path }),
      () => httpIcmPage({ input: { path } })
    ),

  cockpitToday: () => runRpc(callCockpitTodayChannel, () => httpCockpitToday({}))
};

export type Api = typeof api;
