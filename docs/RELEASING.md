# Releasing Valea

Operational guide for the desktop release pipeline
(`.github/workflows/release.yml`). Design rationale lives in
[the release spec](superpowers/specs/2026-07-19-release-auto-update-design.md).

## What ships

| Platform | Built on | Installers | Auto-update artifact |
|---|---|---|---|
| macOS Apple silicon | `macos-latest` | `.dmg` | `.app.tar.gz` + `.sig` |
| Linux x86_64 | `ubuntu-22.04` | AppImage, `.deb`, `.rpm` | AppImage + `.sig` |
| Windows x86_64 | `windows-latest` | NSIS `.exe` | NSIS `.exe` + `.sig` |

Every build is native — the Burrito sidecar embeds host-compiled NIFs
(exqlite, and erlexec on the Unix lanes), so there is no cross-compilation
lane, and no Intel macOS lane (GitHub retired the last Intel runners;
Apple silicon covers every Mac since 2020). Only the AppImage self-updates
on Linux; `.deb`/`.rpm` installs update through the package manager story
we don't have yet — point those users at the AppImage if they want
auto-update. The Linux lane exports `TARGET_ARCH=x86_64 TARGET_ABI=musl`
before the sidecar build: Burrito's Linux ERTS is musl-linked, and without
the override `rustler_precompiled` ships the build host's glibc NIFs
(mdex), which a musl BEAM cannot load — markdown parsing then crashes on
every Linux install (the 0.3.0 "markdown files cannot be opened" bug). Any
new Rust-NIF dependency must publish a `x86_64-unknown-linux-musl`
precompiled variant or be force-built in that lane.
On Windows the updater artifact IS the installer
(`installMode: "passive"`): it reruns with a progress bar and restarts the
app itself, so the frontend's relaunch call is never observed — see
"Windows" below.

## One-time setup: GitHub secrets

The updater keypair was generated 2026-07-19 (password-less) into
`~/.tauri/valea_updater.key[.pub]` on Daniel's machine; the public half is
baked into `desktop/src-tauri/tauri.conf.json` (`plugins.updater.pubkey`).
The private key must never enter the repo. Upload it once:

```bash
gh secret set TAURI_SIGNING_PRIVATE_KEY < ~/.tauri/valea_updater.key
```

That is the only required secret. `TAURI_SIGNING_PRIVATE_KEY_PASSWORD` is
already wired in the workflow for the day the key is regenerated *with* a
password; with the current password-less key it stays unset (the empty
env value and the password-less key agree).

**Back the key up** (password manager). If it is lost, installed apps can
never verify another update: you'd generate a new keypair, put the new
pubkey in `tauri.conf.json`, and every existing install has to download
that release manually once. Annoying, not fatal — but avoidable.

## Cutting a release

1. Bump the version in **all four** files — CI refuses to build unless every
   one of them matches the tag:

   - `desktop/src-tauri/tauri.conf.json` — the app version the updater
     compares to decide whether a release is newer.
   - `backend/mix.exs` — **load-bearing, and silent when wrong.** Burrito
     names its unpacked payload directory
     `valea_desktop_erts-<erts>_<mix.exs version>` and skips extraction
     whenever that directory already exists. Ship a bumped app version with a
     stale `mix.exs` version and every *existing* install keeps running the
     old backend — which, because the sidecar also serves the SPA, means the
     old frontend too. The About box still reads the new version. Fresh
     installs work fine, so this only ever breaks upgraders, and it does not
     announce itself.
   - `desktop/src-tauri/Cargo.toml` (+ `Cargo.lock`) and
     `frontend/package.json` — cosmetic, but asserted so the four can't drift.

2. Commit, then tag exactly `v<that version>` and push both:

   ```bash
   git tag v0.2.0
   git push origin main v0.2.0
   ```

   The workflow fails fast, before any build work, if the tag and any of the
   four version strings disagree.
3. CI builds all three platforms onto one **draft** release (first macOS
   run compiles OTP via asdf, ~25 min; cached afterwards).
4. Smoke-test an installer from the draft's assets if the change warrants
   it, then **publish the release**. Publishing is go-live: the app's
   updater reads `releases/latest/download/latest.json`, which only ever
   serves the newest *published* release. Check the draft has `latest.json`
   with a `darwin-aarch64`, a `linux-x86_64` AND a `windows-x86_64` entry
   before publishing — a lane that failed silently shows up here as a
   missing platform, and publishing anyway strands that platform's users
   on their current version.
5. Rollback = publish a newer fixed version. Un-publishing breaks nobody
   (apps just see no update), but never delete a published release's
   assets out from under updaters mid-download.

Dry run without touching releases: `gh workflow run release.yml` (or the
Actions tab) — same build, bundles parked as workflow artifacts for 7 days.

## How updates reach users

The packaged app checks ~90 s after launch and every 6 h
(`frontend/src/lib/stores/updates.svelte.ts`), silently downloads in the
background, then shows the amber notice at the bottom of the sidebar —
"Restart to update" installs and relaunches. Failed checks stay silent
(offline is normal); only a failed download/install shows an error card.
Browser dev and `tauri dev` never check.

## macOS signing (follow-up)

Bundles are currently **ad-hoc signed**: auto-updates work (the updater
verifies our minisign signature and its downloads carry no quarantine
attribute), but a first-time DMG downloaded in a browser hits Gatekeeper
(right-click → Open). When distribution beyond us matters: get an Apple
Developer ID Application cert, then add the secrets — `APPLE_CERTIFICATE`
(base64 .p12), `APPLE_CERTIFICATE_PASSWORD`, `APPLE_SIGNING_IDENTITY`,
and for notarization `APPLE_ID` + `APPLE_PASSWORD` (app-specific) +
`APPLE_TEAM_ID`. No workflow changes needed: the "Enable Apple signing
when secrets exist" step in `release.yml` forwards each variable to the
bundler only once it has a value. (It exists because the naive
passthrough broke the build — GitHub renders unset secrets as empty
strings, which the bundler treats as a signing request and dies importing
an empty certificate.)

## Windows

The lane is a normal matrix row now (design:
[windows-support](superpowers/specs/2026-07-19-windows-support-design.md)).
It builds like the others — `setup-beam` covers Windows natively, MSVC is
preinstalled, and `just package-backend` selects the `windows_x64` Burrito
target and additionally builds and stages the `valea-spawn.exe` shim (the
agent runtime's Job-Object process supervisor, `tauri.windows.conf.json`'s
second `externalBin`). What follows is what is *different* about the
Windows product.

### NSIS only — no MSI

`tauri.windows.conf.json` pins `bundle.targets` to `["nsis"]`, overriding
the base config's `"all"`. Without the pin, Tauri builds the WiX/MSI
bundle first on Windows — an artifact nothing here ships (the release
assets and the updater flow are NSIS-only) and one that actually broke
the v0.1.0 run: WiX `light.exe` failed on `windows-latest` before the
NSIS step was ever reached. If an MSI is ever wanted (e.g. for managed
enterprise installs), that WiX failure has to be debugged first — extend
the targets list rather than reverting to `"all"`.

### Pending gates — read before tagging a Windows release

Everything below was written and unit-tested on macOS. The v0.1.0 release
run was the first native Windows CI compile — the Burrito sidecar, the
`valea-spawn` shim, and the full desktop crate (all the `cfg(windows)`
Rust) built cleanly on `windows-latest` — but **the gating test suites
have still never run on Windows**. Dispatch
`.github/workflows/windows-bringup.yml` from the branch and work through
the "Batched CI gates" list in
[the acceptance doc](superpowers/acceptance/2026-07-19-windows-support.md)
first — the bring-up lane is what runs the gating *suites* (paths,
containment, the full backend suite, the `valea-spawn` cargo tests);
`release.yml` only builds bundles and would happily ship a red one.
Retire the bring-up workflow, and this subsection, once it goes fully
green and a `release.yml` dry run produces a good NSIS bundle.

### SmartScreen and code signing (follow-up)

The NSIS installer is **not Authenticode-signed**, so a first-time
download shows Microsoft Defender SmartScreen's "Windows protected your
PC" — More info → Run anyway. Same posture (and same fix shape) as
[macOS signing](#macos-signing-follow-up): buy a code-signing
certificate, add it as a secret, and the warning goes away as reputation
accrues. Unlike the Apple secrets, no passthrough is wired in the workflow
yet — signing would add `bundle.windows.certificateThumbprint` (or a
`signCommand`) plus a timestamp URL to the Tauri config.

Auto-update is unaffected either way: the updater verifies our own
minisign signature over the downloaded `.exe` before running it.

### Where Valea keeps its profile

On Windows the backend's app dir and the shell's data dir (including
`secret_key_base`) pin to **`%LOCALAPPDATA%`** (`app_local_data_dir`).
The one way Roaming could still be reached is `%LOCALAPPDATA%` being unset
entirely, where Tauri's `basedir` fallback resolves to Roaming — practically
unreachable on a real Windows session, and not a case we handle specially.
Corporate folder redirection routinely puts
Roaming on a network share, and SQLite in WAL mode is documented-unsafe
over network filesystems — `app.sqlite`, the `sources/` mail and calendar
mirrors, and session transcripts all live there. Decided before the first
Windows release specifically so no user ever has to be migrated off a
roaming location. The consequence is intended: the profile does not follow
the user between machines.

### Network shares and cloud folders

User-owned **ICM folders on a share are supported** — `\\server\share\…`
(or a mapped drive) is plain file IO, UNC roots normalize, and the
containment floor stops a `..` walk at the share root. Three honest limits
apply, and none of them are detected in code:

- **Server-side reparse points are invisible to containment** (spec D7).
  A junction that lives on the *server* side of a share is resolved by the
  server; the client never sees it, so Valea's symlink walk cannot police
  a redirect out of `\\host\share\icm`. For share-hosted ICMs **the
  share's own configuration is part of the trust boundary.** Also recorded
  in [ARCHITECTURE.md](ARCHITECTURE.md) "Trust model".
- **File watching over SMB is best-effort** (spec A5). The backend may
  start fine and still miss events — change notification over SMB is
  best-effort by protocol. The ICM doctor's "watcher live" row says so for
  a `//`-rooted mount; the tree still refreshes on navigation and RPC, as
  it does everywhere.
- **The profile stays local** (spec A6). Point ICM mounts at a share if
  you like; never the workspace itself.

**Cloud-placeholder locations are unsupported** (spec D6): OneDrive,
Dropbox, and iCloud Drive "files on demand" folders hold reparse-point
placeholders that the sync client hydrates on access. Valea does not
detect them; a workspace or an ICM inside one is out of support (dehydrated
files, hydration latency inside the agent's own reads, and a third party
rewriting files underneath the watcher).

**Per-directory case-sensitive NTFS trees are unsupported** (spec D3):
containment compares case-folded on Windows, so a directory flipped with
`fsutil file setCaseSensitiveInfo` can hold two paths Valea considers the
same one. Non-default configuration, documented rather than detected.

### Moving a workspace between machines

Paths normalize, so a workspace folder itself travels — with one hard edge
in the mail store.

A maildir store records its flag separator once, at creation, in
`sources/mail/<slug>/.account` (`maildir_separator`): `;` for a store
created on Windows (`:` is illegal in NTFS filenames), `:` everywhere
else. **The file wins over the host**: an absent field means the legacy
`:`, and a store that says `:` keeps saying `:` when it is opened on
Windows — never OS-defaulted, so no store ever silently starts mixing two
naming conventions inside one maildir.

On Windows that rule buys honesty rather than function. `:` is not a legal
NTFS filename character, so a legacy store cannot *operate* there — and
copying one onto NTFS mangles it before Valea is ever involved: the copy
tool refuses, truncates, or rewrites the names on its own. Don't migrate
mail across OSes by copying files. Re-add the account on the new machine
and let it sync; the maildir is a mirror of the server, not the original.

An `.account` file that can't be parsed (or carries an unrecognized
separator) blocks that account inert, with UI copy pointing at the file:
repair or restore `.account`. Purging the local mirror is not the remedy.
