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

## M6 — Modern auth: OAuth2

**Spec:** design doc §M6 — `docs/superpowers/specs/2026-07-29-mail-full-client-design.md` ("M6 — Modern auth: OAuth2 (XOAUTH2)"). Task detail below elaborated at milestone start (2026-07-30) per the original plan note, against HEAD `e7c679c`.

**Planning facts verified against the code (2026-07-30):**
- Credentials are RAM-only zero-arity closures in Engine state (`engine.ex:639`), resolved only at the `transport.connect/3` boundary via `resolve_secret/1` (`engine.ex:1362`) — the designated seam for "password or fresh access token".
- `set_mail_credential`'s `kind` is a closed clause map (`credential_kind/1`, `api/mail.ex:530-537`); frontend restart-resupply (`resupplySlot`, `stores/mail.svelte.ts:1384-1442`) already re-pushes keychain slots — a third `"oauth"` kind rides all of it.
- `SmtpClient` is a custom module on raw `:ssl` (gen_smtp is MIME-only); AUTH mechanism selection lives at `smtp_client.ex:220-260`, TLS-gated.
- IMAP `login/3` sits at `imap_client.ex:490-505` inside the `connect/3` `with` chain; `drive_segments/5` does NOT yet model XOAUTH2's failure round (server `+ <base64 error>` continuation → client answers with an empty line → tagged `NO`).
- Engine status vocabulary at `engine.ex:200-207`; `@paused_statuses` at `engine.ex:197`; sticky `auth_failed` classification at `engine.ex:1759`.
- `Settings.detect_provider/1` recognizes Gmail only (`settings.ex:85,179`); no outlook/M365 detection exists anywhere.
- Outbound HTTP is `:httpc` with an injectable seam (`Autoconfig.default_http_get/1`, `autoconfig.ex:279-309`); the token endpoint needs a POST/form-encoded sibling of that exact shape.
- The Phoenix endpoint IS the loopback listener; the token-EXEMPT `/calendar/feed.ics` scope (`router.ex:63-64`, own query credential, constant-time compare) is the precedent for an unauthenticated `/oauth/callback` route (providers cannot send the control token). Ports are dynamic (dev 4200, packaged 4817) — the redirect URI must be built at runtime from endpoint config; Google/Microsoft native-client rules allow any loopback port.
- Single-flight precedent: the Engine's deferred-reply `ops_queue` shape (`engine.ex:669-678, 819-898`) — monitored Task + parked callers, `handle_call` never blocks.

### Task 15: XOAUTH2 in the clients

**Files:** `backend/lib/valea/mail/settings.ex` (+ test), `backend/lib/valea/api/mail.ex`, `backend/lib/valea/mail/imap_client.ex` (+ test), `backend/lib/valea/mail/smtp_client.ex` (+ test), `backend/lib/valea/mail/smtp_transport.ex`, `backend/lib/valea/mail/engine.ex` (+ test), `frontend/src/lib/components/mail/mail-shapes.ts` (+ test), regenerated `ash_rpc.ts`.

- [ ] `auth: :password | :oauth2` on the `Settings` account struct (default `:password`); per-account validation in `load/1` — an invalid `auth` value invalidates ONLY that account, never silently falls back to `password` (a downgrade would send an access token as a LOGIN password); `render/1` round-trips it; flat `auth` arg on `setup_mail_account` + field on `get_mail_account_settings`; codegen.
- [ ] One shared pure SASL-string builder: `Base.encode64("user=" <> user <> "\x01auth=Bearer " <> token <> "\x01\x01")` — must never raise on 8-bit input (test it).
- [ ] `ImapClient.connect/3` branches on the account's auth mode: oauth2 → `AUTHENTICATE XOAUTH2 <b64>` (single literal-free segment) instead of `LOGIN`; the FAILURE path answers the server's `+ <base64 error>` continuation with an empty line and reads the tagged `NO`, mapping to `{:error, :reauth_required}` (distinct from `:auth_failed`); add `AUTH=XOAUTH2` to capability detection (`capability_wire_name/1`).
- [ ] `SmtpClient.authenticate/3`: oauth2 accounts use ONLY `AUTH XOAUTH2` — never fall back to PLAIN/LOGIN with a token; handle the 334-continuation error round (empty line → 535 rejection) → `:reauth_required`; password accounts keep byte-identical behavior. Thread the auth mode through the `SmtpTransport` behaviour contract.
- [ ] Engine: `"reauth_required"` joins the status vocabulary, `@type status` doc, and `@paused_statuses`; sticky like `auth_failed`; cleared by `set_credential`; surfaced through `mail_status` (respect the string-key falsy-map rule); `mailStateLabel` in `mail-shapes.ts` gains the state→copy clause (e.g. "Sign-in expired").
- [ ] Task-15 stopgap credential source (documented in the Engine moduledoc): an oauth2 account's existing IMAP/SMTP slots hold a static access token — the auth mode picks the SASL verb, the slot supplies the string. Task 16 replaces slot resolution for oauth2 accounts with engine-minted fresh tokens behind the same closure contract.
- [ ] Fake-server tests, BOTH clients: successful XOAUTH2 exchange asserting the exact base64 line; failure exchange including the continuation/empty-line round; fake SMTP advertises `AUTH XOAUTH2` only in the post-STARTTLS EHLO; every existing password-path script stays untouched (AUTHENTICATE replaces LOGIN's single tag, so tag numbering must not shift).

### Task 16: Authorization flow + setup UI

**Files:** new `backend/lib/valea/mail/oauth.ex` (+ test), new `backend/lib/valea_web/controllers/oauth_callback_controller.ex` (+ test) + router scope, `backend/lib/valea/mail/engine.ex` (+ test), `backend/lib/valea/api/mail.ex`, `backend/lib/valea/mail/settings.ex` (+ test), `frontend/src/lib/components/mail/SetupPanel.svelte`, `frontend/src/lib/components/mail/mail-shapes.ts` (+ test), `frontend/src/lib/stores/mail.svelte.ts` (+ test), regenerated `ash_rpc.ts`.

- [ ] Provider presets in `Valea.Mail.OAuth`: Gmail (`accounts.google.com/o/oauth2/v2/auth` + `oauth2.googleapis.com/token`, scope `https://mail.google.com/`) and Microsoft 365 (`login.microsoftonline.com/common/oauth2/v2.0/authorize` + `/token`, scopes `offline_access https://outlook.office.com/IMAP.AccessAsUser.All https://outlook.office.com/SMTP.Send`); public client ids in app config (`config :valea, :mail_oauth, ...`), overridable per account via `oauth_client_id` in `mail.yaml` (PKCE public clients — no secret anywhere).
- [ ] `start_mail_oauth {account, generation}` RPC: mints state + PKCE verifier/challenge (S256, `:crypto.strong_rand_bytes`), keeps ONE pending flow per account with a TTL, returns the consent URL; redirect URI built at runtime from endpoint config as `http://127.0.0.1:<port>/oauth/callback`.
- [ ] Token-exempt `/oauth/callback` route (the `/calendar/feed.ics` precedent): constant-time state validation; backend-side code exchange (`:httpc` POST, injectable HTTP seam per the autoconfig convention); on success store the refresh token in the engine's new oauth slot and respond with a minimal "Signed in — you can return to Valea" page; error paths (state mismatch, provider `error` param, exchange failure) render an honest failure page and clear the pending flow.
- [ ] Third credential kind `"oauth"` in `credential_kind/1` / `set_mail_credential` (refresh-token resupply after restart, engine slot + rebuild semantics like `:imap`); frontend: oauth completion push → keychain write to `<slug>:oauth` (desktop; RAM-only in browser dev) + boot-time `resupplySlot` reads it back.
- [ ] Engine access-token machinery: per-account cache `{access_token, expires_at}`; single-flight refresh via monitored Task + deferred replies (the `ops_queue` precedent — `status/1`/`sync_now/1` stay instant); oauth2 accounts' worker credential closures call into the engine for a fresh token; `invalid_grant` at refresh → clear cache + refresh token → `reauth_required`.
- [ ] Setup UI: `detect_provider` gains M365 hosts (e.g. `outlook.office365.com`); gmail/outlook detection routes the add form to "Sign in with Google/Microsoft" (password fields hidden for oauth2; an explicit "use a password instead" escape stays — app passwords remain valid); consent URL opened via `openExternal`'s popup-blocker-safe deferred variant; `reauth_required` account cards get a "Sign in again" action reusing the same flow; connected state lands via the existing status push.
- [ ] Tests: OAuth module (consent-URL construction, PKCE pair properties, token exchange success/failure with injected HTTP); callback controller (happy path, state mismatch, provider error, exchange failure); engine single-flight (N concurrent token requests → exactly one refresh, all callers served); `invalid_grant` → `reauth_required`; settings round-trip incl. `oauth_client_id` override; mail-shapes helpers under Vitest; codegen fresh.
- [ ] Manual acceptance against one real Gmail and one real M365 mailbox (the only non-local verification in this plan) — PENDING USER; requires the user registering the public client ids with Google/Microsoft first.
