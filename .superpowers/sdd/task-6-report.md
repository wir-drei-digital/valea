# Task 6 report: fingerprint identity + derived views

## Implemented

### `backend/lib/valea/mail/message_file.ex` (modified)

- `fingerprint/1` — sha256 hex (lowercase, full 64 chars) of raw RFC822
  bytes.
- `msg_id/2` — now `<date>-<from-slug>-<hash8>` where `hash8` is
  `fingerprint/1`'s first 8 hex chars, computed over the FULL raw bytes
  (never the `Message-ID` header). `date_slug`/`from_slug` reused
  byte-for-byte from the old implementation, per the brief.
- `render/2` — new meta shape `%{msg_id:, account:, folders: [String.t()],
  flags: String.t(), attachments: [...]}`. Frontmatter field order: `id,
  message_id, account, folders, flags, from, to, subject, date,
  in_reply_to, references, reply_to, attachments` + notes. No
  `status`/`uid`/`source`/`source_ref`.
- `flip_status/2` and `@status_re` **deleted**, replaced by a more general
  `patch_frontmatter/2`: byte-preserving multi-key `<key>: ...` line
  replacement inside the frontmatter block only (never the body), used by
  `Views.refresh_folders/5` to patch `folders:`/`flags:` in place. Chose a
  byte-preserving patch over "full re-render from a reconstructed
  `%Message{}`" (the brief's other permitted option) because
  reconstructing a `Message` struct from parsed YAML (date strings back to
  `DateTime`, string-keyed address maps back to atom-keyed) is strictly
  more moving parts for no behavioral gain, and it preserves any
  hand-rendered notes lines untouched.
- `yaml_string/1` and `render_string_list/1` made **public** (were
  private) so `Views` can reuse the exact same encoding for the
  `folders:`/`flags:` patch — one source of truth for the YAML
  injection-hardening rules, not a second copy.
- `parse/1`, `sanitize_filename/1` unchanged.

### `backend/lib/valea/mail/views.ex` (new)

`land/4`, `refresh_folders/5`, `remove_occurrence/4`, `view_rel_path/2` —
all paths under `sources/mail/<account>/views/`.

**Sidecar choice:** `views/.fingerprints/<msg_id>` (a plain-text file
holding just the hex fingerprint), not "compare against the raw maildir
candidate file." Reasoning: `land/4` runs BEFORE the raw bytes are
delivered into `maildir/` (the caller needs the resolved `msg_id` back
*to build* the maildir filename `<msg_id>,U=<uid>:2,<flags>` in the first
place — Task 7's job), so there is no maildir occurrence path to compare
against yet in the normal flow. The sidecar also keeps `Views` fully
self-contained (no dependency on folder directory layout). It's removed
alongside the view on full GC (`remove_occurrence/4` with `remaining: 0`),
so a msg_id becomes reusable again once every trace of the old content is
gone.

**Collision rule:** `resolve_msg_id/5` tries 8 → 16 → 64 hex exactly like
the old `sync_pass.ex`'s `msg_id_for_path/3`, but against the sidecar
instead of a candidate file's parsed `message_id`. A candidate is accepted
when its sidecar is absent (unclaimed) or already holds the SAME
fingerprint (re-landing identical content); a different fingerprint moves
to the next hex length. Exhausting all three still resolves (falls back
to the full 64-hex id) rather than raising.

**`msg_id_hint`:** trusted only when unclaimed or already matching the
same fingerprint; a hint colliding with different content falls back to
the ordinary resolution rather than silently overwriting someone else's
view.

**Idempotency:** `land/4` only writes when
`fingerprint_of(root, account, msg_id) != fingerprint` — critical detail:
a re-land of identical bytes must NOT re-render the view, because a prior
`refresh_folders/5` call may have already given it real
`folders:`/`flags:` that a blind re-render (which always starts from
`folders: []`/`flags: ""`) would wipe. Verified by a dedicated test.

**`remove_occurrence/4`'s "refresh only" for `remaining > 0`:** implemented
as a plain no-op. The function signature carries no folder/flags data (by
design — brief's literal signature), so it cannot itself recompute
membership; the caller (Task 7's `SyncPass`) is expected to call
`refresh_folders/5` separately with the updated membership when an
occurrence goes away but others remain. Documented explicitly in the
moduledoc so Task 7 doesn't read "refresh only" as an implicit obligation
this function silently discharges.

### `backend/lib/valea/mail/index.ex` (rewritten)

`rebuild(root, account)` — cache-only:

1. Walks `<root>/sources/mail/<account>/maildir/` recursively (skipping
   `cur`/`new`/`tmp` — those are leaves, not further folder nesting),
   collecting every directory that carries a `.folder` identity file
   (`Maildir.read_folder_identity/1`).
2. For **every** such directory, binds
   `Store.put_sync_state(account, imap_name, %{dir:, backfill_complete:
   false})` FIRST, before parsing a single occurrence in it — watermark/
   `UIDVALIDITY`/`HIGHESTMODSEQ` deliberately left unset (next real pass
   re-establishes them).
3. Then, per bound folder, `Maildir.list_occurrences/1` + per-occurrence
   `Store.put_occurrence/3` + `Store.upsert_index_row/1`.

Since each directory declares its OWN identity independently of walk
order, the case-colliding-folders-plus-reversed-LIST-order scenario the
brief calls out is naturally order-independent — there's nothing to get
backwards. Covered by a dedicated test (`Maildir.folder_to_dir/2`-produced
distinct dirs for `"Work"`/`"work"`, rebuilt correctly regardless of
`File.ls/1`'s arbitrary entry order).

**Design choice — metadata source (flagging for review):** the brief says
Index "re-parses each raw file." I read metadata (message_id, from,
subject, date, in_reply_to, references, has_attachments) from the
occurrence's **shared view** (`views/messages/<msg_id>.md`, via
`MessageFile.parse/1`) instead of re-normalizing the raw RFC822 bytes with
`Normalizer.normalize/1`. Reasoning: the view already holds exactly this
data (computed once at land time), multiple occurrences of one msg_id
would otherwise redundantly re-run full MIME parsing per occurrence for
identical output, and `Index` stays single-purpose (reads `Store` +
`Views`' rendered output, never itself parses mail or writes to
`Views`/`maildir/`). If the intent was literal per-occurrence raw-MIME
re-parsing (e.g., as a self-healing path when a view is missing), that's
a straightforward substitution in `view_meta/3` — flagging here rather
than silently picking one reading. A missing/corrupt view still indexes
the occurrence (it undeniably exists on disk) with blank metadata rather
than being dropped or aborting the rebuild.

**`rebuild/1` (TEMP v3-bridge, arity 1, for `engine.ex`'s `activate/1`):**
implemented as a **pure no-op** (`{:ok, 0}`) — the smaller of the two
options the brief allows (vs. iterating every account from
`Settings.load/1` and calling `rebuild/2` per account). Chose the no-op
because `engine.ex` is itself still single-account-shaped
(`load_settings/1`'s v3-bridge) and doesn't yet consume a real per-account
rebuild at activation; tying `Index` to `Settings` for that would be
scaffolding with no current payoff. Documented in a moduledoc comment,
`# TEMP v3-bridge: removed in Task 9`.

## Gut-vs-adapt: `sync_pass.ex`

**Gutted**, per the brief's explicit authorization. `render/2`'s new meta
shape has no `uid`/`status`/`source` keys; `msg_id/2`'s hash input
changed from "Message-ID-or-header-block" to "full raw bytes"; the entire
landing pipeline (folder walk, attachment write, Message-ID dedupe,
`inbox.md` generation, `Store.record_outcome/outcomes`) is Task 7's
territory (new maildir/views/occurrence model), not a meta-shape patch.
Adapting would have meant faking old single-flat-file semantics against a
format that no longer represents that shape at all.

**What survived:** the outer `transport.connect/3` → `{:ok, conn}` /
`{:error, :auth_failed}` / `{:error, term()}` contract, because
`Valea.Mail.Engine`'s own test suite (`engine_test.exs`) exercises
`sync_now`/`auth_failed`/credential-redaction structurally through exactly
this shape (`HangingTransport`, `LeakyConnectTransport` — confirmed
neither test file ever exercises the successful landing path via
`FakeMailTransport`, so gutting that path breaks nothing there). The
gutted `run/1`: connects, logs out on success, returns
`{:ok, %{new_messages: 0, errors: []}}`; error paths pass through
verbatim.

**What was deleted:** `sync_pass_test.exs`'s entire old suite (folder
landing, attachment writes, UIDVALIDITY resync + Message-ID dedupe,
oversize truncation, per-UID failure/retry, inbox.md generation,
credential-leak-into-outcome edge cases) — all exercised the deleted
pipeline. Replaced with 4 focused cases against the actual gutted
contract: successful connect → no-op result (+ logout called),
`auth_failed` passthrough, arbitrary connect-error passthrough, credential
closure called exactly once at the connect boundary.

## Other fallout adapted (not gutted)

`Valea.Api.Mail` (`get_mail_message`/`list_mail_messages`) and
`Valea.Cockpit.mail_summary/0` still read the OLD, single-flat-file
`Store.upsert_message/1`-keyed cache (`__legacy__` scope) — out of scope
for Task 6 (Task 10 rewrites them against the new per-account API). Their
tests' `plant_message` helpers previously built that cache row by writing
a `MessageFile.render/2` file with the old meta shape and calling the
now-gone-in-effect `Index.rebuild/1` (arity 1) to index it. Since
`render/2`'s meta shape changed and the new `rebuild/1` bridge is a pure
no-op (see above), both helpers now: render the file with the NEW meta
shape (so `get_mail_message`'s `File.read` round trip and
`MessageFile.parse/1` still succeed), and seed the legacy cache row
directly via `Store.upsert_message/1` instead of relying on indexing.
Adapted files: `test/valea_web/mail_rpc_test.exs`, `test/valea/cockpit_test.exs`
— behavior/assertions unchanged, only how the fixture data reaches the
Store changed. No test deleted in either file.

## TDD evidence (RED → GREEN)

- `message_file_test.exs`: rewrote fully against the new `MessageFile`
  API before touching `message_file.ex`'s implementation body (the file
  was edited in place, so RED was confirmed by running the OLD
  implementation against the NEW test file: `hash8`/fingerprint tests and
  the golden `render/2` test failed as expected — old `msg_id/2` still
  hashed `message_id`/header-block, old `render/2` still emitted
  `uid`/`status`/`source`). GREEN after rewriting `message_file.ex`: 26
  passed.
- `views_test.exs` (new): written and run against nonexistent
  `Valea.Mail.Views` first — RED, `UndefinedFunctionError`/module-not-found
  — before creating `views.ex`. GREEN after: 11 passed.
- `index_test.exs`: rewritten fully against the new `rebuild/2` signature
  before rewriting `index.ex`'s body — RED (old `rebuild/1`-only module
  had no `rebuild/2` clause). GREEN after: 7 passed.
- `sync_pass_test.exs`: written against the gutted contract after gutting
  `sync_pass.ex` (this one didn't need a RED phase against a stale
  contract — the old suite's failure mode was "tests old behavior that no
  longer exists," addressed by wholesale replacement, not a fix). 4
  passed.

## Self-review

- Confirmed the idempotent-no-op path in `Views.land/4` doesn't
  silently regress previously-set `folders:`/`flags:` — dedicated test
  (`"landing the exact same bytes twice is a no-op..."`) refreshes
  folders first, re-lands, and asserts they survive.
- Confirmed account isolation is structural (paths are
  `sources/mail/<account>/views/...` throughout), not merely
  "happens to work" — test lands identical bytes under two accounts and
  removes one account's view, asserting the other is untouched.
- Confirmed the hash-extension collision rule actually extends (not just
  "doesn't crash") by pre-planting a sidecar with a deliberately different
  fingerprint at the 8-hex candidate and asserting the real land resolves
  to the 16-hex id.
- Confirmed `Index.rebuild/2`'s per-occurrence resilience doesn't silently
  swallow real failures: the "no confirmed UID" skip is asserted via
  `capture_log` for the exact log message, and the "missing view" path is
  asserted to still produce a real (if metadata-blank) row rather than
  disappearing.
- Re-read `Valea.Mail.Store`'s moduledoc's "TEMP v3-bridge" section before
  touching anything there — confirmed I did NOT touch
  `upsert_message/1`/`get_message/1`/`list_messages/0`/
  `message_by_message_id/1`/`set_message_status/2` (still consumed by
  `Valea.Api.Mail`/`Valea.Cockpit`, Task 10's territory), only relied on
  the already-v2 `put_sync_state/3` (map arity), `put_occurrence/3`,
  `occurrences/2`, `upsert_index_row/1`, `list_messages/2`.
- Double-checked `mix compile --warnings-as-errors` is clean (lib only, as
  the brief's checklist literally specifies) and separately ran
  `mix test --warnings-as-errors`, which aborts on ONE pre-existing,
  unrelated warning in `test/valea_web/audit_rpc_test.exs` (unused default
  args on a private `rpc/3` helper) — confirmed via `git log` that file
  predates this session and I never touched it; flagging rather than
  silently fixing out-of-scope code.

## Verification

- `mix test test/valea/mail/message_file_test.exs` → 26 passed.
- `mix test test/valea/mail/views_test.exs` → 11 passed.
- `mix test test/valea/mail/index_test.exs` → 7 passed.
- `mix test test/valea/mail/sync_pass_test.exs` → 4 passed.
- `mix test test/valea_web/mail_rpc_test.exs test/valea/cockpit_test.exs`
  → 34 passed (adapted fallout, confirmed green).
- Full suite: `mix test` → **831 passed, 0 failures** (interleaved
  `Exqlite ... database is locked` lines are pre-existing SQLite-pool
  contention noise from unrelated concurrent tests, documented elsewhere
  in the suite, not assertion failures).
- `mix format --check-formatted` → clean.
- `mix compile --force --warnings-as-errors` → clean, 0 warnings.

## Commit

`feat(mail): raw-fingerprint identity + derived views/index`.

## Fix wave

Three review findings fixed, TDD (RED confirmed against the pre-fix code
for all three before touching implementation):

1. **CRITICAL — `MessageFile.patch_frontmatter/2` byte corruption.**
   `Regex.replace/4` was called with a STRING replacement, which
   reinterprets `\N` as a capture-group backreference and collapses `\\`
   pairs to a single `\` (Perl-style replacement escaping) — silently
   corrupting any `yaml_string/1`-escaped value containing a backslash
   (e.g. an IMAP folder name ending in `\` renders its closing `\\"` and
   the patch collapsed it to `\"`, un-terminating the YAML string). Fixed
   by switching to the FUNCTION replacement form (`fn _ -> "#{key}:
   #{value}" end`), which returns its result verbatim with no
   reinterpretation. Two regression tests added: a folder name ending in
   `\` and one containing a literal `\1` token, both asserting the exact
   patched line and a successful `MessageFile.parse/1` round-trip.

2. **IMPORTANT — `Views.land/4` sidecar-loss overwrite.** A missing
   `.fingerprints/<msg_id>` sidecar was read as "unclaimed" even when
   `views/messages/<msg_id>.md` still existed, so `land/4` would
   overwrite the existing view (wiping `folders:`/`flags:` set by
   `refresh_folders/5`). Fixed: `land/4` now branches on
   `{fingerprint_of, view_ok?}` — `view_ok?/3` checks the view is both
   present AND parseable. `{sidecar-missing, view-intact}` regenerates
   only the sidecar (treats as claimed, doesn't touch the view); anything
   else (genuinely new, or a corrupt/missing view regardless of sidecar
   state) writes a fresh view. The residual — a lost sidecar can't be
   told apart from a genuine different-content collision at that exact
   msg_id — is documented in the moduledoc and inline. While implementing
   this I found the fix as scoped (sidecar-loss only) left a second gap
   uncovered by the brief: a matching sidecar with a CORRUPT view file
   was still a no-op, so `Index`'s new raw-fallback self-heal (item 3)
   would crash inside `refresh_folders/5` trying to patch a file with no
   frontmatter. Extended `view_ok?/3` to require parseability, not just
   presence, closing that gap without reopening the sidecar-loss bug
   (confirmed by keeping both regression tests green). Regression test:
   land → `refresh_folders(["INBOX"], "S")` → delete only the sidecar →
   land the same bytes again → view still has `folders: ["INBOX"]` /
   `flags: "S"`; sidecar exists again.

3. **ADJUDICATED (from Minor) — `Index.rebuild/2` blank-metadata rows.**
   `view_meta/2` wrote `@blank_meta` whenever a view was missing or
   unparseable. Fixed: `view_meta/6` keeps the view read as the fast
   path, and on failure falls back to re-normalizing the raw maildir
   file this occurrence was listed from (`Normalizer.normalize/1`),
   recovering real `subject`/`from`/`date`/`message_id`/`in_reply_to`/
   `references`, and self-heals by re-landing through `Views.land/4`
   (`msg_id_hint` pinned to the occurrence's own msg_id) +
   `Views.refresh_folders/5`. Any raise in the fallback path (e.g. a
   filesystem error) is still caught by `index_occurrence/5`'s existing
   rescue/catch — per-occurrence resilience is unchanged. Three
   regression tests: (a) an occurrence whose view was never landed at
   all, (b) a landed view's file deleted before rebuild (the brief's
   literal scenario — real subject/from recovered AND the view file
   exists again), (c) a corrupt/unparseable (but present) view file,
   added while chasing the item-2 gap above.

### TDD evidence (RED → GREEN)

All 6 new/modified tests run against the pre-fix code first: the two
`patch_frontmatter/2` tests failed on the exact collapsed-backslash /
misinterpreted-`\1` bytes described in the finding; the sidecar-loss test
failed with `fm["folders"] == []` instead of `["INBOX"]`; the three
`Index.rebuild/2` tests failed with `nil` subjects instead of the real
fixture subject. Implemented one file at a time, re-running its test
file to GREEN before moving to the next.

### Verification

- `mix test test/valea/mail/message_file_test.exs test/valea/mail/views_test.exs test/valea/mail/index_test.exs`
  → 49 passed (up from 44 before this wave — 5 new tests).
- Full suite: `mix test` → **836 passed, 0 failures** (one run hit an
  unrelated flake in `test/valea_web/agent_session_channel_test.exs`, a
  temp-dir `on_exit` race under full-suite parallelism, untouched by
  this change and predating it per `git log`; re-ran full suite and that
  file standalone, both green — 836/836 and 11/11 respectively).
- `mix format --check-formatted` → clean.
- `mix compile --force --warnings-as-errors` → clean, 0 warnings.

### Commit

`fix(mail): byte-exact frontmatter patching, sidecar-loss safety, raw-fallback rebuild`
