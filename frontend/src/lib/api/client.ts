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

  // Channel-level (non-RPC) failures — e.g. the synthesized `channel_timeout`
  // envelope below, or a raw Phoenix channel error payload — don't carry the
  // full `AshRpcError` shape guaranteed by the backend. They're intentionally
  // normalized lossily to 'unknown_error' when neither `type` nor `message`
  // is present, rather than trying to reconstruct a richer error.
  const first = envelope.errors[0];
  const error = first?.type || first?.message || 'unknown_error';
  return { ok: false, error };
}

/** Synthesized `AshRpcError` for a channel push that never got a response. */
const channelTimeoutError: AshRpcError = {
  type: 'channel_timeout',
  message: 'channel_timeout',
  shortMessage: 'channel_timeout',
  vars: {},
  fields: [],
  path: []
};

const channelTimeoutEnvelope: Envelope<never> = { success: false, errors: [channelTimeoutError] };

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
// `resultHandler`/`errorHandler`/`timeoutHandler` rather than returning a
// promise), so each is wrapped into a promise here to match the HTTP
// functions' shape. `wrapChannelCall` is the one place all three handlers are
// defined — every call site below just supplies the generated function.
//
// A `timeoutHandler` is mandatory: without one, the generated push helper
// only `console.error`s on a Phoenix channel "timeout" reply and the
// promise below would never settle, hanging every awaiting store forever.
function wrapChannelCall<T>(
  run: (handlers: {
    resultHandler: (result: Envelope<T>) => void;
    errorHandler: (error: AshRpcError) => void;
    timeoutHandler: () => void;
  }) => void
): Promise<Envelope<T>> {
  return new Promise<Envelope<T>>((resolve) => {
    run({
      resultHandler: resolve,
      errorHandler: (error) => resolve({ success: false, errors: [error] }),
      timeoutHandler: () => resolve(channelTimeoutEnvelope)
    });
  });
}

function callGetWorkspaceChannel(channel: NonNullable<ReturnType<typeof channelAvailable>>) {
  return wrapChannelCall((handlers) => getWorkspaceChannel({ channel, ...handlers }));
}

function callCreateWorkspaceChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { parentDir: string; name: string }
) {
  return wrapChannelCall((handlers) => createWorkspaceChannel({ channel, input, ...handlers }));
}

function callOpenWorkspaceChannel(channel: NonNullable<ReturnType<typeof channelAvailable>>, input: { path: string }) {
  return wrapChannelCall((handlers) => openWorkspaceChannel({ channel, input, ...handlers }));
}

function callRecentWorkspacesChannel(channel: NonNullable<ReturnType<typeof channelAvailable>>) {
  return wrapChannelCall((handlers) => recentWorkspacesChannel({ channel, ...handlers }));
}

function callInspectWorkspaceChannel(channel: NonNullable<ReturnType<typeof channelAvailable>>, input: { path: string }) {
  return wrapChannelCall((handlers) => inspectWorkspaceChannel({ channel, input, ...handlers }));
}

function callIcmTreeChannel(channel: NonNullable<ReturnType<typeof channelAvailable>>) {
  return wrapChannelCall((handlers) => icmTreeChannel({ channel, ...handlers }));
}

function callIcmPageChannel(channel: NonNullable<ReturnType<typeof channelAvailable>>, input: { path: string }) {
  return wrapChannelCall((handlers) => icmPageChannel({ channel, input, ...handlers }));
}

function callCockpitTodayChannel(channel: NonNullable<ReturnType<typeof channelAvailable>>) {
  return wrapChannelCall((handlers) => cockpitTodayChannel({ channel, ...handlers }));
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
