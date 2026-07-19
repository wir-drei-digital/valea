# Releasing Valea

Operational guide for the desktop release pipeline
(`.github/workflows/release.yml`). Design rationale lives in
[the release spec](superpowers/specs/2026-07-19-release-auto-update-design.md).

## What ships

| Platform | Built on | Installers | Auto-update artifact |
|---|---|---|---|
| macOS Apple silicon | `macos-latest` | `.dmg` | `.app.tar.gz` + `.sig` |
| Linux x86_64 | `ubuntu-22.04` | AppImage, `.deb`, `.rpm` | AppImage + `.sig` |

Every build is native — the Burrito sidecar embeds host-compiled NIFs
(exqlite, erlexec), so there is no cross-compilation lane, and no Intel
macOS lane (GitHub retired the last Intel runners; Apple silicon covers
every Mac since 2020). Only the AppImage self-updates on Linux; `.deb`/
`.rpm` installs update through the package manager story we don't have yet
— point those users at the AppImage if they want auto-update.

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

1. Bump `version` in `desktop/src-tauri/tauri.conf.json` (the app-version
   source of truth the updater compares; `backend/mix.exs` and the
   package.json versions are internal and don't matter here).
2. Commit, then tag exactly `v<that version>` and push both:

   ```bash
   git tag v0.2.0
   git push origin main v0.2.0
   ```

   The workflow fails fast if the tag and config version disagree.
3. CI builds both platforms onto one **draft** release (first macOS run
   compiles OTP via asdf, ~25 min; cached afterwards).
4. Smoke-test an installer from the draft's assets if the change warrants
   it, then **publish the release**. Publishing is go-live: the app's
   updater reads `releases/latest/download/latest.json`, which only ever
   serves the newest *published* release. Check the draft has `latest.json`
   with both a `darwin-aarch64` and a `linux-x86_64` entry before
   publishing.
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
Developer ID Application cert, then add the secrets the workflow already
passes through — `APPLE_CERTIFICATE` (base64 .p12),
`APPLE_CERTIFICATE_PASSWORD`, `APPLE_SIGNING_IDENTITY`, and for
notarization `APPLE_ID` + `APPLE_PASSWORD` (app-specific) +
`APPLE_TEAM_ID`. No workflow changes needed.

## Windows

There is deliberately no Windows lane: the pipeline could build one today,
but the app cannot run there yet. Blockers, in order of size:

- **erlexec is Unix-only** and is listed in `extra_applications`, so the
  sidecar would crash at boot, before any feature code. The agent runtime
  (`Valea.Agents.ProcessRuntime`) needs a Windows process-spawning story.
- **Maildir flag filenames** (Spec E) use the `:2,`-style info suffix; `:`
  is illegal in NTFS filenames, so mail storage needs a naming scheme
  change (Dovecot solves this with a configurable separator).
- The 3-layer prose seed writes a **`CLAUDE.md` symlink**; symlink creation
  on Windows needs developer mode or elevation — needs a copy/junction
  fallback.
- Already fine: the keychain commands use the `keyring` crate with
  `windows-native` enabled; Tauri v2 and Burrito both support Windows.

When those land: uncomment/add the `windows_x64` Burrito target in
`backend/mix.exs`, set `include_executables_for: [:unix, :windows]` on
`valea_desktop`, teach `backend/scripts/build-release.sh` + the Justfile
recipe a Windows host mapping (and zig fetch), and add a `windows-latest`
matrix entry (setup-beam supports Windows). The updater config already
carries a Windows `installMode`.
