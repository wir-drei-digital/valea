# Session Origin in the System Prompt — Type Your Own First Instruction

**Date:** 2026-08-02
**Status:** Approved (design), pending implementation plan
**Issue:** wir-drei-digital/valea#3

## Goal

Starting a session from a mail message or a Knowledge entry must drop the
user into a composer with the source already in context and **nothing
sent**. The user's own instruction becomes turn one.

Today both entry points create the session, stash a canned opening prompt,
and navigate — the agent is already streaming a summary nobody asked for
before the user has typed a word. The canned turn burns time and tokens and
pushes the actual instruction down the transcript.

Three things change:

1. **The session's origin moves into the injected system prompt.** The
   agent learns *which* message or page the session was opened from before
   its first action, without a user turn saying so.
2. **The canned prompts go away**, and with them the auto-sent first turn.
   Both entry points route to the existing `chat-new` pane mode, which
   already defers session creation until send.
3. **The composer shows what is attached**, so the user can see the email
   is in play without an agent turn to prove it.

Explicitly **not** in scope: the mail "Clean up inbox" start
(`mail-shapes.ts:367`), which keeps its canned prompt — it has one obvious
intent, no per-session locator, and its prompt is the whole instruction
rather than a preamble to one. Also out: inlining message *content* into
the system prompt (see Rejected Alternatives), and any change to the
server-side `initial_prompt` argument or the `revise_mail_draft` /
schedules callers that use it.

## Background: what already reaches the agent

Valea already injects per-session context as a system prompt.
`SessionSettings.context/1` renders text, `ClaudeCode.launch/2` returns it
as `system_prompt_append` (`claude_code.ex:64`), and
`Acp.Connection.put_system_prompt/2` ships it via the adapter's
`_meta.systemPrompt` `{append: …}` channel (`connection.ex:584-592`). The
same text is materialized as `context.md` purely as a user-inspectable
record. It rides `session/new`, `load` **and** `resume` alike.

For a mail-mounted session that append **already contains the mail working
contract verbatim** (`session_settings.ex:325-331`): read under `views/`,
act only via YAML ops files in `ops/pending/`, drafts under `drafts/`,
never touch `maildir/`, you cannot send.

Sentences 3 and 4 of `messageSessionPrompt()`
(`mail-shapes.ts:1948`) are near-duplicates of that. **They can be deleted
with no replacement.** This resolves the issue's first open question: the
operating instructions are not at risk, because they were never carried by
the prompt in the first place.

The one thing the append does *not* carry is which message was opened.
That, and only that, is what this design adds.

## Architecture

### 1. Backend — an explicit `opened_from` on the scope

The two entry points reach the backend asymmetrically, and this is the
constraint that shapes the whole backend change:

| Entry point | Locator | Reaches `SessionScope.resolve`? |
|---|---|---|
| Mail message | `input` (workspace path) | Yes — folded into `read_paths` (`api/agents.ex:137`) |
| Knowledge page/file | `context_doc` (ICM locator) | **No** — resolved, then passed only to `start_session` for transcript meta |

So deriving the origin from `scope.read_paths` would silently work for mail
and quietly do nothing for Knowledge. Instead, `create_session` — which
already resolves both locators to absolute paths before calling
`SessionScope.resolve` — passes whichever is set through as a new opt, and
the scope carries it explicitly:

```elixir
opened_from: %{path: String.t(), kind: :mail_message | :page | :file} | nil
```

Deriving this explicitly rather than from `read_paths` is deliberate:
`read_paths` is a *grant* list. A future caller granting two files must not
accidentally change what the session claims to be about.

`kind` is supplied by the caller, not inferred. The backend cannot tell a
mail message from a Knowledge page by path shape, and guessing would be a
silent-wrong-answer failure mode.

`kind` rides as a **new `create_session` argument**, not as something read
off the locator. `input` implies `mail_message` today, but `context_doc`
covers both `page` and `file`, so the locator alone cannot distinguish them.

The three spellings are deliberately distinct and must not drift: the
descriptor uses `'mail-message' | 'page' | 'file'` (hyphenated, matching
frontend pane-param convention), the wire argument uses the underscored
`"mail_message" | "page" | "file"`, and the scope holds the atom
`:mail_message | :page | :file`. `createAndPrompt` maps descriptor → wire at
the single creation site; the backend maps wire → atom at the allowlist
below.

**`kind` crosses the wire as a string and must never be `String.to_atom`'d**
— that is unbounded atom creation from client input. It is matched against a
closed allowlist (`"mail_message"`, `"page"`, `"file"`), and anything else
fails the action closed rather than defaulting to a kind. The atom exists
only on the server side of that match. Same posture as `include_mounts`,
which validates each key against real mounts rather than trusting the
string.

### 2. Backend — the premise paragraph

`SessionSettings.context/1` renders a paragraph when `opened_from` is set,
and nothing at all when it is nil (so plain chat sessions are byte-identical
to today). Framing forks on `kind`; the shape is:

> This session was opened from a mail message: `<abs path>`. The user
> started here deliberately — treat that message as the subject of this
> session and read it before acting on their first instruction.

with "a page in this ICM" / "a file in this ICM" for `:page` / `:file`.

**The paragraph never claims a grant mechanism.** An earlier draft said
"(granted read)", which is true for mail (`input` becomes an explicit
`Read(<path>)` allow) and false for Knowledge (`context_doc` gets no grant
— it is readable only because it sits inside the primary ICM's read root,
`api/agents.ex:111-113`). Naming the path and saying nothing about how it
became readable is correct for both, and keeps `context/1` from asserting a
posture it did not build.

The instruction to *read before acting* is load-bearing. Without it the
locator reads as one more available thing in a context doc that is
otherwise a map of what exists, rather than as the session's premise. With
it, "this is a new invoice, document it in my ICM" works as turn one with no
antecedent problem.

### 3. Backend — resume parity

`resume_agent_session` rebuilds the scope from `meta.json`, re-resolving
`read_paths` from `meta["input"]` (`api/agents.ex:295`) and
`include_mounts` from the recorded list. It **ignores `meta["context_doc"]`**,
which is recorded verbatim right beside them (`session_server.ex:571`).

Both locators must be re-resolved on the resume path to regenerate
`opened_from`. Without this a resumed Knowledge session forgets its premise
while a resumed mail session keeps it — a difference with no defensible
reason. Grants are still re-resolved, never widened; `context_doc` gets no
grant on resume for the same reason it gets none on create (it lives inside
a read root already).

**Resume is best-effort, and `opened_from` follows the grant.** The existing
`resume_read_paths/2` deliberately narrows rather than blocks: a vanished
input file yields no grant instead of failing the resume, because "the
conversation already contains whatever was read from it"
(`api/agents.ex:265-276`). `opened_from` must move in lockstep — when the
locator no longer resolves, it is `nil` and the premise paragraph is
omitted. A resumed session must never name a path it cannot read.

### 4. Frontend — origin travels in the descriptor

```ts
export type ChatNewPaneDescriptor = {
  kind: 'chat-new';
  mountKey: string;
  from: {
    kind: 'mail-message' | 'page' | 'file';
    path: string;
    mount?: string;   // mail-<slug>, for includeMounts
    label?: string;   // human-readable, chip display only
  } | null;
};
```

`from: null` is today's blank-session behavior, so every existing
`chat:new:<mountKey>` link keeps parsing unchanged.

**Wire form**, extending the module's documented grammar:

```
chat:new:<mountKey>                              (blank composer — unchanged)
chat:new:<mountKey>/<kind>/<path>                (origin, no mount, no label)
chat:new:<mountKey>/<kind>/<path>/<mount>        (mail: adds includeMounts key)
chat:new:<mountKey>/<kind>/<path>/<mount>/<label>
```

Every field is whole-string `encodeURIComponent`'d — including `path`, whose
`/` becomes `%2F`. This deviates from the `files` descriptor's per-segment
`encodePath`, deliberately: `files` encodes per segment so file URLs stay
readable, but here `/` is the field separator, so a per-segment path would
be indistinguishable from extra fields. Trailing empty fields are omitted on
serialize; an empty `mount` with a present `label` serializes as an empty
segment (`…/<path>//<label>`).

Parse rules: exactly 1 field after the kind prefix means `from: null`; 3–5
fields parse an origin; 2 fields, more than 5, an unrecognized `kind`, or an
undecodable/empty `path` fail the whole descriptor closed. `label` is capped
at 80 characters at parse (§7).

**Not a module-level stash.** Reusing `initial-prompt.ts`'s in-memory map is
tempting and wrong: that map deliberately does not survive a reload, which
is fine for a prompt about to fire but not for a composer the user may sit
in. Losing the attachment silently and then sending "file this under
Müller" with nothing attached is a correctness bug, not lost chrome.
Serializing into the pane param follows the `files` descriptor's precedent
of packing structured data (a tab list plus a cursor, `pane-route.ts:105`).

**`paneIdentity` must include `from`.** It is `chat-new:${d.mountKey}` today
(`pane-route.ts:198`). Left alone, opening a composer for message A and then
for message B recycles the same pane and keeps A's attachment — precisely
the "a different subject still is a different pane" rule the module's own
comment sets out. It becomes `chat-new:${mountKey}:${from?.path ?? ''}`.

### 5. Frontend — one creation site

`MessageView.startSession()` and `EntryMenu.startSessionWithEntry()` stop
calling `createAgentSession` entirely. They open a `chat-new` descriptor
carrying `from` and nothing else.

The single creation site becomes `createAndPrompt` (`ChatView.svelte:379`),
which today calls `createAgentSession` with no opts and grows a
`from`-derived third argument:

- `mail-message` → `input: {kind:'workspace', path}` + `includeMounts: [mount]`
- `page` / `file` → `contextDoc: {kind:'icm', icm_id, path}`

Two divergent creation paths collapse into one. The grant is derived from
`from.path` **at send**, never from the display label, so a stale label can
never produce a wrong grant.

### 6. Frontend — the `/chat` primary route

Mail opens panes (`onSessionBeside`); Knowledge navigates
(`goto('/chat?session=…')`). Deferred, Knowledge wants `/chat?icm=<mountKey>`,
which `routeFor` already emits for `chat-new` (`pane-route.ts:334`).

The new parsing surface: `/chat` must read `from` into its **primary**
descriptor, not only into `pane` params. This is the one genuinely new piece
of route parsing in the change.

**`/chat` cannot render a `chat-new` primary at all today.** Its
`primaryDescriptor` is `{kind:'chat'}` when `?session=` is set and `null`
otherwise (`chat/+page.svelte:151-153`); `?icm=` only feeds
`primaryMountKey()` for the create button, and the view renders the
descriptor only when `kind === 'chat'` (`:237`).

That is a **pre-existing bug this change has to fix anyway**: `routeFor`
already promotes a `chat-new` pane to `/chat?icm=<key>` (`pane-route.ts:334`),
so hitting ⤢ on a new-session pane today lands on a dead "no session
selected" screen and silently loses the composer. Adding the primary state
serves Knowledge's navigation and closes that hole with one change.

Why `goto` rather than `openBeside` for Knowledge: `EntryMenu` is rendered
from `IcmTree` (`IcmTree.svelte:228,355`), the sidebar tree, which appears on
routes that have no pane wiring at all. A callback-when-available design
would give the same menu item two different behaviors depending on route.
Navigation works everywhere, and the primary state is needed regardless.

### 7. Frontend — the attachment chip

The `chat-new` branch renders a bare `Composer` (`ChatView.svelte:618-627`).
It gains an attachment row above it naming the source.

A maildir filename is meaningless to a user and the subject is not
derivable from the path without a lookup, so `from.label` carries a short
display string and the chip falls back to the path basename when it is
absent (a hand-written URL). The label may go stale between opening the
composer and sending — accepted: it is a draft-time affordance only, and
§5 derives the grant from `path`.

Without this row the change trades a canned turn the user did not want for
an empty box with no visible evidence the email is in play.

`from.label` is **URL-supplied and therefore untrusted** — a shared or
hand-written pane link can carry anything. It renders as plain text through
normal Svelte interpolation, never `{@html}`, and is length-capped at parse
so a long label cannot push the composer out of the pane. It is display-only
by construction: §5 derives the grant from `from.path`, so a hostile label
can mislead the eye but can never widen what the session may read.

## Error handling

- **Locator no longer resolves at send.** Unchanged from today —
  `create_session` fails closed with `context_doc_unavailable` /
  `input_unavailable` rather than starting a contextless session. The
  composer surfaces it through the existing `createError` row
  (`ChatView.svelte:618`) with its typed text, and the typed message is
  preserved so the user is not told to "try again" for a deleted file.
- **Malformed `from` in a hand-written URL.** The whole descriptor fails
  closed to `null`, exactly like every other malformed pane param. An
  earlier draft of this spec had it degrade to `from: null`, which
  contradicts §4: a composer that opens *detached* while looking normal is
  the same "user types 'file this under Müller' with nothing attached" bug
  the descriptor design exists to prevent. A `from` that is absent entirely
  is a legitimate blank composer; a `from` that is present but unreadable is
  not, and the pane must not open. `parsePaneParam`'s two repair cases
  (Files tab truncation, cursor clamping) do not apply — those repair a
  still-correct subject, whereas a broken origin has no correct subject to
  fall back to.
- **`opened_from` path outside every read root.** Cannot occur through the
  UI (both locators are validated pre-scope), but `context/1` states the
  grant as fact, so the renderer must not invent one: it names the path the
  scope was actually built with, and nothing else.

## Testing

**Backend**

- `session_settings_test.exs` — `context/1` with each `opened_from` kind
  renders the premise paragraph; with `nil` the output is byte-identical to
  the current fixture (guards plain chat sessions against drift).
- `session_scope_test.exs` — `opened_from` is populated from an `input`
  locator and from a `context_doc` locator; absent when neither is given.
- `api/agents` — a resumed session with a recorded `context_doc`
  regenerates the same `opened_from` as it had at create. This is the
  regression the resume path currently would not catch.

**Frontend**

- `pane-route.test.ts` — round-trip serialize/parse for each `from.kind`;
  `from: null` round-trips to today's string; malformed input yields `null`;
  `paneIdentity` differs for two different `from.path`s under one mountKey.
- `pane-offer.test.ts` — existing `chat-new` beside-`chat` carve-outs still
  hold with a populated `from`.
- `ChatView` — `createAndPrompt` sends the right opts shape per kind, and
  the chip renders label-then-basename fallback.

**Manual**

- Open a mail message → Start a session → composer, nothing streaming, chip
  names the message. Type an instruction referring to it only as "this" and
  confirm the agent reads the right file without being told a path.
- Abandon a composer → no empty session in the sessions list.
- Reload the browser on an open composer → attachment survives.

## Rejected alternatives

**Inline the message headers and body into the append.** Would let turn one
start fully informed with no `Read`. Rejected: unbounded size, it duplicates
a file the agent can already read, and it bakes a snapshot into a prompt
that may outlive the session's view of the mailbox. One tool call is a fine
price, and the user confirmed as much.

**Trim the canned prompts, keep auto-send.** De-risks the injection change
on its own but does not fix the complaint in the issue — the unwanted turn
is the point.

**Mail only, Knowledge later.** Considered and rejected during design:
Knowledge is the case that most needs this, since `context_doc` is injected
nowhere today and its canned prompt is therefore genuinely load-bearing in
a way mail's is not.

**A free-form `system_prompt` argument on `create_session`.** Maximum
flexibility, and wrong: it would make the injected context caller-shaped
prose rather than a rendering of the resolved scope, and every caller would
reinvent the framing. `opened_from` is structured, so `context/1` stays the
single author of what the agent is told.
