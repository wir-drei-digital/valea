# Session Origin in the System Prompt — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Starting a session from a mail message or a Knowledge entry opens a composer with the source attached and nothing sent; the agent learns the source from the injected system prompt instead of an auto-sent canned turn.

**Architecture:** The backend gains an explicit `opened_from` on the session scope, rendered by `SessionSettings.context/1` into the text already delivered via the ACP `_meta.systemPrompt` append channel. The frontend carries the origin in the `chat-new` pane descriptor (URL-serialized, so it survives reload), and both entry points stop creating sessions — the single creation site becomes `ChatView`'s `createAndPrompt`, which fires on send.

**Tech Stack:** Elixir/Phoenix + Ash actions (backend), SvelteKit 5 runes + Vitest (frontend), ExUnit (backend tests).

**Spec:** `docs/superpowers/specs/2026-08-02-session-origin-in-system-prompt-design.md`
**Issue:** wir-drei-digital/valea#3

## Global Constraints

- **Never `String.to_atom` the wire `kind`.** Match against the closed allowlist `"mail_message" | "page" | "file"`; anything else fails the action closed.
- **Three spellings, no drift.** Descriptor `'mail-message' | 'page' | 'file'` (hyphen) → wire `"mail_message" | "page" | "file"` (underscore) → scope atom `:mail_message | :page | :file`.
- **The premise paragraph never claims a grant mechanism.** Name the path; say nothing about how it became readable (`input` grants, `context_doc` does not).
- **`from.label` is untrusted** (URL-supplied): plain Svelte interpolation, never `{@html}`, capped at 80 chars at parse. Display only — grants derive from `from.path`.
- **`opened_from: nil` must render byte-identical `context/1` output to today**, so plain chat sessions cannot drift.
- **Backend formatting:** run `mix format` in `backend/` (the repo's format hook). **Never run prettier bare in `frontend/`** — it is not configured there.
- Backend tests: `cd backend && mix test <path>`. Frontend tests: `cd frontend && bun run test <path>`.

---

## File Structure

**Backend**
- `backend/lib/valea/agents/session_scope.ex` — accepts the `opened_from` opt, puts it on the scope.
- `backend/lib/valea/agents/session_settings.ex` — renders the premise paragraph in `context/1`.
- `backend/lib/valea/api/agents.ex` — new `opened_from_kind` argument; builds `opened_from` on create and on resume.
- Tests: `session_settings_test.exs`, `session_scope_test.exs`.

**Frontend**
- `frontend/src/lib/panes/pane-route.ts` — `from` on the descriptor; codec, identity, title.
- `frontend/src/lib/api/client.ts` — `createAgentSession` opts gain `openedFromKind`.
- `frontend/src/lib/components/views/ChatView.svelte` — `createAndPrompt` derives opts from `from`; attachment chip.
- `frontend/src/lib/components/mail/MessageView.svelte` — opens a descriptor instead of creating.
- `frontend/src/lib/components/knowledge/EntryMenu.svelte` — same, via `goto`.
- `frontend/src/routes/chat/+page.svelte` — renders a `chat-new` primary.
- `frontend/src/lib/components/mail/mail-shapes.ts` — delete `messageSessionPrompt`.
- `frontend/src/lib/stores/initial-prompt.ts` — delete `pageSessionPrompt` / `fileSessionPrompt`.
- Tests: `pane-route.test.ts`.

Backend tasks (1–3) are independent of frontend tasks (4–9) and can land first; the backend accepts the new argument as optional, so nothing breaks in between.

---

### Task 1: `opened_from` on the session scope

**Files:**
- Modify: `backend/lib/valea/agents/session_scope.ex:71-80` (typespec), `:134-186` (`build_scope`)
- Test: `backend/test/valea/agents/session_scope_test.exs`

**Interfaces:**
- Produces: `scope.opened_from :: %{path: String.t(), kind: :mail_message | :page | :file} | nil` — consumed by Task 2's `context/1` and set by Task 3's callers via the `:opened_from` opt.

- [ ] **Step 1: Write the failing test**

Append to `backend/test/valea/agents/session_scope_test.exs`. The file's `setup` yields `%{ws: ws.path, home: dir, generation: generation}` and provides `icm!/3` + `write_icms/2`; find an existing test that resolves a scope successfully and copy its ICM-fixture lines verbatim into the two below (they need one real, enabled ICM to resolve as primary).

```elixir
describe "opened_from" do
  test "carries the origin onto the scope when given", %{ws: ws, home: home, generation: gen} do
    # <-- copy the icm!/write_icms fixture lines from a passing test above,
    #     then use that ICM's mount key as `mount_key` here.
    root = icm!(home, "coaching", "icm-1")
    write_icms(ws, "  - path: #{root}\n")

    {:ok, scope} =
      SessionScope.resolve(%{
        kind: "chat",
        mount_key: "coaching",
        generation: gen,
        session_id: "s-opened-from",
        opened_from: %{path: Path.join(root, "CONTEXT.md"), kind: :page}
      })

    assert scope.opened_from == %{path: Path.join(root, "CONTEXT.md"), kind: :page}
  end

  test "is nil when the caller gives none", %{ws: ws, home: home, generation: gen} do
    root = icm!(home, "coaching", "icm-1")
    write_icms(ws, "  - path: #{root}\n")

    {:ok, scope} =
      SessionScope.resolve(%{
        kind: "chat",
        mount_key: "coaching",
        generation: gen,
        session_id: "s-no-origin"
      })

    assert scope.opened_from == nil
  end
end
```

If `write_icms/2`'s YAML shape differs from `  - path: <root>`, use the exact shape the neighbouring tests use — do not invent one.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && mix test test/valea/agents/session_scope_test.exs`
Expected: FAIL — `key :opened_from not found in: %{...}`

- [ ] **Step 3: Add the opt to the typespec**

In `session_scope.ex`, add to the `@type opts` map (after `optional(:include_mounts)`):

```elixir
          optional(:include_mounts) => [String.t()],
          optional(:opened_from) => %{path: String.t(), kind: atom()} | nil
```

- [ ] **Step 4: Put it on the scope**

In `build_scope/7`, inside the `scope = %{...}` literal, add after the `kind: kind` line:

```elixir
      kind: kind,
      # Spec 2026-08-02: what the session was opened FROM — a mail message or
      # a Knowledge entry. Deliberately NOT derived from `read_paths`: that is
      # a grant list, and a caller granting two files must not silently change
      # what the session claims to be about. `SessionSettings.context/1` turns
      # this into the premise paragraph the agent reads before its first act.
      opened_from: Map.get(opts, :opened_from)
```

Note `build_scope` computes `scope` BEFORE calling `ClaudeCode.launch(scope, session_dir)`, so `opened_from` is already present when `launch` renders the context — no ordering change needed.

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd backend && mix test test/valea/agents/session_scope_test.exs`
Expected: PASS

- [ ] **Step 6: Format and commit**

```bash
cd backend && mix format
cd .. && git add backend/lib/valea/agents/session_scope.ex backend/test/valea/agents/session_scope_test.exs
git commit -m "feat(sessions): carry opened_from on the session scope"
```

---

### Task 2: The premise paragraph in `context/1`

**Files:**
- Modify: `backend/lib/valea/agents/session_settings.ex:267-287`
- Test: `backend/test/valea/agents/session_settings_test.exs`

**Interfaces:**
- Consumes: `scope.opened_from` from Task 1.
- Produces: nothing new — `context/1`'s return string gains a paragraph.

- [ ] **Step 1: Write the failing tests**

Add to `backend/test/valea/agents/session_settings_test.exs`, after the existing `"context.md lists primary and related roots"` test (~line 144):

```elixir
describe "opened_from premise" do
  test "names a mail message and tells the agent to read it first" do
    md =
      SessionSettings.context(
        scope(%{
          opened_from: %{path: "/ws/sources/mail/mara/views/INBOX/42.md", kind: :mail_message}
        })
      )

    assert md =~ "opened from a mail message"
    assert md =~ "/ws/sources/mail/mara/views/INBOX/42.md"
    assert md =~ "read it before acting"
  end

  test "names a page and a file with their own wording" do
    page =
      SessionSettings.context(
        scope(%{opened_from: %{path: "/icms/coaching/CONTEXT.md", kind: :page}})
      )

    file =
      SessionSettings.context(
        scope(%{opened_from: %{path: "/icms/coaching/invoice.pdf", kind: :file}})
      )

    assert page =~ "opened from a page in this ICM"
    assert file =~ "opened from a file in this ICM"
  end

  # The premise must never assert HOW the path became readable: `input`
  # creates an explicit Read() allow, `context_doc` gets no grant at all and
  # is merely inside the primary's read root. One wording serves both only if
  # it claims neither.
  test "never claims a grant mechanism" do
    md =
      SessionSettings.context(
        scope(%{opened_from: %{path: "/icms/coaching/CONTEXT.md", kind: :page}})
      )

    refute md =~ "granted"
  end

  # Guards every plain chat session against drift.
  test "adds nothing when there is no origin" do
    assert SessionSettings.context(scope(%{})) ==
             SessionSettings.context(scope(%{opened_from: nil}))

    refute SessionSettings.context(scope(%{})) =~ "opened from"
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd backend && mix test test/valea/agents/session_settings_test.exs`
Expected: FAIL — the four new tests fail on the missing paragraph (the `nil` equality one passes trivially; that is fine, it is a guard).

- [ ] **Step 3: Render the paragraph**

In `session_settings.ex`, change `context/1`'s heredoc to interpolate a new clause. Replace the final `#{mail_accounts_paragraph(scope)}` line's block so the function ends:

```elixir
    """
    # Session context (Valea-managed)

    Primary ICM: #{scope.primary_icm.mount_key} — #{scope.primary_icm.root}
    Your working directory IS this ICM's root. Relative paths resolve here.

    Related ICMs available to this session (read their entrypoint only when your
    routing calls for it; they do not load automatically):
    #{related}
    #{mail_accounts_paragraph(scope)}#{opened_from_paragraph(scope)}
    """
  end

  # Spec 2026-08-02: the session's PREMISE, not one more available thing. An
  # entry point that opens on a specific message or page used to say so by
  # auto-sending a canned first turn; this replaces that turn, so the wording
  # has to do what the turn did — establish the subject AND get the file read
  # before the user's own instruction (which will say "this invoice", never a
  # path) is acted on.
  #
  # It deliberately does NOT say how the path became readable: a mail
  # message arrives as `input` (an explicit Read() allow), a Knowledge entry
  # as `context_doc` (no grant — it already sits inside the primary's read
  # root). Claiming a mechanism would be wrong for one of the two.
  defp opened_from_paragraph(scope) do
    case Map.get(scope, :opened_from) do
      %{path: path, kind: kind} when is_binary(path) ->
        "\nThis session was opened from #{opened_from_noun(kind)}: #{path}. " <>
          "The user started here deliberately — treat it as the subject of this " <>
          "session and read it before acting on their first instruction.\n"

      _none ->
        ""
    end
  end

  defp opened_from_noun(:mail_message), do: "a mail message"
  defp opened_from_noun(:page), do: "a page in this ICM"
  defp opened_from_noun(:file), do: "a file in this ICM"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd backend && mix test test/valea/agents/session_settings_test.exs`
Expected: PASS (all, including the pre-existing ones — the `nil` path must be unchanged)

- [ ] **Step 5: Format and commit**

```bash
cd backend && mix format
cd .. && git add backend/lib/valea/agents/session_settings.ex backend/test/valea/agents/session_settings_test.exs
git commit -m "feat(sessions): inject the session's origin as system prompt"
```

---

### Task 3: Wire `opened_from` through create and resume

**Files:**
- Modify: `backend/lib/valea/api/agents.ex:61-168` (create), `:277-310` (resume), `:433-440` (`resume_read_paths`)
- Test: `backend/test/valea/agents/session_scope_test.exs`

**Interfaces:**
- Consumes: Task 1's `:opened_from` opt.
- Produces: `create_session` gains argument `opened_from_kind :: String.t() | nil`; private helpers `opened_from/3` and `resume_opened_from/3`.

- [ ] **Step 1: Add the wire argument**

In `create_session`, after the `include_mounts` argument (~`:82`):

```elixir
      # Spec 2026-08-02: which KIND of thing this session was opened from.
      # Not inferable from the locator — `input` does imply a mail message
      # today, but `context_doc` covers both `page` and `file`, so the
      # locator alone cannot tell them apart. Validated against a closed
      # allowlist below; NEVER String.to_atom'd (client-supplied strings
      # creating atoms is unbounded atom growth).
      argument :opened_from_kind, :string, allow_nil?: true
```

- [ ] **Step 2: Add the allowlist helper and the builders**

Near `resume_read_paths/2` (~`:433`):

```elixir
  # Closed allowlist — the ONLY place a client string becomes an origin atom.
  # An unrecognized value is a caller error, not a default: a session that
  # silently mislabels its own premise would put wrong words in the agent's
  # system prompt.
  defp opened_from_kind("mail_message"), do: {:ok, :mail_message}
  defp opened_from_kind("page"), do: {:ok, :page}
  defp opened_from_kind("file"), do: {:ok, :file}
  defp opened_from_kind(nil), do: {:ok, nil}
  defp opened_from_kind(_other), do: {:error, :opened_from_kind_invalid}

  # The origin, built from whichever locator the caller supplied. `input`
  # wins when both are given (a mail message is the more specific claim);
  # in practice no caller sends both.
  defp opened_from(_kind, nil, nil), do: nil
  defp opened_from(nil, _input_abs, _context_doc), do: nil

  defp opened_from(kind, input_abs, context_doc) do
    case input_abs || context_doc do
      path when is_binary(path) -> %{path: path, kind: kind}
      _ -> nil
    end
  end
```

- [ ] **Step 3: Build it on create**

In `create_session`'s `run fn`, add the allowlist check to the `with` chain and pass the result. The chain becomes (changed lines only — keep every existing clause in order):

```elixir
        with :ok <- Manager.check_generation(generation),
             {:ok, %{path: workspace}} <- Manager.current(),
             {:ok, origin_kind} <-
               opened_from_kind(Map.get(input.arguments, :opened_from_kind)),
             {:ok, context_doc} <- resolve_context_doc(context_doc, workspace),
             {:ok, input_abs} <- resolve_session_input(input_locator, workspace),
             {:ok, scope} <-
               SessionScope.resolve(%{
                 kind: "chat",
                 mount_key: mount_key,
                 generation: generation,
                 session_id: id,
                 read_paths: if(input_abs, do: [input_abs], else: []),
                 include_mounts: include_mounts,
                 opened_from: opened_from(origin_kind, input_abs, context_doc)
               }),
```

`context_doc` here is the RESOLVED absolute path returned by `resolve_context_doc/2` (the `with` rebinds the name), which is what `opened_from/3` needs.

- [ ] **Step 4: Persist the kind so resume can rebuild it**

In `start_session`'s opts map inside the same `run fn`, add `opened_from_kind: Map.get(input.arguments, :opened_from_kind)` beside `include_mounts:`. Then in `backend/lib/valea/agents/session_server.ex`, in the meta map (~`:576`), add beside `"include_mounts"`:

```elixir
      "include_mounts" => Map.get(opts, :include_mounts, []),
      # Spec 2026-08-02: recorded verbatim like the two locators beside it, so
      # `resume_agent_session` can rebuild `opened_from` without re-deriving
      # which kind of thing the session was opened from.
      "opened_from_kind" => Map.get(opts, :opened_from_kind),
```

- [ ] **Step 5: Rebuild it on resume**

Add beside `resume_read_paths/2`:

```elixir
  # Resume mirrors `resume_read_paths/2`'s BEST-EFFORT posture: a vanished
  # locator narrows the resumed session (no origin) rather than blocking the
  # resume, because the transcript already holds whatever was read from it.
  # A resumed session must never name a path it can no longer read.
  defp resume_opened_from(nil, _meta, _workspace), do: nil

  defp resume_opened_from(kind_string, meta, workspace) do
    with {:ok, kind} when not is_nil(kind) <- opened_from_kind(kind_string),
         path when is_binary(path) <- resume_origin_path(meta, workspace) do
      %{path: path, kind: kind}
    else
      _unavailable -> nil
    end
  end

  defp resume_origin_path(meta, workspace) do
    case resume_read_paths(meta["input"], workspace) do
      [path | _] ->
        path

      [] ->
        case resolve_context_doc(meta["context_doc"], workspace) do
          {:ok, path} when is_binary(path) -> path
          _ -> nil
        end
    end
  end
```

Then in `resume_agent_session`'s `SessionScope.resolve` call, add after `include_mounts:`:

```elixir
                 include_mounts: meta["include_mounts"] || [],
                 opened_from: resume_opened_from(meta["opened_from_kind"], meta, workspace)
```

- [ ] **Step 6: Map the new error**

Confirm `error_for/1`'s generic atom clause covers `:opened_from_kind_invalid` (it maps unrecognized atoms to their string form — read `:457-470` to verify). If it has an explicit whitelist instead, add `:opened_from_kind_invalid` to it.

- [ ] **Step 7: Test the allowlist through the action**

`opened_from_kind/1` is the security-relevant seam (it is the boundary a client string must not cross as an atom), and it is reachable through `create_session` without a running harness — an invalid kind fails in the `with` chain before any session starts.

Find the test file that already drives `Valea.Api.Agents` actions (`ls backend/test/valea/api/`). Add there; if the directory has no agents test, create `backend/test/valea/api/agents_test.exs` copying the `setup` block and the Ash-invocation style from a sibling file in that directory verbatim.

```elixir
test "rejects an origin kind that is not in the allowlist", ctx do
  assert {:error, _} =
           create_session_action(ctx, %{
             mount_key: "coaching",
             generation: ctx.generation,
             opened_from_kind: "../../etc/passwd"
           })
end

test "accepts the three real origin kinds", ctx do
  for kind <- ["mail_message", "page", "file"] do
    assert {:ok, _} =
             create_session_action(ctx, %{
               mount_key: "coaching",
               generation: ctx.generation,
               opened_from_kind: kind,
               context_doc: %{"kind" => "icm", "icm_id" => "icm-1", "path" => "CONTEXT.md"}
             })
  end
end
```

Replace `create_session_action/2` with the sibling file's actual invocation helper (Ash code interface or `Ash.run_action`) — copy its exact call shape rather than inventing one.

Resume's rebuild is covered by Task 9 Step 7 (manual), not here: asserting it in a unit test would need a live harness session, and the observable behavior is `context.md`'s contents.

- [ ] **Step 8: Run the backend suite**

Run: `cd backend && mix test test/valea/agents/ test/valea/api/`
Expected: PASS

- [ ] **Step 9: Format and commit**

```bash
cd backend && mix format
cd .. && git add backend/lib/valea/api/agents.ex backend/lib/valea/agents/session_server.ex backend/test/valea/agents/session_scope_test.exs
git commit -m "feat(sessions): accept and resume the session's origin"
```

---

### Task 4: `from` on the `chat-new` descriptor

**Files:**
- Modify: `frontend/src/lib/panes/pane-route.ts:1-30` (grammar doc), `:49` (type), `:120-127` (parse), `:161-162` (serialize), `:197-198` (identity)
- Test: `frontend/src/lib/panes/pane-route.test.ts`

**Interfaces:**
- Produces:
  ```ts
  export type PaneOrigin = {
    kind: 'mail-message' | 'page' | 'file';
    path: string;
    mount?: string;
    label?: string;
  };
  export type ChatNewPaneDescriptor = {
    kind: 'chat-new';
    mountKey: string;
    from: PaneOrigin | null;
  };
  export const ORIGIN_LABEL_CAP = 80;
  ```
  Consumed by Tasks 5–8.

- [ ] **Step 1: Write the failing tests**

Add to `frontend/src/lib/panes/pane-route.test.ts`:

```ts
describe('chat-new origin', () => {
  const origin = {
    kind: 'mail-message' as const,
    path: 'views/INBOX/42.md',
    mount: 'mail-mara',
    label: 'Liefertermin'
  };

  it('round-trips a full origin', () => {
    const d: PaneDescriptor = { kind: 'chat-new', mountKey: 'life', from: origin };
    expect(parsePaneParam(serializePaneParam(d))).toEqual(d);
  });

  it('round-trips an origin with no mount and no label', () => {
    const d: PaneDescriptor = {
      kind: 'chat-new',
      mountKey: 'life',
      from: { kind: 'page', path: 'notes/CONTEXT.md' }
    };
    expect(parsePaneParam(serializePaneParam(d))).toEqual(d);
  });

  // Old links keep working and keep their exact wire form.
  it('leaves the blank composer wire form untouched', () => {
    const d: PaneDescriptor = { kind: 'chat-new', mountKey: 'life', from: null };
    expect(serializePaneParam(d)).toBe('chat:new:life');
    expect(parsePaneParam('chat:new:life')).toEqual(d);
  });

  it('encodes a path so its slashes cannot look like extra fields', () => {
    const d: PaneDescriptor = {
      kind: 'chat-new',
      mountKey: 'life',
      from: { kind: 'file', path: 'a/b/c.pdf' }
    };
    expect(serializePaneParam(d)).toBe('chat:new:life/file/a%2Fb%2Fc.pdf');
    expect(parsePaneParam(serializePaneParam(d))).toEqual(d);
  });

  // A present-but-unreadable origin must NOT degrade to a blank composer:
  // opening detached while looking normal is the bug the descriptor exists
  // to prevent.
  it.each([
    ['chat:new:life/mail-message', 'two fields'],
    ['chat:new:life/nope/x.md', 'unknown kind'],
    ['chat:new:life/page/', 'empty path'],
    ['chat:new:life/page/a/b/c/d', 'too many fields']
  ])('fails closed on a broken origin (%s)', (raw) => {
    expect(parsePaneParam(raw)).toBeNull();
  });

  it('caps a hostile label', () => {
    const long = 'x'.repeat(500);
    const parsed = parsePaneParam(`chat:new:life/page/n.md//${long}`);
    expect(parsed).not.toBeNull();
    expect((parsed as ChatNewPaneDescriptor).from?.label).toHaveLength(ORIGIN_LABEL_CAP);
  });

  // "A different subject still is a different pane" — without this, opening a
  // composer for message A then B recycles the pane and keeps A attached.
  it('gives two origins under one mount distinct identities', () => {
    const a: PaneDescriptor = {
      kind: 'chat-new',
      mountKey: 'life',
      from: { kind: 'mail-message', path: 'views/INBOX/1.md' }
    };
    const b: PaneDescriptor = {
      kind: 'chat-new',
      mountKey: 'life',
      from: { kind: 'mail-message', path: 'views/INBOX/2.md' }
    };
    expect(paneIdentity(a)).not.toBe(paneIdentity(b));
  });
});
```

Add `ORIGIN_LABEL_CAP` and `type ChatNewPaneDescriptor` to the file's existing import block, and update the existing `chatNew` fixture at `:34` to `{ kind: 'chat-new', mountKey: 'life', from: null }`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd frontend && bun run test src/lib/panes/pane-route.test.ts`
Expected: FAIL — type errors on `from`, and the new cases fail.

- [ ] **Step 3: Extend the type and the grammar doc**

In `pane-route.ts`, replace line 49 and add above it:

```ts
/**
 * What a new-session composer was opened FROM. `path` is the grant-bearing
 * field (mount-relative for a Knowledge entry, workspace-relative for a mail
 * message — whichever the matching locator wants); `mount` is the
 * `mail-<slug>` key for `includeMounts`; `label` is DISPLAY ONLY.
 *
 * `label` arrives from the URL and is therefore untrusted — a shared or
 * hand-written link can carry anything. It renders as plain text, never
 * `{@html}`, and is capped at parse so a long label cannot push the composer
 * out of its pane. Nothing is ever granted from it.
 */
export type PaneOrigin = {
  kind: 'mail-message' | 'page' | 'file';
  path: string;
  mount?: string;
  label?: string;
};

/** Display-only, URL-supplied — see `PaneOrigin.label`. */
export const ORIGIN_LABEL_CAP = 80;

export type ChatNewPaneDescriptor = {
  kind: 'chat-new';
  mountKey: string;
  from: PaneOrigin | null;
};
```

In the module doc's wire-form list (~`:15`), replace the `chat:new:` line with:

```
 *   chat:new:<mountKey>               (new-session composer scoped to that ICM;
 *                                      rewritten to chat:<id> once it starts)
 *   chat:new:<mountKey>/<originKind>/<path>[/<mount>[/<label>]]
 *                                     (composer opened FROM a message or entry;
 *                                      every field whole-string encoded, so the
 *                                      path's own `/` cannot look like a field
 *                                      separator — unlike files:, which encodes
 *                                      per segment for readable file URLs)
```

- [ ] **Step 4: Parse it**

Replace the `chat` branch's `new:` arm (`:122-125`):

```ts
    if (rest.startsWith('new:')) {
      const fields = rest.slice('new:'.length).split('/');
      const mountKey = tryDecode(fields[0]);
      if (!mountKey) return null;
      if (fields.length === 1) return { kind: 'chat-new', mountKey, from: null };
      // A present-but-broken origin fails the WHOLE descriptor. It must not
      // degrade to a blank composer: a composer that opens detached while
      // looking normal is exactly the "send an instruction about an email
      // that is not attached" bug this field exists to prevent. (files:'s
      // truncate/clamp repairs do not apply — those repair a still-correct
      // subject; a broken origin has no correct subject to fall back to.)
      if (fields.length < 3 || fields.length > 5) return null;
      const from = parseOrigin(fields.slice(1));
      return from ? { kind: 'chat-new', mountKey, from } : null;
    }
```

Add beside `parseCursor` (~`:80`):

```ts
const ORIGIN_KINDS = ['mail-message', 'page', 'file'] as const;

/** `[kind, path, mount?, label?]`, each whole-string encoded. Null if unusable. */
function parseOrigin(fields: string[]): PaneOrigin | null {
  const kind = tryDecode(fields[0]);
  const path = tryDecode(fields[1]);
  if (!kind || !path) return null;
  if (!(ORIGIN_KINDS as readonly string[]).includes(kind)) return null;
  const mount = fields[2] ? tryDecode(fields[2]) : null;
  const label = fields[3] ? tryDecode(fields[3]) : null;
  if (fields[2] && mount === null) return null;
  if (fields[3] && label === null) return null;
  return {
    kind: kind as PaneOrigin['kind'],
    path,
    ...(mount ? { mount } : {}),
    ...(label ? { label: label.slice(0, ORIGIN_LABEL_CAP) } : {})
  };
}
```

- [ ] **Step 5: Serialize it**

Replace the `chat-new` case (`:161-162`):

```ts
    case 'chat-new': {
      const mount = encodeURIComponent(d.mountKey);
      if (!d.from) return `chat:new:${mount}`;
      // Trailing empties are dropped; an absent mount with a present label
      // still needs its slot, so it serializes as an empty segment.
      const fields = [d.from.kind, d.from.path, d.from.mount ?? '', d.from.label ?? ''].map(
        encodeURIComponent
      );
      while (fields.length > 2 && fields[fields.length - 1] === '') fields.pop();
      return `chat:new:${mount}/${fields.join('/')}`;
    }
```

- [ ] **Step 6: Include the origin in identity**

Replace the `chat-new` case in `paneIdentity` (`:197-198`):

```ts
    case 'chat-new':
      // The ORIGIN is part of the subject: a composer opened on message A is
      // not the same pane as one opened on message B, and recycling would
      // leave A attached while the URL says B.
      return `chat-new:${d.mountKey}:${d.from?.path ?? ''}`;
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `cd frontend && bun run test src/lib/panes/pane-route.test.ts`
Expected: PASS

- [ ] **Step 8: Fix the two construction sites the type now breaks**

`frontend/src/routes/knowledge/+page.svelte:293` and `frontend/src/routes/knowledge/[...path]/+page.svelte:328` — add `from: null` to each `{ kind: 'chat-new', mountKey }`.

- [ ] **Step 9: Typecheck and commit**

Run: `cd frontend && bun run check`
Expected: no errors

```bash
git add frontend/src/lib/panes/pane-route.ts frontend/src/lib/panes/pane-route.test.ts frontend/src/routes/knowledge/+page.svelte "frontend/src/routes/knowledge/[...path]/+page.svelte"
git commit -m "feat(panes): let a new-session pane carry what it was opened from"
```

---

### Task 5: One creation site that knows the origin

**Files:**
- Modify: `frontend/src/lib/api/client.ts:2317-2352`, `frontend/src/lib/components/views/ChatView.svelte:368-395`

**Interfaces:**
- Consumes: `PaneOrigin` (Task 4), `opened_from_kind` (Task 3).
- Produces: `createAgentSession` opts gain `openedFromKind?: 'mail_message' | 'page' | 'file'`.

- [ ] **Step 1: Widen the client opts**

In `client.ts`'s `createAgentSession`, add to the opts type and forward it into the RPC params beside `includeMounts` (match the file's existing camel→snake convention — read the surrounding lines and follow exactly how `includeMounts` is passed):

```ts
  openedFromKind?: 'mail_message' | 'page' | 'file';
```

- [ ] **Step 2: Derive the create opts from `from`**

In `ChatView.svelte`, replace the `createAgentSession` call inside `createAndPrompt` (`:381`):

```ts
    const from = descriptor.from;
    const icmId = from && from.kind !== 'mail-message'
      ? mountsStore.mounts.find((m) => m.mountKey === descriptor.mountKey)?.id
      : undefined;

    if (from && from.kind !== 'mail-message' && !icmId) {
      creating = false;
      createError = 'This project has no loadable identity. Run Diagnose from the sidebar.';
      return;
    }

    // The grant is derived from `from.path` — never from `from.label`, which
    // is untrusted URL text and display-only.
    const opts =
      from === null
        ? undefined
        : from.kind === 'mail-message'
          ? {
              input: { kind: 'workspace' as const, path: from.path },
              includeMounts: from.mount ? [from.mount] : [],
              openedFromKind: 'mail_message' as const
            }
          : {
              contextDoc: { kind: 'icm' as const, icm_id: icmId as string, path: from.path },
              openedFromKind: from.kind === 'page' ? ('page' as const) : ('file' as const)
            };

    const result = await api.createAgentSession(
      descriptor.mountKey,
      workspaceStore.generation ?? 0,
      opts
    );
```

Add `mountsStore` to the component's imports if it is not already there (`import { mountsStore } from '$lib/stores/mounts.svelte';`).

- [ ] **Step 3: Preserve the typed create errors**

Still in `createAndPrompt`, extend the existing error mapping so a vanished locator says so instead of "try again":

```ts
      createError =
        result.error === 'harness_unavailable'
          ? "The assistant isn't ready — open Agent settings (the gear in the sidebar) and run the checks."
          : result.error === 'input_unavailable' || result.error === 'context_doc_unavailable'
            ? 'That file is no longer there. Close this composer and start again from the message or page.'
            : 'The session could not be started. Please try again.';
```

- [ ] **Step 4: Typecheck**

Run: `cd frontend && bun run check`
Expected: no errors

- [ ] **Step 5: Commit**

```bash
git add frontend/src/lib/api/client.ts frontend/src/lib/components/views/ChatView.svelte
git commit -m "feat(chat): create the session from the composer's origin"
```

---

### Task 6: The attachment chip

**Files:**
- Modify: `frontend/src/lib/components/views/ChatView.svelte:599-628`

**Interfaces:**
- Consumes: `descriptor.from` (Task 4).

- [ ] **Step 1: Render the row**

In the `chat-new` branch, above `<Composer>` and below the `createError` block:

```svelte
      {#if descriptor.from}
        <!-- Without this the change trades a canned turn the user did not want
             for an empty box with no visible evidence the source is in play.
             `label` is URL-supplied and untrusted: plain interpolation only,
             never {@html}. It is display-only — the grant comes from `path`. -->
        <div class="px-4 pb-2">
          <span
            class="inline-flex max-w-full items-center gap-1.5 truncate rounded-md bg-paper-card px-2 py-1 text-[12px] text-ink-meta"
          >
            <Paperclip class="size-3.5 shrink-0" aria-hidden="true" />
            <span class="truncate">
              {descriptor.from.label ?? descriptor.from.path.split('/').pop() ?? descriptor.from.path}
            </span>
          </span>
        </div>
      {/if}
```

Import the icon at the top of the component: `import Paperclip from '@lucide/svelte/icons/paperclip';`

- [ ] **Step 2: Verify against the design system**

Read `docs/DESIGN_SYSTEM.md` and confirm `bg-paper-card` / `text-ink-meta` are the right tokens for a secondary inline chip; substitute the documented ones if not. Do not invent colour values.

- [ ] **Step 3: Typecheck**

Run: `cd frontend && bun run check`
Expected: no errors

- [ ] **Step 4: Commit**

```bash
git add frontend/src/lib/components/views/ChatView.svelte
git commit -m "feat(chat): show what a new-session composer is attached to"
```

---

### Task 7: A `chat-new` primary on `/chat`

**Files:**
- Modify: `frontend/src/routes/chat/+page.svelte:151-153`, `:232-240`

**Interfaces:**
- Consumes: `ChatNewPaneDescriptor` (Task 4).

This also fixes a pre-existing bug: `routeFor` already promotes a `chat-new` pane to `/chat?icm=<key>` (`pane-route.ts:334`), which today lands on a dead "no session selected" screen.

- [ ] **Step 1: Parse the origin into the primary descriptor**

Replace `primaryDescriptor` (`:151-153`):

```ts
  // `?session=` names an open transcript; `?icm=` with no session is the
  // NEW-session composer (what `routeFor({kind:'chat-new'})` promotes to, and
  // where Knowledge's "start a session with this entry" navigates). `?from=`
  // carries the origin, serialized exactly as it is inside a pane param.
  const primaryDescriptor = $derived<PaneDescriptor | null>(
    selectedId
      ? { kind: 'chat', sessionId: selectedId }
      : parsePaneParam(chatNewParam(page.url))
  );
```

Add beside it:

```ts
  /**
   * The `chat:new:` pane-param spelling for this route's own query shape, so
   * the origin has exactly ONE codec. `?icm=` alone is the blank composer;
   * `?from=` appends the origin fields verbatim.
   */
  function chatNewParam(url: URL): string | null {
    const icm = url.searchParams.get('icm');
    if (!icm) return null;
    const from = url.searchParams.get('from');
    return from
      ? `chat:new:${encodeURIComponent(icm)}/${from}`
      : `chat:new:${encodeURIComponent(icm)}`;
  }
```

Import `parsePaneParam` from `$lib/panes/pane-route` alongside the existing imports from that module.

- [ ] **Step 2: Render it**

At `:237`, the view passes `descriptor` only when `kind === 'chat'`. Widen it so a `chat-new` primary reaches `ChatView` too:

```svelte
            descriptor={primaryDescriptor?.kind === 'chat' ||
            primaryDescriptor?.kind === 'chat-new'
              ? primaryDescriptor
              : null}
```

Read the surrounding block first — if the component's prop is typed to `ChatPaneDescriptor`, widen that type to `ChatPaneDescriptor | ChatNewPaneDescriptor` rather than casting.

- [ ] **Step 3: Confirm the created session replaces the composer**

`ChatView`'s `createAndPrompt` calls `context.sessionCreated?.(data.id)`. For the primary that means navigating to `/chat?session=<id>` — verify the route's `sessionCreated` handler does this (read `:176-200`) and add it if the primary does not wire one. `paneIdentity` must change from `chat-new:…` to `chat:<id>`, which it does, so the fresh component mounts and fires the stashed prompt.

- [ ] **Step 4: Typecheck and commit**

Run: `cd frontend && bun run check`

```bash
git add frontend/src/routes/chat/+page.svelte
git commit -m "fix(chat): render a new-session composer as the route's primary"
```

---

### Task 8: Both entry points stop auto-sending

**Files:**
- Modify: `frontend/src/lib/components/mail/MessageView.svelte:499-533`, `frontend/src/lib/components/knowledge/EntryMenu.svelte:86-101`
- Delete from: `frontend/src/lib/components/mail/mail-shapes.ts:1940-1956`, `frontend/src/lib/stores/initial-prompt.ts:23-47`

**Interfaces:**
- Consumes: `PaneOrigin` (Task 4), the `chat-new` primary (Task 7).

- [ ] **Step 1: Mail opens a descriptor instead of creating**

Replace `MessageView.svelte`'s `startSession()` body. It no longer calls `createAgentSession`, no longer imports `setInitialPrompt` or `messageSessionPrompt`, and opens beside exactly as it did with the created id:

```ts
  // Spec 2026-08-02: no session is created here any more. The composer opens
  // with the message attached and NOTHING sent; `ChatView.createAndPrompt`
  // creates the session on send, so abandoning the composer leaves nothing
  // behind. The mail contract the old canned prompt spelled out is already
  // injected as system prompt on every mail-mounted session.
  function startSession(): void {
    onStartSessionBeside({
      kind: 'chat-new',
      mountKey,
      from: {
        kind: 'mail-message',
        path: message.path,
        mount: mailMountKey,
        label: message.subject || message.from || 'Mail message'
      }
    });
  }
```

The prop changes shape. In `MessageView.svelte:78,88`, replace
`onSessionBeside: (sessionId: string) => void` with
`onStartSessionBeside: (d: ChatNewPaneDescriptor) => void`, importing the type
from `$lib/panes/pane-route`. Both call sites pass the descriptor straight to
`openBeside`, which already accepts one:

- `frontend/src/lib/components/panes/MailPane.svelte:76` →
  `onStartSessionBeside={(d) => context.openBeside?.(d)}`
- `frontend/src/routes/mail/+page.svelte:535` →
  `onStartSessionBeside={(d) => wiring.openBeside(d)}`

Read `MessageView`'s `message` type before writing the `label` — substitute the
real subject/sender field names for `message.subject` / `message.from` if they
differ. The label is display-only, so any short human string is correct; what
matters is that `path` and `mount` are exact.

- [ ] **Step 2: Knowledge navigates to the composer**

Replace `EntryMenu.svelte`'s `startSessionWithEntry()`:

```ts
  // Spec 2026-08-02: navigates to the composer instead of creating a session
  // and auto-sending a canned prompt. `goto` rather than a pane, because this
  // menu is rendered from `IcmTree` — the sidebar — which appears on routes
  // with no pane wiring at all.
  function startSessionWithEntry(): void {
    const from = `${kind === 'file' ? 'file' : 'page'}/${encodeURIComponent(path)}//${encodeURIComponent(name)}`;
    void goto(`/chat?icm=${encodeURIComponent(mountKey)}&from=${encodeURIComponent(from)}`);
  }
```

Drop the now-unused `sessionError` state, the `api`/`workspaceStore`/`recentSessionsStore`/`setInitialPrompt` imports, and the `mountsStore` icm-id lookup — the id is resolved at send time in Task 5 instead. Remove the `sessionError` render block too.

- [ ] **Step 3: Delete the canned prompts**

Delete `messageSessionPrompt` from `mail-shapes.ts` (with its doc comment) and `pageSessionPrompt` + `fileSessionPrompt` from `initial-prompt.ts` (with theirs). Keep `setInitialPrompt` / `takeInitialPrompt` — Task 5 still stashes the user's TYPED text through them. Update `initial-prompt.ts`'s module doc, which describes composing opening prompts.

Leave `cleanupPrompt` in `mail-shapes.ts` alone — the "Clean up inbox" start keeps its prompt by design.

- [ ] **Step 4: Confirm nothing still references the deleted functions**

Run: `cd frontend && grep -rn "messageSessionPrompt\|pageSessionPrompt\|fileSessionPrompt" src`
Expected: no output

- [ ] **Step 5: Typecheck and run the frontend suite**

Run: `cd frontend && bun run check && bun run test`
Expected: PASS. Fix any test that asserted on the deleted prompts by deleting that assertion — the behavior is gone on purpose.

- [ ] **Step 6: Commit**

```bash
git add frontend/src
git commit -m "feat(sessions): type the first instruction instead of auto-sending one"
```

---

### Task 9: Verify end to end

**Files:** none — verification only.

- [ ] **Step 1: Run both suites**

```bash
cd backend && mix test
cd ../frontend && bun run check && bun run test
```

Expected: PASS. Do not proceed while anything is red.

- [ ] **Step 2: Start the app**

Use the `.claude/launch.json` backend + frontend entries via `preview_start` (never `bash`). If the mail rig is needed, follow `docs/testing/` for the Dovecot fixture.

- [ ] **Step 3: Walk the mail path**

Open a message → **Start a session**. Confirm: a composer opens beside, nothing is streaming, and the chip names the message. Type an instruction that refers to the email only as "this" (e.g. "this is a new invoice, note it in my ICM"). Confirm the agent reads the right file without being given a path.

- [ ] **Step 4: Confirm the injected text**

Read `<workspace>/runtime/sessions/<id>/context.md` for that session. Confirm it contains the premise paragraph naming the message, and that the mail contract paragraph is still present.

- [ ] **Step 5: Walk the Knowledge path**

From the sidebar tree's ⋯ menu on a page and on a non-`.md` file: **Start a session with this page/file** → composer with the entry named, nothing sent. Send an instruction and confirm the agent reads it.

- [ ] **Step 6: Check the two failure modes**

- Abandon a composer without sending → no new session appears in the sessions list.
- Reload the browser with a composer open → the chip and attachment survive.

- [ ] **Step 7: Check resume**

Resume a session that was started from a message. Confirm `context.md` still names it.

- [ ] **Step 8: Commit any fixes and open the PR**

```bash
git push -u origin feat/session-origin-in-system-prompt
gh pr create --fill
```

Reference `Closes #3` in the PR body.

---

## Notes for the implementer

- **`.claude/launch.json` has uncommitted changes** unrelated to this work (dev-server entries pointing at dead worktrees). Leave them out of every commit — stage files explicitly, never `git add -A`.
- **The security hook fires on the spec filename.** It is a keyword false positive on a design doc. Two of its Iron Laws do genuinely apply and are already handled: the `String.to_atom` ban (Task 3 Step 2) and untrusted-content rendering (Tasks 4 and 6). The LiveView and Ecto laws do not apply — this change touches neither.
- **Backend and frontend are independently landable.** `opened_from_kind` is optional, so Tasks 1–3 can merge before any frontend work and change nothing observable.
