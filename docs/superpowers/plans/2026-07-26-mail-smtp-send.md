# Mail SMTP Send + Draft Iteration + Multi-Account Hardening (Spec G) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Human-only, hash-bound SMTP send beside Push-to-Drafts (a `send` op kind on the existing mail ledger, tri-state transport, structurally no retransmission), a live agent draft-iteration loop (watcher events + Request-changes session routing), and the 2026-07-26 multi-account audit fixes.

**Architecture:** Send reuses push's machinery verbatim — atomic claim on the widened `(account, origin)` partial-unique index, snapshot-once/compose-from-buffer inside one Engine call under one captured `state.settings`, spool + manifest before network I/O — then transmits exactly once through a new hand-written `SmtpClient` implementing the tri-state `SmtpTransport` behaviour (received-final-non-2xx = provably unsent; `:unknown` only for a missing/undecodable final reply, parked in `send_review`, never retried). Draft iteration is file-based (ACP needs nothing): the watcher stops ignoring `sources/mail/<slug>/drafts/`, and `revise_mail_draft` routes feedback to a running session by input locator or seeds a new one through the finally-exposed `initial_prompt`.

**Tech Stack:** Elixir 1.20 / Phoenix 1.8 / Ash 3 + AshSqlite (hand-migrated, `migrate? false`), `:ssl`/`:gen_tcp` (hand-written SMTP wire client — NOT gen_smtp_client, see spec §SMTP transport & client), gen_smtp's `:mimemail` for MIME only, ash_typescript codegen, SvelteKit + Svelte 5 runes + vitest.

**Spec:** `docs/superpowers/specs/2026-07-26-mail-smtp-send-design.md` (approved, 4 Codex rounds, READY). Where this plan and the spec disagree, the spec governs — flag it, don't improvise.

## Global Constraints

- **Human-only transmission**: `send_draft` / `resolve_send_review` / `retry_sent_copy` / `revise_mail_draft` are control-token RPC actions only. No agent-facing tool or file convention maps to send. The ops-file vocabulary is untouched.
- **No automated retransmission, structurally**: `SmtpTransport.send/5` is called at most once per op; no recovery, reconciliation, or retry path may reach the SMTP transport. The IMAP-connected recovery path may only reconcile (search) or resume the idempotent Sent-copy append.
- **Settings pinning**: review-fingerprint check, claim, snapshot, and wire/record composition run synchronously in ONE Engine call against ONE captured `state.settings`. Never re-read settings outside the Engine for a send.
- **TLS mandatory + verified** for SMTP exactly as IMAP: `verify_peer`, CA store, SNI, hostname check; trust-root override via `connect_opts`/opts for tests only. No plaintext mode; AUTH only over the established TLS layer.
- **IMAP `Valea.Mail.Transport` stays send-free** — SMTP lives only in `Valea.Mail.SmtpTransport`/`SmtpClient`.
- **Keychain**: SMTP secret is a separate entry, FE key `"<slug>:smtp"` via the existing `mail_secret_set/get/delete` Tauri commands (no Rust changes). BE env fallback `VALEA_MAIL_SMTP_PASSWORD_<SLUG upcased, "-"→"_">`. Credentials stay RAM-only closures.
- **Draft statuses** grow to exactly `draft | pushing | pushed | sending | send_review | sent`; displayed state derives from the ledger (kind-aware ordered projection), never frontmatter.
- **Falsy-field rule**: any RPC typed-map field that can be `false`/`0` at top level uses a STRING key (ash_typescript 0.17.3 bug — see `Valea.Api.Mail` moduledoc L22-26).
- Commit trailer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`. Never push to origin.
- Suite gate: `just test` (backend → codegen freshness → `bun run check` → `bun run test`). Any task touching an `Api.*` rpc_action MUST run `cd backend && mix ash_typescript.codegen` and commit the regenerated `frontend/src/lib/api/` in the same commit.
- Backend mail tests follow `backend/test/valea/mail/ops_executor_test.exs` conventions: `async: false`, tmp dir + `start_supervised!({Valea.Repo, database: Path.join(dir, "app.sqlite"), pool_size: 1})` + `Ecto.Migrator.run(..., :up, all: true)`; transports injected via ctx (executor) or `Application.put_env(:valea, :mail_transport, ...)` (engine). Session tests use `Valea.AgentCase` (`open_workspace!/1`, `mount_test_icm!/2`, `fake_cmd/2`).

## File Structure (end state)

```
backend/lib/valea/mail/
  smtp_transport.ex     # NEW  behaviour: send/5 (tri-state) + check_auth/3 (doctor)
  smtp_client.ex        # NEW  hand-written :ssl/:gen_tcp+STARTTLS wire client
  settings.ex           # EXTEND  v5: optional smtp block, smtp_fingerprint/1, smtp env credential
  draft_file.ex         # EXTEND  6 statuses, canonical_send_bytes/1, valid_addr_spec?/1
  draft_mime.ex         # EXTEND  send_message_id/3, compose_send/5 (wire+record dual)
  ops_executor.ex       # EXTEND  send pipeline (prepare/execute/classify/reconcile/resolve),
                        #         recovery + orphan sweep admit kind "send"
  engine.ex             # EXTEND  send_draft serialization, smtp credential, jitter, activation classify
  store.ex + store/pending_op.ex  # EXTEND  send states/columns, ordered ops_by_origin
  doctor.ex             # EXTEND  smtp_tcp / smtp_tls / smtp_auth (on demand only)
backend/lib/valea/api/mail.ex      # EXTEND  review/send/resolve/retry/revise RPCs, projection
backend/lib/valea/api/agents.ex    # EXTEND  create_session initial_prompt argument
backend/lib/valea/agents/session_server.ex  # EXTEND  Registry value carries input locator
backend/lib/valea/agents.ex        # EXTEND  list_running_session_inputs/0
backend/lib/valea/icm/watcher.ex   # EXTEND  mail-drafts classification + per-account debounce
backend/lib/valea_web/channels/workspace_events_channel.ex  # EXTEND  mail_draft push
backend/lib/valea/workspace/manager.ex      # MODIFY  Repo WAL/busy_timeout + verification
backend/priv/repo/migrations/20260726000001_mail_send_ops.exs  # NEW hand migration
backend/priv/workspace_template/config/mail.yaml  # MODIFY  v5 skeleton
backend/test/support/fake_smtp_transport.ex  # NEW  scripted behaviour double
backend/test/support/fake_smtp_server.ex     # NEW  real-socket scriptable SMTP server
frontend/src/lib/api/client.ts               # EXTEND  new wrappers
frontend/src/lib/stores/mail.svelte.ts       # EXTEND  send flows, mail_draft handler, per-account counts
frontend/src/lib/components/mail/DraftsPanel.svelte   # EXTEND  Send, send_review, feedback box
frontend/src/lib/components/mail/SendConfirmModal.svelte  # NEW
frontend/src/lib/components/mail/SetupPanel.svelte    # EXTEND  SMTP section
frontend/src/lib/components/mail/mail-shapes.ts       # EXTEND  smtp setup, messageHref, send shapes
frontend/src/routes/mail/+page.svelte        # MODIFY  account-qualified selection
frontend/src/lib/socket.ts                   # EXTEND  MailDraftPush
docs/ARCHITECTURE.md, docs/VISION.md         # MODIFY  outbound invariant rewrite
docs/superpowers/acceptance/2026-07-26-mail-smtp-send.md  # NEW checklist
```

**Grep gates (final task):** `THERE IS NO SMTP` → 0 hits outside `docs/superpowers/specs|plans`; `outbound: push_drafts_only` → 0 hits outside specs/plans; `gen_smtp_client` → 0 hits in `lib/`.

---

### Task 1: Multi-account hardening (pure fixes, no new surface)

**Files:**
- Modify: `backend/lib/valea/workspace/manager.ex` (`start_repo/1`, ~L309)
- Modify: `backend/lib/valea/mail/engine.ex` (`schedule_poll/1` ~L1027, `via/1` comment ~L153)
- Modify: `backend/lib/valea/mail/ops_executor.ex` (`execute_append/2` ~L650)
- Modify: `frontend/src/routes/mail/+page.svelte`, `frontend/src/lib/components/mail/MessageList.svelte`, `frontend/src/lib/components/mail/AccountSwitcher.svelte`, `frontend/src/lib/stores/mail.svelte.ts` (`selectAccount`), `frontend/src/lib/components/mail/mail-shapes.ts`
- Test: `backend/test/valea/workspace/manager_repo_test.exs` (new), `backend/test/valea/mail/engine_test.exs` (extend), `backend/test/valea/mail/ops_executor_test.exs` (extend), `frontend/src/lib/stores/mail.test.ts`, `frontend/src/lib/components/mail/mail-components.test.ts`

**Interfaces (Produces):**
```elixir
# Engine — public pure helper (jitter is testable without timers):
Valea.Mail.Engine.poll_delay_ms(interval_minutes :: pos_integer()) :: pos_integer()
  # interval_ms + jitter; jitter = Application.get_env(:valea, :mail_poll_jitter, :random)
  # :random → :rand.uniform(bound + 1) - 1 where bound = min(60_000, div(interval_ms, 4))
  # integer n → exactly n (test seam). schedule_poll/1 uses this instead of interval*60_000.
```
```ts
// mail-shapes.ts:
export function messageHref(account: string, msgId: string): string
  // `/mail?account=${encodeURIComponent(account)}&message=${encodeURIComponent(msgId)}`
```

- [ ] **Step 1 (backend, failing tests):**
  - `manager_repo_test.exs`: start `{Valea.Repo, database: <tmp>/app.sqlite, pool_size: 1, journal_mode: :wal, busy_timeout: 5000}` via `start_supervised!`, then `assert %{rows: [["wal"]]} = Valea.Repo.query!("PRAGMA journal_mode")` and `assert %{rows: [[5000]]} = Valea.Repo.query!("PRAGMA busy_timeout")`.
  - `engine_test.exs`: `Application.put_env(:valea, :mail_poll_jitter, 0)` (+ `on_exit` delete) → `assert Engine.poll_delay_ms(15) == 15 * 60_000`; `put_env(..., 1234)` → `== 15 * 60_000 + 1234`; with `:random` (env deleted) assert `delay in (15*60_000)..(15*60_000 + 60_000)` over 50 samples and at least two distinct values.
  - `ops_executor_test.exs`: create an append op under account `"mara"`, build a ctx with `account: "other"`, `assert_raise ArgumentError, fn -> OpsExecutor.execute_append(ctx_other, op.id) end`.
- [ ] **Step 2: Run** `cd backend && mix test test/valea/workspace/manager_repo_test.exs test/valea/mail/engine_test.exs test/valea/mail/ops_executor_test.exs` → new cases FAIL.
- [ ] **Step 3: Implement backend.**
  - `start_repo/1`: spec becomes `{Valea.Repo, database: ..., pool_size: 5, journal_mode: :wal, busy_timeout: 5000}`. After `{:ok, pid}`, verify: `case Valea.Repo.query("PRAGMA journal_mode") do {:ok, %{rows: [["wal"]]}} -> :ok; other -> Logger.warning("sqlite WAL unavailable, continuing in rollback mode: #{inspect(other)}") end` — degrade is a log line, never a crash (spec §Multi-account hardening 2).
  - `poll_delay_ms/1` public as contracted; `schedule_poll/1` calls `Process.send_after(self(), :poll, poll_delay_ms(interval_minutes(state)))`. Applies to every schedule (activation included) — that IS the stagger.
  - `execute_append/2` (and keep the pattern for Task 4's `execute_send/2`): after `op_by_id`, `if op_row.account != ctx.account, do: raise ArgumentError, "op #{op_row.id} belongs to account #{op_row.account}, engine ctx is #{ctx.account}"`.
  - `via/1` module comment: Registry is keyed by slug only; safe because `Manager.open/close` serializes workspaces and `do_close` tears down engines synchronously before a new open — key must grow the workspace id if that invariant ever changes.
- [ ] **Step 4: Run to green** (same command).
- [ ] **Step 5 (frontend, failing tests):**
  - `mail-components.test.ts`: `messageHref('personal', 'a b') === '/mail?account=personal&message=a%20b'`.
  - `mail.test.ts`: after `selectAccount('b')`, `folders`/`messages` are `[]` synchronously (before the fake API resolves — use a never-resolving fake and assert immediately); drafts-count helper: with drafts across accounts, count for selected account only.
- [ ] **Step 6: Implement frontend.**
  - `mail-shapes.ts`: add `messageHref` as contracted. `MessageList.svelte` gains `account: string` prop; link `href={messageHref(account, message.msgId)}`; `+page.svelte` passes `account={mailStore.selectedAccount ?? ''}`.
  - `mail.svelte.ts` `selectAccount`: set `this.folders = []; this.messages = [];` before the `Promise.all` refetch.
  - `+page.svelte`: `const selectedAccountParam = $derived(page.url.searchParams.get('account'));` and REPLACE the selection `$effect` (`:74-105`) with an account-aware one — `mailStore.selectedAccount` and `mailStore.accounts` are now TRACKED (fixes the untrack latch + deep-link race):

```ts
$effect(() => {
  const id = selectedId;
  const accParam = selectedAccountParam;
  const storeAccount = mailStore.selectedAccount;
  const accountsReady = mailStore.accounts.length > 0;
  activeId = null; activeDetail = null; loadError = false;
  if (!id) return;
  const target = accParam ?? storeAccount;
  if (!target) {
    if (accountsReady) loadError = true; // accounts loaded, none selectable
    return; // otherwise wait — effect re-runs when accounts arrive
  }
  let cancelled = false;
  void (async () => {
    if (target !== untrack(() => mailStore.selectedAccount)) {
      await mailStore.selectAccount(target);
      if (cancelled) return;
    }
    const before = untrack(() => mailStore.selected);
    await mailStore.select(id);
    if (cancelled) return;
    const selected = untrack(() => mailStore.selected);
    if (selected !== before) { activeId = id; activeDetail = selected; }
    else { loadError = true; }
  })();
  return () => { cancelled = true; };
});
```

  - `AccountSwitcher.svelte` `onchange`: `mailStore.selectAccount(value); if (page.url.searchParams.has('message')) void goto('/mail');` — switching clears a stale selection.
  - Drafts count (`+page.svelte:174-176`): `mailStore.drafts.filter((d) => d.account === mailStore.selectedAccount).length`.
- [ ] **Step 7: Run** `cd frontend && bun run check && bun run test` → green.
- [ ] **Step 8: Commit** `fix(mail): multi-account hardening — WAL+jitter, account-qualified selection, executor guard`.

---

### Task 2: Settings v5 — smtp block, fingerprint, credentials

**Files:**
- Modify: `backend/lib/valea/mail/settings.ex`, `backend/lib/valea/mail/engine.ex` (credential plumbing), `backend/lib/valea/api/mail.ex` (`setup_mail_account` + `set_mail_credential`), `backend/priv/workspace_template/config/mail.yaml`
- Test: `backend/test/valea/mail/settings_test.exs`, `backend/test/valea/mail/engine_test.exs`, `backend/test/valea_web/` mail RPC test

**Interfaces (Produces):**
```elixir
# Settings struct gains: smtp: nil | %{host: String.t(), port: pos_integer(),
#   security: :starttls | :tls, username: String.t(),
#   from: String.t(),        # defaulted to username at load; always populated when smtp present
#   from_name: String.t() | nil}
smtp_configured?(t()) :: boolean()
smtp_fingerprint(t()) :: String.t() | nil
  # nil when no smtp; else sha256 hex of the canonical string
  # "smtp\n#{from}\n#{from_name || ""}\n#{host}\n#{port}\n#{security}\n#{username}\n"
  # NOTE: threading joins this hash at review time (Task 4's review_fingerprint/2) — this
  # function is the settings component only.
smtp_env_credential(slug) :: String.t() | nil     # VALEA_MAIL_SMTP_PASSWORD_<SLUG>
upsert_account!/3 attrs gains optional :smtp => %{host:, port:, security: nil | "starttls" | "tls",
  username:, from: nil, from_name: nil} | nil     # nil smtp = push-only account
# render/1 emits: version: 5 … safety:\n  never_expunge: true\n  outbound: human_send_and_push
# load/1 accepts version 4 AND 5; v4 accounts load with smtp: nil.
# Validation at load (per-account invalid, others load): security defaults 587→:starttls,
# 465→:tls; other ports REQUIRE explicit security; explicit security contradicting the
# 587/465 convention → invalid; from must satisfy DraftFile.valid_addr_spec?/1 (Task 3 adds
# it — THIS task uses a local copy of @addr_re; Task 3 swaps to the shared fn); CR/LF/NUL in
# from_name → invalid.

# Engine:
Engine.set_credential(slug, secret, kind :: :imap | :smtp)   # 2-arity kept = :imap
# state gains :smtp_credential; do_activate seeds it from Settings.smtp_env_credential/1;
# build_status/1 gains "smtp_configured" => boolean, "smtp_credential" => "present"|"missing"|"n/a"
```

- [ ] **Step 1: Write failing tests** (`settings_test.exs` additions, one test per bullet):
  - v4 file loads: existing fixtures unchanged → accounts get `smtp == nil`, `smtp_configured?/1 == false`.
  - upsert with `smtp: %{host: "mail.example.com", port: 587, username: "d@w.d"}` → load: `security: :starttls`, `from: "d@w.d"`; render contains `version: 5` and `outbound: human_send_and_push`; re-load round-trips.
  - port 465 defaults `:tls`; port 2525 without security → account invalid; `port: 587, security: "tls"` → invalid; `from: "not an addr"` → invalid; `from_name: "a\nb"` → invalid.
  - `smtp_fingerprint/1`: nil without smtp; deterministic; changes when `from_name` changes; unchanged when only `sync.window_days` changes.
  - `smtp_env_credential("my-acct")` reads `VALEA_MAIL_SMTP_PASSWORD_MY_ACCT`.
  - `engine_test.exs`: `set_credential(slug, "s3", :smtp)` then status shows `"smtp_credential" => "present"`; `:imap` 2-arity path unchanged.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement** (settings parse/validate/render + engine plumbing + template `version: 5` / `outbound: human_send_and_push` — keep `accounts: {}`). RPC changes: `setup_mail_account` gains optional args `smtp_host :string nil, smtp_port :integer[min:1] nil, smtp_security :string nil, smtp_username :string nil, smtp_from :string nil, smtp_from_name :string nil` (flat args — the existing action style is flat, not nested maps; all-nil = no smtp block); `set_mail_credential` gains `kind :string nil` (`"imap"` default, `"smtp"` routes to the new closure).
- [ ] **Step 4: Run to green**, run `mix ash_typescript.codegen`, commit regenerated FE api. **Step 5: Commit** `feat(mail): settings v5 — smtp block, fingerprint, separate smtp credential`.

---

### Task 3: `SmtpTransport` + hand-written `SmtpClient` + fakes + compose + doctor

**Files:**
- Create: `backend/lib/valea/mail/smtp_transport.ex`, `backend/lib/valea/mail/smtp_client.ex`
- Create: `backend/test/support/fake_smtp_transport.ex`, `backend/test/support/fake_smtp_server.ex`
- Modify: `backend/lib/valea/mail/draft_file.ex`, `backend/lib/valea/mail/draft_mime.ex`, `backend/lib/valea/mail/doctor.ex`, `backend/lib/valea/mail/engine.ex` (`doctor_ctx` gains smtp pieces)
- Test: `backend/test/valea/mail/smtp_client_test.exs`, `backend/test/valea/mail/draft_file_test.exs`, `backend/test/valea/mail/draft_mime_test.exs`, `backend/test/valea/mail/doctor_test.exs`

**Interfaces (Produces):**
```elixir
defmodule Valea.Mail.SmtpTransport do
  @type smtp_config :: %{host: String.t(), port: pos_integer(), security: :starttls | :tls,
                         username: String.t()}
  @type envelope :: %{from: String.t(), rcpt: [String.t()]}   # bare addr-specs, to++cc++bcc

  @callback send(smtp_config, credential :: String.t(), envelope, data :: binary(),
                 opts :: keyword()) ::
              {:ok, :accepted}
              | {:error, {:rejected_recipients, [{String.t(), String.t()}]}}
              | {:error, term()}       # provably unsent (incl. received final non-2xx after dot)
              | {:unknown, term()}     # bytes may have reached the server; final reply lost/garbled
  @callback check_auth(smtp_config, credential :: String.t(), opts :: keyword()) ::
              :ok | {:error, term()}
  # EHLO → STARTTLS → TLS upgrade → SECOND EHLO → AUTH → QUIT; NEVER issues MAIL FROM.
  # RFC 3207: pre-TLS EHLO extensions MUST be discarded — AUTH mechanisms are selected
  # only from the post-TLS EHLO response (send/5 follows the same rule on the 587 path).
end
# Tri-state boundary (spec, verbatim contract): a received, parseable final reply always
# decides — 250 → accepted; received final non-2xx after the terminating dot →
# {:error, {:refused, code, text}}. The 354 is the line: everything BEFORE the 354 is
# {:error, _}; everything AFTER the 354 is received — including a socket/write failure
# mid-body or mid-terminator, a timeout, or TLS teardown — is {:unknown, _} unless a
# parseable final reply arrived. (A partially-written payload's dot may still have been
# flushed by TCP; "handed to the socket" is NOT a precondition for :unknown — treating a
# mid-write error as provably-unsent would let a human re-click duplicate a delivered
# message.) Any rejected RCPT aborts with RSET+QUIT BEFORE DATA →
# {:error, {:rejected_recipients, [{addr, reason}]}} (all-or-nothing).

# DraftFile:
@statuses ~w(draft pushing pushed sending send_review sent)   # stamp_status/2 guard widened too
canonical_send_bytes(bytes :: binary()) :: binary()
  # bytes with the engine-owned status line removed from the frontmatter block — the SAME
  # regex stamp_status/2 owns (~r/^status:.*$/m, first match inside the block, including its
  # newline). Frontmatter-less input returns bytes unchanged. MUST round-trip:
  # canonical_send_bytes(stamp_status(b, s)) == canonical_send_bytes(b) for every s.
valid_addr_spec?(String.t()) :: boolean()   # exposes @addr_re; Settings swaps its local copy to this

# DraftMime:
send_message_id(account, draft_name, canonical_hash) :: String.t()
  # sha256 of "send/#{account}/#{draft_name}/#{canonical_hash}" first 16 hex →
  # "<valea.send.#{digest}@valea.invalid>"  (domain-separated from push_message_id/3)
compose_send(validated :: DraftFile.validated(), threading, message_id, from :: String.t(),
             from_name :: String.t() | nil) ::
  {:ok, %{wire: binary(), record: binary(), envelope: SmtpTransport.envelope()}}
  # ONE header list built once (Date computed once); record = :mimemail.encode with the Bcc
  # header (when bcc non-empty); wire = same list WITHOUT the Bcc header; envelope.rcpt =
  # bare emails of to++cc++bcc (deduped, order-preserving); envelope.from = from.
  # From header: from_name RFC 2047-encoded via the existing from_address path when present.
```

- [ ] **Step 1: `FakeSmtpServer`** (test support, mirrors `FakeImapServer`'s role): a `:gen_tcp` listener on an ephemeral port driven by a script of steps, e.g. `[{:greet, "220 ok"}, {:expect, "EHLO", "250-x\r\n250 STARTTLS"}, :starttls, {:expect, "AUTH PLAIN", "235 ok"}, {:expect, "MAIL FROM", "250 ok"}, {:expect_rcpt, %{"a@x.co" => "250 ok", "b@x.co" => "550 no"}}, {:expect, "DATA", "354 go"}, {:data_reply, "250 queued"} | :drop_after_data | {:data_reply, "550 rejected"}]`. TLS via the existing test cert fixtures used by `FakeImapServer` (same `connect_opts` trust-root override).
- [ ] **Step 2: Write failing `smtp_client_test.exs`** against `FakeSmtpServer` — one test per outcome: 465 implicit-TLS happy path → `{:ok, :accepted}`; 587 STARTTLS ordering asserted (no AUTH before TLS, AND a **second EHLO after the TLS upgrade** — the fake server rejects `AUTH` unless it observed the post-TLS EHLO, and advertises AUTH only there); AUTH failure → `{:error, {:auth_failed, _}}`; one RCPT rejected → `{:error, {:rejected_recipients, [{"b@x.co", "550 no"}]}}` AND the server never saw `DATA` (script assertion) AND saw `RSET`; final `250` after dot → accepted; final `550` after dot → `{:error, {:refused, 550, _}}`; connection dropped after dot with no reply → `{:unknown, :closed}`; **connection closed mid-body write** → `{:unknown, _}`; **connection closed during the terminator write** → `{:unknown, _}`; reply garbage (`"banana"`) after dot → `{:unknown, {:unparseable, _}}`; drop before `354` → `{:error, _}`; dot-stuffing golden (body line starting `.` arrives as `..`).
- [ ] **Step 3: Run** → FAIL. **Step 4: Implement `SmtpClient`.** TLS opts copied from `ImapClient`'s ssl-option construction (verify_peer, `:public_key.cacerts_get()`, SNI, hostname check; test trust-root override via `opts[:tls_opts]` merged over defaults — the exact `merge_tls_opts` convention at `imap_client.ex:76-77`/`:299-313`, NOT a bespoke `:cacerts` key). Reply parser handles multiline (`250-`/`250 `). AUTH PLAIN (`Base.encode64(<<0, user::binary, 0, pass::binary>>)`), LOGIN fallback when PLAIN unadvertised. `check_auth/3` = same conversation stopped after AUTH + `QUIT`. Redact credentials from every error term (`Valea.Mail.Redact` conventions).
- [ ] **Step 5: `FakeSmtpTransport`** (Agent-scripted behaviour double, per `FakeMailTransport` pattern): `script/2` with per-call results, `calls/1` assertions; used by Tasks 4/5 executor+engine tests.
- [ ] **Step 6: Write failing `draft_file_test.exs` / `draft_mime_test.exs` additions:** all six statuses parse; `stamp_status` accepts `"sending"`/`"send_review"`/`"sent"`; a `from:` frontmatter field rejects as an unknown key (From is config-owned — assert the existing unknown-field rule covers it explicitly); `canonical_send_bytes` round-trip property (with and without an initial `status:` line; frontmatter-less passthrough); `valid_addr_spec?` accepts `a@b.co`, rejects `päivi@b.co` (non-ASCII) and `a b@c.d`; `send_message_id` ≠ `push_message_id` for identical inputs; stable across `stamp_status`; `compose_send` goldens: wire has NO `Bcc:` header while record has it (bcc non-empty), both share identical `Message-ID:` and `Date:` lines, envelope.rcpt includes bcc, empty-bcc → neither variant has a Bcc header and `wire == record`.
- [ ] **Step 7: Run** → FAIL. **Step 8: Implement.** **Step 9: Doctor** — extend `run/1` (after the existing 8 checks, only when `ctx.settings.smtp` present): `smtp_tcp` (`:gen_tcp.connect` to smtp host/port, 5s), `smtp_tls` + `smtp_auth` from ONE `ctx.smtp_transport.check_auth/3` call (mirror `transport_group/2`'s shape; gate on `smtp_tcp`; missing smtp credential → `smtp_auth` failed with the resupply remedy). `Engine` `:doctor_ctx` reply gains `smtp_transport: Application.get_env(:valea, :mail_smtp_transport, Valea.Mail.SmtpClient)` + `smtp_credential`. `doctor_test.exs`: no smtp → exactly the original 8 checks; smtp + scripted `check_auth` ok → 11 checks all ok; auth failure → remedy string present. **Step 10: green, commit** `feat(mail): tri-state SMTP transport — hand-written client, fakes, dual compose, doctor`.

---

### Task 4: The `send` op kind — ledger, executor, engine, recovery, RPCs

**Files:**
- Create: `backend/priv/repo/migrations/20260726000001_mail_send_ops.exs`
- Modify: `backend/lib/valea/mail/store/pending_op.ex`, `backend/lib/valea/mail/store.ex`, `backend/lib/valea/mail/ops_executor.ex`, `backend/lib/valea/mail/engine.ex`, `backend/lib/valea/api/mail.ex`
- Test: `backend/test/valea/mail/store_test.exs`, `backend/test/valea/mail/ops_executor_send_test.exs` (new), `backend/test/valea/mail/engine_test.exs`, RPC test

**Migration (verbatim contract):**
```elixir
def up do
  alter table(:mail_pending_ops) do
    add :content_hash, :string      # raw reviewed-bytes hash (projection rule input)
    add :wire_sha256, :string
    add :record_sha256, :string
    add :envelope_rcpt, :string     # JSON array of bare addrs
  end
  drop_if_exists index(:mail_pending_ops, [:account, :origin], name: :mail_pending_ops_active_append)
  create index(:mail_pending_ops, [:account, :origin],
           unique: true,
           where: "kind IN ('append','send') AND state NOT IN ('rejected','complete')",
           name: :mail_pending_ops_active_outbound)
end
```

**Interfaces (Produces):**
```elixir
# Store: pending_op.ex accepts the 4 new attrs (create + :transition accept lists);
pending_ops(account)   # state filter WIDENED to
  # ["claimed","pending","executing","needs_review","transmitted","send_review"]
ops_by_origin(account, origin)   # now sorted inserted_at DESC (newest first)

# Executor — send pipeline (ctx = %{root, account, settings, transport, smtp_transport,
#   conn: nil | imap_conn, smtp_credential}):
prepare_send(local_ctx, draft_name, content_hash, review_fingerprint) ::
  {:ok, op_row} | {:duplicate, display} | {:error, String.t()}
  # ORDER (all inside the Engine call, one captured settings — Global Constraints).
  # The fingerprint's threading component requires the parsed snapshot, so the check sits
  # after the side-effect-free read but BEFORE anything durable (claim/spool/composition) —
  # spec §RPC surface wording matches:
  # 1. validate name → resolve path → read_draft_nofollow → content_hash verify →
  #    parse_and_validate → corroborate_status (reuse push's fns) →
  #    composed-size guard: byte_size(bytes) > settings.sync.max_message_bytes →
  #    {:error, "draft_too_large"}.
  # 2. threading = resolve_threading(local_ctx, validated.in_reply_to)  (push's resolver).
  # 3. review_fingerprint(local_ctx.settings, threading) recomputed; mismatch →
  #    {:error, "re_review_required"} — no op row, no spool, nothing composed.
  # 4. canonical_hash = sha256(DraftFile.canonical_send_bytes(bytes));
  #    message_id = DraftMime.send_message_id(account, name, canonical_hash);
  #    Store.create_pending_op(%{kind: "send", account, origin: "drafts/"<>name, message_id,
  #    msg_id: name, target_folder: settings.folders.sent, content_hash, state: "claimed"})
  #    — :duplicate_active → {:duplicate, existing_display(...)} (covers push+send mutex).
  # 5. compose_send → write spool "<id>.wire.eml" + "<id>.record.eml" (fsynced) + manifest
  #    %{"kind"=>"send", account, origin, message_id, content_hash, canonical_hash,
  #      "review_fingerprint"=>..., "wire_sha256"=>..., "record_sha256"=>...,
  #      "envelope"=>%{"from"=>..., "rcpt"=>[...]}, "threading"=>..., "provider"=>...,
  #      "reconcile_attempts"=>0, "transitions"=>["spooled"]} → transition "claimed"→"pending"
  #    (+ wire/record hashes, envelope_rcpt onto the row) → cas_stamp "sending".

execute_send(ctx, op_id) :: :ok | {:send_review, reason} | {:rejected, reason}
  # account guard (Task 1's raise). Dispatch by state:
  #   "pending"   → re-verify spool wire hash → transition "executing" + manifest transition
  #                 "transmitting" (BOTH durable BEFORE the transport call) →
  #                 smtp_transport.send(smtp_cfg, credential, envelope, wire, []) ONCE:
  #       {:ok, :accepted}                → transition "transmitted" → sent_copy_step
  #       {:error, {:rejected_recipients, list}} → reject_send (error = joined per-rcpt reasons)
  #       {:error, reason}                → reject_send (provably unsent; draft reverts "draft")
  #       {:unknown, reason}              → transition "send_review" (spool kept)
  #   "executing" → crash window: transmit outcome unrecorded → transition "send_review"
  #   "transmitted" → sent_copy_step (idempotent resume)
  #   "send_review" → reconcile_send (gmail only; generic returns {:send_review, "awaiting_resolution"})
  # NO OTHER STATE MAY REACH smtp_transport.send — assert via test.

sent_copy_step(ctx, op_row)
  # gmail provider: skip append (auto-filed) → complete_send.
  # generic: requires ctx.conn (IMAP). nil conn → op stays "transmitted" + notice, resumed by
  #   the next IMAP-connected recover. With conn: search-first by message_id in folders.sent
  #   (check_append_present), append RECORD payload (re-verify record_sha256 first), confirm →
  #   complete_send (cas_stamp "sent", audit, spool cleaned). Append failure after proven
  #   transmit → complete_send with error: "sent_copy_failed" (mail IS sent; never rejected).

classify_sends_local(local_ctx) :: :ok
  # Engine-activation pass, NO network (spec §Crash recovery): for each kind=="send" op —
  #   "claimed" (no spool payload possible) → reject_send "crashed_before_spool"
  #   "pending" → reject_send "crashed_before_transmit" (DATA provably never reached)
  #   "executing" → transition "send_review" (at-or-past DATA, outcome unknown)
  #   "transmitted"/"send_review" → left alone (network paths resume them)

reconcile_send(ctx, op_row)   # IMAP-connected, gmail profile only:
  # Message-ID search in folders.sent, then all known folders; found → transition
  # "transmitted" → sent_copy_step (gmail: complete). Complete-but-empty search →
  # manifest["reconcile_attempts"]+1; >= 3 → stays "send_review" + notice
  # "gmail_sent_checked_empty". NEVER auto-rejects (spec: parked, human resolves).

resolve_send_review(ctx, op_id, resolution :: :sent | :not_sent) ::
  :ok | {:error, :not_reviewable}
  # only on state "send_review" of ctx.account; :sent → transition "transmitted" →
  # sent_copy_step; :not_sent → reject_send (draft reverts "draft").
retry_sent_copy(ctx, op_id) :: :ok | {:error, :not_retryable}
  # only complete + error=="sent_copy_failed" → re-run sent_copy_step (search-first, idempotent).

# recover/1 grows: recover_sends(ctx) (IMAP-connected: transmitted→sent_copy_step,
# send_review→reconcile_send) — placed alongside recover_appends; sweep_orphan_manifests
# recreate dispatch admits "send" (row recreated at the manifest's LAST recorded transition:
# "spooled"→"pending", "transmitting"→"executing"(→classify→send_review), "transmitted"→"transmitted").

# op_display/1 send additions:
op_display("transmitted"), do: "sending"
op_display("send_review"), do: "send_review"
# (existing clauses keep push behavior; "complete" display resolved by the projection below)

review_fingerprint(settings :: Settings.t(), threading :: DraftMime.threading() | nil) :: String.t() | nil
  # sha256 hex of Settings-fingerprint-input <> "\nthreading\n" <> canonical threading string
  # ("none" when nil / no in_reply_to; else in_reply_to <> "\n" <> Enum.join(references, "\n")).
  # Lives in OpsExecutor (needs DraftMime.threading); nil iff smtp_fingerprint is nil.

# Engine:
Engine.send_draft(slug, draft_name, content_hash, review_fingerprint) ::
  {:ok, display} | {:error, :inactive | :not_configured | :smtp_not_configured |
                            :no_smtp_credential | :blocked | :not_found | String.t()}
  # handle_call mirrors push_draft L421-445 exactly: captured local_ctx from state.settings,
  # prepare_send, busy? → ops_queue, else start_send_task (SMTP transmit needs no IMAP conn;
  # sent-copy connects IMAP inside the task like run_push does; connect failure leaves
  # "transmitted" + notice). do_activate additionally runs classify_sends_local BEFORE
  # schedule_poll.
Engine.resolve_send_review(slug, op_id, resolution), Engine.retry_sent_copy(slug, op_id)
Engine.draft_review(slug, draft_name) :: {:ok, review_map} | {:error, ...}
  # THE atomic review snapshot (GenServer.call — same captured settings): nofollow read →
  # parse → threading resolve → %{"content" => raw, "content_hash" => ..., "recipients" =>
  # %{"to"|"cc"|"bcc" => [%{"name"|"email"}]}, "subject" => ..., "threading" =>
  # %{"in_reply_to"|"references"} | nil, "threading_warning" => bool, "identity" =>
  # %{"from"|"from_name"|"account"}, "review_fingerprint" => ..., "smtp_configured" => bool}
```

**Display projection (replaces `draft_display/3` in `api/mail.ex` — spec §Display projection):**
```elixir
defp draft_display(account, name, parsed, raw_hash) do
  ops = Store.ops_by_origin(account, "drafts/" <> name)   # newest first now
  active = Enum.find(ops, &(&1.state in ~w(claimed pending executing needs_review transmitted send_review)))
  newest_send = Enum.find(ops, &(&1.kind == "send" and &1.state in ~w(complete rejected)))
  pushed? = Enum.any?(ops, &(&1.kind == "append" and &1.state == "complete"))
  fm_status = frontmatter_status(parsed)
  {state, error} =
    cond do
      active != nil -> {OpsExecutor.op_display(active.state), active.error}
      newest_send != nil and newest_send.state == "complete" and newest_send.content_hash == raw_hash ->
        {"sent", newest_send.error}                       # error may be "sent_copy_failed"
      newest_send != nil and newest_send.state == "complete" ->
        {"draft", "earlier_revision_sent"}
      newest_send != nil -> {"draft", newest_send.error}  # rejected → retryable
      fm_status in ["pushing", "pushed", "sending", "send_review", "sent"] -> {"draft", "status_forged"}
      true -> {fm_status || "draft", nil}
    end
  {state, error, pushed?}
end
# list_mail_drafts rows gain "pushed" => pushed? and (as today) "status"/"notice".
```

**RPC additions (`Valea.Api.Mail`):** `get_mail_draft_review(account, draft_name)` → `Engine.draft_review/2` result verbatim; `send_draft(account, draft_name, content_hash, review_fingerprint, generation)` → `Engine.send_draft/4` (fingerprint mismatch surfaces `"re_review_required"`); `resolve_send_review(account, op_id, resolution, generation)` (resolution constrained `one_of: ["sent","not_sent"]`); `retry_sent_copy(account, op_id, generation)`. All follow `push_draft_to_mailbox`'s body shape (L487-503): `check_generation` → `Manager.current` → `validate_slug` → Engine call → `error_for/1` (new clauses: `:smtp_not_configured`, `:no_smtp_credential`, `:not_reviewable`, `:not_retryable`).

- [ ] **Step 1: failing `store_test.exs` additions** — migration applies on a DB that already ran `20260717000001` (old index dropped, widened one active); `create_pending_op(kind: "send")` + second send same origin → `:duplicate_active`; send-vs-append mutex both directions; `pending_ops` includes `transmitted`/`send_review` rows; `ops_by_origin` newest-first.
- [ ] **Step 2: failing `ops_executor_send_test.exs`** (tmp repo + `ModelMailTransport` for IMAP + `FakeSmtpTransport`), one test per scenario, asserting BOTH ledger state and `FakeSmtpTransport.calls/1` counts (the at-most-once property): happy generic (accepted → record appended to Sent → complete → stamp `sent`); happy gmail (no append call); rejected recipients (no DATA, op rejected, per-rcpt error joined, draft reverts); refused-after-dot 550 → rejected; unknown → `send_review`, spool kept, `send` called exactly once; `execute_send` on `send_review` (generic) makes NO smtp call; gmail reconcile found → completes without smtp call; gmail 3× empty → parked + notice; `resolve_send_review :sent` → sent-copy runs idempotently (pre-seed Sent with the Message-ID → no duplicate append); `:not_sent` → rejected + draft reverts; `retry_sent_copy` on `sent_copy_failed` re-runs only the append; `classify_sends_local` table (claimed→rejected, pending→rejected, executing→send_review, transmitted untouched); orphan send manifest at each transition recreates the right state; wire-hash tamper → rejected before transmit; `prepare_send` fingerprint mismatch → `re_review_required`, no op row; oversized draft (`byte_size > sync.max_message_bytes`) → `"draft_too_large"`, no op row; draft-edited-mid-send CAS (stamp leaves newer revision `draft`); canonical Message-ID stable across a failed attempt's stamps (draft without initial `status:`); **display projection via `list_mail_drafts`** (push-complete then send-rejected → primary `draft` + `pushed: true` badge + surfaced error, Send retry eligible; two terminal sends → the NEWEST governs (ordering test); send-complete then draft edited → `draft` + `earlier_revision_sent` note (raw-content-hash gating); `sent` shown only while the file hash matches the completed op's `content_hash`).
- [ ] **Step 3: Run** → FAIL. **Step 4: Implement** migration + store + executor. **Step 5: failing engine/RPC tests** — send serialization (busy engine queues send behind a running pass, double-call second gets `{:duplicate, ...}` display); settings-reload interleave both orderings (reload before call → restarted engine rejects stale fingerprint; reload after entry — assert composed spool From matches the captured settings via the wire payload); RPC round-trips incl. `re_review_required` and the agent-isolation grep-test extension (send RPCs in the control-token surface only). **Step 6: Implement engine + RPCs**, run `mix ash_typescript.codegen`, commit regenerated FE api. **Step 7: full backend suite green.** **Step 8: Commit** `feat(mail): send op kind — tri-state transmit, review fingerprint, recovery, projection, RPCs`.

---

### Task 5: Send UI — confirm modal, send_review flows, SMTP setup

**Files:**
- Create: `frontend/src/lib/components/mail/SendConfirmModal.svelte`
- Modify: `frontend/src/lib/api/client.ts`, `frontend/src/lib/stores/mail.svelte.ts`, `frontend/src/lib/components/mail/DraftsPanel.svelte`, `frontend/src/lib/components/mail/SetupPanel.svelte`, `frontend/src/lib/components/mail/mail-shapes.ts`
- Test: `frontend/src/lib/stores/mail.test.ts`, `frontend/src/lib/components/mail/mail-components.test.ts`, `frontend/src/lib/components/mail/setup.test.ts`

**Interfaces (Produces):**
```ts
// client.ts (wrapper style identical to pushDraftToMailbox):
getMailDraftReview: (account: string, draftName: string) => ...      // → MailDraftReview
sendDraft: (account: string, draftName: string, contentHash: string, reviewFingerprint: string, generation: number) => ...
resolveSendReview: (account: string, opId: string, resolution: 'sent' | 'not_sent', generation: number) => ...
retrySentCopy: (account: string, opId: string, generation: number) => ...
// setupMailAccount gains the six optional smtp args; setMailCredential gains kind?: 'imap'|'smtp'

// mail.svelte.ts:
type MailDraftReview = { content: string; contentHash: string; reviewFingerprint: string;
  recipients: { to: Addr[]; cc: Addr[]; bcc: Addr[] }; subject: string;
  threading: { inReplyTo: string; references: string[] } | null; threadingWarning: boolean;
  identity: { from: string; fromName: string | null; account: string }; smtpConfigured: boolean };
MailStore.draftReview(account, name): Promise<MailDraftReview | { error: string }>
MailStore.sendDraft(account, name, contentHash, reviewFingerprint, generation): Promise<{ state: string } | { error: string }>
  // calls sendDraft, then refreshDrafts; NEVER re-hashes content itself — the hash comes
  // from the review response (one-buffer contract).
MailStore.resolveSendReview(...), MailStore.retrySentCopy(...)
// MailDraft gains pushed: boolean; statusDisplay union grows sending|send_review|sent.
// MailAccountStatus gains smtpConfigured: boolean, smtpCredential: 'present'|'missing'|'n/a'
// (normalizers read the Task 4/2 status keys). resupplyCredentials additionally resupplies
// `${slug}:smtp` when smtpConfigured && smtpCredential === 'missing' (kind 'smtp').
```

- [ ] **Step 1: failing vitest** — `mail.test.ts`: `sendDraft` passes the review's hash/fingerprint verbatim (fake api asserts args) and never calls `getMailDraft`; `resolveSendReview` refreshes drafts; normalizer maps `pushed`, new statuses, smtp status keys; resupply covers smtp. `mail-components.test.ts` (pure fns in `mail-shapes.ts`): `sendConfirmSummary(review)` → lines for To/Cc/Bcc (parsed set), subject, `from_name <from> · account`, threading warning line when `threadingWarning`; `draftStatusBadge` tones for the three new statuses (`sending`→busy, `send_review`→warn, `sent`→ok); `sendReviewExplanation(notice)` gmail-evidence strings (`gmail_sent_checked_empty` → "Sent Mail was checked and found empty…", awaiting-connection variant). `setup.test.ts`: `submitMailSetup` with smtp fields writes keychain `${slug}:smtp` when "same as IMAP" is on (copies the imap secret — a copy, not an alias) and calls `setMailCredential(..., 'smtp')`.
- [ ] **Step 2: Run** `bun run test` → FAIL. **Step 3: Implement** client wrappers, store methods, shapes helpers.
- [ ] **Step 4: Components.** `SendConfirmModal.svelte`: props `{ review: MailDraftReview; account: string; draftName: string; onclose }`; renders `sendConfirmSummary` + body preview; ONE confirm button → `mailStore.sendDraft(account, draftName, review.contentHash, review.reviewFingerprint, generation)`; `re_review_required` error → message + a "Reload review" action calling `draftReview` again. `DraftsPanel.svelte`: Send button beside Push, eligibility `statusDisplay === 'draft' && account.smtpConfigured && !('invalid' in draft.recipients)`; opens the modal via `draftReview`; `pushed` renders as a badge chip, never the primary state; `send_review` rows show `sendReviewExplanation` + "It was sent" / "It was not sent" buttons (each with a confirm step naming the consequence); `sent` + `sent_copy_failed` notice → "Retry Sent copy". `SetupPanel.svelte`: optional SMTP fieldset (host/port/security select/username/from/from_name + password + "same as IMAP" checkbox), submitted through the extended `submitMailSetup`.
- [ ] **Step 5:** `bun run check && bun run test` green. **Step 6: Commit** `feat(mail-fe): send confirm modal, send_review resolution, smtp setup + keychain`.

---

### Task 6: Live drafts — watcher event → store refetch

**Files:**
- Modify: `backend/lib/valea/icm/watcher.ex`, `backend/lib/valea_web/channels/workspace_events_channel.ex`, `frontend/src/lib/socket.ts`, `frontend/src/lib/stores/mail.svelte.ts`
- Test: `backend/test/valea/icm/watcher_test.exs`, channel test, `frontend/src/lib/stores/mail.test.ts`

**Interfaces (Produces):**
```elixir
# watcher.ex: classify_path/2 sources branch splits:
#   under sources_path AND relative segments match ["mail", slug, "drafts", file] with
#   String.match?(slug, ~r/^[a-z0-9][a-z0-9-]{0,31}$/) and String.ends_with?(file, ".md")
#   → {:mail_draft, slug}; else :ignore (everything else under sources/ unchanged).
# note_mail_draft_event(slug, state): arm(:draft_timer, :flush_drafts, state) and
#   draft_pending = MapSet.put(state.draft_pending, slug)   # NEW state keys, init: nil / MapSet.new()
# handle_info(:flush_drafts, state): configured = case Valea.Mail.Settings.load(state.root) do
#   {:ok, %{accounts: accounts}} -> Map.keys(accounts); _ -> [] end
#   for slug <- state.draft_pending, slug in configured:
#     Phoenix.PubSub.broadcast(Valea.PubSub, "mail", {:mail_draft_changed, slug})
#   → %{state | draft_timer: nil, draft_pending: MapSet.new()}
# channel: handle_info({:mail_draft_changed, slug}, socket) →
#   push(socket, "mail_draft", %{"account" => slug})
```
```ts
// socket.ts: export type MailDraftPush = { account: string };
// joinWorkspaceEvents/wireMailEvents: channel.on('mail_draft', (p) => mailStore.handleMailDraft(p));
// mail.svelte.ts: handleMailDraft(_payload: MailDraftPush): void { void this.refreshDrafts(); }
```

- [ ] **Step 1: failing backend tests.** Watcher (real FS, tmp root, configured account `"mara"` via a v5 mail.yaml fixture): write `sources/mail/mara/drafts/x.md` → receive `{:mail_draft_changed, "mara"}` on `"mail"` within 2s; write `sources/mail/mara/maildir/cur/y` and `sources/other.txt` → NO event; two accounts (`mara`, `zoe` both configured) edited within one debounce window → BOTH events, one per slug; unconfigured slug dir → no event. Channel test: broadcast `{:mail_draft_changed, "mara"}` → push `"mail_draft"` `%{"account" => "mara"}`.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement** (separate `draft_timer` — do NOT reuse `discovery_timer`; drafts flushing must not trigger mounts recompute). **Step 4: green.**
- [ ] **Step 5: frontend** — failing `mail.test.ts` case (`handleMailDraft` refetches drafts), implement type + wiring + handler, `bun run check && bun run test` green.
- [ ] **Step 6: Commit** `feat(mail): live drafts — watcher mail_draft_changed with per-account debounce`.

---

### Task 7: Request changes — revise_mail_draft + initial_prompt exposure

**Files:**
- Modify: `backend/lib/valea/agents/session_server.ex` (via/registration), `backend/lib/valea/agents.ex`, `backend/lib/valea/api/agents.ex`, `backend/lib/valea/api/mail.ex`
- Modify: `frontend/src/lib/api/client.ts`, `frontend/src/lib/components/mail/DraftsPanel.svelte`, `frontend/src/lib/components/mail/mail-shapes.ts`
- Test: `backend/test/valea/agents/session_server_test.exs`, `backend/test/valea_web/agents_rpc_test.exs`, mail RPC test, `frontend/src/lib/components/mail/mail-components.test.ts`

**Interfaces (Produces):**
```elixir
# SessionServer: registration value carries the input locator —
#   defp via(id, input \\ nil), do: {:via, Registry, {Valea.Agents.SessionRegistry, id, %{input: input}}}
#   start_link uses via(id, Map.get(opts, :input)); whereis/1 unchanged (lookup ignores value).
Valea.Agents.list_running_session_inputs() :: [{session_id :: String.t(), input :: map() | nil}]
  # Registry.select(Valea.Agents.SessionRegistry, [{{:"$1", :_, :"$2"}, [], [{{:"$1", :"$2"}}]}])
  # |> Enum.map(fn {id, %{input: input}} -> {id, input} end)

# api/agents.ex create_session: NEW argument :initial_prompt, :string, allow_nil?: true —
# passed through to start_session (replaces the hardcoded nil at L138). Nothing else changes.

# api/mail.ex:
# :revise_mail_draft — account, draft_name, feedback:string, mount_key:string, generation
#   run: check_generation → validate_slug → validate_draft_name → draft must exist (nofollow
#   stat) → target = Enum.find(Valea.Agents.list_running_session_inputs(), fn {_id, input} ->
#     locator_resolves_to?(input, draft_abs) end)
#     (locator_resolves_to?: Valea.Icm.Locator.resolve(workspace, input) == {:ok, draft_abs};
#      nil/malformed/unresolvable input → false; resolve errors → false)
#   match → SessionServer.prompt(id, revise_prompt(rel_path, feedback)) →
#     {:ok, %{"session_id" => id, "routed" => "existing"}}
#     (a session that died between select and prompt: prompt/2 is a cast — treat as fire-and-
#      forget; the FE link will show it archived. Accepted: correlation is best-effort.)
#   no match → SessionScope.resolve(%{kind: "chat", mount_key: mount_key, generation,
#     session_id: id, read_paths: [draft_abs], include_mounts: ["mail-" <> slug]}) →
#     Valea.Agents.start_session(%{..., initial_prompt: revise_prompt(rel_path, feedback),
#     input: %{"kind" => "workspace", "path" => rel_path}, include_mounts: ...}) →
#     {:ok, %{"session_id" => id, "routed" => "new"}}
#   :icm_unavailable maps to "no_icm_available" in error_for.

defp revise_prompt(rel_path, feedback) do
  """
  Revise the mail draft at #{rel_path} per this feedback. Edit the file in place. Keep the \
  frontmatter valid (to/cc/bcc/subject/in_reply_to only) and do not touch the status field.

  Feedback:
  #{feedback}
  """
end
```
```ts
// client.ts: reviseMailDraft: (account, draftName, feedback, mountKey, generation) => ...
// DraftsPanel: per-draft "Request changes" disclosure → textarea + submit; mountKey =
//   mostRecentMountKey(recentSessionsStore.groups, icmStore.groups[0]?.mount ?? null)
//   (import from $lib/today/quick-session); null → inline error "No enabled project can
//   host the session. Enable one in the sidebar." (the existing cleanup-entry copy).
//   Success → "Sent to session" + link goto(`/chat?session=${sessionId}`).
```

- [ ] **Step 1: failing backend tests.**
  - `session_server_test.exs`: **initial_prompt enqueue** (closes the known coverage gap): `start_session(root, "happy", initial_prompt: "seeded hello")` → `assert_receive {:session_event, _, %{"type" => "message", "role" => "user"}}` whose content is `"seeded hello"` WITHOUT any `prompt/2` call; `list_running_session_inputs/0` returns the started session with its input locator, and `[]`-input sessions as `{id, nil}`.
  - `agents_rpc_test.exs`: `create_agent_session` with `"initialPrompt"` → session starts and the transcript's first user message matches.
  - mail RPC test: revise with a running session whose input locator resolves to the draft → `routed == "existing"`; without → `routed == "new"` + the new session's meta carries the mail mount + input; bad mount_key → `"no_icm_available"`; missing draft → `"not_found"`; agent-isolation unchanged.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement backend** (via/2 value registration, enumeration, RPC action, prompt template verbatim above, `error_for` clause). Run `mix ash_typescript.codegen`, commit regenerated api.
- [ ] **Step 4: frontend** — failing `mail-components.test.ts` for the feedback-form shape helper (`reviseOutcomeMessage(routed)`), implement client wrapper + panel UI, `bun run check && bun run test` green.
- [ ] **Step 5: Commit** `feat(mail): request-changes — session routing by input locator, initial_prompt over RPC`.

---

### Task 8: Docs rewrite, acceptance checklist, suite gate

**Files:**
- Modify: `docs/ARCHITECTURE.md` (mail §, incl. L463-467 + L628-633 invariant bullets), `docs/VISION.md` (L205 area), code comments: `backend/lib/valea/mail/ops_executor.ex:457`, `backend/lib/valea/mail/engine.ex:287`, `backend/lib/valea/api/mail.ex:483`, `frontend/src/lib/stores/mail.svelte.ts:366`, `frontend/src/lib/components/mail/DraftsPanel.svelte:6`, `frontend/src/lib/api/client.ts:1637`
- Create: `docs/superpowers/acceptance/2026-07-26-mail-smtp-send.md`

- [ ] **Step 1: Docs.** Replace every "no SMTP / Valea cannot send" formulation with the Spec G invariant: *Valea transmits mail only on an explicit human action, hash-bound to the exact draft (and sending identity + threading) the human reviewed; agents have no path to send; no code path retransmits.* ARCHITECTURE gains a §Send subsection (tri-state boundary, settings pinning, send_review semantics, activation classification) and the spec-index entry for Spec G. Comment sweep: each listed comment becomes a pointer to the invariant + spec file.
- [ ] **Step 2: Acceptance checklist** (structure copied from `docs/superpowers/acceptance/2026-07-17-mail-maildir.md`). Preface: a `scripts/` local submission-server companion (the spec's live-acceptance requirement — the real `SmtpClient` against a real local socket with scriptable outcomes; `FakeSmtpServer` extracted into a runnable script is acceptable). Sections: A. generic provider real send (normal send → received + Sent copy; rejected recipient → nothing delivered; kill connection post-DATA → send_review, resolve both ways; sent_copy retry). B. Gmail real send (normal; lost-response drill → auto-reconcile completes; same-Message-ID re-send after wrong not_sent — recipient side shows dedupe/thread). C. Iteration loop live (agent revises → Drafts panel updates without navigation; Request changes routes to the open session; new-session path seeds the prompt). D. Multi-account (two accounts, switch with message open, colliding deep link, simultaneous first syncs under WAL). E. Doctor smtp checks against a real provider.
- [ ] **Step 3: Grep gates** (from File Structure) + full `just test` → all green; fix fallout.
- [ ] **Step 4: Commit** `docs(mail): human-only transmission invariant + Spec G acceptance checklist`.
