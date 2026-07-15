# ACP launch contract: `claude-agent-acp`

Normative record for Phase 1 Task 1.1 of the ICM project-workspaces plan
(`docs/superpowers/plans/2026-07-13-icm-project-workspaces.md`). Every later
phase that touches the harness launch surface (Tasks 1.2, 1.3, and Phase 5's
`SessionScope`/`SessionSettings`) reads THIS document for the exact
wire/CLI mechanism behind cwd, additional read roots, and managed settings
(spec §C7 "Session permission policy").

**Decision landed (do not re-open without a new spike):** enforcement of
reads/writes is **managedSettings-posture + callback**, not callback-only.
An initial version of this note framed enforcement as "callback-only" —
that framing was **wrong** and is corrected here (see "Managed settings"
below for why): registering the ACP `session/request_permission` callback
only makes the SDK pass `--permission-prompt-tool stdio` to the CLI; the
CLI's **own** permission engine (settings + defaults + mode) decides FIRST,
and only calls that fall through to "ask" ever reach the callback. With no
settings at all, CLI defaults govern and can auto-resolve a write or a
denied read before Valea's callback is ever invoked. The corrected,
locked-in mechanism: Valea passes an **in-memory** `managedSettings`
posture (ask `Write`/`Edit`/`Bash`; deny the workspace's protected
subdirectories; deny `WebFetch`/`WebSearch`) on `session/new`, via the
SDK's documented `Options.managedSettings` → `--managed-settings <json>`
channel (no file written into or near the ICM — see "Managed settings"
below for the exact file:line citations). That posture is what forces
sensitive calls to fall through to "ask"; `Valea.Agents
.PermissionPolicy.decide/2` on the callback then authoritatively answers
each one. Additional read roots are still conveyed natively via
`session/new`'s `additionalDirectories` field (a genuine efficiency win —
common related-ICM reads don't each round-trip through the callback), but
that field is a **convenience**, not a security boundary: a read outside
even a declared `additionalDirectories` entry still round-trips.

Versions inspected: `@agentclientprotocol/claude-agent-acp@0.58.1`,
`@anthropic-ai/claude-agent-sdk@0.3.205`, bundled native CLI `2.1.205`
(the binary the adapter actually spawns — see "Two `claude` binaries" below),
globally-installed `claude` CLI `2.1.201`. Both CLI binaries expose an
identical relevant flag surface (verified independently).

---

## Surface (Step 1 — verbatim inventory)

### The adapter binary and package

```
$ which claude-agent-acp
/Users/daniel/.nvm/versions/node/v25.4.0/bin/claude-agent-acp
```

That's a symlink to
`.../lib/node_modules/@agentclientprotocol/claude-agent-acp/dist/index.js`.
`package.json`:

```json
"name": "@agentclientprotocol/claude-agent-acp",
"version": "0.58.1",
"bin": { "claude-agent-acp": "dist/index.js" },
"dependencies": {
  "@agentclientprotocol/sdk": "1.2.1",
  "@anthropic-ai/claude-agent-sdk": "0.3.205",
  "zod": "^3.25.0 || ^4.0.0"
}
```

`claude-agent-acp --help` (and `--version`) print **nothing useful for our
purposes** — the binary is a pure ACP stdio server (JSON-RPC over
stdin/stdout); `--help`/`--version` aren't handled flags for it (only
`--cli` and `--version`/`-v` are special-cased in `dist/index.js:8-41`, and
neither documents the launch surface). The launch surface has to be read
from source, not `--help`.

### Two `claude` binaries — which one the adapter actually spawns

There are two distinct `claude` CLI binaries on this machine, and the
adapter uses the **second**, not the first:

1. `/Users/daniel/.local/bin/claude` → `2.1.201` (the user's own global
   install, what `claude --help` on a bare shell resolves to).
2. `.../claude-agent-acp/node_modules/@anthropic-ai/claude-agent-sdk-darwin-arm64/claude`
   → `2.1.205` — a **platform-specific optional dependency of the SDK**,
   resolved by `claudeCliPath()` (`dist/acp-agent.js:59-95`) via
   `createRequire(...).resolve("@anthropic-ai/claude-agent-sdk-<platform>-<arch>/claude<ext>")`,
   and only overridden by the `CLAUDE_CODE_EXECUTABLE` env var
   (`acp-agent.js:60-61`, and again at the call site,
   `acp-agent.js:2907`: `pathToClaudeCodeExecutable: process.env.CLAUDE_CODE_EXECUTABLE ?? (await claudeCliPath())`).

Both binaries expose an identical set of relevant flags (verified below by
running `--help` against both independently), so this distinction doesn't
change the contract — but it matters for anyone debugging a launch: the
adapter is NOT using the CLI on `$PATH`.

### Relevant CLI flags (`claude --help`, both binaries agree)

```
  --add-dir <directories...>            Additional directories to allow tool
                                        access to
  ...
  --bare                                Minimal mode: skip hooks, LSP, plugin
                                        sync, attribution, auto-memory,
                                        background prefetches, keychain reads,
                                        and CLAUDE.md auto-discovery. Sets
                                        CLAUDE_CODE_SIMPLE=1. ... Explicitly
                                        provide context via:
                                        --system-prompt[-file],
                                        --append-system-prompt[-file], --add-dir
                                        (CLAUDE.md dirs), --mcp-config,
                                        --settings, --agents, --plugin-dir.
  ...
  --permission-mode <mode>              Permission mode to use for the session
                                        (choices: "acceptEdits", "auto",
                                        "bypassPermissions", "manual",
                                        "dontAsk", "plan")
  ...
  --setting-sources <sources>           Comma-separated list of setting sources
                                        to load (user, project, local).
  --settings <file-or-json>             Path to a settings JSON file or a JSON
                                        string to load additional settings from
  --strict-mcp-config                   Only use MCP servers from --mcp-config,
                                        ignoring all other MCP configurations
```

The `--bare` mode's own description is the CLI's own confirmation that
`--add-dir` dirs are "(CLAUDE.md dirs)" — i.e. **added directories
contribute to CLAUDE.md/memory discovery, not just tool-access scope.** This
is load-bearing for the "instruction isolation" requirement below.

### What `session/new` params the adapter forwards (`dist/acp-agent.js`)

`createSession/2` (`acp-agent.js:2758` onward) builds the SDK `query()`
`options` object from the ACP `session/new` params:

```js
// acp-agent.js:2723-2730 (getOrCreateSession -> createSession)
const response = await this.createSession({
    cwd: params.cwd,
    mcpServers: params.mcpServers ?? [],
    additionalDirectories: params.additionalDirectories,
    _meta: params._meta,
}, { resume: params.sessionId });
```

```js
// acp-agent.js:2977-2985
// Prefer the official ACP `additionalDirectories` field. Fall back to the
// legacy `_meta.additionalRoots` extension for clients that haven't been
// updated yet. Either source is merged with directories supplied via
// `_meta.claudeCode.options.additionalDirectories` (SDK pass-through).
const acpAdditionalDirectories = params.additionalDirectories ?? sessionMeta?.additionalRoots ?? [];
options.additionalDirectories = [
    ...(userProvidedOptions?.additionalDirectories ?? []),
    ...acpAdditionalDirectories,
];
```

```js
// acp-agent.js:2856-2858
const options = {
    systemPrompt,
    settingSources: ["user", "project", "local"],   // <- default, overridable
    ...(thinking !== undefined && { thinking }),
    ...userProvidedOptions,                          // <- _meta.claudeCode.options wins
    ...
```

```js
// acp-agent.js:2887, 2907
canUseTool: this.canUseTool(sessionId),              // EVERY tool call routes here
pathToClaudeCodeExecutable: process.env.CLAUDE_CODE_EXECUTABLE ?? (await claudeCliPath()),
```

`params.cwd`, `params.mcpServers`, `params.additionalDirectories`, and
`params._meta` (with `_meta.claudeCode.options.*` spread verbatim into the
SDK options, taking precedence over adapter defaults) are the full native
`session/new` surface this adapter version understands. There is **no**
`settingSources`, `settings`, or "external settings path" field on
`session/new` itself — those only exist as SDK `Options` reachable through
`_meta.claudeCode.options.*`.

### `SettingsManager` — confirms the fallback's premise (b)

`dist/settings.js` (`SettingsManager` class, constructed per-session at
`acp-agent.js:2778-2781`: `new SettingsManager(params.cwd, {...})`):

```js
// settings.js:76-83
getWatchedPaths() {
    return [
        path.join(CLAUDE_CONFIG_DIR, "settings.json"),          // ~/.claude/settings.json
        path.join(this.cwd, ".claude", "settings.json"),        // <cwd>/.claude/settings.json
        path.join(this.cwd, ".claude", "settings.local.json"),  // <cwd>/.claude/settings.local.json
        getManagedSettingsPath(),                                // OS-managed path
    ];
}
```

```js
// settings.js:88-97
async loadAllSettings() {
    try {
        const resolved = await resolveSettings({ cwd: this.cwd });   // <- SDK merge engine
        this.effective = filterEscalatingDefaultMode(resolved);
    } catch (error) { ... }
}
```

There is **no** parameter, constructor option, or `_meta` field anywhere in
`acp-agent.js`/`settings.js` that points `SettingsManager` at a file outside
`{~/.claude, <cwd>/.claude, <OS-managed path>}`. This is an exact,
source-confirmed match of the brief's fallback premise (b): **the adapter
cannot be pointed at an external Valea-owned settings file.**

### SDK `Options` fields relevant to C7 (`sdk.d.ts`, `@anthropic-ai/claude-agent-sdk@0.3.205`)

```ts
// sdk.d.ts:1292
additionalDirectories?: string[];   // "Additional directories Claude can access beyond cwd. Paths should be absolute."

// sdk.d.ts:1835
settings?: string | Settings;       // accepts a FILE PATH *or* an inline Settings object/JSON string

// sdk.d.ts:1836-1859 (doc comment + field) — THE CHOSEN ENFORCEMENT MECHANISM
/**
 * Policy-tier settings supplied by the spawning parent process. ...
 * Even when opted in, the value is filtered restrictive-only: permissive
 * arrays (`permissions.allow`, `additionalDirectories`, `allowedMcpServers`,
 * ...) that would widen an existing admin lock are silently dropped. ...
 *
 * Intended for embedding applications (e.g. desktop apps) that derive
 * lockdown settings from their own enterprise configuration and need to
 * enforce them on the spawned subprocess without writing root-owned files.
 */
managedSettings?: Settings;

// sdk.d.ts:1861-1870
/**
 * Control which filesystem settings to load.
 * - 'user' - Global user settings (~/.claude/settings.json)
 * - 'project' - Project settings (.claude/settings.json)
 * - 'local' - Local settings (.claude/settings.local.json)
 *
 * When omitted, all sources are loaded (matches CLI defaults).
 * Pass [] to disable filesystem settings (SDK isolation mode).
 * Must include 'project' to load CLAUDE.md files.
 */
settingSources?: SettingSource[];

// sdk.d.ts:6298 (field of the `Settings` interface, i.e. settings.json shape)
claudeMdExcludes?: string[];        // "Glob patterns or absolute paths of CLAUDE.md files to exclude
                                     //  from loading ... Only applies to User, Project, and Local
                                     //  memory types."
```

`settingSources` is what actually governs whether CLAUDE.md loads at all
("Must include `'project'` to load CLAUDE.md files") — and the adapter's
own default is `["user", "project", "local"]` (`acp-agent.js:2858`), i.e.
CLAUDE.md loading is ON by default and would need an explicit override to
turn off (see "Instruction isolation" below — turning it off globally is
the wrong tool for isolating one related directory's memory).

`Options.managedSettings` (`sdk.d.ts:1859`, doc comment `sdk.d.ts:1836-1858`)
is the field this contract chooses for enforcement. Its own doc comment says
exactly what Valea needs: an **embedding application** (Valea's Elixir
backend, spawning the adapter, which spawns the CLI) can "enforce [lockdown
settings] on the spawned subprocess without writing root-owned files." It is
also explicitly **restrictive-only-filtered**: `permissions.allow`,
`additionalDirectories`, `allowedMcpServers`, and other permissive keys are
silently dropped even if included — only deny/ask-shaped keys take effect.
This is a good structural fit for Valea's posture (ask + deny only, no
`allow` array) and a hard constraint: an `allow` array in `managedSettings`
would be silently ignored, so allow-listing must stay the callback's job,
not this channel's.

### `sdk.mjs` (bundled, minified) — confirms `additionalDirectories` → `--add-dir`, `settingSources` → `--setting-sources`, `managedSettings` → `--managed-settings`

```
...W.push("--session-mirror");for(let Ue of e)W.push("--add-dir",Ue);...
```
(`e` here is `options.additionalDirectories`; each entry becomes a
`--add-dir <dir>` argv pair to the underlying native CLI — confirms the ACP
`additionalDirectories` field really does translate 1:1 to the CLI flag the
`--bare` help text calls "(CLAUDE.md dirs)".)

```
...settingSources:U ... "--setting-sources=${U.join(...)}" ...
```
(confirms `options.settingSources` becomes `--setting-sources`.)

```
let ju={...s??{}};if(this.options.settings)ju.settings=this.options.settings;
let zu=kA(ju,na);for(let[Ue,Gt]of Object.entries(zu)) ... W.push(`--${Ue}`,Gt);
```
(confirms `options.settings`, if set, becomes a `--settings <value>` argv
pair — consistent with the CLI's own `--settings <file-or-json>`
description. See "Instruction isolation" for how this is used, and the
caveat about passing a **string**, not a raw object.)

```
...if(this.options.managedSettings)W.push("--managed-settings",this.options.managedSettings);...
```
(`sdk.mjs` line 88 — confirms `options.managedSettings`, if set, becomes a
`--managed-settings <value>` argv pair to the underlying native CLI. The
value pushed is already a JSON string by this point: the query-construction
path a few frames earlier — `managedSettings:s?me(s):void 0` (`sdk.mjs` line
117, where `me` is the module's local `JSON.stringify` wrapper) —
stringifies the caller's plain object before it ever reaches this push. This
is the exact mechanism `Options.managedSettings` above documents, confirmed
at the argv-construction level, not just the type-declaration level.)

---

## Contract (Step 2 — the chosen mechanism per C7 need)

### cwd

**Confirmed, already in production use.** `session/new`'s top-level `cwd`
field (`Valea.Acp.Connection.open_session_frames/2`,
`backend/lib/valea/acp/connection.ex:378-401`, already sends
`%{"cwd" => launch.cwd, "mcpServers" => []}`). The adapter validates it's an
absolute, existing directory before creating the session
(`acp-agent.js:2743-2757`, `validateCwd/1`) and it stays authoritative for
every relative path the agent resolves. **No change needed** for cwd itself
— Task 1.2/1.3 only need to start passing an ICM root instead of the Valea
workspace root as that same field.

### Additional read roots

**Mechanism:** native `session/new` top-level field `additionalDirectories:
string[]` (absolute paths). Confirmed native (not a Valea invention) at
`acp-agent.js:2981-2985` — merged from `params.additionalDirectories` (ACP
field), a legacy `_meta.additionalRoots` fallback, and
`_meta.claudeCode.options.additionalDirectories` (direct SDK pass-through),
then handed to the SDK's `query()` as `options.additionalDirectories`. The
SDK translates each entry to a `--add-dir <dir>` argv pair to the native CLI
(confirmed in `sdk.mjs`, quoted above).

**CLAUDE.md auto-load:** YES, added directories auto-load their CLAUDE.md
by default. Two independent, corroborating pieces of evidence:

1. The bare CLI's own `--help` text parenthesizes `--add-dir` as
   `(CLAUDE.md dirs)` in the "explicitly provide context" list — the CLI's
   own documentation says added dirs feed CLAUDE.md discovery.
2. The installed native CLI binary (`2.1.201`/`2.1.205`) contains internal
   state keys named literally `additionalDirectoriesForClaudeMd` /
   `setAdditionalDirectoriesForClaudeMd` / `getAdditionalDirectoriesForClaudeMd`
   (found via `strings` on the compiled binary) — i.e. the CLI tracks a
   distinct "additional directories, for the purpose of CLAUDE.md" concept
   internally, derived from the same `--add-dir` list.

This was **not independently reproduced against a live model turn** in this
spike (see "Verified proof" — the live run never reached a tool call), so
treat it as source/binary-grounded, not behaviorally observed. It is
consistent with spec §C7's own expectation ("Do not auto-load instructions
(CLAUDE.md) from related additional directories — only the primary ICM's
own CLAUDE.md... loads"), i.e. the spec already assumes the default
auto-loads and needs suppressing.

**How to suppress it, two options, ranked:**

- **Preferred — `claudeMdExcludes` (surgical, keeps `additionalDirectories`
  for tool access):** pass
  `_meta.claudeCode.options.settings` as a **JSON string** (not a raw
  object — see caveat below) containing
  `{"claudeMdExcludes": ["<related-root>/CLAUDE.md", "<related-root>/**"]}`.
  This is an in-memory value forwarded straight through to the underlying
  CLI's `--settings <json>` flag (confirmed in `sdk.mjs`, quoted above) —
  **no file is written anywhere**, satisfying the "never write into the
  ICM" invariant while still granting `additionalDirectories` read/tool
  access. `claudeMdExcludes` is documented as applying to "User, Project,
  and Local memory types" and matching by absolute path/glob
  (`sdk.d.ts:6296-6298`), which covers a related ICM's `CLAUDE.md`.
  **Caveat:** pass a JSON **string**, not a plain map — `kA()`'s
  serialization path (`sdk.mjs`) only reliably stringifies `options.settings`
  on the sandbox-merge branch; outside that branch the raw value flows to
  `child_process.spawn`'s argv array, which requires string elements. A
  pre-serialized string (`Jason.encode!/1` on the Elixir side) sidesteps the
  ambiguity entirely and matches the CLI's own "or a JSON string" framing of
  `--settings`.
- **Fallback — `settingSources: ["project"]` or `[]` at the `_meta.claudeCode
  .options` level:** coarser — `settingSources` gates CLAUDE.md loading
  globally ("Must include `'project'` to load CLAUDE.md files",
  `sdk.d.ts:1868`), not per-directory, so `[]` would ALSO suppress the
  primary ICM's own CLAUDE.md, which spec §C7 explicitly wants to keep.
  Only use this if `claudeMdExcludes` turns out not to behave as documented
  in a future live check.

Both are **unverified live** in this spike (blocked by the same rate limit
that blocked the prompt turn — see "Verified proof"). Recorded as the
concrete, source-grounded recipe; Task 1.2/1.3 should add a live check
(actually diffing the system prompt / asking the agent whether it saw the
related dir's CLAUDE.md) before relying on it unconditionally. If it turns
out NOT to suppress the auto-load as documented, that is an accepted **known
limitation** per the brief (Step 2's own escape hatch) — instruction
isolation would then rely on the primary ICM's own `context.md`
(`Valea.Agents.SessionSettings.context/1`, Task 1.2) explicitly telling the
agent not to treat the related ICM's conventions as its own.

### Managed settings (locked decision: in-memory `managedSettings` posture + callback)

**No file, but not callback-only either — this is the corrected decision.**
An earlier draft of this note locked in "callback-only, no file" and framed
it as safe because "the adapter's `SettingsManager` cannot be pointed at an
external file." That framing missed the actual risk: the ACP
`request_permission` callback only ever fires for tool calls the CLI's own
permission engine resolves to `"ask"`. Registering the callback (which is
what makes Valea's adapter launch pass `--permission-prompt-tool stdio` to
the CLI) does not by itself change what the CLI's permission engine decides
BEFORE the callback is consulted — that decision is driven by
settings + defaults + mode. With **zero** settings supplied (the old
decision), the CLI's own defaults govern that first-pass decision, and nothing
guarantees a sensitive write or a should-be-denied read falls through to
`"ask"` rather than being auto-resolved by the CLI itself, invisibly to
Valea. `Valea.Agents.ClaudeSettings`'s own moduledoc says this explicitly for
the workspace-root case Valea already ships
(`backend/lib/valea/agents/claude_settings.ex:51-60`, the "LOAD-BEARING
scoping" comment): an **unscoped** `Read` allow "would auto-approve reads of
ANY path the OS user can reach ... BEFORE the ACP permission callback
fires — making PermissionPolicy's outside-workspace deny and read-roots
allowlist dead code for reads." The same structural risk applies with **no**
settings at all, not just a badly-scoped one — a callback with nothing
upstream steering the CLI's first-pass decision toward `"ask"` is not a
guarantee.

**The fix, and the actual chosen mechanism:** the SDK exposes an in-memory
`Options.managedSettings` field (`sdk.d.ts:1859`, doc comment
`sdk.d.ts:1836-1858` — quoted in full in "Surface" above), documented for
exactly this case — "embedding applications ... that need to enforce
[lockdown settings] on the spawned subprocess without writing root-owned
files." The adapter forwards it verbatim: any value under
`_meta.claudeCode.options.managedSettings` on `session/new` spreads into
`userProvidedOptions` (`acp-agent.js:2856-2858`, quoted in "Surface" above —
`...userProvidedOptions` wins over adapter defaults) and reaches the SDK's
`query()` as `options.managedSettings`, which the SDK then serializes and
forwards as `--managed-settings <json>` to the underlying native CLI
(`sdk.mjs` line 88: `if(this.options.managedSettings)W.push("--managed-settings",this.options.managedSettings)`,
quoted in full in "Surface" above). **No file is written into or near the
ICM** — the value lives only in the adapter/CLI subprocess's argv and
memory for the life of that session, satisfying the "never write into the
ICM" invariant exactly as well as the old "no settings at all" decision did,
while actually closing the gap that decision left open.

Valea renders its posture as this `managedSettings` JSON (restrictive-only,
matching the SDK's own filtering — see "Surface" above): `ask` for
`Write`/`Edit`/`Bash`, `deny` for the workspace's protected subdirectories
(`logs/`, `config/`, `secrets/`, `runtime/`, `.git/`, `app.sqlite*`), and
`deny` for `WebFetch`/`WebSearch`. That posture is what **forces** the
sensitive calls spec §C7 cares about to fall through to `"ask"` — closing
exactly the gap the old "callback-only" decision left open — and
`Valea.Agents.PermissionPolicy.decide/2`, invoked on the resulting
`session/request_permission` callback, remains the sole place that turns
each `"ask"` into an actual `allow`/`deny` decision. In other words: the
posture sets up the gate, the callback is still what walks through it.
`Valea.Agents.SessionSettings.materialize!/1` (Task 1.2) still renders
`content/1` for a **future** harness that CAN accept an external file
(`Valea.Harness` behaviour's `settings_path` directive, left `nil` for
Claude Code) — that path is unaffected by this decision.

**Precondition before any real ICM session runs with writes/secrets
enabled:** the `managedSettings` posture above must get one live
end-to-end verification against a real `claude-agent-acp` subprocess —
confirming (a) a write attempt is `"ask"`-gated (not auto-allowed) under
the posture, (b) a secret-path read is denied, and (c) both round-trip
through `Valea.Agents.PermissionPolicy.decide/2` via the ACP callback, not
resolved by the CLI on its own. This spike attempted exactly that proof —
`session/new` now carries `_meta.claudeCode.options.managedSettings` with a
posture in this shape (see `backend/scripts/spike/acp_launch_probe.exs`) —
but the **tool-call turn itself was blocked by a real account monthly-spend
limit**, identically to the original run (see "Verified proof" below for
both runs' raw output). So today this note is honest about a **live/source
split**: `cwd`, `additionalDirectories`, and "no settings.json file ever
appears" (including with `managedSettings` now attached to `session/new`)
are **live-proven**; that the `managedSettings` posture actually produces
an `"ask"` for a write and a `deny` for a secret read via the callback is
**source/code-grounded** (the field:line citations above) but **not yet
independently live-verified**. Treat that live gap as a hard precondition,
not a formality, before Task 1.2/1.3 route a real ICM session through this
mechanism with writes or secrets enabled.

> **✅ PRECONDITION SATISFIED — live-verified 2026-07-16 (Phase 9 browser
> verification, session `20260715T224007.701935Z-f4bb3d95603e`).** Against a
> real `claude-agent-acp` subprocess with a live model turn (the rate limit
> had lifted), in a chat session whose cwd was the primary ICM root:
> (a) a `Write hello.md` attempt was **`ask`-gated** — the permission card
> (kind `edit`, `perm-0`) surfaced in the UI with the diff preview and was
> resolved `allow_once` by an actual user click, after which the file
> appeared at `<icm_root>/hello.md` with the exact requested content;
> (b) a `Read <workspace>/secrets/api_key.txt` attempt raised `perm-1`
> (kind `read`) through the ACP `session/request_permission` callback and
> was **auto-resolved `reject_once` by `Valea.Agents.PermissionPolicy`**
> with zero user interaction (transcript seq 34→35 adjacent; no card
> shown); the tool call failed with "User refused permission to run tool"
> and the secret content never reached the model. Both halves round-tripped
> through the callback — the CLI resolved neither on its own. Evidence:
> the session transcript in the verification workspace's
> `logs/sessions/<id>.jsonl` and the SDD ledger's Phase-9
> browser-verification entry.

This callback-answers-the-ask half is not hypothetical for Claude Code — it
is how Valea's existing chat/workflow session path **already** operates in
production today (posture-assisted via `ClaudeSettings.write!/1`'s
workspace-root file, not yet via `managedSettings`), unmodified by this
task except for the file→in-memory posture swap this note locks in. See
"Verified proof — production-grounded" below — and see "Rejected
alternatives" for why the file-based version of that posture is not the
path forward for ICMs specifically.

### Instruction isolation

Per spec §C7's fourth bullet ("related additional directories must not
contribute project instructions globally"): the mechanism is the
`claudeMdExcludes` recipe above, scoped to each related ICM's root. This
keeps `additionalDirectories`'s READ/tool-access grant (the reason it's
used at all — avoiding a round-trip per related-ICM read) separate from its
CLAUDE.md side-effect. If the live behavior check (Task 1.2/1.3) finds
`claudeMdExcludes` doesn't suppress it, the fallback is: keep
`additionalDirectories` for read access, and compensate purely at the
prompt level via `context.md` ("the following directories are readable for
reference; do not treat their CLAUDE.md as your own instructions unless
explicitly asked to act within that ICM").

### Rejected alternatives

- **Callback-only, no settings supplied at all** (this note's own original
  decision, before this review pass): rejected — as explained above, a bare
  callback with no upstream posture steering the CLI's first-pass decision
  is not a guarantee that sensitive calls reach it at all; the CLI's own
  defaults could auto-resolve them first. `managedSettings` is what
  supplies that steering without writing a file.
- **External settings file pointed at by the adapter** (fallback option
  1/`--settings <path>` reaching `SettingsManager`): **not forwarded** by
  this adapter version — `SettingsManager` only ever resolves `~/.claude`,
  `<cwd>/.claude`, and the OS-managed path (source-confirmed, see
  "Surface"). The bare `claude` CLI itself DOES have `--settings`, but the
  adapter never lets a caller route an ACP-level value into that flag for
  the SettingsManager's OWN resolution (only into
  `_meta.claudeCode.options.settings`, which is a **different** code path —
  it reaches the underlying CLI subprocess's argv, not `SettingsManager`;
  `SettingsManager` is the adapter's OWN separate settings resolution used
  for `permissions.defaultMode` and model allowlisting, and it never
  consults `options.settings`). This is also a structurally different
  channel from the chosen `managedSettings` field — `options.settings` is
  NOT restrictive-only-filtered by the SDK, so it is the wrong channel for
  a lockdown posture even where it IS forwarded. Re-verify if a future
  adapter version adds an explicit "external settings path" ACP param.
- **`<cwd>/.claude/settings.json` written into the ICM** (fallback option
  2): rejected — it clobbers the user's own config at that path (or, if
  none exists yet, silently claims that path for Valea, which a bare
  non-Valea harness opening the same ICM later would then also pick up).
  The ICM must stay usable by a bare harness with no Valea-owned residue in
  it. This is EXACTLY what `Valea.Agents.ClaudeSettings.write!/1`
  (`backend/lib/valea/agents/claude_settings.ex`) does TODAY for the
  Valea-workspace-root case (a location Valea already owns outright, unlike
  an ICM), which is precisely the pattern Task 1.2 replaces for the
  ICM-root case. Kept only as the historical baseline this spike
  supersedes, not as an option going forward for ICMs.
- **`_meta.valea.*` invention for additional read roots**: unnecessary —
  `additionalDirectories` is a native, first-class `session/new` field
  (confirmed above), so there is no need to invent a Valea-specific `_meta`
  extension for it. (`_meta.claudeCode.options.*` IS used, but that's the
  adapter's own documented SDK pass-through, not a Valea invention.)

---

## Proof harness (Step 3)

`backend/scripts/spike/acp_launch_probe.exs` — throwaway, not test-covered,
deletable once Task 1.2/1.3 land. It:

1. Creates three temp dirs: a **primary ICM** (`PRIMARY.md` + `CLAUDE.md`,
   used as `cwd`), a **related ICM** (`RELATED.md` + `CLAUDE.md`, used as
   the sole `additionalDirectories` entry), and a **secret** dir
   (`SECRET.md`, in neither), plus a fourth dir holding a **stand-in
   settings.json** (denying the secret dir) that is deliberately placed
   OUTSIDE cwd/additionalDirectories, to empirically test whether the
   adapter ever looks at it (a rejected-alternative check, not the chosen
   mechanism). Separately, `session/new` itself now also carries a
   `_meta.claudeCode.options.managedSettings` posture (ask
   `Write`/`Edit`/`Bash`; deny the secret dir; deny `WebFetch`/`WebSearch`)
   — the actual chosen mechanism — so the probe is ready to exercise it the
   moment a live tool-call turn is possible again.
2. Resolves the harness via `Valea.Harnesses.ClaudeCode.acp_command/1` and
   launches it via `Valea.Agents.ProcessRuntime.start/2` with
   `Valea.Agents.Env.minimal/0` as the subprocess environment — the exact
   three modules Task 1.2/1.3 will wire into the real `SessionServer` path,
   reused unchanged.
3. Speaks the ACP wire protocol **directly** (hand-rolled `initialize` →
   `session/new` with `additionalDirectories` → `session/prompt` →
   `session/request_permission` responder) rather than reusing
   `Valea.Acp.Connection`, because `Connection.new/1`
   (`connection.ex:378-401`) has no hook for `additionalDirectories` yet —
   adding one is explicitly Task 1.3's job, and this task must not refactor
   the runtime. The script's header comment explains this in full.
4. Drives one prompt asking the agent to: read `PRIMARY.md`, read
   `RELATED.md` by absolute path, attempt to read the secret file, attempt
   to write a new file — then answers every `session/request_permission`
   request it receives itself (standing in for
   `PermissionPolicy.decide/2` + `SessionServer.policy_decide/2`), denying
   everything, and prints a pass/fail summary plus the raw ACP traffic.

Run: `cd backend && mix run scripts/spike/acp_launch_probe.exs`

---

## Verified proof (Step 4)

### Live-proven (against a real `claude-agent-acp` subprocess, run twice)

```
<- initialize ok (protocolVersion=1)
-> session/new  cwd=/var/.../acp_probe_NNNNN/primary_icm  additionalDirectories=[/var/.../acp_probe_NNNNN/related_icm]
<- session/new ok (sessionId=20e7be56-57c0-4d97-b4de-0fffb085c102)
-> session/prompt (4-step read/read/read-secret/write instructions)
<- session/update  available_commands_update
<- session/update  usage_update
!! session/prompt FAILED: %{"code" => -32603, "data" => %{"errorKind" => "rate_limit"},
   "message" => "Internal error: You've hit your monthly spend limit. Run
   /usage-credits to manage your limit and keep using Fable 5 or switch
   models to continue this chat."}
<- session/update  session_info_update
```

- **cwd accepted, session created live**: `session/new` with a real
  temp-dir `cwd` succeeded and returned a real `sessionId` — twice, on two
  independent runs.
- **`additionalDirectories` accepted live, no error**: the adapter did not
  reject or ignore the field; the session negotiated successfully with it
  present. This is a genuine end-to-end confirmation that the installed
  `0.58.1` adapter understands the field at the wire level (not just in
  source).
- **No `settings.json` ever appeared in either ICM**, confirmed with the
  brief's own verification command, run against both temp dirs after the
  session ran:
  ```
  $ find <primary> <related> -name settings.json
  (no output — exit 0)
  ```
  This directly confirms the "Managed settings" contract above: the
  stand-in external settings file (in a third, unrelated temp dir) was
  never touched, and the adapter never wrote its own settings.json into
  either ICM.
- **The prompt turn itself never ran** — blocked by a genuine, reproducible
  account-level constraint (`errorKind: "rate_limit"`, "monthly spend
  limit"), captured verbatim above. Reproduced identically on a second run
  (not transient/retryable within this session). Per the task's own
  best-effort allowance, this is recorded as the exact blocker, not
  papered over. **No tool call, and therefore no
  `session/request_permission`, was ever observed live** — the four-step
  read/read/read-secret/write proof and the CLAUDE.md-auto-load proof are
  NOT independently live-verified this run; both remain source/binary and
  production-grounded (below).

### Third live run (this review-fix pass): `managedSettings` reaches `session/new` live, same rate-limit blocker on the prompt turn

After adding `_meta.claudeCode.options.managedSettings` to the probe's
`session/new` params (see "Proof harness" above), a third live run against
the real adapter subprocess produced:

```
<- initialize ok (protocolVersion=1)
-> session/new  cwd=/var/.../acp_probe_4422/primary_icm  additionalDirectories=[/var/.../acp_probe_4422/related_icm]  _meta.claudeCode.options.managedSettings=%{"permissions" => %{"ask" => ["Write", "Edit", "Bash"], "deny" => ["Read(/var/.../acp_probe_4422/secret/**)", "Edit(/var/.../acp_probe_4422/secret/**)", "Write(/var/.../acp_probe_4422/secret/**)", "WebFetch", "WebSearch"]}}
<- session/new ok (sessionId=c605898b-9c8b-4786-9ecb-2963dced1368)
-> session/prompt (4-step read/read/read-secret/write instructions)
<- session/update  available_commands_update
<- session/update  usage_update
!! session/prompt FAILED: %{"code" => -32603, "data" => %{"errorKind" => "rate_limit"},
   "message" => "Internal error: You've hit your monthly spend limit. Run
   /usage-credits to manage your limit and keep using Fable 5 or switch
   models to continue this chat."}
<- session/update  session_info_update
```

- **New live confirmation**: `session/new` accepted a real
  `_meta.claudeCode.options.managedSettings` payload without error or
  rejection, and negotiated a session (`sessionId` returned) — the adapter
  does not reject or ignore the `managedSettings` sub-field of
  `_meta.claudeCode.options`. This corroborates the "Surface" section's
  `...userProvidedOptions` spread claim (`acp-agent.js:2856-2858`) at the
  wire level, for `managedSettings` specifically, not just for the fields
  already covered by the first two runs.
- **`find <primary> <related> -name settings.json` still empty** after this
  run too — with `managedSettings` now attached, still no settings.json
  written into either ICM, and the same `.claude/<plugin-scaffold>/`
  directories (see below) reappeared in `primary_icm` only, unchanged from
  the prior two runs.
- **Same blocker, same exact `errorKind: "rate_limit"` message** — the
  prompt turn still never reached a tool call, so this run does **not**
  close the live gap on whether the posture actually produces an `"ask"`
  for the write step or a `deny` for the secret-read step. That remains the
  documented precondition (see "Managed settings" above) for any real ICM
  session with writes/secrets enabled.

### Unexpected live finding: `.claude/` subdirectories DO appear, but never `settings.json`

All three live runs left a `.claude/` directory in the **primary** ICM
(never in the related one) containing only empty subdirectories:
`audit/, plans/, research/, reviews/, skill-metrics/, solutions/` — no files,
and critically **no `settings.json`**. These directory names match
globally-installed Claude Code **plugin/skill scaffolding** (e.g. the
`superpowers` skill pack active in this very environment;
`writing-plans`/`subagent-driven-development` create an `audit/`-style
trail, `skill-creator` an eval `skill-metrics/` dir, etc.) — i.e. this comes
from the **operator's own global `~/.claude` plugin configuration**
initializing on session start, not from anything the adapter's
`SettingsManager` resolves and not from anything Valea writes. It happens
regardless of the "no settings file" decision.

**Known limitation for Phase 5:** a bare ICM opened under a Claude Code
account with global plugins/skills installed may still accumulate an empty
`.claude/<plugin-scaffold>/` skeleton on first session, independent of
Valea's own settings decision. This is orthogonal to C7 (it's not a
settings/permissions leak — no file content, no CLAUDE.md, no
config was written) but worth a doctor-check or `.gitignore`-by-convention
note in Phase 5 if it proves persistent across more accounts/environments.

### Source/binary-grounded (not independently live-reproduced this run)

- `additionalDirectories` → per-entry `--add-dir` argv (quoted `sdk.mjs`
  fragment above).
- `--add-dir` dirs feed CLAUDE.md discovery by default (`--bare` help text:
  "(CLAUDE.md dirs)"; corroborating internal binary strings
  `additionalDirectoriesForClaudeMd` et al.).
- `SettingsManager` never resolves an external file
  (`settings.js:76-97`, exhaustively read).
- `settingSources` gates CLAUDE.md loading ("Must include `'project'`",
  `sdk.d.ts:1868`) and the adapter's default is
  `["user", "project", "local"]` (`acp-agent.js:2858`).
- `claudeMdExcludes` (`sdk.d.ts:6298`) as the surgical suppression
  mechanism, forwarded via `options.settings` → `--settings <json-string>`
  (`sdk.mjs`, quoted above).
- `Options.managedSettings` (`sdk.d.ts:1859`, doc comment
  `sdk.d.ts:1836-1858`) → `--managed-settings <json-string>` argv (`sdk.mjs`
  line 88, `managedSettings:s?me(s):void 0` stringification at line 117,
  both quoted above) — the chosen enforcement channel. **Partially
  live-confirmed this run** (third live run above: `session/new` accepted
  the field without error) but the actual **effect** of the posture — that
  a write attempt gets `"ask"`'d and a secret read gets `deny`'d, both via
  the callback — is still source-grounded only, not independently
  live-observed (the prompt turn never ran in any of the three live runs).
  `restrictive-only` filtering of `managedSettings` (permissive keys like
  `permissions.allow` silently dropped) is documented in the same doc
  comment, not independently tested.

### Production-grounded: today's callback-reaching behavior is settings-posture-assisted, not callback-only

This is not a hypothesis riding on the blocked live run — it is how Valea's
**existing, shipped** chat/workflow session path already works today
(unmodified by this task except for the file→in-memory posture swap this
note locks in), and covered by a green test suite (`mix test
test/valea/acp/connection_test.exs test/valea/agents/session_server_test.exs
test/valea/agents/permission_policy_test.exs` → **59 passed**, run as part
of this task). Read this section as: "the callback reliably gets a chance
to decide, *given that a posture is in place steering the CLI toward
`"ask"` first*" — not as evidence that the bare callback alone would
suffice. Today's production posture is the file `Valea.Agents
.ClaudeSettings.write!/1` writes at the workspace root
(`backend/lib/valea/agents/claude_settings.ex:51-60`, the "LOAD-BEARING
scoping" comment quoted in "Managed settings" above) — exactly the same
structural role this note's `managedSettings` posture now plays for ICMs,
via a different (in-memory, not file) delivery channel. This is precisely
why "callback-only, no posture at all" was the wrong original decision:
production Claude Code sessions have never actually run callback-only:

- `Valea.Acp.Connection.dispatch_incoming/2` intercepts EVERY inbound
  `session/request_permission` request from the adapter
  (`connection.ex:466-492`) — for calls that reach the callback at all,
  there is no code path where the adapter's own permission mode can resolve
  the SAME tool call without Valea seeing it too, because `canUseTool:
  this.canUseTool(sessionId)` (`acp-agent.js:2887`) is wired for every tool,
  unconditionally, by the adapter itself. **One exception**: when the ACP
  session's mode is `"bypassPermissions"`, the adapter short-circuits
  before `canUseTool` is ever invoked and auto-allows —
  `if (session.modes.currentModeId === "bypassPermissions") { return
  {behavior: "allow", ...} }` (`acp-agent.js:2318-2326`, verified against
  the installed `0.58.1` adapter). Valea never selects that mode itself —
  no `bypassPermissions` string appears anywhere in `backend/lib/valea/`,
  and `session/new`/`session/set_mode` payloads Valea sends never set a
  mode — so this exception is a latent adapter capability, not a path
  Valea's own code exercises today. It would only trigger if a user
  explicitly selected a "bypass" config option surfaced by the adapter
  itself (`session/set_config_option`, `connection.ex:192-216`, a
  passthrough for whatever the adapter advertises) — worth a doctor-check
  or explicit exclusion of that mode from the config UI in a later phase if
  the adapter ever advertises it as selectable.
- `Valea.Agents.SessionServer.apply_effect(state, {:permission_requested,
  item})` → `policy_decide/2` (`session_server.ex:308-333`) calls
  `Valea.Agents.PermissionPolicy.decide/2` and answers the ACP request
  itself for `{:allow, _}`/`{:deny, _}` (`answer_now/3`,
  `session_server.ex:346-350`) — **never** left to the adapter/SDK to
  auto-resolve. Only `:ask` leaves the request open, surfaced to the
  timeline unresolved, for the frontend/human to answer via
  `SessionServer.answer_permission/3`.
- `test/valea/agents/session_server_test.exs:87` — "permission request
  reaches the timeline as ask; answering resolves it" — proves the
  ask-then-human-answers path end to end against a **fake** adapter
  (deterministic, no live model needed — exactly the "write is ask-gated,
  not auto-allowed" requirement from Step 4).
- `test/valea/acp/connection_test.exs:302` — "permission request -> item +
  effect; answer by kind -> matching optionId; re-answer is a no-op" —
  proves the wire-level `session/request_permission` → ACP
  `outcome: selected` round-trip is byte-correct.
  `test/valea/agents/permission_policy_test.exs:46` ("read of
  secrets/notes.txt -> deny") and `:139` ("read of an absolute path under NO
  root ... -> ask") prove `PermissionPolicy.decide/2`'s classification for
  exactly the "unreachable secret path" shape this spike's fixture models.

**Nuance worth flagging for Phase 5** (surfaced by trying to write this
spike's own decision function): under `PermissionPolicy.decide/2` **as it
exists today**, an absolute path that never nominally claims membership in
ANY enabled root — like this spike's `secret/` temp dir relative to the
primary/related ICM roots — classifies as `:ask`, not a hard `:deny` (see
the module's own moduledoc: "An absolute path that never nominally claimed
ANY enabled root... does NOT hard deny"). A hard `:deny` today is reserved
for the workspace's own named protected subdirectories
(`secrets/`, `logs/`, `.claude/`, `.git/`, `app.sqlite*`). Spec §C7's
Phase-5 policy (deny `logs/`, `config/`, `secrets/`, `runtime/`, `.git/`,
`app.sqlite*` under the **workspace**) doesn't add a "deny anything outside
declared ICM roots" rule either — it stays `:ask` there too. For an
interactive chat session a human eventually answers that ask; for an
unattended **workflow** session there is no human, so an unbounded `:ask`
for an out-of-scope read is operationally a stall, not a clean audited
denial. This spike's own permission responder papers over the distinction
(it denies everything it's asked about, since it has no human either) — but
Phase 5's `SessionScope`/`PermissionPolicy` extension should decide
explicitly whether "outside the primary+related ICM roots" becomes a hard
`:deny` for workflow sessions specifically, rather than inheriting today's
`:ask` fallback verbatim.

---

## Summary — what's settled vs. what Task 1.2/1.3 must still verify live

| Need | Mechanism | Proof |
|---|---|---|
| cwd | `session/new.cwd` | **Live** (this spike, x3) + already production |
| Additional read roots | `session/new.additionalDirectories` | **Live** (this spike, x3, session accepted) |
| Managed settings (posture delivery, no file) | in-memory `managedSettings` → `--managed-settings <json>` via `_meta.claudeCode.options.managedSettings` (`sdk.d.ts:1859`, `sdk.mjs` line 88) | **Live** (`session/new` accepts the field, no error, no settings.json ever appears — this spike, x1 with the field attached) + production (posture-assisted callback wiring exists today via the file-based predecessor, 59 tests) |
| Enforcement (posture forces writes/denied-reads to `"ask"`, callback decides) | `managedSettings` posture (ask/deny) → `session/request_permission` → `PermissionPolicy.decide/2` | **Production-grounded for the callback-decides half** (existing tests, file-based posture) — **NOT independently live-verified for the `managedSettings`-specific posture** this run (rate-limited before any tool call in all three runs). This is the documented precondition before real ICM sessions with writes/secrets enabled — see "Managed settings" above. |
| CLAUDE.md auto-loads from `additionalDirectories` | yes, by default | **Source/binary-grounded only** — not live-observed |
| Suppressing that auto-load | `claudeMdExcludes` via `_meta.claudeCode.options.settings` (JSON string) | **Source-grounded only, unverified live** — Task 1.2/1.3 must add a live check before depending on it |

Status for this task: **contract fully documented and decision corrected**
(in-memory `managedSettings` posture + callback, not callback-only — see
"Managed settings" above for why the original decision was wrong). Proof is
a mix of live (cwd + additionalDirectories + no-settings-file, including
with `managedSettings` attached) and strong source/production grounding
(the `managedSettings` field:line citations, and the file-based posture's
existing production behavior) — the live gap specific to this task is a
genuine, reproduced, external account constraint (monthly spend limit) that
blocked the prompt turn on all three runs, not a defect in the mechanism or
the probe. That gap is recorded as a hard **precondition** — one live
end-to-end verification of the `managedSettings` posture (write asks,
secret read denies, both via the callback) — before Task 1.2/1.3 route a
real ICM session through it with writes or secrets enabled.
