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
  saveIcmPage as httpSaveIcmPage,
  saveIcmPageChannel,
  createIcmPage as httpCreateIcmPage,
  createIcmPageChannel,
  createIcmFolder as httpCreateIcmFolder,
  createIcmFolderChannel,
  renameIcmEntry as httpRenameIcmEntry,
  renameIcmEntryChannel,
  deleteIcmEntry as httpDeleteIcmEntry,
  deleteIcmEntryChannel,
  icmEntryReferences as httpIcmEntryReferences,
  icmEntryReferencesChannel,
  cockpitToday as httpCockpitToday,
  cockpitTodayChannel
} from './ash_rpc';
import type { AshRpcError } from './ash_types';
import type {
  SaveIcmPageFields,
  CreateIcmPageFields,
  CreateIcmFolderFields,
  RenameIcmEntryFields,
  DeleteIcmEntryFields,
  IcmEntryReferencesFields
} from './ash_rpc';
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

// The generated typed actions below reject an empty/omitted `fields` array
// with `empty_fields_array` — every call site (channel + HTTP) must pass a
// complete field list matching what these wrappers report back to callers.
const saveIcmPageFields: SaveIcmPageFields = ['hash', 'savedAt'];
const createIcmPageFields: CreateIcmPageFields = ['path'];
const createIcmFolderFields: CreateIcmFolderFields = ['path'];
const renameIcmEntryFields: RenameIcmEntryFields = ['path', 'updatedWorkflows'];
const deleteIcmEntryFields: DeleteIcmEntryFields = ['deleted'];
// Note: the generated `IcmEntryReferencesFields` type can't actually express
// nested field selection into an `Array<TypedMap>` (a real ash_typescript
// codegen gap for anonymous embedded-map arrays, not a Resource
// relationship) — `ComplexFieldSelection` only special-cases Relationship /
// ComplexCalculation / direct-TypedMap / Union arrays, so `ArrayOf<TypedMap>`
// falls through to `never`. The backend action itself DOES accept this exact
// nested literal (confirmed in Task 5), so the assertion below is trusted
// runtime knowledge overriding an incomplete generated type, not a guess.
const icmEntryReferencesFields = [{ workflows: ['file', 'name'] }] as unknown as IcmEntryReferencesFields;

function callSaveIcmPageChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { path: string; prosemirror: Record<string, any>; baseHash: string }
) {
  return wrapChannelCall((handlers) => saveIcmPageChannel({ channel, input, fields: saveIcmPageFields, ...handlers }));
}

function callCreateIcmPageChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { parentPath: string; name: string }
) {
  return wrapChannelCall((handlers) =>
    createIcmPageChannel({ channel, input, fields: createIcmPageFields, ...handlers })
  );
}

function callCreateIcmFolderChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { parentPath: string; name: string }
) {
  return wrapChannelCall((handlers) =>
    createIcmFolderChannel({ channel, input, fields: createIcmFolderFields, ...handlers })
  );
}

function callRenameIcmEntryChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { path: string; newName: string }
) {
  return wrapChannelCall((handlers) =>
    renameIcmEntryChannel({ channel, input, fields: renameIcmEntryFields, ...handlers })
  );
}

function callDeleteIcmEntryChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { path: string }
) {
  return wrapChannelCall((handlers) =>
    deleteIcmEntryChannel({ channel, input, fields: deleteIcmEntryFields, ...handlers })
  );
}

function callIcmEntryReferencesChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { path: string }
) {
  return wrapChannelCall((handlers) =>
    icmEntryReferencesChannel({ channel, input, fields: icmEntryReferencesFields, ...handlers })
  );
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

  cockpitToday: () => runRpc(callCockpitTodayChannel, () => httpCockpitToday({})),

  // `prosemirror` is typed `object` (not `Record<string, any>`) so callers —
  // notably `PageEditorStore`, whose `noteChange(getJson: () => object)` gets
  // its JSON straight from the ProseMirror editor — don't need to assert
  // away the missing index signature just to call this.
  saveIcmPage: (path: string, prosemirror: object, baseHash: string) =>
    runRpc(
      (channel) => callSaveIcmPageChannel(channel, { path, prosemirror: prosemirror as Record<string, any>, baseHash }),
      () =>
        httpSaveIcmPage({
          input: { path, prosemirror: prosemirror as Record<string, any>, baseHash },
          fields: saveIcmPageFields
        })
    ),

  createIcmPage: (parentPath: string, name: string) =>
    runRpc(
      (channel) => callCreateIcmPageChannel(channel, { parentPath, name }),
      () => httpCreateIcmPage({ input: { parentPath, name }, fields: createIcmPageFields })
    ),

  createIcmFolder: (parentPath: string, name: string) =>
    runRpc(
      (channel) => callCreateIcmFolderChannel(channel, { parentPath, name }),
      () => httpCreateIcmFolder({ input: { parentPath, name }, fields: createIcmFolderFields })
    ),

  renameIcmEntry: (path: string, newName: string) =>
    runRpc(
      (channel) => callRenameIcmEntryChannel(channel, { path, newName }),
      () => httpRenameIcmEntry({ input: { path, newName }, fields: renameIcmEntryFields })
    ),

  deleteIcmEntry: (path: string) =>
    runRpc(
      (channel) => callDeleteIcmEntryChannel(channel, { path }),
      () => httpDeleteIcmEntry({ input: { path }, fields: deleteIcmEntryFields })
    ),

  icmEntryReferences: (path: string) =>
    runRpc(
      (channel) => callIcmEntryReferencesChannel(channel, { path }),
      () => httpIcmEntryReferences({ input: { path }, fields: icmEntryReferencesFields })
    )
};

export type Api = typeof api;
