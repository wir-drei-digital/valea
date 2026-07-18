# Calendar — ICS feeds in, Valea calendar out (Spec F)

Valea's calendar subsystem: read-only mirrors of the user's external
calendars via polled ICS subscription feeds, plus one agent-writable local
"Valea calendar" that Valea serves back out as an ICS feed the user's own
calendar apps can subscribe to. File-first throughout: every event the
agent can see or create is a plain file under `sources/calendar/`.

Decided against (this phase): CalDAV in any direction, OAuth (Google) and
Graph (Microsoft) — the user's provider mix (Google, iCloud, Infomaniak,
potentially Microsoft) is only covered uniformly by ICS feed URLs, which
need no protocol client and no new auth system. Provider writes are a
possible later increment; the Valea-calendar event files carry everything
needed to render standard VEVENTs, so that seam stays open.

## Storage layout

```
sources/calendar/
  <slug>/                    # one per subscribed feed; slug grammar ^[a-z0-9][a-z0-9-]{0,31}$
    .source                  # identity file: url host + sha256(url) prefix — engine-owned
    feed.ics                 # last SUCCESSFUL raw feed snapshot — engine-owned
    views/events/<id>.md     # derived per-VEVENT markdown views — engine-owned
  valea/
    events/<name>.md         # agent/user-created events — agent-writable (the ONLY
                             #   agent-writable path under sources/calendar)
```

- `<id>` for external views: `ev-<hash16>` where hash16 = first 16 hex of
  sha256(source slug <> "\0" <> VEVENT UID <> "\0" <> canonical
  RECURRENCE-ID) — canonical = the override instant normalized per the
  timezone rules below rendered as a UTC ISO string (or the plain date
  for all-day), empty for a master. A master and its overrides therefore
  never collide on one path. External UIDs are arbitrary, possibly
  hostile bytes — they never become filename material directly; the real
  UID and raw RECURRENCE-ID live in the view's frontmatter.
- `feed.ics` is the SINGLE durable commit point and the authority for
  everything derived: it is replaced atomically (tmp + fsync + rename)
  only after a fetch AND parse succeed, and the views + index are then
  DERIVED from the newly committed snapshot (idempotent rebuild).
  Activation always re-derives views + index from `feed.ics`
  unconditionally, so a crash anywhere between the swap and the derive
  self-heals at the next activation or pass; a failure BEFORE the swap
  leaves the previous snapshot and everything derived from it fully
  intact. Derived state additionally carries a DERIVE MARKER in BOTH
  derived stores — the revision string `rev = sha256(snapshot bytes)
  <> ":" <> host zone name`: the views tree is rebuilt into a tmp dir
  CONTAINING a `views/.rev` file with `rev` and swapped in by rename
  FIRST; only then does a per-source SQLite transaction replace the
  occurrence rows and write `calendar_sync_state.derived_rev = rev`. A
  derive counts as complete only when `views/.rev` AND `derived_rev`
  both equal the current (snapshot, host zone) revision; EVERY pass —
  including a 304 `unchanged` — and every activation checks BOTH and
  re-derives on any mismatch, so a derivation failure, a crash between
  the two stores' swaps, or a host-zone change is repaired on the next
  tick even when the feed itself sends 304s. Queries meanwhile see the
  previous committed rows (SQLite transaction) and the previous views
  tree until their respective swap/commit — never a half-written
  mixture within either store.
- `.source` binds the slug to its feed (host + URL fingerprint). A slug
  whose keychain URL no longer matches `.source` refuses to sync
  (`identity_mismatch`, resolved by purge) — same posture as mail's
  `.account`, preventing one feed's mirror from being silently overwritten
  by a different feed reusing the slug.

## Config and credentials

`config/calendar.yaml` (v1). A LEGACY placeholder file predates this
spec: the workspace template ships an old `account`/`caldav`/
`ics_fallback`-shaped `config/calendar.yaml`, so existing workspaces
carry one. Handling is explicit and destructive-by-design (no
backwards compatibility, nothing in the legacy file is real data): the
template file is REPLACED with the v1 shape (empty `sources:`) in this
change; `Settings.load/1` treats any non-v1 file as
`{:invalid, reason}` surfaced in `calendar_status` (never blocking the
local Valea calendar, which needs no config to work); the first
`setup_calendar_source` or `enable_calendar_feed` rewrites the file
wholesale to v1. Format:

```yaml
version: 1
sources:
  work:
    name: "Work (Google)"
    window: { past_days: 30, future_days: 365 }
    interval_minutes: 30
feed:
  token_hash: "<sha256 hex of the served-feed token>"   # engine-managed
```

- The FEED URL IS A CREDENTIAL (Google's "secret address" embeds a private
  token). URLs never appear in config or any workspace file: OS keychain
  entry `"<workspace_id>" / "<slug>:ics"` (same Tauri commands as mail),
  RAM-only in the engine, dev/browser fallback env `VALEA_CAL_URL_<SLUG>`
  (upcased, dashes to underscores). Restart resupply mirrors mail's
  `resupplyCredentials` flow, keyed per source slug.
- Defaults: past_days 30, future_days 365, interval_minutes 30 (min 5).
- `feed.token_hash` stores only the sha256 of the served-feed token; the
  plain token is shown once at generation/rotation and never persisted.

## Event model

- An external mirror event is one VEVENT from one source's feed. Identity
  = (source slug, UID, RECURRENCE-ID if present). Feeds are authoritative
  snapshots — no cross-fetch reconciliation exists or is needed; each
  successful fetch REPLACES the source's mirror (views + index rows)
  within the window.
- Recurrence: files/views are one per VEVENT master (plus override
  VEVENTs carrying RECURRENCE-ID); OCCURRENCES are expanded only into the
  SQLite index, bounded to the source's window. An unbounded RRULE is fine
  — the window caps expansion.
- The parsed property subset (everything else is preserved-ignored):
  UID, SUMMARY, DTSTART, DTEND | DURATION, RRULE, RDATE, EXDATE,
  RECURRENCE-ID, LOCATION, DESCRIPTION, STATUS (CANCELLED honored),
  TRANSP, LAST-MODIFIED, SEQUENCE, all-day (DATE-typed DTSTART).
  Attendees/organizer/alarms are not parsed (non-goal: no ITIP).

## The ICS parser (`Valea.Calendar.Ics`)

Hand-written (the Elixir ICS/CalDAV packages are effectively unmaintained;
this repo already owns its IMAP protocol core for the same reason). Scope:

- Tokenizer: RFC 5545 line unfolding (CRLF + space/tab), property
  name/params/value split, backslash unescaping (`\\n`, `\\,`, `\\;`,
  `\\\\`), parameter quoting.
- Component reader: VCALENDAR → VEVENT list; VTIMEZONE components are
  read past, not interpreted (see timezones). Unknown components and
  properties are skipped without error.
- Value types: DATE, DATE-TIME (floating, UTC `Z`, and `TZID=` forms),
  DURATION, and RRULE parts FREQ (DAILY/WEEKLY/MONTHLY/YEARLY), COUNT,
  UNTIL, INTERVAL, BYDAY (including ordinals, e.g. `2MO`), BYMONTHDAY,
  BYMONTH, BYSETPOS, WKST; plus RDATE/EXDATE lists. (BYSETPOS is in the
  supported set because Outlook-style "second Monday" rules depend on
  it.)
- Expansion: `expand(vevent, window_from, window_to)` → occurrence list,
  honoring COUNT/UNTIL, EXDATE, RDATE, and override VEVENTs. Override
  matching is defined on CANONICAL INSTANTS: both the master's expanded
  occurrence times and the override's RECURRENCE-ID are normalized
  through the same timezone resolution as DTSTART (all-day compares as
  plain dates; floating compares only against floating) and matched on
  equality; a RECURRENCE-ID that matches no expanded occurrence renders
  the override as a standalone event with a per-source notice. A
  CANCELLED override removes its occurrence. `RANGE=THISANDFUTURE` is
  recognized but NOT implemented: the whole series is treated as
  unsupported (below) rather than mis-rendered. Expansion is iterative
  with a hard iteration cap (guards pathological rules).
- Unsupported recurrence is UNAVAILABLE, never fabricated: an RRULE
  using a part outside the supported set (e.g. BYWEEKNO, BYYEARDAY), a
  THISANDFUTURE override, or an unresolvable timezone (below) marks the
  whole series `recurrence_unsupported` — NO occurrences are emitted
  (not even DTSTART: one stale instance masquerading as the series is
  worse than visible absence), the view is still written with
  `recurrence_unsupported: true` and the raw rule, a per-source notice
  records it, and the UI surfaces "N series unsupported" on the source's
  status line so absence is discoverable, not silent.
- Timezones: `TZID` values are resolved in a fixed chain: (1) as IANA
  names via the `tzdata` time-zone database (new dependency, configured
  as Elixir's `:time_zone_database`); (2) through a static Windows→IANA
  alias table (CLDR windowsZones — Outlook feeds use TZIDs like
  "W. Europe Standard Time"); (3) otherwise the affected VEVENT/series
  is UNSUPPORTED (skipped with a notice, per the rule above) — an
  unknown TZID is never guessed as local/floating time, because a wrong
  guess silently moves real appointments. VTIMEZONE component
  definitions are still not interpreted (the alias chain covers real
  provider feeds; a fixture proving otherwise widens the alias table,
  not the parser). Local wall times at DST transitions resolve
  DETERMINISTICALLY: an ambiguous time (clock rolled back) takes the
  EARLIER UTC instant; a nonexistent time (clock jumped forward) takes
  the first instant AFTER the gap — applied identically to DTSTART,
  expansion, EXDATE/RDATE, and RECURRENCE-ID canonicalization, so
  override identities can never diverge from occurrence identities. All
  index times are stored as UTC instants plus an `all_day` flag
  (all-day events stored as dates; floating times are resolved against
  the host zone at derive time; the derive marker re-derives them when
  the host zone changes).
- Fail-soft per component: one malformed VEVENT is skipped with a notice;
  it never fails the feed. A feed that yields ZERO parseable events where
  the previous snapshot had events is treated as a failed fetch
  (degraded, mirror untouched) — an empty-feed guard against a provider
  serving an error page with `200 text/html`.

## Fetching (`Valea.Calendar.Fetch`)

A minimal HTTPS GET built on `:httpc` with explicit TLS verification
(`verify_peer`, hostname check, CA trust via the same OS-provided
mechanism `ImapClient` already uses — the same no-insecure-escape-hatch
posture). Pinned behavior:
HTTPS-only (an `http://` URL is rejected at setup), redirect cap 3 and
SAME-ORIGIN only (scheme + host + port — a cross-origin redirect fails
the pass; a provider that moves publishes a new URL, the user re-pastes
it), response size cap 20 MB, timeout 30 s, conditional GET via stored
ETag/Last-Modified (304 → pass ends with `unchanged`). Before every
connect, the host's resolved addresses are checked and loopback,
link-local, RFC 1918/ULA, and reserved ranges are rejected — the poller
must not be an SSRF primitive against the user's own machine or LAN.
Residual risk, accepted and documented: a DNS-rebinding feed host could
still race the check against the connect's second resolution; the
attacker in that position already controls a feed the user chose to
subscribe to, and the impact is bounded to a GET whose response lands in
that source's own mirror. The URL never appears in logs or error strings
(redacted like mail credentials — a feed URL IS the secret).

## Sync engine

`Valea.Calendar.Supervisor` (under `Valea.Workspace.Runtime`, beside
`Valea.Mail.Supervisor`) + one `Valea.Calendar.Engine` per valid source,
registered via `{:via, Registry, {Valea.Calendar.Registry, slug}}` — the
mail supervisor/engine pattern minus everything two-way. The Supervisor
is ALSO the per-slug lifecycle serializer: `setup_calendar_source`,
`set_calendar_source_url`, `remove_calendar_source`,
`purge_calendar_source_files`, and config rehash all execute through its
single process, so no two lifecycle mutations for a slug can interleave
— purge re-checks the slug is unconfigured while holding that
serialization, and a concurrent setup for the same slug queues behind
the purge rather than racing the deletion.

- Activation: verify `.source` (absent → claim; mismatch → inert
  `identity_mismatch`), read the keychain-supplied URL (RAM only), rebuild
  the index from `feed.ics` + views (self-heal), start the poll timer.
- A pass: conditional GET → parse → atomically swap `feed.ics` (the
  commit point) → derive this source's views + index rows from the new
  snapshot → broadcast. Single
  in-flight pass per engine (monitored Task, the mail single-flight
  shape). Any failure (network, TLS, parse, empty-feed guard) marks the
  source degraded with a reason and leaves the previous mirror fully
  intact; the next tick retries.
- Status per source: `state` (inactive | idle | syncing | degraded |
  identity_mismatch | invalid_config), `last_sync_at`, `last_error`,
  `event_count`, `notices`, `url_present` (credential-style boolean).
- The VALEA source is not an engine: `Valea.Calendar.Local` validates,
  lists, and renders ON DEMAND — `list_calendar_events` and the served
  feed read the (few) event files live at query time, so agent-written
  files appear without any watcher or index round-trip.

## The Valea calendar (`Valea.Calendar.Local`)

Agent/user-created events are markdown files in
`sources/calendar/valea/events/<name>.md`:

```markdown
---
title: "Coffee with Priya"
start: 2026-07-21T09:30:00+02:00
end: 2026-07-21T10:00:00+02:00
location: "Café Anton"          # optional
all_day: false                   # optional; true ⇒ start/end are DATES
status: confirmed                # optional: confirmed | tentative | cancelled
---
Agenda: follow up on the workshop plan.
```

- Validation is fail-closed (the DraftFile posture): unknown frontmatter
  keys rejected; control characters rejected in every field; `start` must
  be < `end` (`end` omitted → 1-hour default). All-day events: dates
  only; `end` is EXCLUSIVE per RFC 5545 DATE-typed DTEND and must be
  STRICTLY > `start` (`end` omitted → start + 1 day, one-day event);
  the UI editor speaks inclusive dates and converts both ways. Dates
  must parse as ISO 8601 with offset, or as plain dates when `all_day`; body length capped (16 KB). A file that fails validation
  is listed as `invalid` with its reason (UI + status), rendered NOWHERE
  (neither grid nor served feed). Symlinked/hard-linked entries are
  rejected unread (no-follow lstat, the drafts posture). No recurrence in
  v1 — one file is one event.
- UID: deterministic from the FILE NAME only —
  `valea-<hash16 of basename>@valea.local` — so edits keep the UID stable
  (calendar clients track events by UID) and a rename is intentionally a
  new event. The engine never writes into agent files; there is no
  stamping.
- The UI's create/edit/delete panel goes through RPCs that write these
  same files (create refuses to overwrite an existing name; update/delete
  target one file). Agents edit their own files directly through the
  normal permission gate — for the Valea calendar, files ARE the API; no
  declared-ops machinery.

## The served feed

`GET /calendar/feed.ics?token=<plain token>` on the existing loopback
endpoint:

- Serves ONLY the rendered Valea calendar (valid `valea/events/*.md` →
  one VCALENDAR with engine-composed VEVENTs). External mirrors are never
  served — the endpoint cannot become an exfiltration path for the user's
  Google/iCloud data.
- Token: 32 random bytes (base64url), generated on first enable, stored
  ONLY as sha256 in `config/calendar.yaml`, compared constant-time.
  Shown once in the UI with a copy button; `rotate_calendar_feed_token`
  invalidates the old one. The route is token-exempt from the control
  token (calendar apps cannot send headers) and takes NO other
  parameters.
- Rendering is the DraftMime posture inverted for ICS: VEVENTs are
  composed from validated struct fields with RFC 5545 escaping and line
  folding — agent text can never smuggle raw ICS properties or additional
  components into a subscriber's calendar.
- Reachability, stated honestly: the endpoint binds loopback. Calendar
  apps ON THIS MACHINE can subscribe (Calendar.app "On My Mac",
  Outlook/Thunderbird local); server-side subscription fetchers (iCloud-
  located subscriptions, Google, Outlook.com) cannot reach loopback, so
  the feed does NOT propagate to phones in this phase. Any later remote
  reachability (VPN/tailnet interface, headless deployment) reuses this
  endpoint unchanged. The UI copy says exactly this next to the URL.

## Mounts and policy

- ONE synthetic mount `calendar` (kind `:calendar`) covering
  `sources/calendar/` — appended by `Mounts.list/1` whenever
  `config/calendar.yaml` exists with ≥1 source OR any `valea/events/`
  file exists; enabled unless every source is invalid. Follows every
  `kind: :mail` exclusion (never a Knowledge/editor/ICM-mutation target,
  excluded from cockpit sections, watcher ICM events, doctor, global
  search; `unique_mount_key` reserves `calendar`).
- Sessions opt in via a bare-string `"calendar"` entry in `related_icms`
  or via `include_mounts` (the Task-14 validation generalizes from
  "must be kind :mail" to "must be a synthetic, non-ICM mount kind";
  the ICM-key rejection stays).
- `PermissionPolicy` gains a calendar tier with mail's exact semantics,
  same precedence slot (after icm_secret, before escape/ask): any
  candidate under `sources/calendar` (blanket, segment-bounded,
  casefold+NFC, resolved paths) outside a session with the calendar
  mount → DENY, never ask. In scope: WRITE kinds allowed only under
  `valea/events/` (everything else — `.source`, `feed.ics`, `views/` —
  is engine-owned: write → deny); READ kinds allowed everywhere in
  scope (mirrors and views are exactly the calendar data the session
  was granted; there is no spool-like secret area). managedSettings
  mirror: for an out-of-scope session, `**` deny over Read+Edit+Write
  on `sources/calendar`; in scope, Edit+Write deny on everything under
  `sources/calendar` except `valea/events/**`.
- The mail tier and calendar tier share their casefold/segment matching
  helpers (extract, don't duplicate).

## Views

One derived markdown file per VEVENT master under
`<slug>/views/events/ev-<hash16>.md`: frontmatter `uid, source, summary,
start, end, all_day, location, status, recurring (bool), rrule (raw
string, if any)`, DESCRIPTION as body — same injection-hardened yaml
escaping as mail views. Views are engine-owned, rebuilt on every
successful pass (replace-mirror), and are the agent's read surface:
"review my calendar" sessions read these files, not `feed.ics`.

## Index (`Valea.Calendar.Store`)

Hand-migrated (`migrate? false`) AshSqlite resources, all rebuildable
from files (`feed.ics` + valea events) — pure cache, no ledger:

- `calendar_occurrences` (EXTERNAL sources only — valea events are read
  live from their files at query time): source, uid, all_day, occ_start,
  occ_end, summary, location, status, view_path. The endpoints are
  TAGGED by `all_day`: timed rows store UTC ISO instants; all-day rows
  store plain ISO dates with `occ_end` EXCLUSIVE — an all-day date is
  never encoded as a UTC midnight (a negative-offset host would shift
  it a day). One row per expanded occurrence within the window. Indexed
  on (occ_start, occ_end).
- `calendar_sync_state`: source, etag, last_modified, last_sync_at,
  last_error, derived_rev (the derive marker: sha256(snapshot bytes) +
  host zone name; written ATOMICALLY in the same transaction as the
  rebuilt occurrence rows — a failed or incomplete derive leaves it
  mismatched, which is exactly what re-triggers the derive on the next
  pass, 304s included).

`list_events(from, to)` merges the external index rows with the
live-read valea events, ordered by occ_start — the one query the UI
needs.

## RPC surface (`Valea.Api.Calendar`)

Every mutating action takes `generation` (`Manager.check_generation/1`);
falsy-field string-key rule as elsewhere. External snake_case names:

| action | args | returns |
|---|---|---|
| `calendar_status` | — | `sources: {:array, :map}` (per-source status incl. invalid-config entries; plus `"feed_enabled"`, `"valea_event_count"`) |
| `setup_calendar_source` | `source, name, generation` | `"saved" => true` (slug-validated; config write + supervisor rehash) |
| `set_calendar_source_url` | `source, url (sensitive), generation` | `"accepted" => true` (HTTPS-only validation; RAM + used for `.source` claim) |
| `remove_calendar_source` | `source, generation` | `"removed" => true` (config removal + engine stop; files stay) |
| `purge_calendar_source_files` | `source, confirmation, generation` | `"purged" => true` (typed confirm = slug; runs THROUGH the Supervisor's per-slug lifecycle serialization: refuses while the source is still configured (`remove_calendar_source` first — the rehash stops its engine), awaits any in-flight pass task, re-checks the slug is still unconfigured, then deletes `sources/calendar/<slug>` (slug-validated + `Paths.resolve_real` containment) and clears its index + sync-state rows in the same operation — a degraded-but-polling engine can never resurrect a purged mirror) |
| `calendar_sync_now` | `source, generation` | `"started" => true` |
| `calendar_doctor` | `source, generation` | `"ok" =>, checks:` |
| `list_calendar_events` | `from, to (ISO dates), zone (IANA name)` | `events: {:array, :map}` — the range is the half-open interval `[from, to)` interpreted in `zone` (the client's display zone, validated against the tz database). Timed rows match by OVERLAP: `occ_start < zone_end AND occ_end > zone_start` (never a start-only filter — an event straddling the range boundary is included); all-day rows match by date-range overlap of `[start, end)` against `[from, to)`. Rows come back in chronological order IN `zone` (per day: all-day rows first, then timed by local start), valea live-read events merged under the same rule. Tagged shape: `all_day: false` → UTC instants, `all_day: true` → plain dates with exclusive end; each row carries source, and for valea events the file path |
| `create_valea_event` | `name, title, start, end, all_day, location, status, description, generation` | `"created" =>, path:` (refuses existing name; `name` is a bare basename without extension — separator/traversal rejected before path construction, the get_mail_draft posture) |
| `update_valea_event` | `name, title, start, end, all_day, location, status, description, generation` | `"updated" => true` (full-replace write of the named file) |
| `delete_valea_event` | `name, confirmation, generation` | `"deleted" => true` (typed confirm = name) |
| `enable_calendar_feed` | `generation` | `"token" =>` (plain, once) |
| `rotate_calendar_feed_token` | `generation` | `"token" =>` (plain, once) |

Channel pushes on `workspace:events` (source-tagged):
`calendar_status` (one source's status map), `calendar_synced`
(`{source, event_count}`), `calendar_local_changed` (fired from the
valea-event RPC write paths; agent-written files surface on the next
query — live-read, no watcher).

## UI

- `/calendar` route: delete `placeholder-week.ts`; a `CalendarStore`
  (sources/window/events shape, push-wired like mail) holds the RPC
  occurrence rows. The existing grid contract is NOT the RPC shape —
  `calendar-shapes.ts` gains an explicit adapter,
  `occurrenceToGridEvents(row, hostZone)`: for TIMED rows converts UTC
  instants to host-local wall time and splits multi-day occurrences
  into one grid segment per local day (`day`/`startMin`/`endMin`); for
  ALL-DAY rows uses the plain dates DIRECTLY (no zone conversion,
  `[start, end)` exclusive split) and routes them to the grids' all-day
  lane (new — `WeekGrid`/`MonthGrid` gain
  an all-day row), and maps kind: external+confirmed → `booked`,
  external+tentative → `hold`, valea → `block` (CANCELLED occurrences
  are already removed at expansion). `EventCard`/`WeekGrid`/`MonthGrid`
  gain a selection callback prop (`onSelect(event)` — today they have
  none); the route's placeholder rail is replaced by a source legend
  (deterministic color per slug) + upcoming-events list. External
  events: read-only (select → detail popover: title, local time,
  location, source, description). Valea events: same popover +
  Edit/Delete; a "New event" button opens the small editor panel
  (title, start/end or all-day, location, description) →
  `create_valea_event`. The stale route comment about the deleted
  approval queue is replaced.
- Setup panel: source list with per-source status/doctor/typed-confirm
  purge, add-source form (slug, name, URL → keychain via
  `keychainSet(workspaceId, "<slug>:ics", url)` then
  `set_calendar_source_url`), and the served-feed block (enable, URL +
  copy, rotate, the honest reachability note).
- Today page: a calendar line per the cockpit's lenient pattern —
  `N events today · next: <time> <title>` — computed backend-side in
  `Valea.Cockpit` from the index.
- Session entry: "Plan my week" style actions are NOT specced here; the
  calendar mount + `include_mounts` already lets any session opt in.

## Doctor (`Valea.Calendar.Doctor`)

Per source, sequential, gated: `config_present` → `url_present`
(keychain/env) → `reachable` (conditional GET, status + TLS) →
`parse_ok` (count parseable events, surface per-component notices) →
`freshness` (last successful sync age vs 2× interval). Plus a
`feed_endpoint` check (token configured, route answering) shown in the
setup panel's feed block. Every check carries a copyable remedy; the URL
is never echoed in any detail/remedy string.

## Error handling

Per-source isolation (one broken feed degrades one source). Fetch/parse
failures leave the last good mirror + views + index intact. Engine-owned
files damaged out-of-band are rebuilt on the next successful pass
(replace-mirror makes this trivial — no quarantine machinery needed
beyond invalid valea-event listing). `invalid_config` entries surface in
`calendar_status` exactly like mail's. Feed-serving failures (bad token,
disabled) are 404 without detail.

## Testing

- Parser: table/property tests for unfolding, escaping, parameter
  quoting, DATE/DATE-TIME/DURATION forms, and RRULE expansion (COUNT,
  UNTIL, INTERVAL, BYDAY ordinals, BYMONTHDAY, EXDATE, RDATE, overrides,
  cancelled overrides, iteration cap, unsupported-part fail-soft) +
  fixture feeds captured from Google, iCloud, Infomaniak, and Outlook
  exports (committed under `test/fixtures/ics/`), including: a master
  with multiple overrides (distinct view paths, correct replacement), a
  DST-boundary series with EXDATEs (both the ambiguous roll-back hour
  and the nonexistent spring-forward hour, asserting the pinned
  earlier-instant / after-gap choices), Windows-TZID events, a
  THISANDFUTURE override (whole series unsupported), and unsupported
  BYWEEKNO (no fabricated single occurrence).
- Fetch: a scripted local HTTP(S) model server (the FakeImapServer
  pattern): 200/304/redirect-cap/CROSS-ORIGIN-redirect-rejected/
  private-range-target-rejected/oversize/timeout/TLS-failure/HTML-error
  -page cases.
- Engine: activation/identity binding, replace-mirror semantics (a
  shrunken feed removes rows/views), degraded-keeps-mirror, empty-feed
  guard, single-flight, per-source isolation, crash self-heal (kill
  between the feed.ics swap and the derive → next activation converges
  to the committed snapshot), stale-derive repair THROUGH a 304 (failed
  derive + subsequent 304 pass → re-derive via the marker), the
  TWO-STORE completion checks (kill between the views swap and the
  SQLite commit → derived_rev mismatch → re-derive; and the inverse),
  host-zone change re-derive, and purge-vs-degraded-engine
  serialization (purge after remove during an in-flight pass → pass
  awaited, no resurrection).
- Local calendar: validation table (incl. control chars, symlinks,
  date sanity, all-day exclusive-end incl. equal-dates rejection),
  UID stability across edits, render escaping (agent text
  with ICS metacharacters stays inert), served-feed token
  (constant-time compare, rotate invalidates, no parameters honored).
- Policy: the mail deny-suite shape for the calendar tier (unmounted
  deny-not-ask incl. case/NFD variants, in-scope write surface =
  `valea/events/` only, engine-owned write denies, managedSettings
  mirror).
- FE: vitest for CalendarStore + shapes (merging, coloring, editor
  round-trip, feed block).
- RPC: the mail_rpc_test shape for every action incl. typed confirms and
  generation guards; `list_calendar_events` range tests: a timed event
  straddling the range start is included (overlap, not start-filter), a
  UTC-date-vs-local-date boundary event lands on the correct local day,
  all-day exclusive-end overlap, and mixed ordering (all-day before
  timed per local day).

## Non-goals

No CalDAV, no OAuth, no Microsoft Graph. No provider writes (the seam:
valea event files → future push increment). No invites/attendees/ITIP,
no alarms/notifications, no meeting scheduling. No recurrence AUTHORING
in the Valea calendar (v1 creates single events; recurring events come
from external feeds). No remote feed reachability (loopback only,
documented). No per-feed mounts (one calendar mount).

## Change map

- **New:** `backend/lib/valea/calendar/` (`ics.ex`, `fetch.ex`,
  `engine.ex`, `supervisor.ex`, `local.ex`, `views.ex`, `store.ex` +
  resources, `doctor.ex`, `source.ex` — identity file), `Valea.Api.Calendar`,
  the feed controller route, `config/calendar.yaml` handling
  (`settings.ex` v1), FE `stores/calendar.svelte.ts`, calendar setup
  panel + event editor components, ICS fixtures, the `tzdata` dep
  (configured as the Elixir time-zone database).
- **Modified:** `Valea.Mounts` (+ `:calendar` kind; generalized
  include_mounts validation), `Valea.Agents.PermissionPolicy` +
  `SessionSettings` (calendar tier; extract shared casefold helpers),
  `Valea.Cockpit` (+ calendar line), workspace events channel (+ three
  pushes), router (+ feed route), `frontend/src/routes/calendar/+page.svelte`
  (real data; delete `placeholder-week.ts`),
  `frontend/src/lib/components/calendar/{calendar-shapes.ts,WeekGrid,MonthGrid,EventCard}`
  (adapter, all-day lane, selection callbacks), keychain docs (`<slug>:ics`),
  `docs/ARCHITECTURE.md` (+ Calendar section), workspace template
  (`config/calendar.yaml` replaced with the v1 shape;
  `sources/calendar/valea/events/.gitkeep`).
- **Deleted:** `frontend/src/lib/components/calendar/placeholder-week.ts`.

## Execution notes

Suggested build order: ICS parser (+ fixtures) → fetch module → settings
+ store → engine + supervisor → views/index integration → local calendar
+ render + served feed → mounts + policy → RPC + codegen → FE store +
route wiring → setup panel + editor → cockpit + doctor + docs. The
parser and the policy tier are the review-critical pieces (opus-grade
review); most of the rest follows mail patterns mechanically. Live
acceptance (post-merge, by the user): subscribe a real Google secret
address + one iCloud/Infomaniak feed, verify recurring events against
the provider's own UI for a known week, create a Valea event and
subscribe Calendar.app "On My Mac" to the served feed.
