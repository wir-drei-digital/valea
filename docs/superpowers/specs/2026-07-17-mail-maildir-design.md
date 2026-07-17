# Spec E: Mail as Maildir — design

Date: 2026-07-17
Status: approved design, pending implementation plan
Predecessors: Phase 4 Mail (docs/superpowers/specs/2026-07-11-mail-design.md),
Spec D agent-native ICMs (docs/superpowers/specs/2026-07-16-agent-native-icms-design.md)

## Context & goal

Phase 4 shipped mail as a handoff pipeline: the user moves messages into
`AI/Review` in their own client, Valea's IMAP sync lands them as bespoke
markdown files, and the raw RFC822 bytes are discarded. Spec D deleted the
outbound machinery (`MailboxOps`/`DraftMime`) with the queue, leaving
outbound manual. The comprehensive review's hypothesis (rigidity map §2):
email should be a **filesystem building block the agent connects** — a
maildir — not a fixed pipeline.

Spec E rebuilds mail around a canonical local Maildir:

- **Full-account mirror** of every configured account (all folders, minus
  exclusions), windowed by a configurable horizon.
- **Two-way, intent-based sync** so the agent can clean up the inbox by
  moving files — with *moves only, never expunge* as a structural property.
- **Mail as mounts** (one per account) that ICMs opt into via the existing
  related grammar.
- **Markdown views and SQLite index as derived, rebuildable layers** over
  the raw canonical store.
- **Agent-proposed drafts; user-only SMTP send** from the Valea UI.

No backwards compatibility: no prod users, so `config/mail.yaml` v3 and the
old `sources/mail` layout are replaced, not migrated — reconfigure and
resync.

## Decisions (user-confirmed)

1. Maildir scope: **full-account mirror**, all folders (minus exclusions).
2. Sync model: **two-way** — the agent cleans up the inbox via local moves.
3. Deletions: **moves only, never expunge.** No local change ever
   propagates as a server-side deletion.
4. Agent access: **mail = mount, opt-in** via the related-ICMs grammar,
   one mount per account.
5. Outbound: **agent proposes drafts; SMTP send is a user-only UI action.**
   The agent has no path to sending.
6. History: **configurable sync window** (default 90 days) bounding
   backfill; landed messages stay local forever.
7. **Multiple accounts**, each an isolated engine, store subtree, and mount.

## Storage layout

```
sources/mail/<account>/
  maildir/                  # CANONICAL — raw RFC822, standard maildir
    INBOX/{cur,new,tmp}
    Archive/{cur,new,tmp}
    Work/Clients/{cur,new,tmp}   # IMAP hierarchy → nested plain dirs
    Drafts/  Sent/  Trash/ ...
  views/                    # DERIVED — regenerated, never hand-edited
    messages/<msg_id>.md    # normalized markdown per mirrored message
    attachments/<msg_id>/   # extracted on landing
  drafts/                   # agent/user-authored outbound drafts (markdown)
  spool/                    # engine-owned composed RFC822 awaiting APPEND
  quarantine/               # unrecognized files found under maildir/
```

- `<account>` is a short slug chosen at setup (`personal`, `wirdrei`, …);
  it is the stable key for config, keychain, store rows, and the mount.
- IMAP folders map to **nested plain directories** (agent-browsable), not
  Maildir++ dotted names. A folder-name segment equal to `cur`, `new`, or
  `tmp`, or starting with `.`, is percent-escaped deterministically
  (e.g. `cur` → `%63ur`), and a literal `%` is always escaped as `%25` so
  the mapping stays reversible. `\Noselect` folders are skipped.
- **Two-level identity.** A local maildir file represents an
  *occurrence* — one message in one folder, identified by
  `(account, folder, uidvalidity, uid)`. The *message* identity is the
  existing deterministic msg_id (`<date>-<from-slug>-<hash8>`,
  hash-extension collision rule kept), shared by every occurrence of the
  same message. Multi-folder membership is normal IMAP state (a Gmail
  label + INBOX, an ordinary `COPY`) and is represented faithfully:
  separate files and index rows per occurrence, one shared view per
  message.
- **Maildir filenames encode both identities**:
  `<msg_id>,U=<uid>:2,<flags>`. `U=` is the occurrence's UID in its
  folder, assigned at landing; a locally moved file keeps its stale `U=`
  until the engine executes the move and renames it to the destination
  folder's UID (from the `COPYUID`/`MOVE` response, or on the next pull).
  UIDVALIDITY lives in `mail_sync_state`, not the filename. Colons in
  filenames are fine on the only supported platform (macOS).
- Flags live in the filename per maildir convention (`S` seen, `R` replied,
  `F` flagged, `T` trashed, `D` draft), mapped to the IMAP system flags
  (`\Seen`, `\Answered`, `\Flagged`, `\Deleted`, `\Draft`). **Only
  `S`/`R`/`F` are pushable**; `T` and `D` are pull-only — Valea never
  issues `STORE +FLAGS (\Deleted)` outside the move ladder, because a
  pushed `\Deleted` plus any client's expunge would delete real mail.
- Sync bookkeeping (UID maps, watermarks) lives in SQLite — cache only,
  rebuildable from `maildir/` plus a Message-ID resync against the server.

## Sync engine — intent-based two-way

`Valea.Mail.Engine` survives per account (see Accounts). `SyncPass` is
rewritten around two phases per pass, **push before pull**:

### Push (local intents)

Scan `maildir/` and build the current local occurrence set from the
filenames' `msg_id` + `U=` tokens, then diff it against the last-synced
occurrence set in the UID map. Recognized intents, each executed as a
named IMAP op:

- **Move** — only a *paired, unambiguous* disappearance and appearance:
  occurrence `(A, uid)` is missing from folder A, and a file carrying the
  same `<msg_id>,U=<uid>` sits in exactly one other folder B with no
  UID-map record there → the existing safe-move ladder (`UID MOVE` →
  `UID COPY` + `STORE +FLAGS (\Deleted)` + targeted `UID EXPUNGE <uid>`).
  After success the file is renamed to B's UID. Any ambiguous pairing —
  the token missing from several folders, or appeared in several —
  pushes **nothing**; the pass reconciles by re-pulling and surfaces a
  notice. Multi-folder membership on the server is never mistaken for a
  move: each occurrence has its own UID-map row, and an intact occurrence
  is not a disappearance.
- **Flag change** — same folder, same `U=`, different flag suffix →
  `UID STORE ±FLAGS`. Who-changed-it is decided by a three-way diff: each
  UID-map row carries the **last-synced flags**; local ≠ last-synced means
  local intent, server ≠ last-synced means server change, both ≠ means
  conflict.
- **Valea-composed append** — from the pending-append journal + `spool/`
  only, never by discovering unknown files (see Drafting & send).

**Write-through folders.** The `folders.{archive,trash}` targets always
exist as local directories, even when `exclude_folders` keeps them out of
the pull (the Gmail case: archive = `[Gmail]/All Mail`, which is excluded).
A local move into a write-through-but-excluded folder is pushed as a normal
server-side move; the local copy is then removed by the engine on
confirmation, because the message now lives outside the mirrored set —
exactly matching what the user sees (archived mail leaves the mirror,
stays on the server). Moves into mirrored folders are just moves.

Everything else is *not* an intent:

- A message vanished locally with no unambiguous destination → **damage**:
  re-fetch by UID (Message-ID search fallback). Never propagated.
- A duplicated file — its `<msg_id>,U=` occurrence is still intact in its
  recorded folder AND a copy appears elsewhere — is a local copy, which is
  not in the op vocabulary: the extra file is quarantined with a notice
  ("copy in your mail client instead"). Never APPENDed, never treated as
  a move.
- An unknown new file under `maildir/` → moved to `quarantine/` + status
  notice. Never APPENDed.
- Conflict (local and server both changed a message since last pass, or a
  local intent targets a message the server moved/removed) → **server
  wins**; the dropped local intent is surfaced in status.

### Pull (server → local)

Per folder (from `LIST`, minus `sync.exclude_folders`):

- New mail: `UID SEARCH SINCE <horizon>` bounds backfill to the window;
  new UIDs land raw via `BODY.PEEK` into `cur/` (through `tmp/`, standard
  maildir delivery) — one file per occurrence. A message already mirrored
  in another folder lands again as its own occurrence in the new folder;
  the shared msg_id (derived from headers) is what makes both point at one
  view. Message content is fetched only once per msg_id.
- Flags: `CONDSTORE`/`HIGHESTMODSEQ` when advertised, else a plain
  `UID FETCH FLAGS` of the mirrored UID set; server changes rewrite the
  filename flag suffix and the UID-map's last-synced flags.
- Server-side deletions propagate locally (the user's own client stays
  authoritative for deletion): the occurrence's file and index row are
  removed; the shared view and attachments are removed only when the last
  occurrence of that msg_id is gone.
- `UIDVALIDITY` reset → wipe that folder's UID map and watermark, drop its
  pending local intents (surfaced), clean re-pull; already-landed files in
  that folder re-attach by Message-ID, folder-scoped — re-binding the
  occurrence to its new `(uidvalidity, uid)` and renaming the `U=` token.
- Once landed, a message stays local even after it ages past the window —
  the horizon bounds backfill only. Widening the window triggers deeper
  backfill on the next pass.
- Oversized messages (`sync.max_message_bytes`) are skipped and counted,
  never re-fetched hot (as today).

Windowed folder listing means old mail is server-only: visible in the
user's mail client, absent locally. That is the documented trade-off of
the window.

## Safety invariants (extends Phase 4's list)

- **No local→server deletion, structurally.** The op vocabulary is
  move / flag / append. There is no delete op to misconfigure. A bare
  `EXPUNGE` appears nowhere; `UID EXPUNGE <uid>` only inside the move
  ladder.
- **Only the sync engine creates maildir files.** Agent cleanup is renames
  of existing messages. Agent-created files under `maildir/` are
  quarantined, not APPENDed.
- **TLS mandatory and verified, always** — IMAP and SMTP both:
  `verify_peer`, hostname verification, SNI; the only overridable piece is
  the trust root (tests only). No insecure escape hatch.
- **Agents cannot send.** SMTP submission is reachable only through a
  user-initiated RPC from the Valea UI. No agent-facing tool, RPC access,
  or file convention triggers submission. This is a permanent invariant,
  not a deferral.
- **Credentials are RAM-only closures** resolved from the OS keychain —
  never on disk, never logged, never in the workspace. Now two per
  account (IMAP, SMTP).
- **Threat note — mailbox as untrusted content.** A full mirror puts
  attacker-authored text (every received mail) inside the agent's readable
  surface in opted-in sessions. Mitigations, by construction: mail mounts
  are opt-in per account and per ICM; writes are ask-gated; the write
  surface cannot delete server mail or send mail; secrets never live under
  `sources/mail`. Prompt-injected cleanup worst case: messages moved to
  wrong folders or flags flipped — visible in status/audit and reversible
  from the user's own client.

## Accounts & configuration

`config/mail.yaml` v4:

```yaml
version: 4
accounts:
  wirdrei:
    imap: { host: mail.example.com, port: 993, username: daniel@wirdrei.digital }
    smtp: { host: mail.example.com, port: 587, username: daniel@wirdrei.digital, sent_copy: true }
    folders: { drafts: Drafts, sent: Sent, archive: Archive, trash: Trash }
    sync:
      window_days: 90
      interval_minutes: 15
      max_message_bytes: 26214400
      exclude_folders: []
  personal:
    imap: { host: imap.gmail.com, port: 993, username: flipbug360@gmail.com }
    # smtp optional until send is configured
    folders: { drafts: "[Gmail]/Drafts", sent: "[Gmail]/Sent Mail", archive: "[Gmail]/All Mail", trash: "[Gmail]/Trash" }
    sync:
      window_days: 90
      interval_minutes: 15
      max_message_bytes: 26214400
      exclude_folders: ["[Gmail]/All Mail", "[Gmail]/Important", "[Gmail]/Starred"]
safety:            # fixed block, as today
  never_expunge: true
  agent_send: never
```

- `smtp` is optional per account; send actions are unavailable (and the
  doctor's SMTP checks skipped) until configured. `sent_copy: false` for
  servers that auto-append to Sent (Gmail).
- Setup seeds `exclude_folders` with the Gmail virtual folders when the
  IMAP host is Gmail; otherwise empty.
- No credential ever in the file. Keychain entries are account-qualified:
  service `digital.wirdrei.valea`, accounts `<workspace_id>:<account>:imap`
  and `<workspace_id>:<account>:smtp` (username lives in the yaml; the slug
  is the stable key). Resupply flow unchanged otherwise. Browser-mode dev
  fallback: `VALEA_MAIL_PASSWORD_<ACCOUNT_SLUG_UPCASED>` (IMAP only).

Runtime: `Valea.Mail.Supervisor` under `Workspace.Runtime` starts **one
Engine per configured account** (Registry-keyed by `{workspace, account}`),
each with its own credential closures, poll timer, single-flight sync task,
and status. `auth_failed` pauses only that account.

## Store (SQLite, all cache, hand-migrated)

The `migrate? false` hand-migration pattern stays (see ARCHITECTURE.md for
why). The Phase 4 migration is replaced wholesale — no prod users. All
tables rebuildable from `sources/mail/` + resync.

- `mail_sync_state` — per (account, folder): uidvalidity, last-seen UID,
  highestmodseq, last pass result.
- `mail_uid_map` — one row per occurrence `(account, folder, uidvalidity,
  uid)`: msg_id, **last-synced flags** (the three-way diff anchor).
- `mail_messages` — the UI/agent index, one row per occurrence: account,
  folder, uid, msg_id (non-unique — multi-folder membership), message_id,
  from, to, subject, date, flags, in_reply_to, references,
  has_attachments, maildir path.
- `mail_pending_appends` — the append journal: account, target folder,
  spool path, origin draft path, state. Crash-safe with the spool file.
- `mail_send_attempts` — the write-ahead send journal: account, draft
  path, generated Message-ID, state (`submitting | submitted | complete |
  needs_review`), error, timestamps (see Drafting & send).

Deleted: `mail_inbox_headers` (`InboxHeader`) and `mail_uid_outcomes`
(`UidOutcome`) — the full mirror makes the awareness index redundant, and
per-UID handoff outcomes give way to per-folder sync state. `AI/Review`
loses its special role: it's just a folder (keep using it as a convention
if you like; the engine doesn't care).

## Derived views & indexing

- Per-message markdown views reuse the existing `Normalizer` +
  `MessageFile` rendering (msg_id naming kept) — one view per message,
  shared by all its occurrences. Frontmatter now carries `account`,
  `folders` (sorted list of the occurrences' folders), and `flags`
  (informational union — canonical flags live on the maildir filenames)
  instead of the retired `status: review|processed` field;
  `MessageFile.flip_status/2` is deleted.
- Views regenerate whenever a message lands, moves, or changes flags;
  view + attachments are removed when the canonical message is removed
  server-side. The `views/` tree is documented as derived: agent edits
  there propagate nowhere and are overwritten.
- Attachments extract to `views/attachments/<msg_id>/` on landing, deduped
  filenames, as today.
- `inbox.md` generation is deleted.
- Initial sync and view generation are batched with per-folder progress in
  status; a first pass on a busy account is minutes, not hours, at the
  default window.

## Mount & containment

Each account is a mount: key `mail-<account>`, rooted at
`sources/mail/<account>`. An ICM opts in via the existing related grammar
(`related_icms: [mail-wirdrei]`); entry points may include the mount
explicitly for a session. Sessions without the declaration never see mail.
All path decisions go through `Valea.Paths.resolve_real/2` with
segment-boundary membership, as everywhere — the mail root lives inside the
workspace, so containment holds trivially, and the permission boundary is
never weakened.

Writes into a mail mount are ask-gated like any non-primary mount. The
first agent write asks once; approval issues the existing session-scoped,
mount-wide write grant — so "clean up my inbox" is one approval, not fifty.
The spec documents `maildir/` renames as the one meaningful agent write
surface; everything else under the mount is derived or engine-owned.

## Drafting & send

One draft path, markdown-first. A draft is
`sources/mail/<account>/drafts/<name>.md`:

```markdown
---
to: [alex@example.com]
cc: []
bcc: []
subject: "Re: Kickoff"
in_reply_to: 2026-07-15-alex-4f2a91c3   # msg_id, optional
status: draft                            # draft | sent
---
Body in markdown; composed as text/plain.
```

Agents (and the user) write drafts through the normal ask-gate. The Mail
UI lists drafts with a review panel offering two **user-only** actions:

- **Send** — a crash-safe state machine, never a bare submit:
  1. Compose to RFC822 (resurrect `DraftMime` from git history, plain-text
     MIME only) with a **stable, Valea-generated Message-ID**; write the
     composed message to `spool/`.
  2. **Before any network I/O**, persist a `mail_send_attempts` row in
     state `submitting` and stamp the draft `status: sending` — the
     durable record that a submission may be in flight.
  3. SMTP submission (STARTTLS on 587 / implicit TLS on 465, same
     verification posture as IMAP).
  4. On acceptance: row → `submitted`, draft → `status: sent`, audit
     entry; if `sent_copy`, journal the Sent append from the same spool
     file; row → `complete`. On refusal: the row records the error, the
     draft reverts to `status: draft`, and the error is surfaced.

  On restart, a row still in `submitting` is **ambiguous** — the outcome
  is unknown. The draft is locked out of Send (`needs_review`) and shown
  in a reconciliation state: Valea searches the account for the stable
  Message-ID (Sent folder first) — found → resolved as sent; not found →
  the user explicitly chooses resend (a fresh attempt) or revert to
  draft. **Nothing ever resends automatically.**
- **Push to Drafts** — compose the same RFC822, spool + journal an append
  into the Drafts folder; it syncs up and appears in the user's own mail
  client, where they send it from there.

`in_reply_to: <msg_id>` resolves threading headers (`In-Reply-To`,
`References`) from the referenced message's **raw canonical file** — a
direct win of keeping RFC822. If the referenced message isn't mirrored,
compose without threading headers and surface a warning in the panel.
SMTP failure leaves the draft untouched with the error surfaced; no
automatic retry. Appends execute via the pending journal: APPEND to the
server, delete the spool file on success, and the message lands locally on
the next pull (deduped by Message-ID).

## RPC surface (`Valea.Api.Mail`)

All mutating actions take `generation` (checked via
`Manager.check_generation/1`); reads resolve `Manager.current/0` first.
Account-scoped actions take `account`.

- `mail_status()` — all accounts: per-account settings summary, credential
  presence (imap/smtp), last pass, backfill progress, pending intents,
  conflict/quarantine notices.
- `setup_mail_account(account, imap…, smtp…, folders…, sync…, generation)` /
  `remove_mail_account(account, generation)` (removes config + engine;
  local files stay until the user deletes them; the frontend deletes the
  account's keychain entries via `mail_secret_delete`).
- `set_mail_credential(account, kind, secret, generation)` — kind
  `imap|smtp`, secret `sensitive? true`.
- `mail_sync_now(account, generation)`, `mail_doctor(account, generation)`,
  `create_mail_folders(account, generation)`.
- `list_mail_messages(account, folder, limit \\ 100, before \\ nil)` —
  newest-first pagination by date; `get_mail_message(account, msg_id)`.
- `list_mail_drafts()`, `send_draft(account, draft_path, generation)`,
  `push_draft_to_mailbox(account, draft_path, generation)`.

Deleted: `mail_inbox`. Channel events stay `mail_status`, `mail_sync`,
`mail_message` on the `"mail"` PubSub topic, now carrying `account`.

## UI, doctor, status, entry points

- **Mail page**: account switcher, folder list (from the index), message
  list/view (existing components, store rework), drafts review panel with
  Send / Push to Drafts and a reconciliation banner for interrupted sends
  (resolve as sent / resend / revert). Status line per account: last pass,
  initial-sync/backfill progress, pending intents, dropped-conflict and
  quarantine notices.
- **Setup panel**: add/edit N accounts; SMTP section optional; per-account
  keychain writes (Tauri `mail_secret_set` with the account-qualified key).
- **Doctor** (per account): the existing sequential checks
  (config → credential → tcp → tls/login/folders/move_capability) plus
  `maildir_writable`, and — only when SMTP is configured —
  `smtp_reachable`, `smtp_login`. Remedies stay copyable strings.
- **Entry points**: MessageView's "Start a session about this message"
  passes the account's view-file locator and includes that account's
  mount; a "Clean up inbox" action on the Mail page starts a session with
  the account's mount and a cleanup initial prompt. Both reuse the Spec D
  initial-prompt handoff.
- **today.json cockpit**: the `mail` key becomes a per-account summary
  (account, ok, last sync, pending notices), same lenient parsing rules.

## Change map

- **Kept:** `Engine` (per-account child), `Transport` behaviour +
  `ImapClient` + safe-move ladder, `Normalizer`, `MessageFile` rendering,
  credential closure model, `Redact`, keychain Tauri commands (key format
  extended).
- **Extended:** `ImapClient` — `LIST`, `UID SEARCH SINCE`,
  `UID STORE ±FLAGS`, `APPEND`, optional `CONDSTORE`; `Doctor`; RPC surface.
- **New:** `Valea.Mail.Supervisor`, `Maildir` (filename/flag/escape
  helpers, tmp→cur delivery), `IntentScan`, `SmtpClient` (+ behaviour),
  spool/journal executor.
- **Rewritten:** `SyncPass` (push-then-pull), `Store` resources +
  hand-written migration, `Settings` (v4), mail frontend stores.
- **Deleted:** `InboxHeader`, `UidOutcome`, `inbox.md` generation,
  `MessageFile.flip_status/2`, `mail_inbox` RPC.
- **Resurrected:** `DraftMime` (from git history) as the send/push
  composer, plain-text MIME, with its golden tests.

## Error handling

Per-account isolation (auth failure pauses one account). Folders fail soft
within a pass — one folder's error is recorded, the pass continues.
Damage → re-fetch; unknown files and local copies → quarantine; ambiguous
move pairings → nothing pushed, reconcile on pull, notice; conflicts →
server wins, surfaced; oversized → skipped and counted; `UIDVALIDITY`
reset → folder re-pull with folder-scoped Message-ID re-attach; SMTP
refusal → draft reverts, error surfaced, no auto-retry; interrupted send
(crash while `submitting`) → draft locked in the reconciliation state,
resolved by Message-ID search or an explicit user choice, never an
automatic resend. Nothing in the mail stack raises across the RPC
boundary; every failure state has a copyable remedy or a status notice.

## Testing & acceptance

- **Fake transport** grows folders/`LIST`, `SEARCH SINCE`, `STORE`,
  `APPEND`, `CONDSTORE`. Scenario suite: initial windowed sync;
  incremental pass; local move → server move (incl. `U=` rename after
  success); **multi-folder membership** (same message in INBOX + a label
  folder: two occurrences, one view, no false move); local copy →
  quarantine, occurrence intact; ambiguous pairing (token missing from two
  folders) → nothing pushed, reconciled; flags both directions; three-way
  flag conflict (server wins); damage re-fetch; last-occurrence-gone view
  cleanup; `UIDVALIDITY` reset with folder-scoped re-attach; window
  widening backfill; Gmail folder exclusion; two-account isolation;
  pending-append crash recovery (journal + spool survive restart).
- **SMTP**: behaviour + fake for compose/submit; `DraftMime` golden tests;
  send state machine: refusal reverts the draft; crash between acceptance
  and journal transition → restart lands in `needs_review`, resolved by
  Message-ID search (found and not-found branches); no path resends
  without an explicit user choice.
- **Maildir helpers**: filename round-trip, flag mapping, escape rule
  property tests.
- **Live acceptance** (mandatory before trusting the engine): the
  `scripts/dovecot` maildir-backed server *and* one real provider account,
  with a manual checklist doc like Phase 4's
  (docs/superpowers/acceptance/).
- **Frontend**: vitest for reworked stores + draft panel; svelte-check
  and codegen freshness as always (`just test`).

## Non-goals

- OAuth/XOAUTH2 — app passwords only (noted limitation for Gmail).
- IMAP IDLE / push — polling stays.
- Full-history default backfill.
- **Agent-initiated send — permanent invariant, not a deferral.**
- HTML composition, draft attachments, rich compose UI — drafts are
  plain-text files; editing happens in the editor or your mail client.
- Server-side search (SEARCH is used only for windowing).
- Trash retention / expunge of any kind — the server and the user's client
  own eventual deletion.
- Sharing one account across workspaces; per-folder agent ACLs (the mount
  is account-granular).

## Execution notes (for the plan)

Sequence so each stage lands green and independently useful:
maildir core + one-way pull mirror → derived views/index + UI read path →
intent scan + push ops (cleanup complete) → mounts + entry points →
drafts + spool/journal + SMTP send (outbound complete) → doctor/status/
cockpit polish + acceptance docs. Multi-account is structural from the
first task (slugged paths, keyed engines), not retrofitted. Every SDD
dispatch forbids sub-agent spawning; commit trailer and no-push rules as
standing.
