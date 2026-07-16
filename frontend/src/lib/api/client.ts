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
  workspaceSwitchPreflight as httpWorkspaceSwitchPreflight,
  workspaceSwitchPreflightChannel,
  icmTree as httpIcmTree,
  icmTreeChannel,
  icmPage as httpIcmPage,
  icmPageChannel,
  saveIcmPage as httpSaveIcmPage,
  saveIcmPageChannel,
  createIcmPage as httpCreateIcmPage,
  createIcmPageChannel,
  createIcmPageFromTemplate as httpCreateIcmPageFromTemplate,
  createIcmPageFromTemplateChannel,
  createIcmFolder as httpCreateIcmFolder,
  createIcmFolderChannel,
  renameIcmEntry as httpRenameIcmEntry,
  renameIcmEntryChannel,
  deleteIcmEntry as httpDeleteIcmEntry,
  deleteIcmEntryChannel,
  icmEntryReferences as httpIcmEntryReferences,
  icmEntryReferencesChannel,
  icmSearch as httpIcmSearch,
  icmSearchChannel,
  icmPathsExist as httpIcmPathsExist,
  icmPathsExistChannel,
  cockpitToday as httpCockpitToday,
  cockpitTodayChannel,
  createAgentSession as httpCreateAgentSession,
  createAgentSessionChannel,
  listAgentSessions as httpListAgentSessions,
  listAgentSessionsChannel,
  listRecentSessionsByIcm as httpListRecentSessionsByIcm,
  listRecentSessionsByIcmChannel,
  listSessions as httpListSessionsFor,
  listSessionsChannel as listSessionsForChannel,
  createFollowUp as httpCreateFollowUp,
  createFollowUpChannel,
  runWorkflow as httpRunWorkflow,
  runWorkflowChannel,
  distillDecisions as httpDistillDecisions,
  distillDecisionsChannel,
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
  inspectIcm as httpInspectIcm,
  inspectIcmChannel,
  listIcms as httpListIcms,
  listIcmsChannel,
  mountIcm as httpMountIcm,
  mountIcmChannel,
  createIcm as httpCreateIcm,
  createIcmChannel,
  setIcmEnabled as httpSetIcmEnabled,
  setIcmEnabledChannel,
  unmountIcm as httpUnmountIcm,
  unmountIcmChannel,
  icmDoctor as httpIcmDoctor,
  icmDoctorChannel
} from './ash_rpc';
import type { AshRpcError } from './ash_types';
import type {
  CockpitTodayFields,
  SaveIcmPageFields,
  CreateIcmPageFields,
  CreateIcmPageFromTemplateFields,
  CreateIcmFolderFields,
  RenameIcmEntryFields,
  DeleteIcmEntryFields,
  IcmEntryReferencesFields,
  IcmSearchFields,
  IcmPathsExistFields,
  CreateAgentSessionFields,
  ListAgentSessionsFields,
  ListRecentSessionsByIcmFields,
  ListSessionsFields,
  CreateFollowUpFields,
  RunWorkflowFields,
  DistillDecisionsFields,
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
  InspectIcmFields,
  ListIcmsFields,
  MountIcmFields,
  CreateIcmFields,
  SetIcmEnabledFields,
  UnmountIcmFields,
  IcmDoctorFields
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
  input: { name: string }
) {
  return wrapChannelCall((handlers) => createWorkspaceChannel({ channel, input, ...handlers }));
}

function callOpenWorkspaceChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { id: string; generation?: number | null }
) {
  return wrapChannelCall((handlers) => openWorkspaceChannel({ channel, input, ...handlers }));
}

function callRecentWorkspacesChannel(channel: NonNullable<ReturnType<typeof channelAvailable>>) {
  return wrapChannelCall((handlers) => recentWorkspacesChannel({ channel, ...handlers }));
}

function callWorkspaceSwitchPreflightChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { id: string }
) {
  return wrapChannelCall((handlers) => workspaceSwitchPreflightChannel({ channel, input, ...handlers }));
}

function callIcmTreeChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { mountKey: string; generation: number }
) {
  return wrapChannelCall((handlers) => icmTreeChannel({ channel, input, fields: icmTreeFields, ...handlers }));
}

function callIcmPageChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { mountKey: string; path: string }
) {
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
const createIcmPageFromTemplateFields: CreateIcmPageFromTemplateFields = ['path'];
const createIcmFolderFields: CreateIcmFolderFields = ['path'];
const renameIcmEntryFields: RenameIcmEntryFields = ['path', 'updatedWorkflows', 'updatedPages'];
const deleteIcmEntryFields: DeleteIcmEntryFields = ['deleted'];
// Note: the generated `IcmEntryReferencesFields` type can't actually express
// nested field selection into an `Array<TypedMap>` (a real ash_typescript
// codegen gap for anonymous embedded-map arrays, not a Resource
// relationship) — `ComplexFieldSelection` only special-cases Relationship /
// ComplexCalculation / direct-TypedMap / Union arrays, so `ArrayOf<TypedMap>`
// falls through to `never`. The backend action itself DOES accept this exact
// nested literal (confirmed in Task 5), so the assertion below is trusted
// runtime knowledge overriding an incomplete generated type, not a guess.
// `pages` (Task C3) is the AST-confirmed backlinks union alongside the
// original `workflows` — same cast pattern, same codegen gap, one more
// nested field selection in the same literal.
const icmEntryReferencesFields = [
  { workflows: ['file', 'name'] },
  { pages: ['sourcePath', 'mount', 'linkText'] }
] as unknown as IcmEntryReferencesFields;

// `icm_search`/`icm_paths_exist` (Task C2). Same anonymous-embedded-map-array
// codegen gap as `icmEntryReferencesFields` above — `results` is an
// `Array<TypedMap>` action-return field on both, which `ComplexFieldSelection`
// can't express, so the generated `Fields` type collapses to `never` for the
// literal; cast, not inferred. Booleans ride INSIDE `icmPathsExistFields`'s
// `results` array item (`exists`), not as a top-level action-return field, so
// the top-level falsy-map-field workaround documented on
// `listQueueItemsFields`/`mailDoctorFields` does not apply here — see
// `Valea.Api.ICM`'s `:paths_exist` action.
const icmSearchFields = [
  { results: ['path', 'mount', 'title', 'snippet', 'terms'] },
  'skipped'
] as unknown as IcmSearchFields;
const icmPathsExistFields = [{ results: ['path', 'exists'] }] as unknown as IcmPathsExistFields;

const createAgentSessionFields: CreateAgentSessionFields = ['id'];
const runWorkflowFields: RunWorkflowFields = ['runId', 'sessionId'];
const distillDecisionsFields: DistillDecisionsFields = ['runId', 'sessionId'];
const getQueueItemFields: GetQueueItemFields = ['item', 'revision'];
const approveQueueItemFields: ApproveQueueItemFields = ['draftPath', 'appliedPath'];
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

// Task 6.2 — same anonymous-embedded-map-array codegen gap as
// `listAgentSessionsFields` above: `groups`/`sessions` (and `sessions`
// nested a level deeper inside each group) are `Array<TypedMap>`
// action-return fields, which `ComplexFieldSelection` can't express, so the
// generated `Fields` type collapses to `never` for the literal. The backend
// action accepts this exact nested literal (verified by
// `test/valea/api/agents_test.exs`).
const sessionSummarySelection = ['id', 'kind', 'title', 'workflow', 'runId', 'startedAt', 'status', 'live'];
const listRecentSessionsByIcmFields = [
  { groups: ['mountKey', 'icmName', { sessions: sessionSummarySelection }] }
] as unknown as ListRecentSessionsByIcmFields;
const listSessionsForFields = [
  { sessions: sessionSummarySelection },
  'nextCursor'
] as unknown as ListSessionsFields;
const createFollowUpFields: CreateFollowUpFields = ['id'];
const harnessDoctorFields = [
  'ok',
  { checks: ['id', 'status', 'detail', 'remedy'] }
] as unknown as HarnessDoctorFields;
const listWorkflowsFields = [
  {
    workflows: [
      'icmId',
      'mountKey',
      'icmName',
      'relativePath',
      'resolvedPath',
      'name',
      'description',
      'enabled',
      'triggerSource',
      'riskLevel',
      'sourceCount',
      'steps'
    ]
  }
] as unknown as ListWorkflowsFields;
const listQueueItemsFields = [
  {
    items: [
      'runId',
      'title',
      'summary',
      'kind',
      'riskLevel',
      'createdAt',
      'workflow',
      'mountKey',
      'path',
      'icmName',
      'valid',
      'error'
    ]
  }
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
  {
    preparedItems: [
      'type',
      'title',
      'summary',
      'usedSources',
      'primaryAction',
      'secondaryAction',
      'icmName'
    ]
  },
  { openLoops: ['title', 'source'] },
  'whileYouWereAway',
  'triageWorkflowPath',
  'distillWorkflowPath',
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

// Icms (task 3.4, `Valea.Api.Icms` — the C9 id/mount-key based replacement
// for `Valea.Api.Mounts`, kept registered until Phase 11). Same anonymous-
// embedded-map-array codegen gap as `listAgentSessionsFields`/
// `listWorkflowsFields`/`listQueueItemsFields` above (see the comment on
// `icmEntryReferencesFields`) — `icms` is an `Array<TypedMap>` action-return
// field, which `ComplexFieldSelection` can't express, so the generated
// `Fields` type collapses to `never` for the literal. The backend action
// accepts this exact nested literal (verified by `test/valea/api/icms_test.exs`).
// `mountKey`/`id` (`MountIcmFields`/`CreateIcmFields`), `saved`
// (`SetIcmEnabledFields`), and `unmounted` (`UnmountIcmFields`) are plain
// top-level fields with no such gap, so no cast is needed for them — same
// for `icmDoctorFields` below (`checks` is the UNCONSTRAINED
// `Array<Record<string, any>>` passthrough, not a nested `TypedMap`, so it
// hits no gap either — mirrors `mailDoctorFields`).
const listIcmsFields = [
  { icms: ['mountKey', 'id', 'name', 'description', 'root', 'enabled', 'degraded'] }
] as unknown as ListIcmsFields;
const mountIcmFields: MountIcmFields = ['mountKey', 'id'];
const createIcmFields: CreateIcmFields = ['mountKey', 'id'];
const setIcmEnabledFields: SetIcmEnabledFields = ['saved'];
const unmountIcmFields: UnmountIcmFields = ['unmounted'];
const icmDoctorFields: IcmDoctorFields = ['ok', 'checks'];

// `inspect_icm` (Task 10.1) — onboarding's mount-preview primitive, no
// `generation`/open-workspace requirement (see `Valea.Api.Icms`'s
// moduledoc). Plain top-level fields, same as `mountIcmFields` above.
const inspectIcmFields: InspectIcmFields = ['ok', 'name', 'description', 'reason'];

// `icm_tree` (task 4.2 re-key) — a single ICM's `{mountKey, title, tree}`,
// no more all-mounts grouped envelope (`mounts: [...]`). `mountKey`/`title`
// are plain typed top-level fields with no codegen gap; `tree` stays an
// unconstrained `Array<Record<string, any>>` (the recursive folder/page
// tree), so it needs no nested selection of its own, just the bare field
// name.
const icmTreeFields: IcmTreeFields = ['mountKey', 'title', 'tree'];

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
  input: { kind: string; mountKey: string; generation: number }
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

function callListRecentSessionsByIcmChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { limit: number }
) {
  return wrapChannelCall((handlers) =>
    listRecentSessionsByIcmChannel({ channel, input, fields: listRecentSessionsByIcmFields, ...handlers })
  );
}

function callListSessionsForChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { mountKey: string; cursor: string | null }
) {
  return wrapChannelCall((handlers) =>
    listSessionsForChannel({ channel, input, fields: listSessionsForFields, ...handlers })
  );
}

function callCreateFollowUpChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { sessionId: string; generation: number }
) {
  return wrapChannelCall((handlers) =>
    createFollowUpChannel({ channel, input, fields: createFollowUpFields, ...handlers })
  );
}

function callRunWorkflowChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: {
    mountKey: string;
    relativePath: string;
    inputLocator: Record<string, any>;
    generation: number;
  }
) {
  return wrapChannelCall((handlers) =>
    runWorkflowChannel({ channel, input, fields: runWorkflowFields, ...handlers })
  );
}

function callDistillDecisionsChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { generation: number }
) {
  return wrapChannelCall((handlers) =>
    distillDecisionsChannel({ channel, input, fields: distillDecisionsFields, ...handlers })
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
  input: { runId: string; revision: string; generation: number; reason?: string | null }
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

function callInspectIcmChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { path: string }
) {
  return wrapChannelCall((handlers) =>
    inspectIcmChannel({ channel, input, fields: inspectIcmFields, ...handlers })
  );
}

function callListIcmsChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { generation: number }
) {
  return wrapChannelCall((handlers) => listIcmsChannel({ channel, input, fields: listIcmsFields, ...handlers }));
}

function callMountIcmChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { path: string; generation: number }
) {
  return wrapChannelCall((handlers) => mountIcmChannel({ channel, input, fields: mountIcmFields, ...handlers }));
}

function callCreateIcmChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { name: string; path: string; generation: number }
) {
  return wrapChannelCall((handlers) =>
    createIcmChannel({ channel, input, fields: createIcmFields, ...handlers })
  );
}

function callSetIcmEnabledChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { mountKey: string; enabled: boolean; generation: number }
) {
  return wrapChannelCall((handlers) =>
    setIcmEnabledChannel({ channel, input, fields: setIcmEnabledFields, ...handlers })
  );
}

function callUnmountIcmChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { mountKey: string; generation: number }
) {
  return wrapChannelCall((handlers) =>
    unmountIcmChannel({ channel, input, fields: unmountIcmFields, ...handlers })
  );
}

function callIcmDoctorChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { mountKey: string; generation: number }
) {
  return wrapChannelCall((handlers) =>
    icmDoctorChannel({ channel, input, fields: icmDoctorFields, ...handlers })
  );
}

function callSaveIcmPageChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: {
    mountKey: string;
    path: string;
    prosemirror: Record<string, any>;
    baseHash: string;
    generation?: number | null;
  }
) {
  return wrapChannelCall((handlers) => saveIcmPageChannel({ channel, input, fields: saveIcmPageFields, ...handlers }));
}

function callCreateIcmPageChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { mountKey: string; parentPath: string; name: string }
) {
  return wrapChannelCall((handlers) =>
    createIcmPageChannel({ channel, input, fields: createIcmPageFields, ...handlers })
  );
}

function callCreateIcmPageFromTemplateChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: {
    mountKey: string;
    parentPath: string;
    name: string;
    templateMountKey: string;
    templatePath: string;
  }
) {
  return wrapChannelCall((handlers) =>
    createIcmPageFromTemplateChannel({ channel, input, fields: createIcmPageFromTemplateFields, ...handlers })
  );
}

function callCreateIcmFolderChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { mountKey: string; parentPath: string; name: string }
) {
  return wrapChannelCall((handlers) =>
    createIcmFolderChannel({ channel, input, fields: createIcmFolderFields, ...handlers })
  );
}

function callRenameIcmEntryChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { mountKey: string; path: string; newName: string }
) {
  return wrapChannelCall((handlers) =>
    renameIcmEntryChannel({ channel, input, fields: renameIcmEntryFields, ...handlers })
  );
}

function callDeleteIcmEntryChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { mountKey: string; path: string }
) {
  return wrapChannelCall((handlers) =>
    deleteIcmEntryChannel({ channel, input, fields: deleteIcmEntryFields, ...handlers })
  );
}

function callIcmEntryReferencesChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { mountKey: string; path: string }
) {
  return wrapChannelCall((handlers) =>
    icmEntryReferencesChannel({ channel, input, fields: icmEntryReferencesFields, ...handlers })
  );
}

function callIcmSearchChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { query: string; mountKey?: string | null }
) {
  return wrapChannelCall((handlers) =>
    icmSearchChannel({ channel, input, fields: icmSearchFields, ...handlers })
  );
}

function callIcmPathsExistChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { paths: string[] }
) {
  return wrapChannelCall((handlers) =>
    icmPathsExistChannel({ channel, input, fields: icmPathsExistFields, ...handlers })
  );
}

/**
 * One live agent session a workspace switch would stop — mirrors
 * `Valea.Api.Workspace.session_payload/1`'s `%{"id", "title", "icm_mount"}`.
 */
export type LiveSession = {
  id: string;
  title: string;
  icmMount: string | null;
};

/**
 * Typed shape of a `workspace_switch_preflight` RPC result (Task 2.4's
 * `Valea.Workspace.Manager.switch_preflight/1`, wired into `WorkspaceStore.
 * switchTo` at Task 10.1). The backend action returns an unconstrained
 * `:map` (`InferWorkspaceSwitchPreflightResult = Record<string, any>`,
 * STRING-keyed — `target_id`/`live_sessions`), so this is asserted by
 * `normalizeWorkspaceSwitchPreflight` below rather than inferred by
 * ash_typescript, mirroring `IcmPageData`/`normalizeIcmPage` further down.
 */
export type WorkspaceSwitchPreflight = {
  targetId: string;
  liveSessions: LiveSession[];
};

export function normalizeWorkspaceSwitchPreflight(raw: Record<string, any>): WorkspaceSwitchPreflight {
  const rawSessions = Array.isArray(raw.live_sessions) ? raw.live_sessions : [];
  return {
    targetId: raw.target_id,
    liveSessions: rawSessions.map((session: Record<string, any>) => ({
      id: session.id,
      title: session.title,
      icmMount: session.icm_mount ?? null
    }))
  };
}

/**
 * Raw `icm_page` RPC result. The backend action returns an
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

/**
 * Uploads an image for `pagePath` inside `mountKey`'s ICM (Task C7; `mountKey`
 * threaded through in task 4.4's re-key — `pagePath` is ICM-relative, never
 * workspace-relative or absolute, see `ValeaWeb.FilesController`'s
 * moduledoc). Plain HTTP — `POST /files/upload` is not an Ash RPC action, so
 * this bypasses `runRpc`/the generated client entirely and calls `fetch`
 * directly, carrying the same `x-valea-token` header `withAuth` injects for
 * the HTTP RPC fallback (`controlToken()` — see `socket.ts`). Response keys
 * are snake_case on the wire (`path`, `rel_from_page`); mapped to
 * `relFromPage` here, the app's one camelCase boundary for this endpoint.
 */
async function uploadImage(
  file: File,
  mountKey: string,
  pagePath: string
): Promise<ApiResult<{ path: string; relFromPage: string }>> {
  const body = new FormData();
  body.append('file', file);
  body.append('mount_key', mountKey);
  body.append('page_path', pagePath);

  let response: Response;
  try {
    response = await fetch('/files/upload', {
      method: 'POST',
      body,
      headers: { 'x-valea-token': controlToken() }
    });
  } catch {
    return { ok: false, error: 'network_error' };
  }

  const payload: unknown = await response.json().catch(() => null);

  if (!response.ok) {
    const error =
      payload && typeof payload === 'object' && 'error' in payload && typeof payload.error === 'string'
        ? payload.error
        : 'upload_failed';
    return { ok: false, error };
  }

  if (
    !payload ||
    typeof payload !== 'object' ||
    typeof (payload as Record<string, unknown>).path !== 'string' ||
    typeof (payload as Record<string, unknown>).rel_from_page !== 'string'
  ) {
    return { ok: false, error: 'invalid_response' };
  }

  const data = payload as { path: string; rel_from_page: string };
  return { ok: true, data: { path: data.path, relFromPage: data.rel_from_page } };
}

export const api = {
  // id-based (C9, Phase 2) — `getWorkspace`'s payload now carries `id`
  // instead of `path` (see `Valea.Api.Workspace`'s moduledoc); no caller
  // supplies or receives a filesystem path anymore.
  getWorkspace: () => runRpc(callGetWorkspaceChannel, () => httpGetWorkspace(withAuth({}))),

  createWorkspace: (name: string) =>
    runRpc(
      (channel) => callCreateWorkspaceChannel(channel, { name }),
      () => httpCreateWorkspace(withAuth({ input: { name } }))
    ),

  openWorkspace: (id: string, generation?: number | null) =>
    runRpc(
      (channel) => callOpenWorkspaceChannel(channel, { id, generation: generation ?? null }),
      () => httpOpenWorkspace(withAuth({ input: { id, generation: generation ?? null } }))
    ),

  recentWorkspaces: () => runRpc(callRecentWorkspacesChannel, () => httpRecentWorkspaces(withAuth({}))),

  // Read-only preflight for a workspace switch (Task 2.4) — reports the
  // currently open workspace's live agent sessions a switch to `id` would
  // stop. Wired into `WorkspaceStore.switchTo` at Task 10.1 — a switch to
  // a target with live sessions confirms with the caller before opening.
  workspaceSwitchPreflight: (id: string) =>
    runRpc(
      (channel) => callWorkspaceSwitchPreflightChannel(channel, { id }),
      () => httpWorkspaceSwitchPreflight(withAuth({ input: { id } }))
    ).then(
      (result): ApiResult<WorkspaceSwitchPreflight> =>
        result.ok
          ? { ok: true, data: normalizeWorkspaceSwitchPreflight(result.data as Record<string, any>) }
          : result
    ),

  // `icm_tree` (task 4.2 re-key) — one ICM's tree at a time, keyed by
  // `mountKey` and generation-guarded (mirrors `listIcms`'s own
  // generation-guarded read — see `Valea.Api.ICM`'s moduledoc). Callers
  // that need every enabled mount's tree fetch the mount list themselves
  // (`listIcms`) and call this once per mount key — `IcmStore.refetch`
  // (`stores/icm.svelte.ts`) is the one place that does.
  icmTree: (mountKey: string, generation: number) =>
    runRpc(
      (channel) => callIcmTreeChannel(channel, { mountKey, generation }),
      () => httpIcmTree(withAuth({ input: { mountKey, generation }, fields: icmTreeFields }))
    ),

  icmPage: (mountKey: string, path: string) =>
    runRpc(
      (channel) => callIcmPageChannel(channel, { mountKey, path }),
      () => httpIcmPage(withAuth({ input: { mountKey, path } }))
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
  saveIcmPage: (
    mountKey: string,
    path: string,
    prosemirror: object,
    baseHash: string,
    generation?: number | null
  ) =>
    runRpc(
      (channel) =>
        callSaveIcmPageChannel(channel, {
          mountKey,
          path,
          prosemirror: prosemirror as Record<string, any>,
          baseHash,
          generation
        }),
      () =>
        httpSaveIcmPage(
          withAuth({
            input: { mountKey, path, prosemirror: prosemirror as Record<string, any>, baseHash, generation },
            fields: saveIcmPageFields
          })
        )
    ),

  createIcmPage: (mountKey: string, parentPath: string, name: string) =>
    runRpc(
      (channel) => callCreateIcmPageChannel(channel, { mountKey, parentPath, name }),
      () => httpCreateIcmPage(withAuth({ input: { mountKey, parentPath, name }, fields: createIcmPageFields }))
    ),

  createIcmPageFromTemplate: (
    mountKey: string,
    parentPath: string,
    name: string,
    templateMountKey: string,
    templatePath: string
  ) =>
    runRpc(
      (channel) =>
        callCreateIcmPageFromTemplateChannel(channel, {
          mountKey,
          parentPath,
          name,
          templateMountKey,
          templatePath
        }),
      () =>
        httpCreateIcmPageFromTemplate(
          withAuth({
            input: { mountKey, parentPath, name, templateMountKey, templatePath },
            fields: createIcmPageFromTemplateFields
          })
        )
    ),

  createIcmFolder: (mountKey: string, parentPath: string, name: string) =>
    runRpc(
      (channel) => callCreateIcmFolderChannel(channel, { mountKey, parentPath, name }),
      () => httpCreateIcmFolder(withAuth({ input: { mountKey, parentPath, name }, fields: createIcmFolderFields }))
    ),

  renameIcmEntry: (mountKey: string, path: string, newName: string) =>
    runRpc(
      (channel) => callRenameIcmEntryChannel(channel, { mountKey, path, newName }),
      () => httpRenameIcmEntry(withAuth({ input: { mountKey, path, newName }, fields: renameIcmEntryFields }))
    ),

  deleteIcmEntry: (mountKey: string, path: string) =>
    runRpc(
      (channel) => callDeleteIcmEntryChannel(channel, { mountKey, path }),
      () => httpDeleteIcmEntry(withAuth({ input: { mountKey, path }, fields: deleteIcmEntryFields }))
    ),

  icmEntryReferences: (mountKey: string, path: string) =>
    runRpc(
      (channel) => callIcmEntryReferencesChannel(channel, { mountKey, path }),
      () => httpIcmEntryReferences(withAuth({ input: { mountKey, path }, fields: icmEntryReferencesFields }))
    ),

  // `icm_search`/`icm_paths_exist` (Task C2). `mountKey` (Task 5.6) is the
  // PRIMARY ICM to scope the scan to — that ICM plus every ICM it directly
  // declares related via its own `CONTEXT.md` (see `Valea.Mounts.scoped_roots/2`
  // and `Valea.Api.ICM`'s `:search` action) — an omitted/undefined
  // `mountKey` scans every enabled mount, matching
  // `Valea.ICM.Search.search/4`'s default. Callers don't yet pass a
  // `mountKey` (full session-context wiring for the palette/backlinks
  // panel is a later task); this only threads the plumbing through.
  icmSearch: (query: string, mountKey?: string) =>
    runRpc(
      (channel) => callIcmSearchChannel(channel, { query, mountKey: mountKey ?? null }),
      () =>
        httpIcmSearch(withAuth({ input: { query, mountKey: mountKey ?? null }, fields: icmSearchFields }))
    ),

  icmPathsExist: (paths: string[]) =>
    runRpc(
      (channel) => callIcmPathsExistChannel(channel, { paths }),
      () => httpIcmPathsExist(withAuth({ input: { paths }, fields: icmPathsExistFields }))
    ),

  // Mutating wrappers below take `generation` as a plain argument rather
  // than reading it off a store — this module stays store-free (see the
  // header comment). The T16+ stores are responsible for sourcing it from
  // the open workspace and passing it in.

  // Task 5.5: `mountKey` names the session's PRIMARY ICM — the caller must
  // resolve which mount before calling this (for now, the chat page
  // defaults to the first enabled ICM or a `?icm=` query; Phase 9's sidebar
  // `+` will supply a real choice). An unknown/disabled/degraded mount key
  // surfaces as `icm_unavailable` from the backend, same shape as any other
  // RPC error this wrapper propagates.
  createAgentSession: (kind: string, mountKey: string, generation: number) =>
    runRpc(
      (channel) => callCreateAgentSessionChannel(channel, { kind, mountKey, generation }),
      () =>
        httpCreateAgentSession(
          withAuth({ input: { kind, mountKey, generation }, fields: createAgentSessionFields })
        )
    ),

  listAgentSessions: () =>
    runRpc(callListAgentSessionsChannel, () =>
      httpListAgentSessions(withAuth({ fields: listAgentSessionsFields }))
    ),

  // Task 6.2 — grouped-by-ICM recent-session feed for the sidebar's project
  // groups (Phase 9 consumes this; this task only wires the wrapper).
  // `limit` defaults to 5 (spec §"ICM group behavior": up to five sessions
  // per ICM row) so a Phase 9 caller can omit it entirely.
  listRecentSessionsByIcm: (limit = 5) =>
    runRpc(
      (channel) => callListRecentSessionsByIcmChannel(channel, { limit }),
      () => httpListRecentSessionsByIcm(withAuth({ input: { limit }, fields: listRecentSessionsByIcmFields }))
    ),

  // Task 6.2 — full filtered history for one ICM ("Show all…"), paged via
  // `cursor` (`null`/omitted for the first page, otherwise the previous
  // page's `nextCursor`). Named `listSessionsFor` (not `listSessions`) to
  // stay distinct from `listAgentSessions` above — the underlying RPC
  // action's external name IS `list_sessions` (see `Valea.Api`), just
  // imported under a `httpListSessionsFor`/`listSessionsForChannel` alias.
  listSessionsFor: (mountKey: string, cursor: string | null = null) =>
    runRpc(
      (channel) => callListSessionsForChannel(channel, { mountKey, cursor }),
      () => httpListSessionsFor(withAuth({ input: { mountKey, cursor }, fields: listSessionsForFields }))
    ),

  // Task 6.3 — follow-up inherits the ORIGINAL session's own primary ICM
  // server-side (`Valea.Agents.create_follow_up/2`); the caller only names
  // which session to follow up on. `icm_unavailable` (ICM since
  // unmounted/disabled/degraded) and `original_not_found` surface as
  // ordinary RPC errors, same shape as any other action this wrapper
  // propagates.
  createFollowUp: (sessionId: string, generation: number) =>
    runRpc(
      (channel) => callCreateFollowUpChannel(channel, { sessionId, generation }),
      () =>
        httpCreateFollowUp(
          withAuth({ input: { sessionId, generation }, fields: createFollowUpFields })
        )
    ),

  // Task 7.2: `run_workflow`'s `{mountKey, relativePath}` identity (a
  // workflow's Task 7.1 `Valea.Workflows.get/2` address) replaces the old
  // opaque absolute `path`, and `inputLocator` (a `Valea.Icm.Locator`
  // JSON shape — `{ kind: 'workspace', path: 'sources/...' }` for a
  // workspace source, or `{ kind: 'icm', icm_id: '...', path: '...' }`
  // for a page in a mounted ICM) replaces the old bare workspace-relative
  // `input` string. `inputLocator` is typed `object` (not `Record<string,
  // any>`), same rationale as `saveIcmPage`'s `prosemirror` above — it is
  // an unconstrained `:map` action argument the backend passes straight
  // to `Valea.Icm.Locator.resolve/2` without ash_typescript ever
  // camelCasing its keys, so callers build it with the SNAKE_CASE keys
  // `Locator.resolve/2` itself pattern-matches on (`icm_id`, not `icmId`).
  runWorkflow: (mountKey: string, relativePath: string, inputLocator: object, generation: number) =>
    runRpc(
      (channel) =>
        callRunWorkflowChannel(channel, {
          mountKey,
          relativePath,
          inputLocator: inputLocator as Record<string, any>,
          generation
        }),
      () =>
        httpRunWorkflow(
          withAuth({
            input: {
              mountKey,
              relativePath,
              inputLocator: inputLocator as Record<string, any>,
              generation
            },
            fields: runWorkflowFields
          })
        )
    ),

  distillDecisions: (generation: number) =>
    runRpc(
      (channel) => callDistillDecisionsChannel(channel, { generation }),
      () =>
        httpDistillDecisions(
          withAuth({ input: { generation }, fields: distillDecisionsFields })
        )
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

  rejectQueueItem: (runId: string, revision: string, generation: number, reason?: string | null) =>
    runRpc(
      (channel) =>
        callRejectQueueItemChannel(channel, { runId, revision, generation, reason: reason ?? null }),
      () =>
        httpRejectQueueItem(
          withAuth({
            input: { runId, revision, generation, reason: reason ?? null },
            fields: rejectQueueItemFields
          })
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

  // Icms (task 3.4, `Valea.Api.Icms`). `listIcms` delivers its `icms` array
  // RAW (unconstrained per-item shape at this layer, though already
  // camelCased by ash_typescript — see `listIcmsFields`'s comment above) —
  // `stores/mounts.svelte.ts` owns casting it to `MountSummary[]`, same
  // raw-delivery split `QueueStore`/`AuditStore` use for their list RPCs.
  // Unlike the retired `list_mounts`, `list_icms` takes a `generation` —
  // see `Valea.Api.Icms`'s moduledoc for why every action here guards one.

  // Onboarding's mount-preview primitive (Task 10.1) — no `generation`, no
  // open-workspace requirement (see `Valea.Api.Icms`'s moduledoc,
  // "inspect_icm"). Never rejects with an RPC error; every outcome comes
  // back as `ok: true`, with a `data` payload.
  inspectIcm: (path: string) =>
    runRpc(
      (channel) => callInspectIcmChannel(channel, { path }),
      () => httpInspectIcm(withAuth({ input: { path }, fields: inspectIcmFields }))
    ),

  listIcms: (generation: number) =>
    runRpc(
      (channel) => callListIcmsChannel(channel, { generation }),
      () => httpListIcms(withAuth({ input: { generation }, fields: listIcmsFields }))
    ),

  // `mountIcm`'s `path` is passed through EXACTLY as picked/typed (absolute
  // or `~`-based) — see `Valea.Mounts.mount/2`'s moduledoc: the config
  // value stays in the user's own portable form, never a resolved/
  // normalized path.

  mountIcm: (path: string, generation: number) =>
    runRpc(
      (channel) => callMountIcmChannel(channel, { path, generation }),
      () => httpMountIcm(withAuth({ input: { path, generation }, fields: mountIcmFields }))
    ),

  createIcm: (name: string, path: string, generation: number) =>
    runRpc(
      (channel) => callCreateIcmChannel(channel, { name, path, generation }),
      () => httpCreateIcm(withAuth({ input: { name, path, generation }, fields: createIcmFields }))
    ),

  setIcmEnabled: (mountKey: string, enabled: boolean, generation: number) =>
    runRpc(
      (channel) => callSetIcmEnabledChannel(channel, { mountKey, enabled, generation }),
      () =>
        httpSetIcmEnabled(
          withAuth({ input: { mountKey, enabled, generation }, fields: setIcmEnabledFields })
        )
    ),

  unmountIcm: (mountKey: string, generation: number) =>
    runRpc(
      (channel) => callUnmountIcmChannel(channel, { mountKey, generation }),
      () => httpUnmountIcm(withAuth({ input: { mountKey, generation }, fields: unmountIcmFields }))
    ),

  icmDoctor: (mountKey: string, generation: number) =>
    runRpc(
      (channel) => callIcmDoctorChannel(channel, { mountKey, generation }),
      () => httpIcmDoctor(withAuth({ input: { mountKey, generation }, fields: icmDoctorFields }))
    ),

  // Images (Task C7). Plain HTTP, not Ash RPC — see `uploadImage`'s own doc
  // comment above.
  uploadImage
};

export type Api = typeof api;
