# Tasks & Schedules Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Per-ICM `tasks.json`/`schedules.json` ledgers rendered and (for
schedules) executed by Valea — internal scheduler on persisted anchors,
two-layer consent gate, materialized agent briefing, Tasks UI.

**Architecture:** Plain JSON files at each ICM root are the only truth for
declarations; a per-workspace `Valea.Schedules.Scheduler` GenServer re-reads
them every tick and fires prompt sessions (kind `"scheduled"`) or commands,
with all runtime state (anchors, fingerprints, run history) in the
workspace SQLite. Consent for agent-registered schedules rides the
existing permission machinery at two layers (PermissionPolicy tier +
managedSettings mirror). Agents learn the contract from a
Valea-materialized `.valea/briefing.md` (mail `AgentsFile` pattern).

**Tech Stack:** Elixir/Phoenix + Ash (RPC via ash_typescript codegen),
AshSqlite per-workspace Repo, SvelteKit 5 + vitest frontend.

**Spec:** `docs/superpowers/specs/2026-07-29-tasks-schedules-design.md`
(approved at abac6f9 after 4 Codex rounds). Where this plan and the spec
disagree, the spec wins.

## Global Constraints

- File-first invariant: every durable *fact* is a plain file the user owns;
  Valea-side SQLite holds only meta (anchors, run history, caches).
- Agent containment: all path reasoning through `Valea.Paths.resolve_real/2`;
  NEVER weaken `Valea.Agents.PermissionPolicy` — new tiers only add denies/asks.
- Cockpit payloads use STRING keys throughout (JSON-ready; `Valea.Cockpit` convention).
- Leniency split (spec §Leniency): display fields lenient, execution-control
  fields strict and fail closed per entry.
- Unknown JSON fields are preserved on every Valea write (round-trip).
- All Valea-side ledger mutations go through one serialized writer; writes are
  atomic temp+rename with content-hash verify + bounded re-apply (3 retries).
- Scheduler state key is `(icm_id, schedule_id)` where `icm_id` = `manifest.id`;
  `mount_key` is display metadata only.
- Fingerprint = SHA-256 over canonical (key-sorted) JSON of exactly
  `{"catchup", "cron", "payload", "timezone"}`. Not `id`, not `paused`, not display fields.
- Anchors are monotonic: `last_attempted_slot` never decreases.
- Cron: 5-field + `@hourly/@daily/@weekly/@monthly`; Vixie DOM/DOW OR-rule;
  DST gap → first valid instant after; ambiguous → first occurrence.
- Command payloads: exec-style (never a shell string), cwd = ICM root,
  10-minute timeout, output cap 262_144 bytes.
- Scheduled sessions: `kind: "scheduled"`, excluded from session lists by default.
- Session preamble (verbatim, spec §Run lifecycle):
  `Scheduled run "<title>" (<schedule_id>) in <icm_name>. You are running unattended; if you get blocked, record what's needed in tasks.json and end the session.`
- Backend formatting: the repo's mix-format hook handles `.ex` — do not fight it.
  Frontend has NO prettier — never run it.
- Full gate: `just test` (backend mix test → codegen freshness → `bun run check` → `bun run test`).
- Accepted residual risks #1–#6 (spec §Decisions) are settled: do NOT add
  hash-pinning, cross-workspace leases, task-delete detection, or lock files.

---

### Task 1: Ledger core — serialized writer, lenient JSON file, task semantics, archive

**Files:**
- Create: `backend/lib/valea/ledger/json_file.ex`
- Create: `backend/lib/valea/ledger/writer.ex`
- Create: `backend/lib/valea/tasks.ex`
- Test: `backend/test/valea/ledger/json_file_test.exs`
- Test: `backend/test/valea/tasks_test.exs`

**Interfaces:**
- Consumes: `Valea.Yaml` NOT used (these are JSON); `Jason` (already a dep).
- Produces (later tasks rely on these exact signatures):
  - `Valea.Ledger.JsonFile.read(path, list_key) :: {:ok, %{doc: map(), entries: [map()], hash: binary()}} | :absent | {:error, :unreadable}`
  - `Valea.Ledger.JsonFile.write(path, doc :: map(), expected :: binary() | :absent) :: :ok | {:error, :conflict}` — canonical-ish encode (`Jason.encode!(doc, pretty: true)` + trailing newline), temp+rename, hash re-check just before rename.
  - `Valea.Ledger.Writer.exec(fun :: (-> term())) :: term()` — GenServer.call serializing ALL Valea-side ledger mutations for the open workspace (stricter than the spec's per-ICM minimum, which is allowed).
  - `Valea.Tasks.list(icm_root) :: %{status: :ok | :absent | :unreadable, tasks: [map()]}`
  - `Valea.Tasks.create(icm_root, fields :: map()) :: {:ok, map()} | {:error, term()}`
  - `Valea.Tasks.patch(icm_root, task_id :: String.t(), patch :: map()) :: {:ok, map()} | {:error, :not_found | :conflict | :unreadable}`
  - `Valea.Tasks.archive_done(icm_root) :: {:ok, %{archived: non_neg_integer()}}`
  - `Valea.Tasks.sweep(icm_root) :: {:ok, %{archived: non_neg_integer()}}` — auto-archive `done`/`dropped` entries whose `done_at`/`updated_at` is > 14 days old.
  - `Valea.Tasks.snapshot_hash(task :: map()) :: String.t()` — lowercase hex SHA-256 of key-sorted `Jason` encoding.

- [ ] **Step 1: Failing tests for `JsonFile` leniency + conflict contract**

```elixir
# backend/test/valea/ledger/json_file_test.exs
defmodule Valea.Ledger.JsonFileTest do
  use ExUnit.Case, async: true
  alias Valea.Ledger.JsonFile

  setup do
    dir = Path.join(System.tmp_dir!(), "ledger-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{path: Path.join(dir, "tasks.json")}
  end

  test "absent file", %{path: path}, do: assert(JsonFile.read(path, "tasks") == :absent)

  test "malformed json is :unreadable", %{path: path} do
    File.write!(path, "{not json")
    assert JsonFile.read(path, "tasks") == {:error, :unreadable}
  end

  test "non-map entries dropped, unknown fields survive round-trip", %{path: path} do
    File.write!(path, ~s({"readme":"x","tasks":[{"id":"t-1","custom":{"a":1}},42]}))
    {:ok, %{doc: doc, entries: [entry], hash: hash}} = JsonFile.read(path, "tasks")
    assert entry["custom"] == %{"a" => 1}
    :ok = JsonFile.write(path, put_in(doc, ["tasks"], [Map.put(entry, "title", "T")]), hash)
    {:ok, %{entries: [e2]}} = JsonFile.read(path, "tasks")
    assert e2["custom"] == %{"a" => 1} and e2["title"] == "T"
    # top-level unknown key preserved too
    assert Jason.decode!(File.read!(path))["readme"] == "x"
  end

  test "write with stale hash is :conflict", %{path: path} do
    File.write!(path, ~s({"tasks":[]}))
    {:ok, %{doc: doc, hash: hash}} = JsonFile.read(path, "tasks")
    File.write!(path, ~s({"tasks":[{"id":"t-9"}]}))
    assert JsonFile.write(path, doc, hash) == {:error, :conflict}
  end
end
```

- [ ] **Step 2: Run to verify failure** — `cd backend && mix test test/valea/ledger/json_file_test.exs` → module undefined.

- [ ] **Step 3: Implement `JsonFile` + `Writer`**

`json_file.ex`: `read/2` — `File.read` → `:absent` on `:enoent`, `{:error, :unreadable}` on any other error or `Jason.decode` failure or non-map top level; `entries` = `doc[list_key]` filtered `is_map/1` (wrong-typed/missing list → `[]` but keep `doc` as-is); `hash` = `:crypto.hash(:sha256, raw)`. `write/3` — encode pretty + `"\n"`, `File.mkdir_p!` parent, write `path <> ".tmp"`, then re-read current file hash (`:absent` matches enoent) and compare to `expected`; on match `File.rename!`, else delete tmp and `{:error, :conflict}`. Document (moduledoc): the check-to-rename window is accepted residual risk #5 — callers retry via `Writer`.

`writer.ex`: plain GenServer, `name: __MODULE__`, `exec(fun)` = `GenServer.call(__MODULE__, {:exec, fun}, 30_000)`; handle_call runs `fun.()`. Started under Workspace Runtime (Task 4 adds it to the children list together with the schedules supervisor — until then tests start it manually with `start_supervised!`).

- [ ] **Step 4: Failing tests for `Valea.Tasks`** — cover: `create` on absent file materializes the skeleton (`readme` per spec + `tasks` array) and generates `"t-" <> 6-hex` id, stamps `created_at`/`updated_at` (UTC ISO), default `status: "open"`, `created_by: "user"`; `patch` retries against a concurrently rewritten file by re-applying to the fresh entry (simulate: patch fun writes the file mid-flight once via `:meck`-free approach — instead test the public behavior: patch after external rewrite still lands and preserves the external sibling entry); `patch` on vanished id → `{:error, :not_found}`; `archive_done` appends JSONL lines shaped `%{"archive_event" => uuid, "archived_at" => iso, "snapshot_hash" => hex, "task" => task}` to `.valea/task-archive.jsonl` FIRST then prunes; **snapshot-conditional prune**: mark done → run archive with the ledger entry mutated between append and prune (drive via two-phase: call `archive_done` once, then reopen the task, then `archive_done` again — reopened entry must survive and archive must hold one line per distinct snapshot hash); partial trailing line in archive tolerated; `sweep/1` archives only >14-day-old done/dropped (inject clock via optional `now:` opt, default `DateTime.utc_now/0`).

```elixir
test "snapshot-conditional prune: reopened task survives", %{root: root} do
  {:ok, t} = Tasks.create(root, %{"title" => "x"})
  {:ok, _} = Tasks.patch(root, t["id"], %{"status" => "done"})
  {:ok, %{archived: 1}} = Tasks.archive_done(root)
  # simulate crash-between: re-add same task as done, then edit before next archive
  {:ok, t2} = Tasks.create(root, %{"title" => "x"})
  {:ok, _} = Tasks.patch(root, t2["id"], %{"status" => "done"})
  {:ok, _} = Tasks.patch(root, t2["id"], %{"status" => "open"})  # reopened
  {:ok, %{archived: 0}} = Tasks.archive_done(root)
  assert Enum.any?(Tasks.list(root).tasks, &(&1["id"] == t2["id"]))
end
```

- [ ] **Step 5: Implement `Valea.Tasks`** — all mutations wrapped in `Writer.exec/1`; inside, a bounded loop (3 attempts): `JsonFile.read` → locate entry by `"id"` (first occurrence wins) → apply patch map (merge; bump `"updated_at"`; set `"done_at"` when status becomes done) → `JsonFile.write(..., hash)`; `:conflict` → re-read and re-apply; entry missing on re-read → `{:error, :not_found}`. Archive: read → partition done/dropped eligible → append lines (each `Jason.encode!` one line; if file exists and lacks trailing newline, prefix `"\n"`) → re-read ledger → prune only entries whose current `snapshot_hash` equals the just-archived hash → write. Readers of the archive dedupe by `snapshot_hash` (expose `Valea.Tasks.archive_entries(icm_root)` for the UI later; dedupe there). Skeleton readme text verbatim from spec §tasks.json.

- [ ] **Step 6: Run task tests + full backend suite** — `mix test test/valea/tasks_test.exs`, then `mix test`. Expected: green.

- [ ] **Step 7: Commit** — `git commit -m "feat(tasks): ledger core — serialized writer, lenient JSON file, task semantics, snapshot-hash archive"`

---

### Task 2: Cron parser + schedules file model (strict validation, dispositions, fingerprint)

**Files:**
- Create: `backend/lib/valea/schedules/cron.ex`
- Create: `backend/lib/valea/schedules/entry.ex`
- Create: `backend/lib/valea/schedules/file.ex`
- Test: `backend/test/valea/schedules/cron_test.exs`
- Test: `backend/test/valea/schedules/file_test.exs`

**Interfaces:**
- Consumes: `Valea.Ledger.JsonFile.read/2` (Task 1).
- Produces:
  - `Valea.Schedules.Cron.parse(expr :: String.t()) :: {:ok, Valea.Schedules.Cron.t()} | {:error, String.t()}`
  - `Valea.Schedules.Cron.next_slot(cron, zone :: String.t(), after_utc :: DateTime.t()) :: {:ok, DateTime.t()} | {:error, :invalid_zone}` — strictly-after semantics, returns UTC.
  - `%Valea.Schedules.Entry{id, title, cron, cron_raw, timezone, payload, paused, catchup, created_by, disposition, reason, fingerprint, raw}` with `disposition :: :executable | :paused | :not_executable`, `reason :: String.t() | nil`.
  - `Valea.Schedules.Entry.fingerprint(raw :: map()) :: String.t()` — hex SHA-256 of key-sorted Jason encoding of `Map.take(raw, ["catchup", "cron", "payload", "timezone"])`.
  - `Valea.Schedules.File.load(icm_root) :: %{status: :ok | :absent | :unreadable, entries: [Entry.t()], hash: binary() | nil}`

- [ ] **Step 1: Failing cron tests** — vectors (each `{expr, zone, after_utc, expected_utc}`):
  - basics: `"30 7 * * 1-5"` Europe/Zurich after Tue 2026-07-28T10:00:00Z → Wed 2026-07-29T05:30:00Z (07:30 CEST).
  - aliases: `"@daily"` == `"0 0 * * *"`; `"@hourly"`, `"@weekly"` (Sun 00:00), `"@monthly"` (1st 00:00).
  - Vixie OR-rule: `"0 0 13 * 5"` (both restricted) matches the 13th OR any Friday; `"0 0 13 * *"` DOM-only; `"0 0 * * 5"` DOW-only.
  - ranges/steps/lists: `"*/15 * * * *"`, `"0 9-17 * * *"`, `"0 0 1,15 * *"`.
  - DST gap: `"30 2 * * *"` Europe/Zurich crossing 2026-03-29 (02:30 doesn't exist) → fires at 2026-03-29T01:00:00Z (03:00 CEST, first valid instant after the gap).
  - DST ambiguity: `"30 2 * * *"` Europe/Zurich crossing 2026-10-25 → first occurrence only (00:30Z, CEST offset), not 01:30Z.
  - strictly-after: `next_slot` with `after_utc` exactly on a slot returns the NEXT one.
  - invalid: `"61 * * * *"`, `"* * *"`, `"a b c d e"` → `{:error, _}`; bad zone → `{:error, :invalid_zone}`.

- [ ] **Step 2: Run to verify failure.**

- [ ] **Step 3: Implement `Cron`** — parse each of 5 fields into `MapSet` of ints (minute 0-59, hour 0-23, dom 1-31, month 1-12, dow 0-6 with 7→0); track `dom_restricted?`/`dow_restricted?` (field ≠ `*`). `next_slot`: shift `after_utc` to `zone`, truncate to minute, then advance minute-by-minute wall-clock via `NaiveDateTime` iteration bounded to 366×24×60 steps (deterministic, plenty fast for a 30 s tick over a handful of schedules; raise if exceeded — impossible for valid crons); a naive match uses the Vixie rule (`dom_ok or dow_ok` when both restricted, else `and`); convert each matching naive to UTC via `DateTime.from_naive(naive, zone)` handling `{:ambiguous, first, _second} -> first` and `{:gap, _before, just_after} -> just_after` (dedupe: a gap-shifted instant that lands ≤ `after_utc` or duplicates the previous slot is skipped and iteration continues). Zone validity: probe `DateTime.now(zone)` once; error → `{:error, :invalid_zone}`.

- [ ] **Step 4: Failing `File` tests** — strict matrix: missing `id` / non-string id → not_executable "missing id"; invalid cron → "invalid cron"; unknown timezone → "unknown timezone"; `paused: "true"` (string) → not_executable "`paused` is not a boolean" (NEVER runnable — pin this exact case); bad payload kind / missing prompt / non-list args → not_executable; `context_doc` lexically escaping (`"../x"` or absolute) → not_executable "context_doc escapes the ICM"; duplicate ids → ALL carriers not_executable "duplicate id"; valid+paused → `:paused`; valid → `:executable` with fingerprint present; fingerprint STABLE across `title`/`paused`/unknown-field edits, CHANGES on cron/payload/timezone/catchup edits; malformed file → `%{status: :unreadable, entries: []}`; absent → `:absent`.

- [ ] **Step 5: Implement `Entry` + `File`** — `File.load/1` reads via `JsonFile.read(root <> "/schedules.json", "schedules")`, maps each raw map through `Entry.build/1` (validation order: id → cron parse → timezone probe → payload shape (`%{"kind" => "prompt", "prompt" => bin}` optional `context_doc` relative + no `..` segment + not absolute; or `%{"kind" => "command", "command" => bin}` optional `args` list of binaries) → paused/catchup boolean-or-absent), then a duplicate-id pass downgrades every carrier. Display fields lenient (`title` fallback `"untitled"`, `created_by` string-or-nil).

- [ ] **Step 6: Run both test files + suite; commit** — `git commit -m "feat(schedules): cron parser (Vixie/DST-pinned) + strict schedules file model with dispositions"`

---

### Task 3: Run-state store (migration + Ash resources)

**Files:**
- Create: `backend/priv/repo/migrations/20260729000001_create_schedule_tables.exs`
- Create: `backend/lib/valea/schedules/store.ex`
- Create: `backend/lib/valea/schedules/store/state.ex`
- Create: `backend/lib/valea/schedules/store/run.ex`
- Test: `backend/test/valea/schedules/store_test.exs`

**Interfaces:**
- Consumes: `Valea.Repo` (per-workspace AshSqlite) — follow `Valea.Mail.Store` module/resource conventions exactly (internal-only domain, NO AshTypescript, minimal actions).
- Produces:
  - `Valea.Schedules.Store.get_state(icm_id, schedule_id) :: map() | nil` — keys `fingerprint, first_seen_at, last_attempted_slot, deleted_at` (+ ids).
  - `Valea.Schedules.Store.put_state(icm_id, schedule_id, attrs :: map()) :: :ok` (upsert on `(icm_id, schedule_id)`).
  - `Valea.Schedules.Store.record_run(attrs :: map()) :: {:ok, run_id :: String.t()}` — attrs: `icm_id, schedule_id, fingerprint, slot, fired_at, trigger ("scheduled"|"catchup"|"manual"), kind ("prompt"|"command"), outcome, duration_ms, session_id, output, coalesced_count, mount_key`.
  - `Valea.Schedules.Store.update_run(run_id, %{outcome:, duration_ms:, output:}) :: :ok`
  - `Valea.Schedules.Store.runs(icm_id, schedule_id, limit) :: [map()]` newest-first.
  - `Valea.Schedules.Store.notices_since(utc :: DateTime.t()) :: %{waiting: [run], failed: [run], registered: [state]}` — runs with outcome `"waiting"`/`"failed"` since `utc`, plus states with `first_seen_at >= utc` (cockpit notices, Task 6).

- [ ] **Step 1: Write migration** — two tables: `schedule_state` (composite unique index on `icm_id, schedule_id`; text columns `icm_id, schedule_id, fingerprint`; utc_datetime `first_seen_at, last_attempted_slot, deleted_at` nullable) and `schedule_runs` (uuid pk, text `icm_id, schedule_id, fingerprint, trigger, kind, outcome, session_id, mount_key`, utc_datetime `slot, fired_at`, integer `duration_ms, coalesced_count`, text `output` capped at write time not schema; index on `(icm_id, schedule_id, fired_at)`). Mirror the exact `Ecto.Migration` style of `20260726000001_mail_send_ops.exs`.

- [ ] **Step 2: Failing store tests** — upsert semantics (second `put_state` overwrites fingerprint/anchor, preserves row identity); `record_run`/`update_run`/`runs` ordering + limit; `notices_since` picks waiting/failed only and fresh registrations; outcomes free-form strings (`"completed"`, `"failed"`, `"skipped: still running"`, `"interrupted"`, `"timed out"`, `"waiting"`). Use the existing test setup pattern from `backend/test/valea/mail/store_test.exs` (or nearest mail store test) for booting the per-workspace Repo.

- [ ] **Step 3: Implement resources + facade; run; commit** — `git commit -m "feat(schedules): run-state store — anchors, fingerprints, run history in workspace sqlite"`

---

### Task 4: Scheduler engine (anchors, coalescing, catch-up, runners, kill switch)

**Files:**
- Create: `backend/lib/valea/schedules/scheduler.ex`
- Create: `backend/lib/valea/schedules/supervisor.ex`
- Create: `backend/lib/valea/schedules/runner.ex` (behaviour + `Valea.Schedules.Runner.Live`)
- Create: `backend/lib/valea/schedules/command_run.ex`
- Modify: `backend/lib/valea/workspace/runtime.ex` (children: insert `{Valea.Ledger.Writer, []}` and `{Valea.Schedules.Supervisor, %{root: root, generation: gen}}` after the Calendar supervisor, before the session DynamicSupervisor)
- Modify: `backend/lib/valea/mounts.ex` (add `scheduler_paused?/1` + `set_scheduler_paused/2` on workspace.yaml, following the `skills_offers_dismissed/2` read/write pattern at `mounts.ex:581`)
- Test: `backend/test/valea/schedules/scheduler_test.exs`

**Interfaces:**
- Consumes: `Valea.Schedules.File.load/1`, `Valea.Schedules.Cron.next_slot/3`, `Valea.Schedules.Store.*` (Tasks 2–3), `Valea.Mounts.enabled/0` (mount maps carry `.root`, `.name`, `.manifest.id`, `.kind`), `Valea.Audit.append/2`, `Valea.Tasks.sweep/1` (Task 1).
- Produces:
  - `Valea.Schedules.Supervisor` — Supervisor with children `Valea.Schedules.Scheduler` + `{DynamicSupervisor, name: Valea.Schedules.RunSupervisor}`.
  - `Valea.Schedules.Scheduler.run_now(icm_id, schedule_id) :: {:ok, run_id} | {:error, :not_executable | :not_found | :already_running}` (Task 6's RPC calls this).
  - `Valea.Schedules.Runner` behaviour:
    - `@callback start_prompt(mount :: map(), entry :: Entry.t(), meta :: map()) :: {:ok, session_id :: String.t()} | {:error, term()}`
    - `@callback start_command(mount :: map(), entry :: Entry.t(), meta :: map()) :: {:ok, pid()} | {:error, term()}`
  - Scheduler opts (via supervisor cfg, all with defaults): `tick_ms: 30_000`, `now_fun: &DateTime.utc_now/0`, `runner: Valea.Schedules.Runner.Live`.

- [ ] **Step 1: Failing scheduler tests (the determinism suite — fake runner, injected clock).** Test harness: start Store-backed Repo (Task 3 pattern), a tmp workspace root with one fake enabled ICM mount (stub `Valea.Mounts.enabled/0` via the app-env seam the watcher uses, or pass `mounts_fun:` opt — pin `mounts_fun: (-> [mount])` as a scheduler opt for tests), a `FakeRunner` (test module implementing the behaviour, sending `{:fired, entry.id, meta}` to the test pid, tracking liveness via an Agent). Drive ticks synchronously: pin `Scheduler.tick_now/0` (a `GenServer.call` that runs one tick) so tests never sleep. Cases, each its own test:
  1. new schedule registers state (`first_seen_at`/anchor = now), does NOT fire instantly; fires at next future slot when clock advances past it.
  2. multiple elapsed slots → ONE fire with `coalesced_count == n`.
  3. previous run live (FakeRunner reports busy) → one `"skipped: still running"` run record carrying coalesced count; anchor advances to latest slot; next tick emits NOTHING new.
  4. paused / invalid (`paused: "true"` string) / duplicate entries consume slots silently — no fire, no record, anchor advances; repair/unpause then advancing one slot fires exactly once (never the missed interval).
  5. fingerprint reset: edit cron → anchor/first_seen reset to now, no back-fire; edit title → NO reset (fires on time).
  6. tombstone: remove entry from a parseable file → `deleted_at` set; re-add byte-identical → anchors reset (no catch-up of the gap); UNREADABLE file does NOT tombstone.
  7. catchup=false workspace open: anchor := max(anchor, now) — with a pre-seeded past anchor and `now` in the past (backward jump), anchor stays put (monotonic).
  8. catchup=true: one coalesced fire with `trigger: "catchup"` for slots missed "while closed" (seed state, start scheduler, first tick).
  9. kill switch: `Mounts.set_scheduler_paused(root, true)` → tick consumes slots silently for all entries, fires nothing; disengage → no back-fire.
  10. launch-time re-validation: FakeRunner-visible — pause the entry by rewriting the file BETWEEN due-computation and launch (pin a `before_launch:` test-only hook opt executed right before re-validation) → nothing fires, nothing consumed that tick... (per spec step 7: consume nothing this tick).
  11. `run_now/2`: fires `trigger: "manual"` for executable AND paused entries, rejects not_executable/duplicate with `{:error, :not_executable}`, does NOT advance the anchor.
  12. audit: each fire/skip/registration-change appends (`Valea.Audit` started in setup like other tests that use it, or assert via `Audit.entries/1`).

- [ ] **Step 2: Run to verify failure.**

- [ ] **Step 3: Implement `Scheduler`.** GenServer, `name: __MODULE__`. Init: store cfg, `Process.send_after(self(), :tick, 0)` (first tick performs the catch-up pass: for each enabled ICM entry — after fingerprint/tombstone reconciliation — apply catchup rule). Tick body (also the `tick_now` call path), per enabled `kind: :icm` mount:
  1. `File.load(mount.root)`; `:unreadable`/`:absent` → skip mount (audit one `"schedules_unreadable"` per content-hash change; keep last-noticed hash in state — process-local is fine, it's only notice dedup).
  2. Reconcile every entry: compare `Store.get_state(icm_id, entry.id)`; new/fingerprint-changed/tombstoned-and-back → `put_state` with reset anchors + audit `"schedule_registered_changed"` (fields: mount_key, schedule_id, fingerprint, created_by). Previously-seen ids absent from this parseable file → set `deleted_at`, audit.
  3. Per entry with state: `next_slot(cron, zone, max(anchor, first_seen))`; loop collecting all slots ≤ now (count = coalesced); none → continue.
  4. If disposition ≠ `:executable` OR global `Mounts.scheduler_paused?(root)` → advance anchor to latest slot, record nothing.
  5. If a run for `(icm_id, id)` is live (prompt: session id from last run record still `live` per `Valea.Agents.list_sessions/0`; command: `RunSupervisor` child tagged with `{icm_id, id}` — check via `DynamicSupervisor.which_children` + a `Registry` named `Valea.Schedules.RunRegistry` keyed by `{icm_id, id}`; add the Registry to the supervisor children) → advance anchor + one `record_run(outcome: "skipped: still running", coalesced_count: n)`.
  6. Else launch: re-load the file (`before_launch` hook here in test builds), confirm entry still executable+unpaused+same fingerprint+kill switch off; then `runner.start_prompt/3` or `start_command/3` with `meta = %{icm_id:, icm_name: mount.manifest.name, mount_key: mount.name, schedule_id:, fingerprint:, slot:, trigger:, coalesced_count:}`; `record_run(outcome: "running", session_id: ...)` then advance anchor; audit `"schedule_fired"`. Spawn errors → `record_run(outcome: "failed")` + audit.
  Daily `Valea.Tasks.sweep/1` per mount: keep `last_sweep_date` in state; on date change run sweeps (and once on first tick).
- Completion messages: `{:run_finished, run_id, outcome, duration_ms, output}` from `CommandRun`; prompt-session completion is observed lazily (run row stays `"running"`; the run-history RPC joins live session status — pin that in Task 6) EXCEPT `waiting`: a prompt session parked on a permission ask is detected by Task 6's notice query joining sessions; keep scheduler simple.
- Generation binding: scheduler holds `generation`; every Store write goes through a private `bound_write/2` that re-checks `Valea.Workspace.Manager.check_generation(generation)` first — EXCEPT the terminate path: `terminate/2` marks still-`"running"` command runs `"interrupted"` synchronously (spec's shutdown exemption).

- [ ] **Step 4: Implement `Runner.Live` + `CommandRun`.**
  - `start_prompt/3`: `id = Valea.Agents.generate_session_id()`; `SessionScope.resolve(%{kind: "scheduled", mount_key: meta.mount_key, generation: gen, session_id: id, read_paths: [], include_mounts: []})`; `Valea.Agents.start_session(%{id: id, kind: "scheduled", title: "#{entry.title} — #{Date.to_iso8601(date)}", scope: scope, run: nil, initial_prompt: preamble <> "\n\n" <> entry.payload["prompt"], on_turn_end: nil, context_doc: entry.payload["context_doc"], input: nil, include_mounts: []})` — preamble verbatim from Global Constraints. `context_doc` resolved the way `Valea.Api.Agents.create_session` resolves it (reuse/extract its `resolve_context_doc/2` helper into a shared function rather than duplicating); resolution failure → `{:error, :context_doc_unavailable}` → failed run record.
  - `CommandRun`: GenServer started under `RunSupervisor` via `{:via, Registry, {Valea.Schedules.RunRegistry, {icm_id, schedule_id}}}`; init spawns via `Valea.Agents.ProcessRuntime.start/2` with cwd = ICM root and the minimal env (`Valea.Agents.Env.minimal()`) — **verify the exact spec-map keys against `process_runtime.ex`/`ProcessRuntime.Exec` before wiring; the adapter contract (owner messages `{:runtime_output, bin}`, `{:runtime_stderr, bin}`, `{:runtime_exit, code}`) is the stable part**. Accumulate output capped at 262_144 bytes (then note `"[output capped]"` once), `Process.send_after(self(), :timeout, 600_000)` → `ProcessRuntime.stop/1` + outcome `"timed out"`; on exit code 0 → `"completed"`, else `"failed"`; send `{:run_finished, ...}` to the Scheduler; `terminate/2` stops the subprocess (workspace-close kill).

- [ ] **Step 5: Wire Runtime children; run the determinism suite, then the full backend suite** (watch for workspace-open tests newly booting the scheduler — the scheduler must boot inert and tolerate no-mounts/no-Repo just like mail engines: rescue/catch degradation on Store calls during close, mirroring `Valea.Cockpit.mail_summary/0`'s posture).

- [ ] **Step 6: Commit** — `git commit -m "feat(schedules): scheduler engine — persisted anchors, coalescing, tombstones, catch-up, command runs, kill switch"`

---

### Task 5: Consent — PermissionPolicy tier, managedSettings mirror, RiskTier, session kind

**Files:**
- Modify: `backend/lib/valea/agents/permission_policy.ex` (new cond branches in `decide_split/2`)
- Modify: `backend/lib/valea/agents/session_settings.ex` (mirror rules in `content/1`)
- Modify: `backend/lib/valea/agents/risk_tier.ex` (`classify/1`)
- Test: `backend/test/valea/agents/permission_policy_test.exs` (extend)
- Test: `backend/test/valea/agents/session_settings_test.exs` (extend)
- Test: `backend/test/valea/agents/risk_tier_test.exs` (extend)

**Interfaces:**
- Consumes: existing `decide_split/2` cond structure (deny tiers → `paths == [] -> :ask` → allow tiers → `:ask`), `icm_roots` ctx list, `casefold/1` helpers.
- Produces: no new public functions — behavior changes only. Later tasks rely on: agent write to `<icm_root>/schedules.json` decides `:ask` even with a covering `write_root`; agent write under `<icm_root>/.valea/` decides `{:deny, "reject_once"}`; `RiskTier.classify/1` returns `"high"` for `schedules.json` and any path with a `.valea` segment.

- [ ] **Step 1: Failing policy tests** —
```elixir
test "schedules.json write asks even under a covering write_root grant" do
  ctx = ctx_with(write_roots: [icm_root], icm_roots: [icm_root])
  item = %{"kind" => "write", "toolName" => "Write",
           "rawInput" => %{"file_path" => Path.join(icm_root, "schedules.json")}}
  assert PermissionPolicy.decide(item, ctx) == :ask
end
```
  plus: casefold (`SCHEDULES.JSON` asks), edit/delete/move kinds ask too, `tasks.json` under the same grant still ALLOWS (control), nested `sub/schedules.json` is NOT special (root-only rule — the spec says "at an enabled ICM root"), `.valea/briefing.md` + `.valea/task-archive.jsonl` writes DENY for every write kind even when granted, `.valea` READS still allowed, non-ICM roots unaffected, empty-candidates floor still `:ask` (regression pin).

- [ ] **Step 2: Implement policy branches.** In `decide_split/2`: add a deny branch alongside the icm-secret tier: `Enum.any?(resolved, &split_valea_dir?(&1, icm_roots)) and kind in @write_kinds -> {:deny, "reject_once"}` where `split_valea_dir?` checks (casefolded, segment-boundary) that the candidate is under `<icm_root>/.valea`. Add an ask branch BETWEEN the escape-deny and the `paths == []` line: `kind in @write_kinds and Enum.any?(resolved, &split_schedules_file?(&1, icm_roots)) -> :ask` with `split_schedules_file?` = candidate == `<icm_root>/schedules.json` (casefolded basename + exact root join). Ordering note in a comment: deny tiers stay ahead; this ask tier must precede BOTH allow tiers.

- [ ] **Step 3: Settings mirror.** In `content/1`, alongside `secret_denies`: per icm root emit ask entries `["Write(#{root}/schedules.json)", "Edit(#{root}/schedules.json)"]` appended to the existing `"ask"` list, and deny entries `for op <- ["Write", "Edit"], do: "#{op}(#{root}/.valea/**)"` merged into `"deny"`. Comment cites the verified precedence (deny > ask > allow regardless of specificity — code.claude.com/docs/en/permissions) and the spec's fallback if a future harness refutes it. Extend the settings test to assert both lists.

- [ ] **Step 4: RiskTier.** Extend `classify/1`'s condition with `or Path.basename(path) |> String.downcase() == "schedules.json" and path |> Path.split() |> length() == 1` — careful: spec says root `schedules.json`; locator paths are ICM-relative so root file == single segment; also `or ".valea" in Path.split(path)`. Update the moduledoc list. Tests: `schedules.json` high, `sub/schedules.json` medium, `.valea/briefing.md` high, `tasks.json` medium.

- [ ] **Step 5: Session kind `"scheduled"`.** Grep for hardcoded `"chat"` assumptions that would reject the new kind: `SessionScope.resolve/1` (kind is passed through — add a test resolving `kind: "scheduled"` returns a scope with the same grants as chat), transcript meta, `list_sessions` summaries. Add `backend/test/valea/agents/session_scope_test.exs` case. No behavior change expected — the test pins it.

- [ ] **Step 6: Run all four test files + suite; commit** — `git commit -m "feat(consent): schedules.json always-ask + .valea write-deny at both layers, RiskTier stamps, scheduled session kind"`

- [ ] **Step 7 (acceptance note, no code):** add to the acceptance checklist (Task 9) the RUNTIME PROBE: with a real claude-agent-acp session in a granted-write ICM, attempt an agent `Write` to `schedules.json` → the permission dialog must appear; document observed behavior (which layer caught it) in the acceptance doc.

---

### Task 6: RPC surface + cockpit + session-list filtering

**Files:**
- Create: `backend/lib/valea/api/tasks.ex`
- Create: `backend/lib/valea/api/schedules.ex`
- Modify: `backend/lib/valea/api.ex` (register both resources in the `rpc` and `resources` blocks)
- Modify: `backend/lib/valea/cockpit.ex` (drop `open_loops`, add per-section `"tasks"` + `"schedule_notices"`)
- Modify: `backend/lib/valea/api/agents.ex` (`list_recent_sessions_by_icm`, `list_sessions_for`: add optional `include_scheduled` boolean arg, default false, filtering `kind == "scheduled"` backend-side)
- Test: `backend/test/valea/api/tasks_test.exs`, `backend/test/valea/api/schedules_test.exs`, extend `backend/test/valea/cockpit_test.exs`, extend the agents API test.

**Interfaces:**
- Consumes: `Valea.Tasks.*` (Task 1), `Valea.Schedules.File.load/1` + `Cron.next_slot/3` (Task 2), `Store.runs/3` + `notices_since/1` (Task 3), `Scheduler.run_now/2` + `Mounts.set_scheduler_paused/2` (Task 4).
- Produces (RPC actions; all take `generation` and run through a local `verified_lifecycle/2` = `Manager.check_generation/1` + `Manager.current/0`, calendar-style; mutating ones audit):
  - `Valea.Api.Tasks`: `:list_tasks` (per enabled ICM: `%{"mount_key", "icm_name", "status", "tasks" => [...]}`), `:create_task(mount_key, fields)`, `:mutate_task(mount_key, task_id, patch)`, `:archive_done(mount_key | nil)`.
  - `Valea.Api.Schedules`: `:list_schedules` (per ICM: entries with `"disposition"`, `"reason"`, `"next_fire"` (ISO or nil — computed via `next_slot` from the stored anchor), `"last_outcome"`), `:create_schedule(mount_key, fields)` / `:mutate_schedule(mount_key, schedule_id, patch)` / `:delete_schedule(mount_key, schedule_id)` (ledger writes via `Writer.exec` + `JsonFile`, same retry contract as tasks — implement in a `Valea.Schedules.Edit` helper module inside `api/schedules.ex`'s backing context or `lib/valea/schedules/edit.ex`), `:run_schedule_now(mount_key, schedule_id)`, `:schedule_run_history(mount_key, schedule_id, limit)` (join prompt-run rows still `"running"`/`"waiting"` against `Valea.Agents.list_sessions/0` live+status to surface `waiting`), `:set_scheduler_paused(paused)`.
  - Cockpit section shape (STRING keys): existing fields minus `"open_loops"`, plus `"tasks" => %{"due_today" => n, "overdue" => n, "in_progress" => n, "top" => [%{"id","title","due","today","priority"}]}` (top 3: today-flag first, then due asc, then priority) and top-level `"schedule_notices" => [%{"kind" => "waiting"|"failed"|"registered", "mount_key", "schedule_id", "title", "at"}]` from `Store.notices_since(now - 24h)`.

- [ ] **Step 1: Failing cockpit tests** — section has no `"open_loops"`; tasks line counts computed from a fixture `tasks.json` (due today/overdue/in_progress; host-zone date boundary via the same zone source the calendar line uses); malformed `tasks.json` → `"tasks" => nil` with section `"ok" => true` (task ledger failure must not kill the section — mirror the mail_summary degradation posture); notices ride `Store` fixtures.

- [ ] **Step 2: Implement cockpit changes; run.**

- [ ] **Step 3: Failing API tests** — generation guard rejects stale generation on every action (copy the guard-test shape from `backend/test/valea/api/calendar_test.exs`); `create_task` lands in the file; `mutate_task` conflict path maps to an RPC error; `list_schedules` surfaces dispositions + next_fire; `run_schedule_now` on a not_executable entry maps `{:error, :not_executable}` to the standard `Error`; `set_scheduler_paused` round-trips workspace.yaml. Agents list actions exclude `kind == "scheduled"` by default and include with the flag.

- [ ] **Step 4: Implement both resources** — follow `Valea.Api.Skills` action/arg/run structure verbatim (string-keyed `:map` returns, `error_for/1` mapping). Register in `api.ex` both blocks.

- [ ] **Step 5: Codegen + suite** — `just codegen` (regenerates `frontend/src/lib/api/ash_rpc.ts` — commit the generated file; the `just test` gate fails on staleness), `cd backend && mix test`.

- [ ] **Step 6: Commit** — `git commit -m "feat(api): tasks+schedules RPCs, cockpit tasks line + schedule notices, scheduled-session list filtering"`

---

### Task 7: Materialized briefing + templates + today.json guidance

**Files:**
- Create: `backend/priv/icm_briefing_template/briefing.md`
- Create: `backend/lib/valea/icm/briefing.ex`
- Modify: `backend/lib/valea/schedules/scheduler.ex` (materialize per enabled ICM on activation/first tick; also on reconciliation seeing a mount for the first time)
- Modify: `backend/priv/icm_template/CLAUDE.md` (+ its `AGENTS.md` twin if not a symlink) — one pointer line
- Modify: `backend/lib/valea/agents/session_settings.ex` — `context.md` pointer line (the existing-ICM path)
- Test: `backend/test/valea/icm/briefing_test.exs`
- Test: `backend/test/valea/agents/session_settings_test.exs` (context.md pointer)

**Interfaces:**
- Consumes: `Valea.Mail.AgentsFile` as the pattern (`template_dir/0`, `write_via_rename!/2` — copy the private helper, don't reach into mail).
- Produces: `Valea.Icm.Briefing.materialize!(icm_root) :: :ok` — write-if-different `.valea/briefing.md`; `Valea.Icm.Briefing.path(icm_root)`.

- [ ] **Step 1: Author the template.** `briefing.md` content (static, no interpolation needed): regenerated-by-Valea header ("Managed by Valea — regenerated on activation; edits will be overwritten. Agents cannot write in `.valea/`."), both file contracts as field tables with allowed values, minimal valid skeletons for creating each file from scratch, the invariants list (spec §Materialized briefing verbatim: mark-done-never-delete; opaque ids, never reuse; preserve unknown fields; no run state in files; fires only while Valea runs; paused/catchup semantics incl. "slots missed while paused are skipped for good"; one run at a time; cron/payload/timezone edits reset the anchor, title edits don't; delete+recreate resets too; Vixie DOM/DOW + DST rules; strict execution fields fail closed — write real JSON booleans; writing `schedules.json` will ask the user — that is the consent moment), the unattended-run convention, and the WORKED EXAMPLE: an agent adds a task (exact before/after `tasks.json`) and registers a schedule (exact before/after `schedules.json`, using the spec's morning-brief example verbatim).

- [ ] **Step 2: Failing briefing tests** — materialize creates `.valea/briefing.md`; second call with unchanged template does not rewrite (mtime unchanged — write-if-different); a hand-edited file IS rewritten; content includes the literal strings `"tasks.json"`, `"schedules.json"`, `"never delete"`, `"consent moment"`.

- [ ] **Step 3: Implement + wire.** `materialize!/1` reads template from `Path.join(:code.priv_dir(:valea), "icm_briefing_template/briefing.md")`, compares bytes to current, writes via tmp+rename when different. Scheduler calls it per enabled ICM mount on its first tick per mount (track materialized set in state; re-run on workspace open — cheap).

- [ ] **Step 4: Template pointers.** Append to `backend/priv/icm_template/CLAUDE.md` (and `AGENTS.md` if it's a separate file — check; mirror however the template keeps them in sync): `Valea tasks & schedules: this ICM's task ledger (tasks.json) and schedule registry (schedules.json) live in the root — contract in .valea/briefing.md.` Remove/adjust any `open_loops` guidance in the icm/workspace templates and mail templates if present (`grep -rn "open_loops" backend/priv/`).

- [ ] **Step 5: Session-context pointer — the EXISTING-ICM path.** Step 4 only seeds NEW ICMs; an existing ICM's `AGENTS.md`/`CLAUDE.md` is user-owned prose Valea never rewrites, so those get the pointer through the one instruction surface Valea authors for every session: `SessionSettings.context/1`. Add one line to `context.md`'s primary-ICM block (after "Your working directory IS this ICM's root…"): `Tasks & schedules: each enabled ICM keeps its task ledger (tasks.json) and schedule registry (schedules.json) at its root — contract in that root's .valea/briefing.md.` Phrased per-root on purpose, so it also covers related ICMs without per-entry noise. Regenerated every session, so it reaches every ICM old or new and always matches the running app version. Test: `session_settings_test.exs` asserts `context/1`'s render contains `.valea/briefing.md`.

- [ ] **Step 6: Run suite; commit** — `git commit -m "feat(briefing): materialized .valea/briefing.md — the agent contract for tasks+schedules"`

---

### Task 8: Frontend — Tasks route (two tabs), cockpit line, nav, session-list toggle

**Files:**
- Create: `frontend/src/routes/tasks/+page.svelte`
- Create: `frontend/src/lib/components/tasks/TasksTab.svelte`, `TaskRow.svelte`, `TaskEditor.svelte`, `QuickAdd.svelte`, `SchedulesTab.svelte`, `ScheduleRow.svelte`, `RunHistory.svelte`
- Create: `frontend/src/lib/tasks/store.svelte.ts` (RPC-backed; refresh on the existing icm-change socket event the knowledge store already consumes — reuse that subscription helper)
- Create: `frontend/src/lib/tasks/filters.ts` + `frontend/src/lib/tasks/filters.test.ts`
- Create: `frontend/src/lib/tasks/cadence.ts` + `frontend/src/lib/tasks/cadence.test.ts`
- Modify: `frontend/src/lib/shell/nav.ts` (insert `{ id: 'tasks', label: 'Tasks', href: '/tasks', icon: ListTodo }` between `today` and `mail`; import `ListTodo` from lucide alongside the existing icon imports)
- Modify: the Today route components under `frontend/src/lib/components/today/` (tasks line replacing the open_loops rendering; notices)
- Modify: the sessions pane ("Show all") component: add an "include scheduled runs" toggle wiring the new `include_scheduled` RPC arg
- Test: `frontend/src/lib/components/tasks/*.test.ts` for TasksTab + SchedulesTab (vitest component tests — follow the existing component test convention in `frontend/src/lib/components/`)

**Interfaces:**
- Consumes: generated client functions in `frontend/src/lib/api/ash_rpc.ts` from Task 6 (`listTasks`, `createTask`, `mutateTask`, `archiveDone`, `listSchedules`, `createSchedule`, `mutateSchedule`, `deleteSchedule`, `runScheduleNow`, `scheduleRunHistory`, `setSchedulerPaused` — exact camelCase names come from codegen; read them from the generated file, do not guess).
- Produces:
  - `filters.ts`: `todayFilter(tasks: Task[], todayIso: string): Task[]` (due today + overdue + today-flag + in_progress), `sortTasks(tasks: Task[]): Task[]` (today-flag, due asc, priority high→low, created_at).
  - `cadence.ts`: `humanizeCron(expr: string): string` — `"30 7 * * 1-5"` → `"weekdays 07:30"`, `"0 * * * *"` → `"hourly at :00"`, `"0 9 * * 1"` → `"Mondays 09:00"`, fallback: the raw expression. Pure function, table-driven, tested.

- [ ] **Step 1: Failing unit tests for `filters.ts` + `cadence.ts`** (vitest, `bun run test`): today filter includes overdue and in_progress regardless of due; sort order pinned; humanizer vectors incl. fallback-to-raw for exotic expressions.

- [ ] **Step 2: Implement both pure modules; tests green.**

- [ ] **Step 3: Store + route + tabs.** `/tasks` route: two-tab header (Tasks | Schedules; `?tab=schedules` deep-linkable). TasksTab: grouped by ICM (provenance header like the Today sections), Today/All + assignee/status filter chips, `QuickAdd` (title input + ICM picker defaulting to MRU — reuse the MRU source `lib/today/quick-session.ts` uses), checkbox → `mutateTask(status: "done")`, row click → `TaskEditor` (title, notes, due date input, today toggle, priority select, assignee select, status select), overflow menu (drop, archive), agent badge on `created_by === "agent"`, per-ICM calm malformed note ("unreadable — fix by hand or ask the agent"), "Clear done", repair affordance: entries with no id render with a "repair" button → `mutateTask` special-cased backend-side? — NO: repair = `createTask` with the same fields + a UI hint; keep v1 repair as "assign id": backend `mutate_task` with `task_id: nil` is invalid, so pin repair to a dedicated small RPC? — **decision: reuse `create_task` + manual delete guidance in the note; document in the component; the spec's repair affordance is satisfied by the editor normalizing unknown status values on save.**
  SchedulesTab: rows (title, `humanizeCron`, payload chip, next fire, last outcome, pause toggle → `mutateSchedule({paused})`, created_by badge, disposition reason line when not executable), expand → `RunHistory` (fired_at, outcome, duration, trigger, coalesced count; prompt runs link `/chat?session=<id>`; command runs show capped output in a `<pre>`), Run now button (disabled with reason for not_executable), delete w/ confirm, header Pause-all switch + banner, subtle highlight for schedules whose `first_seen_at` is <24h (data already in list payload — add `"registered_recently"` boolean in Task 6's list if missed there; keep consistent).

- [ ] **Step 4: Today + nav + session toggle.** Today: replace the open_loops block with the tasks line (counts + top items linking to `/tasks`), render `schedule_notices` (waiting → link to transcript; failed → link to `/tasks?tab=schedules`; registered → title + next fire). Nav item. Sessions "Show all" pane: "include scheduled runs" checkbox → refetch with `include_scheduled: true`.

- [ ] **Step 5: Component tests** — TasksTab: renders fixture payload, checkbox fires mutate, malformed note shown; SchedulesTab: disposition reason shown, run-now disabled for not_executable, pause toggle wired. Follow the existing vitest component-test setup (query the repo: `ls frontend/src/lib/components/**/*.test.ts` and mirror the closest one, e.g. a mail or today component test).

- [ ] **Step 6: Full gate + browser sanity.** `just test`. Then `preview_start {name: backend-dev-real}`-equivalent dev run per `.claude/launch.json` and click through: quick-add → file appears on disk; hand-edit `tasks.json` → UI updates; pause toggle writes the file. (Browser-pane gotcha from the test plan: use form_input + JS clicks, not raw keystrokes.)

- [ ] **Step 7: Commit** — `git commit -m "feat(tasks-ui): Tasks route with Tasks+Schedules tabs, cockpit tasks line + notices, nav, scheduled-session toggle"`

---

### Task 9: Docs, browser test plan, acceptance checklist

**Files:**
- Modify: `docs/ARCHITECTURE.md` (new "Tasks & Schedules" section: file contracts, scheduler state model, consent tiers, run-state tables — implemented-state prose, spec stays the decision record)
- Modify: `docs/VISION.md` (the "daily loop" §1 note about scheduled work: update "eventually by a scheduled deterministic step" to reflect shipped scheduled sessions/commands; keep MVP non-goals intact)
- Modify: `docs/testing/browser-test-plan.md` (new Tasks/Schedules section per spec §Testing: quick-add → file appears; hand-edit → UI updates; agent registers schedule → ask-gate → row + cockpit notice; invalid entry shows disposition; run-now → transcript reachable; pause-all; archive sweep)
- Create: `docs/superpowers/acceptance/2026-07-29-tasks-schedules.md` (live checklist: A. agent adds task via chat in real ICM; B. agent registers schedule → permission dialog appears (THE RUNTIME PROBE from Task 5 — record which layer caught it); C. schedule fires a prompt session on time, hidden from nav, reachable via run history; D. command schedule runs a script, output captured; E. pause via UI + via hand edit; F. kill switch; G. catchup=true across an app restart; H. Codex round: none — spec settled)

**Interfaces:** none — prose only. Cross-check every claim against the implemented code, not the spec (ARCHITECTURE.md records what IS).

- [ ] **Step 1: Write all four docs.**
- [ ] **Step 2: `grep -rn "open_loops" docs/ backend/priv/ frontend/src/` — retire stragglers.**
- [ ] **Step 3: Full gate `just test`; commit** — `git commit -m "docs: tasks+schedules architecture section, browser test plan, live acceptance checklist"`

---

## Self-Review Notes (performed at authoring)

- **Spec coverage:** data model (T1/T2), leniency split (T1/T2), write discipline + archive (T1), scheduler state model/firing/catch-up/clocks/kill switch (T4), consent both layers + RiskTier + kind (T5), visibility/filtering (T6/T8), UI surfaces + cockpit (T6/T8), briefing + templates (T7), RPC surface (T6), audit (T4/T6), error table behaviors (T1/T2/T4 tests), testing section (distributed per task), docs/acceptance incl. runtime probe (T5 step 7 → T9). `today.json` open_loops retirement (T6 cockpit + T7 templates + T9 grep).
- **Known simplifications vs spec (allowed, stricter):** single workspace-wide `Ledger.Writer` instead of per-ICM writers (strictly stronger serialization); task "repair" v1 = editor normalization + calm note rather than a dedicated repair RPC (spec's affordance intent: nothing visible-but-unfixable — the editor path covers unknown status; id-less entries remain display-only with the note; revisit if it bites).
- **Type consistency:** `Entry.t()` fields, `Store` signatures, and `meta` map keys are pinned above and reused verbatim in T4/T6; RPC action names snake_case backend / camelCase generated — T8 instructed to read generated names, not guess.
