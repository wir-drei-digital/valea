# Calendar (Spec F) — live acceptance checklist

Manual checks against real providers, run post-merge by Daniel. The
automated suite covers every pinned protocol behavior; these drills prove
the pieces that only real feeds, the real keychain, and real calendar
apps can prove. Spec: `docs/superpowers/specs/2026-07-18-calendar-feeds-design.md`.

## A — Real feeds in

- [ ] **A1 · Google secret address.** In the setup panel add source
      `google` with your Google Calendar "Secret address in iCal format"
      URL. Expect: state reaches `idle`, an event count, and
      `sources/calendar/google/` containing `.source`, `feed.ics`, and
      `views/events/*.md` (open one view — frontmatter + description).
- [ ] **A2 · iCloud or Infomaniak feed.** Add a second source from the
      other provider family. Expect the same shape; both sources sync
      independently.
- [ ] **A3 · Recurring events vs the provider's own UI.** Pick a week with
      a recurring series you know (including one moved/cancelled instance
      and one all-day span). Compare the Valea week grid against the
      provider's web UI for that week: same instances, same local times,
      the moved instance in its moved slot, the cancelled one absent,
      the all-day span on the right days (exclusive-end handling).
- [ ] **A4 · Unsupported is visible, not silent.** If any source reports
      "N series unsupported" on its status line, confirm the series named
      in the notices genuinely uses an unsupported rule (or file a fixture
      follow-up if it looks supportable).
- [ ] **A5 · Degraded keeps the mirror.** Break one source (airplane-mode
      the network or revoke/regenerate the secret address), press "Sync
      now". Expect: source goes `degraded` with a reason, the grid still
      shows the last good events, doctor's `reachable` check fails WITH a
      remedy and WITHOUT the URL appearing anywhere. Fix the URL
      (re-add) and confirm recovery.

## B — Valea calendar out

- [ ] **B1 · UI event.** "New event" → create a timed event for today.
      Expect it on the grid immediately and as a file under
      `sources/calendar/valea/events/<name>.md`.
- [ ] **B2 · Agent event.** In a session with the calendar mount
      (bare-string `calendar` in related ICMs / include_mounts), ask the
      agent to create `valea/events/<name>.md` per the frontmatter format.
      Expect: the write goes through the normal permission ask, and the
      event appears on the grid on the next refresh (live read, no sync
      needed). Also confirm the agent CANNOT write outside
      `valea/events/` (e.g. a view file) — denied, and that a session
      WITHOUT the mount cannot even read `sources/calendar/`.
- [ ] **B3 · Served feed in Calendar.app.** Enable the feed, copy the URL.
      Calendar.app → File → New Calendar Subscription → paste, location
      "On My Mac". Expect the valea events (B1 + B2) to appear. Edit the
      B1 event in Valea, refresh the subscription — the change propagates
      (stable UID).
- [ ] **B4 · Token rotation.** Rotate the token. Expect the old
      subscription URL to fail on refresh (404) and a re-subscription with
      the new URL to work.

## C — Credentials + restart

- [ ] **C1 · Keychain entry.** Keychain Access → search the workspace id:
      a `<slug>:ics` entry exists per source; the URL appears in NO file
      under the workspace (`grep -r "<secret-path-fragment>" <workspace>`
      finds nothing).
- [ ] **C2 · Restart resupply.** Quit and relaunch the desktop app.
      Expect sources to come back syncing without re-entering URLs
      (silent keychain resupply), and the derive marker to have
      re-derived without a network fetch if the host zone or day changed.
- [ ] **C3 · Cockpit line.** Today page shows `N events today · next:
      <time> <title>` consistent with the grid.
