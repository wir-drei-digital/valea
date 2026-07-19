# Windows support — design

Date: 2026-07-19
Status: draft, ready for review
Scope: make Windows x86_64 a first-class desktop target — app runtime +
packaging + CI lane. Successor to the Windows section of
[the release spec](2026-07-19-release-auto-update-design.md) and
docs/RELEASING.md, which staged the pipeline but left the app blocked.

## Context & goal

The release pipeline (2026-07-19) ships macOS-arm and Linux-x64 with
auto-update; Windows was deliberately excluded because the app itself
cannot run there. This spec turns the RELEASING.md blocker list into a
design. Goal: a `windows-latest` lane in `release.yml` producing an NSIS
installer + signed updater artifact, and an app whose full product surface
— agent sessions, mail, calendar, knowledge, keychain — works on Windows
10/11 x64.

### Ground truth from the codebase (2026-07-19 investigation)

What is actually blocked, and what turned out to be already solved:

- **Real blocker — erlexec.** `Valea.Agents.ProcessRuntime` and
  `Valea.Agents.Doctor` spawn agent/probe processes via `:exec` (stdio
  pipes, `{:group, 0}` + `:kill_group`, monitor). erlexec is Unix-only,
  and worse than the boot-crash framing: its C++ port program **doesn't
  compile on Windows**, so `mix deps.compile` fails before a release is
  even assembled. Both the dependency and `extra_applications` inclusion
  must become conditional, and the spawn path needs a Windows adapter.
- **Real blocker — maildir separator.** `Valea.Mail.Maildir` encodes
  `msg_id[,U=n]:2,FLAGS`; `:` is illegal in NTFS filenames. Mitigating
  discovery: every durable record (ledger, occ state, reconcile, ops)
  stores structured `{msg_id, uid, flags}` and re-encodes filenames on
  demand through this ONE module — the separator is a filesystem-surface
  property, not a data-model property. No migration, no ledger change.
- **Real gap — path handling is Unix-shaped far beyond `paths.ex`.**
  Absoluteness-as-`String.starts_with?(path, "/")` and
  `prefix <> "/"`-style ancestor checks appear at **16 sites across 10
  modules** (Codex round 1 inventory): `Valea.Paths`,
  `Valea.Agents.PermissionPolicy` (×4), `Valea.Mounts` (×2),
  `Valea.ICM.Watcher` (×2), `Valea.Harnesses.ClaudeCode` (×2 — including
  the command gate that would reject `C:\…\claude-agent-acp.cmd` as
  non-absolute), `Valea.Icm`, `Valea.Api.Icm`, `Valea.Calendar.Local`,
  `ValeaWeb.FilesController`. (`Valea.ICM.Backlinks`'s `"/"` check is
  markdown-URL classification, not filesystem — exempt.) NTFS is also
  case-insensitive while every one of these compares case-sensitively.
  Today's behavior on Windows would be fail-closed (false `:outside`
  denials — broken UX, not a security hole), but the agent boundary must
  be *correct*, not accidentally safe, and the fix is an inventory-wide
  migration to one API, not a `paths.ex` touch-up (§D).
- **Already solved — CLAUDE.md symlink.** `Valea.Mounts.link_claude_md!/1`
  already falls back to writing a literal `@AGENTS.md` one-liner when
  `File.ln_s` fails (Spec D §D1 anticipated symlink-less filesystems).
  Windows without developer mode takes that branch automatically. Verify,
  don't build.
- **Already solved — keychain.** The desktop crate's `keyring` dependency
  ships with `windows-native` (Credential Manager) enabled since Phase 4.
- **New problem found — sidecar orphaning.** On Unix the Burrito wrapper
  `exec()`s into ERTS, so Tauri's `child.kill()` kills the real backend.
  Windows has no exec: the wrapper stays alive as a parent and
  `child.kill()` would kill only the wrapper, orphaning the BEAM on port
  4817 — every next launch would hit the PortCollision dialog. The shell
  must own a Job Object.

## Non-goals

- Windows **web** release (`valea` release target stays `[:unix]`); the
  desktop sidecar is the only Windows deliverable.
- Windows ARM, 32-bit, Windows Server, anything below Windows 10.
- A native Windows *contributor* dev environment (WSL2 is the documented
  dev path; only CI and the shipped app are native).
- Maildir interop with third-party Unix mail tools *on Windows* (the `;`
  separator is nonstandard by necessity; Unix stores keep `:`).

## A. Build & boot

**A1 — conditional erlexec.** The pipeline builds natively per platform
(release-spec invariant), so `mix.exs` may branch on the *build host*:
on `{:win32, _}` = `:os.type()`, drop `{:erlexec, …}` from `deps()` and
`:erlexec` from `extra_applications`. `ProcessRuntime` (the erlexec
adapter, A2) keeps its `:exec.*` remote calls — they only compile-warn if
xref is asked to check Erlang modules, which the suite doesn't — and is
never selected on Windows. Guard with a boot assertion: selecting the
exec adapter when `Code.ensure_loaded?(:exec)` fails is a supervisor-level
crash with a clear message, not a mystery downstream.

**A2 — Burrito target + packaging.** Add `windows_x64: [os: :windows,
cpu: :x86_64]` to the `valea_desktop` targets;
`include_executables_for: [:unix, :windows]`. `build-release.sh` gains a
`Windows_NT`/`MINGW*` host mapping (CI runs it under Git Bash) and fetches
the zig 0.15.2 **.zip** (Windows has no `.tar.xz`); the Justfile
`package-backend` recipe maps the host to `windows_x64` and copies
`burrito_out/valea_desktop_windows_x64.exe` →
`binaries/valea-server-x86_64-pc-windows-msvc.exe`. (Exact Burrito output
name to be confirmed in the first CI dry run — T1 acceptance includes it.)

**A3 — NIF/dep compile audit on Windows.** exqlite compiles its sqlite3
amalgamation with MSVC (runner has it); mdex resolves a
`rustler_precompiled` artifact or falls back to compiling with the
runner's Rust. Both are verify-tasks in T1, not design work.

**A5 — watcher availability model.** `file_system`'s Windows backend
(`inotifywait.exe` port) may be unavailable, and today that is a **boot
crash**, not degradation: `Valea.ICM.Watcher.init/1` and its dynamic
watcher path both hard-match `{:ok, _} = FileSystem.start_link(...)`
inside the workspace runtime supervision tree (watcher.ex:164, :350).
Design (both sites):

- `FileSystem.start_link` results are handled; a backend-start error puts
  the watcher process into an explicit `:disabled` state — it stays
  alive, subscribes to nothing, and dynamic-root recomputation becomes a
  no-op. One warning log at entry; no retry loop.
- Only backend *start* failures degrade; argument/config errors still
  crash (they're bugs, not platform gaps).
- Surfacing: the ICM doctor gains a "live file watching" check reporting
  on/off-with-reason, so "tree doesn't refresh" is diagnosable, not
  mysterious. UI copy unchanged otherwise — the tree still refreshes on
  navigation/RPC.
- Test: a start-error double proves a workspace still opens with the
  watcher disabled.

**A4 — TLS trust.** `Valea.Mail.ImapClient` dials `verify: :verify_peer`
against `:public_key.cacerts_get()`; OTP ≥ 25.1 reads the Windows system
store. Verify in T5 with a real IMAPS connect; no code planned.

## B. Agent runtime on Windows

The erlexec surface to replicate is small (108 lines): spawn with env +
cwd, stream stdout/stderr separately, write stdin, deliver exit code,
kill the whole tree. Erlang `Port`s cover everything except **stderr
separation** (a Port carries one input stream) and **tree kill** (closing
a Port abandons the OS process on Windows).

**B1 — `Valea.Agents.ProcessAdapter` behaviour** with the existing
message contract (`:runtime_output` / `:runtime_stderr` / `:runtime_exit`)
and `start/2`, `write/2`, `stop/1`. Unix adapter = today's
`ProcessRuntime`, renamed, byte-identical behavior. Selection once at
boot via `:os.type()`.

**B2 — `valea-spawn` shim (Windows adapter's other half).** A small Rust
binary, second `[[bin]]` in the existing `desktop/src-tauri` crate.

*Packaging & discovery (Codex round 1: previously unspecified):*

- Built by cargo **before** `tauri build` (external binaries must
  pre-exist): the Windows packaging step runs
  `cargo build --release --bin valea-spawn` and copies the output to
  `desktop/src-tauri/binaries/valea-spawn-x86_64-pc-windows-msvc.exe`,
  exactly like the sidecar copy the Justfile already does for
  `valea-server`.
- Declared as a second `externalBin` entry **only on Windows**, via
  Tauri's platform config merge (`tauri.windows.conf.json` with
  `bundle.externalBin: ["binaries/valea-server", "binaries/valea-spawn"]`)
  — macOS/Linux bundles don't carry a dead binary.
- Runtime handoff: `start_sidecar` (Rust) resolves the shim's installed
  absolute path (same resolution the shell plugin uses for sidecars —
  next to the app executable on Windows) and passes it to the backend as
  `VALEA_SPAWN_SHIM` on the `valea-server` spawn env, alongside
  `PHX_SERVER`/`PORT`/…. The Windows adapter reads it at boot; absent or
  non-existent ⇒ agent sessions fail fast with a doctor-visible
  "spawn shim missing" error (never a silent fallback to Port-only).

*Process contract:*

- argv = target program + args; env/cwd come from the Erlang Port's
  spawn options (the shim inherits and does not modify them).
- Creates a **Job Object with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`**,
  assigns the child, holds the handle for its own lifetime.
- **Three independent pump threads**, so no cross-stream backpressure
  deadlock: (1) shim stdin → child stdin; (2) child stdout → shim stdout
  unmodified (the NDJSON stream); (3) child stderr → the stderr file.
  Each pump is a blocking copy loop with its own buffer; a full/slow
  stream never stalls the others.
- **Stdin EOF ⇒ shutdown**: EOF on the shim's stdin (Elixir closed the
  Port — including the owning BEAM process dying) closes the Job handle
  (tree dies) and exits. `stop/1` = `Port.close/1`. No taskkill, no PID
  races.
- Child exit ⇒ stdout/stderr pumps drain to EOF, then the shim exits
  with the child's exit code; the Port's `:exit_status` becomes
  `:runtime_exit`. Signal-style terminations surface as the code Windows
  reports (non-zero), mapped to `:runtime_exit nil` only when unknown.

*Stderr file lifecycle:*

- Path supplied per spawn via `VALEA_SPAWN_STDERR_FILE`, allocated by the
  adapter under the session's transcript directory (unique per spawn:
  `<session>/stderr-<os_pid>.log`), created by the shim with
  share-read so the backend can read while the child runs.
- Size-capped (1 MiB): past the cap the shim stops writing and appends a
  single `[truncated]` marker on close.
- Consumption: no live tail. The adapter reads the file (bounded, tail
  portion) when the process exits and emits one `:runtime_stderr`
  message before `:runtime_exit`, preserving `SessionServer`'s existing
  contract — coarser than Unix's streamed stderr, and documented as the
  platform difference. Files ride along with session transcripts and
  share their retention.

*Tests (Rust, in-crate):* stdout flood (≥ 50 MB) with idle stderr;
stderr flood past the cap; kill-via-stdin-close mid-stream leaves no
child in the Job; exit-code fidelity; missing stderr-file path env ⇒
immediate failure exit.

**B3 — command resolution policy (Codex round 1).**
`Valea.Harnesses.ClaudeCode.resolve/2` currently accepts a configured
command only if it starts with `/`, else `System.find_executable/1` —
both halves are Unix-shaped. Policy: absolute-configured paths go through
the new `Valea.Paths` classifier (§D), so `C:\…\claude-agent-acp.cmd` is
absolute; bare names resolve with `.exe`/`.cmd`/`.bat` accepted —
`PATHEXT` semantics. Whether OTP's `find_executable` honours `PATHEXT`
fully is a T3 verify; if not, the resolver tries the extension list
itself. Launching `.cmd` targets goes through the shim unchanged (the
shim spawns via `CreateProcess`, which needs `cmd /c` for `.cmd` — the
shim owns that quoting, never the Elixir side).

**B4 — platform-aware minimal env.** `Valea.Agents.Env.@allowlist` is
Unix-only (`HOME USER LOGNAME LANG LC_* TMPDIR SHELL PATH` + the two
token vars). Same fixed-allowlist posture (never inherit-all, secrets
stay excluded), Windows adds: `USERPROFILE`, `APPDATA`, `LOCALAPPDATA`,
`PATHEXT`, `COMSPEC`, `SystemRoot`, `SystemDrive`, `TEMP`, `TMP`.
(`SystemRoot` in particular: many Windows programs, node included, fail
without it.) One list per platform, selected where the adapter is.

**B5 — doctor probes & test fixtures.** Doctor probes (`claude
--version` etc.) run through the adapter (keeps timeout+kill semantics).
Claude Code ships native Windows builds — the doctor's search list gains
the Windows install locations (`where claude`, `%LOCALAPPDATA%`
patterns), enumerated in T3. The doctor/process test fixtures are
Unix-hardcoded today (`#!/bin/sh` scripts, `chmod`, `pgrep`, `exec -a`):
suites split into portable core + platform fixture modules (`.cmd`
scripts and `tasklist` on Windows), tagged so each CI lane runs its own.

## C. Mail — maildir on NTFS

**C1 — per-store separator.** Durable source of truth (Codex round 1:
the "manifest" I hand-waved doesn't exist): the existing
**`sources/mail/<slug>/.account` file** (`Valea.Mail.Account` — already
the store-identity record, already written atomically via temp+rename)
gains a `maildir_separator: ":" | ";"` field, written once at store
creation and validated on read (any other value ⇒ the store fails
closed, like other identity mismatches). Rules:

- New stores: `;` on Windows, `:` elsewhere (`;` is the established
  maildir-on-Windows convention).
- **Absent field = legacy store = `:` always.** Never OS-defaulted on
  read — a Unix-created store opened via any future path on Windows must
  not silently flip its on-disk format (it fails per the hard edge
  below instead).
- `parse_filename/1` accepts both separators unconditionally.
- Threading: `encode_filename` gains the separator argument, sourced
  from the account/engine context that every caller already carries —
  the call sites are `SyncPass` (delivery, flag renames), `Reconcile`,
  `OpsExecutor` (moves, recovery, fallback lookup) and
  `MessageFile`-adjacent view derivation; no call site invents its own.
- Completeness test: one matrix exercising sync → flags → move →
  reconcile → recovery on a `;`-separator store, plus a mixed-parse test
  (both separators readable in one listing).

A store is created once and its separator never changes, so a workspace
moved cross-OS keeps reading and *writing* consistently — with one hard
edge: a `:`-separator store physically copied onto NTFS has illegal
names before Valea even opens it; that is a filesystem-level
impossibility we document (RELEASING "moving workspaces"), not code.

**C2 — tmp/new/cur mechanics.** The atomic delivery path
(write-to-`tmp`, rename into `new`/`cur`) works on NTFS within one
volume; verify rename-onto-existing behavior (`File.rename` semantics on
Windows differ for existing targets) in the maildir unit suite run on the
Windows CI lane.

**C3 — literal-filename audit.** Ledger/ops re-encode from structure
(verified), but derived views and `message_file.ex` frontmatter mention
maildir filenames — audit every site that *persists or parses* a literal
filename and route it through `parse_filename` tolerance. Grep-driven
task with a checklist in the PR description.

## D. Paths & containment (`Valea.Paths`, PermissionPolicy)

The agent boundary must hold on a case-insensitive, drive-lettered,
`\`-separated filesystem — and (Codex round 1) the Unix-shaped decisions
live at 16 sites across 10 modules (Ground truth), not just `paths.ex`.
This section is an **inventory-wide migration to one API**, not a local
fix.

- **D1 — one platform-aware API in `Valea.Paths`**, with our own
  classifier (OTP's `Path.type/1` is host-dependent — on a Unix host
  `Path.type("C:/x")` is `:relative` — so it can neither implement nor
  cross-platform-test Windows semantics):
  - `classify/1` → `:absolute` (`/x` on Unix; `C:/x`, `C:\x` on
    Windows), `:drive_relative` (`C:foo` — **rejected** as `:invalid`
    wherever a path is consumed), `:unc` (`\\server\…` and `\\?\…` —
    **rejected in v1**: Valea workspaces/ICMs live on local disks; UNC
    gets an honest "unsupported location" error, not undefined
    containment semantics), `:relative`.
  - `absolute?/1`, `ancestor?/2` (the `prefix <> "/"` idiom, done once,
    case-folded per D3), `normalize/1` (D2). Absolute walks start from
    the path's own root (`C:/`), never a hard-coded `"/"`.
- **D2 — normalization at ingress**: `normalize/1` applied where
  user/config paths enter (mount roots, adopt-a-folder, session cwd,
  configured agent commands): backslashes → `/`, drive letter
  case-folded, via `Path.expand` semantics.
- **D3 — containment**: comparisons case-insensitive on Windows
  (`String.downcase` both sides — NTFS default; per-dir
  case-sensitivity is out of scope and documented), unchanged
  (case-sensitive) on Unix.
- **D4 — call-site migration (the inventory)**: every
  absoluteness/ancestor/prefix decision in `PermissionPolicy` (×4),
  `Mounts` (×2), `ICM.Watcher` (×2), `Harnesses.ClaudeCode` (×2),
  `Icm`, `Api.Icm`, `Calendar.Local`, `FilesController` routes through
  the D1 helpers. `ICM.Backlinks` (markdown URLs) explicitly stays as-is.
  Acceptance for this task is the grep coming back empty:
  `String.starts_with?(…, "/")`-style path logic outside `Valea.Paths`
  is a review-blocking regression from then on.
- **D5 — 8.3 short names**: `resolve_real` walks literal components, so
  `DOCUME~1` aliases resolve to a *different string* than the long-name
  base and get denied (fail-closed — correct direction). Keep it that
  way; add a test pinning the denial so nobody "fixes" it into a bypass.
- **D6 — reparse points**: NTFS junctions/symlinks surface through
  `File.read_link` and take the existing symlink walk. OneDrive/Dropbox
  cloud-placeholder reparse points are documented as unsupported
  workspace/ICM locations (RELEASING note), not detected code.

Testing split (Codex round 1 corrected the original claim): the pure
suite covers **our own** classifier/normalizer/ancestor logic with
Windows-shaped constructed inputs on every platform — that works
precisely because D1 stops delegating to host-dependent OTP functions.
Anything that *does* touch OTP path functions or the real filesystem
(expand, resolve_real walks, rename semantics) additionally needs the
native Windows CI lane, which runs the full backend suite in T1.

## E. Desktop shell

- **E1 — sidecar Job Object.** In `start_sidecar` (Rust, `#[cfg(windows)]`):
  create a Job Object with kill-on-close, assign the spawned sidecar
  wrapper, leak the handle into app state next to `Backend`. Fixes the
  Burrito-wrapper orphan (Ground truth). The nonce/PortCollision probe
  already covers the "orphan from a crashed previous run" window.
- **E2 — window chrome.** `titleBarStyle: "Overlay"`, `hiddenTitle`,
  `trafficLightPosition` are macOS-only and ignored elsewhere; Windows
  gets standard decorations. Frontend: the drag-region padding the
  overlay style implies must not leave a dead strip on Windows — audit
  `AppShell`'s top padding under `platform() !== 'macos'`.
- **E3 — updater.** Config already carries
  `plugins.updater.windows.installMode: "passive"`; NSIS produces the
  `.exe` + `.sig`, `latest.json` gains `windows-x86_64`. The updater
  restarts the app itself on Windows (installer-driven) — the frontend's
  `installAndRelaunch` already tolerates that (install resolves, relaunch
  never observed).

## F. CI lane

`windows-latest` matrix entry mirroring the others: `setup-beam` (native
Windows support), MSVC preinstalled, bun/rust/just as on Unix, zig zip
fetch (A2), `just package-backend`, `tauri-action` with the same signing
env (minisign covers Windows artifacts; Authenticode signing is a
follow-up like Apple notarization — unsigned NSIS shows SmartScreen,
documented in RELEASING). Backend test suite runs once on the Windows
lane in this spec's bring-up (T1) to shake out path/`System.cmd`
assumptions in tests — it does not become a permanent PR gate yet (cost;
revisit once the lane is stable).

## Sequencing

1. **T1 build bring-up**: A1–A3, A5 + F; goal = a `workflow_dispatch`
   run producing an installable NSIS bundle whose sidecar *boots* (the
   watcher availability model is part of boot, hence T1; agents disabled
   at this point is acceptable mid-branch, never merged). T1 also runs
   the full backend suite once on the Windows lane to shake out
   path/fixture assumptions and feed T2/B5 with the real failure list.
2. **T2 paths**: D1–D6 — the inventory migration. Prerequisite for
   every user-visible flow (mount roots, permission gates, agent command
   resolution all sit on it).
3. **T3 agent runtime**: B1–B5 + E1 (the product's core loop).
4. **T4 maildir**: C1–C3.
5. **T5 polish + acceptance**: A4, E2–E3, doctor copy, RELEASING.md
   rewrite of the "Windows" section into "Windows lane" runbook.

Each T is separately mergeable behind the absent lane; the matrix entry
lands last (T5) so `main` never ships a lane that produces broken
installers.

## Acceptance (Windows 11 VM, manual)

1. Fresh NSIS install → onboarding → create workspace → create ICM →
   agent session round-trip (spawn, stream, permission ask, stop — no
   orphaned `claude`/`erl` processes in Task Manager after quit).
2. Mail: connect account (password lands in Credential Manager), full
   sync, flags round-trip (`;2,` filenames on disk), declared-ops move
   executes, derived views render.
3. Calendar: add ICS feed, events render, served feed reachable.
4. Kill the app from Task Manager mid-session → relaunch → no
   PortCollision dialog, no zombie on 4817.
5. Auto-update: install version N, publish N+1, in-app notice →
   restart-to-update → N+1 running.
6. Cross-OS workspace: workspace created on macOS, opened from a shared
   checkout on Windows (paths normalize, `:`-maildir documented-fails
   with the honest error, not a crash).

## Risks & open verifications

| Risk | Standing | Where handled |
|---|---|---|
| Burrito Windows wrapper maturity (output naming, extraction dir, no-exec) | assumed workable, unverified | T1 dry run; fallback = plain `mix release` + zip-dir sidecar layout (drop Burrito on Windows only) |
| exqlite/mdex compile on MSVC runner | expected fine | T1 |
| `file_system` Windows backend availability | degrade-not-crash designed in | A5, T1 |
| OTP `cacerts_get()` on Windows | expected fine (OTP ≥ 25.1) | A4, T5 |
| `find_executable` + `PATHEXT` semantics on OTP/win32 | unverified; resolver falls back to trying the extension list itself | B3, T3 |
| UNC/`\\?\` rejection surprising users on network drives | accepted for v1; honest "unsupported location" error + RELEASING note | D1 |
| Claude Code Windows install discovery paths | needs enumeration | B5, T3 |
| Job Object + Tauri shell interplay (nested job limits on Win10) | low — nested jobs supported since Win 8 | E1, T3 |
| SmartScreen on unsigned NSIS | accepted, documented | F, RELEASING |
