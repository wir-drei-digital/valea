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
- **Two-way, declared-ops sync** so the agent can clean up the inbox —
  mutations are declared in validated ops files and executed by the
  engine, with *moves only, never expunge* as a structural property.
- **Mail as mounts** (one per account) that ICMs opt into via the existing
  related grammar.
- **Markdown views and SQLite index as derived, rebuildable layers** over
  the raw canonical store.
- **Agent-proposed drafts; user-only Push-to-Drafts** from the Valea UI —
  Valea never transmits mail; the user sends pushed drafts from their own
  client. (SMTP send: cut, see Non-goals.)

No backwards compatibility: no prod users, so `config/mail.yaml` v3 and the
old `sources/mail` layout are replaced, not migrated — reconfigure and
resync.

## Decisions (user-confirmed)

1. Maildir scope: **full-account mirror**, all folders (minus exclusions).
2. Sync model: **two-way** — the agent cleans up the inbox. (Mechanism
   refined after adversarial review: declared ops files executed by the
   engine, not raw file moves — see Push.)
3. Deletions: **moves only, never expunge.** No local change ever
   propagates as a server-side deletion.
4. Agent access: **mail = mount, opt-in** via the related-ICMs grammar,
   one mount per account.
5. Outbound: **agent proposes drafts; pushing a reviewed draft into the
   account's Drafts folder is a user-only UI action.** The agent has no
   path to outbound. (Refined after adversarial review: SMTP send is cut
   from this spec — its ambiguous-acceptance failure mode is irreducible;
   the user sends pushed drafts from their own mail client.)
6. History: **configurable sync window** (default 90 days) bounding
   backfill; landed messages stay local forever.
7. **Multiple accounts**, each an isolated engine, store subtree, and mount.

## Storage layout

```
sources/mail/<account>/
  .account                  # immutable mailbox identity (host + username)
  maildir/                  # CANONICAL — raw RFC822, engine-owned,
    INBOX/{cur,new,tmp}     #   read-only to agents
    Archive/{cur,new,tmp}
    Work/Clients/{cur,new,tmp}   # IMAP hierarchy → nested plain dirs
    Drafts/  Sent/  Trash/ ...
  views/                    # DERIVED — regenerated, never hand-edited
    messages/<msg_id>.md    # normalized markdown per mirrored message
    attachments/<msg_id>/   # extracted on landing
  ops/
    pending/                # AGENT-WRITABLE — declared mailbox ops (YAML)
    done/                   # engine-owned — claimed ops + per-op results
  drafts/                   # AGENT-WRITABLE — outbound drafts (markdown)
  spool/                    # engine-owned composed RFC822 + op manifests
  quarantine/               # unrecognized files found under maildir/
```

- `<account>` is a short slug chosen at setup (`personal`, `wirdrei`, …);
  it is the stable key for config, keychain, store rows, and the mount.
- IMAP folders map to **nested plain directories** (agent-browsable), not
  Maildir++ dotted names. A folder-name segment equal to `cur`, `new`, or
  `tmp`, or starting with `.`, is percent-escaped deterministically
  (e.g. `cur` → `%63ur`), and a literal `%` is always escaped as `%25` so
  the mapping stays reversible. `\Noselect` folders are skipped. The
  mapping is additionally **injective on a case- and
  normalization-insensitive filesystem (APFS)**: at `LIST` time, segments
  that collide under casefold + Unicode normalization receive a
  deterministic hash suffix, and every mailbox directory carries an
  engine-owned `.folder` file recording the exact IMAP mailbox name —
  authoritative for ops targets, ledger entries, and rebuilds, never
  inferred back from the directory spelling.
- **Two-level identity.** A local maildir file represents an
  *occurrence* — one message in one folder, identified by
  `(account, folder, uidvalidity, uid)`. The *message* identity is the
  deterministic msg_id `<date>-<from-slug>-<hash8>`, whose hash is a
  **fingerprint of the raw RFC822 bytes** (hash-extension collision rule
  kept). Message-ID is sender-controlled and not unique, so it is only a
  lookup hint, never an identity: two distinct messages that reuse a
  Message-ID get different msg_ids and separate views, while true
  multi-folder occurrences of one message (same bytes — a Gmail label +
  INBOX, an ordinary `COPY`) share one msg_id and one view, with separate
  files and index rows per occurrence.
- **Maildir filenames encode both identities**:
  `<msg_id>,U=<uid>:2,<flags>`. `U=` is the occurrence's UID in its
  folder, assigned at landing; when the engine executes a move it
  relocates the file and renames it to the destination folder's UID,
  which is always confirmed before relocation (see Push). UIDVALIDITY lives
  in `mail_sync_state`, not the filename. Colons in filenames are fine on
  the only supported platform (macOS).
- Flags live in the filename per maildir convention (`S` seen, `R` replied,
  `F` flagged, `T` trashed, `D` draft), mapped to the IMAP system flags
  (`\Seen`, `\Answered`, `\Flagged`, `\Deleted`, `\Draft`). **Only
  `S`/`R`/`F` are pushable**; `T` and `D` are pull-only — Valea never
  issues `STORE +FLAGS (\Deleted)` outside the move ladder, because a
  pushed `\Deleted` plus any client's expunge would delete real mail.
- Sync bookkeeping (UID maps, watermarks) lives in SQLite — cache only,
  rebuildable from `maildir/` plus a fingerprint resync against the
  server (Message-ID as a shortcut where present).

## Sync engine — declared-ops two-way

`Valea.Mail.Engine` survives per account (see Accounts). `SyncPass` is
rewritten around two phases per pass, **push before pull**:

### Push (declared ops)

Nothing infers intent from filesystem diffs. Mailbox mutations are
**declared** and executed by the engine:

- An ops file is YAML at `ops/pending/<name>.yaml`: a list of operations
  from the closed vocabulary
  `{op: move, msg_id, from, to}` ·
  `{op: flag, msg_id, folder, add: [...], remove: [...]}` (S/R/F only).
  Agents write ops files through the normal ask-gate (`ops/pending/` is
  one of the two agent-writable dirs); the Valea UI's own actions
  (archive button, flag toggle) go through the same executor via RPC.
  Folder references use exact IMAP mailbox names (as recorded in
  `.folder` files), not directory spellings.
- Each op is **validated against current occurrence state** before
  execution: the msg_id must resolve to exactly one occurrence in `from`
  (for flags: in `folder`), the destination must be a known folder, and
  the pushable-flag rule applies. Valid ops enter the durable op ledger;
  invalid or ambiguous ops are rejected per-op, never guessed at.
- Moves execute as the existing safe-move ladder (`UID MOVE` →
  `UID COPY` + `STORE +FLAGS (\Deleted)` + targeted `UID EXPUNGE <uid>`).
  The **destination UID is confirmed for every move** — from the
  `COPYUID`/`MOVE` response where the server supports UIDPLUS, otherwise
  by a **horizon-independent** candidate scan of the destination folder
  (UIDs above its pre-op watermark, Message-ID shortcut when present,
  fingerprint always decides) — and persisted in the ledger **before**
  the source file is relocated. The local file is never removed without a confirmed
  destination occurrence, so a landed message can never vanish from the
  mirror — the "once landed, stays local" invariant survives moving
  messages older than the sync window.
- The executor **claims a pending file by atomically renaming it into the
  engine-owned `ops/done/`** before parsing anything — the agent-writable
  copy ceases to exist before interpretation, so a file cannot change
  under the executor. Per-op results are appended to the claimed file
  (`ok | rejected: <reason> | needs_review`) — a file-first audit trail
  the agent can read but not edit (`ops/done/` is write-denied).
- **Valea-composed appends** come from the ops ledger + `spool/` only,
  never from ops files and never by discovering unknown files (see
  Drafting & push); the ops vocabulary cannot express append, delete, or
  anything else.

**Execution-time verification.** Cached state is never sufficient for a
mutation. Immediately before any `UID MOVE`/`UID COPY`/`UID STORE`/
`UID EXPUNGE`, the executor `SELECT`s the source folder and requires its
live UIDVALIDITY to equal the op's recorded value, then fetches the
source message and requires a **fingerprint match** with the op's msg_id
(`CONDSTORE`/`UNCHANGEDSINCE` guards used additionally where advertised).
Any mismatch — a reset, a recycled UID, altered content — rejects the op
for re-validation after the next pull; destructive steps are never issued
from cached UID state alone. Push-before-pull is an ordering
optimization, never a trust statement.

**Durable server-op ledger.** Moves and appends — the two non-idempotent
server mutations — execute through `mail_pending_ops`: the op is recorded
durably *before* any remote I/O and transitions state as each ladder step
completes. Every ledger op — move or append, file-declared or
RPC-originated — also writes a self-contained, fsynced **manifest** under
`spool/` before any remote I/O: for a move, the source
folder/UIDVALIDITY/UID and msg_id fingerprint, the destination, the
recorded pre-op destination watermark, the origin, and each ladder
transition appended as it happens; for an append, as described in Store.
Manifests are removed only at op completion, so boot can reconcile every
unfinished op even after database loss — moves included, not just
appends. After an uncertain result (disconnect, missing tagged
response), the op is never blindly retried: the engine first
**reconciles** — destination candidates are the destination folder's
UIDs above its watermark recorded at op creation (a bounded set), with a
Message-ID search as a shortcut only when the message has one (inbound
mail is never required to carry a Message-ID); every candidate is
confirmed by fingerprint; the source is re-checked — and the op continues
only when the outcome is proven. For a move, the source copy is deleted
only once **exactly one** fingerprint-confirmed destination occurrence is
proven to exist; anything unprovable (zero or several matches) stops the
op in `needs_review` with a recovery notice instead of retrying. Appends
are idempotent by construction: every composed message carries a stable,
unique, **Valea-generated** Message-ID (always present, unlike inbound
mail), and every append execution — first attempt or retry — searches the
target folder for that Message-ID first, marking the op complete if
found. Flag `STORE`s are idempotent and execute directly, without the
ledger.

**Write-through folders.** The `folders.{archive,trash}` targets always
exist as local directories, even when `exclude_folders` keeps them out of
the pull. An op moving a message into a write-through-but-excluded folder
is pushed as a normal server-side move whose confirmation uses a
**transient destination check**: the executor `SELECT`s the excluded
folder read-only, records its `UIDNEXT − 1` on the op *before* the ladder
starts, and confirms the new destination occurrence exactly like any
other move — the folder still never enters the mirror. On confirmation
the local copy is removed, because the message now lives outside the
mirrored set — exactly matching what the user sees (archived mail leaves
the mirror, stays on the server). Moves into mirrored folders are just
moves.

**Gmail profile.** Accounts detected as Gmail at setup carry
`provider: gmail` (everything else: `generic`). Gmail's label model
breaks the generic confirmation for archive: every message already
exists in `[Gmail]/All Mail`, so the documented archive gesture
(`UID MOVE` to All Mail) removes the Inbox label without creating any
new UID — there is nothing above a watermark to find. The gmail profile
therefore uses an **explicit, different postcondition**: after the
`UID MOVE` (Gmail advertises native MOVE; the gmail profile refuses the
`COPY`-fallback ladder), success is proven by **source UID absent from
the source folder AND All Mail membership confirmed via an `X-GM-MSGID`
search** in a transient, read-only `SELECT` of All Mail. The local copy
is not removed before that proof. Live Gmail acceptance must cover
archive, retries, and lost responses.

Local maildir mutations are *not* a channel:

- `maildir/` is engine-owned and read-only to agents (policy-enforced;
  documented to the user as engine-owned). Anything that mutates it
  anyway is **damage**, repaired on the next pass: a vanished or altered
  file is restored from the server (re-fetch by UID,
  fingerprint-verified); an unknown file is moved to `quarantine/` with a
  notice. Nothing is ever inferred from such changes, and nothing local
  ever propagates to the server except declared ops.
- Conflict (an op targets a message the server moved or removed since the
  last pull) → the op is rejected with a notice; **server wins**.

### Pull (server → local)

Per folder (from `LIST`, minus `sync.exclude_folders`):

- New occurrences: discovery is **UID-based, not date-based**. At a
  folder's first sync, its high-water mark is initialized to
  `UIDNEXT − 1` (from `SELECT`) — every UID present before Valea's first
  pass is permanently behind the watermark, so pre-existing old mail
  stays server-only exactly as configured — and bodies are backfilled
  only for the windowed subset (`UID SEARCH SINCE <horizon>`). Every
  incremental pass thereafter fetches **all UIDs above the watermark**
  regardless of message date — so a years-old message that another
  client moves or labels into a mirrored folder still lands (its new UID
  is above the watermark even though its date is outside the window).
  New UIDs land
  raw via `BODY.PEEK` into `cur/` (through `tmp/`, standard
  maildir delivery) — one file per occurrence. Every occurrence is
  fetched and fingerprinted; storage of views/attachments is deduplicated
  by msg_id. A cheaper precheck (Message-ID + size match) is never a
  substitute for the fingerprint — attacker-crafted lookalikes must not
  merge.
- Flags: `CONDSTORE`/`HIGHESTMODSEQ` when advertised, else a plain
  `UID FETCH FLAGS` of the mirrored UID set; server changes rewrite the
  filename flag suffix and the UID-map's last-synced flags.
- Server-side deletions propagate locally (the user's own client stays
  authoritative for deletion): the occurrence's file and index row are
  removed; the shared view and attachments are removed only when the last
  occurrence of that msg_id is gone.
- `UIDVALIDITY` reset → wipe that folder's UID map and watermark, reject
  that folder's pending ops (surfaced), clean re-pull; already-landed
  files in that folder re-attach folder-scoped — candidates by Message-ID
  where present, otherwise the folder's UIDs; fingerprint always
  decides — re-binding the occurrence to its new `(uidvalidity, uid)`
  and renaming the `U=` token. Reset recovery is a **complete
  reconciliation**: the pre-reset local occurrence set is snapshotted
  before the map is wiped; after the re-pull, every local file with no
  fingerprint-proven server match is removed together with its index row
  (server-authoritative deletion holds across resets), and shared
  views/attachments go when the last occurrence goes.
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
- **Only the engine mutates `maildir/`.** Agents cannot write there at
  all (policy deny); cleanup is declared in validated ops files and
  executed by the engine. Any out-of-band mutation is damage: restored
  from the server or quarantined, never interpreted, never APPENDed.
- **Accounts are identity-bound.** A `sources/mail/<account>` subtree
  activates only for the mailbox recorded in its `.account` file;
  reusing a slug for a different mailbox requires an explicit typed
  purge. No cross-account exposure through key reuse.
- **TLS mandatory and verified, always**:
  `verify_peer`, hostname verification, SNI; the only overridable piece is
  the trust root (tests only). No insecure escape hatch.
- **Valea cannot send mail.** There is no SMTP anywhere — the Phase 4
  invariant stands. Outbound is exactly one user-initiated action:
  pushing a reviewed draft into the account's own Drafts folder, from
  which the user sends with their own client. No agent-facing tool, RPC
  access, or file convention can trigger it; agent-initiated outbound is
  permanently off the table.
- **Credentials are RAM-only closures** resolved from the OS keychain —
  never on disk, never logged, never in the workspace. One per account
  (IMAP).
- **What the user reviewed is what gets pushed.** Push is hash-bound end
  to end: the UI passes the reviewed draft's SHA-256 with the RPC; the
  server reads the draft **once** into an immutable buffer, verifies the
  hash against that buffer, and composes from the same buffer (never
  re-reading the mutable file); the composed spool payload's hash is
  persisted on the op and re-verified immediately before every APPEND.
  One non-terminal push per draft, serialized through the Engine —
  concurrent clicks cannot produce two pushes. `spool/` is deny-all to
  agents.
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
    folders: { drafts: Drafts, sent: Sent, archive: Archive, trash: Trash }
    sync:
      window_days: 90
      interval_minutes: 15
      max_message_bytes: 26214400
      exclude_folders: []
  personal:
    provider: gmail        # detected from the IMAP host at setup
    imap: { host: imap.gmail.com, port: 993, username: flipbug360@gmail.com }
    folders: { drafts: "[Gmail]/Drafts", sent: "[Gmail]/Sent Mail", archive: "[Gmail]/All Mail", trash: "[Gmail]/Trash" }
    sync:
      window_days: 90
      interval_minutes: 15
      max_message_bytes: 26214400
      exclude_folders: ["[Gmail]/All Mail", "[Gmail]/Important", "[Gmail]/Starred"]
safety:            # fixed block, as today
  never_expunge: true
  outbound: push_drafts_only
```

- `provider: generic | gmail`, detected from the IMAP host at setup;
  `gmail` unlocks the `X-GM-MSGID` extension and the Gmail archive
  postcondition (see Push) and seeds `exclude_folders` with the Gmail
  virtual folders. Otherwise `generic`, empty exclusions.
- No credential ever in the file. Keychain entries are account-qualified:
  service `digital.wirdrei.valea`, account `<workspace_id>:<account>:imap`
  (username lives in the yaml; the slug is the stable key). Resupply flow unchanged otherwise. Browser-mode dev
  fallback: `VALEA_MAIL_PASSWORD_<ACCOUNT_SLUG_UPCASED>` (IMAP only).

**Mailbox identity binding.** At first activation the engine writes
`sources/mail/<account>/.account` — an immutable identity file recording
`imap.host` + `imap.username`. Every activation compares it against
config: on mismatch the account **refuses to activate**
(`identity_mismatch` status with a remedy) — nothing is synced or
indexed, and the account's mount is not offered to sessions. Re-adding a
slug over a subtree that belonged to a different mailbox requires an
explicit, typed purge confirmation in the setup UI, or a new slug. An
existing subtree is never mounted or indexed before its identity is
verified.

Runtime: `Valea.Mail.Supervisor` under `Workspace.Runtime` starts **one
Engine per configured account** (Registry-keyed by `{workspace, account}`),
each with its own credential closures, poll timer, single-flight sync task,
and status. `auth_failed` pauses only that account.

## Store (SQLite, all cache, hand-migrated)

The `migrate? false` hand-migration pattern stays (see ARCHITECTURE.md for
why). The Phase 4 migration is replaced wholesale — no prod users. The
sync tables are pure cache, rebuildable from `sources/mail/` + resync —
**except `mail_pending_ops`, which is durable operational state** (atomic
claims, generated Message-IDs, payload hashes, outcome records) that no
resync can reconstruct. It is made recoverable instead of rebuildable:
every op — move or append, file-declared or RPC-originated — writes a
self-contained manifest (`spool/<id>.manifest.yaml` — kind, folders,
identifiers and fingerprints, payload hash + spool file for appends,
origin, state transitions) in the same step as its ledger row. After
database loss, boot treats any manifest without a completed ledger row
as unresolved: the affected drafts and ops are **blocked** until
reconciliation (watermark scans, Message-ID shortcut, fingerprint
confirmation) proves the outcome — nothing retries, pushes, or mutates
for them in the meantime.

- `mail_sync_state` — per (account, folder): uidvalidity, last-seen UID,
  highestmodseq, last pass result.
- `mail_uid_map` — one row per occurrence `(account, folder, uidvalidity,
  uid)`: msg_id, **last-synced flags** (the pull-diff anchor for
  detecting server-side flag changes).
- `mail_messages` — the UI/agent index, one row per occurrence: account,
  folder, uid, msg_id (non-unique — multi-folder membership), message_id,
  from, to, subject, date, flags, in_reply_to, references,
  has_attachments, maildir path.
- `mail_pending_ops` — the durable server-op ledger (see Sync engine):
  kind (`move | append`), account, source/target folder, uids, generated
  Message-ID, origin (draft path or ops file), spool path + payload
  SHA-256 for appends, state
  (`claimed | pending | executing | rejected | needs_review | complete`),
  error,
  timestamps; **unique non-terminal append per (account, origin draft)**
  — the atomic claim that serializes concurrent pushes (see Drafting &
  push). Crash-safe together with the spool file + manifest; durable
  state, not cache (see above).

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
first agent write asks once; approval issues the existing session-scoped
write grant — so "clean up my inbox" is one approval, not fifty. But the
grant is **not the whole subtree**: the agent-writable surface of a mail
mount is exactly `ops/pending/` and `drafts/`. `PermissionPolicy` denies
agent writes everywhere else in the mount — `maildir/` (canonical mail is
engine-owned; cleanup is declared in ops files, never performed by the
agent's own file operations), `views/`, `ops/done/` (the audit trail the
agent must not edit), `quarantine/`, and `.account` (all readable) — and
denies `spool/` entirely, read and write, because it
holds engine-owned outbound payloads. The denies are mirrored in
managedSettings as defense-in-depth, exactly like the Spec D ICM-secrets
deny, and deny takes precedence over any grant (existing policy
semantics, already regression-tested). No rename-only permission mode is
needed anywhere: generic write grants simply never cover canonical mail.

## Drafting & push

One draft path, markdown-first. A draft is
`sources/mail/<account>/drafts/<name>.md`:

```markdown
---
to: [alex@example.com]
cc: []
bcc: []
subject: "Re: Kickoff"
in_reply_to: 2026-07-15-alex-4f2a91c3   # msg_id, optional
status: draft                            # draft | pushing | pushed
---
Body in markdown; composed as text/plain.
```

**Frontmatter is untrusted input.** Composition validates before use:
unknown fields reject; any CR, LF, or NUL anywhere in any field value
rejects; `to`/`cc`/`bcc` are parsed with an RFC 5322 mailbox parser and
the outbound headers are serialized **from the parsed values only**,
never from raw strings; `subject` is RFC 2047-encoded; `in_reply_to`
must be a syntactically valid msg_id. The review panel displays the
parsed recipient set — exactly what will be transmitted, not the raw
frontmatter text.

Agents (and the user) write drafts through the normal ask-gate. The Mail
UI lists drafts with a review panel offering one **user-only** action:

- **Push to Drafts** — a crash-safe, serialized push:
  1. **Atomic claim.** In one SQLite transaction: insert the append op
     into `mail_pending_ops` together with its **stable, Valea-generated
     Message-ID**, under the uniqueness constraint of one non-terminal
     push per `(account, draft_path)`. A concurrent push (double click,
     second tab) never creates a second op — it returns the existing
     op's status. Pushes are additionally serialized through the
     account's Engine process. All of this happens **before any network
     I/O**. The op is born in state `claimed` — not yet executable.
  2. **Immutable snapshot.** Read the draft file once into a byte buffer;
     verify `content_hash` against that buffer (mismatch → the op
     terminates `rejected` with a re-review error); compose to RFC822
     (resurrect `DraftMime` from git history, plain-text MIME only)
     **from that same buffer** — the draft file is never re-read, so
     there is no verify-then-read window for an agent to swap content.
     Write the composed message + manifest to `spool/` (fsynced), record
     the payload SHA-256 on the op, stamp the draft `status: pushing`;
     only then does the op transition `claimed → pending` (executable).
  3. The ops executor performs the idempotent APPEND: re-verify the spool
     payload hash, search the Drafts folder for the Message-ID (found →
     already pushed, complete), APPEND. On proven success: draft →
     `status: pushed`, audit entry, spool cleaned; the draft appears in
     the user's own mail client, where they send it from there. On
     refusal: the op records the error, the draft reverts to
     `status: draft`, and the error is surfaced.

  There is no ambiguous terminal state: an unknown APPEND outcome is
  always resolvable by the Message-ID search, and retrying is safe by
  construction. Boot recovery covers both storage orderings: a manifest
  without a ledger row blocks until reconciled (see Store); a `claimed`
  row without its spool payload is provably un-transmitted (no network
  I/O happens before `pending`) and terminates `rejected` — the draft
  reverts to `status: draft` for re-review. The mutable draft file is
  never re-read to "repair" an attempt. **Valea itself never transmits
  mail** — SMTP does not exist in this design (see Non-goals).

`in_reply_to: <msg_id>` resolves threading headers (`In-Reply-To`,
`References`) from the referenced message's **raw canonical file** — a
direct win of keeping RFC822. If the referenced message isn't mirrored,
compose without threading headers and surface a warning in the panel.
Appends execute via the ops ledger (see Sync engine):
verify the spool payload hash, search the target folder for the stable
Message-ID (found → op complete, nothing sent twice), APPEND, record
completion durably, then delete the spool file; the message lands locally
on the next pull.

## RPC surface (`Valea.Api.Mail`)

All mutating actions take `generation` (checked via
`Manager.check_generation/1`); reads resolve `Manager.current/0` first.
Account-scoped actions take `account`.

- `mail_status()` — all accounts: per-account settings summary, credential
  presence, last pass, backfill progress, pending ops,
  conflict/quarantine notices.
- `setup_mail_account(account, imap…, folders…, sync…, generation)` /
  `remove_mail_account(account, generation)` (removes config + engine;
  local files stay until the user deletes them; the frontend deletes the
  account's keychain entries via `mail_secret_delete`).
- `set_mail_credential(account, secret, generation)` — secret
  `sensitive? true`.
- `mail_sync_now(account, generation)`, `mail_doctor(account, generation)`,
  `create_mail_folders(account, generation)`.
- `mail_apply_ops(account, ops, generation)` — the UI's archive/move/flag
  actions, validated and executed by the same ops executor as ops files;
  returns per-op results.
- `purge_mail_account_files(account, confirmation, generation)` — the
  typed-confirmation purge behind slug reuse (see identity binding).
- `list_mail_messages(account, folder, limit \\ 100, before \\ nil)` —
  newest-first pagination by date; `get_mail_message(account, msg_id)`.
- `list_mail_drafts()`,
  `push_draft_to_mailbox(account, draft_path, content_hash, generation)` —
  `content_hash` is the SHA-256 of the draft exactly as reviewed in the
  UI; a mismatch rejects with a re-review error.

Deleted: `mail_inbox`. Channel events stay `mail_status`, `mail_sync`,
`mail_message` on the `"mail"` PubSub topic, now carrying `account`.

## UI, doctor, status, entry points

- **Mail page**: account switcher, folder list (from the index), message
  list/view (existing components, store rework), drafts review panel with
  the parsed-recipient display and the Push to Drafts action (drafts show
  their status: draft / pushing / pushed; a rejected push surfaces its
  error). Status line per account: last pass,
  initial-sync/backfill progress, pending ops, dropped-conflict and
  quarantine notices.
- **Setup panel**: add/edit N accounts; per-account keychain writes
  (Tauri `mail_secret_set` with the account-qualified key).
- **Doctor** (per account): the existing sequential checks
  (config → credential → tcp → tls/login/folders/move_capability) plus
  `maildir_writable`. Remedies stay copyable strings.
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
  `UID STORE ±FLAGS`, `APPEND`, optional `CONDSTORE`, and the Gmail
  extensions (`X-GM-MSGID`) on the gmail profile; `Doctor`;
  `MessageFile.msg_id` hash input becomes the raw-RFC822 fingerprint;
  RPC surface (incl. `mail_apply_ops`, `purge_mail_account_files`).
- **New:** `Valea.Mail.Supervisor`, `Maildir` (filename/flag/escape
  helpers, tmp→cur delivery), `OpsFile` (parse + occurrence-validate the
  declared-ops vocabulary), the
  `mail_pending_ops` ledger executor (moves + appends, reconciling,
  hash-verifying), mailbox identity binding (`.account`); mail-mount deny
  rules in `PermissionPolicy` + managedSettings mirror.
- **Rewritten:** `SyncPass` (push-then-pull), `Store` resources +
  hand-written migration, `Settings` (v4), mail frontend stores.
- **Deleted:** `InboxHeader`, `UidOutcome`, `inbox.md` generation,
  `MessageFile.flip_status/2`, `mail_inbox` RPC.
- **Resurrected:** `DraftMime` (from git history) as the push composer,
  plain-text MIME, with its golden tests.

## Error handling

Per-account isolation (auth failure pauses one account). Folders fail soft
within a pass — one folder's error is recorded, the pass continues.
Out-of-band maildir changes → restored from the server or quarantined,
nothing inferred; invalid/ambiguous ops → rejected per-op with reasons in
`ops/done/`; identity mismatch → account refuses activation with a
remedy; uncertain move/append results → reconcile via Message-ID search +
fingerprint confirmation before any retry, unprovable outcomes stop in
`needs_review`; hash mismatches (draft or spool) → op rejected with a
re-review error; op-vs-server conflicts → op rejected, server wins,
surfaced; oversized → skipped and counted; `UIDVALIDITY`
reset → folder re-pull with fingerprint-confirmed re-attach; database
loss → spool manifests drive reconciliation, affected drafts/ops blocked
until outcomes are proven; push refusal → draft reverts, error surfaced;
interrupted push → resolved by the idempotent Message-ID search, retry
safe by construction. Nothing in the mail stack raises across the RPC
boundary; every failure state has a copyable remedy or a status notice.

## Testing & acceptance

- **Fake transport** grows folders/`LIST`, `SEARCH SINCE`, `STORE`,
  `APPEND`, `CONDSTORE`, and a Gmail label-model mode (`X-GM-MSGID`,
  All-Mail-membership semantics). Scenario suite: initial windowed sync;
  incremental pass; ops move → server move (incl. `U=` rename and local
  relocation after proven success); **multi-folder membership** (same
  message in INBOX + a label folder: two occurrences, one view);
  **duplicate Message-ID, distinct messages** → distinct fingerprints,
  distinct msg_ids, two views, no merge; invalid/ambiguous ops (unknown
  msg_id, wrong `from`, unknown folder, non-pushable flag) → rejected
  per-op with results in `done/`; out-of-band maildir tamper (vanished,
  altered, unknown file) → restored from server or quarantined, nothing
  pushed; server flag changes pulled onto filenames; op vs. server-move
  conflict → op rejected, server wins; last-occurrence-gone view cleanup;
  `UIDVALIDITY` reset with fingerprint-confirmed folder-scoped re-attach
  **including stale-occurrence cleanup** (message deleted server-side
  before the reset → local file, index row, and last-occurrence view
  removed after the re-pull);
  **watermark initialization** (folder containing only >window-old mail →
  watermark = `UIDNEXT − 1`, second pass fetches nothing, old mail stays
  server-only); **message without a Message-ID** (move + disconnect →
  reconciled via the destination watermark scan + fingerprint, no
  permanent `needs_review`);
  window widening backfill; Gmail folder exclusion; **slug-reuse identity
  mismatch** → account refuses activation, typed purge path works;
  two-account isolation; ops-ledger crash recovery (ledger + spool
  survive restart); **ladder disconnect after each request** (`COPY`
  accepted but response lost → reconcile proves exactly one
  fingerprint-confirmed destination copy, no duplicate, no premature
  source delete); **Gmail archive** (label-model fake: message pre-exists
  in All Mail, archive proves source-absence + `X-GM-MSGID` membership
  before local removal; lost response → retry converges, no stuck op);
  **write-through transient confirmation** (excluded destination
  `SELECT`ed read-only, new UID confirmed, folder stays unmirrored);
  **database loss with an in-flight RPC-originated move** → boot
  reconciles from the move manifest, no duplicate destination copy;
  **append crash after server acceptance** → search-first
  retry finds the Message-ID and completes without a duplicate; spool
  tamper (payload hash mismatch) → op stops in `needs_review`;
  **recycled-UID guard** (UIDVALIDITY changed or source fingerprint
  mismatched at execution time → op rejected, no `STORE`/`EXPUNGE`
  issued); **move of a message older than the window** → destination
  confirmed horizon-independently, source relocated, nothing vanishes;
  **case-colliding folder names** (`Clients` vs `clients`) on a
  case-insensitive volume → distinct directories, no mixed UID maps,
  ops target the exact IMAP names; **claim-by-rename** (pending ops file
  mutated after claim → executor parses only the claimed engine-owned
  copy); **old message moved by another client** (>window-old message
  moved between mirrored folders → lands via the UID watermark, source
  removal never orphans it); **header injection** (CR/LF in subject or recipients →
  composition rejects) and malformed mailbox syntax → rejected with the
  parsed-recipient review intact; **database-loss recovery** (ledger rows
  gone, manifests present → drafts/ops blocked, reconciliation resolves
  without duplicate delivery).
- **Push**: `DraftMime` golden tests; frontmatter validation (injection,
  malformed mailbox syntax, unknown fields); push refusal reverts the
  draft; crash between APPEND acceptance and completion → search-first
  retry completes without a duplicate; draft changed after review →
  `content_hash` rejection against the snapshot buffer; **crash after
  the SQL claim, before the spool/manifest write** → boot terminates the
  op `rejected`, draft reverts, nothing transmitted; **concurrent
  double-push** → one op, one Drafts message, second caller sees the
  existing op; **draft swapped between verification and composition** →
  structurally impossible (composition consumes the verified buffer) —
  test asserts compose-from-buffer semantics.
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
- **SMTP send — cut after adversarial review.** SMTP acceptance is
  irreducibly ambiguous (a lost response after acceptance cannot be
  disproven by any search), so v1 ships Push-to-Drafts only; a future
  spec may revisit send with provider-specific submission records.
- **Agent-initiated outbound — permanent invariant, not a deferral.**
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
ops files + ledger executor (cleanup complete) → mounts + entry points →
drafts + push (outbound complete) → doctor/status/
cockpit polish + acceptance docs. Multi-account is structural from the
first task (slugged paths, keyed engines), not retrofitted. Every SDD
dispatch forbids sub-agent spawning; commit trailer and no-push rules as
standing.
