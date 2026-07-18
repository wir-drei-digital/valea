# Valea browser test plan (reusable)

A full-app manual/agent-driven browser regression pass. Run it after any
phase merge or before a release. Each check states the action and the
expected result; anything off-expectation is a finding — fix small things
immediately, file bigger ones. This plan deliberately avoids real external
accounts: live-provider drills (real IMAP, real ICS feeds, Calendar.app
subscriptions, OS keychain) live in `docs/superpowers/acceptance/` and are
NOT repeated here.

## Environment

The run must never touch the developer's real app data
(`~/Library/Application Support/valea`): dev mode auto-opens the recorded
`last_opened` workspace from whatever `VALEA_APP_DIR` resolves to.

1. Fresh isolated app dir per run:
   `export VALEA_APP_DIR=$(mktemp -d)/valea-browser-test`
2. Backend: `cd backend && VALEA_APP_DIR=... mix phx.server` (port 4200,
   dev control token `valea-dev-token` per `config/runtime.exs`).
3. Frontend: `cd frontend && VITE_VALEA_CONTROL_TOKEN=valea-dev-token bun
   run dev` (port 4273, proxies `/api`+`/rpc`+`/files`+`/socket` to 4200).
4. Browse `http://localhost:4273`. Browser mode means NO keychain
   (`inDesktop() === false`): credential fields use the env fallbacks
   (`VALEA_MAIL_PASSWORD_<SLUG>`, `VALEA_CAL_URL_<SLUG>`) — set them on the
   BACKEND process when a leg needs them.
5. Wrap-up: kill both servers, `rm -rf` the app dir, run `cd backend &&
   just test` if any fix touched code.

Known browser-mode limits (do not report as bugs):
- Keychain writes silently no-op (`keychainSet` resolves false) → the
  calendar add-source flow reports "URL not durably stored" — expected.
- External calendar feeds cannot point at localhost (the fetcher's SSRF
  guard rejects loopback by design); real-feed behavior is acceptance-only.
- Agent sessions need a real `claude` binary on the backend's PATH; if
  unavailable, verify the session UI's error surfacing instead.

## A — Onboarding + workspace

- [ ] A1 Fresh app dir → the app shows onboarding (Start fresh / Use
      existing), no console errors, no unstyled flash.
- [ ] A2 "Start fresh" with a name → workspace opens; sidebar shows the
      starter ICM; `VALEA_APP_DIR` contains the hidden id-based workspace
      with the v1-empty `config/calendar.yaml`, `config/mail.yaml`,
      `sources/calendar/valea/events/` (empty), CLAUDE.md symlink intact.
- [ ] A3 Reload the tab → same workspace reopens (last_opened), no
      re-onboarding.
- [ ] A4 Workspace switcher: create a second workspace, switch between
      them, recent list correct; no cross-workspace data bleed in any
      route (Today, Knowledge, Mail, Calendar).

## B — Shell, navigation, Today

- [ ] B1 All nav destinations render without console errors: Today,
      Knowledge/ICM, Sessions, Mail, Calendar, Audit (whatever the sidebar
      currently offers).
- [ ] B2 Today (empty state): honest "nothing prepared yet" copy; mail
      line absent when unconfigured; calendar line absent when no events.
- [ ] B3 Today (populated): after C/E legs create pages + events, the
      cockpit reflects them (calendar line: "N events today · next: …").
- [ ] B4 Dark mode / theme toggle (if present) and a narrow window: no
      broken layout in the main routes.

## C — Knowledge / ICM editor

- [ ] C1 Create a page from template + a blank page; edit, save; reload →
      content persists byte-stable (no converter drift on reopen).
- [ ] C2 Page links: type `[[` → picker; link to another page; backlinks
      panel shows the reference; rename the target page → link rewrites,
      backlinks intact.
- [ ] C3 Folder CRUD + rename with impact dialog; delete with reference
      warning.
- [ ] C4 Cmd+K search: finds by title + content; MRU ordering; dangling
      link affordance.
- [ ] C5 Image upload into a page: renders inline; file lands under the
      ICM; serve endpoint contained (URL is workspace-scoped).
- [ ] C6 today.json: hand-write one in an ICM root (prepared/open loops) →
      Today renders the section.

## D — Agent sessions

- [ ] D1 New session from Knowledge entry point (and Mail/Calendar entry
      points if present): session opens with the right cwd/mounts posture.
- [ ] D2 Chat round-trip with the real agent (if `claude` on PATH):
      response streams, transcript persists, recent-sessions list updates.
- [ ] D3 Permission ask-gate: have the agent attempt a write outside its
      grant → ask dialog appears; deny → agent sees denial; audit entry.
- [ ] D4 Sessions list: status chips (live/ended), reopen a past session
      transcript.

## E — Calendar (Spec F)

- [ ] E1 Empty route: grid renders (week/day/month switch, paging), rail
      shows the no-sources copy, "New event" + "Sources" buttons work.
- [ ] E2 Sources panel: add-source form validation (bad slug rejected,
      `valea` rejected, http:// URL rejected with the friendly HTTPS
      message — and NOTHING configured afterward); a syntactically valid
      https URL to a nonexistent host: source appears, goes degraded with
      a reason, mirror intact, doctor shows the failed `reachable` check
      with a remedy and NO URL anywhere in the output.
- [ ] E3 Valea events via UI: create timed (today) + all-day (multi-day,
      inclusive end in the editor) + tentative + cancelled; grid shows
      correct slots/lane/styles (block kind, strike-through for
      cancelled); files exist under `sources/calendar/valea/events/`;
      popover shows details; edit round-trips (all-day inclusive↔exclusive
      correct); typed-confirm delete removes file + grid entry.
- [ ] E4 Grid correctness: event spanning midnight renders split across
      days; all-day lane appears only when all-day events are visible;
      month view chips + "+N more"; day drill-down from month.
- [ ] E5 Served feed: enable → token shown once with copy + honest
      reachability copy; `GET /calendar/feed.ics?token=<t>` (backend port)
      returns text/calendar with the valea VEVENTs, correct escaping;
      wrong/missing token → 404 empty; extra params → 404; rotate →
      old token 404s, new one serves.
- [ ] E6 Live updates: with the route open, create an event file directly
      on disk (simulating an agent) → appears on next query/refresh;
      RPC-created events appear without reload (calendar_local_changed).
- [ ] E7 Invalid config: hand-break `config/calendar.yaml` (non-v1 junk) →
      setup panel + rail surface the reason; route stays usable; adding a
      source converges it back to v1 wholesale.
- [ ] E8 Today cockpit line matches E3's events for today.

## F — Mail (UI-level; live IMAP is acceptance-only)

- [ ] F1 Mail route empty state → setup panel; add-account form validation
      (slug grammar, port, required fields); submit against a dead host →
      honest error state, config written, account listed with its state.
- [ ] F2 Doctor renders the gated checks with remedies for the dead host;
      no credential text anywhere.
- [ ] F3 Account maintenance affordances: remove; typed-confirm purge
      refuses wrong confirmation text; re-adopt/discard controls render.
- [ ] F4 (Optional, if local Dovecot installed) point an account at the
      scripts/dovecot instance: INBOX lists, message opens, archive/flag
      ops round-trip, drafts panel + push-to-drafts.

## G — Audit + cross-cutting

- [ ] G1 Audit route lists the run's actions (session asks, mutations)
      with sane timestamps.
- [ ] G2 RPC error surfacing: stop the backend with the app open → routes
      degrade honestly (no white screens); restart → app recovers
      (socket rejoin, stores refresh).
- [ ] G3 Console sweep: zero uncaught errors across the whole run
      (warnings triaged).
- [ ] G4 The served-feed + files endpoints reject requests without their
      tokens (spot-check with curl).

## Wrap-up

- [ ] Re-run `cd backend && just test` if any code changed during the run.
- [ ] Record findings + fixes in the run summary (not in this file); keep
      this plan updated only when the APP's surfaces change.
