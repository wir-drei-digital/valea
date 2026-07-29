# Mail — Full Client (closing the ten gaps)

**Date:** 2026-07-29
**Status:** Approved (design), pending implementation plan
**Builds on:** `2026-07-11-mail-design.md` (spec E), `2026-07-17-mail-maildir-design.md`, `2026-07-26-mail-smtp-send-design.md` (spec G), and the 2026-07-29 UI pass (HTML rendering + trust gate, autodiscovery, account edit, folder popover, read filters, Today unread).

## Goal

Close the ten gaps identified in the 2026-07-29 audit so Valea mail is a
fully featured, daily-drivable email client — without weakening any of the
standing safety invariants:

- **never_expunge** — Valea never expunges a message; "delete" is a move to
  the configured Trash folder, hand-reversible on the server.
- **Human-only transmission** — nothing is ever sent except by an explicit
  human action on the control-token-gated RPC surface, hash-bound to the
  exact reviewed draft. Composing (new in this wave) writes draft FILES;
  it adds zero new transmission paths, and agents gain none.
- **File-first** — drafts, trust, config, and views remain plain files.
- **TLS mandatory** — unchanged for password auth; OAuth adds XOAUTH2 on
  top of the same verified-TLS connections.

Scope decisions (confirmed 2026-07-29): all ten gaps in one phased plan,
core UX first and OAuth2/IDLE as the final phases; compose is **plain-text
first** riding the existing draft pipeline (rich/HTML composition is out of
scope); search is **full-text via SQLite FTS5**.

## Phasing

| Milestone | Contents | Size |
|---|---|---|
| **M1 Triage basics** | mark read/unread (auto + manual), Trash + move-to-folder, list pagination, attachment open | small |
| **M2 Compose & send** | human compose/reply/reply-all/forward as plain-text drafts; then draft attachments | medium |
| **M3 Find & follow** | FTS5 full-text search; conversation threading | medium |
| **M4 Rich rendering** | inline `cid:` images in HTML mail | small |
| **M5 Live** | new-mail OS notifications; IMAP IDLE push sync | medium |
| **M6 Modern auth** | OAuth2 (Gmail, Microsoft 365) for IMAP + SMTP | large |

Each milestone is independently shippable; later milestones may re-derive
detail at their start (progressive elaboration — M5/M6 tasks are outlined,
not fully specified, in the initial plan).

## M1 — Triage basics

### Mark read / unread

The maildir `S` flag is already in the pushable set (`Valea.Mail.Maildir.
pushable_flags/0` = S/R/F) and the ops executor already applies flag ops
locally + on the server. This is therefore UI-only:

- **Auto-mark on open:** when the read pane loads a message whose flags lack
  `S`, the route fires one `mail_apply_ops` flag op (`add: ["S"]`) for the
  occurrence in the selected folder. Fire-and-forget; a rejected op (offline,
  blocked account) leaves the message unread rather than surfacing an error.
- **Manual toggle:** a "Mark unread" / "Mark read" action beside Flag in the
  read pane (same `runOp` plumbing as Flag).
- Lists/counts refresh through the existing `applyOps` refetch.

### Trash and move-to-folder

- **Trash:** a Delete action in the read pane composes a `move` op from the
  current folder to the account's configured `folders.trash` name (Gmail:
  `[Gmail]/Trash`) — exactly the Archive pattern, no confirm (a move is
  reversible server-side). Hidden when the message is already in Trash or no
  trash folder is configured.
- **Move to folder:** a "Move to…" popover (same look as `FolderPicker`)
  listing the account's mirrored folders minus the current one; picking one
  composes the `move` op. Both navigate back to the list on success.

### List pagination

`list_mail_messages` already takes `limit` + `before`. The store gains
`loadOlder()` (appends the next page keyed on the oldest loaded date-cursor;
dedupe by msg_id) and the list renders a "Load older" row whenever the last
fetch came back full. No virtualization in this wave.

### Attachment open

Attachment chips become real links: the workspace `/files/raw` endpoint
(which serves contained workspace files under the split credential) opens
the attachment in a new tab (browser) / the OS default app via the raw URL
(desktop `openExternal`). Copy-path stays as a secondary action.

## M2 — Compose & send (plain text)

### The write path

One new RPC, `write_mail_draft(account, name | null, content, base_hash |
null, generation)`:

- Creates (name null → minted `YYYYMMDDTHHMMSS-<subject-slug>.md`) or
  updates a draft file under `sources/mail/<account>/drafts/`.
- CAS on update: `base_hash` must match the current content hash (the page
  editor's conflict discipline; `"content_changed"` on mismatch).
- Validates the draft grammar via the existing `DraftFile` parser before
  writing — an unparseable draft is refused, never written.
- Control-token-gated like everything else; agents keep writing draft files
  directly through their mount (unchanged); this RPC is the HUMAN's pen.

Everything downstream is untouched: the ledger, push-to-Drafts, the review
snapshot, hash-bound send. A human-authored draft is just a draft.

### Compose UI

- **Compose** button in the mail list pane header (per selected account).
- A `ComposeView` in the main pane (route state `?compose=…`, like
  `?drafts=1`): To / Cc / Bcc / Subject inputs + a plain-text body textarea,
  Save (writes the draft) and "Review & send…" (saves, then opens the
  existing `SendConfirmModal` flow for that draft). Push-only accounts see
  Save + "Push to Drafts" instead — same gating the Drafts panel already
  applies.
- **Reply / Reply-all / Forward** actions in the read pane prefill the
  composer from the open message's frontmatter: recipients (reply →
  `reply_to || from`; reply-all → from + to minus the account's own
  address), `Re:`/`Fwd:` subject, `in_reply_to: <message_id>` (threading
  headers resolve backend-side at review time, as today), and a `> `-quoted
  plain-text body (forward: unquoted original below a separator).

### Draft attachments (second slice)

- Draft frontmatter gains `attachments:` — a list of **workspace-relative
  paths** (file-first: what you send must be a file in the workspace).
- `DraftMime` builds `multipart/mixed` when present (size caps: 10 MB/file,
  25 MB total, refused at review); the review snapshot lists filenames +
  sizes so the human confirms exactly what leaves.
- Composer UI: an "Attach…" picker over the workspace file tree (reuse
  `IcmTree` in a popover). Forward-with-attachments re-references the
  original message's landed attachment paths.

## M3 — Find & follow

### Full-text search (FTS5)

- A raw-SQL migration adds `mail_search` (FTS5, `unicode61`, prefix index):
  columns `account, msg_id, from_text, subject, body`.
- Fed at the same three points that own view files: `Views.land` (insert),
  `Views.refresh_folders` (no body change — no-op), `Views.remove_occurrence`
  final removal (delete), and `Index.rebuild` (truncate + re-feed per
  account) — so search never drifts from what's on disk.
- RPC `search_mail(account, query, limit)` → the `list_mail_messages`
  summary shape + a snippet. Query goes through FTS5 `MATCH` with the user
  string escaped into a prefix-quoted form (never raw — FTS query syntax is
  not exposed).
- UI: a search input in the mail list header; non-empty query swaps the
  folder list for results (folder-agnostic, per account); Esc/clear
  restores. Read filter hides during search.

### Threading

- Index rows gain `thread_key`: the first id of `references` when present,
  else `in_reply_to`, else the row's own `message_id` (else msg_id). Set at
  land/refresh time + backfilled by `Index.rebuild`.
- `list_mail_messages` gains `thread_count` per row and collapses to the
  newest row per thread when a new `threaded: true` argument is set.
- UI: the message list shows one row per conversation with a count badge;
  the read pane gets a thread strip (the other messages in this thread,
  from `message_rows_by_thread_key`) with jump links. Flat behavior is
  unchanged for messages with no references.

## M4 — Rich rendering: `cid:` images

- `Valea.Mail.Normalizer` captures each attachment's `Content-ID` (it
  currently keeps only filename + content); landed attachment frontmatter
  gains `content_id`.
- `message_html` resolves `src="cid:X"` against the message's landed
  attachments and inlines matches as `data:` URIs (caps: 1 MB/image,
  4 MB/message; over-cap images stay broken rather than blowing up the
  payload). CSP already allows `data:` images, trusted or not.
- Old views lack `content_id` — cid inlining simply starts working for
  newly landed mail; a doctor "re-land views" action is explicitly out of
  scope.

## M5 — Live

### New-mail notifications

- The sync pass reports how many NEW unread messages a finished pass landed
  (per folder-classified INBOX); the `mail_sync` push gains `new_unread`.
- Frontend: on `new_unread > 0` for any account with notifications enabled,
  raise an OS notification ("<account>: 2 new messages — <first subject>")
  — Tauri notification plugin on desktop (new capability in the desktop
  crate), `Notification` API in the browser. Click focuses/opens `/mail`.
- Per-account `notifications: true|false` in `config/mail.yaml` (default
  off), toggled from the account row in mail settings.

### IMAP IDLE

- Per-account `IdleWatcher` child under the account's supervisor: one
  dedicated TLS connection SELECTing INBOX and issuing IDLE (capability-
  gated; absent capability → watcher exits, polling behavior unchanged).
- On `EXISTS`/`EXPUNGE`/`FETCH` untagged events: debounce (2s) and trigger
  a targeted sync pass for INBOX through the existing engine entry point.
- Re-issue IDLE every 25 minutes; reconnect with backoff; credential comes
  from the same closure the sync connections use; watcher stops/starts with
  the engine's credential lifecycle.

## M6 — Modern auth: OAuth2 (XOAUTH2)

- **SASL XOAUTH2** in both `ImapClient` (`AUTHENTICATE XOAUTH2`) and the
  SMTP transport (`AUTH XOAUTH2`), selected per account by a new
  `auth: password | oauth2` config field (default `password` — nothing
  changes for existing accounts).
- **Token flow:** authorization-code + PKCE with a loopback redirect: the
  backend binds a localhost listener, the browser opens the provider's
  consent page (desktop `open_external`; plain tab in browser dev), the
  code is exchanged backend-side, and the **refresh token** is stored as
  the account's credential (OS keychain slot `<slug>:oauth`; RAM-only in
  browser dev, like passwords today).
- **Access tokens** are minted on demand by the engine's credential closure
  (single-flight refresh per account, refresh on expiry/re-auth on
  invalid_grant → account drops to a `reauth_required` state with a
  "Sign in again" affordance in settings).
- **Providers:** Gmail and Microsoft 365 presets (endpoints + scopes:
  `https://mail.google.com/`, `offline_access IMAP.AccessAsUser.All
  SMTP.Send`); client ids ship in app config and are overridable in
  `config/mail.yaml` (PKCE public clients, no secret). Autodiscovery/
  provider detection routes gmail/outlook hosts to the OAuth path in the
  setup form ("Sign in with Google/Microsoft" replaces the password field).

## Explicitly out of scope (this wave)

Rich/HTML composition and inline compose images; undo-send delay and
scheduled send; junk/spam controls; address book and contact autocomplete;
multiple sending identities per account; message-list virtualization;
re-landing old views for cid backfill; POP3.

## Testing posture

Every backend behavior lands with ExUnit coverage (the mail suite's
existing fixtures + the fake IMAP server/transport where connections are
involved); frontend logic stays in pure sibling `.ts` modules under Vitest
(no component harness). Each milestone ends with a live pass against the
dovecot rig (`just mail-dev` + the seeded-app-dir workflow) before merge;
M6 additionally needs one manual pass against a real Gmail and a real M365
mailbox — the only part of this plan that cannot be verified locally.
