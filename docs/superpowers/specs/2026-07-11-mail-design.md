# Mail (Phase 4) — Design

**Date:** 2026-07-11 · **Status:** approved design (v2 after external review), pre-plan
**Depends on:** 2026-07-10-agent-slice-design.md (queue trust loop, workflows, audit, workspace runtime)

## Goal

A sync-to-files engine that connects Valea to the user's real mailbox over
IMAP, lands the messages they hand over as plain files in `sources/mail/`,
and closes the approval loop back into the mailbox — replacing the seeded
mock input while keeping the agent's integration surface exactly what it is
today: files.

The consent gesture is unchanged from the vision: the user moves a mail into
the `AI/Review` folder from their own mail client. Valea syncs that folder
down, the existing New Inquiry Triage workflow runs on the normalized file,
the existing queue gates the draft, and on approval the draft appears in the
user's real Drafts folder, ready to send from their own client. Valea never
sends mail.

## Decisions (from brainstorm)

| Question | Decision |
| --- | --- |
| IMAP write posture | **Read + minimal writes.** Sync is read-only. Writes happen only in the post-approval stage: APPEND approved draft to the Drafts folder, MOVE the source message `AI/Review` → `AI/Processed` (on reject too). Never send. |
| Authentication | **App-password only**, stored in the OS keychain via Tauri. No OAuth in this phase. No credentials in config files, env-var fallback for browser dev only. |
| Sync scope | **`AI/Review` fully** (bodies + attachments, agent-visible files) + **INBOX headers only** (from/subject/date awareness index; agent does not get INBOX bodies). |
| UI | **Basic `/mail` route**: Review list + read pane + Run triage, INBOX header list, sync status, account setup + connection doctor. Not a mail client — no compose, no send, no search, no other folders. |
| Triggering | **Manual.** The user clicks Run triage. The engine emits new-message events internally so Phase 6 can add watching without redesign. |
| Engine home | **Elixir backend** (option A): minimal vendored IMAP client behind a `Valea.Mail.Transport` behaviour; a Rust helper binary (option C) remains the escape hatch behind the same behaviour if provider quirks demand it. |

## Non-goals

Sending mail (SMTP is removed from config entirely). OAuth/XOAUTH2.
Multi-account. IMAP IDLE (polling only; IDLE is a later refinement). Full
folder sync beyond `AI/Review` + INBOX headers. Search. HTML rendering of
mail in the UI (text extraction only). Auto-triggered workflow runs.

## Architecture

All engine code lives in the backend under `Valea.Mail.*`. One process per
open workspace, supervised by `Valea.Workspace.Runtime` beside the watcher,
audit, and session supervisor. The desktop shell contributes only a keychain
command pair; the frontend contributes the `/mail` route and settings panel.

```
Valea.Mail.Transport    behaviour — the IMAP operations the engine needs
Valea.Mail.ImapClient   real transport: :ssl sockets, bounded protocol subset
Valea.Mail.Normalizer   RFC822 bytes → normalized message (via :mimemail)
Valea.Mail.Engine       per-workspace GenServer: poll loop, credential (RAM),
                        file landing, audit, events, post-approval mailbox ops
Valea.Mail.SyncState    UIDVALIDITY / last-UID / Message-ID dedupe (SQLite)
Valea.Api.Mail          ash_typescript RPCs for the SPA
```

### Transport behaviour

```elixir
@callback connect(config, credential) :: {:ok, conn} | {:error, reason}
@callback capabilities(conn) :: {:ok, [String.t()]}
@callback list_folders(conn) :: {:ok, [folder]}
@callback create_folder(conn, name) :: :ok | {:error, reason}
@callback select(conn, folder) :: {:ok, %{uidvalidity: integer, uidnext: integer}}
@callback uid_search(conn, criteria) :: {:ok, [uid]}
@callback uid_fetch_meta(conn, uids) :: {:ok, [%{uid: _, size: _, flags: _}]}
@callback uid_fetch_headers(conn, uids) :: {:ok, [%{uid: _, headers: binary}]}
@callback uid_fetch_full(conn, uid) :: {:ok, binary}   # whole RFC822 via BODY.PEEK[]
@callback uid_move(conn, uid, dest_folder) ::
            :ok | {:error, reason} | {:unsupported, reason}
            # ImapClient resolves the safe-move ladder internally
            # (MOVE → UIDPLUS COPY+UID EXPUNGE → :unsupported)
@callback append(conn, folder, flags, rfc822) :: :ok | {:error, reason}
@callback logout(conn) :: :ok
```

### ImapClient (the vendored minimal client)

Implements exactly the subset the behaviour needs. Ground rules, several
learned from prior art (ExImap's documented failure modes):

- **UIDs only.** Sequence numbers are never used.
- **`BODY.PEEK[...]`** everywhere — sync never sets `\Seen`.
- **Literal-exact parsing.** Responses are parsed by reading literal byte
  counts (`{123}\r\n`), never by regex over accumulated text. The parser is
  a small tokenizer over tagged/untagged responses with literals.
- **`RFC822.SIZE` before body fetch** — oversized messages are never pulled.
- **Safe move, never bare EXPUNGE.** `UID MOVE` when the server advertises
  `MOVE`; else, when `UIDPLUS` is advertised, `UID COPY` +
  `UID STORE +FLAGS (\Deleted)` + **`UID EXPUNGE <uid>`** (RFC 4315), which
  expunges only Valea's message. A bare `EXPUNGE` is never issued — it
  would purge every `\Deleted` message in the mailbox, including ones the
  user's own client marked. With neither capability, the move is reported
  `unsupported`: the source message is left untouched (no `\Deleted` flag),
  the local file still flips to `processed`, and the user moves it in their
  own client. The doctor reports which of the three levels the server
  supports.
- **Connect-per-pass.** No persistent connections, no IDLE. Connect, work,
  LOGOUT. CAPABILITY is refreshed after login (servers may change the
  advertised set post-authentication).
- **TLS is mandatory.** Implicit TLS on port 993 only — there is no
  plaintext or STARTTLS mode and no `ssl` toggle anywhere in config or UI.
  `:ssl` options: `verify_peer` against the OS CA store
  (`:public_key.cacerts_get()`), hostname verification via the standard
  `:public_key` match rules, and SNI set to the configured host.
- Folder names used by Valea (`AI/Review`, `AI/Processed`, `Drafts`) are
  ASCII; modified-UTF-7 mailbox encoding is not implemented (documented
  limitation — custom folder names must be ASCII).

### Normalizer

`:mimemail.decode/1` (gen_smtp) parses the RFC822 message. Body selection:
prefer the `text/plain` part; if only HTML exists, extract text with Floki
(tags stripped, block elements to line breaks). Charset handling without the
iconv NIF: UTF-8 passes through (validated), ISO-8859-1 and Windows-1252 are
mapped via `codepagex` (pure-Elixir mapping tables), anything else lands
as lossy UTF-8 with `charset_note` in frontmatter. A malformed MIME message
never fails the sync pass: it lands with headers + raw-text-best-effort body
and a `normalizer_note`.

Attachments: written to `sources/mail/attachments/<msg_id>/<filename>` with
filenames sanitized (basename only, control chars stripped, deduped with
numeric suffix, no traversal). Listed in frontmatter with size and path.

### Engine

Per-workspace GenServer. State: config (from `config/mail.yaml`), credential
(RAM only), sync status, poll timer.

**Activation gating:** the Runtime starts its children *before* the
Manager runs the workspace migration (manager.ex order: repo → runtime →
migrate → broadcast), so the Engine must not read `mail.yaml` at init —
it would see the pre-v3 shape. The Engine boots inert, subscribed to the
`"workspace"` PubSub topic, and activates (loads config, runs the
recovery scan, starts the poll timer) only on the `{:workspace_opened,
info, generation}` broadcast — which the Manager fires only after the
migration succeeded. A rolled-back open simply kills the still-inert
Engine. (The Migration moduledoc's stale claim that it runs before the
runtime gets corrected as part of this phase.)

One **sync pass** (triggered by timer, default every 5 minutes, or Sync now):

1. Connect + login. Auth failure → status `auth_failed`, **polling pauses**
   until a credential is re-supplied (no retry storm).
2. `AI/Review`: SELECT, check UIDVALIDITY against SyncState (change → clean
   resync of the folder; Message-ID dedupe keeps existing files stable),
   UID SEARCH for new UIDs, size-check, fetch full, normalize, land file
   (atomic write, same tmp+rename discipline as the rest of the backend),
   record SyncState, audit `mail_message_synced`, emit `mail_message_upserted`.
3. INBOX: fetch headers for new UIDs, regenerate `sources/mail/inbox.md`
   (newest first, capped).
4. LOGOUT. Emit `mail_sync_finished {new_messages, errors}`.

Every mutating step is stamped with the workspace generation, exactly like
Phase 3's runtime paths. A crashed pass reruns idempotently. One bad message
is recorded as `failed` for that UID and the pass continues — it never
wedges the pass, and it is retried on later passes (attempt-capped, see
SyncState) rather than silently skipped forever.

The Engine also executes **post-approval mailbox ops** (see below) and the
**doctor** (see UI).

### SyncState + message index

Three SQLite tables (Ash resources) inside the workspace DB, all
cache-layer per Principle 1 — the files stay canonical:

- `mail_sync_state`: folder, uidvalidity, high-water UID (highest UID
  *seen*, used only to scope the next UID SEARCH).
- `mail_uid_outcomes`: folder, uid, outcome (`synced | skipped_oversize |
  failed`), attempts, msg_id. A single high-water mark alone would skip a
  failed UID forever; instead, `failed` UIDs are retried on subsequent
  passes with an attempt cap (3, then `failed` is terminal but visible in
  sync status), and `skipped_oversize` ones are not re-fetched.
- `mail_messages`: msg_id, message_id (full, for dedupe), path, from,
  subject, date, status, has_attachments, uid — the index behind the
  list/get RPCs. Rebuilt from the files on workspace open (same posture as
  the ICM tree scan), so a wiped DB is a resync/rescan, never data loss.

Dedupe is keyed on the **full Message-ID** via `mail_messages`, never on
the filename hash.

## Workspace layout & formats

```
sources/mail/
  messages/<msg_id>.md          # one file per Review message, stable forever
  attachments/<msg_id>/<file>
  inbox.md                      # regenerated headers index (awareness only)
  drafts/<run_id>.md            # unchanged from Phase 3
```

### Normalized message file

`msg_id` = `<date>-<from-slug>-<hash8>`: date is the message date
(`YYYY-MM-DD`), from-slug is the sender display name (fallback: email
local part) lowercased/ASCII-slugged, and `hash8` is the first 8 hex chars
of SHA-256 over the Message-ID. When Message-ID is missing, the hash is
taken over the message's **entire raw header block** (far stronger than
date/from/subject, which can legitimately collide). `hash8` is a filename
disambiguator, not the identity: dedupe uses the full Message-ID in the
index, and if a landing file's path already exists for a *different*
Message-ID, the hash is extended to 16 (then 64) chars until unique.
Deterministic — resync lands the same file. Frontmatter values YAML-encoded with the
Phase-3 control-character rejection (frontmatter-injection hardening).

```markdown
---
id: 2026-07-09-priya-nair-3f2a91c4
message_id: "<CAJx…@mail.example.com>"
from: { name: "Priya Nair", email: "priya@example.com" }
to: [{ name: "Mara Lindt", email: "mara@example.com" }]
subject: "Question about leadership coaching"
date: 2026-07-09T06:58:00Z
uid: 4711
in_reply_to: null         # Message-ID this mail replies to, if any
references: []            # full References chain (list of Message-IDs)
reply_to: null            # Reply-To address if it differs from from
status: review            # review | processed
source: imap              # imap | seed
source_ref: "email://imap/2026-07-09-priya-nair-3f2a91c4"
attachments: []           # [{ filename, path, bytes }]
---
Hi Mara, I found your work through a colleague. …
```

Files never move or vanish when the server-side message moves — `status:`
flips `review` → `processed`. Stable paths keep queue items, audit entries,
and any agent references valid. Optional notes fields (`charset_note`,
`normalizer_note`, `truncation_note`) record degraded handling.

`message_id`, `in_reply_to`, `references`, and `reply_to` exist precisely
because the raw RFC822 bytes are discarded after normalization: they are
everything the post-approval APPEND needs to thread the draft correctly
and address the right recipient (`reply_to || from`).

### inbox.md

A single regenerated file — a header table (date, from, subject), newest
first, capped (default 200). Awareness only: it feeds the Today summary
count and gives the agent daily-briefing context without exposing bodies
the user didn't hand over.

### config/mail.yaml (v3)

Non-secret only. The v2 `smtp:` block and `username_env`/`password_env`
keys are removed, and so is the v2 `ssl:` boolean — TLS is mandatory and
not configurable (a toggle would make `ssl: false` either dead config or a
plaintext-login footgun).

```yaml
account: mara@example.com
imap:
  host: imap.example.com
  port: 993
  username: mara@example.com
folders:
  review: "AI/Review"
  processed: "AI/Processed"
  drafts: "Drafts"
sync:
  interval_minutes: 5
  max_message_bytes: 10485760   # 10 MB
  inbox_index_limit: 200
safety:
  send_directly: false          # invariant; the engine has no send path
  create_drafts_only: true
```

### Seed & migration (workspace v2 → v3)

The existing migration contract is binding: **never delete or overwrite a
user-modified file** (migration.ex moduledoc; enforced by tests). v2→v3
therefore works with hash-based pristine detection — the migration ships
the SHA-256 of each known v2 seed file it wants to touch, and only a
byte-identical file counts as pristine:

- **Priya mock:** reseeded as
  `sources/mail/messages/2026-07-09-priya-nair-seed0001.md` with
  `source: seed`, `source_ref: "email://seed/priya-nair-inquiry"`,
  `status: review` (written only if absent) — the demo loop keeps working
  with no account. The old `sources/mail/normalized/priya-nair-inquiry.json`
  is never deleted: pristine → moved to `logs/migrations/v3/`; modified →
  it is a user file and stays exactly where it is.
- **`config/mail.yaml`:** pristine v2 seed → replaced with the v3 seed.
  User-modified → the original is copied to `logs/migrations/v3/` and the
  file is rewritten preserving the user's `account`, `imap.host`,
  `imap.port`, `imap.username`, and `folders` values while dropping
  `smtp:`, `ssl:`, and the `*_env` keys.
- **`icm/Workflows/New Inquiry Triage.md`:** pristine → updated input
  contract (the run names a `sources/mail/messages/*.md` path — markdown,
  not JSON). User-modified → left untouched; the migration records a note
  (audited) and the mail doctor surfaces the contract mismatch as a
  warning.
- **`config/workspace.yaml`:** gains a persistent workspace identity —
  `id: <uuid4>` (also added by Scaffold for new workspaces) — plus
  `version: 3`. The UUID exists because keychain entries must survive the
  workspace folder moving or being renamed (a path-derived key would not).
- Idempotent `Valea.Workspace.Migration` step, same pattern as v1→v2;
  `logs/migrations/` is append-only and never itself migrated.

## Credentials

- **Desktop:** two Tauri commands using the `keyring` crate —
  `mail_secret_set(workspace_id, username, secret)` /
  `mail_secret_get(workspace_id, username)` (plus delete). Service name =
  the app bundle identifier; account = `workspace_id:username`, where
  `workspace_id` is the persistent UUID from `config/workspace.yaml`
  (stable across folder moves/renames). Exposed only over Tauri IPC to the
  SPA, never over HTTP. Concretely this phase adds to the desktop crate:
  the `keyring` dependency, the `#[tauri::command]` handlers registered in
  the `invoke_handler`, and a Tauri v2 capability granting exactly these
  commands to the sidecar-origin webview (the SPA is served from the
  localhost sidecar, so the capability must name that remote origin —
  today `main.rs` registers no commands and no such capability exists).
- **Hand-off:** on app launch and after account setup, the SPA reads the
  secret from the keychain and calls the `mail_set_credential` RPC over the
  token-authenticated control plane. The Engine keeps it in process memory
  only. It is never written to disk, never appears in the workspace, audit
  log, doctor output, or error messages (redaction enforced at the Engine
  boundary).
- **Recovery:** backend restart → status `credential_missing` → the SPA
  silently re-supplies from the keychain.
- **Browser dev fallback:** `VALEA_MAIL_PASSWORD` env var, read only when
  the Tauri IPC is absent. Dev-only, documented as such.
- Valea's product promise holds: the workspace folder contains zero
  credentials; the managed `.claude/settings.json` deny rules are unchanged
  and nothing secret ever becomes a file.

## Approval-flow integration

Phase 3's approve path is untouched and stays the source of truth:
revision-guarded atomic pending→processing→approved walk, `approval_intent`
audited synchronously, idempotent local draft write to
`sources/mail/drafts/<run_id>.md`.

Phase 4 adds a **post-approval mailbox stage**, executed by the Engine
after the local approve completes. It can never block or undo an approval,
and it is crash-durable:

**Durable intent.** The mailbox ops are written into the envelope *before*
the terminal rename: approve's step 6 becomes "rewrite
`processing/<run_id>.json` with a `mailbox_ops` map (`draft_append:
pending`, `archive_source: pending`), then rename to `approved/`" — so an
envelope in `approved/` always already carries its op intents. Reject
gains the same treatment for its single `archive_source` op. After the
rename, the queue notifies the Engine; if the process dies anywhere in
between, the Engine's **recovery scan** (at activation, alongside the
existing `recover_staging` pattern) walks `approved/` and `rejected/` for
envelopes with non-terminal ops and resumes them. The intent lives in the
envelope on disk — never only in a message to a process that might be gone.

The ops:

1. **APPEND draft**: compose RFC822 from the approved draft markdown via
   `:mimemail` — `To` = source `reply_to || from`, `Subject` from the
   draft frontmatter, `In-Reply-To` = source `message_id`, `References` =
   source `references + [message_id]` — APPEND to the configured Drafts
   folder with `\Draft` flag. The composed draft carries a
   **deterministic Message-ID** (`<valea.draft.<run_id>@valea.invalid>`),
   and before any APPEND (first attempt or retry) the Engine does
   `UID SEARCH HEADER "Message-ID"` for it in the Drafts folder — found
   means a prior attempt succeeded even if the crash hit before the audit
   line, so the op is marked `done` without re-appending. Audit
   `draft_appended`.
2. **MOVE source message** `AI/Review` → `AI/Processed` (safe-move ladder
   from the ImapClient section; `unsupported` is a terminal status shown
   to the user); flip the file's `status:` to `processed`. Runs on
   **reject too** (a rejected item has still been reviewed). Audit
   `message_archived`.

Per-op status (`pending / done / failed / skipped / unsupported`) is
recorded on the queue item envelope (a versioned extension of
`queue_item/v1` → `queue_item/v2` with a `mailbox_ops` map) and surfaced
in the UI with a retry action (`mail_retry_mailbox_ops(item_id)` RPC —
idempotent by the same search-before-append guard; ops already `done` are
never repeated). IMAP offline at approval time = draft exists locally, ops
show `failed` with retry. Seed messages (`source: seed`) get `skipped`
ops at intent-writing time.

**Queue API extension:** Phase 3's queue reads only `pending/`; the UI
now also needs terminal envelopes, so the queue API gains list/get over
`approved/` and `rejected/` (id, decided time, `mailbox_ops` status) to
render outcomes and drive retry.

## UI

### `/mail` route

Same AppFrame + ListPane composition as `/chat`:

- **List pane:** Review messages (from, subject, relative date; status dot
  green=review pending, neutral=processed), then a collapsed INBOX header
  section (awareness list from `inbox.md`, no bodies, no actions). Footer:
  sync status line (last sync, next poll, error if any) + **Sync now**.
- **Main pane:** normalized message rendered cleanly — header block from
  frontmatter, plain-text body, attachment chips (click reveals the file
  path; opening files is Knowledge's job). Primary action **Run triage** —
  enqueues the existing workflow run with this message path as
  `email.selected` (exact Phase-3 run semantics; disabled while a run for
  this message is live). Processed messages show their linked queue item /
  draft outcome.
- **Empty state / no account:** setup panel.

### Account setup + doctor

Setup panel: host, port (default 993, always TLS), username, account
label → password field
that writes **only** to the keychain (Tauri) and then hands off to the
backend; in browser dev it posts straight to `mail_set_credential` with a
visible "dev mode — not persisted" note. Then the doctor runs:

`config_present → credential_present → tcp_reachable → tls_ok → login_ok →
folders (review/processed/drafts exist; one-click "Create AI folders" for
the missing AI/* ones) → move_capability (MOVE / UIDPLUS fallback /
unsupported-manual) → workflow_contract (warns if a user-modified Triage
page still names the legacy JSON input)`

Same presentation pattern as the Phase-3 DoctorPanel; every check's detail
is one toggle away; secrets redacted.

### Today integration

The morning summary line gains real counts: N messages awaiting review
(from the message index), M in inbox (from `inbox.md`). Review messages
surface as Today cards with Run triage, replacing the seeded mock card
when an account is configured (seed card remains when not).

### Events

`mail_status_changed`, `mail_sync_started`, `mail_sync_finished`,
`mail_message_upserted`, `mail_mailbox_ops_updated` — over the existing
workspace channel, generation-stamped, with a `MailStore` in the SPA
following the Phase-3 store patterns.

## Error handling summary

| Failure | Behavior |
| --- | --- |
| Auth failure | status `auth_failed`, polling paused until credential re-supplied |
| Server unreachable / TLS error | pass fails, status shows error, next poll retries |
| Oversized message (> cap) | headers-only file with `truncation_note`, attachments skipped |
| Unknown charset / broken MIME | best-effort body + note in frontmatter, pass continues |
| UIDVALIDITY change | clean folder resync; Message-ID dedupe keeps files stable |
| MOVE not supported | UIDPLUS → COPY+STORE+`UID EXPUNGE <uid>`; neither → op `unsupported`, source untouched, user moves it manually (bare EXPUNGE never issued) |
| Mailbox op fails post-approval | approval stands, op `failed` + retry button, audited |
| Crash around approval terminal rename | op intents already in the envelope on disk; Engine recovery scan resumes them at activation |
| APPEND retried after crash-before-audit | deterministic draft Message-ID + UID SEARCH in Drafts detects the prior success — no duplicate draft |
| Evil attachment filename | sanitized to safe basename, never traverses |
| One bad message | recorded `failed` + audited, pass continues; retried on later passes (attempt cap 3) |

## Testing

- **ImapClient:** scripted fake IMAP server over real TCP/SSL sockets in
  ExUnit (the fake-ACP-agent pattern): greeting, login, literals, tagged/
  untagged interleaving, the full move ladder (MOVE / UIDPLUS `UID
  EXPUNGE` / unsupported — asserting bare EXPUNGE is never sent), size
  responses, post-login CAPABILITY refresh, mid-stream disconnects.
- **Normalizer:** fixture `.eml` corpus — plain, HTML-only, nested
  multipart, base64/quoted-printable, ISO-8859-1/Windows-1252, evil
  filenames, broken MIME.
- **Engine:** fake Transport — full pass, incremental pass, UIDVALIDITY
  reset, dedupe, size cap, per-UID failed-retry with attempt cap,
  auth-failure pause, activation gating (no config read before
  `workspace_opened`), post-approval ops incl. failure/retry/
  skip-for-seed/unsupported, recovery scan over `approved/`+`rejected/`
  with pending intents, search-before-append idempotence, generation
  staleness.
- **API/queue:** RPC contract tests under the existing isolated test env;
  envelope extension roundtrip.
- **Frontend:** vitest for MailStore + route components; svelte-check.
- **Manual E2E:** `just mail-dev` runs a Dovecot container with seeded
  folders for hands-on verification (not CI-required).

## Acceptance scenario (Phase 4)

Open app → connect account (password lands in keychain, doctor green,
"Create AI folders" if needed) → in the user's own mail client, move a real
inquiry into AI/Review → Sync now (or wait for the poll) → the message
appears in `/mail` and on Today → Run triage → review the prepared draft
with sources → approve → draft file lands locally **and** appears in the
mailbox's Drafts folder, source message moves to AI/Processed, full chain
in the audit log — and "Open the hood" shows the plain files behind every
step. With no account connected, the seeded Priya flow still demos
end-to-end unchanged.
