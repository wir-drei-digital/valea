# Mail — Full Client Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the ten audit gaps — mark-read, Trash/move, pagination, attachment open, human compose/reply/forward (+ attachments), FTS5 search, threading, `cid:` images, notifications + IMAP IDLE, OAuth2 — per the phased spec, preserving every mail safety invariant (never_expunge, human-only hash-bound transmission, file-first, mandatory TLS).

**Spec:** `docs/superpowers/specs/2026-07-29-mail-full-client-design.md`

**Tech stack:** Elixir/Phoenix + Ash (ash_typescript codegen), ecto_sqlite3 (FTS5 via raw-SQL migration), gen_smtp, Floki; Svelte 5 + SvelteKit 2, Tailwind 4, bits-ui popover; Vitest 4, ExUnit.

**Planning facts verified against the code (2026-07-29):**
- `S` is already a pushable flag (`Maildir.pushable_flags/0` = S/R/F; `ops_file.ex` accepts it) — M1 mark-read needs **no backend change**.
- `list_mail_messages` already accepts `limit` + `before` — pagination is store/UI only.
- `Normalizer` does **not** capture `Content-ID` today — M4 must add it end-to-end (normalizer → landed frontmatter → `message_html`).
- Drafts have **no** attachments support today (`DraftFile` grammar, `DraftMime`) — Task 7 adds it.
- The account's special-folder names (incl. `trash`) already ride `mail_status` (`MailAccountStatus.folders`).

## Global constraints

- Frontend package manager is **bun**; backend is **mix**. **Never run prettier**; backend formatting is a `mix format` hook.
- Svelte 5 runes only; **no component render harness** — logic in sibling `.ts` files (Vitest), components verified by `bun run check`.
- `{@html}` forbidden for mail/agent content everywhere; mail HTML renders ONLY through the existing sandboxed `HtmlMailView` iframe.
- Backend path logic goes through `Valea.Paths` (`ancestor?`, `relative_to`, `resolve_real`) — `Path.relative_to/2` and raw `String.starts_with?` path checks are lint-failed by `paths_boundary_test.exs`.
- Every mutating RPC takes `generation` and guards with `Manager.check_generation/1`; every `account` argument goes through `validate_slug/1` before any I/O.
- Top-level boolean action fields that can be `false` use STRING keys (the ash_typescript falsy-map rule — see `Valea.Api.Mail`'s moduledoc).
- One `workspace:events` join (root layout); new pushes ride the existing channel + `wireMailEvents`.
- After RPC-surface changes: `mix ash_typescript.codegen`, commit the regenerated client (`just test` fails on staleness).
- Elixir test strings containing parens must not use `~s(...)` sigils (they don't nest) — use `~s[...]`.
- Commit after every task; end commit messages with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Milestone exit: full `just test` green + a live pass against the dovecot rig (see the browser-testing memory / `just mail-dev`; remember the container needs `mkdir -p /home/vmail/mara && chown -R 1000:1000 /home/vmail`, and dev TLS trust needs the COMBINED CA bundle, not the fixture CA alone).

---

## M1 — Triage basics

### Task 1: Mark read/unread (auto on open + manual toggle)

**Files:** `frontend/src/lib/components/mail/MessageView.svelte`, `frontend/src/lib/components/mail/mail-shapes.ts` (+ test), `frontend/src/routes/mail/+page.svelte` (if the effect lives route-side).

- [ ] Pure helper `markReadOp(msgId, folder)` / `markUnreadOp(msgId, folder)` in `mail-shapes.ts` returning the flag-op maps (`add/remove: ["S"]`) + Vitest coverage (shape, and that `S` is the only flag touched).
- [ ] Auto-mark effect: when the open message's frontmatter flags lack `S`, fire `mailStore.applyOps` once per opened msg_id (guard against re-fire on refetch; fire-and-forget — op rejection must not surface an error banner).
- [ ] Manual "Mark unread"/"Mark read" ghost action beside Flag (uses the same `runOp` path; after mark-unread, suppress the auto-mark for that msg_id until navigation).
- [ ] Verify the unread dot/filters/Today counts update via existing refetches (no new wiring).

### Task 2: Trash + Move-to-folder actions

**Files:** `MessageView.svelte`, `mail-shapes.ts` (+ test), new `frontend/src/lib/components/mail/MoveToPopover.svelte`.

- [ ] Helpers: `trashTarget(status, currentFolder)` (configured `folders.trash`, `null` when unset or already there) and `moveTargets(folders, currentFolder)` — pure + tested.
- [ ] "Delete" action → `move` op to the trash folder, then navigate to `/mail` (Archive's exact pattern, warn-ink label, no confirm).
- [ ] `MoveToPopover` (FolderPicker's visual pattern) listing `moveTargets`; pick → `move` op → back to list.
- [ ] ExUnit: none needed (executor `move` is covered); extend `mail-components.test.ts` for both helpers.

### Task 3: List pagination ("Load older")

**Files:** `frontend/src/lib/stores/mail.svelte.ts` (+ `mail.test.ts`), `frontend/src/routes/mail/+page.svelte`.

- [ ] Store: track `oldestCursor`/`lastPageFull` from `refreshMessages`; add `loadOlder()` → `listMailMessages(account, folder, {limit, before: oldestCursor})`, append + dedupe by msg_id; reset on account/folder switch. Tests: append, dedupe, reset, no-op when last page wasn't full.
- [ ] UI: "Load older" row under the list when `lastPageFull` (hidden while the read filter shows a filtered-empty note); disable while in flight.
- [ ] Guard: live refetches (`handleMailMessage`/`handleMailSync`) replace only the NEWEST page — keep appended older pages (document the compromise chosen in the store doc comment).

### Task 4: Attachment open

**Files:** `MessageView.svelte`, `frontend/src/lib/components/files/raw-url.ts` (+ test) if the builder needs a workspace-path variant, backend `files_controller` ONLY if it refuses mail paths (verify first).

- [ ] Verify `/files/raw` serves `sources/mail/<acct>/views/attachments/...` under the split credential (curl against the dev backend); note the finding in the task commit message.
- [ ] Attachment chips become links: browser → raw URL in a new tab; desktop → `openExternal(rawUrl)`. Keep copy-path as a small secondary icon.
- [ ] Vitest for the URL builder variant; no new backend tests unless the controller needed a change.

**M1 exit:** dovecot live pass — open unread message marks it read (dot clears, server flag set — check via a second sync), delete lands the message in Trash on the server, move round-trips, "Load older" pages a >100-message INBOX (seed loop), attachment opens.

---

## M2 — Compose & send

### Task 5: `write_mail_draft` RPC

**Files:** `backend/lib/valea/api/mail.ex`, `backend/lib/valea/api.ex`, `backend/lib/valea/mail/draft_file.ex` (content-hash helper reuse), tests in `mail_rpc_test.exs`; codegen + `client.ts` wrapper.

- [ ] Action `write_mail_draft(account, name | nil, content, base_hash | nil, generation)` → `%{"name" => ..., "saved" => true}`. Name minted `YYYYMMDDTHHMMSS-<subject-slug>` when nil (slug from the parsed draft subject, `"draft"` fallback); name grammar validated like `get_mail_draft`'s.
- [ ] Refuse before writing: grammar-invalid content (`DraftFile` parse), CAS mismatch (`"content_changed"` when `base_hash` set and stale), a name that resolves outside `drafts/` (`Paths.resolve_real`), and drafts in a non-`draft` ledger state (`"draft_busy"` — never rewrite a file mid-push/send).
- [ ] Atomic write; the existing `mail_draft` watcher push refreshes every panel for free.
- [ ] ExUnit: create-with-minted-name, update-with-CAS (ok + stale), grammar refusal, traversal refusal, busy-state refusal. Codegen + wrapper (`api.writeMailDraft`).

### Task 6: Compose UI (new / reply / reply-all / forward)

**Files:** new `frontend/src/lib/components/mail/ComposeView.svelte`, new `frontend/src/lib/components/mail/compose.ts` (+ test), `MessageView.svelte`, `routes/mail/+page.svelte`, `mail.svelte.ts`.

- [ ] Pure `compose.ts`: `draftContent(fields)` (frontmatter render: to/cc/bcc/subject/in_reply_to + body — mirror `DraftFile`'s grammar exactly), `replyPrefill(frontmatter, ownAddress, mode: reply | replyAll | forward)` (recipient math, `Re:`/`Fwd:` idempotent prefixing, `> ` quoting / forward separator). Vitest: recipient de-dup + own-address removal, quoting, subject prefixes, frontmatter injection safety (newlines in subjects).
- [ ] `ComposeView` in the main pane behind `?compose=new` / `?compose=<draftName>`: To/Cc/Bcc/Subject inputs + body textarea; Save (→ `writeMailDraft`, then stays editing with the returned name + fresh base hash); "Review & send…" (save, then the existing `SendConfirmModal` flow); push-only accounts get "Push to Drafts" instead (same gate the Drafts panel uses).
- [ ] Entry points: "Compose" button in the list-pane header; Reply/Reply-all/Forward actions in the read pane → `?compose=new` with prefill carried via in-memory handoff (the `initial-prompt.ts` pattern, not URL params — bodies don't belong in URLs).
- [ ] Unsaved-changes guard on navigation (beforeNavigate + the pane-close flush contract).

### Task 7: Draft attachments

**Files:** `backend/lib/valea/mail/draft_file.ex`, `draft_mime.ex`, `ops_executor.ex` (review snapshot), tests; `ComposeView.svelte`, `SendConfirmModal.svelte`, `compose.ts`.

- [ ] `DraftFile`: optional `attachments:` frontmatter — workspace-relative paths, each resolved via `Paths.resolve_real` against the workspace root at USE time (missing/outside → draft invalid for push/send with a per-file reason).
- [ ] `DraftMime`: `multipart/mixed` when attachments present; content-type by extension (closed map + `application/octet-stream` fallback); caps 10 MB/file, 25 MB total — enforced at review/push, refused with `"attachments_too_large"`.
- [ ] Review snapshot lists `{filename, bytes}` per attachment; `SendConfirmModal` renders them (what leaves the machine is exactly what was reviewed — the hash still covers only draft bytes, so the snapshot ALSO fingerprints attachment content hashes into `review_fingerprint`).
- [ ] Composer "Attach…" popover over the workspace tree (`IcmTree` reuse); forward mode pre-fills the original's landed attachment paths.
- [ ] ExUnit: MIME shape round-trip (parse with `:mimemail`), caps, missing-file refusal, fingerprint covers attachment bytes.

**M2 exit:** dovecot live pass — compose → review → send (against a real SMTP? the rig has none: verify to the point of `send_draft`'s transport call with the fake transport in dev config, plus one manual real-account send), reply threading headers resolve, attachment lands in the built MIME.

---

## M3 — Find & follow

### Task 8: FTS5 index + `search_mail` RPC

**Files:** new migration under `backend/priv/repo/migrations/` (raw SQL), `backend/lib/valea/mail/store.ex`, `views.ex`, `index.ex`, `api/mail.ex` (+ registry/codegen/wrapper), tests.

- [ ] Migration: `CREATE VIRTUAL TABLE mail_search USING fts5(account UNINDEXED, msg_id UNINDEXED, from_text, subject, body, tokenize='unicode61', prefix='2 3')`.
- [ ] `Store.search(account, query, limit)`: parameterized `MATCH` with the user string transformed into quoted prefix terms (`foo bar` → `"foo"* "bar"*`) — FTS query syntax is NEVER exposed; empty/oversized queries short-circuit to `[]`.
- [ ] Feed points: `Views.land` upsert, final `remove_occurrence` delete, `Index.rebuild` truncate-and-refeed (body text read from the just-written view file, from/subject from the normalized message).
- [ ] RPC `search_mail(account, query, limit \\ 40)` → summary rows (+ `snippet` via `snippet(mail_search, ...)`); slug + workspace guards as everywhere.
- [ ] ExUnit: land→searchable, remove→gone, rebuild→consistent, prefix + multi-term behavior, quoting of hostile query strings.

### Task 9: Search UI

**Files:** `routes/mail/+page.svelte`, `mail.svelte.ts` (+ tests), `MessageList.svelte` (snippet line).

- [ ] Store: `search(query)` / `clearSearch()`, results separate from `messages` (no cross-contamination with folder state); debounce 250 ms route-side.
- [ ] UI: search input under the pane header (folder picker + read filter hide while active); result rows reuse `MessageList` with the snippet as the second line; Esc / clear restores the folder view; selecting a result opens it normally (`?account&message`).

### Task 10: Thread keys (backend)

**Files:** migration (add `thread_key` to `mail_messages` + backfill note), `store.ex`, `index.ex`, `views.ex`, `api/mail.ex` (`list_mail_messages` `threaded` arg + `thread_count`; `message_rows_by_thread_key`), tests.

- [ ] `thread_key` derivation (references head → in_reply_to → message_id → msg_id), written at land/refresh and by `Index.rebuild` (which is the backfill: rebuild on next activation covers existing stores — document that).
- [ ] `list_mail_messages(threaded: true)`: newest row per thread_key within the folder + `thread_count`; unthreaded behavior byte-identical when the flag is absent.
- [ ] `get_mail_thread(account, thread_key)` RPC → ordered summaries across folders.
- [ ] ExUnit: derivation table, collapse + count, cross-folder thread listing, rebuild backfill.

### Task 11: Thread UI

**Files:** `MessageList.svelte`, `MessageView.svelte`, `mail.svelte.ts`, `mail-shapes.ts` (+ tests), `routes/mail/+page.svelte`.

- [ ] List renders threaded by default (count badge on multi-message threads); a store-level escape hatch keeps search results flat.
- [ ] Read pane thread strip: the thread's other messages (from `get_mail_thread`) as compact jump rows above the body; current message highlighted.
- [ ] Unread semantics: a collapsed thread shows the dot if ANY member is unread (pure helper + test).

**M3 exit:** dovecot live pass — seeded thread (3 replies) collapses with count and the strip jumps between members; body-text search hits with snippet; hostile query strings return calmly.

---

## M4 — Rich rendering

### Task 12: `cid:` images inline

**Files:** `backend/lib/valea/mail/normalizer.ex` (+ test), `message_file.ex` (attachment frontmatter `content_id`), `views.ex` (thread it through), `api/mail.ex` (`message_html` cid resolution), fixtures (new `cid_image.eml`), `mail_rpc_test.exs`.

- [ ] Normalizer captures `Content-ID` per attachment (angle-bracket-stripped); `MessageFile.render` emits `content_id:` in the attachments list (injection-hardened like every header field); parse side reads it back.
- [ ] `message_html`: after sanitize, resolve `src="cid:X"` against the message's landed attachments (frontmatter → attachment path → `Paths.resolve_real` under the account's attachments dir) and inline as `data:<mime>;base64` (1 MB/image, 4 MB/message caps; unresolvable/over-cap cids left as-is).
- [ ] ExUnit end-to-end: land the fixture → `get_mail_message` html contains the data URI; caps honored; a cid referencing a non-attachment resolves to nothing.

---

## M5 — Live (elaborate task detail at milestone start)

### Task 13: New-mail notifications

- [ ] Sync pass computes `new_unread` (newly landed INBOX occurrences without `S`) per finished pass; `mail_sync` push gains the field (additive).
- [ ] Per-account `notifications:` flag in `config/mail.yaml` (Settings load/render + `setup_mail_account` arg + settings-row toggle; default off).
- [ ] Frontend `notify.ts`: permission-gated OS notification (Tauri plugin on desktop — desktop-crate capability + the `keychain.ts`-style IPC boundary note — `Notification` API in browser); wired off `wireMailEvents`' `mail_sync` handler; click → focus `/mail?account=…`.

### Task 14: IMAP IDLE

- [ ] `IdleWatcher` GenServer per account (engine-supervised, credential-lifecycle-coupled): CAPABILITY-gated IDLE on INBOX over its own verified-TLS connection; untagged EXISTS/EXPUNGE/FETCH → debounced targeted sync-pass trigger; 25-min re-issue; reconnect with backoff; clean no-op exit when the server lacks IDLE.
- [ ] Fake-IMAP-server test coverage for the IDLE conversation (extend `fake_imap_server_test.exs` harness); engine tests for lifecycle (credential set/cleared, engine stop).
- [ ] Dovecot supports IDLE — live-verify: APPEND from the seed script while the app is open; the message appears without "Sync now".

---

## M6 — Modern auth: OAuth2 (elaborate task detail at milestone start)

### Task 15: XOAUTH2 in the clients

- [ ] `auth: password | oauth2` per-account config (Settings; default password); credential closure abstracted to yield either a password or a fresh access token.
- [ ] `ImapClient` `AUTHENTICATE XOAUTH2` + SMTP `AUTH XOAUTH2` (base64 SASL string), auth-failure mapping to a distinct `reauth_required` engine state.
- [ ] Fake-server tests for both SASL exchanges.

### Task 16: Authorization flow + setup UI

- [ ] PKCE authorization-code flow with loopback redirect: backend-minted state/verifier, localhost listener, provider consent in the system browser, code exchange, refresh token → `<slug>:oauth` keychain slot (RAM-only in browser dev); single-flight access-token refresh in the engine; `invalid_grant` → `reauth_required` + "Sign in again" in settings.
- [ ] Gmail + Microsoft 365 presets (endpoints/scopes per spec); client ids in app config, overridable per account; autodiscovery/provider detect routes gmail/outlook hosts to "Sign in with …" in the setup form (password fields hidden for oauth2 accounts).
- [ ] Manual acceptance against one real Gmail and one real M365 mailbox (the only non-local verification in this plan).
