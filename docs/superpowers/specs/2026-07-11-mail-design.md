# Mail (Phase 4) — Design

**Date:** 2026-07-11 · **Status:** approved design, pre-plan
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
@callback uid_move(conn, uid, dest_folder) :: :ok | {:error, reason}
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
- **`UID MOVE` when the server advertises `MOVE`**, otherwise
  `UID COPY` + `UID STORE +FLAGS (\Deleted)` + `EXPUNGE` — chosen per
  connection from CAPABILITY.
- **Connect-per-pass.** No persistent connections, no IDLE. Connect, work,
  LOGOUT. TLS via `:ssl` with proper verification (system CA store),
  implicit TLS on 993 (STARTTLS not needed for the supported posture).
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
is skipped with an audit note; it never wedges the pass.

The Engine also executes **post-approval mailbox ops** (see below) and the
**doctor** (see UI).

### SyncState + message index

Two SQLite tables (Ash resources) inside the workspace DB, both cache-layer
per Principle 1 — the files stay canonical:

- `mail_sync_state`: folder, uidvalidity, last_seen_uid.
- `mail_messages`: msg_id, path, from, subject, date, status,
  has_attachments, uid — the index behind the list/get RPCs. Rebuilt from
  the files on workspace open (same posture as the ICM tree scan), so a
  wiped DB is a resync/rescan, never data loss.

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
of SHA-256 over the Message-ID (fallback when Message-ID is missing:
SHA-256 over date + from + subject). Collision-safe and deterministic —
resync lands the same file. Frontmatter values YAML-encoded with the
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

### inbox.md

A single regenerated file — a header table (date, from, subject), newest
first, capped (default 200). Awareness only: it feeds the Today summary
count and gives the agent daily-briefing context without exposing bodies
the user didn't hand over.

### config/mail.yaml (v3)

Non-secret only. The v2 `smtp:` block and `username_env`/`password_env`
keys are removed.

```yaml
account: mara@example.com
imap:
  host: imap.example.com
  port: 993
  ssl: true
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

- The Priya mock is reseeded as
  `sources/mail/messages/2026-07-09-priya-nair-seed0001.md` with
  `source: seed`, `source_ref: "email://seed/priya-nair-inquiry"`,
  `status: review` — the whole demo loop keeps working with no account.
- `sources/mail/normalized/` (and the JSON mock) is removed; `inbox.md`
  seeded with a small plausible header list.
- `config/mail.yaml` rewritten to v3 (preserving any user-edited host/
  account values, dropping smtp/env keys).
- `icm/Workflows/New Inquiry Triage.md` input contract updated: the run
  names a `sources/mail/messages/*.md` path (markdown, not JSON).
- Idempotent `Valea.Workspace.Migration` step, same pattern as v1→v2;
  `config/workspace.yaml` version bumps to 3.

## Credentials

- **Desktop:** two Tauri commands using the `keyring` crate —
  `mail_secret_set(workspace_id, username, secret)` /
  `mail_secret_get(workspace_id, username)` (plus delete). Service name =
  the app bundle identifier; account = `workspace_id:username`. Exposed
  only over Tauri IPC to the SPA, never over HTTP.
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
after the local approve completes. It can never block or undo an approval:

1. **APPEND draft**: compose RFC822 from the approved draft markdown via
   `:mimemail` — `To`/`Subject` from the draft frontmatter,
   `In-Reply-To`/`References` from the source message so the draft threads
   correctly — APPEND to the configured Drafts folder with `\Draft` flag.
   Audit `draft_appended`.
2. **MOVE source message** `AI/Review` → `AI/Processed`; flip the file's
   `status:` to `processed`. Runs on **reject too** (a rejected item has
   still been reviewed). Audit `message_archived`.

Per-op status (`pending / done / failed / skipped`) is recorded on the
queue item envelope (a versioned extension of `queue_item/v1` →
`mailbox_ops` map) and surfaced in the UI with a retry action
(`mail_retry_mailbox_ops(item_id)` RPC, idempotent — ops that succeeded
are not repeated; APPEND idempotence is guarded by checking for a prior
`draft_appended` audit success before re-appending). IMAP offline at
approval time = draft exists locally, ops show `failed` with retry. Seed
messages (`source: seed`) skip mailbox ops (`skipped`).

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

Setup panel: host, port, SSL, username, account label → password field
that writes **only** to the keychain (Tauri) and then hands off to the
backend; in browser dev it posts straight to `mail_set_credential` with a
visible "dev mode — not persisted" note. Then the doctor runs:

`config_present → credential_present → tcp_reachable → tls_ok → login_ok →
folders (review/processed/drafts exist; one-click "Create AI folders" for
the missing AI/* ones) → move_capability (MOVE or fallback)`

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
| MOVE not supported | COPY+STORE+EXPUNGE fallback per CAPABILITY |
| Mailbox op fails post-approval | approval stands, op `failed` + retry button, audited |
| Evil attachment filename | sanitized to safe basename, never traverses |
| One bad message | skipped + audited, pass continues |

## Testing

- **ImapClient:** scripted fake IMAP server over real TCP/SSL sockets in
  ExUnit (the fake-ACP-agent pattern): greeting, login, literals, tagged/
  untagged interleaving, MOVE vs fallback capability variants, size
  responses, mid-stream disconnects.
- **Normalizer:** fixture `.eml` corpus — plain, HTML-only, nested
  multipart, base64/quoted-printable, ISO-8859-1/Windows-1252, evil
  filenames, broken MIME.
- **Engine:** fake Transport — full pass, incremental pass, UIDVALIDITY
  reset, dedupe, size cap, auth-failure pause, post-approval ops incl.
  failure/retry/skip-for-seed, generation staleness.
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
