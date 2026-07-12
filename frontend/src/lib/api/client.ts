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
  cockpitTodayChannel,
  createAgentSession as httpCreateAgentSession,
  createAgentSessionChannel,
  listAgentSessions as httpListAgentSessions,
  listAgentSessionsChannel,
  runWorkflow as httpRunWorkflow,
  runWorkflowChannel,
  harnessDoctor as httpHarnessDoctor,
  harnessDoctorChannel,
  listWorkflows as httpListWorkflows,
  listWorkflowsChannel,
  listQueueItems as httpListQueueItems,
  listQueueItemsChannel,
  getQueueItem as httpGetQueueItem,
  getQueueItemChannel,
  approveQueueItem as httpApproveQueueItem,
  approveQueueItemChannel,
  rejectQueueItem as httpRejectQueueItem,
  rejectQueueItemChannel,
  listAuditEntries as httpListAuditEntries,
  listAuditEntriesChannel,
  mailStatus as httpMailStatus,
  mailStatusChannel,
  setupMailAccount as httpSetupMailAccount,
  setupMailAccountChannel,
  setMailCredential as httpSetMailCredential,
  setMailCredentialChannel,
  mailSyncNow as httpMailSyncNow,
  mailSyncNowChannel,
  mailDoctor as httpMailDoctor,
  mailDoctorChannel,
  createMailFolders as httpCreateMailFolders,
  createMailFoldersChannel,
  listMailMessages as httpListMailMessages,
  listMailMessagesChannel,
  getMailMessage as httpGetMailMessage,
  getMailMessageChannel,
  mailInbox as httpMailInbox,
  mailInboxChannel,
  retryMailboxOps as httpRetryMailboxOps,
  retryMailboxOpsChannel,
  listDecidedQueueItems as httpListDecidedQueueItems,
  listDecidedQueueItemsChannel,
  listMounts as httpListMounts,
  listMountsChannel,
  setMountEnabled as httpSetMountEnabled,
  setMountEnabledChannel,
  createMount as httpCreateMount,
  createMountChannel
} from './ash_rpc';
import type { AshRpcError } from './ash_types';
import type {
  CockpitTodayFields,
  SaveIcmPageFields,
  CreateIcmPageFields,
  CreateIcmFolderFields,
  RenameIcmEntryFields,
  DeleteIcmEntryFields,
  IcmEntryReferencesFields,
  CreateAgentSessionFields,
  ListAgentSessionsFields,
  RunWorkflowFields,
  HarnessDoctorFields,
  ListWorkflowsFields,
  ListQueueItemsFields,
  GetQueueItemFields,
  ApproveQueueItemFields,
  RejectQueueItemFields,
  ListAuditEntriesFields,
  MailStatusFields,
  SetupMailAccountFields,
  SetMailCredentialFields,
  MailSyncNowFields,
  MailDoctorFields,
  CreateMailFoldersFields,
  ListMailMessagesFields,
  GetMailMessageFields,
  MailInboxFields,
  RetryMailboxOpsFields,
  ListDecidedQueueItemsFields,
  IcmTreeFields,
  ListMountsFields,
  SetMountEnabledFields,
  CreateMountFields
} from './ash_rpc';
import { connectSocket, getRpcChannel, controlToken } from '../socket';

export type ApiResult<T> = { ok: true; data: T } | { ok: false; error: string };

/**
 * Injects the per-launch control token header into a generated HTTP RPC
 * config. The channel transport carries the token via the socket connect
 * param instead (see `socket.ts`), so only the HTTP fallback path needs this.
 * The backend rejects `/rpc/*` without a matching header (401).
 */
function withAuth<C extends object>(config: C): C & { headers: Record<string, string> } {
  return { ...config, headers: { 'x-valea-token': controlToken() } };
}

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
  return wrapChannelCall((handlers) => icmTreeChannel({ channel, fields: icmTreeFields, ...handlers }));
}

function callIcmPageChannel(channel: NonNullable<ReturnType<typeof channelAvailable>>, input: { path: string }) {
  return wrapChannelCall((handlers) => icmPageChannel({ channel, input, ...handlers }));
}

function callCockpitTodayChannel(channel: NonNullable<ReturnType<typeof channelAvailable>>) {
  return wrapChannelCall((handlers) => cockpitTodayChannel({ channel, fields: cockpitTodayFields, ...handlers }));
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

const createAgentSessionFields: CreateAgentSessionFields = ['id'];
const runWorkflowFields: RunWorkflowFields = ['runId', 'sessionId'];
const getQueueItemFields: GetQueueItemFields = ['item', 'revision'];
const approveQueueItemFields: ApproveQueueItemFields = ['draftPath'];
const rejectQueueItemFields: RejectQueueItemFields = ['rejected'];
const listAuditEntriesFields: ListAuditEntriesFields = ['entries'];

// Same anonymous-embedded-map-array codegen gap as `icmEntryReferencesFields`
// above (see its comment) — each of these nests field selection into an
// `Array<TypedMap>` action-return field, which `ComplexFieldSelection` can't
// express, so the generated `Fields` type collapses to `never` for the
// literal. The backend actions accept these exact nested literals (verified
// by the passing `agents_rpc_test.exs` / `queue_rpc_test.exs` suites).
const listAgentSessionsFields = [
  { sessions: ['id', 'kind', 'title', 'workflow', 'runId', 'startedAt', 'status', 'live'] }
] as unknown as ListAgentSessionsFields;
const harnessDoctorFields = [
  'ok',
  { checks: ['id', 'status', 'detail', 'remedy'] }
] as unknown as HarnessDoctorFields;
const listWorkflowsFields = [
  {
    workflows: [
      'path',
      'name',
      'description',
      'enabled',
      'triggerSource',
      'riskLevel',
      'sourceCount',
      'steps',
      'mount'
    ]
  }
] as unknown as ListWorkflowsFields;
const listQueueItemsFields = [
  { items: ['runId', 'title', 'summary', 'kind', 'riskLevel', 'createdAt', 'workflow', 'valid', 'error'] }
] as unknown as ListQueueItemsFields;

// Cockpit (Task 18 typed the whole `today` action — see `Valea.Api.Cockpit`'s
// moduledoc). Same anonymous-embedded-map-array codegen gap as
// `listWorkflowsFields`/`icmEntryReferencesFields` above (`schedule`/
// `preparedItems`/`openLoops` are `Array<TypedMap>`, and `mail` on top of
// that is a nested `TypedMap` field), so the generated `CockpitTodayFields`
// type can't express this literal either — cast, not inferred. Selects
// every field: `normalizeCockpitToday` (`lib/today/cockpit.ts`) reads the
// whole payload.
const cockpitTodayFields = [
  'workspace',
  'dateLabel',
  'greeting',
  'summary',
  { schedule: ['time', 'title', 'subtitle', 'status'] },
  { preparedItems: ['type', 'title', 'summary', 'usedSources', 'primaryAction', 'secondaryAction'] },
  { openLoops: ['title', 'source'] },
  'whileYouWereAway',
  'triageWorkflowPath',
  { mail: ['reviewCount', 'inboxCount', 'configured'] }
] as unknown as CockpitTodayFields;

// Mail (T13/T14). Every top-level boolean-valued field here (`saved`,
// `accepted`, `started`, `ok`) is delivered under a STRING key by the
// backend (`Valea.Api.Mail`'s moduledoc documents the same falsy-map-field
// ash_typescript 0.17.3 workaround `Valea.Api.Queue` uses) — that's a
// runtime detail only, invisible at this field-selection layer since a JS
// object key is a string either way; no cast needed for these.
const mailStatusFields: MailStatusFields = ['status'];
const setupMailAccountFields: SetupMailAccountFields = ['saved'];
const setMailCredentialFields: SetMailCredentialFields = ['accepted'];
const mailSyncNowFields: MailSyncNowFields = ['started'];
const mailDoctorFields: MailDoctorFields = ['ok', 'checks'];
const createMailFoldersFields: CreateMailFoldersFields = ['created'];
const getMailMessageFields: GetMailMessageFields = ['message', 'inbox'];
const retryMailboxOpsFields: RetryMailboxOpsFields = ['accepted'];
const listDecidedQueueItemsFields: ListDecidedQueueItemsFields = ['items'];

// Mounts (A-T12/A-T14). Same anonymous-embedded-map-array codegen gap as
// `listAgentSessionsFields`/`listWorkflowsFields`/`listQueueItemsFields`
// above (see the comment on `icmEntryReferencesFields`) — `mounts` is an
// `Array<TypedMap>` action-return field, which `ComplexFieldSelection`
// can't express, so the generated `Fields` type collapses to `never` for
// the literal. The backend action accepts this exact nested literal
// (verified by the passing `mounts_rpc_test.exs` suite). `saved`/`relRoot`
// are plain top-level fields (`SetMountEnabledFields`/`CreateMountFields`)
// with no such gap, so no cast is needed for them.
const listMountsFields = [
  { mounts: ['name', 'title', 'description', 'relRoot', 'enabled', 'degraded'] }
] as unknown as ListMountsFields;
const setMountEnabledFields: SetMountEnabledFields = ['saved'];
const createMountFields: CreateMountFields = ['relRoot'];

// `icm_tree` (A-T11). Same anonymous-embedded-map-array codegen gap as
// `listMountsFields` above — `mounts` is an `Array<TypedMap>` action-return
// field. `tree` itself stays an unconstrained `Array<Record<string, any>>`
// (the recursive folder/page tree), so it needs no nested selection of its
// own, just the bare field name.
const icmTreeFields = [{ mounts: ['mount', 'title', 'rootRel', 'tree'] }] as unknown as IcmTreeFields;

// Same anonymous-embedded-map-array codegen gap as `listAgentSessionsFields`/
// `listWorkflowsFields`/`listQueueItemsFields` above (see the comment on
// `icmEntryReferencesFields`) — `messages`/`entries` are `Array<TypedMap>`
// action-return fields, which `ComplexFieldSelection` can't express, so the
// generated `Fields` type collapses to `never` for the literal. The backend
// actions accept these exact nested literals (verified by the passing
// `mail_rpc_test.exs` suite).
const listMailMessagesFields = [
  { messages: ['msgId', 'fromName', 'fromEmail', 'subject', 'date', 'status', 'hasAttachments', 'uid', 'path'] }
] as unknown as ListMailMessagesFields;
const mailInboxFields = [{ entries: ['uid', 'fromText', 'subject', 'date'] }] as unknown as MailInboxFields;

function callCreateAgentSessionChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { kind: string; generation: number }
) {
  return wrapChannelCall((handlers) =>
    createAgentSessionChannel({ channel, input, fields: createAgentSessionFields, ...handlers })
  );
}

function callListAgentSessionsChannel(channel: NonNullable<ReturnType<typeof channelAvailable>>) {
  return wrapChannelCall((handlers) =>
    listAgentSessionsChannel({ channel, fields: listAgentSessionsFields, ...handlers })
  );
}

function callRunWorkflowChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { path: string; input: string; generation: number }
) {
  return wrapChannelCall((handlers) =>
    runWorkflowChannel({ channel, input, fields: runWorkflowFields, ...handlers })
  );
}

function callHarnessDoctorChannel(channel: NonNullable<ReturnType<typeof channelAvailable>>) {
  return wrapChannelCall((handlers) =>
    harnessDoctorChannel({ channel, fields: harnessDoctorFields, ...handlers })
  );
}

function callListWorkflowsChannel(channel: NonNullable<ReturnType<typeof channelAvailable>>) {
  return wrapChannelCall((handlers) =>
    listWorkflowsChannel({ channel, fields: listWorkflowsFields, ...handlers })
  );
}

function callListQueueItemsChannel(channel: NonNullable<ReturnType<typeof channelAvailable>>) {
  return wrapChannelCall((handlers) =>
    listQueueItemsChannel({ channel, fields: listQueueItemsFields, ...handlers })
  );
}

function callGetQueueItemChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { runId: string }
) {
  return wrapChannelCall((handlers) =>
    getQueueItemChannel({ channel, input, fields: getQueueItemFields, ...handlers })
  );
}

function callApproveQueueItemChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { runId: string; revision: string; generation: number }
) {
  return wrapChannelCall((handlers) =>
    approveQueueItemChannel({ channel, input, fields: approveQueueItemFields, ...handlers })
  );
}

function callRejectQueueItemChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { runId: string; revision: string; generation: number }
) {
  return wrapChannelCall((handlers) =>
    rejectQueueItemChannel({ channel, input, fields: rejectQueueItemFields, ...handlers })
  );
}

function callListAuditEntriesChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { limit: number }
) {
  return wrapChannelCall((handlers) =>
    listAuditEntriesChannel({ channel, input, fields: listAuditEntriesFields, ...handlers })
  );
}

function callMailStatusChannel(channel: NonNullable<ReturnType<typeof channelAvailable>>) {
  return wrapChannelCall((handlers) => mailStatusChannel({ channel, fields: mailStatusFields, ...handlers }));
}

function callSetupMailAccountChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { account: string; host: string; port: number; username: string; generation: number }
) {
  return wrapChannelCall((handlers) =>
    setupMailAccountChannel({ channel, input, fields: setupMailAccountFields, ...handlers })
  );
}

function callSetMailCredentialChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { secret: string; generation: number }
) {
  return wrapChannelCall((handlers) =>
    setMailCredentialChannel({ channel, input, fields: setMailCredentialFields, ...handlers })
  );
}

function callMailSyncNowChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { generation: number }
) {
  return wrapChannelCall((handlers) => mailSyncNowChannel({ channel, input, fields: mailSyncNowFields, ...handlers }));
}

function callMailDoctorChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { generation: number }
) {
  return wrapChannelCall((handlers) => mailDoctorChannel({ channel, input, fields: mailDoctorFields, ...handlers }));
}

function callCreateMailFoldersChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { generation: number }
) {
  return wrapChannelCall((handlers) =>
    createMailFoldersChannel({ channel, input, fields: createMailFoldersFields, ...handlers })
  );
}

function callListMailMessagesChannel(channel: NonNullable<ReturnType<typeof channelAvailable>>) {
  return wrapChannelCall((handlers) =>
    listMailMessagesChannel({ channel, fields: listMailMessagesFields, ...handlers })
  );
}

function callGetMailMessageChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { msgId: string }
) {
  return wrapChannelCall((handlers) =>
    getMailMessageChannel({ channel, input, fields: getMailMessageFields, ...handlers })
  );
}

function callMailInboxChannel(channel: NonNullable<ReturnType<typeof channelAvailable>>) {
  return wrapChannelCall((handlers) => mailInboxChannel({ channel, fields: mailInboxFields, ...handlers }));
}

function callRetryMailboxOpsChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { runId: string; generation: number }
) {
  return wrapChannelCall((handlers) =>
    retryMailboxOpsChannel({ channel, input, fields: retryMailboxOpsFields, ...handlers })
  );
}

function callListDecidedQueueItemsChannel(channel: NonNullable<ReturnType<typeof channelAvailable>>) {
  return wrapChannelCall((handlers) =>
    listDecidedQueueItemsChannel({ channel, fields: listDecidedQueueItemsFields, ...handlers })
  );
}

function callListMountsChannel(channel: NonNullable<ReturnType<typeof channelAvailable>>) {
  return wrapChannelCall((handlers) => listMountsChannel({ channel, fields: listMountsFields, ...handlers }));
}

function callSetMountEnabledChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { name: string; enabled: boolean; generation: number }
) {
  return wrapChannelCall((handlers) =>
    setMountEnabledChannel({ channel, input, fields: setMountEnabledFields, ...handlers })
  );
}

function callCreateMountChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { name: string; description: string; generation: number }
) {
  return wrapChannelCall((handlers) =>
    createMountChannel({ channel, input, fields: createMountFields, ...handlers })
  );
}

function callSaveIcmPageChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { path: string; prosemirror: Record<string, any>; baseHash: string; generation?: number | null }
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

/**
 * Typed shape of an `icm_page` RPC result. The backend action returns an
 * unconstrained `:map` (`InferIcmPageResult = Record<string, any>` in the
 * generated client), so this is asserted by `normalizeIcmPage` below rather
 * than inferred by ash_typescript.
 *
 * `frontmatter` is `null` when the page has no leading YAML frontmatter
 * block, or when it has one that failed to parse (see `Valea.ICM.page/1`) —
 * either way the raw view (`content`) still shows everything.
 */
export type IcmPageData = {
  path: string;
  title: string;
  uri: string;
  content: string;
  hash: string;
  prosemirror: Record<string, unknown>;
  frontmatter: Record<string, unknown> | null;
};

/**
 * Normalizes a raw `icm_page` RPC result. This action's own field names
 * (`path`, `title`, `content`, `hash`, `prosemirror`, `frontmatter`) contain
 * no underscores, so — unlike `normalizeIcmNode` in `icm.svelte.ts` — there's
 * no snake/camel dual-casing to reconcile at this level.
 *
 * `frontmatter` is passed through UNTOUCHED, not reshaped key-by-key like
 * the fields above: its keys and nested structure are user-authored YAML
 * from the workflow contract (e.g. `risk_level`, `trigger.source`), not
 * wire-format field names, so camelizing or otherwise renaming them would
 * corrupt what the page actually says. It rides straight from the backend's
 * `YamlElixir.read_from_string/1` output (already string-keyed) to the UI.
 */
export function normalizeIcmPage(raw: Record<string, any>): IcmPageData {
  return {
    path: raw.path,
    title: raw.title,
    uri: raw.uri,
    content: raw.content,
    hash: raw.hash,
    prosemirror: raw.prosemirror,
    frontmatter: raw.frontmatter ?? null
  };
}

/**
 * Raw `queue_item/v1` envelope — the shape `Valea.Workflows.Runner` writes
 * to `queue/pending/<run_id>.json` and `get_queue_item` hands back. Its
 * field names stay SNAKE_CASE and `approval`/`payload` stay untouched
 * nested maps: `get_item`'s `item` field is deliberately unconstrained on
 * the backend (see `Valea.Api.Queue`'s moduledoc) so this whole envelope —
 * including the workflow-authored `payload` — rides through byte-for-byte,
 * the same raw-delivery contract `IcmPageData.frontmatter` uses.
 */
export type QueueItemEnvelope = {
  schema: string;
  run_id: string;
  session_id: string;
  workflow: string;
  workflow_hash: string;
  input: string;
  input_hash: string;
  risk_level: string;
  approval: Record<string, unknown>;
  created_at: string;
  payload: Record<string, unknown>;
};

/**
 * Raw audit log entry (`{root}/logs/audit.jsonl`). Every entry carries
 * `ts`/`type`/`generation`; the rest of the fields vary by `type` (see
 * `Valea.Audit`'s callers), so `list_audit_entries` delivers entries
 * unconstrained/raw rather than forcing a union type this client would have
 * to keep in lockstep with every audited event shape.
 */
export type AuditEntry = {
  ts: string;
  type: string;
  generation: number | null;
  [key: string]: unknown;
};

export const api = {
  getWorkspace: () => runRpc(callGetWorkspaceChannel, () => httpGetWorkspace(withAuth({}))),

  createWorkspace: (parentDir: string, name: string) =>
    runRpc(
      (channel) => callCreateWorkspaceChannel(channel, { parentDir, name }),
      () => httpCreateWorkspace(withAuth({ input: { parentDir, name } }))
    ),

  openWorkspace: (path: string) =>
    runRpc(
      (channel) => callOpenWorkspaceChannel(channel, { path }),
      () => httpOpenWorkspace(withAuth({ input: { path } }))
    ),

  recentWorkspaces: () => runRpc(callRecentWorkspacesChannel, () => httpRecentWorkspaces(withAuth({}))),

  inspectWorkspace: (path: string) =>
    runRpc(
      (channel) => callInspectWorkspaceChannel(channel, { path }),
      () => httpInspectWorkspace(withAuth({ input: { path } }))
    ),

  icmTree: () => runRpc(callIcmTreeChannel, () => httpIcmTree(withAuth({ fields: icmTreeFields }))),

  icmPage: (path: string) =>
    runRpc(
      (channel) => callIcmPageChannel(channel, { path }),
      () => httpIcmPage(withAuth({ input: { path } }))
    ).then(
      (result): ApiResult<IcmPageData> =>
        result.ok ? { ok: true, data: normalizeIcmPage(result.data as Record<string, any>) } : result
    ),

  cockpitToday: () =>
    runRpc(callCockpitTodayChannel, () => httpCockpitToday(withAuth({ fields: cockpitTodayFields }))),

  // `prosemirror` is typed `object` (not `Record<string, any>`) so callers —
  // notably `PageEditorStore`, whose `noteChange(getJson: () => object)` gets
  // its JSON straight from the ProseMirror editor — don't need to assert
  // away the missing index signature just to call this.
  //
  // `generation` (T21) is optional — `undefined`/`null` skips the backend's
  // `check_generation/1` guard entirely (pre-T21 callers, transition
  // compat); `PageEditorStore` now always passes the generation it captured
  // at load, giving `workspace_changed` a backstop against a switch that
  // happened after the frontend's own local generation check (T21) passed
  // but before the write landed.
  saveIcmPage: (path: string, prosemirror: object, baseHash: string, generation?: number | null) =>
    runRpc(
      (channel) =>
        callSaveIcmPageChannel(channel, { path, prosemirror: prosemirror as Record<string, any>, baseHash, generation }),
      () =>
        httpSaveIcmPage(
          withAuth({
            input: { path, prosemirror: prosemirror as Record<string, any>, baseHash, generation },
            fields: saveIcmPageFields
          })
        )
    ),

  createIcmPage: (parentPath: string, name: string) =>
    runRpc(
      (channel) => callCreateIcmPageChannel(channel, { parentPath, name }),
      () => httpCreateIcmPage(withAuth({ input: { parentPath, name }, fields: createIcmPageFields }))
    ),

  createIcmFolder: (parentPath: string, name: string) =>
    runRpc(
      (channel) => callCreateIcmFolderChannel(channel, { parentPath, name }),
      () => httpCreateIcmFolder(withAuth({ input: { parentPath, name }, fields: createIcmFolderFields }))
    ),

  renameIcmEntry: (path: string, newName: string) =>
    runRpc(
      (channel) => callRenameIcmEntryChannel(channel, { path, newName }),
      () => httpRenameIcmEntry(withAuth({ input: { path, newName }, fields: renameIcmEntryFields }))
    ),

  deleteIcmEntry: (path: string) =>
    runRpc(
      (channel) => callDeleteIcmEntryChannel(channel, { path }),
      () => httpDeleteIcmEntry(withAuth({ input: { path }, fields: deleteIcmEntryFields }))
    ),

  icmEntryReferences: (path: string) =>
    runRpc(
      (channel) => callIcmEntryReferencesChannel(channel, { path }),
      () => httpIcmEntryReferences(withAuth({ input: { path }, fields: icmEntryReferencesFields }))
    ),

  // Mutating wrappers below take `generation` as a plain argument rather
  // than reading it off a store — this module stays store-free (see the
  // header comment). The T16+ stores are responsible for sourcing it from
  // the open workspace and passing it in.

  createAgentSession: (kind: string, generation: number) =>
    runRpc(
      (channel) => callCreateAgentSessionChannel(channel, { kind, generation }),
      () =>
        httpCreateAgentSession(
          withAuth({ input: { kind, generation }, fields: createAgentSessionFields })
        )
    ),

  listAgentSessions: () =>
    runRpc(callListAgentSessionsChannel, () =>
      httpListAgentSessions(withAuth({ fields: listAgentSessionsFields }))
    ),

  runWorkflow: (path: string, input: string, generation: number) =>
    runRpc(
      (channel) => callRunWorkflowChannel(channel, { path, input, generation }),
      () =>
        httpRunWorkflow(withAuth({ input: { path, input, generation }, fields: runWorkflowFields }))
    ),

  harnessDoctor: () =>
    runRpc(callHarnessDoctorChannel, () => httpHarnessDoctor(withAuth({ fields: harnessDoctorFields }))),

  listWorkflows: () =>
    runRpc(callListWorkflowsChannel, () => httpListWorkflows(withAuth({ fields: listWorkflowsFields }))),

  listQueueItems: () =>
    runRpc(callListQueueItemsChannel, () =>
      httpListQueueItems(withAuth({ fields: listQueueItemsFields }))
    ),

  getQueueItem: (runId: string) =>
    runRpc(
      (channel) => callGetQueueItemChannel(channel, { runId }),
      () => httpGetQueueItem(withAuth({ input: { runId }, fields: getQueueItemFields }))
    ).then(
      (result): ApiResult<{ item: QueueItemEnvelope; revision: string }> => {
        if (!result.ok) return result;
        const data = result.data as Record<string, any>;
        return { ok: true, data: { item: data.item as QueueItemEnvelope, revision: data.revision as string } };
      }
    ),

  approveQueueItem: (runId: string, revision: string, generation: number) =>
    runRpc(
      (channel) => callApproveQueueItemChannel(channel, { runId, revision, generation }),
      () =>
        httpApproveQueueItem(
          withAuth({ input: { runId, revision, generation }, fields: approveQueueItemFields })
        )
    ),

  rejectQueueItem: (runId: string, revision: string, generation: number) =>
    runRpc(
      (channel) => callRejectQueueItemChannel(channel, { runId, revision, generation }),
      () =>
        httpRejectQueueItem(
          withAuth({ input: { runId, revision, generation }, fields: rejectQueueItemFields })
        )
    ),

  listAuditEntries: (limit: number) =>
    runRpc(
      (channel) => callListAuditEntriesChannel(channel, { limit }),
      () => httpListAuditEntries(withAuth({ input: { limit }, fields: listAuditEntriesFields }))
    ).then(
      (result): ApiResult<{ entries: AuditEntry[] }> => {
        if (!result.ok) return result;
        const data = result.data as Record<string, any>;
        return { ok: true, data: { entries: data.entries as AuditEntry[] } };
      }
    ),

  // Mail (T13/T14). `mailStatus`/`listMailMessages`/`mailInbox`/`getMailMessage`
  // deliver their `status`/`message` payloads RAW (unconstrained `:map`,
  // see `MailStatusFields`/`GetMailMessageFields` above) — `stores/mail.svelte.ts`
  // owns normalizing those into camelCase app-facing shapes, same
  // raw-delivery split `IcmPageData.frontmatter`/`QueueItemEnvelope` use.

  mailStatus: () => runRpc(callMailStatusChannel, () => httpMailStatus(withAuth({ fields: mailStatusFields }))),

  setupMailAccount: (account: string, host: string, port: number, username: string, generation: number) =>
    runRpc(
      (channel) => callSetupMailAccountChannel(channel, { account, host, port, username, generation }),
      () =>
        httpSetupMailAccount(
          withAuth({ input: { account, host, port, username, generation }, fields: setupMailAccountFields })
        )
    ),

  setMailCredential: (secret: string, generation: number) =>
    runRpc(
      (channel) => callSetMailCredentialChannel(channel, { secret, generation }),
      () => httpSetMailCredential(withAuth({ input: { secret, generation }, fields: setMailCredentialFields }))
    ),

  mailSyncNow: (generation: number) =>
    runRpc(
      (channel) => callMailSyncNowChannel(channel, { generation }),
      () => httpMailSyncNow(withAuth({ input: { generation }, fields: mailSyncNowFields }))
    ),

  mailDoctor: (generation: number) =>
    runRpc(
      (channel) => callMailDoctorChannel(channel, { generation }),
      () => httpMailDoctor(withAuth({ input: { generation }, fields: mailDoctorFields }))
    ),

  createMailFolders: (generation: number) =>
    runRpc(
      (channel) => callCreateMailFoldersChannel(channel, { generation }),
      () => httpCreateMailFolders(withAuth({ input: { generation }, fields: createMailFoldersFields }))
    ),

  listMailMessages: () =>
    runRpc(callListMailMessagesChannel, () => httpListMailMessages(withAuth({ fields: listMailMessagesFields }))),

  getMailMessage: (msgId: string) =>
    runRpc(
      (channel) => callGetMailMessageChannel(channel, { msgId }),
      () => httpGetMailMessage(withAuth({ input: { msgId }, fields: getMailMessageFields }))
    ),

  mailInbox: () => runRpc(callMailInboxChannel, () => httpMailInbox(withAuth({ fields: mailInboxFields }))),

  retryMailboxOps: (runId: string, generation: number) =>
    runRpc(
      (channel) => callRetryMailboxOpsChannel(channel, { runId, generation }),
      () => httpRetryMailboxOps(withAuth({ input: { runId, generation }, fields: retryMailboxOpsFields }))
    ),

  listDecidedQueueItems: () =>
    runRpc(callListDecidedQueueItemsChannel, () =>
      httpListDecidedQueueItems(withAuth({ fields: listDecidedQueueItemsFields }))
    ),

  // Mounts (A-T12/A-T14). `listMounts` delivers its `mounts` array RAW
  // (unconstrained per-item shape at this layer, though already camelCased
  // by ash_typescript — see `listMountsFields`'s comment above) —
  // `stores/mounts.svelte.ts` owns casting it to `MountSummary[]`, same
  // raw-delivery split `QueueStore`/`AuditStore` use for their list RPCs.

  listMounts: () => runRpc(callListMountsChannel, () => httpListMounts(withAuth({ fields: listMountsFields }))),

  setMountEnabled: (name: string, enabled: boolean, generation: number) =>
    runRpc(
      (channel) => callSetMountEnabledChannel(channel, { name, enabled, generation }),
      () =>
        httpSetMountEnabled(
          withAuth({ input: { name, enabled, generation }, fields: setMountEnabledFields })
        )
    ),

  createMount: (name: string, description: string, generation: number) =>
    runRpc(
      (channel) => callCreateMountChannel(channel, { name, description, generation }),
      () => httpCreateMount(withAuth({ input: { name, description, generation }, fields: createMountFields }))
    )
};

export type Api = typeof api;
