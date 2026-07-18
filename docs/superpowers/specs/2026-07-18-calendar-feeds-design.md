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
  intact. No cross-store transaction is needed because derived state is
  never the authority.
- `.source` binds the slug to its feed (host + URL fingerprint). A slug
  whose keychain URL no longer matches `.source` refuses to sync
  (`identity_mismatch`, resolved by purge) — same posture as mail's
  `.account`, preventing one feed's mirror from being silently overwritten
  by a different feed reusing the slug.

## Config and credentials

`config/calendar.yaml` (v1 — no earlier format exists, no migration):

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
  not the parser). All index times are stored as UTC instants plus an
  `all_day` flag (all-day events stored as dates; floating times are
  resolved against the host zone AT DERIVE TIME and re-derived on every
  pass, so a host-zone change corrects itself on the next sync).
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
mail supervisor/engine pattern minus everything two-way:

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
  be < `end` (or `end` omitted for a 1-hour default; all-day: end date ≥
  start date); dates must parse as ISO 8601 with offset or as plain dates
  when `all_day`; body length capped (16 KB). A file that fails validation
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
  live from their files at query time): source, uid, occ_start (utc),
  occ_end (utc), all_day, summary, location, status, view_path. One row
  per expanded occurrence within the window. Indexed on
  (occ_start, occ_end).
- `calendar_sync_state`: source, etag, last_modified, last_sync_at,
  last_error.

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
| `purge_calendar_source_files` | `source, confirmation, generation` | `"purged" => true` (typed confirm = slug; refuses on healthy running engine) |
| `calendar_sync_now` | `source, generation` | `"started" => true` |
| `calendar_doctor` | `source, generation` | `"ok" =>, checks:` |
| `list_calendar_events` | `from, to (ISO dates)` | `events: {:array, :map}` (occurrence rows; each carries source, and for valea events the file path) |
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
  (accounts/window/events shape, push-wired like mail) feeds the existing
  `WeekGrid`/`MonthGrid`/day view with merged real events, colored by
  source (deterministic color from slug). The stale route comment about
  the deleted approval queue is replaced. External events: read-only
  (click → detail popover: title, time, location, source, description).
  Valea events: same popover + Edit/Delete; a "New event" button opens
  the small editor panel (title, start/end or all-day, location,
  description) → `create_valea_event`.
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
  DST-boundary series with EXDATEs, Windows-TZID events, a
  THISANDFUTURE override (whole series unsupported), and unsupported
  BYWEEKNO (no fabricated single occurrence).
- Fetch: a scripted local HTTP(S) model server (the FakeImapServer
  pattern): 200/304/redirect-cap/CROSS-ORIGIN-redirect-rejected/
  private-range-target-rejected/oversize/timeout/TLS-failure/HTML-error
  -page cases.
- Engine: activation/identity binding, replace-mirror semantics (a
  shrunken feed removes rows/views), degraded-keeps-mirror, empty-feed
  guard, single-flight, per-source isolation, and crash self-heal (kill
  between the feed.ics swap and the derive → next activation converges
  to the committed snapshot).
- Local calendar: validation table (incl. control chars, symlinks,
  date sanity), UID stability across edits, render escaping (agent text
  with ICS metacharacters stays inert), served-feed token
  (constant-time compare, rotate invalidates, no parameters honored).
- Policy: the mail deny-suite shape for the calendar tier (unmounted
  deny-not-ask incl. case/NFD variants, in-scope write surface =
  `valea/events/` only, engine-owned write denies, managedSettings
  mirror).
- FE: vitest for CalendarStore + shapes (merging, coloring, editor
  round-trip, feed block).
- RPC: the mail_rpc_test shape for every action incl. typed confirms and
  generation guards.

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
  (real data; delete `placeholder-week.ts`), keychain docs (`<slug>:ics`),
  `docs/ARCHITECTURE.md` (+ Calendar section), workspace template
  (`sources/calendar/valea/events/.gitkeep`).
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
