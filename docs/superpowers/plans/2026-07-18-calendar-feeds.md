# Calendar — ICS Feeds Implementation Plan (Spec F)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Read-only mirrors of the user's external calendars via polled ICS subscription feeds, plus one agent-writable local "Valea calendar" served back out as a tokened loopback ICS feed — file-first under `sources/calendar/`.

**Architecture:** Per-source `Valea.Calendar.Engine` processes (the mail engine pattern minus everything two-way) poll ICS feed URLs held RAM-only; `feed.ics` is the single durable commit point and views + SQLite occurrence index are derived from it under a two-store revision marker that self-heals crashes, 304-stale derives, host-zone changes, and the rolling window. The Valea calendar is markdown event files read live at query time and rendered into a served feed with injection-proof ICS composition. One synthetic `calendar` mount + a PermissionPolicy tier with mail's deny-not-ask semantics gate agent access.

**Tech Stack:** Elixir 1.20 / Phoenix 1.8 / Ash 3 + AshSqlite (hand-migrated), `tzdata` (new dep, the Elixir time-zone database), `:httpc` + `:ssl` (no new HTTP dep), SvelteKit + Svelte 5 runes + Bun + vitest.

**Authoritative spec (tie-breaker for every ambiguity):** `docs/superpowers/specs/2026-07-18-calendar-feeds-design.md`. Every implementer MUST read it in full before writing code. Where this plan and the spec disagree, STOP and escalate — do not pick silently.

## Global Constraints

- NEVER push to origin. NEVER weaken `Valea.Paths.resolve_real/2` containment — every path from user/agent input goes through it exactly like existing chokepoints.
- Commit trailer, exact: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- No credentials in any workspace file: the FEED URL IS A CREDENTIAL. OS keychain `"<workspace_id>" / "<slug>:ics"`; backend holds it ONLY as a zero-arity closure in engine process state; dev/browser fallback env `VALEA_CAL_URL_<SLUG>` (slug upcased, dashes → underscores). Feed URLs never appear in logs, error strings, status maps, or exceptions (redact like `Valea.Mail.Redact`).
- No backwards compatibility anywhere (no production users). The legacy `config/calendar.yaml` placeholder is destructively converged (Task 2).
- Source slug grammar `^[a-z0-9][a-z0-9-]{0,31}$`; `valea` is RESERVED — rejected by setup, set-url, config validation (`invalid_config`), and purge. `purge_calendar_source_files` may only ever target a VALIDATED EXTERNAL slug.
- ash_typescript falsy-field rule: any generic-action top-level field that can genuinely be `false` uses a STRING key (`"saved"`, `"accepted"`, `"removed"`, `"purged"`, `"started"`, `"ok"`, `"created"`, `"updated"`, `"deleted"`). Every mutating RPC takes `generation` and guards with `Valea.Workspace.Manager.check_generation/1` first.
- Test gate: `cd backend && just test` = backend suite + codegen-freshness (`git diff --exit-code ../frontend/src/lib/api/` — COMMIT before running it, and re-run codegen after RPC changes) + `bun run check` + `bun run test`. Check the mix test exit status directly, never through a grep pipe (PIPESTATUS masking burned us in Spec E). Baselines at branch start: backend 1059, FE 616, check 0 errors 0 warnings.
- Subagents implementing tasks are FORBIDDEN from spawning further subagents.
- `.superpowers/` stays untracked — never force-add gitignored files.
- Time discipline in all new code: all-day values are plain `Date`s end-EXCLUSIVE, never encoded as UTC midnights; timed values are UTC `DateTime`s rendered `YYYY-MM-DDTHH:MM:SSZ` (second precision). DST resolution is deterministic everywhere: ambiguous local time → EARLIER UTC instant; nonexistent local time → first instant AFTER the gap.

## Pattern files (read, don't reinvent)

| Concern | Mirror this |
|---|---|
| Settings load/validate/rewrite, slug grammar | `backend/lib/valea/mail/settings.ex` |
| Engine (registry via-tuple, activation on `{:workspace_opened, info, generation}`, single-flight monitored Task, credential closure, status map) | `backend/lib/valea/mail/engine.ex` |
| Supervisor (children from settings, rehash) | `backend/lib/valea/mail/supervisor.ex` |
| Identity file posture | `backend/lib/valea/mail/account.ex` (`.account`) |
| AshSqlite hand-migrated resources (`migrate? false`) | `backend/lib/valea/mail/store.ex` + `backend/lib/valea/mail/store/*.ex` + `backend/priv/repo/migrations/20260717000001_create_mail_tables.exs` |
| Injection-hardened markdown views | `backend/lib/valea/mail/views.ex` |
| Fail-closed frontmatter file validation, no-follow lstat | `backend/lib/valea/mail/draft_file.ex` |
| Composition-side escaping posture | `backend/lib/valea/mail/draft_mime.ex` |
| TLS options (verify_peer, OS CA trust, no insecure escape hatch) | `backend/lib/valea/mail/imap_client.ex` |
| Redaction | `backend/lib/valea/mail/redact.ex` |
| RPC resource conventions (typed vs unconstrained returns, string falsy keys, slug validation before I/O, `sensitive? true`, generation guard) | `backend/lib/valea/api/mail.ex` |
| Doctor (sequential gated checks, copyable remedies) | `backend/lib/valea/mail/doctor.ex` |
| Policy tier + casefold/segment matching | `backend/lib/valea/agents/permission_policy.ex` |
| managedSettings mirror | `backend/lib/valea/agents/session_settings.ex` |
| Mount synthesis + exclusions | `backend/lib/valea/mounts.ex` |
| include_mounts validation | `backend/lib/valea/agents/session_scope.ex` |
| Channel pushes | `backend/lib/valea_web/channels/workspace_events_channel.ex` |
| Cockpit lenient summaries | `backend/lib/valea/cockpit.ex` (`mail_summary/0`) |
| Scripted fake protocol server | `backend/test/support/` (FakeImapServer) |
| RPC/engine test conventions | `backend/test/**/mail_rpc_test.exs`, `engine_test` files |
| FE store (multi-account, push-wired, resupplyCredentials) | `frontend/src/lib/stores/mail.svelte.ts` |

## File structure (whole feature)

```
backend/lib/valea/calendar/
  ics.ex             # Task 1 — parser + expansion (pure)
  windows_zones.ex   # Task 1 — static Windows→IANA alias table
  fetch.ex           # Task 2 — HTTPS GET with pins
  settings.ex        # Task 2 — calendar.yaml v1
  store.ex           # Task 2 — index facade
  store/occurrence.ex, store/sync_state.ex   # Task 2
  source.ex          # Task 3 — .source identity file
  views.ex           # Task 3 — derived markdown views + .rev swap
  engine.ex          # Task 3 — per-source sync engine
  supervisor.ex      # Task 3 — children + per-slug lifecycle serializer
  local.ex           # Task 4 — Valea calendar (validate/list/write)
  render.ex          # Task 4 — ICS composition (served feed)
  doctor.ex          # Task 6
backend/lib/valea/api/calendar.ex              # Task 6
backend/lib/valea_web/controllers/calendar_feed_controller.ex  # Task 4
backend/priv/repo/migrations/20260718000001_create_calendar_tables.exs  # Task 2
backend/priv/workspace_template/config/calendar.yaml            # Task 2 (replaced)
backend/priv/workspace_template/sources/calendar/valea/events/.gitkeep  # Task 2
backend/test/fixtures/ics/*.ics                # Task 1
frontend/src/lib/stores/calendar.svelte.ts     # Task 7
frontend/src/lib/components/calendar/{calendar-shapes.ts,WeekGrid,MonthGrid,EventCard,
  CalendarSetupPanel.svelte,EventEditorPanel.svelte,EventPopover.svelte}  # Task 7
frontend/src/routes/calendar/+page.svelte      # Task 7 (placeholder-week.ts DELETED)
docs/ARCHITECTURE.md, docs/superpowers/acceptance/2026-07-18-calendar-feeds.md  # Task 8
```

Suggested dispatch: Tasks 1–6 to implementer subagents (Tasks 1 and 5 get opus-grade review); Tasks 7–8 controller-implemented (Spec E precedent).

---

### Task 1: ICS parser (`Valea.Calendar.Ics`) + timezone chain + fixtures

The review-critical core. Pure code, no I/O, no processes.

**Files:**
- Create: `backend/lib/valea/calendar/ics.ex`, `backend/lib/valea/calendar/windows_zones.ex`
- Create: `backend/test/valea/calendar/ics_test.exs`, `backend/test/fixtures/ics/` (fixtures listed below)
- Modify: `backend/mix.exs` (add `{:tzdata, "~> 1.1"}`), `backend/config/config.exs` (`config :elixir, :time_zone_database, Tzdata.TimeZoneDatabase`)

**Interfaces (Produces — later tasks rely on these exact names):**

```elixir
defmodule Valea.Calendar.Ics do
  defmodule Event do
    # Times are TAGGED VALUES, unresolved until expansion:
    #   {:date, %Date{}} | {:utc, %DateTime{}} | {:floating, %NaiveDateTime{}}
    #   | {:zoned, %NaiveDateTime{}, tzid :: String.t()}
    defstruct [:uid, :summary, :dtstart, :dtend, :duration, :rrule, :rdate, :exdate,
               :recurrence_id, :thisandfuture, :location, :description, :status,
               :transp, :last_modified, :sequence, :all_day]
  end

  defmodule Feed do
    defstruct events: [], total_vevents: 0, malformed: 0, notices: []
  end

  @spec parse(binary()) :: {:ok, %Feed{}} | {:error, :not_ics}
  # {:error, :not_ics} when no VCALENDAR wrapper parses at all (HTML error page).
  # A malformed VEVENT increments `malformed`, appends a notice, is skipped.

  @spec expand(%Event{}, [%Event{}], Date.t(), Date.t(), String.t()) ::
          {:ok, [occurrence], notices :: [String.t()]} | {:unsupported, reason :: String.t()}
  # expand(master, overrides_same_uid, window_from, window_to, host_zone)
  # occurrence :: %{all_day: false, start: DateTime.t(), end: DateTime.t()}   (UTC)
  #             | %{all_day: true, start_date: Date.t(), end_date: Date.t()}  (end EXCLUSIVE)
  # Window is inclusive dates; emit occurrences overlapping [from 00:00, to+1 00:00) host-zone.
  # `notices` carries unmatched-override notes (see override matching below).

  @spec resolve(tagged_time, String.t()) ::
          {:ok, DateTime.t()} | {:date, Date.t()} | {:error, :unknown_tzid}
  # The ONE timezone resolution: IANA via tzdata → WindowsZones.to_iana → :unknown_tzid.
  # DST: ambiguous → earlier instant; gap → first instant after the gap.

  @spec canonical_recurrence_id(%Event{}, String.t()) :: String.t()
  # "" for masters; UTC ISO8601 for timed; ISO date for all-day — resolved via resolve/2.

  @spec view_id(slug :: String.t(), uid :: String.t(), canonical_rid :: String.t()) :: String.t()
  # "ev-" <> first 16 hex chars of sha256(slug <> "\0" <> uid <> "\0" <> canonical_rid)

  @spec acceptable?(%Feed{}, previous_had_events? :: boolean()) ::
          :ok | {:error, :zero_parseable | :too_many_malformed}
  # {:error, :zero_parseable}    when events == [] and previous_had_events?
  # {:error, :too_many_malformed} when malformed >= 2 and malformed > 0.2 * total_vevents
end

defmodule Valea.Calendar.WindowsZones do
  @spec to_iana(String.t()) :: {:ok, String.t()} | :error
  # Static map from CLDR windowsZones supplement (territory "001" defaults),
  # e.g. "W. Europe Standard Time" => "Europe/Berlin". Full table, not a sample.
end
```

**Pinned parser semantics (spec §The ICS parser — the brief must repeat these):**
- Tokenizer: RFC 5545 unfolding (CRLF or LF, continuation = leading space OR tab), property `NAME;PARAM=val;PARAM="quoted":value` split, backslash unescaping (`\n`/`\N`, `\,`, `\;`, `\\`) applied to TEXT values only.
- Components: VCALENDAR → VEVENTs. VTIMEZONE read past, never interpreted. Unknown components/properties skipped silently.
- RRULE parts supported: FREQ (DAILY/WEEKLY/MONTHLY/YEARLY), COUNT, UNTIL, INTERVAL, BYDAY (with ordinals, e.g. `2MO`, `-1FR`), BYMONTHDAY, BYMONTH, BYSETPOS, WKST. Any other part (BYWEEKNO, BYYEARDAY, BYHOUR, …) → whole series `{:unsupported, "rrule part BYWEEKNO"}` — NO occurrences, not even DTSTART.
- `RANGE=THISANDFUTURE` on RECURRENCE-ID → set `thisandfuture: true`; expand/5 returns `{:unsupported, "THISANDFUTURE override"}` for the whole series.
- Override matching on CANONICAL INSTANTS: master occurrence times and override RECURRENCE-IDs both normalized through `resolve/2`; equality match replaces the occurrence. All-day compares as plain dates; floating only against floating. A RECURRENCE-ID matching no expanded occurrence → the override is emitted as a STANDALONE occurrence and a notice string is appended to the 3-tuple's `notices` (Task 3's Views collects those into per-source notices).
- CANCELLED override removes its occurrence; CANCELLED master → no occurrences (whole event cancelled).
- DTEND absent: DURATION if present; else timed → DTSTART (zero length is fine, grid renders minimum height — match RFC 5545 default of dtstart for DATE-TIME); all-day → start + 1 day.
- Expansion iterative, hard cap 100_000 iterations per series → `{:unsupported, "iteration cap"}`.
- EXDATE/RDATE: lists, multiple properties accumulate, resolved via `resolve/2`, EXDATE removes by canonical instant, RDATE adds.
- All-day: DATE-typed DTSTART ⇒ `all_day: true`; DATE-typed DTEND is EXCLUSIVE.
- UNTIL: per RFC, inclusive; UTC form compared as instant, DATE form as date.

**Fixtures (commit under `backend/test/fixtures/ics/`, hand-authored realistic exports):**
`google-weekly.ics` (TZID=Europe/Zurich weekly RRULE + one override + one EXDATE), `icloud-allday.ics` (multi-day all-day, DATE DTEND exclusive), `infomaniak-basic.ics`, `outlook-windows-tz.ics` (TZID="W. Europe Standard Time", BYSETPOS "second Monday" rule), `dst-boundary.ics` (Europe/Zurich series crossing both transitions, EXDATE in the ambiguous hour), `overrides-multi.ics` (master + 2 overrides + 1 cancelled override), `thisandfuture.ics`, `byweekno-unsupported.ics`, `malformed-mixed.ics` (7 VEVENTs, 3 malformed), `error-page.html`.

**Steps:**

- [ ] **Step 1: deps + config.** Add tzdata, configure `:time_zone_database`, `mix deps.get`, commit `chore(backend): add tzdata as the Elixir time-zone database`.
- [ ] **Step 2: write the test file first** — table-driven tests for every pinned semantic above: unfolding (incl. tab continuation, LF-only), escaping, param quoting, DATE/DATE-TIME (floating/Z/TZID)/DURATION parsing, each RRULE part, COUNT vs UNTIL, INTERVAL, BYDAY ordinals incl. negative, BYMONTHDAY, BYSETPOS, WKST effect on weekly w/ interval 2, EXDATE removal, RDATE addition, override replacement + cancelled override + unmatched-override notice, THISANDFUTURE unsupported, BYWEEKNO unsupported (assert NO occurrences), iteration cap, DST ambiguous→earlier + gap→after (assert exact UTC instants for Europe/Zurich 2026-10-25 02:30 and 2026-03-29 02:30), Windows TZID chain, unknown TZID → unsupported, all-day exclusive end, `view_id/3` exact value for a known input, `acceptable?/2` truth table (0-events-with-previous, 0-events-without-previous → :ok, 1-of-7 malformed → :ok, 3-of-7 → error, 2-of-2 → error, shrunk-all-parseable → :ok), fixture round-trips. Run: `mix test test/valea/calendar/ics_test.exs` — expect failures (module absent).
- [ ] **Step 3: implement `windows_zones.ex`** (full CLDR windowsZones "001" table as a module attribute map) and `ics.ex` per the interface block. Keep expansion allocation-light: generate candidate instants per FREQ, apply BYxxx filters/expansions per RFC 5545 §3.3.10 evaluation order (BYMONTH, BYMONTHDAY, BYDAY, then BYSETPOS over each interval set), then COUNT/UNTIL/window bounds.
- [ ] **Step 4: run the parser suite until green**, then the full backend suite (`mix test`) to prove no regressions.
- [ ] **Step 5: commit** `feat(backend): hand-written RFC 5545 parser + expansion with pinned timezone chain (Spec F Task 1)`.

---

### Task 2: Fetch + Settings + Store

**Files:**
- Create: `backend/lib/valea/calendar/fetch.ex`, `backend/lib/valea/calendar/settings.ex`, `backend/lib/valea/calendar/store.ex`, `backend/lib/valea/calendar/store/occurrence.ex`, `backend/lib/valea/calendar/store/sync_state.ex`, `backend/priv/repo/migrations/20260718000001_create_calendar_tables.exs`, `backend/test/support/fake_feed_server.ex`
- Create: `backend/test/valea/calendar/{fetch_test.exs,settings_test.exs,store_test.exs}`
- Modify: `backend/priv/workspace_template/config/calendar.yaml` (REPLACE legacy placeholder with v1-empty), add `backend/priv/workspace_template/sources/calendar/valea/events/.gitkeep`

**Interfaces (Produces):**

```elixir
defmodule Valea.Calendar.Fetch do
  @spec validate_url(String.t()) :: :ok | {:error, :not_https | :invalid_url}
  # THE one URL admission gate: parseable URI, scheme "https", non-empty host.
  # Consumed by Task 3's Engine.set_url and Task 6's set_calendar_source_url —
  # BEFORE any keychain write, engine state, or .source identity claim.
  @spec get(url :: String.t(), etag :: String.t() | nil, last_modified :: String.t() | nil) ::
          {:ok, %{body: binary(), etag: String.t() | nil, last_modified: String.t() | nil}}
          | :unchanged
          | {:error, :not_https | :ssrf_blocked | :cross_origin_redirect | :redirect_limit
                     | :too_large | :timeout | :tls | {:http, status :: pos_integer()}}
end

defmodule Valea.Calendar.Settings do
  defstruct sources: %{}, invalid: %{}, feed_token_hash: nil
  # sources: %{slug => %{name: String.t(), past_days: 30, future_days: 365, interval_minutes: 30}}
  # invalid: %{slug => reason} — the Valea.Mail.Settings valid/invalid split, verbatim:
  #   a structurally-broken ENTRY (bad slug grammar, malformed window/interval/name)
  #   lands here instead of failing the file; engines/status treat them per Task 6.
  #   A file carrying a `valea` source key is WHOLE-FILE invalid (spec: "a config file
  #   carrying it is invalid_config") — never half-honored.
  @spec load(root :: String.t()) ::
          {:ok, %__MODULE__{}} | {:error, :absent} | {:error, {:invalid, String.t()}}
  @spec valid_slug?(String.t()) :: boolean()   # grammar AND slug != "valea"
  @spec put_source(root, slug, name) :: :ok | {:error, term()}
  @spec remove_source(root, slug) :: :ok | {:error, term()}
  @spec generate_feed_token(root) :: {:ok, plain_token :: String.t()} | {:error, term()}
  # ONE canonical v1 rewrite path: read current state, apply the change, write the
  # whole v1 document. On a VALID v1 file, put_source/remove_source PRESERVE
  # feed.token_hash and the other sources; generate_feed_token PRESERVES sources
  # (32 bytes :crypto.strong_rand_bytes, Base.url_encode64 padding: false; persists
  # ONLY the sha256 hex; overwrite = rotation; plain token returned exactly once).
  # On an INVALID or legacy-shaped file, destructive convergence is authorized for
  # EXACTLY the spec's two entry points and nothing else (spec §Config: "the first
  # setup_calendar_source or enable_calendar_feed rewrites the file wholesale to
  # v1"): put_source and generate_feed_token replace it WHOLESALE with a fresh v1
  # carrying only their own change; remove_source is NON-destructive — it returns
  # {:error, {:invalid, reason}} and leaves the file byte-identical (there is no
  # v1 source to remove in a non-v1 file). load/1 itself NEVER rewrites anything
  # except the exact legacy placeholder below — the read path stays non-destructive.
  # Tasks 4 and 6 are consumers.
  @spec env_var(slug :: String.t()) :: String.t()   # "VALEA_CAL_URL_" <> upcased, - → _
end

defmodule Valea.Calendar.Store do
  @spec replace_source!(slug, rows :: [map()], derived_rev :: String.t(),
          etag :: String.t() | nil, last_modified :: String.t() | nil) :: :ok
  # ONE SQLite transaction: delete slug's occurrence rows, insert new, upsert sync_state
  # (etag/last_modified/last_sync_at/derived_rev, clears last_error).
  @spec derived_rev(slug) :: String.t() | nil
  @spec mark_error(slug, reason :: String.t()) :: :ok        # last_error only, mirror untouched
  @spec clear_source!(slug) :: :ok                           # purge: rows + sync_state
  @spec occurrences_overlapping(utc_start :: String.t(), utc_end :: String.t(),
          from_date :: String.t(), to_date :: String.t()) :: [map()]
  # WHERE (all_day = 0 AND occ_start < :utc_end AND occ_end > :utc_start)
  #    OR (all_day = 1 AND occ_start < :to_date AND occ_end > :from_date)
  @spec sync_meta(slug) :: %{etag: _, last_modified: _, last_sync_at: _, last_error: _} | nil
  @spec occurrence_count(slug) :: non_neg_integer()
end
```

**Pinned values:**
- Fetch: HTTPS only; manual redirects (autoredirect off), cap 3, SAME-ORIGIN (scheme+host+port) else `:cross_origin_redirect`; body cap 20 MB (streamed check); timeout 30_000 ms; conditional GET via If-None-Match/If-Modified-Since; TLS = ImapClient's verify_peer + OS CA posture. Before EVERY connect (initial + each redirect): resolve host, reject loopback/link-local/RFC1918/ULA/reserved (IPv4 + IPv6) → `:ssrf_blocked`. The URL never appears in any error/log — errors are atoms.
- Store row text formats: timed `occ_start`/`occ_end` = `YYYY-MM-DDTHH:MM:SSZ`; all-day = `YYYY-MM-DD` with `occ_end` EXCLUSIVE. Columns: `calendar_occurrences(source, uid, all_day, occ_start, occ_end, summary, location, status, view_path)` indexed on `(occ_start, occ_end)` + `(source)`; `calendar_sync_state(source PK, etag, last_modified, last_sync_at, last_error, derived_rev)`. `migrate? false` resources, hand migration mirrors the mail one.
- Settings: v1 YAML per spec §Config. `load/1` legacy-placeholder convergence is an EXACT-VALUE match, nothing looser: the parsed document must equal the known template placeholder — top-level keys exactly `{account, caldav, ics_fallback, event_types}` with `account == "mara@example.com"`, `caldav == %{url: "https://caldav.example.com/", username_env: "CALDAV_USERNAME", password_env: "CALDAV_PASSWORD"}`, `ics_fallback == %{path: "sources/calendar/import.ics"}`, and `event_types` exactly the template's three keyword lists (compare against a module-attribute copy of the shipped placeholder). Only THAT document is rewritten to v1-empty (`version: 1\nsources: {}\n`, one logged notice). EVERY other non-v1 document — empty file, partial legacy keys, altered values, anything custom — is `{:invalid, reason}`; never rewritten, never silently replaced. Defaults past 30 / future 365 / interval 30, interval floor 5.
- Template: `calendar.yaml` becomes exactly `version: 1\nsources: {}\n`; add the `valea/events/.gitkeep`.

**Steps:**

- [ ] **Step 1: tests first.** `fetch_test.exs` against `FakeFeedServer` (scripted TCP like FakeImapServer, plain HTTP locally + a TLS scenario): 200-with-etag, 304, redirect chain of 3 followed / 4 → `:redirect_limit`, cross-origin redirect rejected, oversize aborted, timeout, HTML-error-page bodies pass through (guarding is Ics/engine's job). SSRF unit tests hit the address-classifier directly (private/loopback/link-local/ULA/reserved v4+v6). `settings_test.exs`: v1 round-trip, defaults, interval floor, bad slug, `valea` slug → invalid, EXACT legacy placeholder → rewritten-once + notice, NEGATIVE convergence cases (empty document, subset of legacy keys, legacy keys with altered values, extra key added) → `{:invalid, _}` with file untouched, junk → invalid, absent → `:absent`, `generate_feed_token/1` (token is 32 bytes decoded, base64url no padding, ONLY the sha256 hex lands in the file, second call rotates the hash), MUTATION-INTERACTION cases (put_source/remove_source after a token exists → token_hash preserved; generate_feed_token with sources configured → sources preserved; EACH of put_source and generate_feed_token on an invalid-config file AND on a legacy-shaped file → wholesale fresh v1 carrying only its own change, no inherited sources or token hash; remove_source on the SAME invalid and legacy-shaped files → `{:error, {:invalid, _}}` with the file byte-identical), per-entry invalid split (one broken entry lands in `invalid` while valid entries load; a `valea` source key → whole-file `{:error, {:invalid, _}}`). `store_test.exs`: replace_source! transactional replace, derived_rev round-trip, mark_error preserves rows, clear_source!, overlap query truth table (timed straddling boundaries, all-day exclusive end, mixed).
- [ ] **Step 2: migration + resources + implementations** until green. NOTE: `FakeFeedServer`'s TLS side can reuse the dovecot/test cert helpers if present; if standing up TLS locally is disproportionate, cover TLS-failure via an `:ssl` error injection on the client seam and say so in the report.
- [ ] **Step 3: full backend suite; commit** `feat(backend): calendar fetch/settings/store foundations (Spec F Task 2)`.

---

### Task 3: Engine + Supervisor + Source identity + Views (the derive protocol)

**Files:**
- Create: `backend/lib/valea/calendar/{source.ex,views.ex,engine.ex,supervisor.ex}`
- Create: `backend/test/valea/calendar/{views_test.exs,engine_test.exs}`
- Modify: `backend/lib/valea/application.ex` (`{Registry, keys: :unique, name: Valea.Calendar.Registry}`), `backend/lib/valea/workspace/runtime.ex` (`{Valea.Calendar.Supervisor, %{root: root, generation: gen}}` beside Mail.Supervisor)

**Interfaces:**

```elixir
defmodule Valea.Calendar.Source do
  @spec verify_or_claim(dir, url) :: :ok | {:error, :identity_mismatch}
  # .source content: host <> "\n" <> first 16 hex of sha256(url) — absent → write it (claim),
  # present-and-matching → :ok, present-and-different → {:error, :identity_mismatch}.
end

defmodule Valea.Calendar.Views do
  @spec rebuild!(source_dir, slug, feed :: %Ics.Feed{}, rev :: String.t(),
          window :: {Date.t(), Date.t()}, host_zone :: String.t()) :: %{
          rows: [map()], notices: [String.t()], unsupported_series: non_neg_integer()}
  # Writes views into source_dir/views.tmp-<rand>/events/*.md + .rev file containing rev,
  # then: rename views -> views.old-<rand> (if exists), rename tmp -> views, rm -rf old.
  # (Marker checks make the non-atomic double rename safe: .rev rides INSIDE the new dir.)
  # Returns the OCCURRENCE ROWS for Store.replace_source! (uses Ics.expand/5 per master,
  # collecting unmatched-override notices + unsupported counts).
  @spec current_rev(source_dir) :: String.t() | nil     # reads views/.rev
end

defmodule Valea.Calendar.Engine do
  # {:via, Registry, {Valea.Calendar.Registry, slug}}; activation on the "workspace" topic
  # {:workspace_opened, info, generation} like Valea.Mail.Engine.
  @spec status(slug) :: map()   # state inactive|idle|syncing|degraded|identity_mismatch,
                                # last_sync_at, last_error, event_count, notices, url_present,
                                # unsupported_series (integer — Views.rebuild!'s count, updated on
                                # EVERY derive incl. activation/304 self-heal re-derives, so the
                                # spec's "N series unsupported" survives restarts and 304 runs).
                                # NOTE: `invalid_config` is NOT an engine state — engines exist
                                # only for VALID sources; invalid entries are synthesized at the
                                # API layer (Task 6) from Settings.load's `invalid` map.
  @spec sync_now(slug) :: :ok | {:error, :busy | :no_url | :not_running}
  @spec set_url(slug, url) :: :ok | {:error, term()}
  # Calls Fetch.validate_url/1 FIRST — a non-HTTPS/invalid URL is rejected with its typed
  # error BEFORE the RAM closure is stored and BEFORE Source.verify_or_claim runs, so a
  # bad URL can never bind the slug's .source identity.
  @spec with_credentials(slug, (ctx :: map() -> result)) ::
          {:ok, result} | {:error, :busy | :no_url | :not_running} when result: any()
  # The credential-safe execution seam (Task 6's Doctor is the consumer): runs `fun`
  # INSIDE the engine process (GenServer.call, generous timeout), occupying the single
  # work slot (:busy while a pass runs, and vice versa). ctx = %{url_fun:, etag:,
  # last_modified:, interval_minutes:, last_sync_at:} — the URL closure never crosses
  # a process boundary and never appears in the returned result (tested).
end

defmodule Valea.Calendar.Supervisor do
  @spec lifecycle((-> any())) :: any()
  # Serializes setup/set-url/remove/purge/rehash through the ONE supervisor process
  # (GenServer.call, generous timeout). Task 6's RPCs call this.
  @spec rehash() :: :ok        # re-read settings, start/stop engines to match
  @spec purge!(slug) :: :ok | {:error, :still_configured | term()}
  # Inside lifecycle/1: refuse if slug still configured; await any in-flight pass task;
  # re-check unconfigured; delete sources/calendar/<slug> (slug-validated +
  # Paths.resolve_real containment); Store.clear_source!(slug).
end
```

**Pinned derive protocol (the heart — brief repeats it verbatim from spec §Storage layout):**

```elixir
# rev computation (Engine):
window_from = Date.add(today_in_host_zone, -past_days)
window_to   = Date.add(today_in_host_zone,  future_days)
rev = Base.encode16(:crypto.hash(:sha256, snapshot_bytes), case: :lower)
      <> ":" <> host_zone_name
      <> ":" <> Date.to_iso8601(window_from) <> ":" <> Date.to_iso8601(window_to)
```

- A pass: conditional GET → parse → `Ics.acceptable?(feed, prev_event_count > 0)` → atomic `feed.ics` swap (tmp + fsync + rename) → derive → broadcast. Derive = `Views.rebuild!` (views swap FIRST) then `Store.replace_source!` (SQLite transaction SECOND, writes `derived_rev = rev`).
- ACTIVATION derives UNCONDITIONALLY: parse the committed `feed.ics` (if present) and rebuild views + index from it, no marker consultation — the spec's "activation always re-derives views + index from `feed.ics` unconditionally". This is what repairs out-of-band damage to engine-owned files even when both markers still match.
- EVERY subsequent pass — including 304 `:unchanged` — runs the marker check: compute `rev` from the CURRENT `feed.ics` bytes + today's window; if `Views.current_rev != rev` OR `Store.derived_rev(slug) != rev` → re-derive both stores from `feed.ics`. This heals crashes between swaps, failed derives behind 304s, host-zone changes, day rollover, and window-config changes.
- `prev_event_count` and `unsupported_series` live in engine state, seeded by activation's unconditional derive (absent `feed.ics` → 0/0).
- Any failure (fetch error, `{:error, :not_ics}`, acceptance guard) → `Store.mark_error` + degraded status; mirror/views/index untouched; next tick retries. Single in-flight pass (monitored Task, mail shape). Poll timer per source `interval_minutes`.
- Broadcasts on the workspace PubSub: `{:calendar_status_changed, slug, status_map}`, `{:calendar_synced, slug, %{event_count: n}}`.

**Steps:**

- [ ] **Step 1: `views_test.exs` + `source` tests first** — view frontmatter CONDITIONAL schema: common exact keys `uid, source, summary, start, end, all_day, location, status, recurring, rrule, recurrence_id` (`recurrence_id` = the raw RECURRENCE-ID string, empty for masters, per spec §Storage layout "the real UID and raw RECURRENCE-ID live in the view's frontmatter"; same yaml escaping as `Valea.Mail.Views`); an UNSUPPORTED-series view carries ADDITIONALLY — and only then — `recurrence_unsupported: true` (supported views OMIT the key entirely; write separate exact-frontmatter assertions for a supported and an unsupported view). DESCRIPTION as body, one file per master incl. per-override files at distinct `Ics.view_id` paths (tests assert the master's empty `recurrence_id` and each override's RAW value), unsupported-series view keeps the raw rule and produces NO index rows, `.rev` written inside the swapped dir, double-rename replace, hostile UID never in a filename. Then `engine_test.exs` covering EVERY spec §Testing engine case: activation/identity (claim, mismatch → inert), replace-mirror (shrunken feed removes rows+views), degraded-keeps-mirror, zero-parseable guard, partial-damage guard (populated mirror SURVIVES 1-valid+3-malformed; shrunken all-parseable replaces), single-flight, per-source isolation, crash self-heal (kill between feed.ics swap and derive → next activation converges), UNCONDITIONAL-activation repair (markers both CURRENT but a view file deleted / an index row removed out-of-band → activation restores both stores; a subsequent 304 pass keeps them intact), stale-derive repair THROUGH a 304, two-store checks (kill between views swap and SQLite commit → mismatch → re-derive; and the inverse), host-zone change re-derive, ROLLING-WINDOW re-derive (advance the clock past the future boundary under continuing 304s → day-quantized rev mismatch → rows roll in/out), window-config change re-derive, purge-vs-degraded serialization (remove → in-flight pass awaited → purge → no resurrection), `set_url` HTTPS admission (http URL → typed error, NO `.source` file created, no closure stored), `with_credentials` (mutual exclusion with a pass; result carries no URL), and a supported→unsupported transition (feed update swaps a supported RRULE for BYWEEKNO → `unsupported_series` increments in status, occurrences drop). Inject clock + zone via engine opts (e.g. `now_fun`, `zone_fun`) so tests don't sleep.
- [ ] **Step 2: implement** `source.ex`, `views.ex`, `engine.ex`, `supervisor.ex`, runtime/application wiring, until green.
- [ ] **Step 3: full backend suite; commit** `feat(backend): calendar sync engine with two-store derive marker (Spec F Task 3)`.

---

### Task 4: Valea calendar (Local) + ICS render + served feed

**Files:**
- Create: `backend/lib/valea/calendar/local.ex`, `backend/lib/valea/calendar/render.ex`, `backend/lib/valea_web/controllers/calendar_feed_controller.ex`
- Create: `backend/test/valea/calendar/{local_test.exs,render_test.exs}`, `backend/test/valea_web/calendar_feed_controller_test.exs`
- Modify: `backend/lib/valea_web/router.ex` (token-exempt `get "/calendar/feed.ics", CalendarFeedController, :feed` — its own scope, modeled on the files `:serve` scope's pipeline arrangement)

**Interfaces:**

```elixir
defmodule Valea.Calendar.Local do
  defmodule Event do
    defstruct [:name, :path, :title, :start, :end, :all_day, :location, :status,
               :description, :mtime]
    # timed: start/end are %DateTime{} (offset preserved from file, UTC-normalized for index use)
    # all-day: start/end are %Date{}, end EXCLUSIVE
    # mtime: the file's modification time as a UTC %DateTime{} truncated to seconds —
    #   populated by list/1's lstat; Render consumes it for DTSTAMP + LAST-MODIFIED.
  end
  @spec list(root) :: %{valid: [%Event{}], invalid: [%{name: _, reason: String.t()}]}
  # Live read of sources/calendar/valea/events/*.md — lstat no-follow, fail-closed per file.
  @spec valid_name?(String.t()) :: boolean()
  # bare basename, no extension: ^[a-z0-9][a-z0-9._-]{0,79}$ and no ".." segment —
  # rejected BEFORE any path construction (the get_mail_draft posture).
  @spec write(root, name, attrs, mode :: :create | :update) ::
          {:ok, rel_path} | {:error, :exists | :not_found | {:invalid, String.t()}}
  @spec delete(root, name) :: :ok | {:error, :not_found}
  @spec uid(name :: String.t()) :: String.t()
  # "valea-" <> first 16 hex of sha256(name <> ".md") <> "@valea.local"  (basename incl. ext)
end

defmodule Valea.Calendar.Render do
  @spec feed([%Local.Event{}]) :: binary()
  # One VCALENDAR (VERSION:2.0, PRODID:-//Valea//Calendar//EN, CALSCALE:GREGORIAN);
  # per event: UID, DTSTAMP + LAST-MODIFIED (both = the event's `mtime` field, rendered
  # as UTC "YYYYMMDDTHHMMSSZ"), SUMMARY, DTSTART/DTEND
  # (timed: UTC "...Z" form; all-day: ;VALUE=DATE, end exclusive), LOCATION?, STATUS
  # (upcased), DESCRIPTION (body). TEXT values RFC 5545-escaped (\\ \; \, \n),
  # lines folded at 75 octets (CRLF + single space), UTF-8 boundary-safe.
  # Composition from validated struct fields ONLY — agent text can never smuggle
  # raw properties/components (DraftMime posture inverted).
end
```

**Pinned validation (Local, fail-closed — brief carries spec §The Valea calendar verbatim):** unknown frontmatter keys reject; control chars reject in every field (body: newlines/tabs allowed, other C0 reject); `title` required non-empty ≤ 500 chars; timed `start` ISO 8601 WITH offset, `start < end`, `end` default start+1h; `all_day: true` ⇒ plain dates, `end` EXCLUSIVE and STRICTLY > start (equal dates reject), default start+1 day; `status` ∈ confirmed|tentative|cancelled (default confirmed); body ≤ 16 KB (16_384 bytes); symlink/hard-link → reject unread. Invalid files are listed with reasons, rendered NOWHERE.

**Feed endpoint:** the controller only READS the stored hash (`Settings.load/1` → `feed_token_hash`) and compares `Plug.Crypto.secure_compare(sha256(param), stored_hash)`; no token configured / missing / mismatch / any error → 404 empty body, no detail; NO other parameters honored; serves ONLY `Render.feed(valid valea events)` with `content-type: text/calendar; charset=utf-8`. Enable/rotate EXCLUSIVELY call `Valea.Calendar.Settings.generate_feed_token/1` — produced and tested in Task 2; this task and Task 6 only consume it; no second token-mutation path exists.

**Steps:**

- [ ] **Step 1: tests first.** `local_test.exs`: the full validation table above + UID stability across edits (rename = new UID) + create-refuses-existing + name grammar rejects (`../x`, `a/b`, `.hidden`, 81 chars, uppercase OK? — NO: grammar is lowercase-only per the regex; assert). `render_test.exs`: escaping (agent text `X;Y,Z\nBEGIN:VEVENT` stays inert TEXT), folding at 75 octets incl. multi-byte boundary, all-day VALUE=DATE exclusive end, cancelled status renders, DTSTAMP + LAST-MODIFIED both equal a controlled file mtime rendered `YYYYMMDDTHHMMSSZ` (set the fixture file's mtime with `File.touch!/2`). Controller test: valid token 200 + content-type, wrong/missing/extra-param/disabled → 404, constant-time compare used, rotate invalidates old.
- [ ] **Step 2: implement + green; full backend suite.**
- [ ] **Step 3: commit** `feat(backend): valea local calendar, ICS render, tokened served feed (Spec F Task 4)`.

---

### Task 5: Mounts + PermissionPolicy calendar tier + managedSettings (opus-grade review)

**Files:**
- Modify: `backend/lib/valea/mounts.ex`, `backend/lib/valea/agents/session_scope.ex`, `backend/lib/valea/agents/permission_policy.ex`, `backend/lib/valea/agents/session_settings.ex`
- Test: extend the existing policy/mounts/session-scope suites (find them via `grep -rl "mail_denied\|kind: :mail" backend/test`)

**Interfaces (Produces):**
- `Mounts.list/1` appends, whenever `<root>/config/calendar.yaml` EXISTS (any content — validity is status, not availability): `%{name: "calendar", root: <abs sources/calendar>, manifest: nil, enabled: true, degraded: nil, kind: :calendar}`. `unique_mount_key` reserves `"calendar"`.
- Every existing `kind == :mail` exclusion (cockpit sections, watcher ICM events, doctor, global search, Knowledge/editor/ICM-mutation targets, `files_controller` resolve_mount, primary-ICM selection) generalizes to "synthetic non-ICM" — mechanically: flip `== :mail` / `!= :mail` comparisons to `!= :icm` / `== :icm` where the intent is icm-vs-synthetic. AUDIT EVERY SITE: `grep -rn ":mail" backend/lib | grep -i "kind"` and decide each one; a site that is genuinely mail-only (e.g. mail engine lookups) stays.
- `session_scope.ex` `resolve_include_mounts/2`: accepted kinds become `[:mail, :calendar]` (generalized "synthetic, non-ICM mount kind"); ICM-key rejection stays. Bare-string `"calendar"` in `related_icms` works exactly like `"mail"` does today.
- `PermissionPolicy`: new calendar tier directly AFTER the mail tier in `evaluate`'s cond (order: denied → protected → icm_secret → mail → calendar → escaped → ask/allow). Extract the shared helpers mail already has (`casefold/1`, `casefold_under_root?/2`, `split_real/1` usage) — extraction means calendar CALLS the same private helpers in the same module; do NOT duplicate their bodies. Semantics:

```elixir
# ctx gains: calendar_in_scope? :: boolean(), and the territory root is
# workspace_root/sources/calendar (casefolded, resolved) — one mount, so no per-slug lists.
defp calendar_denied?({:ok, path}, kind, territory_root, in_scope?) do
  cf = casefold(path)
  cond do
    not casefold_under_root?(cf, territory_root) -> false
    not in_scope? -> true                                    # DENY, never ask
    write_kind?(kind) ->                                     # writes ONLY under valea/events/
      not casefold_under_root?(cf, territory_root <> "/valea/events")
    true -> false                                            # reads allowed everywhere in scope
  end
end
```

- `session_settings.ex` managedSettings mirror: out-of-scope session → deny `Read`+`Edit`+`Write` on `sources/calendar/**`. In-scope → mirror "everything except `valea/events/**` is write-denied" by ENUMERATION at settings-build time (deny always beats allow in the settings model, so an exception can't be carved with an allow rule): for every name in (configured source slugs ∪ `File.ls` of `sources/calendar/`) minus `valea`, deny `Edit`+`Write` on `sources/calendar/<name>/**` — the wholesale per-directory glob covers `.source`, `feed.ics`, `views/**`, AND crash leftovers like `views.tmp-*`/`views.old-*` and removed-but-unpurged slug dirs; plus deny `Edit`+`Write` on `sources/calendar/*` and `sources/calendar/valea/*` (both non-recursive — stray top-level files; `valea/events/*.md` stays writable because those paths match neither glob). The snapshot is per-session-start like the rest of managedSettings; PermissionPolicy remains the authoritative gate for anything appearing mid-session.

**Steps:**

- [ ] **Step 1: tests first** — the mail deny-suite shape for calendar: unmounted session deny-not-ask (incl. casefold + NFD variants, symlink-resolved paths), in-scope write allowed ONLY under `valea/events/` (deny `.source`, `feed.ics`, `views/x.md`, `sources/calendar/stray.txt`), in-scope reads allowed on views + feed.ics, managedSettings mirror snapshot both postures (in-scope: a configured slug's `views.tmp-crash/events/x.md` and a removed-but-unpurged leftover dir's files are BOTH write-denied by the enumeration; `valea/events/x.md` is not), mounts appear/disappear on calendar.yaml existence, include_mounts accepts `"calendar"` + still rejects ICM keys, and the EMPTY-WORKSPACE BOOTSTRAP: fresh template workspace + opted-in session can create its first `valea/events/x.md` through the normal write path.
- [ ] **Step 2: implement; audit every `kind` site (list them in the report); green; full backend suite.**
- [ ] **Step 3: commit** `feat(backend): calendar mount + permission tier with mail deny semantics (Spec F Task 5)`.

---

### Task 6: RPC surface + Doctor + Cockpit + channel pushes + codegen

**Files:**
- Create: `backend/lib/valea/api/calendar.ex`, `backend/lib/valea/calendar/doctor.ex`
- Create: `backend/test/valea/api/calendar_rpc_test.exs`, `backend/test/valea/calendar/doctor_test.exs`
- Modify: `backend/lib/valea/api.ex` (register resource), `backend/lib/valea/cockpit.ex` (calendar line), `backend/lib/valea_web/channels/workspace_events_channel.ex` (3 handlers), regenerate `frontend/src/lib/api/` (codegen)

**`calendar_status` synthesis (pin — mirrors `Valea.Api.Mail.mail_status_accounts/1` verbatim):** valid sources → `Engine.status/1` stringified + `"valid" => true`; each `Settings.load` `invalid` entry → `%{"source" => slug, "valid" => false, "state" => "invalid_config", "reason" => reason}`; entries sorted by `"source"`. Whole-file `{:error, {:invalid, reason}}` → `"sources" => []` plus top-level `"config_invalid" => reason` (string | nil, nil whenever the file is absent/valid); the calendar mount stays available throughout (availability keys on file EXISTENCE — Task 5). Top-level shape: `"sources"`, `"feed_enabled"` (string key, boolean), `"valea_event_count"`, `"config_invalid"`.

**The 13 actions — implement EXACTLY the spec §RPC surface table (the brief includes the table verbatim).** Conventions from `Valea.Api.Mail`: string falsy keys, `generation` + `check_generation` on every mutating action, slug grammar validated before ANY I/O (`Settings.valid_slug?/1` — which already embeds the `valea` reservation), `url` argument `sensitive? true`, `list_calendar_events`' `zone` validated against the tz database (invalid → error, never a silent default). Mutating lifecycle actions run through `Valea.Calendar.Supervisor.lifecycle/1`. `purge_calendar_source_files` additionally requires typed `confirmation == slug` and refuses any non-configured-external target. `create/update/delete_valea_event` go through `Local.write/4` / `Local.delete/2` with `Local.valid_name?/1` first; delete takes typed `confirmation == name`; all three fire `{:calendar_local_changed}`. `enable_calendar_feed`/`rotate_calendar_feed_token` call `Settings.generate_feed_token/1` (Task 4) and return the plain token once.

**`list_calendar_events` (pin, from the spec row):** half-open `[from, to)` interpreted in `zone`; zone boundaries resolved with the Task-1 DST rules; timed rows by OVERLAP (`occ_start < zone_end AND occ_end > zone_start`), all-day by date-range overlap `[start,end)` vs `[from,to)`; valea events merged live (`Local.list/1`, same overlap rules, timed events UTC-normalized); ordered chronologically IN `zone` — per local day: all-day rows first, then timed by local start.

**THE occurrence wire schema (single source of truth — Task 7 consumes exactly this; string keys, snake_case, no camelCase translation, per the `Valea.Api.Mail` convention):**

```
CalendarOccurrence = {
  "source":      string,                 // slug, or "valea"
  "all_day":     boolean,                // the shape discriminator
  "start":       string,                 // all_day=false: "YYYY-MM-DDTHH:MM:SSZ" (UTC)
  "end":         string,                 //   all_day=true: "YYYY-MM-DD" plain dates, end EXCLUSIVE
  "summary":     string,                 // external SUMMARY; valea `title` NORMALIZED to this key
  "location":    string | null,
  "status":      "confirmed" | "tentative" | "cancelled",
  "description": string | null,          // valea: file body; external: HYDRATED at query time by
                                         //   reading the view file body for rows in range (SQLite
                                         //   stores NO description column — spec's pinned columns)
  "view_path":   string | null,          // external rows: workspace-relative view file path
  "path":        string | null           // valea rows: workspace-relative event file path
}
```

RPC serialization tests assert this exact shape for one external timed, one external all-day, and one valea row.

**Doctor:** per source, sequential, gated: `config_present` → `url_present` (keychain closure or env) → `reachable` (conditional GET, reports status class + TLS) → `parse_ok` (parseable count + per-component notices) → `freshness` (last successful sync age vs 2× interval). The network-touching checks run through `Engine.with_credentials/2` (Task 3's credential-safe seam) — Doctor NEVER reads the keychain/env itself and holds the URL only inside the engine-executed closure; a source with no running engine reports `url_present` failed with the resupply remedy (checks after the failed gate don't run). Plus `feed_endpoint` (token configured + route answering — loopback self-request). Every check carries a copyable remedy; NO URL ever appears in any check detail/remedy/error string — a dedicated test greps the full doctor output for the fixture URL's host and token.

**`set_calendar_source_url` admission:** calls `Fetch.validate_url/1` FIRST — `:not_https`/`:invalid_url` are returned as typed errors before any keychain interaction, engine call, or `.source` claim (RPC test proves an `http://` URL leaves no `.source` file and no engine state behind).

**Cockpit:** `today()` gains `"calendar" => %{"events_today" => n, "next" => %{"time" => "09:30", "title" => t} | nil}` — computed via the same query path as `list_calendar_events` for host-zone today, lenient like `mail_summary/0` (any failure → `nil` entry, never crashes today()).

**Channel:** `{:calendar_status_changed, slug, status}` → push `"calendar_status"` (stringified, + `"source" => slug`); `{:calendar_synced, slug, %{event_count: n}}` → push `"calendar_synced"` `%{"source" => slug, "event_count" => n}` (SNAKE_CASE `event_count` — the spec's channel table is the wire contract; do NOT follow mail's camelCase push style here, and the channel test asserts the snake key); `{:calendar_local_changed}` → push `"calendar_local_changed"` `%{}`.

**Steps:**

- [ ] **Step 1: tests first** — the mail_rpc_test shape for every action: happy path, generation guard, slug grammar rejects incl. `valea` on setup/set-url/purge, purge refusals (still-configured; unconfigured-but-never-existed), typed confirms, the END-TO-END new-source sequence (`setup_calendar_source` → engine running with `url_present: false` → `set_calendar_source_url` → `url_present: true` + `.source` claimed; and the reject leg: an `http://` URL after setup → typed error, no `.source`, `url_present` stays false), `calendar_status` invalid-config synthesis (per-entry invalid_config entries; whole-file invalid → `"sources" => []` + `"config_invalid"` reason while the action still succeeds), `list_calendar_events` range tests (timed event straddling range start INCLUDED; UTC-date-vs-local-date boundary event lands on the correct local day for a negative-offset zone; all-day exclusive-end overlap; mixed ordering all-day-first), invalid `zone` rejected, doctor check gating + no-URL-in-output, cockpit line presence + leniency, channel push shapes.
- [ ] **Step 2: implement; run codegen; commit BEFORE `just test` (codegen-freshness gate diffs `../frontend/src/lib/api/`).**
- [ ] **Step 3: full `just test` (all four gates); commit** `feat(backend): calendar RPC surface, doctor, cockpit line (Spec F Task 6)`.

---

### Task 7: Frontend — store, adapter, grids, route, setup panel, editor (controller-implemented)

**Files:**
- Create: `frontend/src/lib/stores/calendar.svelte.ts` (+ `calendar.test.ts`), `frontend/src/lib/components/calendar/{CalendarSetupPanel.svelte,EventEditorPanel.svelte,EventPopover.svelte}`
- Modify: `frontend/src/lib/components/calendar/{calendar-shapes.ts,calendar-shapes.test.ts,WeekGrid.svelte,MonthGrid.svelte,EventCard.svelte}`, `frontend/src/routes/calendar/+page.svelte`
- Delete: `frontend/src/lib/components/calendar/placeholder-week.ts`

**Interfaces:**

```ts
// calendar-shapes.ts — the adapter (spec §UI, verbatim contract).
// CalendarOccurrence is EXACTLY Task 6's pinned wire schema (string keys, snake_case:
// source / all_day / start / end / summary / location / status / description /
// view_path / path) — type it from that block, and build test fixtures from it.
export function occurrenceToGridEvents(row: CalendarOccurrence, hostZone: string):
  { segments: GridEvent[]; allDay: AllDayEntry[] }
// TIMED rows: UTC instants → host-local wall time, split multi-day occurrences into one
// GridEvent per local day (existing contract: day / startMin / endMin / kind).
// ALL-DAY rows: plain dates used DIRECTLY (no zone conversion), [start, end) exclusive
// split into per-day AllDayEntry, routed to the grids' NEW all-day lane.
// kind mapping: external+confirmed → "booked", external+tentative → "hold",
// valea → "block". (CANCELLED external occurrences never arrive; valea cancelled
// events render struck-through in the all-day lane/segment.)

// CalendarStore (mail.svelte.ts pattern): sources status, visible-range events,
// load(from, to, zone), push wiring (calendar_status / calendar_synced /
// calendar_local_changed → targeted refresh), create/update/deleteValeaEvent,
// setup actions — the ONE add-source sequence, in this exact order:
//   1. setupCalendarSource(slug, name)   → config write + supervisor rehash; the engine
//      starts URL-less (status url_present: false — a valid engine state, not an error)
//   2. setCalendarSourceUrl(slug, url)   → the engine EXISTS now; Fetch.validate_url
//      gates admission, then RAM closure + .source claim
//   3. keychainSet(workspaceId, `${slug}:ics`, url) ONLY on step-2 success — a rejected
//      URL never reaches the keychain.
// Keychain-write FAILURE at step 3 is non-fatal and retryable: the engine keeps its RAM
// closure (source works for this session); the panel shows a "URL not durably stored —
// retry" warning; after a restart url_present is false and the standard resupply prompt
// asks again — re-entering the SAME URL re-matches the .source identity (verify_or_claim
// → :ok), so no rollback of the claim is needed or wanted; a DIFFERENT URL is the normal
// identity_mismatch → purge path.
// [This order is the AMENDED spec §UI Setup panel text (spec fix committed alongside
// plan wave 8) — the spec itself now pins setup → set-url → keychain-on-acceptance.]
// removeCalendarSource, purgeCalendarSourceFiles,
// calendarSyncNow, calendarDoctor, enable/rotateCalendarFeedToken),
// resupplyCredentials analog on workspace open (per-slug `:ics` keychain reads).
```

- `WeekGrid`/`MonthGrid`: new all-day lane row; all three components gain `onSelect(event)` prop (today they have none).
- Route: real data via CalendarStore; rail = source legend (deterministic color per slug — hash slug → hue) + upcoming-events list; external event select → read-only `EventPopover` (title, local time, location, source, description); valea select → popover + Edit/Delete; "New event" → `EventEditorPanel` (title, start/end or all-day toggle speaking INCLUSIVE dates and converting to/from exclusive at the RPC boundary, location, description) → `create_valea_event`. Replace the stale route comment referencing the deleted approval queue.
- `CalendarSetupPanel`: source list with per-source status/doctor/typed-confirm purge — the status line renders the spec-mandated "N series unsupported" whenever `unsupported_series > 0` (the field rides Engine.status through `calendar_status`) — add-source form (slug, name, URL → `set_calendar_source_url` first, keychain on success — see the store's admission-order note), served-feed block (enable, URL + copy, rotate, and the honest reachability copy: local calendar apps can subscribe; server-side fetchers — iCloud/Google/Outlook.com — cannot reach loopback, so no phone propagation in this phase). Store test: a source status with `unsupported_series: 2` renders the notice.

**Steps:**

- [ ] **Step 1: vitest first** for the adapter (UTC→local split across a day boundary in a non-UTC zone, multi-day timed split, all-day exclusive split, kind mapping, DST-day segment lengths) and the store (merge/refresh on pushes, editor inclusive↔exclusive round-trip, feed block state, invalid-config rendering: `invalid_config` source entries and a `config_invalid` reason surface in the setup panel while the route stays usable; the add-source sequence: setup → set-url → keychain in order, an RPC-rejected URL never triggers keychainSet, and a mocked keychainSet failure produces the retryable warning state without losing the accepted source).
- [ ] **Step 2: implement store + adapter + components + route; delete `placeholder-week.ts`.**
- [ ] **Step 3: `bun run check` (0/0) + `bun run test`; full `just test`; commit** `feat(frontend): calendar route on real data with setup panel and event editor (Spec F Task 7)`.

---

### Task 8: Docs + acceptance checklist + final gates (controller-implemented)

**Files:**
- Modify: `docs/ARCHITECTURE.md` (Calendar section per spec §Change map — subsystem shape, derive protocol, mount/policy posture, served-feed reachability honesty), keychain docs wherever `<slug>:imap` is documented (add `<slug>:ics`)
- Create: `docs/superpowers/acceptance/2026-07-18-calendar-feeds.md`

**Steps:**

- [ ] **Step 1: ARCHITECTURE.md + keychain docs** (grep for `:imap` across docs/ and desktop/ to find every site).
- [ ] **Step 2: acceptance checklist** from spec §Execution notes: subscribe a real Google secret address + one iCloud/Infomaniak feed; verify recurring events against the provider's UI for a known week (incl. an override and an all-day span); create a Valea event via UI and via an agent session file-write; subscribe Calendar.app "On My Mac" to the served feed and see it; rotate the token and confirm the old URL dies; restart resupply (keychain) drill; degraded-feed drill (break the URL, confirm mirror intact + doctor remedy).
- [ ] **Step 3: full `just test`; grep gates** (`grep -rn "placeholder-week" frontend/src` → empty; `grep -rn "approval queue\|dedicated Calendar phase" frontend/src` → empty; `grep -rn "caldav" backend/priv/workspace_template` → empty); commit `docs: calendar architecture section + live-acceptance checklist (Spec F Task 8)`.

---

## Final gate

Whole-branch review (opus-grade) against the spec with the run ledger's deferred-minors list, then the finishing-a-development-branch gate. Live acceptance (the Task 8 checklist) is executed by Daniel post-merge.
