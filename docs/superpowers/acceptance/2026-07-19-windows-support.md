# Windows support — CI gates + live acceptance checklist

Three lists, in order. The **batched CI gates** are the native-Windows
runs that every task on the `windows-support` branch deferred (no Windows
runner exists locally, and the branch had no remote while it was built) —
they must go green before any of the VM drills below mean anything. The
**acceptance drills** (A–G) are the spec's seven manual items, run on a
Windows 11 VM against a real NSIS install. The **post-gate cleanups** are
the small edits this branch deliberately left for after the gates. Spec:
`docs/superpowers/specs/2026-07-19-windows-support-design.md`; runbook:
`docs/RELEASING.md` "Windows".

---

## Batched CI gates (do these first)

CI1–CI4 come from ONE `workflow_dispatch` of
`.github/workflows/windows-bringup.yml`; **CI5 is a manual check on the
VM** and **CI6 dispatches a different workflow** (`release.yml`). The
numbering below is by concern, NOT the workflow's step order — that order
is: paths suite (CI2) → build SPA + sidecar + shim (CI1's harvest) →
backend suite (CI3) → NSIS bundle → shim suite (CI4). The suite runs
first on purpose: it needs no bundle, so a red there costs a minute
instead of a build.

One run, but each step is a **separate gate** — read them individually,
and don't let a green summary hide a step that never executed because an
earlier one failed. Everything here is a first execution: none of this
code has ever been compiled or run on Windows.

- [ ] **CI1 · T1 survey harvest.** From the "Build SPA + Burrito sidecar
      (+ spawn shim)" step's log, confirm three things the packaging path
      assumes:
      (a) Burrito's output is named exactly
      `backend/burrito_out/valea_desktop_windows_x64.exe` — the Justfile's
      `cp` hardcodes that name and a different Burrito naming convention
      breaks staging; (b) `unzip` was present for the pinned-zig fetch
      (`backend/scripts/build-release.sh` uses `unzip -qo` on the Windows
      zip, unlike the `tar.xz` path everywhere else); (c) `exqlite`
      compiled its sqlite3 amalgamation with MSVC and `mdex` either
      resolved a `rustler_precompiled` artifact or compiled with the
      runner's Rust. Any of these failing is a packaging fix, not a code
      fix — record which.
- [ ] **CI2 · T3/T4 paths + containment gate.** The "Paths containment
      suite (gating)" step: `paths_test.exs` and `paths_boundary_test.exs`
      plus the suites of every module whose containment calls were
      rewired onto `Valea.Paths` (mounts, permission policy, ICM, symlink
      containment, ICM RPC, calendar local, files controller). These
      exercise real OTP path functions and the real filesystem — drive
      letters, UNC roots, the root floor, case-folded containment, 8.3
      short-name denial — which is exactly what the pure suite on macOS
      cannot prove.
- [ ] **CI3 · T6/T7 full backend suite.** The "Backend suite (gating)"
      step, with `VALEA_SPAWN_SHIM` pointed at the STAGED shim. Gating,
      not a survey: a red run is a Windows regression. The uploaded
      `windows-test-run.txt` artifact is the record — keep it with this
      checklist. Expect the platform fixtures (`tasklist` twins of the
      `pgrep`-based process tests) and the `PortShim` adapter path to be
      the interesting parts.
- [ ] **CI4 · T5 `valea-spawn` shim suite.** The
      `cargo test --release --test spawn_shim` step — the first time the
      shim's Windows behavior is **executed and asserted** anywhere. It
      proves the B2 contract that exists nowhere else: tree kill on stdin
      EOF, capped stderr file, exit-code mirror, `COMSPEC /d /s /c`
      quoting for `.cmd` targets, exit 64 on an embedded-`"` argument to a
      batch target.
      Compilation credit, so a failure is read at the right step: the shim
      binary first compiles earlier, inside CI1's `just package-backend`
      (`cargo build --release --bin valea-spawn`); the sidecar's Job Object
      (spec E1, `src/winjob.rs`) is in neither — it belongs to the main app
      binary and first compiles in the "Build NSIS bundle (no release)"
      step.
- [ ] **CI5 · ClaudeCode install-location candidates (manual, on the VM).**
      Not a CI step — `Valea.Harnesses.ClaudeCode`'s
      `search_install_locations/1` (**private — verify through the agent
      doctor's `adapter` row, not an IEx call**) guesses where a real
      Windows install of the ACP adapter lands, and the guesses have never
      been checked against one. Install the harness
      on the VM the way a user would (npm global), then confirm the
      resolved path is one of the probed candidates, derived from the
      CONFIGURED command name (`claude-agent-acp` by default, never a
      hardcoded `claude.exe` — that's the interactive CLI, a different
      protocol): `%APPDATA%\npm\<cmd>.cmd`,
      `%USERPROFILE%\.local\bin\<cmd>.exe`,
      `%USERPROFILE%\.local\bin\<cmd>.cmd`. If the real install lands
      elsewhere, add that candidate to the list.
- [ ] **CI6 · `release.yml` Windows dry run.** `gh workflow run
      release.yml` once CI1–CI4 are green: the release lane must produce
      `bundles-windows_x64` containing an NSIS `.exe` and its `.sig`. This
      is the run that proves the matrix row itself (BEAM install on
      `runner.os != 'macOS'`, the job-level `shell: bash` default, the
      NSIS artifact globs) — the bring-up lane proves the suites, this one
      proves the lane.

---

## A — Install, boot, agent round-trip (spec acceptance 1)

- [ ] **A1 · Fresh install.** Download the NSIS `.exe` from the dry-run
      artifact (or the draft release) onto a clean Windows 11 VM and
      install it. Expect SmartScreen's "Windows protected your PC" (the
      installer is unsigned — More info → Run anyway); this is the
      documented state, not a failure. App launches, onboarding appears.
- [ ] **A2 · Workspace + ICM.** Complete onboarding, create a workspace,
      create an ICM. Expect the profile at
      `%LOCALAPPDATA%\valea\workspaces\<uuid>\` — **not** under
      `%APPDATA%`/Roaming (spec A6). The ICM folder lands wherever you
      chose it, with the 3-layer seed inside.
- [ ] **A3 · CLAUDE.md symlink fallback.** On this VM with **developer
      mode OFF** (check Settings → System → For developers first; symlink
      creation without it needs elevation), open the freshly created
      ICM's `CLAUDE.md` in Notepad. Expect the literal one-line file
      `@AGENTS.md` — the copy fallback — and **no error surfaced anywhere
      in the UI**; ICM creation must not have complained. Verify, don't
      build: the fallback already exists in `Valea.Mounts.link_claude_md!/1`;
      this drill is the proof it is what Windows actually takes.
- [ ] **A4 · Agent session round-trip.** Start a session in that ICM.
      Expect: spawn, streamed response, a permission ask on a write that
      you approve, the write landing, and Stop actually stopping it. The
      agent's stderr should exist as a flat file under the workspace's
      `logs\sessions\` (the shim writes it; an empty file is fine, a
      missing one is a bug).
- [ ] **A5 · No orphans (Task Manager).** Quit the app from its window,
      then open Task Manager → Details. Expect **none** of:
      `valea-server.exe`, `valea-spawn.exe`, the Burrito-extracted
      `erl.exe`, or the harness's `node.exe`. This is the Job-Object contract at both levels
      (shell-owned Job for the sidecar, shim-owned Job for the agent
      tree); a survivor here is spec E1/B2 failing, and the most likely
      single point of failure on the whole list.
- [ ] **A6 · Doctor is honest.** Open the agent doctor and the ICM
      doctor. Expect `node` and `adapter` rows resolved (CI5), and a
      "watcher live" row that reads `ok` for a local mount — or, if the
      `file_system` backend didn't start, `unknown` **with a reason**,
      never a mysterious stale `failed` (spec A5).

## B — Mail on NTFS (spec acceptance 2)

- [ ] **B1 · Connect + full sync.** Add an IMAP account through the setup
      panel. Expect the password to land in Credential Manager (Windows
      Credentials → the app's bundle identifier, account
      `<workspace-id>:<slug>:imap`) and a full sync to complete.
- [ ] **B2 · IMAPS trusts the OS store (spec A4).** The connection above
      must succeed against a public CA with no extra configuration —
      `Valea.Mail.ImapClient` dials `verify: :verify_peer` against
      `:public_key.cacerts_get()`, which reads the Windows system store on
      OTP ≥ 25.1. This is the whole A4 verification; a TLS failure here is
      an OTP/platform finding, and there is deliberately no insecure
      escape hatch to fall back on.
- [ ] **B3 · `;2,` filenames on disk.** In
      `%LOCALAPPDATA%\valea\workspaces\<uuid>\sources\mail\<slug>\`:
      `.account` contains `maildir_separator: ";"`, and the files under
      `maildir\cur\` end in `;2,` + flag letters. No `:` anywhere in a
      filename (it could not exist on NTFS — that is the point).
- [ ] **B4 · Flags round-trip.** Mark a message read/unread in Valea,
      re-sync, and confirm the flag letter changes in the `cur\` filename
      AND on the server (check from another client). Then declare a move
      op and let the engine execute it — the message moves on the server
      and its file moves locally, with the `;2,` naming preserved.
- [ ] **B5 · Derived views render.** Open the account's `views/` in the
      UI: message pages render with frontmatter, attachments listed, and
      the read pane's folder/flags meta line agrees with the filenames
      from B3.
- [ ] **B6 · Corrupt `.account` reads as a file problem.** Quit, hand-edit
      `.account` to `maildir_separator: "|"`, relaunch. Expect the account
      blocked inert with the error line pointing at the `.account` file
      being unreadable — **not** the raw
      `invalid maildir_separator in .account`, and not copy that implies
      purging the mirror. Restore the file, relaunch, account recovers.

## C — Calendar (spec acceptance 3)

- [ ] **C1 · Feed in.** Add an ICS source. Expect state `idle`, an event
      count, `sources\calendar\<slug>\` with `.source`, `feed.ics`, and
      `views\events\*.md`, and events on the week grid at the right local
      times (the Windows-zone mapping is exercised here — see
      `Valea.Calendar.WindowsZones`).
- [ ] **C2 · Served feed out.** Create a Valea event, enable the served
      feed, and fetch its URL from a browser on the VM. Expect the event
      in the ICS payload.

## D — Crash recovery (spec acceptance 4)

- [ ] **D1 · Kill mid-session → relaunch.** Start an agent session, then
      End Task on the app from Task Manager while it is streaming.
      Relaunch. Expect: **no PortCollision dialog**, nothing left
      listening on 4817 (`netstat -ano | findstr :4817` before relaunch
      should be empty — the shell's Job Object took the sidecar down with
      the app), and the previous session's transcript intact.

## E — Auto-update (spec acceptance 5, E3)

- [ ] **E1 · `latest.json` has the Windows entry.** On the draft release
      for version N+1, open `latest.json` and confirm a `windows-x86_64`
      platform entry alongside `darwin-aarch64` and `linux-x86_64`, whose
      `url` points at the NSIS `.exe` and whose `signature` is non-empty.
      Missing entry = the Windows lane failed silently; do not publish.
- [ ] **E2 · N → N+1 in place.** With version N installed on the VM,
      publish N+1. Within ~90 s of launch (or on the 6-hourly check) the
      amber notice appears at the bottom of the sidebar; download
      completes; "Restart to update" runs the installer in **passive**
      mode and the app comes back as N+1. The frontend's relaunch call
      never being observed is expected on Windows (the installer restarts
      the app) — that is not a hang.

## F — Cross-OS workspace, honest failure (spec acceptance 6)

- [ ] **F1 · The legacy `:` rule survives the host (no silent rewrite).**
      Bring a mac-created workspace to the VM whose
      `sources\mail\<slug>\.account` either says `maildir_separator: ":"`
      or omits the field entirely (legacy). Open it and re-read that file:
      it must be **unchanged**. A store's separator is chosen once, at
      creation, and the file outranks the host — a Windows launch must
      never flip an existing store to `;` and start writing two naming
      conventions into one maildir.
- [ ] **F2 · The hard edge is honest, not a crash.** The corollary of F1
      is that such a store cannot actually work on NTFS, and the drill is
      to see *how* it fails. Copy a `:`-separator maildir onto NTFS the
      way a user would (Explorer, a zip, `robocopy`) and record what the
      copy itself did — `:` is not a legal NTFS filename character, so
      the names are refused, truncated, or rewritten *before Valea is
      involved*. Then open it: expect an honest blocked/empty account,
      never a crash, never a half-sync. Watch specifically for the sneaky
      failure — `name:2,S` is alternate-data-stream syntax on NTFS, so a
      write can appear to succeed while producing an invisible stream on
      `name`; if that is what happens, that IS the finding to record.
      RELEASING.md's "Moving a workspace between machines" is the
      user-facing statement of all this — correct it if reality differs.
- [ ] **F3 · Non-mail workspace travels.** A workspace with ICMs but no
      mail opens on the VM with paths normalized (drive letters, `\` vs
      `/`) and the tree browsable.

## G — Network share (spec acceptance 7)

- [ ] **G1 · UNC-rooted ICM.** Share a folder from the host (or a second
      VM) and mount an ICM from `\\server\share\…`. Expect: browse, open
      and edit a page, and run an agent session inside it with a
      permission ask that resolves correctly.
- [ ] **G2 · `..` above the share root is denied.** Ask the agent (or use
      a path field) to reach `\\server\share\..\something` or
      `<icm>\..\..\outside`. Expect a deny from the root floor — the walk
      must not climb above `\\server\share`.
- [ ] **G3 · Watcher says best-effort.** Open the ICM doctor with that
      mount enabled. Expect its "watcher live" row's detail to carry
      "(best-effort on network paths)" for the UNC root. Then edit a file
      on the share from the *server* side and confirm the tree still
      catches up on navigation/RPC even if no live event arrives — that is
      the designed behavior, not a bug.
- [ ] **G4 · The D7 limit is real, and stated.** Optional but worth
      seeing once: create a junction on the *server* side inside the
      shared folder pointing outside it, and confirm Valea's containment
      does not see it (the client cannot). Nothing to fix — this is the
      documented trust-boundary limit (ARCHITECTURE.md "Trust model",
      RELEASING.md "Windows"). If containment DID catch it, the docs are
      overly pessimistic and should be corrected.

---

## Post-gate cleanups

Do these once the gates are green and the drills are done — each one is a
small edit this branch deliberately left undone:

- [ ] **Retire the bring-up workflow.** Delete
      `.github/workflows/windows-bringup.yml` after its first fully-green
      dispatch AND a good `release.yml` Windows dry run (CI6). Until both,
      it is the branch's only Windows gate. Drop the "Pending gates"
      subsection from `docs/RELEASING.md` "Windows" in the same commit.
- [ ] **MERGE NOTE — E2 overlay chrome.** This branch added
      `frontend/src/lib/shell/platform.ts` (`overlayChrome()` =
      desktop AND macOS UA) but changed no component: the overlay
      title-bar code it exists for — `Sidebar.svelte`'s `pt-12` brand band
      with its `data-tauri-drag-region`, and `+layout.svelte`'s fixed top
      drag strip — is uncommitted work in the main tree that merges
      later. **When the two meet, switch those files' `desktop` consts
      from `inDesktop()` to `overlayChrome()`.** Left as-is, Windows gets
      a dead ~48px strip under a real title bar. Verify by emulating a
      non-mac UA in devtools: brand band back to `pt-4`, no dead strip;
      macOS unchanged.
- [ ] **IMAPS OS-trust result (spec A4) → docs.** If drill B2 surprises
      (OTP not reading the Windows certificate store), record it in
      RELEASING.md; the spec's risk table lists this as "expected fine,
      unverified" and this checklist is where it becomes a fact either
      way.
- [ ] **Updater manifest (spec E3) → standing publish gate.** Drill E1's
      `windows-x86_64` check is already written into RELEASING.md's
      "Cutting a release" step 4. Confirm it once against a real tag, then
      it stops being an acceptance item and stays a do-not-publish
      condition.
- [ ] **Flip the spec index line.** `docs/ARCHITECTURE.md`'s
      windows-support entry currently reads **Shipped (Windows lane gated
      on the branch's first green bring-up dispatch + VM acceptance)** and
      points here. Once this file is fully ticked, drop the parenthetical.
