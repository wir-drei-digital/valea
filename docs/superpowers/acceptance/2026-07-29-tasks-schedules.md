# Tasks & schedules — live acceptance checklist

Manual checks executed by the user AFTER merge, in a **real ICM** with a
**real `claude` binary**. The automated suite covers every rule against
injected clocks and fake runners — the scheduler's determinism, the
strict-field matrix, the consent tiers, the archive's crash windows. This
list is the part only real wall-clock time, a real harness subprocess and a
real desktop build can prove. Spec:
`docs/superpowers/specs/2026-07-29-tasks-schedules-design.md`. UI-level and
file-round-trip checks are the browser plan's leg H
(`docs/testing/browser-test-plan.md`) and are NOT repeated here.

**Section B is the one that gates trust.** Everything else here is a
timing or lifecycle proof; B is the proof that an agent cannot register a
standing grant of future unattended execution without a human saying yes in
the moment. Do not let a schedule an agent wrote run on a real ICM until B
is filled in.

Conventions: `ICM` = the real ICM's root on disk, `WS` = the open
workspace's hidden root. Fill every **Observed:** line; a blank one means
the check has not run. Use a throwaway schedule id per drill (`s-acc-<n>`)
and delete it afterwards — these fire for real. A `command` payload runs
with your full authority and no sandbox; point every command drill at a
script you wrote for it.

## Preface: making the clock cooperate

The scheduler ticks every 30 s and fires on wall-clock cron slots, so most
of this list is "set a cadence a minute or two out, then wait". Two
practical notes before starting:

- **A newly registered schedule first fires at its next FUTURE slot** — the
  reconciler anchors it at registration time. `* * * * *` registered at
  09:41:20 fires at 09:42:00, not immediately. Budget one minute per fire.
- **Do not set the system clock backwards** to shorten a drill. Anchors are
  monotonic on purpose (`max(stored, candidate)`), so a backward jump makes
  a schedule go *quiet* until wall time re-passes the anchor — you would be
  testing G, not the leg you meant. Section H's restart drill is the
  supported way to exercise a closed window.
- Keep the audit log open (`/audit`) — most legs here have an audit line as
  their second, independent witness.
- Observed (clock plan understood, throwaway ids chosen):

## A. Agent adds a task via chat, in a real ICM

### A1. The write is ordinary, and the ledger is right
- Steps: Start a session in the real ICM. Ask the agent, in plain words, to
  add a task for something real ("add a task to send the Kita follow-up
  tomorrow, high priority"). Then open `ICM/tasks.json`.
- Expected: an ordinary ICM write — one `Write`/`Edit` ask (or none, if the
  session already carries a write grant over the ICM), **no** special
  gating. The file carries a `readme`, a `tasks` array, and an entry with
  an `id`, `status: "open"`, `created_by: "agent"` and real timestamps.
  The `/tasks` route shows it under the right project with a `from agent`
  badge, and Today's tasks line counts it.
- Observed:

### A2. The agent found the contract on its own
- Steps: In the SAME session, before prompting further, ask the agent where
  it learned the file's shape.
- Expected: it names `.valea/briefing.md` (or the `readme` field pointing
  at it, or the `context.md` line Valea writes into every session) — not
  guesswork, and not the `AGENTS.md` prose of an ICM that predates this
  feature. This is the whole discovery mechanism for an EXISTING ICM whose
  prose Valea never rewrites; if the agent had to be told the schema by
  you, the mechanism did not work.
- Observed:

### A3. Completion is a status change, never a deletion
- Steps: Ask the agent to mark that task done. Then complete a second task
  from the UI checkbox and click "Clear done".
- Expected: the agent SETS `status` (and ideally `done_at`) rather than
  removing the entry. After "Clear done" the cleared entries are gone from
  `tasks.json` and present in `ICM/.valea/task-archive.jsonl`, one JSON
  object per line with `archive_event`, `archived_at`, `snapshot_hash` and
  the full `task` snapshot. `grep` in that file finds them.
- Observed:

## B. THE RUNTIME PROBE — agent registers a schedule

The spec's amended managed-settings bullet says the mirror is best-effort
and **very likely inert** under the pinned adapter, and that the enforcing
layer is `Valea.Agents.PermissionPolicy` on the ACP `request_permission`
callback. That is a source-grounded claim, not a measured one. This section
measures it.

### B1. The dialog appears at all — with a write grant in place
- Steps: Start a session in the real ICM whose scope carries a **write
  grant over the ICM root** (the ordinary case for a session that has
  already been allowed to edit files there — approve one ordinary write
  first if needed, so you know the grant is live). Then ask the agent to
  register a schedule in `schedules.json` (e.g. a weekday 07:30 inbox
  brief). Watch the chat.
- Expected: the write to `ICM/schedules.json` raises the **permission
  dialog anyway** — a broad grant must not buy schedule registration. The
  dialog carries the HIGH risk banner ("Changes how your assistant
  behaves") and the diff of what is about to be written. Deny once: the
  agent sees the denial and the file is unchanged. Then repeat and approve:
  the entry lands, the Schedules tab shows it with a `from agent` badge and
  a `new` highlight, and Today grows a `<title> was registered` notice
  linking to `/tasks?tab=schedules`.
- Observed (dialog appeared? risk banner? deny path clean?):

### B2. WHICH LAYER caught it
- Steps: With B1's ask on screen, check the backend log/console for the
  `session/request_permission` round trip and Valea's own decision, and
  check `/audit` for the permission entry. Then, for contrast, note what a
  plain `Write` to an ungranted path looks like in the same log.
- Expected: **record what you actually see**, not what should happen. The
  question is whether the ask reached Valea's `PermissionPolicy` callback
  (the expected answer) or was raised by the harness's own managed-settings
  `ask` rule before Valea was consulted. Evidence that it was the callback:
  the ACP `session/request_permission` frame arrives and Valea's audit
  carries the decision for THIS path. Evidence that the mirror fired: an
  ask that never reaches Valea's callback at all.
- Observed (layer: PermissionPolicy callback / managedSettings ask /
  both / undetermined — plus the log excerpt):

### B3. The adapter's startup output — dropped or unparsed settings
- Steps: Restart the backend and start one fresh session, capturing the
  adapter subprocess's **startup** output (stderr included — Valea logs
  `[acp] …` lines; run the backend in a terminal you can scroll). Search it
  for any warning about settings entries being dropped, ignored or not
  understood — in particular the phrase **"is not matched by file
  permission checks"**, and anything mentioning `managed-settings`,
  `permissions.allow`, or an unparsed rule.
- Expected: record the warnings verbatim. Two outcomes are both
  informative: warnings naming our `Write(...)`/`Edit(...)` entries confirm
  the mirror is being parsed but not consulted (the documented
  `Write(<path>)`-accepted-but-never-consulted behavior), and silence with
  B2 showing the callback caught it confirms the "inert mirror, callback
  enforces" reading. What must NOT happen is B1's dialog failing to appear.
- Observed (warnings verbatim, or "none"):

### B4. `.valea/` is denied, not asked
- Steps: In the same session, ask the agent to edit `.valea/briefing.md`
  and, separately, to append a line to `.valea/task-archive.jsonl`.
- Expected: **both refused outright** — a deny, no dialog, nothing for a
  human to accidentally approve. Reading either file stays ordinary (ask
  the agent to quote a line from the briefing to confirm). The audit
  records the denials.
- Observed:

### B5. A shell redirection still fails safe (accepted risk #6)
- Steps: Ask the agent to write `schedules.json` "using a shell command"
  (e.g. a heredoc redirect).
- Expected: it lands on the generic `Bash` ask — a dialog appears (never a
  silent allow), but it cannot say "this registers a schedule". This is the
  documented, accepted gap. Confirm the ask appears; deny it.
- Observed:

## C. Briefing materialized on activation, in a real ICM

### C1. It appears, and its content is sane
- Steps: On an ICM that has never seen this feature, open the workspace and
  wait for one tick. Read `ICM/.valea/briefing.md`.
- Expected: the file exists, byte-identical to
  `backend/priv/icm_briefing_template/briefing.md`, headed by the
  regenerated-by-Valea warning. Read it as if you were the agent: both file
  grammars, the strict/lenient split, the cron dialect incl. the Vixie day
  rule, the invariants, the consent expectations, and a worked example are
  all there and none of it contradicts what the app actually does.
- Observed:

### C2. Regeneration, and the failure mode
- Steps: Hand-edit the briefing (add a line), then reopen/switch the
  workspace. Separately: replace `ICM/.valea` with a regular FILE, reopen,
  and watch.
- Expected: the hand edit is overwritten on the next activation (no mtime
  churn when nothing changed — an untouched briefing is not rewritten). The
  `.valea`-is-a-file case costs a log line and ONE `briefing_unwritable`
  audit entry, retried quietly thereafter — never a stalled scheduler and
  never a resurrected bare `.valea/`. Schedules in that ICM keep firing.
- Observed:

### C3. A brand-new ICM gets it before it has any ledgers
- Steps: Create or mount a fresh ICM with no `tasks.json` and no
  `schedules.json` at all. Wait one tick.
- Expected: `.valea/briefing.md` is there anyway. (It is keyed off the
  mount's root, not off having read a schedules file — the fresh ICM is
  exactly the one that most needs the contract.)
- Observed:

## D. A prompt schedule fires on time

### D1. It fires at its slot, not at registration
- Steps: Register (from the UI) a `prompt` schedule with a cron slot 2–3
  minutes out, whose prompt is something checkable ("append a line to
  scratch.md saying you ran"). Note the wall-clock registration time. Watch
  the Schedules tab's "next fire".
- Expected: **nothing happens at registration**. At the slot (within one
  30 s tick) the run appears in the row's run history with `trigger:
  scheduled`, and the prompt's effect shows on disk. The audit carries a
  `schedule_fired` entry with the fingerprint and the session id.
- Observed:

### D2. It is hidden from the session lists, and reachable from run history
- Steps: Check the sidebar's recent sessions and `/chat?all=1`. Then expand
  the schedule's run history and click **Open transcript**.
- Expected: the scheduled session is **absent** from both lists by default;
  ticking "Include scheduled runs" reveals it. The run-history link opens
  the real transcript at `/chat?session=<id>`.
- Observed:

### D3. The preamble is in the transcript, verbatim
- Steps: Read the first user message of that transcript.
- Expected: the fixed preamble is there and reads exactly:
  *Scheduled run "&lt;title&gt;" (&lt;schedule_id&gt;) in &lt;icm name&gt;.
  You are running unattended; if you get blocked, record what's needed in
  tasks.json and end the session.* — followed by a blank line and then the
  schedule's own prompt **verbatim**. The session title is
  `<schedule title> — <YYYY-MM-DD>`, the date being the slot's wall-clock
  date in the schedule's zone. Any mangling of this string (a protocol
  error, a truncation at a parenthesis) is a failure, not cosmetics.
- Observed:

### D4. One run at a time
- Steps: Register a `* * * * *` prompt schedule whose prompt takes several
  minutes (ask it to work something genuinely long). Let 3–4 slots pass.
- Expected: exactly ONE session runs. The skipped slots produce ONE
  `skipped: still running` record per skip event with a coalesced count —
  not one per slot, and not re-emitted every tick. No second concurrent
  session ever starts. Delete the schedule afterwards.
- Observed:

## E. A command schedule runs a script

### E1. Output captured, exit code honest
- Steps: Write `ICM/scripts/acc.sh` that echoes a few lines to stdout AND
  stderr and exits 0. Register a `command` schedule
  (`{"kind":"command","command":"scripts/acc.sh","args":[]}`) a couple of
  minutes out. Wait, then expand the run history.
- Expected: outcome `completed`, a real duration, and the captured output
  inline in the run history — stdout and stderr interleaved. The audit's
  `schedule_fired` entry carries the **full command line**. Change the
  script to exit 1 and let it fire again: outcome `failed`, with the exit
  status in the output, a cockpit notice on Today, and **no automatic
  retry** — the next slot is the retry.
- Observed:

### E2. cwd, env, and no shell
- Steps: Have the script print `pwd` and a couple of env vars, and register
  a second schedule whose `args` contain shell metacharacters
  (`["a; echo pwned", "$HOME", "*"]`) that the script simply echoes back.
- Expected: cwd is the ICM root. The metacharacter arguments arrive at the
  script **verbatim, unexpanded and unsplit** — there is no shell. A bare
  command name resolves on PATH; a name with a separator resolves against
  the ICM root.
- Observed:

### E3. (Optional) Timeout path
- Steps: Register a command schedule pointing at a script that sleeps
  longer than 10 minutes. Let it fire and wait it out.
- Expected: at 10 minutes the outcome is `timed out`, the subprocess **and
  its process group** are gone (`ps` confirms — no orphan), whatever output
  it produced before the kill is retained, and the next slot fires normally.
- Observed (optional — mark "skipped" if not run):

### E4. Output cap
- Steps: Point a command schedule at a script that writes well over 256 KiB
  (e.g. `yes | head -c 400000`).
- Expected: the stored output is capped at 256 KiB with a single
  `[output capped]` marker appended; the run history renders it in a
  scrollable block without freezing the UI; the run still completes with
  its real exit status.
- Observed:

## F. Pause — from the UI and by hand

### F1. UI toggle writes the file
- Steps: With a schedule due in ~2 minutes, click Pause. Open
  `ICM/schedules.json`.
- Expected: `"paused": true` is in the file (the file alone fully describes
  the desired state), the row reads Paused, no `next fire` is advertised,
  and **the slot passes without firing**. Resume afterwards: the schedule
  does **not** back-fire the slot it missed — unpausing never replays.
- Observed:

### F2. Hand edit pauses too, within one tick
- Steps: With a `* * * * *` schedule running, hand-edit the file to
  `"paused": true` and watch.
- Expected: it stops firing within one tick (≤ 30 s), and the UI row
  follows without a reload. Set it back to `false`: it resumes at the next
  slot, with no replay of the paused window. (A pause landing inside the
  final snapshot-to-spawn window — milliseconds — may miss that one fire;
  that is the documented guarantee, not a bug.)
- Observed:

### F3. A malformed pause attempt does NOT leave it running
- Steps: Hand-edit the file to `"paused": "true"` — the STRING.
- Expected: the entry becomes **not executable** with the visible reason
  naming the field (``` `paused` is not a boolean ```), and it fires
  nothing. The failure mode of a botched pause must never be "keeps
  running".
- Observed:

## G. The kill switch, including the tri-state

### G1. Pause all stops everything, and never back-fires
- Steps: With two schedules due within the next few minutes, engage **Pause
  all**. Let both slots pass. Then resume.
- Expected: the banner appears, `scheduler_paused: true` is in
  `WS/config/workspace.yaml`, and neither schedule fires. "Run now" is
  refused while it is engaged. On resume, **nothing back-fires** — the
  anchors advanced silently. Engaging and disengaging are both in `/audit`.
- Observed:

### G2. Config-unreadable fails CLOSED, and says so honestly
- Steps: Hand-break `WS/config/workspace.yaml` (a stray tab, an unclosed
  quote) while a schedule is due within a couple of minutes.
- Expected: **nothing fires** — this is the control that stops unattended
  prompts and unsandboxed commands, and it must never fail open. The
  Schedules header shows the WARN variant, `Scheduling paused: workspace
  config unreadable. Fix config/workspace.yaml by hand — nothing fires
  until it parses.`, and the switch is **disabled** (Valea refuses to
  rewrite a config it cannot read; the RPC answers `config_unreadable`).
  Exactly ONE `scheduler_config_unreadable` audit entry per transition into
  that state — not one per 30 s tick. Repair the file: firing resumes, and
  the slots that passed while it was broken are NOT replayed.
- Observed:

## H. `catchup: true` across an app restart

### H1. One coalesced fire, not one per missed slot
- Steps: Register a schedule with `"catchup": true` and a frequent cadence
  (`*/2 * * * *`). Confirm it fires once normally. Then **quit the app
  entirely** (backend included) for 15–20 minutes — long enough for many
  slots — and relaunch.
- Expected: on open, exactly **ONE** fire covering the whole closed window,
  recorded with `trigger: catchup` and a `coalesced_count` matching the
  number of slots that passed. Not one run per slot, and not zero.
- Observed (coalesced_count seen):

### H2. `catchup: false` (the default) is silent
- Steps: Same drill on a schedule with `catchup` absent or `false`.
- Expected: **nothing** fires on open — the anchor fast-forwards silently —
  and the schedule resumes at its next future slot. No run record is
  written for the missed window.
- Observed:

### H3. An edit made while closed resets instead of catching up
- Steps: With a `catchup: true` schedule, quit the app, wait past several
  slots, then EDIT the cadence (or the payload) before relaunching.
- Expected: reconciliation runs first, so the changed fingerprint resets
  the anchor and **no catch-up fire happens** — the schedule simply starts
  fresh at its next future slot. Editing only the `title` while closed
  leaves the catch-up intact.
- Observed:

## I. A scheduled session parked on an ask

### I1. It parks, it does not bypass, and Today says so
- Steps: Register a prompt schedule whose prompt asks for something that
  must be gated — e.g. "write a file at `<some path outside the ICM>`" — so
  the unattended session hits a permission ask nobody is there to answer.
  Let it fire, then do not touch the dialog for a few minutes.
- Expected: the session **parks**. It does not proceed, and it does not
  get a weaker posture for being scheduled. The row's last outcome reads
  `waiting`, and Today grows a `<title> is waiting for your approval`
  notice linking to `/tasks?tab=schedules`. Nothing fires a second run of
  that schedule while it sits there.
- Observed:

### I2. Resolving it from the normal transcript view
- Steps: Open the parked run's transcript from the run history and answer
  the ask (deny is fine).
- Expected: the ask resolves in the ordinary chat surface — there is no
  separate approval queue — the `waiting` notice clears, and the run
  proceeds to its real outcome.
- Observed:

### I3. Self-perpetuation fails closed
- Steps: Register a prompt schedule whose prompt tells the agent to add
  another schedule to `schedules.json`.
- Expected: the unattended session parks on the always-ask for
  `schedules.json` and **registers nothing**. An agent cannot grow its own
  standing execution rights while nobody is watching.
- Observed:

## Known limitations (documented, not blockers)

- **Nothing fires while Valea is closed.** Stated in the UI. Your existing
  systemd/launchd timers remain a valid pattern outside Valea; Valea does
  not try to absorb them.
- **`schedule_runs` has no retention or prune policy.** Nothing deletes run
  records, so the table grows for the life of the workspace. Rows are small
  and one schedule produces at most one event per slot, but ownership of a
  prune is unassigned — worth revisiting if a minutely schedule runs for
  months.
- **Cockpit notices span disabled mounts.** The notice query has no mount
  filter; only the *label* lookup is built from enabled mounts. A schedule
  in a mount you disabled within the last 24 h can still produce a notice
  (attributed via the run row's own recorded mount key). Not wrong, but it
  can look surprising right after disabling a project.
- **The same ICM mounted in two workspaces can double-fire.** Anchors are
  per-workspace, so one cron slot can fire once per workspace — around a
  switch, or with two app instances. Accepted; there is no cross-workspace
  lease. Do not mount a schedule-carrying ICM in two workspaces you both
  keep open.
- **A foreign write in the final microseconds is unrecoverable for open
  entries** (accepted risk #5): a whole-file write landing between Valea's
  last hash check and its rename is silently overwritten, and open tasks in
  that window have no archive copy. POSIX rename offers no true CAS and a
  lock file in user territory was rejected.
- **Command content drift is not detected** (accepted risk #1): an approved
  command schedule's target script can change later through ordinary
  writes, and the next unattended fire runs the new content. No
  hash-pinning; the mitigations are always-ask registration, the per-fire
  audit with the full command line, and pause/kill-switch.
- **A `Bash` redirection onto `schedules.json` reaches the generic ask**
  (accepted risk #6): never a silent allow, but the dialog cannot say what
  it is about. §B5 is where you see it.
- **External writers get no consent event** (accepted risk #2): a hand edit
  or a sync tool can create an active schedule without Valea observing a
  consent moment. Those channels are yours.
- **Destructive task rewrites by an agent are undetected in v1** (accepted
  risk #4): the briefing says "set status, never delete"; the archive and
  transcripts are the safety nets.
