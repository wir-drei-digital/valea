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
  icmListDir as httpIcmListDir,
  icmListDirChannel,
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
  resumeAgentSession as httpResumeAgentSession,
  resumeAgentSessionChannel,
  harnessDoctor as httpHarnessDoctor,
  harnessDoctorChannel,
  harnessConfig as httpHarnessConfig,
  harnessConfigChannel,
  setHarnessCommand as httpSetHarnessCommand,
  setHarnessCommandChannel,
  archiveAgentSession as httpArchiveAgentSession,
  archiveAgentSessionChannel,
  deleteAgentSession as httpDeleteAgentSession,
  deleteAgentSessionChannel,
  listAuditEntries as httpListAuditEntries,
  listAuditEntriesChannel,
  mailStatus as httpMailStatus,
  mailStatusChannel,
  setupMailAccount as httpSetupMailAccount,
  setupMailAccountChannel,
  getMailAccountSettings as httpGetMailAccountSettings,
  getMailAccountSettingsChannel,
  mailAutoconfig as httpMailAutoconfig,
  mailAutoconfigChannel,
  setMailCredential as httpSetMailCredential,
  setMailCredentialChannel,
  startMailOauth as httpStartMailOauth,
  startMailOauthChannel,
  mailSyncNow as httpMailSyncNow,
  mailSyncNowChannel,
  mailDoctor as httpMailDoctor,
  mailDoctorChannel,
  createMailFolders as httpCreateMailFolders,
  createMailFoldersChannel,
  listMailMessages as httpListMailMessages,
  listMailMessagesChannel,
  searchMail as httpSearchMail,
  searchMailChannel,
  listMailFolders as httpListMailFolders,
  listMailFoldersChannel,
  getMailMessage as httpGetMailMessage,
  getMailMessageChannel,
  getMailThread as httpGetMailThread,
  getMailThreadChannel,
  listTrustedMailSenders as httpListTrustedMailSenders,
  listTrustedMailSendersChannel,
  setMailSenderTrust as httpSetMailSenderTrust,
  setMailSenderTrustChannel,
  removeMailAccount as httpRemoveMailAccount,
  removeMailAccountChannel,
  purgeMailAccountFiles as httpPurgeMailAccountFiles,
  purgeMailAccountFilesChannel,
  readoptMailAccount as httpReadoptMailAccount,
  readoptMailAccountChannel,
  discardHeldFolder as httpDiscardHeldFolder,
  discardHeldFolderChannel,
  mailApplyOps as httpMailApplyOps,
  mailApplyOpsChannel,
  pushDraftToMailbox as httpPushDraftToMailbox,
  pushDraftToMailboxChannel,
  listMailDrafts as httpListMailDrafts,
  listMailDraftsChannel,
  getMailDraft as httpGetMailDraft,
  getMailDraftChannel,
  writeMailDraft as httpWriteMailDraft,
  writeMailDraftChannel,
  getMailDraftReview as httpGetMailDraftReview,
  getMailDraftReviewChannel,
  sendDraft as httpSendDraft,
  sendDraftChannel,
  resolveSendReview as httpResolveSendReview,
  resolveSendReviewChannel,
  retrySentCopy as httpRetrySentCopy,
  retrySentCopyChannel,
  reviseMailDraft as httpReviseMailDraft,
  reviseMailDraftChannel,
  inspectIcm as httpInspectIcm,
  inspectIcmChannel,
  listIcms as httpListIcms,
  listIcmsChannel,
  mountIcm as httpMountIcm,
  mountIcmChannel,
  adoptIcm as httpAdoptIcm,
  adoptIcmChannel,
  createIcm as httpCreateIcm,
  createIcmChannel,
  setIcmEnabled as httpSetIcmEnabled,
  setIcmEnabledChannel,
  listIcmMailAccess as httpListIcmMailAccess,
  listIcmMailAccessChannel,
  setIcmMailAccess as httpSetIcmMailAccess,
  setIcmMailAccessChannel,
  unmountIcm as httpUnmountIcm,
  unmountIcmChannel,
  icmDoctor as httpIcmDoctor,
  icmDoctorChannel,
  calendarStatus as httpCalendarStatus,
  calendarStatusChannel,
  setupCalendarSource as httpSetupCalendarSource,
  setupCalendarSourceChannel,
  setCalendarSourceUrl as httpSetCalendarSourceUrl,
  setCalendarSourceUrlChannel,
  removeCalendarSource as httpRemoveCalendarSource,
  removeCalendarSourceChannel,
  purgeCalendarSourceFiles as httpPurgeCalendarSourceFiles,
  purgeCalendarSourceFilesChannel,
  calendarSyncNow as httpCalendarSyncNow,
  calendarSyncNowChannel,
  calendarDoctor as httpCalendarDoctor,
  calendarDoctorChannel,
  listCalendarEvents as httpListCalendarEvents,
  listCalendarEventsChannel,
  createValeaEvent as httpCreateValeaEvent,
  createValeaEventChannel,
  updateValeaEvent as httpUpdateValeaEvent,
  updateValeaEventChannel,
  deleteValeaEvent as httpDeleteValeaEvent,
  deleteValeaEventChannel,
  enableCalendarFeed as httpEnableCalendarFeed,
  enableCalendarFeedChannel,
  rotateCalendarFeedToken as httpRotateCalendarFeedToken,
  rotateCalendarFeedTokenChannel,
  listSkills as httpListSkills,
  listSkillsChannel,
  installSkill as httpInstallSkill,
  installSkillChannel,
  updateSkill as httpUpdateSkill,
  updateSkillChannel,
  uninstallSkill as httpUninstallSkill,
  uninstallSkillChannel,
  dismissSkillsOffer as httpDismissSkillsOffer,
  dismissSkillsOfferChannel
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
  CreateAgentSessionInput,
  ListAgentSessionsFields,
  ListRecentSessionsByIcmFields,
  ListSessionsFields,
  ResumeAgentSessionFields,
  HarnessDoctorFields,
  HarnessConfigFields,
  SetHarnessCommandFields,
  ArchiveAgentSessionFields,
  DeleteAgentSessionFields,
  ListAuditEntriesFields,
  MailStatusFields,
  SetupMailAccountFields,
  GetMailAccountSettingsFields,
  MailAutoconfigFields,
  SetMailCredentialFields,
  StartMailOauthFields,
  MailSyncNowFields,
  MailDoctorFields,
  CreateMailFoldersFields,
  ListMailMessagesFields,
  SearchMailFields,
  ListMailFoldersFields,
  GetMailMessageFields,
  GetMailThreadFields,
  ListTrustedMailSendersFields,
  SetMailSenderTrustFields,
  RemoveMailAccountFields,
  PurgeMailAccountFilesFields,
  ReadoptMailAccountFields,
  DiscardHeldFolderFields,
  MailApplyOpsFields,
  PushDraftToMailboxFields,
  ListMailDraftsFields,
  GetMailDraftFields,
  WriteMailDraftFields,
  GetMailDraftReviewFields,
  SendDraftFields,
  ResolveSendReviewFields,
  RetrySentCopyFields,
  ReviseMailDraftFields,
  IcmTreeFields,
  IcmListDirFields,
  InspectIcmFields,
  ListIcmsFields,
  MountIcmFields,
  AdoptIcmFields,
  CreateIcmFields,
  SetIcmEnabledFields,
  UnmountIcmFields,
  IcmDoctorFields,
  ListIcmMailAccessFields,
  SetIcmMailAccessFields,
  CalendarStatusFields,
  SetupCalendarSourceFields,
  SetCalendarSourceUrlFields,
  RemoveCalendarSourceFields,
  PurgeCalendarSourceFilesFields,
  CalendarSyncNowFields,
  CalendarDoctorFields,
  ListCalendarEventsFields,
  CreateValeaEventFields,
  UpdateValeaEventFields,
  DeleteValeaEventFields,
  EnableCalendarFeedFields,
  RotateCalendarFeedTokenFields,
  ListSkillsFields,
  ListSkillsInput,
  InstallSkillFields,
  InstallSkillInput,
  UpdateSkillFields,
  UpdateSkillInput,
  UninstallSkillFields,
  UninstallSkillInput,
  DismissSkillsOfferFields,
  DismissSkillsOfferInput
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

function callIcmListDirChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { mountKey: string; path: string; generation: number }
) {
  return wrapChannelCall((handlers) => icmListDirChannel({ channel, input, fields: icmListDirFields, ...handlers }));
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
const renameIcmEntryFields: RenameIcmEntryFields = ['path', 'updatedPages'];
const deleteIcmEntryFields: DeleteIcmEntryFields = ['deleted'];
// Note: the generated `IcmEntryReferencesFields` type can't actually express
// nested field selection into an `Array<TypedMap>` (a real ash_typescript
// codegen gap for anonymous embedded-map arrays, not a Resource
// relationship) — `ComplexFieldSelection` only special-cases Relationship /
// ComplexCalculation / direct-TypedMap / Union arrays, so `ArrayOf<TypedMap>`
// falls through to `never`. The backend action itself DOES accept this exact
// nested literal (confirmed in Task 5), so the assertion below is trusted
// runtime knowledge overriding an incomplete generated type, not a guess.
// `pages` (Task C3) is the AST-confirmed backlinks union — the workflow-
// frontmatter reference union (`workflows`) was deleted in Task 5 (Spec D
// §A); page-link rename integrity remains `Valea.ICM.LinkRewrite`'s job.
const icmEntryReferencesFields = [
  { pages: ['sourcePath', 'mount', 'linkText'] }
] as unknown as IcmEntryReferencesFields;

// `icm_search`/`icm_paths_exist` (Task C2). Same anonymous-embedded-map-array
// codegen gap as `icmEntryReferencesFields` above — `results` is an
// `Array<TypedMap>` action-return field on both, which `ComplexFieldSelection`
// can't express, so the generated `Fields` type collapses to `never` for the
// literal; cast, not inferred. Booleans ride INSIDE `icmPathsExistFields`'s
// `results` array item (`exists`), not as a top-level action-return field, so
// the top-level falsy-map-field workaround documented on
// `mailDoctorFields` does not apply here — see
// `Valea.Api.ICM`'s `:paths_exist` action.
const icmSearchFields = [
  { results: ['path', 'mount', 'title', 'snippet', 'terms'] },
  'skipped'
] as unknown as IcmSearchFields;
const icmPathsExistFields = [{ results: ['path', 'exists'] }] as unknown as IcmPathsExistFields;

const createAgentSessionFields: CreateAgentSessionFields = ['id', 'inputPath'];
const listAuditEntriesFields: ListAuditEntriesFields = ['entries'];

// Same anonymous-embedded-map-array codegen gap as `icmEntryReferencesFields`
// above (see its comment) — each of these nests field selection into an
// `Array<TypedMap>` action-return field, which `ComplexFieldSelection` can't
// express, so the generated `Fields` type collapses to `never` for the
// literal. The backend actions accept these exact nested literals (verified
// by the passing `agents_rpc_test.exs` suite).
const listAgentSessionsFields = [
  {
    sessions: ['id', 'kind', 'title', 'workflow', 'runId', 'startedAt', 'status', 'live', 'busy', 'icmMount', 'icmName']
  }
] as unknown as ListAgentSessionsFields;

// Task 6.2 — same anonymous-embedded-map-array codegen gap as
// `listAgentSessionsFields` above: `groups`/`sessions` (and `sessions`
// nested a level deeper inside each group) are `Array<TypedMap>`
// action-return fields, which `ComplexFieldSelection` can't express, so the
// generated `Fields` type collapses to `never` for the literal. The backend
// action accepts this exact nested literal (verified by
// `test/valea/api/agents_test.exs`).
const sessionSummarySelection = [
  'id',
  'kind',
  'title',
  'workflow',
  'runId',
  'startedAt',
  'status',
  'live',
  'busy',
  'icmMount',
  'icmName'
];
const listRecentSessionsByIcmFields = [
  { groups: ['mountKey', 'icmName', { sessions: sessionSummarySelection }] }
] as unknown as ListRecentSessionsByIcmFields;
const listSessionsForFields = [
  { sessions: sessionSummarySelection },
  'nextCursor'
] as unknown as ListSessionsFields;
const resumeAgentSessionFields: ResumeAgentSessionFields = ['id'];
const harnessDoctorFields = [
  'ok',
  { checks: ['id', 'status', 'detail', 'remedy'] }
] as unknown as HarnessDoctorFields;
const harnessConfigFields: HarnessConfigFields = ['command', 'approved', 'isDefault', 'defaultCommand'];
const setHarnessCommandFields: SetHarnessCommandFields = ['command', 'approved', 'isDefault', 'defaultCommand'];
const archiveAgentSessionFields: ArchiveAgentSessionFields = ['archived'];
const deleteAgentSessionFields: DeleteAgentSessionFields = ['deleted'];

// Cockpit (Spec D §C rewrite — see `Valea.Api.Cockpit`'s moduledoc). Same
// anonymous-embedded-map-array codegen gap as `icmEntryReferencesFields`
// above (`sections`/`recentSessions` are `Array<TypedMap>`, each carrying
// its own nested `Array<TypedMap>`/`TypedMap` fields, and `mail` is a
// nested `TypedMap` too), so the generated `CockpitTodayFields` type can't
// express this literal either — cast, not inferred. Selects every field:
// `normalizeCockpitToday` (`lib/today/cockpit.ts`) reads the whole payload.
const cockpitTodayFields = [
  {
    sections: [
      'mountKey',
      'icmName',
      'ok',
      'updatedAt',
      'notes',
      { prepared: ['title', 'summary', 'page'] },
      { openLoops: ['title', 'source'] }
    ]
  },
  {
    mail: [
      'account',
      'configured',
      'state',
      'pendingOps',
      'notices',
      'unreadCount',
      { unread: ['msgId', 'fromName', 'fromEmail', 'subject', 'date'] }
    ]
  },
  { calendar: ['eventsToday', { next: ['time', 'title'] }] },
  { recentSessions: ['id', 'title', 'startedAt', 'status', 'live'] }
] as unknown as CockpitTodayFields;

// Mail (Task 10 rework — account-scoped RPC surface, mail-as-maildir design
// spec E). Every top-level boolean-valued field here (`saved`, `accepted`,
// `started`, `ok`) is delivered under a STRING key by the backend
// (`Valea.Api.Mail`'s moduledoc documents the same falsy-map-field
// ash_typescript 0.17.3 workaround `Valea.Api.Queue` uses) — that's a
// runtime detail only, invisible at this field-selection layer since a JS
// object key is a string either way; no cast needed for these.
//
// `mailStatusFields` selects the RAW (unconstrained) `accounts` array —
// each entry keeps the exact snake_case shape `Valea.Mail.Engine.status/1`
// builds (`account`/`configured`/`credential`/`state`/`last_sync_at`/
// `last_error`/`username`/`workspace_id`/`pending_ops`/`held_folders`/
// `backfill`/`notices`, plus `valid`/`reason` for an invalid-config entry).
// Delivered verbatim to `stores/mail.svelte.ts`, whose
// `normalizeMailAccountStatus` owns the camelCase narrowing per entry.
const mailStatusFields: MailStatusFields = ['accounts'];
const removeMailAccountFields: RemoveMailAccountFields = ['removed'];
const purgeMailAccountFilesFields: PurgeMailAccountFilesFields = ['purged'];
const readoptMailAccountFields: ReadoptMailAccountFields = ['readopted'];
const discardHeldFolderFields: DiscardHeldFolderFields = ['discarded'];
const pushDraftToMailboxFields: PushDraftToMailboxFields = ['state'];
// `drafts` is an unconstrained `Array<Record<string, any>>` passthrough
// (string keys as `Valea.Api.Mail.draft_entry/3` writes them) — the store
// owns normalizing entries, same raw-delivery split as `mailStatusFields`.
const listMailDraftsFields: ListMailDraftsFields = ['drafts'];
const getMailDraftFields: GetMailDraftFields = ['content', 'path'];
const writeMailDraftFields: WriteMailDraftFields = ['name', 'saved'];
// The review snapshot's TYPED fields arrive camelCased; its three nested
// maps (`recipients`/`threading`/`identity`) are unconstrained passthroughs
// keeping `OpsExecutor.review_snapshot/2`'s snake keys, normalized by
// `stores/mail.svelte.ts` — same raw-delivery split as `mailStatusFields`.
const getMailDraftReviewFields: GetMailDraftReviewFields = [
  'content',
  'contentHash',
  'recipients',
  'subject',
  'attachments',
  'threading',
  'threadingWarning',
  'identity',
  'reviewFingerprint',
  'smtpConfigured'
];
const sendDraftFields: SendDraftFields = ['state'];
const resolveSendReviewFields: ResolveSendReviewFields = ['resolved'];
const retrySentCopyFields: RetrySentCopyFields = ['retried'];
const reviseMailDraftFields: ReviseMailDraftFields = ['sessionId', 'routed'];
// Same `Array<TypedMap>` codegen gap as `listMailMessagesFields` above.
const mailApplyOpsFields = [{ results: ['op', 'result', 'reason'] }] as unknown as MailApplyOpsFields;
const setupMailAccountFields: SetupMailAccountFields = ['saved'];
// `notifications` sits BESIDE `account:`, not inside it: it is a boolean that
// is `false` for every account that hasn't opted in, and the falsy-map-field
// bug nulls an atom-keyed `false` at any nesting depth (see
// `Valea.Api.Mail`'s action comment) — so the backend returns it top-level
// under a string key.
// `auth` is selected for the same reason every other field here is: the edit
// form has to send the account's WHOLE entry back on save (M6 task 15), and a
// mode it never read is a mode it would silently rewrite to `password`.
// `oauthClientId` is selected for exactly the same reason `auth` is: the edit
// form has to send the account's WHOLE entry back on save (M6 task 16), and an
// override it never read is an override it would silently drop.
const getMailAccountSettingsFields: GetMailAccountSettingsFields = [
  'notifications',
  {
    account: [
      'host',
      'port',
      'username',
      'auth',
      'oauthClientId',
      { smtp: ['host', 'port', 'security', 'username', 'from', 'fromName'] }
    ]
  }
];
const mailAutoconfigFields: MailAutoconfigFields = [
  { imap: ['host', 'port', 'security'] },
  { smtp: ['host', 'port', 'security'] },
  'source'
];
const setMailCredentialFields: SetMailCredentialFields = ['accepted'];
const startMailOauthFields: StartMailOauthFields = ['url'];
const mailSyncNowFields: MailSyncNowFields = ['started'];
const mailDoctorFields: MailDoctorFields = ['ok', 'checks'];
const createMailFoldersFields: CreateMailFoldersFields = ['created'];
// `inbox` (whether the message was legacy-inbox-only) is gone — the
// account-scoped `get_mail_message` only ever reads a real indexed view now.
const getMailMessageFields: GetMailMessageFields = ['message'];
const listTrustedMailSendersFields: ListTrustedMailSendersFields = ['senders'];
const setMailSenderTrustFields: SetMailSenderTrustFields = ['trusted'];

// Icms (task 3.4, `Valea.Api.Icms` — the C9 id/mount-key based replacement
// for `Valea.Api.Mounts`, kept registered until Phase 11). Same anonymous-
// embedded-map-array codegen gap as `listAgentSessionsFields` above (see
// the comment on `icmEntryReferencesFields`) — `icms` is an `Array<TypedMap>` action-return
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
// `adopt_icm` (Task 12/13) — mints the identity file and mounts by
// reference in one step; same plain top-level field shape as `mountIcmFields`.
const adoptIcmFields: AdoptIcmFields = ['mountKey', 'id'];
const createIcmFields: CreateIcmFields = ['mountKey', 'id'];
const setIcmEnabledFields: SetIcmEnabledFields = ['saved'];
const unmountIcmFields: UnmountIcmFields = ['unmounted'];
const icmDoctorFields: IcmDoctorFields = ['ok', 'checks'];
// Mail-access toggles (Mail settings) over the CONTEXT.md opt-in grammar —
// `access` is the same `Array<TypedMap>` codegen gap as `listIcmsFields`.
const listIcmMailAccessFields = [
  { access: ['mountKey', 'name', 'accounts'] }
] as unknown as ListIcmMailAccessFields;
const setIcmMailAccessFields: SetIcmMailAccessFields = ['saved', 'accounts'];

// `inspect_icm` (Task 10.1) — onboarding's mount-preview primitive, no
// `generation`/open-workspace requirement (see `Valea.Api.Icms`'s
// moduledoc). Plain top-level fields, same as `mountIcmFields` above.
// `adoptable` (Task 12) flags a plain folder Valea could adopt by writing a
// small identity file into it — see `IcmInspection.adoptable`'s doc comment
// in onboarding-path.ts.
const inspectIcmFields: InspectIcmFields = ['ok', 'name', 'description', 'reason', 'adoptable'];

// Skills (ICM skills design spec §Frontend, Task 9 — `Valea.Api.Skills`).
// `listSkills` selects the full per-row shape plus the top-level `dismissed`
// string array. Same anonymous-embedded-map-array codegen gap as
// `listIcmsFields` above (see the comment on `icmEntryReferencesFields`) —
// `skills` is a constrained `Array<TypedMap>`, which `ComplexFieldSelection`
// can't express, so the generated `ListSkillsFields` type collapses to
// `never` for the literal; cast, not inferred. `dismissed` is a plain
// top-level primitive field with no such gap, so it rides as a bare name
// alongside the nested `skills` selection, same shape as `icmSearchFields`'s
// `'skipped'`. The four mutating actions each return a plain `{ok}`
// top-level boolean, so `['ok']` needs no cast.
const listSkillsFields = [
  { skills: ['skillId', 'name', 'description', 'sourceUrl', 'license', 'pinned', 'state', 'installedVersion'] },
  'dismissed'
] as unknown as ListSkillsFields;
const installSkillFields: InstallSkillFields = ['ok'];
const updateSkillFields: UpdateSkillFields = ['ok'];
const uninstallSkillFields: UninstallSkillFields = ['ok'];
const dismissSkillsOfferFields: DismissSkillsOfferFields = ['ok'];

// `icm_tree` (task 4.2 re-key) — a single ICM's `{mountKey, title, tree}`,
// no more all-mounts grouped envelope (`mounts: [...]`). `mountKey`/`title`
// are plain typed top-level fields with no codegen gap; `tree` stays an
// unconstrained `Array<Record<string, any>>` (the recursive folder/page
// tree), so it needs no nested selection of its own, just the bare field
// name.
const icmTreeFields: IcmTreeFields = ['mountKey', 'title', 'tree'];

// `icm_list_dir` — the lazy single-level counterpart to `icm_tree`
// (`Valea.ICM.list_dir/2`): `entries` is one directory level's raw node
// maps, same unconstrained shape as `tree` above (folder entries just carry
// no `children`).
const icmListDirFields: IcmListDirFields = ['mountKey', 'title', 'entries'];

// Same anonymous-embedded-map-array codegen gap as `listAgentSessionsFields`
// above (see the comment on `icmEntryReferencesFields`) — `messages` is an
// `Array<TypedMap>` action-return field, which `ComplexFieldSelection`
// can't express, so the generated `Fields` type collapses to `never` for the
// literal. The backend action accepts this exact nested literal (verified
// by the passing `mail_rpc_test.exs` suite). `status` (the old flat
// review/processed marker) is gone — replaced by `flags` (real IMAP flag
// letters) and `viewPath` (the derived view's workspace-relative path).
const listMailMessagesFields = [
  { messages: ['msgId', 'fromName', 'fromEmail', 'subject', 'date', 'flags', 'hasAttachments', 'uid', 'path', 'viewPath'] }
] as unknown as ListMailMessagesFields;

// `list_mail_messages(threaded: true)` rows are `listMailMessagesFields`'
// shape plus `threadKey` (the conversation to open with `getMailThread`),
// `threadCount` (how many of the folder's messages the row stands for) and
// `threadUnread` (whether ANY of them is unread — the row's own `flags` are
// the newest message's and cannot answer that). A SEPARATE literal rather
// than three extra names on the flat one: the backend omits all three keys
// entirely from an unthreaded listing, so asking for them there would only
// promise a caller something that never arrives. Same `Array<TypedMap>`
// codegen gap, same cast.
const listMailThreadsFields = [
  {
    messages: [
      'msgId',
      'fromName',
      'fromEmail',
      'subject',
      'date',
      'flags',
      'hasAttachments',
      'uid',
      'path',
      'viewPath',
      'threadKey',
      'threadCount',
      'threadUnread'
    ]
  }
] as unknown as ListMailMessagesFields;

// `get_mail_thread` rows are the flat shape plus `folder` — one conversation
// spans folders, so each message says where it lives. Same codegen gap.
const getMailThreadFields = [
  {
    messages: [
      'msgId',
      'fromName',
      'fromEmail',
      'subject',
      'date',
      'flags',
      'hasAttachments',
      'uid',
      'path',
      'viewPath',
      'folder'
    ]
  }
] as unknown as GetMailThreadFields;

// `search_mail` hits are `listMailMessagesFields`' shape plus `snippet` (a
// body excerpt around the match), so search results render through the same
// list components as a folder listing. Same `Array<TypedMap>` codegen gap,
// same cast.
const searchMailFields = [
  {
    messages: [
      'msgId',
      'fromName',
      'fromEmail',
      'subject',
      'date',
      'flags',
      'hasAttachments',
      'uid',
      'path',
      'viewPath',
      'snippet'
    ]
  }
] as unknown as SearchMailFields;

// Same `Array<TypedMap>` codegen gap as `listMailMessagesFields` above —
// `folders` items arrive camelCased (`messageCount`/`backfillComplete`),
// matching `MailFolder` in `stores/mail.svelte.ts`.
const listMailFoldersFields = [
  { folders: ['name', 'dir', 'held', 'messageCount', 'backfillComplete'] }
] as unknown as ListMailFoldersFields;

function callCreateAgentSessionChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: CreateAgentSessionInput
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

function callResumeAgentSessionChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { sessionId: string; generation: number }
) {
  return wrapChannelCall((handlers) =>
    resumeAgentSessionChannel({ channel, input, fields: resumeAgentSessionFields, ...handlers })
  );
}

function callHarnessDoctorChannel(channel: NonNullable<ReturnType<typeof channelAvailable>>) {
  return wrapChannelCall((handlers) =>
    harnessDoctorChannel({ channel, fields: harnessDoctorFields, ...handlers })
  );
}

function callHarnessConfigChannel(channel: NonNullable<ReturnType<typeof channelAvailable>>) {
  return wrapChannelCall((handlers) =>
    harnessConfigChannel({ channel, fields: harnessConfigFields, ...handlers })
  );
}

function callSetHarnessCommandChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { command: string[] }
) {
  return wrapChannelCall((handlers) =>
    setHarnessCommandChannel({ channel, input, fields: setHarnessCommandFields, ...handlers })
  );
}

function callArchiveAgentSessionChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { sessionId: string; generation: number }
) {
  return wrapChannelCall((handlers) =>
    archiveAgentSessionChannel({ channel, input, fields: archiveAgentSessionFields, ...handlers })
  );
}

function callDeleteAgentSessionChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { sessionId: string; generation: number }
) {
  return wrapChannelCall((handlers) =>
    deleteAgentSessionChannel({ channel, input, fields: deleteAgentSessionFields, ...handlers })
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

/**
 * The optional v5 SMTP block of `setupMailAccount`, in this wrapper's own
 * un-prefixed shape — flattened onto the RPC's six `smtp*` arguments by
 * `smtpSetupInput` below. `null`/absent = a push-only account (the v4
 * behaviour verbatim); a blank string or `null` field means "not supplied",
 * which the backend turns back into its own default (port 587, `from`
 * defaulting to `username`).
 */
/**
 * One account's SASL mode (mail full-client plan, M6 task 15) — the closed
 * vocabulary `Valea.Mail.Settings`' `auth:` key takes, mirrored here because
 * `setup_mail_account` re-renders the account entry WHOLE: a save that omits
 * the mode writes `password`, so an edit of an `oauth2` account has to send it
 * back or the engine would start offering that account's access token as a
 * LOGIN password. Anything outside these two is refused backend-side
 * (`invalid_auth`), never defaulted.
 */
export type MailAuthMode = 'password' | 'oauth2';

/**
 * Which credential SLOT a `setMailCredential` call fills — `Valea.Api.Mail`'s
 * `credential_kind/1` vocabulary. `'imap'`/`'smtp'` are the two password
 * slots; `'oauth'` is an `auth: 'oauth2'` account's REFRESH token, and reaches
 * this call only on the resupply path (a restart handing back what the OS
 * keychain kept). A newly authorized token never travels through the RPC
 * surface at all — the provider redirect delivers it to `/oauth/callback`.
 */
export type MailCredentialKind = 'imap' | 'smtp' | 'oauth';

export type MailSmtpSetup = {
  host?: string | null;
  port?: number | null;
  /** `"starttls"` | `"tls"` — a STRING on the wire, validated against the port convention backend-side. */
  security?: string | null;
  username?: string | null;
  from?: string | null;
  fromName?: string | null;
};

function smtpSetupInput(smtp: MailSmtpSetup | null) {
  if (!smtp) return {};
  return {
    smtpHost: smtp.host ?? null,
    smtpPort: smtp.port ?? null,
    smtpSecurity: smtp.security ?? null,
    smtpUsername: smtp.username ?? null,
    smtpFrom: smtp.from ?? null,
    smtpFromName: smtp.fromName ?? null
  };
}

function callGetMailAccountSettingsChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { account: string }
) {
  return wrapChannelCall((handlers) =>
    getMailAccountSettingsChannel({ channel, input, fields: getMailAccountSettingsFields, ...handlers })
  );
}

function callMailAutoconfigChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { email: string }
) {
  return wrapChannelCall((handlers) =>
    mailAutoconfigChannel({ channel, input, fields: mailAutoconfigFields, ...handlers })
  );
}

function callSetupMailAccountChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: {
    account: string;
    host: string;
    port: number;
    username: string;
    generation: number;
    smtpHost?: string | null;
    smtpPort?: number | null;
    smtpSecurity?: string | null;
    smtpUsername?: string | null;
    smtpFrom?: string | null;
    smtpFromName?: string | null;
    notifications?: boolean | null;
    auth?: MailAuthMode | null;
    oauthClientId?: string | null;
  }
) {
  return wrapChannelCall((handlers) =>
    setupMailAccountChannel({ channel, input, fields: setupMailAccountFields, ...handlers })
  );
}

function callSetMailCredentialChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { account: string; secret: string; generation: number; kind?: MailCredentialKind }
) {
  return wrapChannelCall((handlers) =>
    setMailCredentialChannel({ channel, input, fields: setMailCredentialFields, ...handlers })
  );
}

function callStartMailOauthChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { account: string; generation: number }
) {
  return wrapChannelCall((handlers) =>
    startMailOauthChannel({ channel, input, fields: startMailOauthFields, ...handlers })
  );
}

function callMailSyncNowChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { account: string; generation: number }
) {
  return wrapChannelCall((handlers) => mailSyncNowChannel({ channel, input, fields: mailSyncNowFields, ...handlers }));
}

function callMailDoctorChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { account: string; generation: number }
) {
  return wrapChannelCall((handlers) => mailDoctorChannel({ channel, input, fields: mailDoctorFields, ...handlers }));
}

function callCreateMailFoldersChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { account: string; generation: number }
) {
  return wrapChannelCall((handlers) =>
    createMailFoldersChannel({ channel, input, fields: createMailFoldersFields, ...handlers })
  );
}

// The field selection follows the `threaded` flag, exactly as the HTTP path
// below does: a collapsed listing carries two fields a flat one does not.
function callListMailMessagesChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { account: string; folder: string; limit?: number; before?: string; threaded?: boolean }
) {
  return wrapChannelCall((handlers) =>
    listMailMessagesChannel({
      channel,
      input,
      fields: input.threaded ? listMailThreadsFields : listMailMessagesFields,
      ...handlers
    })
  );
}

function callGetMailThreadChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { account: string; threadKey: string }
) {
  return wrapChannelCall((handlers) =>
    getMailThreadChannel({ channel, input, fields: getMailThreadFields, ...handlers })
  );
}

function callSearchMailChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { account: string; query: string; limit?: number }
) {
  return wrapChannelCall((handlers) =>
    searchMailChannel({ channel, input, fields: searchMailFields, ...handlers })
  );
}

function callGetMailMessageChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { account: string; msgId: string }
) {
  return wrapChannelCall((handlers) =>
    getMailMessageChannel({ channel, input, fields: getMailMessageFields, ...handlers })
  );
}

function callListTrustedMailSendersChannel(channel: NonNullable<ReturnType<typeof channelAvailable>>) {
  return wrapChannelCall((handlers) =>
    listTrustedMailSendersChannel({ channel, fields: listTrustedMailSendersFields, ...handlers })
  );
}

function callSetMailSenderTrustChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { email: string; trusted: boolean; generation: number }
) {
  return wrapChannelCall((handlers) =>
    setMailSenderTrustChannel({ channel, input, fields: setMailSenderTrustFields, ...handlers })
  );
}

function callListMailFoldersChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { account: string }
) {
  return wrapChannelCall((handlers) =>
    listMailFoldersChannel({ channel, input, fields: listMailFoldersFields, ...handlers })
  );
}

function callRemoveMailAccountChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { account: string; generation: number }
) {
  return wrapChannelCall((handlers) =>
    removeMailAccountChannel({ channel, input, fields: removeMailAccountFields, ...handlers })
  );
}

function callPurgeMailAccountFilesChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { account: string; confirmation: string; generation: number }
) {
  return wrapChannelCall((handlers) =>
    purgeMailAccountFilesChannel({ channel, input, fields: purgeMailAccountFilesFields, ...handlers })
  );
}

function callReadoptMailAccountChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { account: string; confirmation: string; generation: number }
) {
  return wrapChannelCall((handlers) =>
    readoptMailAccountChannel({ channel, input, fields: readoptMailAccountFields, ...handlers })
  );
}

function callDiscardHeldFolderChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { account: string; folder: string; confirmation: string; generation: number }
) {
  return wrapChannelCall((handlers) =>
    discardHeldFolderChannel({ channel, input, fields: discardHeldFolderFields, ...handlers })
  );
}

function callMailApplyOpsChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { account: string; ops: Record<string, unknown>[]; generation: number }
) {
  return wrapChannelCall((handlers) =>
    mailApplyOpsChannel({ channel, input, fields: mailApplyOpsFields, ...handlers })
  );
}

function callPushDraftToMailboxChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { account: string; draftName: string; contentHash: string; generation: number }
) {
  return wrapChannelCall((handlers) =>
    pushDraftToMailboxChannel({ channel, input, fields: pushDraftToMailboxFields, ...handlers })
  );
}

function callListMailDraftsChannel(channel: NonNullable<ReturnType<typeof channelAvailable>>) {
  return wrapChannelCall((handlers) =>
    listMailDraftsChannel({ channel, fields: listMailDraftsFields, ...handlers })
  );
}

function callGetMailDraftChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { account: string; draftName: string }
) {
  return wrapChannelCall((handlers) =>
    getMailDraftChannel({ channel, input, fields: getMailDraftFields, ...handlers })
  );
}

function callWriteMailDraftChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: {
    account: string;
    name: string | null;
    content: string;
    baseHash: string | null;
    generation: number;
  }
) {
  return wrapChannelCall((handlers) =>
    writeMailDraftChannel({ channel, input, fields: writeMailDraftFields, ...handlers })
  );
}

function callGetMailDraftReviewChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { account: string; draftName: string }
) {
  return wrapChannelCall((handlers) =>
    getMailDraftReviewChannel({ channel, input, fields: getMailDraftReviewFields, ...handlers })
  );
}

function callSendDraftChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: {
    account: string;
    draftName: string;
    contentHash: string;
    reviewFingerprint: string | null;
    generation: number;
  }
) {
  return wrapChannelCall((handlers) => sendDraftChannel({ channel, input, fields: sendDraftFields, ...handlers }));
}

function callResolveSendReviewChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { account: string; opId: string; resolution: string; generation: number }
) {
  return wrapChannelCall((handlers) =>
    resolveSendReviewChannel({ channel, input, fields: resolveSendReviewFields, ...handlers })
  );
}

function callRetrySentCopyChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { account: string; opId: string; generation: number }
) {
  return wrapChannelCall((handlers) =>
    retrySentCopyChannel({ channel, input, fields: retrySentCopyFields, ...handlers })
  );
}

function callReviseMailDraftChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { account: string; draftName: string; feedback: string; mountKey: string; generation: number }
) {
  return wrapChannelCall((handlers) =>
    reviseMailDraftChannel({ channel, input, fields: reviseMailDraftFields, ...handlers })
  );
}

// -- calendar (Spec F) --------------------------------------------------------

// `sources` (like mail's `accounts`) and `events` are RAW unconstrained
// arrays — snake_case entries the calendar store normalizes itself; the
// typed top-level keys (`feedEnabled`/`valeaEventCount`/`configInvalid`)
// arrive camelCased like every typed field.
const calendarStatusFields: CalendarStatusFields = [
  'sources',
  'feedEnabled',
  'valeaEventCount',
  'valeaInvalid',
  'configInvalid'
];
const listCalendarEventsFields: ListCalendarEventsFields = ['events'];
const setupCalendarSourceFields: SetupCalendarSourceFields = ['saved'];
const setCalendarSourceUrlFields: SetCalendarSourceUrlFields = ['accepted'];
const removeCalendarSourceFields: RemoveCalendarSourceFields = ['removed'];
const purgeCalendarSourceFilesFields: PurgeCalendarSourceFilesFields = ['purged'];
const calendarSyncNowFields: CalendarSyncNowFields = ['started'];
const calendarDoctorFields: CalendarDoctorFields = ['ok', 'checks'];
const createValeaEventFields: CreateValeaEventFields = ['created', 'path'];
const updateValeaEventFields: UpdateValeaEventFields = ['updated'];
const deleteValeaEventFields: DeleteValeaEventFields = ['deleted'];
const enableCalendarFeedFields: EnableCalendarFeedFields = ['token'];
const rotateCalendarFeedTokenFields: RotateCalendarFeedTokenFields = ['token'];

/** Valea-event attributes shared by create/update — generated-input camelCase (`allDay`). */
export type ValeaEventAttrs = {
  title: string;
  start: string;
  end?: string | null;
  allDay?: boolean | null;
  location?: string | null;
  status?: string | null;
  description?: string | null;
};

function callCalendarStatusChannel(channel: NonNullable<ReturnType<typeof channelAvailable>>) {
  return wrapChannelCall((handlers) =>
    calendarStatusChannel({ channel, fields: calendarStatusFields, ...handlers })
  );
}

function callSetupCalendarSourceChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { source: string; name: string; generation: number }
) {
  return wrapChannelCall((handlers) =>
    setupCalendarSourceChannel({ channel, input, fields: setupCalendarSourceFields, ...handlers })
  );
}

function callSetCalendarSourceUrlChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { source: string; url: string; generation: number }
) {
  return wrapChannelCall((handlers) =>
    setCalendarSourceUrlChannel({ channel, input, fields: setCalendarSourceUrlFields, ...handlers })
  );
}

function callRemoveCalendarSourceChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { source: string; generation: number }
) {
  return wrapChannelCall((handlers) =>
    removeCalendarSourceChannel({ channel, input, fields: removeCalendarSourceFields, ...handlers })
  );
}

function callPurgeCalendarSourceFilesChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { source: string; confirmation: string; generation: number }
) {
  return wrapChannelCall((handlers) =>
    purgeCalendarSourceFilesChannel({ channel, input, fields: purgeCalendarSourceFilesFields, ...handlers })
  );
}

function callCalendarSyncNowChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { source: string; generation: number }
) {
  return wrapChannelCall((handlers) =>
    calendarSyncNowChannel({ channel, input, fields: calendarSyncNowFields, ...handlers })
  );
}

function callCalendarDoctorChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { source: string; generation: number }
) {
  return wrapChannelCall((handlers) =>
    calendarDoctorChannel({ channel, input, fields: calendarDoctorFields, ...handlers })
  );
}

function callListCalendarEventsChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { from: string; to: string; zone: string }
) {
  return wrapChannelCall((handlers) =>
    listCalendarEventsChannel({ channel, input, fields: listCalendarEventsFields, ...handlers })
  );
}

function callCreateValeaEventChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: ValeaEventAttrs & { name: string; generation: number }
) {
  return wrapChannelCall((handlers) =>
    createValeaEventChannel({ channel, input, fields: createValeaEventFields, ...handlers })
  );
}

function callUpdateValeaEventChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: ValeaEventAttrs & { name: string; generation: number }
) {
  return wrapChannelCall((handlers) =>
    updateValeaEventChannel({ channel, input, fields: updateValeaEventFields, ...handlers })
  );
}

function callDeleteValeaEventChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { name: string; confirmation: string; generation: number }
) {
  return wrapChannelCall((handlers) =>
    deleteValeaEventChannel({ channel, input, fields: deleteValeaEventFields, ...handlers })
  );
}

function callEnableCalendarFeedChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { generation: number }
) {
  return wrapChannelCall((handlers) =>
    enableCalendarFeedChannel({ channel, input, fields: enableCalendarFeedFields, ...handlers })
  );
}

function callRotateCalendarFeedTokenChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { generation: number }
) {
  return wrapChannelCall((handlers) =>
    rotateCalendarFeedTokenChannel({ channel, input, fields: rotateCalendarFeedTokenFields, ...handlers })
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

function callAdoptIcmChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { path: string; name: string; generation: number }
) {
  return wrapChannelCall((handlers) => adoptIcmChannel({ channel, input, fields: adoptIcmFields, ...handlers }));
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

function callListIcmMailAccessChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { generation: number }
) {
  return wrapChannelCall((handlers) =>
    listIcmMailAccessChannel({ channel, input, fields: listIcmMailAccessFields, ...handlers })
  );
}

function callSetIcmMailAccessChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: { mountKey: string; account: string; enabled: boolean; generation: number }
) {
  return wrapChannelCall((handlers) =>
    setIcmMailAccessChannel({ channel, input, fields: setIcmMailAccessFields, ...handlers })
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

function callListSkillsChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: ListSkillsInput
) {
  return wrapChannelCall((handlers) =>
    listSkillsChannel({ channel, input, fields: listSkillsFields, ...handlers })
  );
}

function callInstallSkillChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: InstallSkillInput
) {
  return wrapChannelCall((handlers) =>
    installSkillChannel({ channel, input, fields: installSkillFields, ...handlers })
  );
}

function callUpdateSkillChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: UpdateSkillInput
) {
  return wrapChannelCall((handlers) =>
    updateSkillChannel({ channel, input, fields: updateSkillFields, ...handlers })
  );
}

function callUninstallSkillChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: UninstallSkillInput
) {
  return wrapChannelCall((handlers) =>
    uninstallSkillChannel({ channel, input, fields: uninstallSkillFields, ...handlers })
  );
}

function callDismissSkillsOfferChannel(
  channel: NonNullable<ReturnType<typeof channelAvailable>>,
  input: DismissSkillsOfferInput
) {
  return wrapChannelCall((handlers) =>
    dismissSkillsOfferChannel({ channel, input, fields: dismissSkillsOfferFields, ...handlers })
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

/**
 * Mints a one-file, short-lived `ticket` for `(mountKey, path)` — the
 * credential a `/files/raw` request can carry when it CANNOT send the
 * `x-valea-token` header, i.e. when the fetch is performed by a new browser
 * tab or by the OS browser rather than by this page (see
 * `rawFileOpenUrl`, and `ValeaWeb.FilesController`'s "Tickets" moduledoc
 * section for why that is a narrower grant than the header it replaces).
 *
 * Plain HTTP for the same reason as `uploadImage` above — `POST
 * /files/ticket` is not an Ash RPC action — and carrying the same header,
 * which is the gate: a ticket is only obtainable BY the token holder.
 */
async function fileTicket(mountKey: string, path: string): Promise<ApiResult<string>> {
  let response: Response;
  try {
    response = await fetch('/files/ticket', {
      method: 'POST',
      body: JSON.stringify({ mount_key: mountKey, path }),
      headers: { 'content-type': 'application/json', 'x-valea-token': controlToken() }
    });
  } catch {
    return { ok: false, error: 'network_error' };
  }

  const payload: unknown = await response.json().catch(() => null);
  const ticket =
    payload && typeof payload === 'object' ? (payload as Record<string, unknown>).ticket : null;

  if (!response.ok || typeof ticket !== 'string' || ticket === '') {
    return { ok: false, error: 'ticket_failed' };
  }

  return { ok: true, data: ticket };
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

  // `icm_list_dir` — ONE directory level of one ICM (`""` = the mount's own
  // root), the lazy counterpart to `icmTree` above. `IcmStore` fetches root
  // levels on load and deeper levels on demand (folder expand / deep link)
  // instead of walking whole mounts up front.
  icmListDir: (mountKey: string, path: string, generation: number) =>
    runRpc(
      (channel) => callIcmListDirChannel(channel, { mountKey, path, generation }),
      () => httpIcmListDir(withAuth({ input: { mountKey, path, generation }, fields: icmListDirFields }))
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
  //
  // Task 9 (Spec D §B): the `kind` argument is gone — the server always
  // creates a `chat` session now. `opts.contextDoc`/`opts.input` are raw
  // string-keyed ICM/workspace locators, sent verbatim (same convention the
  // deleted run_workflow used for `input_locator`) — `contextDoc` names a
  // document already covered by the session's own read roots (no extra
  // grant); `input` is resolved server-side to ONE exact read path, granted,
  // and returned as `inputPath` so the caller can reference exactly the
  // file it unlocked in its opening prompt.
  // Task 14 (mail spec §"Mount & containment"): `opts.includeMounts` opts the
  // session into mail account mounts by key (`mail-<slug>`, default `[]`) —
  // each must name an existing, enabled, non-degraded mail mount; the backend
  // rejects an ICM key as `include_not_mail` and anything unavailable as
  // `mail_unavailable`, fail-closed, before any session starts.
  createAgentSession: (
    mountKey: string,
    generation: number,
    opts?: {
      /** Raw string-keyed ICM locator — sent verbatim ({kind:'icm', icm_id, path}). */
      contextDoc?: { kind: 'icm'; icm_id: string; path: string };
      /** Raw string-keyed ICM/workspace locator granted as one exact read path. */
      input?: { kind: 'workspace'; path: string } | { kind: 'icm'; icm_id: string; path: string };
      /** Mail mount keys (mail-<slug>) to include in the session scope. */
      includeMounts?: string[];
    }
  ) =>
    runRpc(
      (channel) =>
        callCreateAgentSessionChannel(channel, {
          mountKey,
          generation,
          contextDoc: opts?.contextDoc ?? null,
          input: opts?.input ?? null,
          includeMounts: opts?.includeMounts ?? []
        }),
      () =>
        httpCreateAgentSession(
          withAuth({
            input: {
              mountKey,
              generation,
              contextDoc: opts?.contextDoc ?? null,
              input: opts?.input ?? null,
              includeMounts: opts?.includeMounts ?? []
            },
            fields: createAgentSessionFields
          })
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

  // Same-transcript resume (replaced the deleted create_follow_up): the
  // server re-resolves scope from the ORIGINAL transcript's own meta and
  // revives the session under the SAME id/transcript. `icm_unavailable`
  // (ICM since unmounted/disabled/degraded), `not_found`, and
  // `workspace_changed` surface as ordinary RPC errors.
  resumeAgentSession: (sessionId: string, generation: number) =>
    runRpc(
      (channel) => callResumeAgentSessionChannel(channel, { sessionId, generation }),
      () =>
        httpResumeAgentSession(
          withAuth({ input: { sessionId, generation }, fields: resumeAgentSessionFields })
        )
    ),

  harnessDoctor: () =>
    runRpc(callHarnessDoctorChannel, () => httpHarnessDoctor(withAuth({ fields: harnessDoctorFields }))),

  harnessConfig: () =>
    runRpc(callHarnessConfigChannel, () => httpHarnessConfig(withAuth({ fields: harnessConfigFields }))),

  setHarnessCommand: (command: string[]) =>
    runRpc(
      (channel) => callSetHarnessCommandChannel(channel, { command }),
      () => httpSetHarnessCommand(withAuth({ input: { command }, fields: setHarnessCommandFields }))
    ),

  archiveAgentSession: (sessionId: string, generation: number) =>
    runRpc(
      (channel) => callArchiveAgentSessionChannel(channel, { sessionId, generation }),
      () =>
        httpArchiveAgentSession(
          withAuth({ input: { sessionId, generation }, fields: archiveAgentSessionFields })
        )
    ),

  deleteAgentSession: (sessionId: string, generation: number) =>
    runRpc(
      (channel) => callDeleteAgentSessionChannel(channel, { sessionId, generation }),
      () =>
        httpDeleteAgentSession(
          withAuth({ input: { sessionId, generation }, fields: deleteAgentSessionFields })
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

  // Mail (account-scoped RPC surface, mail-as-maildir design spec E §RPC
  // surface). `mailStatus`/`listMailMessages`/`getMailMessage` deliver
  // their `accounts`/`messages`/`message` payloads RAW (unconstrained or
  // per-item passthrough) — `stores/mail.svelte.ts` owns normalizing those
  // into camelCase app-facing shapes, same raw-delivery split
  // `IcmPageData.frontmatter` uses. Every wrapper below takes an explicit
  // `account` slug — there is no implicit "the one configured account".
  // `mailStatus` itself takes none (the action lists every account).

  mailStatus: () => runRpc(callMailStatusChannel, () => httpMailStatus(withAuth({ fields: mailStatusFields }))),

  // `smtp` is the OPTIONAL v5 send block (spec G §Configuration &
  // credentials), flattened onto the action's six `smtp*` arguments. Passing
  // `null` (the default) means a push-only account — byte-for-byte the v4
  // call. An smtp block the backend can't load is REFUSED (`invalid_smtp`)
  // rather than written, so the account keeps syncing over IMAP.
  //
  // `notifications` is the per-account OS-notification opt-in. It defaults to
  // `false` HERE rather than being left off the input: the action re-renders
  // the account entry whole, so an omitted argument writes the flag off — a
  // caller that means "keep it on" must say so on every save.
  //
  // `auth` (M6 task 15) is the same contract with a sharper edge: it defaults
  // to `'password'`, so an EDIT of an `oauth2` account that doesn't pass its
  // mode back rewrites the account as a password account — and the next IMAP
  // connect would then put the access token in the LOGIN password field. Every
  // caller that saves an existing account must carry the mode through (see
  // `submitMailSetup`).
  setupMailAccount: (
    account: string,
    host: string,
    port: number,
    username: string,
    generation: number,
    smtp: MailSmtpSetup | null = null,
    notifications = false,
    auth: MailAuthMode = 'password',
    oauthClientId: string | null = null
  ) =>
    runRpc(
      (channel) =>
        callSetupMailAccountChannel(channel, {
          account,
          host,
          port,
          username,
          generation,
          notifications,
          auth,
          oauthClientId,
          ...smtpSetupInput(smtp)
        }),
      () =>
        httpSetupMailAccount(
          withAuth({
            input: {
              account,
              host,
              port,
              username,
              generation,
              notifications,
              auth,
              oauthClientId,
              ...smtpSetupInput(smtp)
            },
            fields: setupMailAccountFields
          })
        )
    ),

  // The non-secret connection config of one account (host/port/username +
  // smtp block), for the settings form's edit-mode prefill.
  getMailAccountSettings: (account: string) =>
    runRpc(
      (channel) => callGetMailAccountSettingsChannel(channel, { account }),
      () =>
        httpGetMailAccountSettings(
          withAuth({ input: { account }, fields: getMailAccountSettingsFields })
        )
    ),

  // Best-effort IMAP/SMTP discovery from an email address's domain
  // (`Valea.Mail.Autoconfig`: ISPDB / provider autoconfig / MX / SRV /
  // heuristic). `imap`/`smtp` are null when nothing was found.
  mailAutoconfig: (email: string) =>
    runRpc(
      (channel) => callMailAutoconfigChannel(channel, { email }),
      () => httpMailAutoconfig(withAuth({ input: { email }, fields: mailAutoconfigFields }))
    ),

  // `kind` selects WHICH credential slot the secret fills — omitted means
  // `imap`, exactly what this call has always meant. The two are separate
  // keychain entries and separate RAM-only closures per Engine; an SMTP auth
  // failure never pauses the IMAP sync.
  setMailCredential: (account: string, secret: string, generation: number, kind?: MailCredentialKind) =>
    runRpc(
      (channel) => callSetMailCredentialChannel(channel, { account, secret, generation, ...(kind ? { kind } : {}) }),
      () =>
        httpSetMailCredential(
          withAuth({
            input: { account, secret, generation, ...(kind ? { kind } : {}) },
            fields: setMailCredentialFields
          })
        )
    ),

  // Mailbox sign-in, step one (M6 task 16): mints the account's state + PKCE
  // pair backend-side and returns the provider's consent URL to open in the
  // user's BROWSER. Nothing secret comes back — the authorization code and the
  // refresh token are handled entirely by the backend's `/oauth/callback`
  // route, which the provider redirects to. Mutating (it parks a pending
  // flow), hence the `generation`.
  startMailOauth: (account: string, generation: number) =>
    runRpc(
      (channel) => callStartMailOauthChannel(channel, { account, generation }),
      () => httpStartMailOauth(withAuth({ input: { account, generation }, fields: startMailOauthFields }))
    ),

  mailSyncNow: (account: string, generation: number) =>
    runRpc(
      (channel) => callMailSyncNowChannel(channel, { account, generation }),
      () => httpMailSyncNow(withAuth({ input: { account, generation }, fields: mailSyncNowFields }))
    ),

  mailDoctor: (account: string, generation: number) =>
    runRpc(
      (channel) => callMailDoctorChannel(channel, { account, generation }),
      () => httpMailDoctor(withAuth({ input: { account, generation }, fields: mailDoctorFields }))
    ),

  createMailFolders: (account: string, generation: number) =>
    runRpc(
      (channel) => callCreateMailFoldersChannel(channel, { account, generation }),
      () => httpCreateMailFolders(withAuth({ input: { account, generation }, fields: createMailFoldersFields }))
    ),

  // `threaded: true` collapses the folder by conversation — one row per
  // thread, the newest message representing it, carrying `threadKey` and
  // `threadCount`. Omitted (the default) it is the flat per-message listing,
  // byte-for-byte as before: the backend leaves the two thread fields out of
  // those rows entirely.
  listMailMessages: (
    account: string,
    folder: string,
    opts: { limit?: number; before?: string; threaded?: boolean } = {}
  ) =>
    runRpc(
      (channel) => callListMailMessagesChannel(channel, { account, folder, ...opts }),
      () =>
        httpListMailMessages(
          withAuth({
            input: { account, folder, ...opts },
            fields: opts.threaded ? listMailThreadsFields : listMailMessagesFields
          })
        )
    ),

  // One conversation, oldest message first, across every folder it touches.
  // `threadKey` comes from a `listMailMessages(..., { threaded: true })` row.
  getMailThread: (account: string, threadKey: string) =>
    runRpc(
      (channel) => callGetMailThreadChannel(channel, { account, threadKey }),
      () => httpGetMailThread(withAuth({ input: { account, threadKey }, fields: getMailThreadFields }))
    ),

  // Full-text search across one account's landed messages. `query` is plain
  // text the user typed — the backend turns it into quoted prefix terms, so
  // nothing here needs (or is able) to escape it.
  searchMail: (account: string, query: string, opts: { limit?: number } = {}) =>
    runRpc(
      (channel) => callSearchMailChannel(channel, { account, query, ...opts }),
      () => httpSearchMail(withAuth({ input: { account, query, ...opts }, fields: searchMailFields }))
    ),

  getMailMessage: (account: string, msgId: string) =>
    runRpc(
      (channel) => callGetMailMessageChannel(channel, { account, msgId }),
      () => httpGetMailMessage(withAuth({ input: { account, msgId }, fields: getMailMessageFields }))
    ),

  listMailFolders: (account: string) =>
    runRpc(
      (channel) => callListMailFoldersChannel(channel, { account }),
      () => httpListMailFolders(withAuth({ input: { account }, fields: listMailFoldersFields }))
    ),

  // The trusted-senders list behind HTML mail's remote-content gate
  // (`Valea.Mail.Trust`) — workspace-scoped, file-first
  // (config/mail-trusted-senders.json).
  listTrustedMailSenders: () =>
    runRpc(callListTrustedMailSendersChannel, () =>
      httpListTrustedMailSenders(withAuth({ fields: listTrustedMailSendersFields }))
    ),

  setMailSenderTrust: (email: string, trusted: boolean, generation: number) =>
    runRpc(
      (channel) => callSetMailSenderTrustChannel(channel, { email, trusted, generation }),
      () =>
        httpSetMailSenderTrust(
          withAuth({ input: { email, trusted, generation }, fields: setMailSenderTrustFields })
        )
    ),

  removeMailAccount: (account: string, generation: number) =>
    runRpc(
      (channel) => callRemoveMailAccountChannel(channel, { account, generation }),
      () => httpRemoveMailAccount(withAuth({ input: { account, generation }, fields: removeMailAccountFields }))
    ),

  // The two destructive/recovery actions and the held-folder discard all
  // require a typed `confirmation` (the exact slug, or the exact folder
  // name) — passed through verbatim; the backend compares, never the UI
  // alone (mail design spec E §UI/doctor).
  purgeMailAccountFiles: (account: string, confirmation: string, generation: number) =>
    runRpc(
      (channel) => callPurgeMailAccountFilesChannel(channel, { account, confirmation, generation }),
      () =>
        httpPurgeMailAccountFiles(
          withAuth({ input: { account, confirmation, generation }, fields: purgeMailAccountFilesFields })
        )
    ),

  readoptMailAccount: (account: string, confirmation: string, generation: number) =>
    runRpc(
      (channel) => callReadoptMailAccountChannel(channel, { account, confirmation, generation }),
      () =>
        httpReadoptMailAccount(
          withAuth({ input: { account, confirmation, generation }, fields: readoptMailAccountFields })
        )
    ),

  discardHeldFolder: (account: string, folder: string, confirmation: string, generation: number) =>
    runRpc(
      (channel) => callDiscardHeldFolderChannel(channel, { account, folder, confirmation, generation }),
      () =>
        httpDiscardHeldFolder(
          withAuth({ input: { account, folder, confirmation, generation }, fields: discardHeldFolderFields })
        )
    ),

  // The UI's archive/flag actions — the SAME declared-op vocabulary agents
  // write as ops files, executed through the same serialized executor. Each
  // op map is an unconstrained :map passed VERBATIM (no camelization):
  // {op:'move', msg_id, from, to} / {op:'flag', msg_id, folder, add,
  // remove} — snake keys, exactly as `Valea.Mail.OpsFile.parse_one/1`
  // validates. Per-op results come back positionally ({op: index, result,
  // reason}).
  applyMailOps: (account: string, ops: Record<string, unknown>[], generation: number) =>
    runRpc(
      (channel) => callMailApplyOpsChannel(channel, { account, ops, generation }),
      () => httpMailApplyOps(withAuth({ input: { account, ops, generation }, fields: mailApplyOpsFields }))
    ),

  // One of the two user-initiated outbound actions (`sendDraft` is the
  // other). Valea transmits mail only on an explicit human action, hash-bound
  // to the exact draft the human reviewed; agents have no path to this RPC
  // surface, and no code path retransmits — see
  // docs/superpowers/specs/2026-07-26-mail-smtp-send-design.md §Invariant
  // rewrite. `contentHash` is the sha256 hex of the exact bytes
  // `getMailDraft` returned, binding the push to that revision.
  pushDraftToMailbox: (account: string, draftName: string, contentHash: string, generation: number) =>
    runRpc(
      (channel) => callPushDraftToMailboxChannel(channel, { account, draftName, contentHash, generation }),
      () =>
        httpPushDraftToMailbox(
          withAuth({ input: { account, draftName, contentHash, generation }, fields: pushDraftToMailboxFields })
        )
    ),

  listMailDrafts: () =>
    runRpc(callListMailDraftsChannel, () => httpListMailDrafts(withAuth({ fields: listMailDraftsFields }))),

  getMailDraft: (account: string, draftName: string) =>
    runRpc(
      (channel) => callGetMailDraftChannel(channel, { account, draftName }),
      () => httpGetMailDraft(withAuth({ input: { account, draftName }, fields: getMailDraftFields }))
    ),

  // THE human's pen for draft files — the only way the composer puts bytes
  // under an account's `drafts/`. `name: null` mints one
  // (`YYYYMMDDTHHMMSS-<subject-slug>.md`) and returns it. `baseHash` is the
  // sha256 hex of the bytes this edit started from (what `getMailDraft`
  // returned): compare-and-swap, so an edit made against bytes an agent has
  // since replaced fails `content_changed` instead of clobbering them. Pass
  // `null` ONLY to create — an existing draft with no base hash is refused
  // for the same reason.
  writeMailDraft: (
    account: string,
    name: string | null,
    content: string,
    baseHash: string | null,
    generation: number
  ) =>
    runRpc(
      (channel) => callWriteMailDraftChannel(channel, { account, name, content, baseHash, generation }),
      () =>
        httpWriteMailDraft(
          withAuth({ input: { account, name, content, baseHash, generation }, fields: writeMailDraftFields })
        )
    ),

  // -- send (spec G). THE atomic review snapshot behind the confirm modal:
  // one no-follow read backend-side, from which the rendered recipients/
  // subject/identity/threading AND both confirm tokens (`contentHash`,
  // `reviewFingerprint`) come. Read-only — it claims nothing and touches no
  // network.
  getMailDraftReview: (account: string, draftName: string) =>
    runRpc(
      (channel) => callGetMailDraftReviewChannel(channel, { account, draftName }),
      () => httpGetMailDraftReview(withAuth({ input: { account, draftName }, fields: getMailDraftReviewFields }))
    ),

  // The ONE action in this codebase that transmits — human-only by
  // construction (this surface is control-token-gated; agent sessions have
  // no transport to it). Both tokens come VERBATIM from the review response
  // the human confirmed: `reviewFingerprint` binds the sending identity and
  // the resolved threading, which the content hash alone cannot cover.
  sendDraft: (
    account: string,
    draftName: string,
    contentHash: string,
    reviewFingerprint: string | null,
    generation: number
  ) =>
    runRpc(
      (channel) =>
        callSendDraftChannel(channel, { account, draftName, contentHash, reviewFingerprint, generation }),
      () =>
        httpSendDraft(
          withAuth({
            input: { account, draftName, contentHash, reviewFingerprint, generation },
            fields: sendDraftFields
          })
        )
    ),

  // The human's verdict on a send parked in `send_review`: `sent` runs the
  // idempotent Sent copy and completes the op, `not_sent` rejects it and
  // reverts the draft for another explicit click. Neither transmits.
  resolveSendReview: (account: string, opId: string, resolution: 'sent' | 'not_sent', generation: number) =>
    runRpc(
      (channel) => callResolveSendReviewChannel(channel, { account, opId, resolution, generation }),
      () =>
        httpResolveSendReview(
          withAuth({ input: { account, opId, resolution, generation }, fields: resolveSendReviewFields })
        )
    ),

  // Re-runs ONLY the idempotent Sent-copy append of a send that completed
  // with a `sent_copy_failed` notice — the mail is already transmitted, and
  // this path cannot reach the SMTP transport at all.
  retrySentCopy: (account: string, opId: string, generation: number) =>
    runRpc(
      (channel) => callRetrySentCopyChannel(channel, { account, opId, generation }),
      () => httpRetrySentCopy(withAuth({ input: { account, opId, generation }, fields: retrySentCopyFields }))
    ),

  // "Request changes" (spec G §UI): hand feedback on a draft to an agent,
  // which edits the file in place. The backend owns the correlation — a live
  // session whose input locator already names this draft gets the feedback as
  // another turn (`routed: 'existing'`), otherwise one is created on
  // `mountKey` with the account's mail mount included (`routed: 'new'`), its
  // opening prompt seeded SERVER-side. Unlike every other session entry point
  // here, nothing is stashed client-side: the caller may never navigate to
  // the session at all.
  reviseMailDraft: (account: string, draftName: string, feedback: string, mountKey: string, generation: number) =>
    runRpc(
      (channel) => callReviseMailDraftChannel(channel, { account, draftName, feedback, mountKey, generation }),
      () =>
        httpReviseMailDraft(
          withAuth({ input: { account, draftName, feedback, mountKey, generation }, fields: reviseMailDraftFields })
        )
    ),

  // -- calendar (Spec F). `calendarStatus`/`listCalendarEvents` deliver their
  // `sources`/`events` arrays RAW (snake_case entries) — the calendar store
  // owns normalizing them, same raw-delivery split as `mailStatusFields`.

  calendarStatus: () =>
    runRpc(callCalendarStatusChannel, () => httpCalendarStatus(withAuth({ fields: calendarStatusFields }))),

  setupCalendarSource: (source: string, name: string, generation: number) =>
    runRpc(
      (channel) => callSetupCalendarSourceChannel(channel, { source, name, generation }),
      () => httpSetupCalendarSource(withAuth({ input: { source, name, generation }, fields: setupCalendarSourceFields }))
    ),

  setCalendarSourceUrl: (source: string, url: string, generation: number) =>
    runRpc(
      (channel) => callSetCalendarSourceUrlChannel(channel, { source, url, generation }),
      () =>
        httpSetCalendarSourceUrl(withAuth({ input: { source, url, generation }, fields: setCalendarSourceUrlFields }))
    ),

  removeCalendarSource: (source: string, generation: number) =>
    runRpc(
      (channel) => callRemoveCalendarSourceChannel(channel, { source, generation }),
      () => httpRemoveCalendarSource(withAuth({ input: { source, generation }, fields: removeCalendarSourceFields }))
    ),

  purgeCalendarSourceFiles: (source: string, confirmation: string, generation: number) =>
    runRpc(
      (channel) => callPurgeCalendarSourceFilesChannel(channel, { source, confirmation, generation }),
      () =>
        httpPurgeCalendarSourceFiles(
          withAuth({ input: { source, confirmation, generation }, fields: purgeCalendarSourceFilesFields })
        )
    ),

  calendarSyncNow: (source: string, generation: number) =>
    runRpc(
      (channel) => callCalendarSyncNowChannel(channel, { source, generation }),
      () => httpCalendarSyncNow(withAuth({ input: { source, generation }, fields: calendarSyncNowFields }))
    ),

  calendarDoctor: (source: string, generation: number) =>
    runRpc(
      (channel) => callCalendarDoctorChannel(channel, { source, generation }),
      () => httpCalendarDoctor(withAuth({ input: { source, generation }, fields: calendarDoctorFields }))
    ),

  listCalendarEvents: (from: string, to: string, zone: string) =>
    runRpc(
      (channel) => callListCalendarEventsChannel(channel, { from, to, zone }),
      () => httpListCalendarEvents(withAuth({ input: { from, to, zone }, fields: listCalendarEventsFields }))
    ),

  createValeaEvent: (name: string, attrs: ValeaEventAttrs, generation: number) =>
    runRpc(
      (channel) => callCreateValeaEventChannel(channel, { name, ...attrs, generation }),
      () =>
        httpCreateValeaEvent(withAuth({ input: { name, ...attrs, generation }, fields: createValeaEventFields }))
    ),

  updateValeaEvent: (name: string, attrs: ValeaEventAttrs, generation: number) =>
    runRpc(
      (channel) => callUpdateValeaEventChannel(channel, { name, ...attrs, generation }),
      () =>
        httpUpdateValeaEvent(withAuth({ input: { name, ...attrs, generation }, fields: updateValeaEventFields }))
    ),

  deleteValeaEvent: (name: string, confirmation: string, generation: number) =>
    runRpc(
      (channel) => callDeleteValeaEventChannel(channel, { name, confirmation, generation }),
      () =>
        httpDeleteValeaEvent(
          withAuth({ input: { name, confirmation, generation }, fields: deleteValeaEventFields })
        )
    ),

  enableCalendarFeed: (generation: number) =>
    runRpc(
      (channel) => callEnableCalendarFeedChannel(channel, { generation }),
      () => httpEnableCalendarFeed(withAuth({ input: { generation }, fields: enableCalendarFeedFields }))
    ),

  rotateCalendarFeedToken: (generation: number) =>
    runRpc(
      (channel) => callRotateCalendarFeedTokenChannel(channel, { generation }),
      () => httpRotateCalendarFeedToken(withAuth({ input: { generation }, fields: rotateCalendarFeedTokenFields }))
    ),

  // Icms (task 3.4, `Valea.Api.Icms`). `listIcms` delivers its `icms` array
  // RAW (unconstrained per-item shape at this layer, though already
  // camelCased by ash_typescript — see `listIcmsFields`'s comment above) —
  // `stores/mounts.svelte.ts` owns casting it to `MountSummary[]`, same
  // raw-delivery split `AuditStore` uses for its own list RPC.
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

  // `adopt_icm` (Task 12/13) — mints a small identity file (`icm.yaml`,
  // `{format: 2, id, name}`) into a plain folder that isn't a Valea ICM yet
  // (see `IcmInspection.adoptable`'s doc comment in onboarding-path.ts),
  // then mounts it by reference in the same step — the one consented write
  // the adopt-a-folder consent step gates. `path` is passed through exactly
  // as picked/typed, same contract `mountIcm` documents above.
  adoptIcm: (path: string, name: string, generation: number) =>
    runRpc(
      (channel) => callAdoptIcmChannel(channel, { path, name, generation }),
      () => httpAdoptIcm(withAuth({ input: { path, name, generation }, fields: adoptIcmFields }))
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

  // Mail-access toggles (Mail settings): which projects' sessions may read
  // a mailbox — the CONTEXT.md `mail-<slug>` opt-in grammar, read + edited
  // in place backend-side (`Valea.Mounts.Context`).
  listIcmMailAccess: (generation: number) =>
    runRpc(
      (channel) => callListIcmMailAccessChannel(channel, { generation }),
      () =>
        httpListIcmMailAccess(
          withAuth({ input: { generation }, fields: listIcmMailAccessFields })
        )
    ),

  setIcmMailAccess: (mountKey: string, account: string, enabled: boolean, generation: number) =>
    runRpc(
      (channel) => callSetIcmMailAccessChannel(channel, { mountKey, account, enabled, generation }),
      () =>
        httpSetIcmMailAccess(
          withAuth({ input: { mountKey, account, enabled, generation }, fields: setIcmMailAccessFields })
        )
    ),

  icmDoctor: (mountKey: string, generation: number) =>
    runRpc(
      (channel) => callIcmDoctorChannel(channel, { mountKey, generation }),
      () => httpIcmDoctor(withAuth({ input: { mountKey, generation }, fields: icmDoctorFields }))
    ),

  // Skills (ICM skills design spec §Frontend, Task 9 — `Valea.Api.Skills`).
  // The settings/offer UI is the consent step; every action is generation-
  // guarded and control-token-gated (agents carry no RPC access — see the
  // resource's moduledoc). Each wrapper takes the generated `*Input` object
  // verbatim, so `generation` is caller-supplied from `workspaceStore`, same
  // store-free-api convention the icms/mail wrappers keep (see this module's
  // header comment). `listSkills` delivers `{skills, dismissed}`;
  // install/update/uninstall/dismiss each resolve `{ok: true}`.
  listSkills: (input: ListSkillsInput) =>
    runRpc(
      (channel) => callListSkillsChannel(channel, input),
      () => httpListSkills(withAuth({ input, fields: listSkillsFields }))
    ),

  installSkill: (input: InstallSkillInput) =>
    runRpc(
      (channel) => callInstallSkillChannel(channel, input),
      () => httpInstallSkill(withAuth({ input, fields: installSkillFields }))
    ),

  // `force` (default false) overwrites an install the user has edited — the
  // consent dialog's "Replace my edited copy" path sets it; a plain update
  // leaves it unset.
  updateSkill: (input: UpdateSkillInput) =>
    runRpc(
      (channel) => callUpdateSkillChannel(channel, input),
      () => httpUpdateSkill(withAuth({ input, fields: updateSkillFields }))
    ),

  uninstallSkill: (input: UninstallSkillInput) =>
    runRpc(
      (channel) => callUninstallSkillChannel(channel, input),
      () => httpUninstallSkill(withAuth({ input, fields: uninstallSkillFields }))
    ),

  dismissSkillsOffer: (input: DismissSkillsOfferInput) =>
    runRpc(
      (channel) => callDismissSkillsOfferChannel(channel, input),
      () => httpDismissSkillsOffer(withAuth({ input, fields: dismissSkillsOfferFields }))
    ),

  // Images (Task C7). Plain HTTP, not Ash RPC — see `uploadImage`'s own doc
  // comment above.
  uploadImage,
  // Raw-file open tickets (mail M1 task 4). Plain HTTP too, same reason.
  fileTicket
};

export type Api = typeof api;
