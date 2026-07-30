# Tasks & schedules — the contract for this ICM

Managed by Valea — regenerated on activation; edits will be overwritten.
Agents cannot write in `.valea/`. Reading it is ordinary and encouraged;
every write under this directory is denied, not asked.

Two files at this ICM's root are the whole API. There is no tool, no skill
and no RPC for you here: **the file is the interface.**

| File | What it is | Who writes it |
| ---- | ---------- | ------------- |
| `tasks.json` | the shared work ledger — the ICM's single "needs attention" surface | you, the user, and Valea's UI |
| `schedules.json` | the schedule registry — recurring prompts and commands Valea fires | you (the write is gated — see Consent), the user, Valea's UI |
| `.valea/task-archive.jsonl` | completed tasks, appended by Valea | Valea only (read-only to you) |

Valea owns the *meta* layer only: run history, archival, audit, the UI. It
never puts run state in the files.

`today.json` (if this ICM has one) keeps `notes` and `prepared` only. It no
longer carries `open_loops` — open work belongs in `tasks.json`, where the
user can see, filter and complete it.

## How to edit these files

Read the whole file, change the entry you mean, write the whole file back.

- **Preserve fields you don't recognize.** `readme`, unknown top-level keys,
  unknown entry fields, fields a newer Valea added — round-trip all of them.
  Valea does the same when it patches an entry.
- **Read fresh, write promptly.** Valea's own writes are hash-checked and
  retried; yours are not. A long gap between your read and your write is
  where an update gets lost.
- Both files are plain JSON, human-editable, and the user may edit them by
  hand at any moment. Neither file is a schema you may extend silently:
  extra keys survive, but nothing reads them.
- If a file is missing, create it with the skeleton below. If a file is
  malformed, Valea shows the user a calm "unreadable — fix by hand or ask
  the agent" note and **nothing in `schedules.json` fires** until it parses.

## `tasks.json`

Minimal valid file:

```json
{
  "readme": "Task ledger for this ICM. Managed by Valea and agents. Contract: .valea/briefing.md",
  "tasks": []
}
```

One entry:

| Field | Type / allowed values | Required | Notes |
| ----- | --------------------- | -------- | ----- |
| `id` | string, `t-` + 6 lowercase hex (e.g. `t-8f3a2c`) | yes, in practice | Opaque. You generate it. Never reuse one. An entry without an id is visible but not addressable. |
| `title` | string | yes | The one thing the user reads. |
| `notes` | string | no | Freeform. |
| `status` | `"open"` \| `"in_progress"` \| `"done"` \| `"dropped"` | yes | Nothing else. Unknown values render as text and sort last. |
| `assignee` | `"user"` \| `"agent"` | no | Agent-assigned tasks are *pulled* by a session; Valea never auto-executes a task. |
| `due` | `"YYYY-MM-DD"` | no | Date only. |
| `today` | JSON `true` / `false` | no | The user's focus flag for the Today filter. |
| `priority` | `"high"` \| `"medium"` \| `"low"` | no | |
| `source` | string | no | Freeform provenance locator: a mail message locator, a file path, a URL. Recognized locators become links. |
| `created_by` | `"user"` \| `"agent"` | no | Set `"agent"` for tasks you create — the UI badges them. |
| `created_at` | ISO 8601 UTC, second precision | no | e.g. `"2026-07-29T08:00:00Z"`. |
| `updated_at` | ISO 8601 UTC | no | Bump it when you change an entry. |
| `done_at` | ISO 8601 UTC or `null` | no | Stamp it when you move an entry into `done`/`dropped`; clear it if you reopen. |

Tasks are **inert**: nothing here executes, schedules or fires. Duplicate
task ids degrade softly (the first occurrence wins for addressing) — but
generate fresh ones anyway.

## `schedules.json`

Minimal valid file:

```json
{
  "readme": "Schedules for this ICM. Fire only while Valea is running. Contract: .valea/briefing.md",
  "schedules": []
}
```

One entry:

| Field | Type / allowed values | Required | Notes |
| ----- | --------------------- | -------- | ----- |
| `id` | short opaque slug (e.g. `s-morning-brief`) | **yes** | No id → not executable and not addressable. Never reuse one. **Duplicate ids make EVERY carrier non-executable** — array order must never decide what runs. |
| `title` | string | no (degrades to `"untitled"`) | Display only. Editing it never disturbs the cadence. |
| `cron` | 5-field cron, or `@hourly` / `@daily` / `@weekly` / `@monthly` | **yes** | Grammar below. |
| `timezone` | IANA zone name (e.g. `"Europe/Zurich"`) | no | Absent = the host's zone. `null` or a non-string is an error, not "absent". |
| `payload` | object, see below | **yes** | |
| `paused` | JSON `true` / `false` | no (default `false`) | A file field: you, the user, or the UI can pause. |
| `catchup` | JSON `true` / `false` | no (default `false`) | See Catch-up below. |
| `created_by` | `"user"` \| `"agent"` | no | Set `"agent"` for schedules you register. |
| `created_at` | ISO 8601 UTC | no | Provenance only. |

**Declaration only.** Never write run state into this file — no `last_run`,
no `next_fire`, no `last_outcome`. Valea keeps all of that on its side and
shows it in the UI.

### Payloads

`prompt` — starts an ordinary agent session in this ICM, unattended:

```json
{
  "kind": "prompt",
  "prompt": "Work the inbox-triage workflow and update tasks.json.",
  "context_doc": "communications/workflows/inbox-triage.md"
}
```

- `prompt`: non-empty string, required.
- `context_doc`: optional, **ICM-relative** path (no leading `/`, no `..`
  segment — even one that would resolve back inside). A `context_doc` that
  doesn't exist when the schedule fires makes the run *fail*; it never
  produces a weaker session.

`command` — exec-style spawn, cwd = this ICM's root:

```json
{
  "kind": "command",
  "command": "python3",
  "args": ["scripts/sync.py"]
}
```

- `command`: non-empty string, required. Resolved like a terminal would
  (absolute, ICM-root-relative, or via PATH).
- `args`: list of plain strings (default `[]`). **Never a shell string** —
  there is no shell, no interpolation, no pipes and no redirection. Put a
  pipeline in a script and call the script.
- A command runs with the user's full authority and **no sandbox**. Timeout
  10 minutes; output captured and capped at 256 KiB into the run record.

### Cron grammar

```
minute  hour  day-of-month  month  day-of-week
 0-59   0-23      1-31      1-12   0-6  (7 = Sunday, same as 0)
```

A field is `*`, a number, an `a-b` range, a comma-separated list of those,
or `*`/`a-b` followed by `/step`. `@hourly`, `@daily`, `@weekly` (Sunday
00:00) and `@monthly` (the 1st, 00:00) stand in for a whole expression.

**Not** part of the grammar, so nobody has to guess the dialect: month and
weekday *names* (`JAN`, `MON`), the `L` / `W` / `#` extensions, a seconds or
year field, backwards ranges (`30-10`), and a bare `5/10` step with no `*`
or range in front of the `/`. Anything refused makes the entry
non-executable with a visible reason — it never quietly fires at the wrong
time.

**The Vixie day rule.** Day-of-month and day-of-week are **OR'd when both
are restricted**, AND'd otherwise:

- `0 0 13 * 5` → the 13th **and** every Friday.
- `0 0 13 * *` → the 13th only.
- `0 0 * * 5` → Fridays only.
- "Restricted" is read off the field's **first character**, so `*/2` counts
  as a star for the *rule* while still constraining the *set*:
  `0 0 */2 * 5` fires on odd-numbered Fridays (AND), not on every Friday.

**Zones and DST.** Cron fields are wall-clock times in the schedule's zone;
each slot resolves to one UTC instant.

- A wall time that does not exist (spring-forward gap) fires at the first
  valid instant after the gap — once, not once per skipped minute.
- A wall time that happens twice (fall-back) fires only at its **first**
  occurrence.

## Lenient display, strict execution

Display fields are forgiving: a missing `title`, a wrong-typed `notes` or an
unknown `status` degrades and the row still shows up so it can be repaired.

**Execution-control fields are strict and fail closed, per entry.** For a
schedule those are `id`, `cron`, `timezone` (when present), `payload` (shape
*and* kind), `paused` and `catchup`. Anything invalid, missing or
wrong-typed makes that one entry **not executable**: it never fires, and the
UI shows the reason ("invalid cron", "unknown timezone", "`paused` is not a
boolean", "duplicate id"). Other entries are unaffected.

**Write real JSON booleans.** `"paused": true`, never `"paused": "true"` —
the string form is refused outright, because a malformed *pause attempt*
must never leave a schedule running.

## Invariants

- **Mark done, never delete.** Set `status` to `"done"` or `"dropped"`;
  Valea archives completed entries to `.valea/task-archive.jsonl` and prunes
  them from the ledger. Deleting an entry yourself destroys history nothing
  can recover.
- **Ids are opaque short slugs you generate. Never reuse one**, in either
  file — Valea's run history and archive are keyed off them.
- **Preserve fields you don't recognize.** Round-trip unknown keys.
- **No run state in the files.** Anchors, run records, outcomes and archives
  are Valea's; the files declare *what should be*, never *what happened*.
- **Schedules fire only while Valea is running.** Nothing fires when the app
  is closed. This is not cron and not a systemd timer; it is a registry Valea
  executes while it is open.
- **A newly registered schedule first fires at its next FUTURE slot**, never
  instantly on registration.
- **`paused` is a file field, honored within one tick (≤ 30 s):
  slots missed while paused are skipped for good — unpausing never
  back-fires.** The same rule covers an entry that was non-executable:
  repairing it never back-fires the slots it missed either.
- **`catchup`** (default `false`): with `false`, slots that passed while
  Valea was closed are consumed silently on open. With `true`, at most **one
  coalesced fire** covers everything missed.
- **One run per schedule at a time.** A slot arriving while the previous run
  is still live is recorded as skipped, not queued.
- **Editing `cron`, `timezone`, `payload` or `catchup` resets that
  schedule's anchor** — the schedule is a new one as far as timing goes, so
  there is no catch-up across an edit. Editing `title`, toggling `paused`, or
  adding a field Valea has never heard of does **not** reset it.
- **Deleting an id and recreating it resets the anchor too**, byte-identical
  recreation included.
- **No automatic retry.** A failed run is recorded; the next slot is the
  retry.

## Consent — what to expect when you write

- **Writing `schedules.json` will ask the user for permission, every time.
  That ask is the consent moment for the schedule.** No broad write grant
  can buy it. Once the write is approved, the schedule is live — there is no
  second approval step, so make the entry say exactly what you mean before
  you write it.
- Use your ordinary file tools for these files. A shell redirection reaches
  the user as a generic "run this command" ask that cannot say "this
  registers a schedule" — worse for the human deciding.
- Writing `tasks.json` is an ordinary ICM write.
- **`.valea/` is not writable by agents** — this briefing and the task
  archive are Valea's. Read them freely.
- If you are running **unattended** (a scheduled prompt run) and you hit a
  permission ask nobody is there to answer, the session simply parks on it —
  Valea shows the run as `waiting` and nothing else happens. So when you get
  blocked:
  **record what's needed in `tasks.json` and end the session.**
  Do not try to work around a gate.

## Worked example

An agent triaging the inbox has one task to add and one recurring brief to
register.

### 1. Add a task

`tasks.json` before:

```json
{
  "readme": "Task ledger for this ICM. Managed by Valea and agents. Contract: .valea/briefing.md",
  "tasks": [
    {
      "id": "t-8f3a2c",
      "title": "Send Kita offer follow-up",
      "status": "open",
      "assignee": "user",
      "due": "2026-07-30",
      "today": true,
      "priority": "high",
      "source": "mail:w3d/INBOX/<msg_id>",
      "created_by": "agent",
      "created_at": "2026-07-29T08:00:00Z",
      "updated_at": "2026-07-29T08:00:00Z",
      "done_at": null
    }
  ]
}
```

`tasks.json` after — the existing entry is untouched, the new one appended:

```json
{
  "readme": "Task ledger for this ICM. Managed by Valea and agents. Contract: .valea/briefing.md",
  "tasks": [
    {
      "id": "t-8f3a2c",
      "title": "Send Kita offer follow-up",
      "status": "open",
      "assignee": "user",
      "due": "2026-07-30",
      "today": true,
      "priority": "high",
      "source": "mail:w3d/INBOX/<msg_id>",
      "created_by": "agent",
      "created_at": "2026-07-29T08:00:00Z",
      "updated_at": "2026-07-29T08:00:00Z",
      "done_at": null
    },
    {
      "id": "t-3d91af",
      "title": "Reply to Alex about the kickoff date",
      "notes": "He proposed the 12th; check the calendar first.",
      "status": "open",
      "assignee": "agent",
      "due": "2026-07-31",
      "priority": "medium",
      "source": "mail:w3d/INBOX/<other_msg_id>",
      "created_by": "agent",
      "created_at": "2026-07-30T09:12:00Z",
      "updated_at": "2026-07-30T09:12:00Z",
      "done_at": null
    }
  ]
}
```

Completing it later is a `status` change plus `done_at` — **never a
deletion**:

```json
{ "id": "t-3d91af", "status": "done", "updated_at": "2026-07-31T10:04:00Z", "done_at": "2026-07-31T10:04:00Z" }
```

### 2. Register a schedule

`schedules.json` before — the ICM has none yet, so the file does not exist.
Create it with the skeleton and the entry in one write:

`schedules.json` after (this write is the ask):

```json
{
  "readme": "Schedules for this ICM. Fire only while Valea is running. Contract: .valea/briefing.md",
  "schedules": [
    {
      "id": "s-morning-brief",
      "title": "Morning inbox brief",
      "cron": "30 7 * * 1-5",
      "timezone": "Europe/Zurich",
      "payload": {
        "kind": "prompt",
        "prompt": "Work the inbox-triage workflow and update tasks.json.",
        "context_doc": "communications/workflows/inbox-triage.md"
      },
      "paused": false,
      "catchup": false,
      "created_by": "agent",
      "created_at": "2026-07-29T08:00:00Z"
    }
  ]
}
```

Weekdays at 07:30 Zurich time. The user approves the write, the schedule is
live, and its first fire is the next weekday 07:30 — not now. Adding a
second schedule later means reading this file again and appending to
`schedules`, `readme` and existing entries preserved.

## Where the rest lives

Run history (per fire: outcome, duration, trigger, transcript link or
captured output), "run now", pause and pause-all, the task archive and
"clear done" are all in **Valea's UI** — the Tasks page, its Schedules tab,
and the Today cockpit. You never need them to do your part: write the files,
and Valea does the rest.
