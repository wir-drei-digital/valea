# Spec G: Mail outbound — SMTP send, draft iteration, multi-account hardening

Date: 2026-07-26
Status: approved design, pending implementation plan
Predecessors: Spec E mail-as-maildir
(docs/superpowers/specs/2026-07-17-mail-maildir-design.md), Spec D
agent-native ICMs (docs/superpowers/specs/2026-07-16-agent-native-icms-design.md)

## Context & goal

Spec E shipped outbound as Push-to-Drafts only: the agent proposes draft
files, the user pushes a reviewed draft into the account's Drafts folder
and sends it from their own client. SMTP was cut because a lost response
after `DATA` cannot be disproven by any search — an *automated* sender
cannot ever safely retry.

Spec G revisits that with a different frame: **the human is in the loop at
transmission time.** There is no queue and no automated retry — a send is
one explicit click, and an unprovable outcome parks for the human who
clicked seconds ago. The worst case becomes "maybe unsent, maybe sent
once," never a blind duplicate. On the Gmail profile the ambiguity is even
resolvable: Gmail auto-files SMTP-sent mail into Sent Mail, so a
Message-ID search proves the outcome either way.

Three goals, one spec:

1. **SMTP send** — a second, human-only outbound action beside
   Push-to-Drafts, reusing the push machinery (claim → snapshot → spool →
   ledger) end to end.
2. **Draft iteration loop** — agents already draft by writing ask-gated
   files; close the loop so the Mail UI sees draft edits live and can
   route "request changes" feedback back into a session.
3. **Multi-account hardening** — fold in the fixes from the 2026-07-26
   multi-account audit (account-qualified message URLs, SQLite WAL +
   poll jitter, per-account drafts count, defensive executor guard).

## Decisions (user-confirmed)

1. **Send sits alongside Push-to-Drafts**, it does not replace it. Push
   stays as the low-trust fallback and covers accounts without SMTP
   configured.
2. **Full iteration loop in the Mail UI**: live draft refresh plus a
   Request-changes action that routes feedback into a session.
3. **SMTP credentials are a separate keychain entry per account**
   (`<workspace_id>:<slug>:smtp`), with a "same as IMAP" copy shortcut in
   the setup UI.
4. **The multi-account audit fixes land in this spec**, not a separate
   branch.
5. **Send is human-only, permanently.** Agents draft and iterate; the
   send trigger is a control-token RPC action agents structurally cannot
   reach (the Spec E trust boundary, unchanged in kind).

## Invariant rewrite

Spec E's "Valea cannot send mail — there is no SMTP anywhere" becomes:

> **Valea transmits mail only on an explicit human action, hash-bound to
> the exact draft the human reviewed. Agents have no path to send.**

Enforcement is the same boundary as push: `send_draft` is an action on the
control-token-gated RPC surface; agent sessions speak ACP only and carry
no RPC endpoint or token. No agent-facing tool or file convention maps to
send; the ops-file vocabulary still cannot express send, append, or
delete. `safety.outbound` in mail.yaml becomes `human_send_and_push`.
ARCHITECTURE.md and VISION.md's "no SMTP" language is rewritten in the
same change — the *invariant* is human-only transmission, not the absence
of a transport.

The IMAP `Valea.Mail.Transport` behaviour keeps its no-send property
untouched: SMTP lives in a separate behaviour (below), so "the IMAP
transport has no send callback" remains a checkable structural fact.

## Configuration & credentials

`config/mail.yaml` v5. Per-account, a new optional `smtp` block:

```yaml
version: 5
accounts:
  wirdrei:
    imap: { host: mail.example.com, port: 993, username: daniel@wirdrei.digital }
    smtp:
      host: mail.example.com
      port: 587                 # 587 => STARTTLS, 465 => implicit TLS
      security: starttls        # starttls | tls, must match the port's convention
      username: daniel@wirdrei.digital
      from_name: "Daniel Milenkovic"   # optional display name
      # from: <addr-spec>              # optional; defaults to smtp.username
    folders: { drafts: Drafts, sent: Sent, archive: Archive, trash: Trash }
    sync: { ... as v4 ... }
safety:
  never_expunge: true
  outbound: human_send_and_push
```

- **`smtp` absent → the account is push-only.** The Send action does not
  render for it; nothing else changes. v4 files load as v5 with no `smtp`
  blocks and the `safety.outbound` value normalized on next save (no prod
  migration concerns beyond that).
- `security` is validated against the port convention at config load
  (587↔starttls, 465↔tls; other ports allowed but must state `security`
  explicitly). There is no plaintext mode and no `none` value —
  **TLS mandatory and verified, always**, exactly as IMAP: `verify_peer`,
  hostname verification, SNI; trust-root override for tests only. AUTH is
  never issued before the TLS layer is up (STARTTLS completes first).
- **From identity is config-owned, never frontmatter-owned.** `From` is
  `smtp.from` (validated as a single addr-spec at config load) defaulting
  to `smtp.username`, with optional `smtp.from_name` RFC 2047-encoded.
  A draft cannot set or override From — header serialization takes the
  identity from settings only.
- Keychain: service `digital.wirdrei.valea`, account
  `<workspace_id>:<slug>:smtp` — separate from `:imap`. Setup UI offers
  "same as IMAP", which copies the IMAP secret into the SMTP entry (a
  copy, not an alias — rotation stays independent). Browser-mode dev
  fallback: `VALEA_MAIL_SMTP_PASSWORD_<ACCOUNT_SLUG_UPCASED>`.
  Credentials remain RAM-only closures per Engine, never on disk or in
  logs; `auth_failed` on SMTP pauses only sends for that account, never
  the IMAP sync.

**Doctor** grows three sequential SMTP checks per account (run on demand
only, never on a timer — some providers rate-limit AUTH):
`smtp_tcp → smtp_tls → smtp_auth` (EHLO, STARTTLS where configured,
AUTH, QUIT — never `MAIL FROM`, nothing that could enqueue anything).
Remedies stay copyable strings.

## SMTP transport & client

`Valea.Mail.SmtpTransport` — a new, deliberately tiny behaviour:

```elixir
@callback send(config, credential :: String.t(), envelope, data :: binary(), opts) ::
            {:ok, :accepted}
          | {:error, {:rejected_recipients, [{addr, reason}]}}
          | {:error, term()}          # failed BEFORE DATA was accepted — provably unsent
          | {:unknown, term()}        # response after DATA lost — maybe sent
```

`envelope` is `%{from: addr, rcpt: [addr]}` — computed from the parsed
draft, never from raw strings. The tri-state return is the load-bearing
contract: implementations MUST distinguish "failed before the server
could have accepted the message" (`:error` — safe to reject the op and
let the human click again) from "the message may have been accepted"
(`:unknown` — enters reconciliation, never retried). Any failure after
`DATA` is issued and the final `.` transmitted is `:unknown`, including
timeouts and TLS teardown errors on the reply read.

`Valea.Mail.SmtpClient` implements it on `gen_smtp_client` (gen_smtp is
already a dependency). gen_smtp's TLS defaults are not acceptable —
`tls_options` are set explicitly: `verify_peer`, CA store, SNI,
`customize_hostname_check` with wildcard support — the same posture as
`ImapClient`. AUTH PLAIN/LOGIN only, only over the established TLS layer.
**All-or-nothing recipients**: every `RCPT TO` (to + cc + bcc) must be
accepted; any rejection aborts with `RSET`/`QUIT` *before* `DATA` and
returns `{:error, {:rejected_recipients, ...}}` with per-recipient
reasons — Valea never delivers to a subset of the reviewed recipient set.
Tests inject a fake per the existing `FakeMailTransport` pattern, with
scripted failure points at every protocol step.

## Send pipeline

A send is a new ledger op kind, `kind: send`, in `mail_pending_ops` —
executed by the existing ops executor, serialized through the account's
Engine, exactly like push. Steps 1–2 are push's own, verbatim:

1. **Atomic claim.** One SQLite transaction inserts the send op under the
   partial-unique index **one non-terminal op per `(account, origin)`**
   (widened in the hand migration to span `append` and `send` together) —
   so a draft cannot be pushed and sent concurrently, or sent twice from
   two tabs. The op records a
   **deterministic, Valea-generated Message-ID** —
   `send_message_id(account, draft_name, content_hash)`, domain-separated
   from `push_message_id` so a pushed copy and a sent message of
   identical content never share a Message-ID. Born `claimed`, before any
   network I/O.
2. **Immutable snapshot.** Same containment as push: validated basename,
   `resolve_real` under the account's `drafts/` root, no-follow open of a
   regular single-link file, read once into a buffer, verify
   `content_hash` against that buffer, `DraftFile.parse_and_validate`
   from it, compose from it. Composition produces **two byte-variants
   from the one buffer**: the *wire* message (no `Bcc` header) and the
   *record* message (with `Bcc` — the user's own Sent record). Both,
   plus the envelope, go into `spool/` with an fsynced manifest; both
   hashes are persisted on the op; only then `claimed → pending`, and the
   draft stamps `sending`. Status stamps use push's compare-and-swap rule
   throughout (a draft edited meanwhile stays untouched as `draft`; the
   panel reports that an earlier revision was sent).
3. **Transmit.** The executor re-verifies the spool wire-payload hash,
   then calls `SmtpTransport.send/5` once. Outcomes:
   - `{:error, _}` (incl. rejected recipients, AUTH failure, connect/TLS
     failure) — provably unsent. Op → `rejected` with the reason
     (per-recipient where applicable), draft reverts to `draft`, error
     surfaced. Retrying is a fresh human click on the reviewed draft.
   - `{:ok, :accepted}` — transmission proven. Op → `transmitted`
     (durable), then the **Sent-copy step**: generic profile APPENDs the
     *record* bytes to `folders.sent` through the existing idempotent
     append machinery (search for the op's Message-ID first, APPEND,
     confirm); gmail profile skips the APPEND (Google auto-files Sent
     Mail — appending would duplicate). On confirmation (or on gmail
     immediately) the op completes, the draft stamps `sent`, audit entry,
     spool cleaned. A Sent-copy failure after proven transmission
     **cannot un-send the mail**: the op completes with a
     `sent_copy_failed` notice and a retry affordance — the retry re-runs
     only the idempotent append, never the transmit.
   - `{:unknown, _}` — **never retried.** Op → `send_review` (durable,
     manifest updated). Gmail profile: reconciliation searches Sent Mail
     (then all known folders) for the op's Message-ID — found →
     transmission proven, continue as accepted. An empty search is a
     strong signal but not proof (Sent Mail visibility after a 250 is not
     guaranteed to be instant), so the search re-runs over a short
     bounded window; still empty → the op stays parked in `send_review`,
     with the panel noting that Gmail's Sent Mail was checked and found
     empty. Generic profile: nothing can prove either way — the op parks
     in `send_review` and the panel explains exactly what happened and
     what to check. Human resolution (below) applies to any parked op on
     either profile.
4. **Human resolution** (generic-profile `send_review` only):
   `resolve_send_review(account, op_id, resolution, generation)` with
   `resolution: sent | not_sent`. `sent` → run the Sent-copy step
   (idempotent), complete, draft stamps `sent`. `not_sent` → op
   `rejected`, draft reverts to `draft` for another explicit click. The
   panel wording tells the user to check their own Sent folder and, if
   in doubt, the recipient — resolving `not_sent` and re-sending after an
   actual delivery re-sends with the **same Message-ID** (deterministic
   construction), which lets recipient clients thread/dedupe the
   duplicate; that is the accepted worst case of a wrong resolution.

**Crash recovery** extends the existing boot reconciliation: a `claimed`
send without its spool payload is provably un-transmitted → `rejected`,
draft reverts. A `pending`/`executing` send whose manifest shows DATA was
never reached is provably unsent → `rejected`. Anything at-or-past DATA
without a recorded outcome recovers as `{:unknown}` → the `send_review`
path above. A `transmitted` op resumes at the Sent-copy step
(idempotent). Manifests carry every transition, so database loss
reconstructs the same states from `spool/`, and affected drafts stay
blocked until proven — nothing retries a transmit, ever.

Threading (`in_reply_to: <msg_id>`) resolves `In-Reply-To`/`References`
from the referenced raw canonical file, as push does; unmirrored
reference → compose without threading headers plus a panel warning.
Compose guards: `sync.max_message_bytes` bounds the composed size;
non-ASCII in any address rejects at validation (no SMTPUTF8 in v1;
subject and body are fine — RFC 2047 / quoted-printable as today).

**Draft status vocabulary** grows to
`draft | pushing | pushed | sending | send_review | sent`.
`DraftFile.@statuses` accepts all six (so an engine-stamped draft stays
re-parseable), and the anti-forgery rule is unchanged: displayed state
derives from the ledger, never from frontmatter — an agent-written
`status: sent` with no corroborating ledger op renders `draft` with a
`status_forged` notice.

**UI.** The drafts panel gains a Send button per draft, rendered only
when the account has SMTP configured and the draft parses valid. Clicking
opens a confirm modal showing the **parsed** recipient set (to/cc/bcc
exactly as they will be transmitted), subject, and the sending identity
(`from_name <from>`, account slug); confirm is one click — no typed
confirmation (the review is the modal; the hash binds it). The RPC
carries `content_hash` like push. `send_review` rows render the
explanation and the two resolution actions; `sent_copy_failed` renders
its retry.

## Draft iteration loop

Agents draft today by writing ask-gated files into
`sources/mail/<slug>/drafts/` — ACP needs nothing new (Valea advertises
no fs capability; the harness writes directly and the ask-gate +
permission tiers govern it). Two additions close the loop:

**Live drafts.** The ICM watcher's fixed `sources` listener currently
classifies all events `:ignore`. It now recognizes
`sources/mail/<slug>/drafts/*.md` (slug-validated against configured
accounts) and emits a debounced `mail_draft_changed` event on the `"mail"`
PubSub topic carrying `account`. The frontend store refetches the drafts
list on that event (the list is global, so one handler suffices), which
also fixes the list-pane count going stale. No other `sources/` paths
change classification; the engine is not involved (drafts are not engine
state until a push/send claims them).

**Request changes.** Each draft row gains a feedback box. Submitting
calls `revise_mail_draft(account, draft_name, feedback, generation)`:

- If a **running** session's `input` locator resolves to this draft file,
  the feedback is enqueued to that session as an ordinary follow-up
  prompt (the drafting context is worth keeping) and its `session_id`
  returns.
- Otherwise a new session starts via the existing create-session
  plumbing: `include_mounts: ["mail-<slug>"]`, the draft as the `input`
  locator (which also issues the exact read grant), and the feedback
  wrapped in a fixed prompt template ("revise the draft at <path> per
  this feedback; edit the file in place; keep the frontmatter valid;
  do not touch status") as the **initial prompt** — this finally exposes
  the Spec D `initial_prompt` plumbing through the RPC layer instead of
  the hardcoded `nil` at both call sites.
- The response carries the `session_id`; the UI shows "sent to session"
  with an open-session link. The agent's subsequent edits ripple back
  through the live-drafts event. Session discovery is a query over
  running `SessionServer`s' locator metadata — no new persistent
  draft↔session table; if nothing is running, a fresh session is simply
  started (correlation is a convenience, not state).

The permission model is untouched: the revise session's draft writes are
ask-gated like any draft write; the feedback prompt grants nothing.

## Multi-account hardening (from the 2026-07-26 audit)

1. **Account-qualified message selection.** The Mail route's selection
   becomes `?account=<slug>&message=<msgId>`; `MessageList` links carry
   both; the selection effect tracks both (no more `untrack` on the
   account) and loads via `getMailMessage(account, msgId)` with that
   explicit account. Switching accounts clears or re-resolves the
   selection; a deep link before status resolves retries once accounts
   arrive instead of latching a permanent load error. This fixes the
   stale read pane on account switch and cross-account msg_id ambiguity.
2. **SQLite under concurrent engines.** The workspace Repo turns on
   `journal_mode: :wal` and an explicit generous `busy_timeout`; each
   Engine's poll timer gets per-account random jitter (a bounded fraction
   of the interval) so N accounts stop ticking in lockstep after
   `{:workspace_opened}`. First passes on two busy accounts must both
   complete in tests.
3. **Per-account drafts count.** The list-pane "Drafts (N)" counts only
   the selected account's drafts (the panel keeps listing all accounts,
   labeled, as today). `selectAccount` clears `folders`/`messages` before
   refetching to kill the stale flash.
4. **Defensive executor guard.** `execute_append`/`execute_send` assert
   the fetched op row's `account` equals the executing Engine's account —
   a one-line invariant check where a mismatch aborts loudly.
5. **Registry invariant made explicit.** The mail Registry stays keyed by
   slug, with a module comment stating the single-workspace invariant it
   depends on (Manager serializes open/close and tears engines down
   synchronously) — or the key grows the workspace id if that ever
   changes. No behavior change.

## RPC surface (additions to `Valea.Api.Mail` / `Valea.Api.Agents`)

All mutating actions take `generation`; account-scoped actions validate
the slug before any path I/O, as everywhere. The RPC channel remains
control-token-gated — agents have no transport to it.

- `send_draft(account, draft_name, content_hash, generation)` — same
  basename validation, containment, and no-follow snapshot rules as
  `push_draft_to_mailbox`; returns the op status.
- `resolve_send_review(account, op_id, resolution, generation)` —
  `resolution: sent | not_sent`; only valid on a `send_review` op of that
  account.
- `retry_sent_copy(account, op_id, generation)` — re-runs only the
  idempotent Sent-copy append of a completed-with-notice send.
- `revise_mail_draft(account, draft_name, feedback, generation)` — the
  Request-changes entry point (routes or creates a session; returns
  `session_id`).
- `setup_mail_account` gains the optional `smtp` block;
  `set_mail_credential` gains a `kind: imap | smtp` argument (secret
  stays `sensitive? true`); `mail_doctor` includes the SMTP checks when
  configured.
- `create_session` exposes the already-plumbed `initial_prompt`
  (used by `revise_mail_draft`; harmless generally — the surface is
  user-only by construction).
- Channel: new `mail_draft_changed` event on the `"mail"` topic, carrying
  `account`.

## Safety invariants (delta over Spec E)

- **Human-only transmission.** Send is reachable only via the
  control-token RPC; agents have no RPC transport (existing, tested
  boundary). The ops vocabulary still cannot express send.
- **What the human reviewed is what gets sent.** The same hash-bound,
  snapshot-once, compose-from-buffer chain as push, extended to the wire
  payload: the transmitted bytes' hash is persisted and re-verified
  immediately before the one `send` call.
- **No automated retransmission, structurally.** The executor calls
  `SmtpTransport.send` at most once per op; every recovery path either
  proves the outcome, rejects (provably unsent), or parks in
  `send_review` for the human. There is no code path that transmits from
  a recovery or reconciliation routine.
- **All-or-nothing recipients.** A partial `RCPT` acceptance never
  reaches `DATA`.
- **From is config-owned.** Frontmatter cannot influence the envelope
  sender or From header.
- **Bcc never leaves the machine on the wire.** The wire variant carries
  no Bcc header (envelope-only); the record variant exists only for the
  user's own Sent folder.
- **IMAP transport stays send-free.** SMTP is a separate behaviour; the
  Spec E structural checks on `Valea.Mail.Transport` keep holding.
- **Push invariants untouched** — the never-expunge policy, engine-owned
  maildir, deny tiers, and identity binding are not modified by this
  spec.

## Change map

- **New:** `Valea.Mail.SmtpTransport` (behaviour), `Valea.Mail.SmtpClient`
  (gen_smtp_client + strict TLS), `send` op kind in the ops executor
  (claim/snapshot shared with push; transmit + Sent-copy + review
  states), `send_message_id/3` in `DraftMime`, wire/record dual compose,
  `revise_mail_draft` + session-locator discovery, watcher drafts
  classification + `mail_draft_changed`, `resolve_send_review` /
  `retry_sent_copy` / `send_draft` RPCs, SMTP doctor checks, SMTP
  keychain entries + setup UI, Send button + confirm modal +
  `send_review` UI.
- **Extended:** `Settings` (v5: optional `smtp`, `safety.outbound`
  normalization), `DraftFile.@statuses` (+`sending`/`send_review`/
  `sent`), `mail_pending_ops` hand migration (`kind` admits `send`,
  columns for wire/record hashes + envelope), manifests (send
  transitions), `Engine` (send serialization, SMTP credential closure),
  boot recovery (send states), `create_session` (`initial_prompt`
  exposed), mail store/panel (drafts events, send flows), Mail route
  (account-qualified selection), Repo config (WAL/busy_timeout), Engine
  poll (jitter).
- **Rewritten:** ARCHITECTURE.md/VISION.md outbound sections ("no SMTP" →
  human-only transmission invariant); the `THERE IS NO SMTP` code
  comments become pointers to the new invariant.
- **Unchanged:** IMAP `Transport` behaviour, sync engine, ops-file
  vocabulary, permission tiers, push flow semantics.

## Error handling

Per-account isolation holds: SMTP failures never pause IMAP sync.
Provably-unsent failures reject the op with a surfaced, copyable reason
and revert the draft; unknown outcomes park in `send_review` (gmail:
auto-resolved by the Message-ID search) with explicit user guidance;
Sent-copy failures after proven transmit complete-with-notice and offer
an idempotent retry; hash mismatches (draft or spool) reject with a
re-review error; config errors (`security`/port mismatch, invalid
`from`) mark the account's SMTP invalid — push-only until fixed — never
a crash. Revise-flow failures (draft missing, session spawn failure)
surface in the panel; nothing in the mail stack raises across the RPC
boundary.

## Testing & acceptance

- **Fake SMTP transport** with scripted failure points at every step:
  connect/TLS/EHLO/AUTH failure; one-of-N `RCPT` rejected (abort before
  DATA, per-recipient errors, nothing delivered); disconnect mid-DATA
  (`:unknown`); lost final response (`:unknown`); clean accept.
- **Scenario suite:** double-click single-send (unique claim, second
  caller sees the op); push-vs-send mutual exclusion on one draft;
  draft-edited-mid-send CAS (new revision untouched, panel reports the
  sent revision); `send_review` → `sent` resolution (idempotent Sent
  copy, complete); `send_review` → `not_sent` (draft reverts, fresh
  click re-sends with the same Message-ID); gmail lost-response
  auto-reconcile (found → completes; empty across the bounded re-check
  window → stays parked with the checked-and-empty notice, never
  auto-rejected); generic lost-response stays parked, nothing retries;
  Sent-copy failure after accept → complete-with-notice, retry runs only
  the append; crash at every ledger state (claimed-no-spool → rejected;
  pre-DATA → rejected; post-DATA unknown → `send_review`; transmitted →
  Sent-copy resumes; database loss → manifests reconstruct, drafts
  blocked until proven); Bcc golden tests (wire variant has no Bcc
  header, envelope includes bcc rcpts, record variant keeps Bcc);
  non-ASCII address rejects; From/from_name from config only (frontmatter
  cannot override); oversized compose rejects; agent cannot reach
  `send_draft`/`resolve_send_review` (RPC-isolation test extended);
  forged `status: sent` renders `draft` + notice.
- **Iteration loop:** watcher event on agent draft write → store refetch
  (debounced, slug-validated, non-draft `sources/` paths still ignored);
  `revise_mail_draft` routes to a running session with a matching input
  locator, else creates one with the mount + locator + seeded prompt;
  permission tier unchanged (revise session's draft write still asks).
- **Multi-account:** two accounts, switch with a message open → read pane
  clears/re-resolves (no stale render); colliding msg_id across accounts
  deep-links to the right one; deep link before status resolves →
  retries, no latched error; two engines' jittered first passes both
  complete under WAL; per-account drafts count; executor account-guard
  aborts on mismatch.
- **Live acceptance** (mandatory before trusting send): the
  scripts/dovecot harness gains a companion local submission server so
  the real `SmtpClient` wiring (TLS, AUTH, tri-state outcomes) runs
  against a real socket, **plus one real Gmail send and one real
  generic-provider send** with a manual checklist doc
  (docs/superpowers/acceptance/), covering: normal send, rejected
  recipient, lost-response drill (kill the connection post-DATA) on both
  profiles, Sent-copy verification, and same-Message-ID re-send after a
  wrong `not_sent` resolution.
- **Frontend:** vitest for send confirm modal (parsed recipients), status
  rendering incl. `send_review`/`sent_copy_failed`, drafts-event
  handling, account-qualified selection; svelte-check + codegen
  freshness (`just test`).

## Residual risks & accepted trade-offs

- **Generic-provider ambiguity is irreducible** — that fact from Spec E
  has not changed. What changed is who resolves it: the human who just
  clicked, guided by the panel, instead of an automated retry policy.
  The worst case of a wrong `not_sent` resolution is a duplicate
  delivery sharing one Message-ID (recipient-side threading absorbs it);
  the worst case of a wrong `sent` resolution is an unsent mail the user
  believes sent — mitigated by telling them exactly what to check before
  resolving.
- **Deterministic Message-IDs leak a hash of (account, draft name,
  content hash) shape** — opaque and collision-resistant; accepted for
  the idempotency and cross-attempt discoverability it buys.
- **SMTP AUTH with app passwords only** — OAuth stays a non-goal; Gmail
  requires an app password, as for IMAP today.
- **The revise flow's session discovery is best-effort** — locator match
  on running sessions only; a closed session means a fresh one. No
  persistent draft↔session state to corrupt.

## Non-goals

- OAuth/XOAUTH2, provider send APIs (Gmail API/JMAP).
- HTML composition, attachments on outbound drafts, rich compose UI.
- Scheduling, undo-send, send queues, batch send, automated retry of any
  transmission.
- SMTPUTF8 / non-ASCII addresses; DSN/read receipts; REQUIRETLS.
- **Agent-triggered send — permanent invariant, not a deferral.**
- Per-recipient partial delivery.

## Execution notes (for the plan)

Sequence so each stage lands green and independently useful:
multi-account hardening (pure fixes, no new surface) → settings v5 +
SMTP credentials + doctor → SmtpTransport/SmtpClient + fake → send op
kind in the executor (claim/snapshot/transmit/recovery) + RPCs →
Send UI + send_review flows → live-drafts watcher event + store →
revise_mail_draft + initial_prompt exposure + UI → docs rewrite
(ARCHITECTURE/VISION invariant language) + acceptance checklist. Every
SDD dispatch forbids sub-agent spawning; commit trailer and no-push rules
as standing.
