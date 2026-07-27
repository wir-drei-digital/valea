# Human-only SMTP send (Spec G) — live acceptance checklist

Manual checks against real servers, executed by the user AFTER merge. The
automated suite covers every contract against the fake SMTP transport, the
real `SmtpClient` over `FakeSmtpServer`'s TLS sockets, and the model IMAP
transport; this list is the part only a real submission server and a real
provider can prove. Spec:
`docs/superpowers/specs/2026-07-26-mail-smtp-send-design.md`.

**Nothing here is safe to skip.** Send is the one action in this codebase
that cannot be undone: an accepted `250` is a message in someone else's
mailbox. Do not trust send on a real account until section A and section B
are both filled in.

Conventions: `WS` = the open workspace root. Fill every **Observed:** line;
a blank one means the check hasn't run. Use a throwaway recipient address
you control for every "normal send" step. Grep-gate exemption (documented,
not a failure): `backend/test/valea/mail/settings_test.exs`'s v4-config
fixture still contains `outbound: push_drafts_only` — it asserts that a v4
file loads unchanged, so the old value is the point of the test.

## Preface: the local submission-server companion

Section A needs a real socket with *scriptable* outcomes — a real provider
cannot be made to drop the connection after `DATA` on demand. Build a small
runnable companion under `scripts/` before starting, then point a test
account's `smtp:` block at it.

- **Basis:** `backend/test/support/fake_smtp_server.ex` is already exactly
  this server, minus a CLI. It listens on loopback with the committed TLS
  fixtures (`backend/test/fixtures/tls/{ca.pem,server.pem,server.key}`),
  speaks both security modes (implicit TLS and STARTTLS, with the RFC 3207
  post-upgrade `EHLO` rule enforced), and is driven by an ordered script of
  `{:greet, _} | {:expect, pattern, reply} | :starttls | :implicit_tls | …`
  steps. Extracting it into a script that takes a **fixed port** and a
  **named scenario** (`accept`, `reject-rcpt`, `drop-after-data`,
  `auth-fail`, `5xx-after-dot`) is the whole job — do not write a second
  SMTP server.
- **Trust root:** the fixture CA is not in the system store. Start the
  backend with `ELIXIR_ERL_OPTIONS` pointing at
  `backend/test/fixtures/tls/ca.pem`, exactly as the `mail-dev` recipe in
  the justfile documents for Dovecot (same caveat: no spaces in the
  checkout path, and unset it afterwards — it replaces the BEAM's trusted
  roots process-wide).
- **Pairing:** run it alongside `just mail-dev` so one test account has a
  real IMAP server (for the Sent copy and its retry) and a real submission
  server on the same host.
- Observed (companion built, scenarios reachable):

## A. Generic provider, real send

Either the local companion above (deterministic outcomes) or a real
non-Gmail provider (Infomaniak, Fastmail, a self-hosted MTA). The
`sent_copy` steps need a real IMAP account behind the same slug.

### A1. Setup and the first real send
- Steps: In Mail settings, add or edit an account with an `smtp:` block
  (host, 587/starttls or 465/tls, username, optional `from_name`). Use
  "same as IMAP" or type the SMTP password. Write a draft under
  `WS/sources/mail/<slug>/drafts/hello.md` (frontmatter `to:` + `subject:`,
  a plain body). Open the Drafts panel, click Send, read the confirm modal,
  confirm.
- Expected: the modal renders the parsed recipients, subject, and the
  sending identity `from_name <from>` — **from settings, never from the
  draft**; one click, no typed confirmation. The row walks
  `sending → sent`. The mail **arrives** at the recipient. The `From` is
  the configured identity; the `Message-ID` is `<valea.send.…@valea.invalid>`
  (distinct from any `valea.push.` id). The account's `Sent` folder gains
  the message exactly once (generic profile APPENDs the *record* variant);
  `WS/sources/mail/<slug>/spool/` is clean afterwards.
- Observed:

### A2. Bcc on the wire vs. in the record
- Steps: Send a draft with `to:`, `cc:`, and a `bcc:` address you control.
- Expected: every recipient (incl. bcc) receives it; the **delivered**
  message carries no `Bcc` header; the copy in your own `Sent` folder does.
- Observed:

### A3. Rejected recipient — nothing delivered
- Steps: Send a draft whose `to:` list has one deliverable address and one
  the server will reject (companion: `reject-rcpt`; real provider: an
  address at a domain it refuses to relay to).
- Expected: **nothing is delivered to anyone** — the abort happens with
  `RSET`/`QUIT` before `DATA`. The op is `rejected` with the per-recipient
  reason surfaced in the panel; the draft returns to `draft` and Send is
  offered again; no message in `Sent`; no partial delivery to the good
  address.
- Observed:

### A4. Lost response after DATA → `send_review`, resolved `sent`
- Steps: Companion scenario `drop-after-data` (kill the connection after
  the terminating dot, before the final reply). Send a draft.
- Expected: the row parks as **`send_review`**, never retries, and the
  panel explains what happened and tells you to check your own Sent folder
  and, if in doubt, the recipient. Resolve **`sent`** → the idempotent Sent
  copy runs, the op completes, the draft stamps `sent`. Watch the wire (or
  the companion's log): the transport is called **once**, never again.
- Observed:

### A5. Same drill, resolved `not_sent`
- Steps: Repeat A4 and resolve **`not_sent`**.
- Expected: the op is `rejected`, the draft reverts to `draft`, and Send is
  available again. Nothing was retransmitted by Valea itself.
- Observed:

### A6. Sent-copy failure and its retry
- Steps: Send successfully, but make the IMAP side fail the Sent APPEND
  (stop Dovecot / the IMAP server just after the accept, or point
  `folders.sent` at a name that does not exist).
- Expected: the send **completes** — a Sent-copy failure can never un-send
  the mail — with a `sent_copy_failed` notice and a retry affordance.
  Restore IMAP, click retry: it re-runs **only** the append, the copy lands
  **once** (search-first idempotence), and the notice clears. The recipient
  received exactly one message across the whole drill.
- Observed:

### A7. Crash mid-send, with IMAP down
- Steps: Queue a send, kill the backend while it is in flight (before the
  transport call for one run; after the accept for another). Relaunch with
  the IMAP server stopped.
- Expected: at activation and **with no network at all**, a send stranded
  before DATA classifies `rejected` (draft reverts, claim released — the
  row is not stuck rendering `sending`); one stranded at-or-past DATA parks
  as `send_review`; a `transmitted` op waits and finishes its Sent copy on
  the next connected pass. Nothing re-transmits at any point.
- Observed:

### A8. Review binding — the draft, the identity, the thread
- Steps: Three attempts. (a) Open the confirm modal, edit the draft file on
  disk, then confirm. (b) Open the modal, change `smtp.from` or
  `from_name` in Mail settings (or from a second tab), then confirm.
  (c) Write a draft with `in_reply_to:` a mirrored message, open the modal,
  delete that message server-side, sync, then confirm.
- Expected: all three refuse **before anything is composed or
  transmitted** — (a) a content-hash mismatch, (b) and (c)
  `re_review_required` — and the modal offers a reload that shows the new
  truth (for (c), the unthreaded warning). Nothing reaches the wire in any
  of them.
- Observed:

### A9. One draft, one claim
- Steps: With a draft open in two windows/tabs, click Send in both as
  close together as you can. Then, on a fresh draft, click Push and Send
  back-to-back.
- Expected: exactly one op is claimed; the second caller sees the existing
  op (`duplicate_active`), never a second transmission and never a second
  APPEND. A push-completed draft still reads `draft` with a `pushed` badge
  and still offers both buttons.
- Observed:

## B. Gmail, real send (Daniel's account)

App password (OAuth is a non-goal), provider `gmail`.

### B1. Normal Gmail send
- Steps: Configure `smtp.gmail.com` (587/starttls or 465/tls) on the Gmail
  account. Send a draft to an address you control.
- Expected: it arrives; the gmail profile **skips the Sent APPEND** and
  Google files the message in `[Gmail]/Sent Mail` itself — exactly **one**
  copy there, not two. The op completes and the draft stamps `sent`.
- Observed:

### B2. Lost-response drill → auto-reconcile completes
- Steps: Send, and kill the connection after the terminating dot (drop the
  network / block the port the instant the payload is out; a proxy that
  cuts the response is the reliable way).
- Expected: the op parks as `send_review`, then reconciliation searches
  Sent Mail for the op's `Message-ID` over the bounded re-check window,
  finds it, and the op **completes on its own** — proof, not a guess. If
  the search comes back empty it stays parked with the
  "Sent Mail was checked and found empty" note and is never auto-rejected;
  with IMAP not yet connected it renders the awaiting-connection notice.
- Observed:

### B3. Same-Message-ID re-send after a wrong `not_sent`
- Steps: Park a send (B2's drill), resolve **`not_sent`** even though the
  mail actually went out, then click Send again on the unedited draft.
- Expected: the second transmission carries the **same**
  `<valea.send.…@valea.invalid>` Message-ID (deterministic over the
  canonical bytes, which the engine's `status:` stamps do not change). On
  the **recipient's** side the duplicate threads/dedupes rather than
  appearing as two unrelated mails — verify in the recipient client, that
  is the whole point of this check. Then edit the draft and send once more:
  the Message-ID **changes**.
- Observed:

## C. Iteration loop, live

Needs one enabled ICM (the primary) plus a mail mount.

### C1. Agent revision refreshes the panel without navigation
- Steps: With the Drafts panel open, have an agent session edit a draft
  file under `WS/sources/mail/<slug>/drafts/`.
- Expected: the row updates (body, recipients, count) **without navigating
  or reloading** — the watcher's debounced `mail_draft` event drives the
  refetch. Editing drafts in two accounts inside one debounce window
  updates both, neither event lost. Writing a non-draft file under
  `sources/` triggers nothing.
- Observed:

### C2. Request changes routes to the open session
- Steps: Start a session that drafts a reply (from a message, "Start a
  session about this message"). With that session still running, use
  Request changes on the draft it wrote.
- Expected: the feedback lands in **that** session as a follow-up prompt
  (the drafting context is kept); the panel says "sent to session" with a
  working open-session link; the agent's edit ripples back through C1.
- Observed:

### C3. New-session path seeds the prompt
- Steps: Close/end that session (or use a draft no running session owns)
  and Request changes again.
- Expected: a **new** session starts on the MRU primary ICM with the mail
  mount included and the draft as its `input` grant, seeded with the revise
  prompt (revise the file at this path per the feedback, keep the
  frontmatter valid, do not touch `status:`) — the prompt is already there,
  not typed by you. Its draft write is still **ask-gated** (the feedback
  grants nothing). With no enabled ICM at all, it fails closed with the
  "enable a project first" remedy rather than guessing a primary.
- Observed:

## D. Multi-account

Two configured accounts (Dovecot `demo1`/`demo2`, or Gmail + generic).

### D1. Switch accounts with a message open
- Steps: Open a message in account 1's read pane, then switch to account 2
  with the switcher.
- Expected: the read pane clears or re-resolves — **never** a stale message
  from the other account; folders/messages clear before the refetch (no
  stale flash); the "Drafts (N)" count in the list pane shows the selected
  account's drafts only, while the panel keeps listing all accounts,
  labeled.
- Observed:

### D2. Colliding deep link
- Steps: Contrive the same `msg_id` in both accounts (same raw message
  delivered to both), then open `/mail?account=<slug>&message=<msgId>` for
  each.
- Expected: each link resolves to **its own** account's message. A deep
  link opened before mail status has resolved retries once accounts arrive
  instead of latching a permanent load error.
- Observed:

### D3. Simultaneous first syncs under WAL
- Steps: With both accounts configured and both mailboxes busy, open the
  workspace cold and let both engines run their first pass.
- Expected: both passes complete, no `database is locked` in the logs
  (`PRAGMA journal_mode` reports `wal`, `busy_timeout` 5s); the two
  accounts do not tick in lockstep afterwards (per-account poll jitter). On
  a filesystem that refuses WAL, expect a logged status notice — never a
  crash.
- Observed:

### D4. Cross-account isolation of the send side
- Steps: Put a wrong SMTP password on account 1. Sync and send on both.
- Expected: account 1's send fails with an auth error and its **IMAP sync
  keeps running**; account 2 is entirely unaffected in both directions.
  An account with no `smtp:` block shows no Send button at all and still
  offers Push.
- Observed:

## E. Doctor against a real provider

### E1. SMTP checks, sending account
- Steps: Run Doctor on a correctly configured sending account, then on one
  with a wrong port/security combination, then with the SMTP password
  removed.
- Expected: `smtp_tcp` → `smtp_tls` → `smtp_auth` appear after the IMAP
  checks and pass on the good account. **Nothing is enqueued anywhere** —
  no `MAIL FROM`, no message, nothing in any Sent folder, no test mail to
  any recipient. The bad port/security fails at `smtp_tls` with a copyable
  remedy naming 587↔STARTTLS / 465↔TLS; the missing credential fails
  `smtp_auth` with the resupply remedy and **without** opening a session.
  Credentials never appear in any error text. Doctor runs on demand only —
  confirm nothing re-runs it on a timer (providers rate-limit AUTH).
- Observed:

### E2. Push-only account
- Steps: Run Doctor on an account with no `smtp:` block.
- Expected: no SMTP checks at all — not three "not applicable" rows.
- Observed:

## F. Credential drills (desktop build)

### F1. SMTP keychain entry and resupply
- Steps: Set up SMTP in the desktop app (password typed once), quit,
  relaunch, send.
- Expected: keychain entry `"<workspace_id>" / "<slug>:smtp"` exists
  **beside** `"<slug>:imap"` (two entries, not one); after relaunch the
  account returns to `smtp_credential: present` without retyping, and a
  send works. Rotating the IMAP password does not change the SMTP one
  ("same as IMAP" copied it, it did not alias it). Browser dev mode
  instead requires `VALEA_MAIL_SMTP_PASSWORD_<SLUG>`.
- Observed:

### F2. Non-ASCII SMTP password
- Steps: Set an SMTP password containing non-ASCII (e.g. `pässwört£`) on
  the local companion or a provider that allows it; connect through setup +
  keychain round-trip, then send.
- Expected: AUTH succeeds; resupply after restart still works (no encoding
  mangling anywhere in the chain).
- Observed:

## Known deferred items (tracked, not blockers)

- **Generic-provider ambiguity is irreducible.** A parked `send_review` on
  a non-Gmail account cannot be resolved by Valea at all — only by the
  human, guided by the panel. A wrong `not_sent` costs a duplicate sharing
  one Message-ID (B3); a wrong `sent` costs an unsent mail believed sent.
- No SMTPUTF8: non-ASCII **addresses** are rejected at validation (subject
  and body are fine). No attachments, no HTML outbound, no scheduling,
  undo-send, or any automated retry of a transmission — by design.
- OAuth/XOAUTH2 stays a non-goal; Gmail needs an app password.
- The revise flow's session discovery is best-effort: it matches running
  sessions by `input` locator only, so a closed session means a fresh one.
