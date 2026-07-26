# ICM skills (vendored install, consent, settings) — design

Status: approved 2026-07-26 (design sections approved in session; spec pending
user review). Builds on Spec D agent-native ICMs
(`2026-07-16-agent-native-icms-design.md` — the agent interprets ICM prose;
Valea is cockpit + guardrails) and the ICM project workspaces substrate
(`2026-07-13-icm-project-workspaces-design.md`). Companion to the mail
account-root `AGENTS.md` briefing (engine-owned, same-day work): that file
teaches the *mail surface*; skills teach *methodology*.

## Goal

ICMs need housekeeping: guidance on how to structure a context project and how
to add new workflow documents without inventing the grammar from scratch. That
guidance is exactly what agent skills are for. Valea vendors a pinned snapshot
of a methodology skill — first entry: `icm-architect`
(github.com/RinDig/icm-architect, MIT; SKILL.md + references + templates
implementing the ICM paper's folder-structure forms) — and installs it **into
the user's ICM, with the user's explicit consent, visible and manageable in
settings**.

The agent never installs anything. Valea copies files only on a user's click.

## Decisions (approved in session)

1. **Install scope: per-ICM vendored.** Install target is
   `<icm>/.claude/skills/<skill>/`. The skill travels with the portable ICM —
   it keeps working in bare Claude Code on another machine, which is the
   product's own promise ("every ICM stays usable by a bare coding harness
   with no Valea present"). Valea never writes into `~/.claude`. Claude Code
   auto-discovers project-scope skills from cwd, and every Valea session runs
   with the primary ICM root as cwd, so installed skills load in Valea
   sessions and bare sessions alike. Cost accepted: N mounted ICMs may hold N
   copies at N versions; the settings surface makes that visible instead of
   pretending it can't happen.
2. **Updates: badge + one-click, never silent.** Unlike the mail briefing
   (engine-owned, inside the hidden workspace), an installed skill lives in a
   user-owned folder and is the user's after install. When the app ships a
   newer snapshot, settings shows "update available"; updating takes a click.
   If the user hand-edited the skill (hash mismatch, §On-disk contract), the
   update warns before overwriting. "Nothing is copied or moved behind your
   back."
3. **Offer moment: once per ICM at mount/create/adopt.** A dismissible card
   right after `create_icm` / `adopt_icm` / `mount_icm` succeeds — the moment
   the user is already deciding how this ICM works. Never a blocking step.
   Dismissal is operational state and recorded in the workspace config, not in
   the ICM.
4. **UI surface: the agent settings modal.** A "Skills" section in the
   existing agent-settings dialog — one place for everything agent-related,
   reusing the dialog whose trust model is already "saving here is the consent
   step" (`set_harness_command` precedent).

## Catalog

- `backend/priv/skills/<skill-id>/` — the full vendored snapshot (SKILL.md,
  `references/`, `assets/`, …), committed to the repo. No runtime fetching,
  ever: updating or replacing a skill is a repo commit (offline-safe,
  supply-chain-quiet, and "might change later" becomes a data change).
- `backend/priv/skills/catalog.yaml` — one entry per skill:

  ```yaml
  version: 1
  skills:
    icm-architect:
      name: "ICM Architect"
      description: "Structure this ICM's folders and add new workflow documents using the ICM methodology's five forms."
      source_url: "https://github.com/RinDig/icm-architect"
      license: "MIT"
      pinned: "<commit sha or tag of the vendored snapshot>"
  ```

- Unknown keys ignored (forward compat, matching `icm.yaml` posture). A
  catalog entry whose snapshot directory is missing is a doctor-visible
  defect, not a crash.

## On-disk contract

Install copies the snapshot to `<icm>/.claude/skills/<skill-id>/` and writes
one sidecar **inside the installed folder**:

```yaml
# <icm>/.claude/skills/<skill-id>/.provenance.yaml
format: 1
skill: icm-architect
version: "<pinned value from catalog at install time>"
source_url: "https://github.com/RinDig/icm-architect"
installed_by: valea
files:
  SKILL.md: "<sha256>"
  references/core.md: "<sha256>"
  # … every installed file, relative path → content hash
```

- The sidecar travels with the portable ICM, so any Valea instance recognizes
  the install, its version, and — by re-hashing — whether the user edited it.
  `.provenance.yaml` itself is excluded from the hash manifest.
- **State derivation** (pure function of catalog + disk), checked in this
  precedence order — first match wins:
  1. no skill dir → `not_installed`
  2. dir present, no/unparseable sidecar → `foreign` (someone else put a
     skill there; Valea lists it read-only and never updates or removes it)
  3. any recorded hash mismatches the file on disk → `edited` (at any
     version; the row still offers Update, with the explicit overwrite
     warning — an edited old copy is edited first, outdated second)
  4. sidecar version != catalog pinned → `update_available`
  5. otherwise → `installed`
- Writes are staged: copy to `<icm>/.claude/skills/.tmp-<skill-id>-<nonce>/`,
  then a single atomic rename into place (replacing the old dir on update via
  rename-aside + rename + cleanup). A crash never leaves a half-written skill
  at the live path.
- Uninstall deletes `<icm>/.claude/skills/<skill-id>/` after a plain confirm
  in the UI (recoverable by reinstall; no typed-confirm ceremony). `foreign`
  dirs are never deletable through Valea.
- After install the files are the user's: editable, versionable, readable by
  any harness. Valea touches them again only on the user's explicit update or
  uninstall click.

## Backend

New context `Valea.Skills` (`backend/lib/valea/skills.ex`, splitting into
`skills/` modules only if it grows):

- `catalog/0` — parse + validate `priv/skills/catalog.yaml` against the
  vendored snapshot dirs.
- `inspect(workspace, mount_key)` — per-mount skill states (the derivation
  above) for every catalog entry, plus `foreign` entries found on disk.
- `install(workspace, mount_key, skill_id)` /
  `update(workspace, mount_key, skill_id, opts)` /
  `uninstall(workspace, mount_key, skill_id)` — the staged-write operations.
  `update` refuses on `edited` unless `force: true` (the UI's overwrite
  confirmation supplies it). All three refuse on `foreign`.
- Mount resolution reuses `Valea.Mounts.mount_by_key/2` (enabled,
  non-degraded) and containment reuses `Valea.Paths.resolve_real/2` — the
  install path must resolve inside the mount root, symlinked
  `.claude`/`skills` segments refuse rather than follow.

New RPC resource `Valea.Api.Skills`, following `Valea.Api.Icms` exactly:
generation guard first on every action, the same central error-mapping
vocabulary, actions `list_skills` (per mount), `install_skill`,
`update_skill`, `uninstall_skill`. Trust model is the
`set_harness_command` one: **the settings click is the consent step**, the
RPC is reachable only from the control-token-gated UI socket, and the agent
tool surface carries no RPC access — the existing agent-RPC-isolation test
extends to the new actions.

## Risk tier

`Valea.Agents.RiskTier` learns one rule: any path under a `.claude/`
directory inside a mount classifies **high** (it configures future agent
behavior — skills, project settings alike). This closes a pre-existing hole
(`@behavior_basenames` only catches `AGENTS.md`/`CLAUDE.md`/`CONTEXT.md`
today) and applies regardless of who installed the skill. No
`PermissionPolicy` change: skill files are ordinary mount content — readable,
and agent edits go through the ask-gate like any ICM write, now with the
high-risk banner.

## Frontend

**Agent settings modal — "Skills" section.** Below the harness command: one
row per (mounted ICM × catalog skill), plus rows for `foreign` dirs. Each row
shows the state (`not installed` / `installed vX` / `update available` /
`edited` / `foreign`) and the matching action (Install / Update / Remove;
`foreign` rows are display-only). Install opens the consent dialog:

> **Install ICM Architect into Mara Lindt Coaching?**
> Adds 5 files under `.claude/skills/icm-architect/` in your ICM folder. It
> teaches your assistant how to structure this ICM's folders and add new
> workflow documents. After installing, the files are yours — readable,
> editable, and they travel with the folder.
> Source: github.com/RinDig/icm-architect (MIT).
> [Install into Mara Lindt Coaching] [Not now]

Buttons name outcomes; no exclamation marks; plain language with the
technical detail (paths, source) present but quiet. Update uses the same
dialog shape with a short "what changes" note (old → new version); on
`edited` it adds the overwrite warning and requires the explicit
"Replace my edited copy" button.

**Offer card.** After a successful `create_icm` / `adopt_icm` / `mount_icm`,
a dismissible card renders under that ICM's group in the main sidebar (both
the onboarding paths and later sidebar mounts land there), offering the
install once ("Your assistant can learn the ICM methodology — install the
ICM Architect skill into this folder?" → opens the same consent dialog).
Dismissal appends the skill id to a `skills_offers_dismissed:` list under
that ICM's entry in `config/workspace.yaml` (operational state stays in the
workspace, the ICM is never marked; a list, so future catalog entries get
their own one-time offer). Installing or dismissing retires the card; it
never blocks or nags.

## Testing

- `Valea.Skills` unit tests: catalog parse/validate (unknown keys ignored,
  missing snapshot dir → defect), install/update/uninstall round-trips,
  staged-write crash-safety (tmp dir left behind is ignored and cleaned),
  state derivation for all five states incl. precedence (`edited` beats
  `update_available`), `edited` refusal without `force`,
  `foreign` refusal for all mutations, containment (symlinked `.claude`
  refuses).
- `Valea.Api.Skills` tests: generation guard on every action, error
  vocabulary, agent-RPC-isolation assertion extended to the new actions.
- `RiskTier` tests: `.claude/**` under a mount → high, at any depth; the
  existing basename rules unaffected.
- Frontend tests: row-state derivation, offer-card show/dismiss logic
  (dismissed flag, installed flag, foreign dir).

## Non-goals

No marketplace or runtime fetching; no skill enable/disable toggle
(installed = on disk; removal is the toggle); no writes to `~/.claude` or any
global Claude config; no skill authoring or editing UI; no automatic updates;
no MCP servers; no per-skill permission carve-outs. Additional catalog
entries are future data changes, not future features.
