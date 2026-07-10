# Agent Prototype Slice Implementation Plan (Phase 3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The full AI-prepares-human-approves loop with zero external integrations: ACP agent sessions inside the workspace, a real Chat surface, workflow execution on the seeded mock email, a hardened approval queue, an audit trail, and workspace switching.

**Architecture:** A pure ACP codec (vendored from legend, updated to current protocol) drives a per-session GenServer that spawns `claude-agent-acp` via erlexec with the workspace as cwd. The agent proposes; the server owns all identity and execution (staging path → validated envelope → `queue/pending/` → atomic approve). All workspace-bound processes live under a `Workspace.Runtime` supervisor stamped with a generation. Everything the agent consumes or produces is a plain file (file-first principle — no MCP, no custom tools).

**Tech Stack:** Elixir/Phoenix/Ash + erlexec + yaml_elixir (backend), ash_typescript RPC + Phoenix channels, SvelteKit/Svelte 5 + shadcn-svelte (frontend), Tauri v2 + Burrito sidecar (desktop), `@agentclientprotocol/claude-agent-acp` (adapter).

**Spec:** `docs/superpowers/specs/2026-07-10-agent-slice-design.md` — the binding document. Read it once before Task 1 if you are the controller; implementers receive relevant excerpts below.

**Donor repo (READ-ONLY):** `/Users/daniel/Development/legend` — never modify it. Vendored files get an origin header comment naming the source path.

## Global Constraints

- Adapter: `@agentclientprotocol/claude-agent-acp`, binary `claude-agent-acp`, Node 22+. ACP protocol version `1`, NDJSON framing (newline-delimited JSON-RPC, NO Content-Length headers).
- `initialize` sends `clientInfo: {name: "valea", version: <app version>}`; a negotiated `protocolVersion != 1` fails the handshake.
- Session start preference: `session/resume` (if `sessionCapabilities.resume`) → `session/load` (if `agentCapabilities.loadSession`, replay deduped by `messageId`) → `session/new`. `mcpServers` is ALWAYS `[]` (file-first principle).
- Config: `session/set_config_option` + `config_option_update`; `session/set_mode` only as deprecated fallback; `session/set_model` is never used.
- Cancellation answers every pending permission request with `{"outcome": {"outcome": "cancelled"}}` before clearing.
- Permission options are selected by `kind` (`allow_once` / `reject_once`), never by assuming option ids. Auto-allow always picks `allow_once`, never "always".
- Permission policy precedence: deny → allow → ask; unclassifiable = `:ask`. Hard-deny: `secrets/`, `logs/`, `.claude/`, `.git/`, `app.sqlite*`, network tools. Reads auto-allow ONLY inside `icm/`, `sources/`, `prompts/` + root instruction files. Workflow runs may write ONLY their exact staging path; chat sessions have NO automatic write root.
- The agent subprocess: absolute executable path, argv without a shell, minimal env allowlist (`HOME`, `PATH`, `USER`, `LOGNAME`, `LANG`, `LC_ALL`, `LC_CTYPE`, `TMPDIR`, `SHELL`, plus `ANTHROPIC_API_KEY`/`CLAUDE_CODE_OAUTH_TOKEN` when set). NEVER the backend's full environment.
- Harness executable config lives in app config (`Valea.App.Config`), NEVER in workspace files.
- stderr is a separate stream — logged, never fed to the JSON decoder.
- Transcripts: `logs/sessions/<session-id>.jsonl`, line 1 metadata (`schema: "session/v1"`), then `{"seq": n, "item": {...}}` lines, appended as items arrive.
- Queue: agent writes `proposal/v1` to `queue/staging/<run_id>/proposal.json`; server writes `queue_item/v1` envelope to `queue/pending/<run_id>.json`; approve = revision-guarded, atomic `pending → processing → approved`, intent audit record before execution, idempotent draft at `sources/mail/drafts/<run_id>.md`.
- Every mutating Phase-3 RPC and `save_icm_page` carries `generation :: integer`; stale → error `workspace_changed`.
- Frontend renders agent text with plain Svelte interpolation — `{@html}` is FORBIDDEN for any agent-derived content.
- Design system: `docs/DESIGN_SYSTEM.md` is binding (green acts / amber suggests / terracotta warns; terracotta never filled; no exclamation marks in copy; "Knowledge" not "Memory").
- Determinism contract: opening and saving an untouched ICM page writes nothing; frontmatter blocks are reattached byte-identical; canonical body form is one line per block with NO trailing newline.
- Ports: Phoenix dev 4200, Vite 4273, desktop sidecar 4817 (loopback only).
- All new RPC actions use constrained map returns (typed fields) — never unconstrained `:map` for new surface.
- Commits end with: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- Run backend tests from `backend/` with `mix test`; frontend from `frontend/` with `bun run test` (vitest) and `bun run check` (svelte-check). `just test` runs everything including the codegen staleness gate — regenerate with `just codegen` after changing RPC actions.

## File Map (created/modified)

Backend (`backend/`):
- `lib/valea/agents/process_runtime.ex` (T1) — erlexec pipes spawner
- `lib/valea/agents/command_spec.ex` (T7), `lib/valea/harness.ex` (T7), `lib/valea/harnesses/claude_code.ex` (T7), `lib/valea/agents/env.ex` (T7)
- `lib/valea/agents/claude_settings.ex` (T2), `priv/workspace_template/**` (T2)
- `lib/valea/workspace/migration.ex` (T3), `lib/valea/workspace/scaffold.ex` (T3, modify)
- `lib/valea/icm.ex` + `lib/valea/icm/references.ex` (T4, modify)
- `lib/valea/workspace/runtime.ex` (T5), `lib/valea/workspace/manager.ex` (T5, modify), `lib/valea/audit.ex` (T5), `lib/valea/icm/watcher.ex` (T5+T13, modify)
- `lib/valea_web/plugs/control_token.ex` (T6), `lib/valea_web/channels/user_socket.ex` (T6, modify), router/health/SPA controllers (T6, modify)
- `lib/valea/acp/connection.ex` (T8) — vendored codec
- `lib/valea/agents/session_server.ex` (T9), `lib/valea/agents/session_supervisor.ex` (T9), `test/support/fake_adapter.exs` (T9)
- `lib/valea_web/channels/agent_session_channel.ex` (T10), `lib/valea/agents.ex` (T10)
- `lib/valea/agents/permission_policy.ex` (T11), `lib/valea/paths.ex` (T11)
- `lib/valea/workflows.ex` + `lib/valea/workflows/runner.ex` (T12)
- `lib/valea/queue.ex` (T13)
- `lib/valea/agents/doctor.ex` (T14)
- `lib/valea/api/agents.ex`, `lib/valea/api/queue.ex`, `lib/valea/api/error.ex` (T15)

Frontend (`frontend/src/`):
- `lib/api/client.ts` (T15, modify), generated `lib/api/ash_rpc.ts`/`ash_types.ts` (T15)
- `lib/stores/agent-session.svelte.ts`, `lib/stores/queue.svelte.ts`, `lib/stores/workflows.svelte.ts` (T16)
- `lib/components/agent/*` (T17), `routes/chat/+page.svelte` + doctor (T18)
- `routes/+page.svelte` Today + `routes/queue/[run_id]/+page.svelte` (T19)
- `routes/workflows/+page.svelte`, `routes/audit/+page.svelte` (T20)
- `lib/components/shell/Sidebar.svelte` + workspace switcher + `lib/stores/page-editor.svelte.ts` guard (T21)

Desktop (`desktop/`): token/nonce generation + init script (T6).

Docs: `docs/VISION.md`, `docs/ARCHITECTURE.md` (T22).

---

### Task 1: erlexec process runtime — proven in the packaged app (RISK GATE)

Everything in this phase depends on erlexec's C port binary surviving Burrito packaging. Prove it FIRST. If the packaged app cannot spawn/kill a subprocess tree, STOP and report BLOCKED — the phase needs a different process runtime.

**Files:**
- Modify: `backend/mix.exs` (add dep)
- Create: `backend/lib/valea/agents/process_runtime.ex`
- Create: `backend/test/valea/agents/process_runtime_test.exs`
- Modify: `backend/lib/valea/api/workspace.ex` (temporary diagnostic action — see Step 6)

**Interfaces:**
- Produces: `Valea.Agents.ProcessRuntime.start(spec, owner_pid)` → `{:ok, handle} | {:error, String.t()}` where `spec` is `%{cmd: String.t() (absolute path), args: [String.t()], env: %{String.t() => String.t()}, cd: String.t()}` and `handle` is opaque (`%{os_pid: integer, exec_pid: pid}`).
- `write(handle, iodata)` → `:ok`; `stop(handle)` → `:ok` (kills the whole process group, 5s kill timeout).
- Owner receives: `{:runtime_output, binary}`, `{:runtime_stderr, binary}`, `{:runtime_exit, integer | nil}`.

- [ ] **Step 1: Add the dependency**

In `backend/mix.exs` deps, add:

```elixir
{:erlexec, "~> 2.0"},
```

Run: `cd backend && mix deps.get && mix compile`
Expected: compiles clean (erlexec builds its C port program).

- [ ] **Step 2: Write the failing test**

`backend/test/valea/agents/process_runtime_test.exs`:

```elixir
defmodule Valea.Agents.ProcessRuntimeTest do
  use ExUnit.Case, async: false

  alias Valea.Agents.ProcessRuntime

  @cat System.find_executable("cat")

  test "spawns with pipes, echoes stdin to owner as runtime_output, exits" do
    {:ok, handle} =
      ProcessRuntime.start(%{cmd: @cat, args: [], env: %{}, cd: System.tmp_dir!()}, self())

    :ok = ProcessRuntime.write(handle, "hello\n")
    assert_receive {:runtime_output, "hello\n"}, 2_000

    :ok = ProcessRuntime.stop(handle)
    assert_receive {:runtime_exit, _code}, 6_000
  end

  test "stderr arrives as a separate message, never mixed into stdout" do
    sh = System.find_executable("sh")

    {:ok, handle} =
      ProcessRuntime.start(
        %{cmd: sh, args: ["-c", "echo out; echo err 1>&2; sleep 5"], env: %{}, cd: System.tmp_dir!()},
        self()
      )

    assert_receive {:runtime_output, out}, 2_000
    assert out =~ "out"
    assert_receive {:runtime_stderr, err}, 2_000
    assert err =~ "err"
    :ok = ProcessRuntime.stop(handle)
    assert_receive {:runtime_exit, _}, 6_000
  end

  test "stop kills the whole process group (no orphaned children)" do
    sh = System.find_executable("sh")

    {:ok, handle} =
      ProcessRuntime.start(
        %{cmd: sh, args: ["-c", "sleep 300 & echo started; wait"], env: %{}, cd: System.tmp_dir!()},
        self()
      )

    assert_receive {:runtime_output, _}, 2_000
    os_pid = handle.os_pid
    :ok = ProcessRuntime.stop(handle)
    assert_receive {:runtime_exit, _}, 6_000
    # After group kill, no `sleep 300` child of the dead shell survives.
    Process.sleep(200)
    {out, _} = System.cmd("pgrep", ["-g", to_string(os_pid)], stderr_to_stdout: true)
    assert out == ""
  end

  test "missing executable returns error, does not raise" do
    assert {:error, _} =
             ProcessRuntime.start(%{cmd: "/nonexistent/bin", args: [], env: %{}, cd: "/tmp"}, self())
  end
end
```

- [ ] **Step 3: Run to verify failure**

Run: `cd backend && mix test test/valea/agents/process_runtime_test.exs`
Expected: FAIL — module not defined.

- [ ] **Step 4: Implement**

`backend/lib/valea/agents/process_runtime.ex`. Study the donor first:
`/Users/daniel/Development/legend/backend/lib/legend/runtimes/local_pty.ex` (156 lines) — we need only its `:pipes` half, no PTY, no CommandSpec dependency yet (plain map spec keeps T1 dependency-free):

```elixir
defmodule Valea.Agents.ProcessRuntime do
  @moduledoc """
  Spawns an OS subprocess with plain stdio pipes via erlexec and relays its
  output to an owner process as messages:

      {:runtime_output, binary}   # stdout — the NDJSON stream
      {:runtime_stderr, binary}   # stderr — NEVER fed to the JSON decoder
      {:runtime_exit, code | nil} # nil for signal kills

  Vendored pattern from legend's Legend.Runtimes.LocalPty (pipes mode).
  `stop/1` kills the whole process group so adapter children never orphan.
  """

  @start_timeout_ms 5_000

  @spec start(map(), pid()) :: {:ok, map()} | {:error, String.t()}
  def start(%{cmd: cmd} = spec, owner) when is_pid(owner) do
    cond do
      !is_binary(cmd) or cmd == "" -> {:error, "no executable configured"}
      !File.exists?(cmd) -> {:error, "executable not found: #{cmd}"}
      true -> do_start(spec, owner)
    end
  end

  defp do_start(spec, owner) do
    relay = spawn_relay(spec, owner)

    receive do
      {:relay_started, ^relay, os_pid} -> {:ok, %{os_pid: os_pid, exec_pid: relay}}
      {:relay_failed, ^relay, reason} -> {:error, inspect(reason)}
    after
      @start_timeout_ms ->
        Process.exit(relay, :kill)
        {:error, "subprocess start timed out"}
    end
  end

  defp spawn_relay(spec, owner) do
    parent = self()

    spawn(fn ->
      argv = [spec.cmd | spec.args]

      run_opts = [
        :stdin,
        {:stdout, self()},
        {:stderr, self()},
        {:env, Map.to_list(spec.env)},
        {:cd, spec.cd},
        {:group, 0},
        {:kill_group, true},
        :monitor,
        {:kill_timeout, 5}
      ]

      case :exec.run(argv, run_opts) do
        {:ok, _pid, os_pid} ->
          send(parent, {:relay_started, self(), os_pid})
          relay_loop(os_pid, owner)

        {:error, reason} ->
          send(parent, {:relay_failed, self(), reason})
      end
    end)
  end

  defp relay_loop(os_pid, owner) do
    receive do
      {:stdout, ^os_pid, data} ->
        send(owner, {:runtime_output, data})
        relay_loop(os_pid, owner)

      {:stderr, ^os_pid, data} ->
        send(owner, {:runtime_stderr, data})
        relay_loop(os_pid, owner)

      {:DOWN, ^os_pid, :process, _pid, reason} ->
        send(owner, {:runtime_exit, decode_exit(reason)})

      {:write, data} ->
        :exec.send(os_pid, IO.iodata_to_binary(data))
        relay_loop(os_pid, owner)

      :stop ->
        :exec.stop(os_pid)
        relay_loop(os_pid, owner)
    end
  end

  @spec write(map(), iodata()) :: :ok
  def write(%{exec_pid: relay}, data) do
    send(relay, {:write, data})
    :ok
  end

  @spec stop(map()) :: :ok
  def stop(%{exec_pid: relay}) do
    send(relay, :stop)
    :ok
  end

  defp decode_exit(:normal), do: 0
  defp decode_exit({:exit_status, status}), do: :exec.status(status) |> exit_code()
  defp decode_exit(_), do: nil

  defp exit_code({:status, code}), do: code
  defp exit_code({:signal, _sig, _core}), do: nil
end
```

Note `{:group, 0}` + `{:kill_group, true}` — the process-group cleanup the spec requires. erlexec's `:exec` application must be started: add `:erlexec` to `extra_applications` in `mix.exs` (`extra_applications: [:logger, :erlexec, ...existing...]`).

- [ ] **Step 5: Run tests to verify pass**

Run: `cd backend && mix test test/valea/agents/process_runtime_test.exs`
Expected: 4 tests pass.

- [ ] **Step 6: Add the temporary packaged-app diagnostic RPC**

In `backend/lib/valea/api/workspace.ex`, add a generic action (follow the file's existing action style exactly):

```elixir
action :runtime_check, :map do
  constraints fields: [
                ok: [type: :boolean, allow_nil?: false],
                detail: [type: :string, allow_nil?: false]
              ]

  run fn _input, _ctx ->
    cat = System.find_executable("cat") || "/bin/cat"

    with {:ok, handle} <-
           Valea.Agents.ProcessRuntime.start(
             %{cmd: cat, args: [], env: %{}, cd: System.tmp_dir!()},
             self()
           ),
         :ok <- Valea.Agents.ProcessRuntime.write(handle, "ping\n") do
      receive do
        {:runtime_output, "ping\n"} ->
          Valea.Agents.ProcessRuntime.stop(handle)
          {:ok, %{"ok" => true, "detail" => "spawn/echo/kill ok"}}
      after
        3_000 ->
          Valea.Agents.ProcessRuntime.stop(handle)
          {:ok, %{"ok" => false, "detail" => "no echo within 3s"}}
      end
    else
      {:error, reason} -> {:ok, %{"ok" => false, "detail" => reason}}
    end
  end
end
```

Expose it in the rpc block of the domain the same way existing actions are exposed (see `lib/valea/api.ex`), then run `just codegen`.

- [ ] **Step 7: Prove it in the packaged app**

```bash
cd /Users/daniel/Development/valea
just package-backend
just desktop-bundle
```

Launch the built .app (path printed by the bundle step, e.g. `desktop/src-tauri/target/release/bundle/macos/*.app`) with a scratch app dir, then hit the diagnostic over the sidecar port:

```bash
VALEA_APP_DIR=$(mktemp -d) open <path-to>.app
sleep 8
curl -s -X POST http://localhost:4817/rpc/run \
  -H 'content-type: application/json' \
  -d '{"action":"runtime_check","fields":["ok","detail"],"input":{}}'
```

Expected: `{"success":true,"data":{"ok":true,"detail":"spawn/echo/kill ok"}}`. Also verify no orphan processes after quitting the app: `pgrep -f exec-port` is empty.
If this fails inside the .app but passes in dev: report BLOCKED with the exact failure — do not work around it silently.

- [ ] **Step 8: Commit**

```bash
git add backend/mix.exs backend/mix.lock backend/lib/valea/agents/process_runtime.ex backend/test/valea/agents/process_runtime_test.exs backend/lib/valea/api/workspace.ex frontend/src/lib/api/
git commit -m "feat(backend): erlexec process runtime, proven in packaged app"
```

(The `runtime_check` action stays — it becomes the doctor's spawn probe and harms nothing.)

---

### Task 2: Workspace template v2 — Layer 0/1 files, workflow pages, managed settings

**Files:**
- Create: `backend/priv/workspace_template/AGENTS.md`, `backend/priv/workspace_template/CLAUDE.md`
- Create: `backend/priv/workspace_template/icm/Workflows/New Inquiry Triage.md` (+ `Post-Session Follow-up.md`, `Session Prep Brief.md`, `Weekly Admin Review.md`)
- Create: `backend/priv/workspace_template/config/workspace.yaml`
- Delete: `backend/priv/workspace_template/workflows/` (all four YAMLs), `backend/priv/workspace_template/config/harnesses.yaml`
- Create: `backend/priv/workspace_template/queue/staging/.gitkeep`, `backend/priv/workspace_template/queue/processing/.gitkeep`
- Create: `backend/lib/valea/agents/claude_settings.ex`
- Create: `backend/test/valea/agents/claude_settings_test.exs`
- Modify: `backend/priv/workspace_template/gitignore` (append `.claude/`)
- Modify: existing template/scaffold tests that reference `workflows/` (run the suite to find them)

**Interfaces:**
- Produces: `Valea.Agents.ClaudeSettings.write!(workspace_root)` — writes `.claude/settings.json` (creates dir), idempotent. `Valea.Agents.ClaudeSettings.content()` → map (for tests).
- Produces: template layout consumed by T3 migration and all later tasks.

- [ ] **Step 1: Write AGENTS.md**

`backend/priv/workspace_template/AGENTS.md` — exactly this content:

```markdown
# Working in this folder

You are the assistant for Mara Lindt Coaching. This folder is the entire
business: every fact you may use and every piece of work you produce is a
plain file here. You need no other tools and no network access — if
something is not in a file, you do not know it.

## The map

- `icm/` — reference memory the owner curates. Read the pages a job's
  Inputs name. Do not read the whole tree.
- `icm/Workflows/` — your job contracts. Each page states its Inputs,
  Process, and Outputs.
- `sources/` — incoming material (mail, calendar, files). Read-only.
- `prompts/` — reusable prompt fragments. Read-only.
- `queue/` — where proposals wait for the owner's decision. You write
  only where the current job names an exact output path.
- `logs/`, `secrets/`, `.claude/`, `app.sqlite` — off-limits. Never read
  or write them.

## Hard rules

1. Never send anything, anywhere. You prepare; the owner approves.
2. Never delete files.
3. Never edit pages under `icm/` — suggest changes in your reply instead.
4. One proposal per workflow run, at the exact path the run names.
5. When unsure, stop and say what is missing rather than guessing.

## The proposal contract

A workflow run names one output path. Write a single JSON file there:

```json
{
  "schema": "proposal/v1",
  "kind": "email_draft",
  "title": "Reply to Priya Nair — coaching inquiry",
  "summary": "Good-fit inquiry. Drafted a warm reply proposing a discovery call.",
  "sources": [
    "sources/mail/normalized/priya-nair-inquiry.json",
    "icm/Offers/Founder Coaching Package.md"
  ],
  "proposed_action": {
    "type": "create_email_draft",
    "to": "priya@example.com",
    "subject": "Re: Question about leadership coaching",
    "body_markdown": "Hi Priya, ..."
  },
  "reasoning": "Classified good-fit because the inquiry matches the founder coaching offer."
}
```

- `sources` lists every file you actually read, workspace-relative.
- `body_markdown` is the complete draft, ready to review.
- `reasoning` is one or two plain sentences the owner will read.
```

- [ ] **Step 2: Write CLAUDE.md**

`backend/priv/workspace_template/CLAUDE.md` — exactly:

```markdown
@AGENTS.md
```

- [ ] **Step 3: Write the four workflow pages**

`backend/priv/workspace_template/icm/Workflows/New Inquiry Triage.md`:

```markdown
---
enabled: true
trigger: { type: manual, source: email.selected }
sources:
  - { id: current_email, type: email, required: true }
  - { id: founder_coaching_offer, type: icm, path: "icm/Offers/Founder Coaching Package.md" }
  - { id: tone_guide, type: icm, path: "icm/Tone & Voice/Email Tone Guide.md" }
  - { id: no_medical_advice, type: icm, path: "icm/Policies/No Medical Advice.md" }
  - { id: pricing, type: icm, path: "icm/Pricing/Current Pricing.md" }
risk_level: medium
approval:
  required: true
  reason: Email replies must be reviewed before sending.
  actions: [create_email_draft]
audit: { log_sources: true, log_inputs: true, log_outputs: true, log_agent: true }
---

# New Inquiry Triage

Classifies a new email inquiry and drafts a reply for review.

## Inputs

| Input | Where |
| --- | --- |
| The inquiry email | named by the run |
| Offer, tone, policy and pricing pages | listed under `sources` above |

## Process

1. Summarize the incoming inquiry in two sentences.
2. Classify it: good-fit, unclear, not fit, or spam.
3. Draft a warm reply using the tone guide and the relevant offer. Respect
   the no-medical-advice policy.

## Outputs

One `proposal/v1` file at the exact path the run names, with
`kind: "email_draft"`. Do not send anything.
```

`backend/priv/workspace_template/icm/Workflows/Post-Session Follow-up.md`:

```markdown
---
enabled: false
trigger: { type: manual, source: calendar.completed }
sources:
  - { id: completed_event, type: calendar, required: true }
  - { id: client_page, type: icm, path: "icm/Clients/*" }
  - { id: tone_guide, type: icm, path: "icm/Tone & Voice/Email Tone Guide.md" }
  - { id: followup_template, type: icm, path: "icm/Templates/Follow-up Email.md" }
risk_level: medium
approval:
  required: true
  reason: Email replies must be reviewed before sending.
  actions: [create_email_draft]
audit: { log_sources: true, log_inputs: true, log_outputs: true, log_agent: true }
---

# Post-Session Follow-up

Drafts a follow-up email after a completed client session. Not active yet —
calendar sources arrive in a later phase.

## Inputs

| Input | Where |
| --- | --- |
| The completed session event | named by the run |
| Client page, tone guide, template | listed under `sources` above |

## Process

1. Summarize what was discussed and any commitments made.
2. Draft a warm follow-up email using the tone guide and the client's open
   commitments.

## Outputs

One `proposal/v1` file at the exact path the run names, with
`kind: "email_draft"`. Do not send anything.
```

`backend/priv/workspace_template/icm/Workflows/Session Prep Brief.md`:

```markdown
---
enabled: false
trigger: { type: manual, source: calendar.upcoming }
sources:
  - { id: upcoming_event, type: calendar, required: true }
  - { id: client_page, type: icm, path: "icm/Clients/*" }
  - { id: brief_prompt, type: prompt, path: "prompts/session_brief_writer.md" }
risk_level: low
approval:
  required: true
  reason: Briefs are reviewed before they land on the desk.
  actions: [create_brief]
audit: { log_sources: true, log_inputs: true, log_outputs: true, log_agent: true }
---

# Session Prep Brief

Prepares a one-page brief before an upcoming client session. Not active
yet — calendar sources arrive in a later phase.

## Inputs

| Input | Where |
| --- | --- |
| The upcoming session event | named by the run |
| Client page and brief prompt | listed under `sources` above |

## Process

1. Read the client page: goals, open commitments, last session notes.
2. Write a one-page brief: where things stand, suggested focus, open loops.

## Outputs

One `proposal/v1` file at the exact path the run names. Do not send
anything.
```

`backend/priv/workspace_template/icm/Workflows/Weekly Admin Review.md`:

```markdown
---
enabled: false
trigger: { type: manual, source: schedule.weekly }
sources:
  - { id: open_queue, type: queue, required: true }
  - { id: recent_mail, type: email, path: "sources/mail/normalized/*" }
risk_level: low
approval:
  required: true
  reason: The weekly review is read by the owner before anything changes.
  actions: [create_brief]
audit: { log_sources: true, log_inputs: true, log_outputs: true, log_agent: true }
---

# Weekly Admin Review

Summarizes the week's open loops for the owner. Not active yet — scheduled
triggers arrive in a later phase.

## Inputs

| Input | Where |
| --- | --- |
| Open queue items | `queue/pending/` |
| Recent mail | `sources/mail/normalized/` |

## Process

1. List open loops: unanswered inquiries, pending approvals, overdue
   follow-ups.
2. Write a short review with one suggested next step per loop.

## Outputs

One `proposal/v1` file at the exact path the run names. Do not send
anything.
```

- [ ] **Step 4: workspace.yaml, queue dirs, deletions, gitignore**

`backend/priv/workspace_template/config/workspace.yaml`:

```yaml
version: 2
```

```bash
cd backend/priv/workspace_template
mkdir -p queue/staging queue/processing
touch queue/staging/.gitkeep queue/processing/.gitkeep
git rm -r workflows config/harnesses.yaml
printf '.claude/\n' >> gitignore
```

- [ ] **Step 5: Failing test for ClaudeSettings**

`backend/test/valea/agents/claude_settings_test.exs`:

```elixir
defmodule Valea.Agents.ClaudeSettingsTest do
  use ExUnit.Case, async: true

  alias Valea.Agents.ClaudeSettings

  setup do
    root = Path.join(System.tmp_dir!(), "vws-#{System.os_time(:nanosecond)}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "writes managed settings with deny/ask/allow contract", %{root: root} do
    :ok = ClaudeSettings.write!(root)
    settings = root |> Path.join(".claude/settings.json") |> File.read!() |> Jason.decode!()
    perms = settings["permissions"]

    assert "Read(./secrets/**)" in perms["deny"]
    assert "Read(./logs/**)" in perms["deny"]
    assert "Read(./.git/**)" in perms["deny"]
    assert "WebFetch" in perms["deny"]
    assert "WebSearch" in perms["deny"]
    assert perms["ask"] == ["Write", "Edit", "Bash"]
    assert perms["allow"] == ["Read"]
  end

  test "idempotent — second write yields identical bytes", %{root: root} do
    :ok = ClaudeSettings.write!(root)
    first = File.read!(Path.join(root, ".claude/settings.json"))
    :ok = ClaudeSettings.write!(root)
    assert File.read!(Path.join(root, ".claude/settings.json")) == first
  end
end
```

Run: `cd backend && mix test test/valea/agents/claude_settings_test.exs` — expect FAIL (module missing).

- [ ] **Step 6: Implement ClaudeSettings**

`backend/lib/valea/agents/claude_settings.ex`:

```elixir
defmodule Valea.Agents.ClaudeSettings do
  @moduledoc """
  Writes the MANAGED `.claude/settings.json` into a workspace. ACP agents
  only *may* ask permission — Claude Code auto-approves reads and anything
  its own rules allow before Valea's callback ever fires. This file forces
  writes/Bash to `ask` (so they reach the ACP permission request) and
  hard-denies the protected paths. Regenerated at every session start;
  the workspace gitignore excludes `.claude/`.
  """

  @protected ["secrets", "logs", ".claude", ".git"]
  @db_globs ["app.sqlite", "app.sqlite-wal", "app.sqlite-shm"]

  def content do
    deny =
      Enum.flat_map(@protected, fn dir ->
        ["Read(./#{dir}/**)", "Edit(./#{dir}/**)", "Write(./#{dir}/**)"]
      end) ++
        Enum.flat_map(@db_globs, fn f -> ["Read(./#{f})", "Edit(./#{f})", "Write(./#{f})"] end) ++
        ["WebFetch", "WebSearch"]

    %{
      "permissions" => %{
        "deny" => deny,
        "ask" => ["Write", "Edit", "Bash"],
        "allow" => ["Read"]
      }
    }
  end

  def write!(workspace_root) do
    dir = Path.join(workspace_root, ".claude")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "settings.json"), Jason.encode!(content(), pretty: true) <> "\n")
    :ok
  end
end
```

- [ ] **Step 7: Run tests, fix template fallout**

Run: `cd backend && mix test`
Expected: ClaudeSettings tests pass. Any Phase-1/2 tests referencing `workflows/*.yaml` or `harnesses.yaml` now fail — update them to the new reality: References tests point at `icm/Workflows/*.md` **only if that change is trivial here**; if References itself still globs `workflows/*.yaml`, leave its tests failing-listed for Task 4 is NOT acceptable — instead make the minimal edit now: in `backend/lib/valea/icm/references.ex` change the glob from `workflows/*.yaml` to `icm/Workflows/*.md` (Task 4 owns the deeper frontmatter work; this keeps the suite green). Determinism/round-trip suites that enumerate every seed page will pick up the four new workflow pages — if they fail on frontmatter, scope them to body-only pages with a clearly named exclusion list `@frontmatter_pages` and a comment `# Task 4 extends the contract to frontmatter pages` (Task 4 removes the exclusion).

Run: `cd backend && mix test` until green.

- [ ] **Step 8: Commit**

```bash
git add -A backend/priv/workspace_template backend/lib/valea/agents/claude_settings.ex backend/test/valea/agents/claude_settings_test.exs backend/lib/valea/icm/references.ex backend/test
git commit -m "feat(backend): workspace template v2 — AGENTS.md/CLAUDE.md, workflow pages in ICM, managed Claude settings"
```

---

### Task 3: Workspace migration + scaffold update + Manager hook

**Files:**
- Create: `backend/lib/valea/workspace/migration.ex`
- Create: `backend/test/valea/workspace/migration_test.exs`
- Modify: `backend/lib/valea/workspace/scaffold.ex` (required dirs: drop `workflows`, add `queue/staging`, `queue/processing`; template copy already covers new files)
- Modify: `backend/lib/valea/workspace/manager.ex` (run migration inside open/create, after mount checks, before broadcasting workspace open)

**Interfaces:**
- Consumes: `Valea.Agents.ClaudeSettings.write!/1` (T2).
- Produces: `Valea.Workspace.Migration.migrate(root)` → `{:ok, version :: integer} | {:error, String.t()}` — idempotent, never deletes user files.

- [ ] **Step 1: Failing tests**

`backend/test/valea/workspace/migration_test.exs`:

```elixir
defmodule Valea.Workspace.MigrationTest do
  use ExUnit.Case, async: true

  alias Valea.Workspace.Migration

  defp v1_workspace! do
    root = Path.join(System.tmp_dir!(), "vmig-#{System.os_time(:nanosecond)}")

    for d <- ["icm/Offers", "workflows", "queue/pending", "logs", "config", "sources/mail/normalized"] do
      File.mkdir_p!(Path.join(root, d))
    end

    File.write!(Path.join(root, "workflows/new_inquiry_triage.yaml"), """
    id: new_inquiry_triage
    name: New Inquiry Triage
    description: Classifies a new email inquiry and drafts a reply for review.
    enabled: true
    trigger:
      type: manual
      source: email.selected
    sources:
      - id: offer
        type: icm
        path: icm/Offers/Founder Coaching Package.md
    steps:
      - id: draft_reply
        instruction: Draft a warm reply.
    outputs:
      - type: approval_item
        schema: queue_item
    approval:
      required: true
      reason: Email replies must be reviewed before sending.
      actions:
        - create_email_draft
    risk_level: medium
    audit:
      log_sources: true
      log_inputs: true
      log_outputs: true
      log_agent: true
    """)

    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  test "migrates v1: layer files, converted workflow page, dirs, settings, marker" do
    root = v1_workspace!()
    assert {:ok, 2} = Migration.migrate(root)

    assert File.exists?(Path.join(root, "AGENTS.md"))
    assert File.read!(Path.join(root, "CLAUDE.md")) =~ "@AGENTS.md"
    assert File.dir?(Path.join(root, "queue/staging"))
    assert File.dir?(Path.join(root, "queue/processing"))
    assert File.exists?(Path.join(root, ".claude/settings.json"))
    assert File.read!(Path.join(root, "config/workspace.yaml")) =~ "version: 2"

    page = File.read!(Path.join(root, "icm/Workflows/New Inquiry Triage.md"))
    assert String.starts_with?(page, "---\n")
    assert page =~ "enabled: true"
    assert page =~ "icm/Offers/Founder Coaching Package.md"
    assert page =~ "# New Inquiry Triage"
    assert page =~ "Draft a warm reply."
    # the source yaml is preserved, never deleted
    assert File.exists?(Path.join(root, "workflows/new_inquiry_triage.yaml"))
  end

  test "idempotent — second run changes nothing" do
    root = v1_workspace!()
    {:ok, 2} = Migration.migrate(root)
    snapshot = snapshot(root)
    {:ok, 2} = Migration.migrate(root)
    assert snapshot(root) == snapshot
  end

  test "does not overwrite an existing converted page or existing AGENTS.md" do
    root = v1_workspace!()
    File.mkdir_p!(Path.join(root, "icm/Workflows"))
    File.write!(Path.join(root, "icm/Workflows/New Inquiry Triage.md"), "user content")
    File.write!(Path.join(root, "AGENTS.md"), "user agents")
    {:ok, 2} = Migration.migrate(root)
    assert File.read!(Path.join(root, "icm/Workflows/New Inquiry Triage.md")) == "user content"
    assert File.read!(Path.join(root, "AGENTS.md")) == "user agents"
  end

  test "fresh v2 workspace (from template) migrates to a no-op" do
    root = Path.join(System.tmp_dir!(), "vmig-#{System.os_time(:nanosecond)}")
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, _} = Valea.Workspace.Scaffold.create(root)
    snapshot = snapshot(root)
    {:ok, 2} = Migration.migrate(root)
    # settings.json is (re)written but byte-identical; everything else untouched
    assert snapshot(root) == snapshot
  end

  defp snapshot(root) do
    root
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Map.new(fn f -> {f, File.read!(f)} end)
  end
end
```

Adjust the `Scaffold.create/1` call to the real scaffold API (read `backend/lib/valea/workspace/scaffold.ex` first — if it takes `(parent, name)` or returns a different shape, mirror what existing scaffold tests do).

Run: `cd backend && mix test test/valea/workspace/migration_test.exs` — expect FAIL.

- [ ] **Step 2: Implement Migration**

`backend/lib/valea/workspace/migration.ex`:

```elixir
defmodule Valea.Workspace.Migration do
  @moduledoc """
  Idempotent, versioned workspace upgrades, run by the Manager on every
  open/create before the workspace runtime starts. Never deletes or
  overwrites user files; converted sources are left in place.
  """

  @current_version 2

  @spec migrate(String.t()) :: {:ok, integer()} | {:error, String.t()}
  def migrate(root) do
    with {:ok, _} <- ensure_v2(root, read_version(root)) do
      # Managed settings are regenerated on every open (and per session start).
      Valea.Agents.ClaudeSettings.write!(root)
      {:ok, @current_version}
    end
  rescue
    e -> {:error, "migration failed: #{Exception.message(e)}"}
  end

  defp read_version(root) do
    path = Path.join(root, "config/workspace.yaml")

    with true <- File.exists?(path),
         {:ok, %{"version" => v}} when is_integer(v) <- YamlElixir.read_from_file(path) do
      v
    else
      _ -> 1
    end
  end

  defp ensure_v2(_root, v) when v >= 2, do: {:ok, v}

  defp ensure_v2(root, _v) do
    copy_missing!(root, "AGENTS.md")
    copy_missing!(root, "CLAUDE.md")
    File.mkdir_p!(Path.join(root, "queue/staging"))
    File.mkdir_p!(Path.join(root, "queue/processing"))
    File.mkdir_p!(Path.join(root, "icm/Workflows"))
    convert_workflows!(root)
    ensure_gitignore_claude!(root)
    File.mkdir_p!(Path.join(root, "config"))
    File.write!(Path.join(root, "config/workspace.yaml"), "version: 2\n")
    {:ok, 2}
  end

  defp copy_missing!(root, rel) do
    target = Path.join(root, rel)

    unless File.exists?(target) do
      File.cp!(Path.join(template_dir(), rel), target)
    end
  end

  defp template_dir, do: Application.app_dir(:valea, "priv/workspace_template")

  defp convert_workflows!(root) do
    root
    |> Path.join("workflows/*.yaml")
    |> Path.wildcard()
    |> Enum.each(fn yaml_path ->
      case YamlElixir.read_from_file(yaml_path) do
        {:ok, wf} when is_map(wf) ->
          name = wf["name"] || Path.basename(yaml_path, ".yaml")
          target = Path.join(root, "icm/Workflows/#{name}.md")
          unless File.exists?(target), do: File.write!(target, workflow_page(wf, name))

        _ ->
          :ok
      end
    end)
  end

  defp workflow_page(wf, name) do
    frontmatter =
      %{
        "enabled" => wf["enabled"] || false,
        "trigger" => wf["trigger"] || %{},
        "sources" => wf["sources"] || [],
        "risk_level" => wf["risk_level"] || "medium",
        "approval" => wf["approval"] || %{"required" => true},
        "audit" => wf["audit"] || %{}
      }

    steps =
      (wf["steps"] || [])
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {step, i} ->
        "#{i}. #{String.trim(step["instruction"] || step["id"] || "")}"
      end)

    """
    ---
    #{frontmatter |> yaml_encode() |> String.trim_trailing()}
    ---

    # #{name}

    #{String.trim(wf["description"] || "")}

    ## Inputs

    | Input | Where |
    | --- | --- |
    | Run input | named by the run |
    | Reference pages | listed under `sources` above |

    ## Process

    #{steps}

    ## Outputs

    One `proposal/v1` file at the exact path the run names. Do not send
    anything.
    """
  end

  # Minimal YAML emitter for the known frontmatter shape (maps, lists,
  # scalars). yaml_elixir has no encoder; keep this private and dumb.
  defp yaml_encode(map) when is_map(map) do
    Enum.map_join(map, "\n", fn {k, v} -> "#{k}: #{yaml_value(v)}" end)
  end

  defp yaml_value(v) when is_map(v) do
    inner = Enum.map_join(v, ", ", fn {k, val} -> "#{k}: #{yaml_value(val)}" end)
    "{ #{inner} }"
  end

  defp yaml_value(v) when is_list(v) do
    "\n" <> Enum.map_join(v, "\n", fn item -> "  - #{yaml_value(item)}" end)
  end

  defp yaml_value(v) when is_binary(v) do
    if String.contains?(v, [":", "#", "*"]), do: ~s("#{v}"), else: v
  end

  defp yaml_value(v), do: to_string(v)

  defp ensure_gitignore_claude!(root) do
    path = Path.join(root, ".gitignore")
    current = if File.exists?(path), do: File.read!(path), else: ""

    unless String.contains?(current, ".claude/") do
      File.write!(path, current <> ".claude/\n")
    end
  end
end
```

Add `{:yaml_elixir, "~> 2.11"}` to `backend/mix.exs` deps, `mix deps.get`.
Note the list-in-flow-map YAML edge: `yaml_value` for a list nested inside a `{ }` flow map would emit broken YAML — the known frontmatter shape only nests lists at the top level (`sources`) and scalars/flat maps elsewhere (`approval.actions` is a list inside a map: handle it by emitting `approval` as a flow map with `[a, b]` list syntax). Change `yaml_value(v) when is_list(v)` used inside flow context: simplest correct fix — make `yaml_value/1` lists emit `[item1, item2]` flow style, and give ONLY the top-level `sources` key block style via a special case in `yaml_encode/1`:

```elixir
  defp yaml_encode(map) when is_map(map) do
    Enum.map_join(map, "\n", fn
      {"sources", v} when is_list(v) ->
        "sources:\n" <> Enum.map_join(v, "\n", fn item -> "  - #{yaml_value(item)}" end)

      {k, v} ->
        "#{k}: #{yaml_value(v)}"
    end)
  end

  defp yaml_value(v) when is_list(v), do: "[" <> Enum.map_join(v, ", ", &yaml_value/1) <> "]"
```

(Keep the map/scalar clauses as above.)

- [ ] **Step 3: Scaffold + Manager wiring**

In `backend/lib/valea/workspace/scaffold.ex`: update the required-directory verification list — remove `workflows`, add `queue/staging` and `queue/processing` (read the module; the list is explicit).

In `backend/lib/valea/workspace/manager.ex`: in both the open and create success paths (they converge where the workspace is validated/mounted, before the workspace-open broadcast), insert:

```elixir
case Valea.Workspace.Migration.migrate(root) do
  {:ok, _version} -> :ok
  {:error, reason} -> throw({:migration_failed, reason})
end
```

adapted to the Manager's actual error-flow style (it threads `{:error, reason}` tuples — follow the file's existing failure paths so a migration failure yields a closed-workspace state with a truthful error, exactly like a failed mount; do NOT leave the workspace half-open).

- [ ] **Step 4: Run the full backend suite**

Run: `cd backend && mix test`
Expected: migration tests pass; Manager open/switch tests still pass (they now run migrations on their tmp workspaces — fresh scaffolds are v2 no-ops).

- [ ] **Step 5: Commit**

```bash
git add backend/lib/valea/workspace backend/test/valea/workspace backend/mix.exs backend/mix.lock
git commit -m "feat(backend): versioned idempotent workspace migration wired into Manager"
```

---

### Task 4: Frontmatter passthrough — ICM read/save, references, PageMeta

**Files:**
- Modify: `backend/lib/valea/icm.ex` (frontmatter split on read + reattach on save)
- Modify: `backend/lib/valea/api/icm.ex` (`:page` action returns `frontmatter`)
- Modify: `backend/lib/valea/icm/references.ex` (confirm glob is `icm/Workflows/*.md` from T2; no other change needed — it is a literal string scan)
- Modify: `backend/test/valea/markdown/*` determinism/round-trip suites (remove the T2 `@frontmatter_pages` exclusion; add frontmatter fixtures)
- Create: `backend/test/valea/icm_frontmatter_test.exs`
- Modify: `frontend/src/lib/components/editor/PageMeta.svelte` (display frontmatter read-only)
- Modify: `frontend/src/lib/api/client.ts` (pass `frontmatter` through — do NOT camelize its keys; it is user data)

**Interfaces:**
- Produces: `Valea.ICM.split_frontmatter(binary)` → `{frontmatter_block :: binary, body :: binary}` where `frontmatter_block` is `""` or the exact bytes `"---\n...\n---\n"` (delimiters included, trailing newline included).
- `Valea.ICM.page/1` result map gains `frontmatter: map() | nil` (parsed via YamlElixir; parse failure → `nil` — the raw view still shows everything).
- `content` stays the WHOLE file (raw view truth); `prosemirror` is converted from the BODY only; `hash` stays whole-file bytes.
- `save_page/3` writes `frontmatter_block <> serialized_body` after the hash guard passes, splitting the frontmatter from the CURRENT file at write time.

- [ ] **Step 1: Failing tests**

`backend/test/valea/icm_frontmatter_test.exs` — follow the setup pattern of the existing `backend/test/valea/icm_test.exs` (tmp workspace via scaffold or fixture builder; read that file first and reuse its helpers):

```elixir
defmodule Valea.ICMFrontmatterTest do
  use ExUnit.Case, async: false
  # reuse the workspace setup helper used by test/valea/icm_test.exs

  @page_with_fm """
  ---
  enabled: true
  risk_level: medium
  ---

  # Contract

  Body paragraph.
  """

  describe "split_frontmatter/1" do
    test "splits block including delimiters and trailing newline" do
      {block, body} = Valea.ICM.split_frontmatter(@page_with_fm)
      assert block == "---\nenabled: true\nrisk_level: medium\n---\n"
      assert body == "\n# Contract\n\nBody paragraph.\n"
    end

    test "no frontmatter -> empty block, unchanged body" do
      assert {"", "# T\n"} = Valea.ICM.split_frontmatter("# T\n")
    end

    test "unterminated frontmatter is treated as body" do
      assert {"", "---\nbroken"} = Valea.ICM.split_frontmatter("---\nbroken")
    end
  end

  describe "page/1 + save_page/3 with frontmatter" do
    # setup writes @page_with_fm to icm/Workflows/Contract.md in the tmp workspace

    test "page returns parsed frontmatter, whole-file content, body-only prosemirror" do
      {:ok, page} = Valea.ICM.page("Workflows/Contract.md")
      assert page.frontmatter == %{"enabled" => true, "risk_level" => "medium"}
      assert String.starts_with?(page.content, "---\n")
      refute inspect(page.prosemirror) =~ "enabled: true"
    end

    test "save without edits reattaches frontmatter byte-identically (round trip)" do
      {:ok, page} = Valea.ICM.page("Workflows/Contract.md")
      {:ok, _} = Valea.ICM.save_page("Workflows/Contract.md", page.prosemirror, page.hash)
      # canonical body may differ from the fixture's blank-line formatting,
      # but the frontmatter block must be byte-identical and the round trip
      # must be stable: a second open+save writes nothing new.
      {:ok, page2} = Valea.ICM.page("Workflows/Contract.md")
      assert String.starts_with?(page2.content, "---\nenabled: true\nrisk_level: medium\n---\n")
      {:ok, _} = Valea.ICM.save_page("Workflows/Contract.md", page2.prosemirror, page2.hash)
      {:ok, page3} = Valea.ICM.page("Workflows/Contract.md")
      assert page3.content == page2.content
    end

    test "malformed yaml -> frontmatter nil, page still readable" do
      # setup writes "---\n{ broken\n---\n\n# X\n"
      {:ok, page} = Valea.ICM.page("Workflows/Broken.md")
      assert page.frontmatter == nil
      assert page.title
    end
  end
end
```

Also extend the seed round-trip determinism suite: every seed page under `icm/Workflows/` must satisfy `frontmatter_block <> to_markdown(from_markdown(body)) == file_bytes` — i.e. the four template pages' BODIES must already be canonical (one line per block, no trailing newline beyond the final one... note: the existing canonical form is NO trailing newline; the template pages in T2 end with `\n` from the heredoc — the determinism test will catch this; fix the template files to the canonical no-trailing-newline form as part of THIS task if the suite demands it, matching how the 13 Phase-1 seed pages were canonicalized).

Run: `cd backend && mix test test/valea/icm_frontmatter_test.exs` — expect FAIL.

- [ ] **Step 2: Implement in `backend/lib/valea/icm.ex`**

Add:

```elixir
@doc """
Splits an optional leading frontmatter block. Returns
`{block_including_delimiters, body}`; `{"", input}` when absent or
unterminated. The block always ends with the closing `---\n`.
"""
def split_frontmatter("---\n" <> rest = input) do
  case String.split(rest, "\n---\n", parts: 2) do
    [yaml, body] -> {"---\n" <> yaml <> "\n---\n", body}
    _ -> {"", input}
  end
end

def split_frontmatter(input), do: {"", input}

defp parse_frontmatter(""), do: nil

defp parse_frontmatter(block) do
  yaml = block |> String.trim_leading("---\n") |> String.trim_trailing("---\n")

  case YamlElixir.read_from_string(yaml) do
    {:ok, map} when is_map(map) -> map
    _ -> nil
  end
end
```

In `page/1`: after reading the file bytes, `{block, body} = split_frontmatter(content)`; convert `body` (not `content`) to ProseMirror; add `frontmatter: parse_frontmatter(block)` to the returned map (keep `content` = whole file).

In `save_page/3`: after the hash guard passes against the whole current file bytes, `{block, _old_body} = split_frontmatter(current_bytes)`; write `block <> serialized_body` via the existing atomic write.

In `backend/lib/valea/api/icm.ex` `:page` action: the returned map already stringifies keys — `frontmatter` rides along. Add a note in the action's comment: frontmatter keys are user data and are delivered raw (the unconstrained-map casing caveat works FOR us here).

- [ ] **Step 3: Run backend suite; canonicalize template workflow pages if the determinism test demands**

Run: `cd backend && mix test`
Fix template page endings as needed (Step 1 note). Remove the T2 `@frontmatter_pages` exclusion from the round-trip suite. Green before moving on.

- [ ] **Step 4: PageMeta display + client passthrough**

`frontend/src/lib/components/editor/PageMeta.svelte`: read the component first. Add, when the page has frontmatter, a read-only block above the ownership card: a `SectionOverline` "Contract" followed by rows label/value (label column `#948A75`, value 600 ink — design system §8 structured facts). Render only scalar/flat values: `enabled`, `risk_level`, `trigger.source`, and `sources` as a count ("5 sources"). No editing affordance.

`frontend/src/lib/api/client.ts`: locate the `icmPage` normalizer (Phase-1 dual-casing normalization) — ensure the `frontmatter` field is passed through UNTOUCHED (no key camelization; add a one-line comment saying why). Extend the page type it returns with `frontmatter: Record<string, unknown> | null`.

Run: `cd frontend && bun run check && bun run test`
Expected: 0 errors; vitest green.

- [ ] **Step 5: Commit**

```bash
git add backend/lib/valea backend/test backend/priv/workspace_template frontend/src/lib
git commit -m "feat: frontmatter passthrough — byte-identical reattach, read-only display"
```

---

### Task 5: Workspace.Runtime supervisor, generations, Valea.Audit

**Files:**
- Create: `backend/lib/valea/workspace/runtime.ex`
- Create: `backend/lib/valea/audit.ex`
- Create: `backend/test/valea/workspace/runtime_test.exs`, `backend/test/valea/audit_test.exs`
- Modify: `backend/lib/valea/workspace/manager.ex` (start/stop Runtime, generation counter, expose `generation/0` and include generation in `current/0` + workspace broadcasts)
- Modify: `backend/lib/valea/workspace/supervisor.ex` (add a `DynamicSupervisor` slot for the Runtime — read the module; it currently supervises Manager + Repo machinery)
- Modify: `backend/lib/valea/icm/watcher.ex` (started under Runtime, not wherever Phase 1 put it; verify via `grep -rn "Watcher" backend/lib`)
- Modify: `backend/lib/valea/api/error.ex` (+ `workspace_changed`)

**Interfaces:**
- Produces: `Valea.Workspace.Runtime.start_link(%{root: String.t(), generation: integer()})` — Supervisor with children: `Valea.ICM.Watcher`, `Valea.Audit`, `{DynamicSupervisor, name: Valea.Agents.SessionSupervisor}` (sessions arrive T9), and (T13) `Valea.Queue` recovery hook.
- `Valea.Workspace.Manager.generation/0` → `integer | nil` (nil when closed). Generation increments on every successful open/create.
- `Valea.Audit.append(type :: String.t(), fields :: map())` → `:ok` — serialized writes to `{root}/logs/audit.jsonl`, each line `%{"ts" => ISO8601, "type" => type, "generation" => g} |> Map.merge(fields)`.
- `Valea.Audit.entries(limit)` → `{:ok, [map()]}` newest-first.
- Guard helper for RPC actions: `Valea.Workspace.Manager.check_generation(g)` → `:ok | {:error, :workspace_changed}`.

- [ ] **Step 1: Failing tests**

`backend/test/valea/audit_test.exs`:

```elixir
defmodule Valea.AuditTest do
  use ExUnit.Case, async: false

  setup do
    root = Path.join(System.tmp_dir!(), "vaud-#{System.os_time(:nanosecond)}")
    File.mkdir_p!(Path.join(root, "logs"))
    on_exit(fn -> File.rm_rf!(root) end)
    start_supervised!({Valea.Audit, %{root: root, generation: 7}})
    %{root: root}
  end

  test "appends jsonl with ts, type, generation; entries newest-first", %{root: root} do
    :ok = Valea.Audit.append("workflow_run_started", %{"run_id" => "r1"})
    :ok = Valea.Audit.append("queue_item_created", %{"run_id" => "r1"})

    lines = root |> Path.join("logs/audit.jsonl") |> File.read!() |> String.split("\n", trim: true)
    assert length(lines) == 2
    first = Jason.decode!(hd(lines))
    assert first["type"] == "workflow_run_started"
    assert first["generation"] == 7
    assert first["ts"] =~ "T"

    {:ok, entries} = Valea.Audit.entries(10)
    assert [%{"type" => "queue_item_created"}, %{"type" => "workflow_run_started"}] =
             Enum.map(entries, &Map.take(&1, ["type"]))
  end
end
```

`backend/test/valea/workspace/runtime_test.exs`:

```elixir
defmodule Valea.Workspace.RuntimeTest do
  use ExUnit.Case, async: false

  test "runtime supervises watcher + audit + session supervisor and dies as a unit" do
    root = Path.join(System.tmp_dir!(), "vrt-#{System.os_time(:nanosecond)}")
    File.mkdir_p!(Path.join(root, "icm"))
    File.mkdir_p!(Path.join(root, "logs"))
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, sup} = Valea.Workspace.Runtime.start_link(%{root: root, generation: 1})
    assert Process.whereis(Valea.ICM.Watcher)
    assert Process.whereis(Valea.Audit)
    assert Process.whereis(Valea.Agents.SessionSupervisor)

    :ok = Supervisor.stop(sup)
    refute Process.whereis(Valea.ICM.Watcher)
    refute Process.whereis(Valea.Audit)
    refute Process.whereis(Valea.Agents.SessionSupervisor)
  end
end
```

Manager generation tests go into the EXISTING manager test file (read it; follow its workspace fixtures):

```elixir
test "generation increments per open and is nil when closed" ... 
test "check_generation returns workspace_changed for a stale generation" ...
test "switching workspaces stops the previous runtime processes" do
  # open ws A -> capture watcher pid; open ws B -> old pid is dead, new pid alive
end
```

Run: `cd backend && mix test test/valea/audit_test.exs test/valea/workspace/runtime_test.exs` — expect FAIL.

- [ ] **Step 2: Implement**

`backend/lib/valea/audit.ex`:

```elixir
defmodule Valea.Audit do
  @moduledoc """
  Append-only audit trail at {root}/logs/audit.jsonl. One GenServer
  serializes writes; failures are logged loudly but never crash callers —
  file moves are the source of truth, audit is the trail (spec §Queue).
  """
  use GenServer
  require Logger

  def start_link(cfg), do: GenServer.start_link(__MODULE__, cfg, name: __MODULE__)

  def append(type, fields \\ %{}) do
    GenServer.cast(__MODULE__, {:append, type, fields})
  end

  def entries(limit) do
    GenServer.call(__MODULE__, {:entries, limit})
  end

  @impl true
  def init(%{root: root, generation: gen}) do
    path = Path.join(root, "logs/audit.jsonl")
    File.mkdir_p!(Path.dirname(path))
    {:ok, %{path: path, generation: gen}}
  end

  @impl true
  def handle_cast({:append, type, fields}, state) do
    entry =
      %{
        "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "type" => type,
        "generation" => state.generation
      }
      |> Map.merge(fields)

    case File.write(state.path, Jason.encode!(entry) <> "\n", [:append]) do
      :ok -> :ok
      {:error, reason} -> Logger.error("audit append failed: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_call({:entries, limit}, _from, state) do
    entries =
      case File.read(state.path) do
        {:ok, data} ->
          data
          |> String.split("\n", trim: true)
          |> Enum.reverse()
          |> Enum.take(limit)
          |> Enum.flat_map(fn line ->
            case Jason.decode(line) do
              {:ok, map} -> [map]
              _ -> []
            end
          end)

        _ ->
          []
      end

    {:reply, {:ok, entries}, state}
  end
end
```

`backend/lib/valea/workspace/runtime.ex`:

```elixir
defmodule Valea.Workspace.Runtime do
  @moduledoc """
  Everything that lives and dies with an open workspace: file watcher,
  audit writer, agent sessions. Started by the Manager after a successful
  open+migration; fully stopped BEFORE a switch completes, so no process
  of the old workspace can touch the new one. Each start carries the
  workspace generation.
  """
  use Supervisor

  def start_link(cfg), do: Supervisor.start_link(__MODULE__, cfg, name: __MODULE__)

  @impl true
  def init(%{root: root, generation: gen}) do
    children = [
      {Valea.ICM.Watcher, Path.join(root, "icm")},
      {Valea.Audit, %{root: root, generation: gen}},
      {DynamicSupervisor, name: Valea.Agents.SessionSupervisor, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
```

(`Valea.ICM.Watcher.start_link/1` already exists with `name: __MODULE__` — confirm its child_spec accepts the path argument; add `def child_spec(path)` if needed. T13 widens the watcher to queue dirs.)

Manager changes (`backend/lib/valea/workspace/manager.ex`):
- State gains `generation: 0`.
- Successful open/create: after migration, `generation = state.generation + 1`; start Runtime via the workspace supervisor (`DynamicSupervisor.start_child` or a dedicated slot — mirror how the Repo is dynamically started in this codebase, see `Valea.Workspace.Supervisor`); store the runtime pid.
- Close/switch: `Supervisor.stop(runtime_pid)` (if alive) BEFORE unmounting the old workspace / starting the new one. Handle already-dead pids.
- Public: `def generation, do: GenServer.call(__MODULE__, :generation)` returning current generation or nil when closed; `current/0` payload gains `"generation"`.
- `def check_generation(g)`: `:ok` when `g == current generation`, else `{:error, :workspace_changed}`.
- Remove the watcher from wherever Phase 1 started it (it now lives under Runtime) — `grep -rn "ICM.Watcher" backend/lib` and clean up.

`backend/lib/valea/api/error.ex`: add `workspace_changed` to the error vocabulary following the file's existing pattern.

Workspace broadcasts (`grep -rn "workspace:events" backend/lib`): include `generation` in the workspace payload pushed to the channel, and in the `getWorkspace` RPC return (unconstrained Phase-1 map — it rides along).

- [ ] **Step 3: Run the full backend suite**

Run: `cd backend && mix test`
Expected: green, including Phase-1 manager/watcher tests (they may need the runtime-start expectations updated — keep their INTENT: truthful closed state on failures).

- [ ] **Step 4: Frontend generation plumbing (small)**

`frontend/src/lib/stores/workspace.svelte.ts`: store `generation: number | null` from the workspace payload (RPC + channel event both carry it now). Read the store first; follow its patterns. Add a vitest case in the existing `workspace.test.ts`: generation is captured from load and updated on workspace event.

Run: `cd frontend && bun run test && bun run check`

- [ ] **Step 5: Commit**

```bash
git add backend frontend/src/lib/stores
git commit -m "feat: workspace runtime supervisor, generations, audit writer"
```

---

### Task 6: Control-plane authentication (token, nonce, CSP)

**Files:**
- Create: `backend/lib/valea_web/plugs/control_token.ex`
- Create: `backend/test/valea_web/control_token_test.exs`
- Modify: `backend/lib/valea_web/channels/user_socket.ex` (token check in `connect/3`)
- Modify: `backend/lib/valea_web/router.ex` (plug into `/rpc` pipeline)
- Modify: `backend/lib/valea_web/controllers/health_controller.ex` (echo readiness nonce)
- Modify: the SPA-serving controller `backend/lib/valea_web/controllers/spa_controller.ex` (CSP header)
- Modify: `backend/config/runtime.exs` (read `VALEA_CONTROL_TOKEN`, `VALEA_READY_NONCE`; dev default)
- Modify: `desktop/src-tauri/src/` (generate token+nonce, env to sidecar, init script, nonce check)
- Modify: `frontend/src/lib/socket.ts` + `frontend/src/lib/api/client.ts` (send token)
- Modify: `Justfile` (dev env)

**Interfaces:**
- Produces: token resolution `ValeaWeb.ControlToken.expected/0` → `String.t()` (from app env, set in runtime.exs; dev/test default `"valea-dev-token"` ONLY when `config_env() in [:dev, :test]`; in prod a missing `VALEA_CONTROL_TOKEN` makes boot fail with a clear message).
- Frontend token resolution (exported from `socket.ts`): `controlToken()` → `window.__VALEA_CONTROL_TOKEN ?? import.meta.env.VITE_VALEA_CONTROL_TOKEN ?? 'valea-dev-token'`.
- HTTP: header `x-valea-token`; socket: connect param `token`.
- `/api/health` returns `{"status":"ok","nonce":<VALEA_READY_NONCE or null>}`.

- [ ] **Step 1: Failing tests**

`backend/test/valea_web/control_token_test.exs` (use the project's existing `ConnCase`-equivalent; read an existing controller test for the pattern):

```elixir
defmodule ValeaWeb.ControlTokenTest do
  use ValeaWeb.ConnCase, async: false

  test "rpc without token is rejected 401", %{conn: conn} do
    conn = post(conn, "/rpc/run", %{"action" => "get_workspace", "fields" => [], "input" => %{}})
    assert conn.status == 401
  end

  test "rpc with the token passes the plug", %{conn: conn} do
    conn =
      conn
      |> put_req_header("x-valea-token", "valea-dev-token")
      |> post("/rpc/run", %{"action" => "get_workspace", "fields" => [], "input" => %{}})

    assert conn.status == 200
  end

  test "health echoes the readiness nonce and needs no token", %{conn: conn} do
    conn = get(conn, "/api/health")
    assert %{"status" => "ok"} = json_response(conn, 200)
  end

  test "socket connect without token is rejected" do
    assert :error = Phoenix.ChannelTest.__connect__(ValeaWeb.UserSocket, %{}, %{})
  end
end
```

(If the socket assertion helper differs in this Phoenix version, use `Phoenix.ChannelTest.connect(ValeaWeb.UserSocket, %{})` with `use ValeaWeb.ChannelCase` and assert `:error`; a `%{"token" => "valea-dev-token"}` connect must return `{:ok, _}`. Existing channel tests connect without params — update them all to pass the dev token.)

Run: `cd backend && mix test test/valea_web/control_token_test.exs` — expect FAIL.

- [ ] **Step 2: Implement backend side**

`backend/lib/valea_web/plugs/control_token.ex`:

```elixir
defmodule ValeaWeb.Plugs.ControlToken do
  @moduledoc """
  Per-launch loopback control token. The desktop shell generates it and
  hands it to both the sidecar (env) and the SPA (init script); browsers
  on malicious origins can neither read it nor forge the header cross-
  origin. Requests without it get a 401 and no detail.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    expected = ValeaWeb.ControlToken.expected()

    case get_req_header(conn, "x-valea-token") do
      [token] when is_binary(token) ->
        if Plug.Crypto.secure_compare(token, expected) do
          conn
        else
          halt_401(conn)
        end

      _ ->
        halt_401(conn)
    end
  end

  defp halt_401(conn) do
    conn |> send_resp(401, ~s({"error":"unauthorized"})) |> halt()
  end
end

defmodule ValeaWeb.ControlToken do
  def expected, do: Application.fetch_env!(:valea, :control_token)
  def ready_nonce, do: Application.get_env(:valea, :ready_nonce)
end
```

`backend/config/runtime.exs`:

```elixir
control_token =
  System.get_env("VALEA_CONTROL_TOKEN") ||
    if config_env() == :prod do
      raise "VALEA_CONTROL_TOKEN must be set in production"
    else
      "valea-dev-token"
    end

config :valea, control_token: control_token, ready_nonce: System.get_env("VALEA_READY_NONCE")
```

Router: `plug ValeaWeb.Plugs.ControlToken` inside the `:api` pipeline used by `/rpc` (create a separate `:rpc` pipeline so `/api/health` stays token-free).

`user_socket.ex`:

```elixir
@impl true
def connect(%{"token" => token}, socket, _connect_info) do
  if Plug.Crypto.secure_compare(token, ValeaWeb.ControlToken.expected()),
    do: {:ok, socket},
    else: :error
end

def connect(_params, _socket, _connect_info), do: :error
```

Health controller: include `nonce: ValeaWeb.ControlToken.ready_nonce()` in the JSON.

SPA controller: add headers on the index response:

```elixir
conn
|> put_resp_header(
  "content-security-policy",
  "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; " <>
    "connect-src 'self' ws://localhost:* http://localhost:*; img-src 'self' data:; font-src 'self'"
)
```

(`style-src 'unsafe-inline'` is required by Svelte transitions/inline styles; fonts/scripts are bundled — `'self'` suffices per the file-first/no-CDN posture.)

- [ ] **Step 3: Frontend token**

`frontend/src/lib/socket.ts`:

```typescript
declare global {
  interface Window {
    __VALEA_CONTROL_TOKEN?: string;
  }
}

export function controlToken(): string {
  return (
    (typeof window !== 'undefined' && window.__VALEA_CONTROL_TOKEN) ||
    import.meta.env.VITE_VALEA_CONTROL_TOKEN ||
    'valea-dev-token'
  );
}
```

Pass `{ params: { token: controlToken() } }` to the `Socket` constructor. In `client.ts`, add the `x-valea-token: controlToken()` header to the HTTP fetch path (find the fetch wrapper the generated client uses — ash_typescript accepts custom fetch options/headers via its config; read `frontend/src/lib/api/client.ts` and the generated `ash_rpc.ts` header handling, and set it where the existing content-type header is set).

`Justfile` dev recipe: export `VITE_VALEA_CONTROL_TOKEN=valea-dev-token` (matching the backend dev default) so browser dev keeps working.

- [ ] **Step 4: Desktop wiring**

In `desktop/src-tauri/src/` (read `main.rs`/`lib.rs` first — the sidecar spawn and window creation both exist from Phase 1):

1. Before spawning the sidecar: generate two random hex strings (32 bytes each) using `getrandom`/`rand` (add the crate if absent):

```rust
fn random_hex() -> String {
    let mut b = [0u8; 32];
    getrandom::getrandom(&mut b).expect("rng");
    b.iter().map(|x| format!("{:02x}", x)).collect()
}
let token = random_hex();
let nonce = random_hex();
```

2. Pass both as env to the sidecar command: `VALEA_CONTROL_TOKEN`, `VALEA_READY_NONCE`.
3. Add an initialization script to the window builder:

```rust
.initialization_script(&format!("window.__VALEA_CONTROL_TOKEN = \"{token}\";"))
```

4. Readiness: where Phase 1 waits for the sidecar port, fetch `http://localhost:4817/api/health` and verify `nonce` equals the generated one; a mismatch means another process owns the port — fail with a user-readable error dialog instead of loading the SPA.

Build check: `cd desktop && cargo build --manifest-path src-tauri/Cargo.toml` (or `just desktop-bundle` if that is the established path).

- [ ] **Step 5: Run everything**

Run: `cd backend && mix test && cd ../frontend && bun run check && bun run test`
Expected: green (existing channel/controller tests updated for the token).

- [ ] **Step 6: Commit**

```bash
git add backend desktop frontend Justfile
git commit -m "feat: per-launch control token, nonce readiness, CSP on the served SPA"
```

---

### Task 7: Harness seam — CommandSpec, behaviour, ClaudeCode, minimal env, app config

**Files:**
- Create: `backend/lib/valea/agents/command_spec.ex`, `backend/lib/valea/harness.ex`, `backend/lib/valea/harnesses/claude_code.ex`, `backend/lib/valea/agents/env.ex`
- Create: `backend/test/valea/harnesses/claude_code_test.exs`, `backend/test/valea/agents/env_test.exs`
- Modify: `backend/lib/valea/app/config.ex` (harness command storage + consent flag)

**Interfaces:**
- Produces: `%Valea.Agents.CommandSpec{cmd: String.t(), args: [String.t()], env: %{String.t() => String.t()}}` — `cmd` MUST be absolute by the time it reaches ProcessRuntime.
- `Valea.Harness` behaviour: `definition() :: %{id: String.t(), name: String.t()}`, `acp_command(opts :: %{optional(:env) => map()}) :: {:ok, CommandSpec.t()} | {:error, :harness_unavailable}`.
- `Valea.Harnesses.ClaudeCode.acp_command/1` — resolves the executable: `Valea.App.Config.harness_command()` (list of strings, default `["claude-agent-acp"]`); head resolved via `System.find_executable/1` when not absolute; missing → `{:error, :harness_unavailable}`.
- `Valea.Agents.Env.minimal/0` → map with ONLY: `HOME`, `PATH`, `USER`, `LOGNAME`, `LANG`, `LC_ALL`, `LC_CTYPE`, `TMPDIR`, `SHELL`, `ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN` — each included only if set in the backend's env.
- `Valea.App.Config`: `harness_command/0`, `set_harness_command/1` (persists; sets `harness_command_approved: false` when changed from default — the UI consent flow flips it; default command is implicitly approved).

**Steps:** (same TDD rhythm)

- [ ] **Step 1:** Write failing tests:

```elixir
# backend/test/valea/agents/env_test.exs
defmodule Valea.Agents.EnvTest do
  use ExUnit.Case, async: true

  test "minimal env contains only the allowlist and never secrets" do
    System.put_env("SECRET_KEY_BASE", "supersecret")
    env = Valea.Agents.Env.minimal()
    refute Map.has_key?(env, "SECRET_KEY_BASE")
    assert env["HOME"] == System.get_env("HOME")
    assert env["PATH"] == System.get_env("PATH")
    assert Enum.all?(Map.keys(env), &(&1 in Valea.Agents.Env.allowlist()))
  end
end
```

```elixir
# backend/test/valea/harnesses/claude_code_test.exs
defmodule Valea.Harnesses.ClaudeCodeTest do
  use ExUnit.Case, async: false

  alias Valea.Harnesses.ClaudeCode

  test "definition names the harness" do
    assert %{id: "claude_code", name: "Claude Code"} = ClaudeCode.definition()
  end

  test "resolves a configured absolute command as-is" do
    cat = System.find_executable("cat")
    Valea.App.Config.set_harness_command([cat, "--extra"])

    assert {:ok, spec} = ClaudeCode.acp_command(%{env: %{"HOME" => "/tmp"}})
    assert spec.cmd == cat
    assert spec.args == ["--extra"]
    assert spec.env["HOME"] == "/tmp"
  after
    Valea.App.Config.set_harness_command(["claude-agent-acp"])
  end

  test "missing executable -> harness_unavailable" do
    Valea.App.Config.set_harness_command(["definitely-not-a-real-binary-xyz"])
    assert {:error, :harness_unavailable} = ClaudeCode.acp_command(%{})
  after
    Valea.App.Config.set_harness_command(["claude-agent-acp"])
  end
end
```

(App.Config tests use the `VALEA_APP_DIR` tmp-dir pattern from the existing `backend/test/valea/app/config_test.exs` — read it and reuse its setup so these tests do not touch the real app dir.)

- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement:

```elixir
# backend/lib/valea/agents/command_spec.ex
defmodule Valea.Agents.CommandSpec do
  @moduledoc "How to spawn an agent adapter: absolute cmd + argv, no shell."
  @enforce_keys [:cmd]
  defstruct cmd: nil, args: [], env: %{}

  @type t :: %__MODULE__{cmd: String.t(), args: [String.t()], env: map()}
end

# backend/lib/valea/harness.ex
defmodule Valea.Harness do
  @moduledoc """
  The harness seam (spec §Harness seam): a harness only describes how to
  spawn its ACP adapter subprocess. Everything else — protocol, permissions,
  transcripts, queue — is generic. Adding an agent is ~10 lines.
  """
  alias Valea.Agents.CommandSpec

  @callback definition() :: %{id: String.t(), name: String.t()}
  @callback acp_command(opts :: map()) :: {:ok, CommandSpec.t()} | {:error, :harness_unavailable}
end

# backend/lib/valea/agents/env.ex
defmodule Valea.Agents.Env do
  @allowlist ~w(HOME PATH USER LOGNAME LANG LC_ALL LC_CTYPE TMPDIR SHELL ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN)

  def allowlist, do: @allowlist

  def minimal do
    for key <- @allowlist, value = System.get_env(key), value != nil, into: %{} do
      {key, value}
    end
  end
end

# backend/lib/valea/harnesses/claude_code.ex
defmodule Valea.Harnesses.ClaudeCode do
  @moduledoc """
  Claude Code over the @agentclientprotocol/claude-agent-acp adapter.
  The executable comes from TRUSTED app config (never workspace files —
  spec §harnesses.yaml removed).
  """
  @behaviour Valea.Harness

  alias Valea.Agents.CommandSpec

  @impl true
  def definition, do: %{id: "claude_code", name: "Claude Code"}

  @impl true
  def acp_command(opts \\ %{}) do
    [cmd | args] = Valea.App.Config.harness_command()

    resolved = if String.starts_with?(cmd, "/"), do: cmd, else: System.find_executable(cmd)

    case resolved do
      nil ->
        {:error, :harness_unavailable}

      abs ->
        if File.exists?(abs),
          do: {:ok, %CommandSpec{cmd: abs, args: args, env: opts[:env] || %{}}},
          else: {:error, :harness_unavailable}
    end
  end
end
```

`Valea.App.Config` additions (follow the module's existing JSON get/put style): key `"harness_command"` (default `["claude-agent-acp"]`), key `"harness_command_approved"` (default `true` for the default command; `set_harness_command/1` sets it `false` whenever the new value differs from the default).

- [ ] **Step 4:** `cd backend && mix test` → green. **Step 5:** Commit:

```bash
git add backend/lib/valea backend/test/valea
git commit -m "feat(backend): harness seam — command spec, minimal env, app-config executable"
```

---

### Task 8: ACP codec — vendor legend's Connection, update to current protocol

The single hardest module. Vendor deliberately, then modify. The donor is
`/Users/daniel/Development/legend/backend/lib/legend/core/acp/connection.ex`
(572 lines, PURE — no IO, no processes). Its tests (if present under
`/Users/daniel/Development/legend/backend/test/` — search for
`connection_test`) are also worth reading for shapes.

**Files:**
- Create: `backend/lib/valea/acp/connection.ex` (vendored + modified, origin header)
- Create: `backend/test/valea/acp/connection_test.exs`

**Interfaces (what T9/T10 consume — preserve these exactly):**
- `Connection.new(launch)` → `{state, frames}` where `launch = %{cwd: String.t(), mode: :new | :resume | :load, conversation_id: String.t() | nil, known_message_ids: MapSet.t(), client_version: String.t()}` and `frames` is a list of iodata NDJSON frames to write to stdin.
- `Connection.handle_bytes(state, binary)` → `{state, items, frames, effects}` — items are render-item maps (`%{"id" => ..., "type" => ...}`), frames go to stdin, effects are tagged tuples: `{:session_ready}`, `{:conversation_id, String.t()}`, `{:turn, stop_reason :: String.t()}`, `{:handshake_failed, String.t()}`, `{:permission_requested, item}`.
- `Connection.prompt(state, content)` → `{state, items, frames}`; `Connection.cancel(state)` → `{state, frames}`; `Connection.answer_permission(state, perm_item_id, kind)` → `{state, items, frames}` (kind ∈ `"allow_once" | "reject_once"`; resolves the option id FROM the stored request's options); `Connection.set_config_option(state, config_id, value)` → `{state, frames}`; `Connection.turn_in_flight?(state)` → boolean.
- Render item types produced: `message` (role user/assistant, accumulating `text`), `thought`, `tool` (merge by toolCallId: `title`, `kind`, `status`, `diff`, `output` capped 64 KiB tail-kept), `plan`, `permission` (`options: [%{"optionId" =>, "name" =>, "kind" =>}]`, `resolved` bool, `outcome`), `config` (one per configId: `%{"id" => "config-" <> configId, "name" =>, "current" =>, "options" =>}`), `commands`, `usage` (`%{"id" => "usage", "type" => "usage", ...latest usage fields}`), `session_info` (`%{"id" => "session_info", "title" => ...}`), `turn` (`%{"id" => "turn-" <> n, "stop_reason" =>}`).

- [ ] **Step 1: Vendor**

```bash
cp /Users/daniel/Development/legend/backend/lib/legend/core/acp/connection.ex backend/lib/valea/acp/connection.ex
```

Rename module to `Valea.Acp.Connection`; add the origin header comment:

```elixir
# Vendored from legend backend/lib/legend/core/acp/connection.ex (2026-07-10)
# and updated to current ACP (v1 + session config options, resume, clientInfo,
# cancellation outcomes). Pure codec: no IO, no processes — the SessionServer
# owns both.
```

Strip legend-specific pieces: MCP tunnel/server params (`mcpServers` becomes the literal `[]` — file-first principle), any `Legend.` aliases, PTY/terminal references.

- [ ] **Step 2: Apply the protocol updates (each with the code below)**

1. **initialize** — params become:

```elixir
%{
  "protocolVersion" => 1,
  "clientInfo" => %{"name" => "valea", "version" => launch.client_version},
  "clientCapabilities" => %{}
}
```

2. **initialize response** — validate the negotiated version and store session capabilities:

```elixir
defp handle_response(state, :initialize, result) do
  negotiated = result["protocolVersion"]

  if negotiated != 1 do
    {state, [], [], [{:handshake_failed, "protocol version mismatch: #{inspect(negotiated)}"}]}
  else
    caps = %{
      load?: get_in(result, ["agentCapabilities", "loadSession"]) == true,
      resume?: get_in(result, ["agentCapabilities", "sessionCapabilities", "resume"]) == true ||
               get_in(result, ["sessionCapabilities", "resume"]) == true
    }

    {frames, tag} = open_session_frames(state, caps)
    # register pending request under `tag`, return frames
    ...
  end
end

defp open_session_frames(%{launch: launch} = state, caps) do
  base = %{"cwd" => launch.cwd, "mcpServers" => []}

  cond do
    launch.mode in [:resume, :load] and launch.conversation_id && caps.resume? ->
      {request(state, "session/resume", Map.put(base, "sessionId", launch.conversation_id)), :session_resume}

    launch.mode in [:resume, :load] and launch.conversation_id && caps.load? ->
      {request(state, "session/load", Map.put(base, "sessionId", launch.conversation_id)), :session_load}

    true ->
      {request(state, "session/new", base), :session_new}
  end
end
```

(`request/3` is legend's id-allocating frame builder — keep it.) `session_resume` response handling mirrors `session_load` (no replay) — emit `{:session_ready}`, keep the launch conversation id.

3. **load replay dedup** — in the user/agent message-chunk reducers, when the chunk carries a `"messageId"` already in `launch.known_message_ids`, skip it (return `{state, nil}`); when it carries a new messageId, record it in state so intra-replay duplicates also collapse.

4. **config options** — add reducers alongside legend's mode/model ones:

```elixir
defp reduce_update(state, %{"sessionUpdate" => "config_option_update"} = u, _turn) do
  option = u["configOption"] || u
  id = "config-" <> to_string(option["configId"] || option["id"])

  item = %{
    "id" => id,
    "type" => "config",
    "name" => option["name"],
    "category" => option["category"],
    "current" => option["value"] || option["currentValue"],
    "options" => option["options"] || []
  }

  {state, item}
end

defp reduce_update(state, %{"sessionUpdate" => "session_info_update"} = u, _turn) do
  {state, %{"id" => "session_info", "type" => "session_info", "title" => u["title"]}}
end

defp reduce_update(state, %{"sessionUpdate" => "usage_update"} = u, _turn) do
  {state, Map.merge(%{"id" => "usage", "type" => "usage"}, Map.drop(u, ["sessionUpdate"]))}
end
```

Also parse `configOptions` from the `session/new` response result (same normalized `config` items) while KEEPING legend's `modes`/`models` parsing as fallback for older adapters.

5. **set_config_option / deprecated set_mode fallback**:

```elixir
def set_config_option(state, config_id, value) do
  {state, frames} =
    if state.has_config_options? do
      request(state, "session/set_config_option", %{
        "sessionId" => state.conversation_id,
        "configId" => config_id,
        "value" => value
      })
    else
      request(state, "session/set_mode", %{
        "sessionId" => state.conversation_id,
        "modeId" => value
      })
    end

  {state, frames}
end
```

(`has_config_options?` set true when the session/new response or any `config_option_update` delivered config options.) Remove legend's `set_model/2` entirely.

6. **cancellation outcomes** — replace legend's `cancel/1`:

```elixir
def cancel(%{perms: perms} = state) do
  cancelled_frames =
    Enum.map(perms, fn {_item_id, jsonrpc_id} ->
      encode(%{
        "jsonrpc" => "2.0",
        "id" => jsonrpc_id,
        "result" => %{"outcome" => %{"outcome" => "cancelled"}}
      })
    end)

  {state, notify_frames} = notification(state, "session/cancel", %{"sessionId" => state.conversation_id})
  {%{state | perms: %{}}, cancelled_frames ++ notify_frames}
end
```

7. **answer_permission by kind** — replace the option-id variant:

```elixir
def answer_permission(state, perm_item_id, kind) when kind in ["allow_once", "reject_once"] do
  with {jsonrpc_id, perms} <- Map.pop(state.perms, perm_item_id),
       true <- jsonrpc_id != nil,
       %{"options" => options} <- get_item(state, perm_item_id),
       %{"optionId" => option_id} <- Enum.find(options, &(&1["kind"] == kind)) do
    frame =
      encode(%{
        "jsonrpc" => "2.0",
        "id" => jsonrpc_id,
        "result" => %{"outcome" => %{"outcome" => "selected", "optionId" => option_id}}
      })

    resolved = %{"id" => perm_item_id, "type" => "permission", "resolved" => true, "outcome" => kind}
    {%{state | perms: perms}, [resolved], [frame]}
  else
    _ -> {state, [], []}
  end
end
```

(The permission render item must therefore keep the raw `options` list with `optionId`/`name`/`kind` — legend already stores options; verify and keep. `get_item/2` reads the reducer's working map — if legend's state drops items after emit, keep a `last_permission_options` map keyed by item id instead; either is fine as long as the kind→optionId resolution works after emit.)

8. Everything else stays legend-verbatim: NDJSON buffering + 1 MiB cap, tool-call merge, plan, `-32601` for unknown agent→client requests, permission request item construction, turn lifecycle (`{:turn, stopReason}` on prompt response, including error responses).

- [ ] **Step 3: Write the test suite**

`backend/test/valea/acp/connection_test.exs` — pure and table-driven; helpers:

```elixir
defp frame(map), do: Jason.encode!(map) <> "\n"

defp boot(mode \\ :new, known \\ MapSet.new()) do
  {state, [init_frame]} =
    Valea.Acp.Connection.new(%{
      cwd: "/ws",
      mode: mode,
      conversation_id: (if mode == :new, do: nil, else: "conv-1"),
      known_message_ids: known,
      client_version: "0.3.0"
    })

  init = Jason.decode!(init_frame)
  assert init["method"] == "initialize"
  assert init["params"]["clientInfo"]["name"] == "valea"
  {state, init["id"]}
end

defp init_response(id, caps \\ %{}) do
  frame(%{"jsonrpc" => "2.0", "id" => id, "result" => Map.merge(%{"protocolVersion" => 1}, caps)})
end
```

Cases (write ALL of these):
1. Fresh handshake: init → response → emits `session/new` with `"mcpServers" => []` and the cwd; session/new response with sessionId → effects contain `{:session_ready}` and `{:conversation_id, "sess-abc"}`.
2. Version mismatch (`"protocolVersion" => 2`) → `{:handshake_failed, _}` effect, no session frame.
3. Resume preference: mode `:resume` + `sessionCapabilities.resume` true → `session/resume` frame; only `loadSession` true → `session/load`; neither → `session/new`.
4. Load replay dedup: after a `session/load` handshake, two `user_message_chunk` updates with `"messageId" => "m1"` where `known_message_ids` contains `"m1"` produce zero items; a fresh `"m2"` produces one.
5. Prompt turn: `prompt(state, "hi")` emits `session/prompt` with prompt blocks; `turn_in_flight?` true; prompt response with `stopReason: "end_turn"` → `{:turn, "end_turn"}` effect + turn item; error response → `{:turn, "error"}`.
6. Message accumulation: two `agent_message_chunk` updates concatenate into one `message` item id `msg-<turn>`.
7. Tool merge: `tool_call` then `tool_call_update` (status completed, content with text) merge by id; output capped (feed > 64 KiB, assert tail kept).
8. Permission round-trip: inbound `session/request_permission` request (id 9, options with kinds `allow_once`/`reject_once`) → permission item with options + `{:permission_requested, _}` effect; `answer_permission(state, id, "allow_once")` → frame with `"id" => 9` and the matching optionId + resolved item; answering again → no frames.
9. Cancellation: with a pending permission (jsonrpc id 9), `cancel/1` emits FIRST the id-9 `cancelled` outcome frame, THEN the `session/cancel` notification; perms cleared.
10. Config: `config_option_update` produces a `config` item; `set_config_option/3` emits `session/set_config_option` when options were seen, `session/set_mode` otherwise.
11. Garbage: `handle_bytes` with `"not json\n"` → no items, no crash; a single line > 1 MiB resets the buffer without crashing.
12. Unknown agent→client request (`fs/read_text_file`, id 4) → immediate `-32601` reply frame.
13. `usage_update` and `session_info_update` produce their singleton items.

- [ ] **Step 4: Run until green**

Run: `cd backend && mix test test/valea/acp/connection_test.exs`

- [ ] **Step 5: Commit**

```bash
git add backend/lib/valea/acp backend/test/valea/acp
git commit -m "feat(backend): ACP codec — vendored pure connection updated to current protocol"
```

---

### Task 9: SessionServer + transcript files + fake adapter

**Files:**
- Create: `backend/lib/valea/agents/session_server.ex`
- Create: `backend/lib/valea/agents.ex` (public API: start/list/attach; grows in T10)
- Create: `backend/test/support/fake_adapter.exs` (executable NDJSON script)
- Create: `backend/test/valea/agents/session_server_test.exs`
- Modify: `backend/lib/valea/application.ex` (add `{Registry, keys: :unique, name: Valea.Agents.SessionRegistry}` — app-level, sessions register by id)

**Interfaces:**
- Consumes: ProcessRuntime (T1), CommandSpec/ClaudeCode/Env (T7), Connection (T8), Audit (T5), Runtime's `Valea.Agents.SessionSupervisor` (T5).
- Produces: `Valea.Agents.start_session(opts)` → `{:ok, %{id: String.t()}} | {:error, term}` with `opts = %{kind: "chat" | "workflow", title: String.t(), workspace: String.t(), generation: integer(), run: map() | nil, initial_prompt: String.t() | nil, on_turn_end: (String.t() -> any()) | nil, policy_ctx: map()}`.
- `Valea.Agents.SessionServer` client API (all by session id via Registry): `attach(id)` → `{:ok, %{items: [map], cursor: integer, busy: boolean, status: String.t()}}`; `prompt(id, content)`; `cancel(id)`; `answer_permission(id, item_id, kind)`; `set_config_option(id, config_id, value)`; `stop(id)`.
- PubSub topic `"agent_session:" <> id`, messages: `{:session_event, seq, item}`, `{:session_status, status}` (status ∈ starting/running/exited/failed), `{:session_exit, code}`.
- Transcript file `{workspace}/logs/sessions/{id}.jsonl` — line 1: `%{"schema" => "session/v1", "id" =>, "acp_session_id" => nil-then-updated?  NO — metadata line is written once at start with acp_session_id nil; the `{:conversation_id, cid}` effect appends a normal item `%{"id" => "acp_session", "type" => "meta", "acp_session_id" => cid}` (append-only file, no rewrites), "kind" =>, "run_id" =>, "title" =>, "workflow" =>, "harness" => "claude_code", "generation" =>, "started_at" => ISO8601}`; then `%{"seq" => n, "item" => item}` per line.
- Permission flow: on `{:permission_requested, item}` effect the server calls `Valea.Agents.PermissionPolicy.decide(item, policy_ctx)` — until T11 lands, the server uses a default policy module attribute `@policy Valea.Agents.PermissionPolicy` and T9 ships a TEMPORARY stub module (same file layout, returns `:ask` always, moduledoc says T11 replaces the internals). `:ask` → item is broadcast for the UI; `{:allow, kind}`/`{:deny, kind}` → immediately `answer_permission` on the codec and audit `permission_auto_allowed`/`permission_auto_denied`; asks audit `permission_asked`, human answers audit `permission_answered`.

- [ ] **Step 1: The fake adapter**

`backend/test/support/fake_adapter.exs` — a standalone script run as `elixir fake_adapter.exs <scenario>`; speaks NDJSON on stdio:

```elixir
# Scripted ACP adapter for SessionServer integration tests.
# Scenarios: happy | permission | crash_mid_turn | stderr_noise | hang
defmodule FakeAdapter do
  def main([scenario]) do
    loop(%{scenario: scenario, session: "fake-sess-1"})
  end

  defp loop(ctx) do
    case IO.gets("") do
      :eof -> :ok
      line ->
        msg = Jason.decode!(line)
        handle(msg, ctx)
        loop(ctx)
    end
  end

  defp handle(%{"method" => "initialize", "id" => id}, ctx) do
    if ctx.scenario == "hang", do: Process.sleep(:infinity)

    reply(id, %{
      "protocolVersion" => 1,
      "agentCapabilities" => %{"loadSession" => false}
    })
  end

  defp handle(%{"method" => "session/new", "id" => id}, ctx) do
    reply(id, %{"sessionId" => ctx.session})
  end

  defp handle(%{"method" => "session/prompt", "id" => id}, ctx) do
    case ctx.scenario do
      "crash_mid_turn" ->
        update(ctx, %{"sessionUpdate" => "agent_message_chunk", "content" => %{"type" => "text", "text" => "part"}})
        System.halt(9)

      "permission" ->
        request(50, "session/request_permission", %{
          "sessionId" => ctx.session,
          "toolCall" => %{"toolCallId" => "t1", "title" => "Write file", "kind" => "edit",
                          "rawInput" => %{"file_path" => "/ws/queue/staging/r1/proposal.json"}},
          "options" => [
            %{"optionId" => "y", "name" => "Allow", "kind" => "allow_once"},
            %{"optionId" => "n", "name" => "Reject", "kind" => "reject_once"}
          ]
        })
        # wait for the answer before finishing the turn
        answer = IO.gets("") |> Jason.decode!()
        _ = answer
        update(ctx, %{"sessionUpdate" => "agent_message_chunk", "content" => %{"type" => "text", "text" => "done"}})
        reply(id, %{"stopReason" => "end_turn"})

      _ ->
        if ctx.scenario == "stderr_noise", do: IO.puts(:stderr, "noise {not json}")
        update(ctx, %{"sessionUpdate" => "agent_message_chunk", "content" => %{"type" => "text", "text" => "hello"}})
        reply(id, %{"stopReason" => "end_turn"})
    end
  end

  defp handle(%{"method" => "session/cancel"}, _ctx), do: :ok
  defp handle(_other, _ctx), do: :ok

  defp reply(id, result), do: emit(%{"jsonrpc" => "2.0", "id" => id, "result" => result})
  defp request(id, method, params), do: emit(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})

  defp update(ctx, u),
    do: emit(%{"jsonrpc" => "2.0", "method" => "session/update",
               "params" => %{"sessionId" => ctx.session, "update" => u}})

  defp emit(map), do: IO.puts(Jason.encode!(map))
end

FakeAdapter.main(System.argv())
```

Caveat: the script needs Jason. Standalone `elixir` scripts don't see project deps — run it THROUGH the project instead: the tests set the harness command to `[System.find_executable("mix"), "run", "--no-start", "test/support/fake_adapter.exs", scenario]`? NO — simplest robust choice: make the fake adapter dependency-free by hand-rolling minimal JSON (fragile) — do NOT. Instead use `elixir --eval` with Mix available? Also no. The clean answer: `Mix.install`-free — run via the project's compiled code path:

```
[System.find_executable("elixir"), "-pa", Path.expand("_build/test/lib/jason/ebin"), "test/support/fake_adapter.exs", scenario]
```

`-pa` puts Jason's compiled beams on the code path; the script adds `Application.ensure_all_started(:jason)` is unnecessary (Jason is a library, no app start needed). Compute the `-pa` path in the test helper with `Path.expand` from the project root. This works both locally and in CI because `mix test` has already built `_build/test/lib/jason`.

- [ ] **Step 2: Failing integration tests**

`backend/test/valea/agents/session_server_test.exs`:

```elixir
defmodule Valea.Agents.SessionServerTest do
  use ExUnit.Case, async: false

  setup do
    root = Path.join(System.tmp_dir!(), "vses-#{System.os_time(:nanosecond)}")
    File.mkdir_p!(Path.join(root, "logs/sessions"))
    on_exit(fn -> File.rm_rf!(root) end)

    start_supervised!({Valea.Audit, %{root: root, generation: 1}})
    start_supervised!({DynamicSupervisor, name: Valea.Agents.SessionSupervisor, strategy: :one_for_one})

    %{root: root}
  end

  defp fake_cmd(scenario) do
    elixir = System.find_executable("elixir")
    jason = Path.expand("_build/test/lib/jason/ebin")
    script = Path.expand("test/support/fake_adapter.exs")
    [elixir, "-pa", jason, script, scenario]
  end

  defp start_session(root, scenario, extra \\ %{}) do
    Valea.App.Config.set_harness_command(fake_cmd(scenario))

    Valea.Agents.start_session(
      Map.merge(
        %{kind: "chat", title: "Test", workspace: root, generation: 1,
          run: nil, initial_prompt: nil, on_turn_end: nil,
          policy_ctx: %{workspace: root, session_kind: "chat", write_paths: []}},
        extra
      )
    )
  end

  test "happy path: handshake, prompt, transcript file, turn end", %{root: root} do
    {:ok, %{id: id}} = start_session(root, "happy")
    Phoenix.PubSub.subscribe(Valea.PubSub, "agent_session:" <> id)

    :ok = Valea.Agents.SessionServer.prompt(id, "hi")
    assert_receive {:session_event, _, %{"type" => "message", "text" => text}}, 10_000
    assert text =~ "hello"
    assert_receive {:session_event, _, %{"type" => "turn"}}, 10_000

    {:ok, %{items: items, busy: false}} = Valea.Agents.SessionServer.attach(id)
    assert Enum.any?(items, &(&1["type"] == "message"))

    transcript = File.read!(Path.join(root, "logs/sessions/#{id}.jsonl"))
    [meta | rest] = String.split(transcript, "\n", trim: true)
    assert %{"schema" => "session/v1", "kind" => "chat"} = Jason.decode!(meta)
    assert length(rest) >= 2
  end

  test "permission request reaches the timeline as ask; answering resolves it", %{root: root} do
    {:ok, %{id: id}} = start_session(root, "permission")
    Phoenix.PubSub.subscribe(Valea.PubSub, "agent_session:" <> id)

    :ok = Valea.Agents.SessionServer.prompt(id, "write")
    assert_receive {:session_event, _, %{"type" => "permission", "resolved" => false} = perm}, 10_000

    :ok = Valea.Agents.SessionServer.answer_permission(id, perm["id"], "allow_once")
    assert_receive {:session_event, _, %{"type" => "permission", "resolved" => true}}, 10_000
    assert_receive {:session_event, _, %{"type" => "turn"}}, 10_000
  end

  test "mid-turn crash: exit broadcast, turn ends, transcript intact", %{root: root} do
    {:ok, %{id: id}} = start_session(root, "crash_mid_turn")
    Phoenix.PubSub.subscribe(Valea.PubSub, "agent_session:" <> id)

    :ok = Valea.Agents.SessionServer.prompt(id, "boom")
    assert_receive {:session_exit, _code}, 10_000
    {:ok, %{status: "exited", busy: false}} = Valea.Agents.SessionServer.attach(id)
  end

  test "stderr noise never corrupts the stream", %{root: root} do
    {:ok, %{id: id}} = start_session(root, "stderr_noise")
    Phoenix.PubSub.subscribe(Valea.PubSub, "agent_session:" <> id)
    :ok = Valea.Agents.SessionServer.prompt(id, "hi")
    assert_receive {:session_event, _, %{"type" => "turn"}}, 10_000
  end

  test "hung handshake trips the watchdog", %{root: root} do
    # pass a short watchdog through opts for the test
    {:ok, %{id: id}} = start_session(root, "hang", %{handshake_timeout_ms: 500})
    Phoenix.PubSub.subscribe(Valea.PubSub, "agent_session:" <> id)
    assert_receive {:session_status, :failed}, 5_000
  end

  test "harness_unavailable propagates", %{root: root} do
    Valea.App.Config.set_harness_command(["no-such-binary-zzz"])
    assert {:error, :harness_unavailable} =
             Valea.Agents.start_session(%{kind: "chat", title: "x", workspace: root, generation: 1,
                                          run: nil, initial_prompt: nil, on_turn_end: nil,
                                          policy_ctx: %{workspace: root, session_kind: "chat", write_paths: []}})
  end
end
```

(App.Config in tests: use the `VALEA_APP_DIR` tmp pattern per its existing tests — set it in `setup` so `set_harness_command` writes to a scratch config.)

- [ ] **Step 3: Implement SessionServer + Agents facade**

Donor for the shape: `/Users/daniel/Development/legend/backend/lib/legend/core/agents/session_server.ex` — read its ACP half (start_transport, handle runtime messages, effects execution, queueing) but WRITE OUR OWN slim version (~250 lines); do not vendor wholesale (it carries PTY/remote/MCP baggage). Key structure:

```elixir
defmodule Valea.Agents.SessionServer do
  use GenServer, restart: :temporary
  require Logger

  @handshake_timeout_ms 30_000

  # --- client API (via_tuple(id) through Valea.Agents.SessionRegistry) ---
  # attach/1 prompt/2 cancel/1 answer_permission/3 set_config_option/3 stop/1

  # --- init flow ---
  # 1. id = timestamp <> "-" <> 6-byte hex suffix (:crypto.strong_rand_bytes)
  # 2. Regenerate managed settings: Valea.Agents.ClaudeSettings.write!(workspace)
  # 3. {:ok, spec} = Valea.Harnesses.ClaudeCode.acp_command(%{env: Valea.Agents.Env.minimal()})
  #    (do this in Valea.Agents.start_session BEFORE DynamicSupervisor.start_child
  #     so {:error, :harness_unavailable} returns synchronously)
  # 4. ProcessRuntime.start(%{cmd: spec.cmd, args: spec.args, env: spec.env, cd: workspace}, self())
  # 5. {conn, frames} = Connection.new(%{cwd: workspace, mode: :new, conversation_id: nil,
  #       known_message_ids: MapSet.new(), client_version: version()})
  #    write frames; arm watchdog Process.send_after(self(), :handshake_timeout, timeout)
  # 6. Open transcript: write metadata line; state holds file path (append with File.write(..., [:append]))

  # --- handle_info({:runtime_output, data}) ---
  # {conn, items, frames, effects} = Connection.handle_bytes(conn, data)
  # write frames -> ProcessRuntime.write; Enum.each(items, &append_item/1); run effects

  # --- effects ---
  # {:session_ready} -> cancel watchdog; status :running; flush queued prompt
  # {:conversation_id, cid} -> append meta item %{"id" => "acp_session", "type" => "meta", "acp_session_id" => cid}
  # {:turn, stop} -> append turn item; if on_turn_end, spawn(fn -> on_turn_end.(stop) end); drain prompt queue
  # {:handshake_failed, reason} -> fail(reason)
  # {:permission_requested, item} -> policy_decide(item)

  # --- policy_decide/1 ---
  # case @policy.decide(item, state.policy_ctx) do
  #   {:allow, kind} -> audit "permission_auto_allowed"; answer on codec (kind "allow_once")
  #   {:deny, kind}  -> audit "permission_auto_denied";  answer on codec (kind "reject_once")
  #   :ask           -> audit "permission_asked"; item already appended/broadcast — UI takes over
  # end

  # --- append_item(item) ---
  # seq = state.seq + 1; File.write(transcript, Jason.encode!(%{"seq" => seq, "item" => item}) <> "\n", [:append])
  # Phoenix.PubSub.broadcast(Valea.PubSub, topic, {:session_event, seq, item})

  # --- prompt queueing: if Connection.turn_in_flight?, queue (max 50); else send now
  # --- handle_info({:runtime_stderr, data}) -> Logger.warning("[acp #{id}] stderr: #{data}")
  # --- handle_info({:runtime_exit, code}) -> status :exited; broadcast {:session_exit, code}; stay alive
  # --- handle_info(:handshake_timeout, s) -> if not ready: ProcessRuntime.stop; fail("handshake timed out")
  # --- terminate: ProcessRuntime.stop(handle) if alive
end
```

Fill this in completely — every commented line above is a requirement, not a suggestion. `Valea.Agents.start_session/1` (in `backend/lib/valea/agents.ex`) resolves the harness command first, then `DynamicSupervisor.start_child(Valea.Agents.SessionSupervisor, {SessionServer, opts_with_spec})`, waits for the child's `{:ok, pid}`, returns `{:ok, %{id: id}}` (id generated by the caller and passed in opts so it is known synchronously). Accept `handshake_timeout_ms` in opts (default `@handshake_timeout_ms`).

Temporary policy stub `backend/lib/valea/agents/permission_policy.ex`:

```elixir
defmodule Valea.Agents.PermissionPolicy do
  @moduledoc "Stub — Task 11 implements the real deny/allow/ask policy."
  def decide(_permission_item, _ctx), do: :ask
end
```

Add to `application.ex` children: `{Registry, keys: :unique, name: Valea.Agents.SessionRegistry}`.

- [ ] **Step 4: Run until green**

Run: `cd backend && mix test test/valea/agents/session_server_test.exs`
Then the full suite: `cd backend && mix test`

- [ ] **Step 5: Commit**

```bash
git add backend/lib/valea backend/test
git commit -m "feat(backend): agent session server — spawn, transcript files, watchdog, prompt queue"
```

---

### Task 10: AgentSessionChannel + session listing

**Files:**
- Create: `backend/lib/valea_web/channels/agent_session_channel.ex`
- Create: `backend/test/valea_web/agent_session_channel_test.exs`
- Modify: `backend/lib/valea_web/channels/user_socket.ex` (add `channel "agent_session:*", ValeaWeb.AgentSessionChannel`)
- Modify: `backend/lib/valea/agents.ex` (`list_sessions/0`, `attach_or_replay/1`)

**Interfaces:**
- Produces: channel topic `agent_session:<id>`. Join reply: `%{items: [...], cursor: n, busy: bool, status: "running" | "exited" | "failed" | "ended"}`. For a LIVE session (Registry hit) the reply comes from `SessionServer.attach/1`; for an ENDED session (no process, transcript file exists) items are replayed from the file with `busy: false, status: "ended"`. Unknown id → join error `%{reason: "session_not_found"}`.
- Pushes: `"event"` → `%{seq, item}` (gated `seq > socket.assigns.cursor`), `"status"` → `%{status}`, `"exit"` → `%{exit_code}`.
- Inbound: `"prompt"` `%{"content" => String.t()}`, `"cancel"`, `"permission"` `%{"item_id" =>, "kind" =>}` (kind allow_once/reject_once only — anything else replies error), `"set_config_option"` `%{"config_id" =>, "value" =>}`, `"stop"`. Inbound on an ended session replies `{:error, %{reason: "session_not_found"}}`. Catch-all `handle_in` prevents crashes on unknown events.
- `Valea.Agents.list_sessions/0` → `{:ok, [%{"id" =>, "kind" =>, "title" =>, "workflow" =>, "run_id" =>, "started_at" =>, "status" =>, "live" => bool}]}` — scans `{workspace}/logs/sessions/*.jsonl` first lines (newest first by started_at), merging live status from the Registry.

**Steps:** TDD as always — channel tests use `ValeaWeb.ChannelCase` with the dev token (T6); drive a live fake-adapter session (reuse T9's `fake_cmd` helper via a shared `test/support/agent_case.ex` helper module you create now), covering: join replay on a live session; join replay on an ended session from file only (start `happy` session, prompt, await turn, `stop`, kill the server process via `SessionServer.stop`, then join and assert items from file, `status: "ended"`); seq gating (push after join not duplicated below cursor); `prompt` in, event out; `permission` answer path; unknown topic id join error; `list_sessions` ordering + `live` flags. Implement the channel (mirror the Phase-1 `workspace_events_channel.ex`/legend `session_channel.ex` structure — the donor file is `/Users/daniel/Development/legend/backend/lib/legend_web/channels/session_channel.ex`). Run `cd backend && mix test`. Commit:

```bash
git add backend
git commit -m "feat(backend): agent session channel with file replay + session listing"
```

---

### Task 11: PermissionPolicy (real) + symlink-aware path resolution

**Files:**
- Create: `backend/lib/valea/paths.ex`
- Rewrite: `backend/lib/valea/agents/permission_policy.ex` (replace the T9 stub)
- Create: `backend/test/valea/paths_test.exs`, `backend/test/valea/agents/permission_policy_test.exs`

**Interfaces:**
- Produces: `Valea.Paths.resolve_real(path, base)` → `{:ok, absolute_resolved} | {:error, :outside | :invalid}` — expands `path` against `base`, resolves symlinks component-by-component (bounded, 32 hops), then verifies the result is inside `base` (also symlink-resolved). Non-existent trailing components are allowed (a write target does not exist yet): resolve the DEEPEST EXISTING ancestor, then re-append the non-existent remainder — the remainder must not contain `..`.
- Produces: `Valea.Agents.PermissionPolicy.decide(permission_item, ctx)` → `{:allow, "allow_once"} | {:deny, "reject_once"} | :ask` with `ctx = %{workspace: String.t(), session_kind: "chat" | "workflow", write_paths: [String.t()]}` (write_paths: exact absolute file paths a workflow run may write; empty for chat).
- Rules (spec verbatim, precedence deny → allow → ask):
  - Extract candidate paths from `permission_item["rawInput"]` keys `file_path`, `path`, `notebook_path`, `filePath` (strings only) — the permission item built in T8 must carry `rawInput` and `kind` from the ACP toolCall; verify the codec keeps them on the permission render item and add them if missing (small T8 follow-up inside this task is allowed).
  - DENY if any resolved path is under `secrets/`, `logs/`, `.claude/`, `.git/` or matches `app.sqlite*` — or resolution fails with `:outside`.
  - Tool kinds: read-ish kinds are `["read"]`; write-ish are `["edit", "write", "delete", "move"]`; everything else (`execute`, `fetch`, missing, unknown) → `:ask` (never allow, never deny — Bash may be legitimate, the human decides).
  - ALLOW read: kind read AND ≥1 path extracted AND all paths inside `icm/`, `sources/`, `prompts/`, or equal to `AGENTS.md`/`CLAUDE.md` at the root.
  - ALLOW write: kind write-ish AND session_kind == "workflow" AND every path is in `ctx.write_paths` (exact match after resolution).
  - Everything else → `:ask`. No paths extracted → `:ask` (for read kinds too).

- [ ] **Step 1: Failing tests** — cover at minimum:

```elixir
# paths_test.exs
- resolves relative path against base
- rejects ../ escape -> {:error, :outside}
- resolves a symlink pointing inside base
- rejects a symlink pointing OUTSIDE base (File.ln_s to a tmp dir sibling)
- allows non-existent target file inside an existing dir (write target)
- rejects non-existent remainder containing ".."

# permission_policy_test.exs (build ctx against a real tmp workspace with icm/, secrets/, queue/staging/r1/)
- read inside icm/ -> {:allow, "allow_once"}
- read of secrets/notes.txt -> {:deny, "reject_once"}
- read via symlink icm/link.md -> /etc/passwd -> deny
- read of queue/pending/x.json -> :ask (not a declared read root)
- write to the exact staging path, workflow ctx -> allow
- write to a DIFFERENT staging path -> :ask
- any write in chat ctx -> :ask
- write targeting logs/audit.jsonl -> deny (deny precedence over ask)
- kind "execute" (Bash) -> :ask even with workspace paths in rawInput
- no rawInput paths, kind read -> :ask
```

- [ ] **Step 2: Implement**

`backend/lib/valea/paths.ex`:

```elixir
defmodule Valea.Paths do
  @moduledoc """
  Symlink-aware containment. The ICM chokepoint's lexical check is not
  enough for the agent boundary: a symlink inside the workspace can point
  anywhere. Resolution walks existing components via File.read_link,
  bounded to 32 hops.
  """

  @max_hops 32

  def resolve_real(path, base) do
    abs = Path.expand(path, base)
    base_real = resolve_existing(Path.expand(base), @max_hops)

    with {:ok, resolved} <- split_and_resolve(abs),
         true <- String.starts_with?(resolved <> "/", base_real <> "/") or resolved == base_real do
      {:ok, resolved}
    else
      false -> {:error, :outside}
      {:error, _} = err -> err
    end
  end

  # Resolve the deepest existing ancestor; re-append the non-existent tail.
  defp split_and_resolve(abs) do
    {existing, tail} = deepest_existing(abs, [])

    if Enum.any?(tail, &(&1 == "..")) do
      {:error, :invalid}
    else
      {:ok, Path.join([resolve_existing(existing, @max_hops) | tail])}
    end
  end

  defp deepest_existing(path, tail) do
    cond do
      File.exists?(path) or path == "/" -> {path, tail}
      true -> deepest_existing(Path.dirname(path), [Path.basename(path) | tail])
    end
  end

  defp resolve_existing(path, 0), do: path

  defp resolve_existing(path, hops) do
    parts = Path.split(path)

    {resolved, _} =
      Enum.reduce(parts, {"", hops}, fn part, {acc, h} ->
        candidate = if acc == "", do: part, else: Path.join(acc, part)

        case File.read_link(candidate) do
          {:ok, target} when h > 0 ->
            target = Path.expand(target, Path.dirname(candidate))
            {resolve_existing(target, h - 1), h - 1}

          _ ->
            {candidate, h}
        end
      end)

    resolved
  end
end
```

`backend/lib/valea/agents/permission_policy.ex`:

```elixir
defmodule Valea.Agents.PermissionPolicy do
  @moduledoc """
  deny -> allow -> ask, unclassifiable = ask (spec §PermissionPolicy).
  Pure: decisions depend only on the permission item and the ctx. Every
  decision is audited by the SessionServer, not here.
  """

  @protected_dirs ["secrets", "logs", ".claude", ".git"]
  @db_prefix "app.sqlite"
  @read_kinds ["read"]
  @write_kinds ["edit", "write", "delete", "move"]
  # Default reference roots; ctx[:read_roots] overrides — a LIST so ICM
  # mounts can extend it later (spec §Composition-ready choices).
  @default_read_roots ["icm", "sources", "prompts"]
  @root_files ["AGENTS.md", "CLAUDE.md"]

  def decide(item, ctx) do
    kind = item["kind"]
    read_roots = ctx[:read_roots] || @default_read_roots
    paths = extract_paths(item)
    resolved = Enum.map(paths, &Valea.Paths.resolve_real(&1, ctx.workspace))

    cond do
      Enum.any?(resolved, &denied?(&1, ctx.workspace)) -> {:deny, "reject_once"}
      paths == [] -> :ask
      Enum.any?(resolved, &(elem(&1, 0) == :error)) -> :ask
      kind in @read_kinds and all_in_read_roots?(resolved, ctx.workspace, read_roots) ->
        {:allow, "allow_once"}
      kind in @write_kinds and ctx.session_kind == "workflow" and
          all_in_write_paths?(resolved, ctx.write_paths) -> {:allow, "allow_once"}
      true -> :ask
    end
  end

  defp extract_paths(item) do
    raw = item["rawInput"] || %{}

    ["file_path", "path", "notebook_path", "filePath"]
    |> Enum.map(&raw[&1])
    |> Enum.filter(&is_binary/1)
  end

  defp denied?({:error, :outside}, _ws), do: true
  defp denied?({:error, _}, _ws), do: false

  defp denied?({:ok, path}, ws) do
    rel = Path.relative_to(path, ws)
    top = rel |> Path.split() |> List.first()
    top in @protected_dirs or String.starts_with?(Path.basename(rel), @db_prefix)
  end

  defp all_in_read_roots?(resolved, ws, read_roots) do
    Enum.all?(resolved, fn {:ok, path} ->
      rel = Path.relative_to(path, ws)
      top = rel |> Path.split() |> List.first()
      top in read_roots or rel in @root_files
    end)
  end

  defp all_in_write_paths?(resolved, write_paths) do
    Enum.all?(resolved, fn {:ok, path} -> path in write_paths end)
  end
end
```

Wire the audit in the SessionServer's `policy_decide` (T9 already audits — verify the three entry types fire with `%{"session_id" =>, "title" => item["title"], "decision" =>}` fields).

- [ ] **Step 3: Run** `cd backend && mix test` → green (T9's permission test still passes: the fake adapter's write is to a staging path but the ctx is chat → `:ask` → surfaced → the test answers it; verify).

- [ ] **Step 4: Commit**

```bash
git add backend
git commit -m "feat(backend): permission policy — deny/allow/ask with symlink-aware containment"
```

---

### Task 12: Workflows + Runner (server-owned run identity)

**Files:**
- Create: `backend/lib/valea/workflows.ex`, `backend/lib/valea/workflows/runner.ex`
- Create: `backend/test/valea/workflows_test.exs`, `backend/test/valea/workflows/runner_test.exs`

**Interfaces:**
- Produces: `Valea.Workflows.list/0` → `{:ok, [wf]}`; `Valea.Workflows.get(icm_rel_path)` → `{:ok, wf} | {:error, :not_found}` where `wf = %{path: "icm/Workflows/....md", name:, description:, enabled: boolean, trigger: map, sources: [map], risk_level:, approval: map, steps_preview: [String.t()]}` (name = H1 or filename; description = first body paragraph; steps_preview = numbered items under "## Process").
- Produces: `Valea.Workflows.Runner.run(workflow_path, input_path)` → `{:ok, %{run_id:, session_id:}} | {:error, :not_found | :workflow_disabled | :input_not_found | :harness_unavailable | term}`.
- Run mechanics (spec §Runner, all server-owned):
  - `run_id = <UTC yyyymmddThhmmssZ>-<6 hex>`; staging dir `queue/staging/<run_id>/`; exact output path `queue/staging/<run_id>/proposal.json`.
  - Hashes: sha256 hex of the workflow page bytes and the input file bytes at run start.
  - Audit `workflow_run_started` (run_id, workflow, input, hashes).
  - Session opts: `kind: "workflow"`, `title: wf.name`, `run: %{run_id:, workflow: path, workflow_hash:, input: input_path, input_hash:, risk_level:, approval:}`, `policy_ctx: %{workspace:, session_kind: "workflow", write_paths: [abs staging proposal path]}`, `initial_prompt: composed`, `on_turn_end: fn stop -> Runner.finalize(run_id, workspace) end`.
  - Prompt template (verbatim, interpolating the three paths):

```
Read AGENTS.md first if you have not already. Then execute the workflow
contract at "<workflow_path>" against the input file "<input_path>".
Follow the contract's Process steps. Read only the pages its Inputs and
sources name. Write exactly one proposal/v1 JSON file to
"<staging_rel_path>" and nothing else. When the file is written, state
in one sentence what you prepared, and stop.
```

  - `Runner.finalize(run_id, workspace)` — idempotent: reads the exact staging path; missing → audit `workflow_run_finished` with `outcome: "no_proposal"`; unparseable/invalid per `proposal/v1` validation (required: schema=="proposal/v1", kind=="email_draft", non-empty title/summary/reasoning, sources list of strings, proposed_action with type=="create_email_draft" + to/subject/body_markdown strings) → outcome `"invalid_proposal"` and the staging file is LEFT in place for inspection; valid → build the `queue_item/v1` envelope (spec §queue item, all server fields from the run record + `payload`), write `queue/pending/<run_id>.json` (atomic tmp+rename), remove the staging dir, audit `queue_item_created` then `workflow_run_finished` with `outcome: "proposal_created"`.
  - Run records: keep them in a `Valea.Workflows.RunRegistry` — a public ETS table owned by the Runtime supervisor? Simpler and sufficient: the run map is CLOSED OVER by `on_turn_end` and stored in the SessionServer opts; `finalize/2` receives `run_id` and re-derives everything it needs from a small JSON sidecar the Runner writes at run start: `queue/staging/<run_id>/run.json` (the envelope minus payload). This survives crashes (staging recovery can inspect it) and needs no process state. Implement the sidecar approach.

- [ ] **Step 1: Failing tests** — highlights (full tmp workspace via scaffold; fake adapter drives the session):

```elixir
# workflows_test.exs
- list/0 returns 4 workflows from the template, exactly one enabled
- get/1 parses frontmatter (trigger.source, risk_level, approval.actions) and steps_preview
- get/1 on a page without frontmatter -> {:error, :not_found}? NO — a Workflows/ page
  missing frontmatter is not a contract: list/0 skips it, get/1 returns {:error, :not_found}

# runner_test.exs
- run/2 on a disabled workflow -> {:error, :workflow_disabled}
- run/2 on missing input -> {:error, :input_not_found}
- happy path with a "workflow_happy" fake-adapter scenario (ADD IT to fake_adapter.exs:
  on session/prompt it writes a valid proposal/v1 JSON to the staging path parsed
  from the prompt text — the scenario greps the prompt for queue/staging/.../proposal.json,
  writes the file relative to its cwd, emits a message chunk, ends the turn):
  -> queue/pending/<run_id>.json exists with schema queue_item/v1, run_id, workflow_hash,
     payload.kind == "email_draft"; staging dir removed; audit chain has
     workflow_run_started, queue_item_created, workflow_run_finished
- finalize with no staging file -> outcome no_proposal, no pending item
- finalize with invalid payload (missing to) -> outcome invalid_proposal, staging kept
- finalize twice -> second call is a no-op (pending item not duplicated)
```

- [ ] **Step 2: Implement** `Valea.Workflows` (frontmatter via `Valea.ICM.split_frontmatter` + YamlElixir; body parsing with simple line scans — H1 for name, first non-heading paragraph for description, `## Process` numbered lines for steps_preview) and `Valea.Workflows.Runner` per the interface block. sha256: `:crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)`.

- [ ] **Step 3: Run** `cd backend && mix test` → green. **Step 4: Commit**

```bash
git add backend
git commit -m "feat(backend): workflow contracts + runner with server-owned run identity"
```

---

### Task 13: Queue — validation, hardened approval, recovery, live events

**Files:**
- Create: `backend/lib/valea/queue.ex`
- Create: `backend/test/valea/queue_test.exs`
- Modify: `backend/lib/valea/icm/watcher.ex` (watch `queue/` too; broadcast `{:queue_changed}` on the `"queue"` topic, debounced, when the touched path is under queue/)
- Modify: `backend/lib/valea/workspace/runtime.ex` (run `Valea.Queue.recover/1` once at startup — a `Task` child or `:transient` GenServer that runs and exits)
- Modify: the workspace events channel (push `"queue_changed"` to `workspace:events` subscribers on `{:queue_changed}` — follow how `icm_changed` is forwarded)

**Interfaces:**
- Produces: `Valea.Queue.list/0` → `{:ok, [item_summary]}` (pending only, newest first: run_id, title, summary, kind, risk_level, created_at, workflow, valid: boolean — invalid files listed with `valid: false` + `error`).
- `Valea.Queue.get(run_id)` → `{:ok, %{item: full_envelope_map, revision: sha256_hex_of_file_bytes}} | {:error, :queue_item_gone | :queue_item_invalid}`.
- `Valea.Queue.approve(run_id, revision)` → `{:ok, %{draft_path: String.t()}} | {:error, :queue_item_gone | :queue_item_changed | :queue_item_invalid}` implementing EXACTLY: revision check → atomic rename `pending/ → processing/` (rename failure = gone) → audit `approval_intent` → idempotent draft write `sources/mail/drafts/<run_id>.md` (exists = already executed, skip write) → audit `action_executed` → rename `processing/ → approved/` → audit `item_approved`.
- Draft file format:

```markdown
---
to: <payload.proposed_action.to>
subject: <payload.proposed_action.subject>
run_id: <run_id>
workflow: <workflow>
sources:
  - <each source>
---

<payload.proposed_action.body_markdown>
```

- `Valea.Queue.reject(run_id, revision)` → `{:ok, %{}} | {:error, ...}` — revision check → rename `pending/ → rejected/` → audit `item_rejected`.
- `Valea.Queue.recover(workspace)` — for each file in `processing/`: draft exists → complete (move to approved, audit `item_approved` with `recovered: true`); else → back to pending (audit `approval_recovered`).

- [ ] **Step 1: Failing tests** — cover: list/get with revision; approve happy chain INCLUDING audit ordering (read audit.jsonl, assert `approval_intent` precedes `action_executed` precedes `item_approved`); approve with stale revision → `queue_item_changed` and file untouched; approve twice → second `queue_item_gone`; idempotent draft (pre-create the draft file, approve → succeeds without overwriting); reject; recover both branches; invalid pending JSON listed with `valid: false` and `get` → `queue_item_invalid`; watcher: touch a file under `queue/pending/` → receive `{:queue_changed}` on the `"queue"` topic within 1s.

- [ ] **Step 2: Implement.** Atomic claims via `File.rename/2` (same filesystem). Revision = sha256 of file bytes, computed in `get/1` and re-verified inside `approve/reject` immediately BEFORE the rename (read bytes → hash → compare → rename). Watcher: change its `dirs:` to `[icm_path, queue_path]` and route events by path prefix — icm events keep the existing behavior, queue events debounce onto a second timer broadcasting `{:queue_changed}` on `"queue"`.

- [ ] **Step 3: Run** `cd backend && mix test` → green. **Step 4: Commit**

```bash
git add backend
git commit -m "feat(backend): hardened queue — revision guard, atomic claim, idempotent execute, recovery"
```

---

### Task 14: Doctor

**Files:**
- Create: `backend/lib/valea/agents/doctor.ex`
- Create: `backend/test/valea/agents/doctor_test.exs`

**Interfaces:**
- Produces: `Valea.Agents.Doctor.run/0` → `{:ok, %{checks: [check], ok: boolean}}` with `check = %{"id" => "node" | "adapter" | "auth", "status" => "ok" | "failed" | "unknown", "detail" => String.t(), "remedy" => String.t() | nil}`.
- Checks (spec §Doctor, exact commands):
  1. `node`: `System.find_executable("node")` + `node --version` ≥ v22 → else remedy `"Install Node 22 or newer (https://nodejs.org)"`.
  2. `adapter`: resolve via `Valea.Harnesses.ClaudeCode.acp_command/1`; run `<cmd> --version` with a 5s timeout → failed remedy `"npm install -g @agentclientprotocol/claude-agent-acp"`.
  3. `auth`: `<cmd> --cli auth status` exit 0 → ok; non-zero → failed, remedy `"claude-agent-acp --cli auth login --claudeai"`; command errors/timeouts → `"unknown"` with remedy nil and detail explaining the probe could not run (an honest unknown, spec-sanctioned).
- Timeouts via `Task.async` + `Task.yield(t, 5_000) || Task.shutdown(t)` around `System.cmd` (System.cmd has no timeout).

**Steps:** TDD: tests fake the executables by pointing `Valea.App.Config.set_harness_command/1` at small shell scripts written into a tmp dir (`#!/bin/sh\necho 0.58.1` / `exit 1` / `sleep 10`), plus a PATH-manipulation case for the node check (pass an env override arg `Doctor.run(path_override)` — default `nil` uses the real PATH; keep the override parameter test-only and documented). Implement, run, commit:

```bash
git add backend
git commit -m "feat(backend): harness doctor — node, adapter, auth probes with honest unknowns"
```

---

### Task 15: RPC surface + codegen + client wrappers

**Files:**
- Create: `backend/lib/valea/api/agents.ex`, `backend/lib/valea/api/queue_api.ex` (module `Valea.Api.Queue`)
- Modify: `backend/lib/valea/api.ex` (register resources + rpc actions), `backend/lib/valea/api/error.ex` (new error atoms)
- Create: `backend/test/valea/api/agents_api_test.exs`, `backend/test/valea/api/queue_api_test.exs`
- Modify: `frontend/src/lib/api/client.ts` (wrappers), regenerate `ash_rpc.ts`/`ash_types.ts`

**Interfaces (action names + typed returns — the generated TS client is the contract for T16+):**

All follow the `Valea.Api.ICM` pattern (generic actions, `constraints fields:`, `error_for/1`). Mutating actions take `generation :: integer` and start with `with :ok <- Valea.Workspace.Manager.check_generation(input.arguments.generation) do ... end`.

- `create_agent_session(kind, generation)` → `%{id: string}` — calls `Valea.Agents.start_session` with `kind`, title `"New session"`, chat policy ctx.
- `list_agent_sessions()` → `%{sessions: [%{id, kind, title, workflow, run_id, started_at, status, live}]}` (typed: sessions is `{:array, :map}` with field constraints — copy the nested-constraint style from an existing constrained action or use `fields: [sessions: [type: {:array, :map}, constraints: [fields: [...]]]]`).
- `run_workflow(path, input, generation)` → `%{run_id: string, session_id: string}`; errors map `:workflow_disabled | :input_not_found | :harness_unavailable | :not_found`.
- `harness_doctor()` → `%{ok: boolean, checks: [%{id, status, detail, remedy}]}` (remedy `allow_nil?: true`).
- `list_workflows()` → `%{workflows: [%{path, name, description, enabled, trigger_source, risk_level, source_count, steps: [string]}]}` — note: FLATTEN for typing (`trigger_source` = trigger["source"], `source_count` = length(sources)); the full page is one click away in Knowledge, the card needs no deep nesting.
- `list_queue_items()` → `%{items: [%{run_id, title, summary, kind, risk_level, created_at, workflow, valid, error}]}` (`error` allow_nil).
- `get_queue_item(run_id)` → `%{item: :map (unconstrained — the envelope with payload; document the casing caveat: deliver raw), revision: string}`.
- `approve_queue_item(run_id, revision, generation)` → `%{draft_path: string}`.
- `reject_queue_item(run_id, revision, generation)` → `%{rejected: boolean}`.
- `list_audit_entries(limit)` → `%{entries: :map array unconstrained — audit entries are heterogeneous; deliver raw with a comment}`.
- MODIFY `save_icm_page` (existing, `backend/lib/valea/api/icm.ex`): add an OPTIONAL `generation :: integer` argument (`allow_nil?: true`); when present, run `Valea.Workspace.Manager.check_generation/1` before saving (stale → `workspace_changed`); nil skips the check (transition compatibility). Regenerate the client here so T21 needs no codegen; the editor store starts passing it in T21.

Errors added to `error_for/1`: `:harness_unavailable, :session_not_found, :queue_item_invalid, :queue_item_gone, :queue_item_changed, :workspace_changed, :workflow_disabled, :input_not_found`.

**Steps:**
- [ ] Step 1: failing resource tests (drive actions through `Ash` directly like existing api tests do — read `backend/test/valea/api/` first; cover: happy path per action, generation mismatch → `workspace_changed`, queue errors mapped).
- [ ] Step 2: implement resources; register in `lib/valea/api.ex` rpc block.
- [ ] Step 3: `just codegen` — commit the regenerated `frontend/src/lib/api/ash_rpc.ts` + `ash_types.ts` (staleness gate).
- [ ] Step 4: extend `frontend/src/lib/api/client.ts` with wrapped functions (follow the existing wrapper + fields-list pattern EXACTLY — every typed action needs its non-empty fields array): `createAgentSession`, `listAgentSessions`, `runWorkflow`, `harnessDoctor`, `listWorkflows`, `listQueueItems`, `getQueueItem`, `approveQueueItem`, `rejectQueueItem`, `listAuditEntries`. Mutating wrappers read the generation from the workspace store — NO: client.ts must stay store-free (check its current imports); instead each wrapper takes `generation` as an argument and the STORES supply it (T16).
- [ ] Step 5: `cd backend && mix test && just test` (staleness gate green), commit:

```bash
git add backend frontend/src/lib/api
git commit -m "feat: typed RPC surface for agents, workflows, queue, audit"
```

---

### Task 16: Frontend stores + agent channel client

**Files:**
- Create: `frontend/src/lib/stores/agent-session.svelte.ts` + `agent-session.test.ts`
- Create: `frontend/src/lib/stores/queue.svelte.ts` + `queue.test.ts`
- Create: `frontend/src/lib/stores/workflows.svelte.ts`
- Create: `frontend/src/lib/stores/sessions-list.svelte.ts`
- Modify: `frontend/src/lib/socket.ts` (per-session channel helper)

**Interfaces:**
- `socket.ts` gains `joinAgentSession(id: string): Channel` (fresh channel per session id, caller owns leave()).
- `AgentSessionStore` (donor: `/Users/daniel/Development/legend/frontend/src/lib/shell/acpSession.svelte.ts`, 77 lines — port the pattern to our API):

```typescript
export type AcpItem = { seq?: number; id: string; type: string; [k: string]: unknown };

export class AgentSessionStore {
  items: AcpItem[] = $state([]);
  status = $state<'connecting' | 'running' | 'exited' | 'failed' | 'ended'>('connecting');
  busy = $state(false);
  error = $state<string | null>(null);
  // #byId Map, #cursor; upsert(item, seq?) dedups on seq <= cursor && known id,
  // busy flips false on type === 'turn', rebuild sorts by seq.
  // constructor(id) joins via joinAgentSession(id): on 'ok' feeds reply.items
  // through upsert, sets cursor, THEN busy from reply.busy, status from reply.status.
  // channel.on('event'|'status'|'exit') -> upsert / status / status='exited'.
  // prompt(text) pushes 'prompt' + busy=true; cancel(); answerPermission(itemId, kind);
  // setConfigOption(configId, value); stop(); dispose() leaves the channel.
}
```

- `QueueStore`: `items` from `listQueueItems`, `detail(runId)` via `getQueueItem`, `approve(runId, revision)` / `reject(runId, revision)` passing `workspaceStore.generation`, refetch on `queue_changed` (wire the event listener where `icm_changed` is wired — find `wireIcmEvents` in `frontend/src/lib` and add `wireQueueEvents` beside it, same idempotent pattern).
- `WorkflowsStore`: `list` via `listWorkflows`, refetch on `icm_changed` (workflow pages are ICM pages).
- `SessionsListStore`: `sessions` via `listAgentSessions`, `refresh()`.

**Steps:** TDD with vitest fakes (mirror `page-editor.test.ts` fake-channel style — read it first): upsert dedup below cursor; replay merge idempotent on rejoin; busy falling edge on turn item; busy seeds from join reply LAST; permission answer resolves optimistically only on server echo (no local mutation). Implement, `bun run test && bun run check`, commit:

```bash
git add frontend/src/lib
git commit -m "feat(frontend): agent session store, queue/workflows stores, live queue events"
```

---

### Task 17: Chat transcript components (Paper & ink)

**Files:**
- Create under `frontend/src/lib/components/agent/`: `Transcript.svelte`, `MessageItem.svelte`, `ThoughtItem.svelte`, `ToolCallCard.svelte`, `PermissionCard.svelte`, `PlanBar.svelte`, `UsageLine.svelte`, `Composer.svelte`, `ConfigChip.svelte`, `index.ts`
- Donors (read for structure, REWRITE in our idiom — Svelte 5 runes, shadcn-svelte primitives, Paper & ink tokens; do not copy legend CSS): `/Users/daniel/Development/legend/frontend/src/lib/components/sessions/AcpConversation.svelte` and `acp-parts/*`

**Interfaces:**
- `Transcript.svelte` props: `{ store: AgentSessionStore }` — iterates `store.items` keyed by `item.id`, dispatching: `message` role user → right-aligned bubble, green fill `--act` bg + white text, radius 14/14/4/14 (§9); `message` assistant → card surface, mirrored radius; `thought` → collapsed-by-default strip, ink-meta italic, "Thinking" overline; `tool` → `ToolCallCard`; `permission` → `PermissionCard`; `turn` → subtle hairline + stop-reason meta ONLY when stop_reason != "end_turn"; `plan`/`config`/`usage`/`commands`/`meta`/`session_info` are NOT rendered inline (plan → PlanBar dock, usage → UsageLine, config → Composer chips).
- ALL text via `{item.text}` interpolation. `{@html}` is forbidden (Global Constraints) — repeat this in a component comment.
- `ToolCallCard`: kind label (mono, 10.5px, `--ink-meta`), title, status glyph (running: pulsing dot `--suggest`; completed: check `--ok`; failed: `--warn-ink`), optional diff block (old lines `--warn-ink` bg tint, new lines green tint, mono 11px, `overflow-x: auto`), output `<pre>` capped height 200px with scroll.
- `PermissionCard`: §6 consequence styling — card with `--suggest-bg` ground, amber border; title + command line (mono); two buttons from `item.options` by kind: allow_once → secondary-outline "Allow once", reject_once → terracotta-outline "Don't allow"; NEVER a green fill here. Resolved state: 0.75 opacity receipt line "Allowed once · 14:02" / "Not allowed". Callback prop `onAnswer(kind)`.
- `Composer`: textarea (autogrow, max 8 lines), Enter sends / Shift+Enter newline, disabled+"Working…" while `store.busy`; ConfigChips row from `store.items` type config; quiet cancel link while busy ("Stop"). Callback prop `onSend(text)`.
- `PlanBar`: sticky above composer when a plan item exists: "n of m done · current step title", expandable checklist.
- `UsageLine`: quiet ink-meta line under the transcript when a usage item exists (tokens used — render the fields present, no invented math).

**Steps:** build components; add a vitest render smoke test for Transcript dispatch (one item of each type renders its component — use `@testing-library/svelte` if already a devDependency, else a plain mount smoke via `svelte` server-side render is fine; match how existing component tests are done, if none exist keep to `bun run check` + the route-level verification in T18). Run `bun run check`. Commit:

```bash
git add frontend/src/lib/components/agent
git commit -m "feat(frontend): agent transcript components in Paper & ink"
```

---

### Task 18: Chat route + sessions list + doctor screen

**Files:**
- Create: `frontend/src/routes/chat/+page.svelte` (replace the Phase-1 stub — find it under `frontend/src/routes/(stubs)/` and MOVE the route out of the stubs group)
- Create: `frontend/src/lib/components/agent/DoctorPanel.svelte`
- Modify: `frontend/src/lib/shell/nav.ts` if the Chat nav entry points at a stub path

**Behavior (all of it):**
- Layout: `AppShell` with `ListPane` (sessions) + main (transcript or empty state).
- ListPane: sessions from `SessionsListStore` — live sessions first (green `--ok` dot), then ended (0.75 opacity), workflow runs get a small mono badge with the workflow name; row shows title + started_at (relative). "New session" quiet button at the bottom → `createAgentSession('chat', generation)` → navigate to `/chat?session=<id>`.
- Main: no session selected → `EmptyState` ("Talk to your assistant about the business — everything it knows is a file in your folder.") with a "Start a session" primary and a quiet "Run checks" link → DoctorPanel.
- Session selected (`?session=` param): instantiate `AgentSessionStore(id)` ($effect with cleanup calling dispose), render `Transcript` + `PlanBar` + `UsageLine` + `Composer`. Ended sessions: transcript read-only, composer replaced by a quiet line "This session has ended." + secondary button "Start a follow-up session" (creates a new chat session).
- Session creation failing with `harness_unavailable` → render `DoctorPanel` inline instead of the transcript.
- `DoctorPanel.svelte`: calls `harnessDoctor` on mount and on "Check again"; three §8-style rows: check name, status glyph (ok green check / failed terracotta / unknown amber "?"), detail sentence, and when failed a mono copyable command block (a small copy button using `navigator.clipboard.writeText`). Calm copy, no exclamation marks: "Valea uses your own Claude Code. Nothing to configure in here — sign in once in a terminal and check again."
- Permission cards wire `onAnswer` → `store.answerPermission(item.id, kind)`.

**Steps:** implement; verify with the dev stack: `just dev`, open the Chat route, and — with the real adapter installed and authenticated (`claude-agent-acp` on PATH; run the doctor first) — hold a short conversation asking about an ICM page; verify a tool-call card appears. If the machine lacks the adapter/auth, verify the DoctorPanel path renders the remedies instead and note it in the report. `bun run check` green. Commit:

```bash
git add frontend/src
git commit -m "feat(frontend): chat route with live sessions, transcript, doctor flow"
```

---

### Task 19: Today approval flow + queue review route

**Files:**
- Modify: `frontend/src/routes/+page.svelte` (Today) and the today components under `frontend/src/lib/components/today/`
- Create: `frontend/src/routes/queue/[run_id]/+page.svelte`
- Create: `frontend/src/lib/components/queue/ApprovalCard.svelte`, `frontend/src/lib/components/queue/DraftReview.svelte`

**Behavior:**
- Today (read the existing page first; it renders seeded cockpit cards): the Priya inquiry card gains a primary quiet action **"Prepare a reply"** → `runWorkflow('icm/Workflows/New Inquiry Triage.md', 'sources/mail/normalized/priya-nair-inquiry.json', generation)` → card switches to an in-progress state: amber "PREPARING" badge, one-line status, link "Watch the assistant work →" to `/chat?session=<session_id>`. On `queue_changed` with a pending item whose `workflow` matches, the in-progress card is replaced by `ApprovalCard`.
- `ApprovalCard` (§6 approval family): kind badge "REPLY DRAFTED" (green tint), title, summary, source chips (dot colors: terracotta for `sources/mail/*`, green for `icm/Clients/*`, amber for other `icm/*` — a small `sourceDot(path)` helper), risk hint, and ONE primary action: **"Review the draft →"** (green link-style, NOT approve — spec: approval is never available from the summary alone) → `/queue/<run_id>`. Quiet meta "Why this? →" → `/chat?session=<session_id>` (session_id comes from the envelope via getQueueItem — pass run_id and let the review route resolve).
- `/queue/[run_id]`: loads `getQueueItem`; `DraftReview` shows the FULL draft: To, Subject (§8 label/value rows), body rendered as plain preformatted text (NOT markdown-rendered — untrusted; mono is wrong for an email though: use body font, `white-space: pre-wrap`), sources list (clickable chips → Knowledge pages / raw), reasoning quote (italic serif, §10 verbatim style). Actions row: **"Approve — put in my drafts"** (green fill) and **"Don't send this"** (secondary outline; terracotta only if it deleted something — it does not, so outline neutral), both passing `revision` + `generation`. Success → quiet receipt line replacing the buttons ("In your drafts · 14:02 · sources/mail/drafts/<run_id>.md" mono path) ; `queue_item_changed` → calm inline sentence "This item changed since you opened it." with a "Reload" quiet button; `queue_item_gone` → "Already handled." + link back to Today.
- Invalid items (`valid: false`) on Today render a muted card: "The assistant produced something I couldn't read." + mono path + "Open the file" (raw view is out of scope for JSON — link opens nothing this phase; show the path only).

**Steps:** implement; vitest for `sourceDot` helper + queue store approve error mapping (if not covered in T16); manual verify (dev stack + real adapter, or by hand-crafting a valid `queue/pending/<id>.json` file in the dev workspace and watching it appear via `queue_changed` — document which path you used in the report). `bun run check` green. Commit:

```bash
git add frontend/src
git commit -m "feat(frontend): today approval flow with full-draft review gate"
```

---

### Task 20: Workflows route + Audit route

**Files:**
- Create: `frontend/src/routes/workflows/+page.svelte` (replace stub, move out of `(stubs)`)
- Create: `frontend/src/routes/audit/+page.svelte` (replace stub)
- Create: `frontend/src/lib/components/workflows/WorkflowCard.svelte`

**Behavior:**
- Workflows: grid/stack of `WorkflowCard`s from `WorkflowsStore` — name (Newsreader page-title style small), description, trigger chip (mono `trigger_source`), risk badge (green low / amber medium / terracotta-tint high), source count chip, §11 numbered step timeline from `steps` (24px ink circles on a 1.5px guide, the LAST step is the only green circle — the approval step; if steps are empty render nothing), enabled state: disabled cards at 0.75 opacity with a neutral "NOT ACTIVE YET" badge. Card footer: "Edit →" links to `/knowledge/Workflows/<name>.md` (the existing Knowledge page route), quiet mono "open the raw file" hint text (the Knowledge raw toggle is one click further — no new machinery).
- Audit: reverse-chron receipt rows (§8 dense): icon/dot by type (permission_* amber, item_approved/action_executed green, item_rejected neutral ink, workflow_run_* ink), a PLAIN SENTENCE per entry type (write a `sentence(entry)` helper covering every audit type from T5/T11/T12/T13 — e.g. `item_approved` → "You approved '<title>' — draft created.", `permission_auto_allowed` → "Read allowed by policy: <title>."), timestamp right-aligned, and when the entry carries `session_id` a quiet "transcript →" link to `/chat?session=<id>`, when `run_id` a "review →" link to `/queue/<run_id>`. Load via `listAuditEntries(200)`; refetch on `queue_changed`.

**Steps:** implement; `bun run check`; vitest for `sentence()` covering all entry types. Commit:

```bash
git add frontend/src
git commit -m "feat(frontend): workflows contract cards and audit receipts"
```

---

### Task 21: Workspace switcher + dirty-editor guard

**Files:**
- Modify: `frontend/src/lib/components/shell/Sidebar.svelte` (+ a new `WorkspaceSwitcher.svelte` beside it)
- Modify: `frontend/src/lib/stores/workspace.svelte.ts` (`switchTo(path)`)
- Modify: `frontend/src/lib/stores/page-editor.svelte.ts` (stale-workspace guard)
- Test: extend `frontend/src/lib/stores/workspace.test.ts` + `page-editor.test.ts`

**Behavior:**
- `WorkspaceSwitcher.svelte`: the current workspace name (basename of path), placed above the `StatusPill`, mono 11px, with a chevron; opens a shadcn DropdownMenu: recent workspaces (name + dimmed path, current one checked), separator, "Open another folder…" → a small inline form (path input + Open button — the same mechanism onboarding uses; read `Onboarding.svelte` and reuse its input pattern or extract a tiny shared component if trivial).
- `workspaceStore.switchTo(path)`:
  1. Ask the active page editor to settle: call the SAME exported hook the knowledge route registered for pre-mutate flushes (find `onBeforeMutate`/`before-mutate.ts` from Phase 2 — reuse it directly). A failed flush → abort the switch, surface the existing unsaved-changes message near the switcher (calm sentence, `role="alert"`).
  2. Call `openWorkspace(path)`; on success the existing workspace event resets stores (Phase-1 machinery) and `generation` updates.
- `page-editor.svelte.ts`: capture the workspace generation at page load; the debounced save callback aborts (state stays dirty, error surfaced) when `workspaceStore.generation` no longer matches — the backend `workspace_changed` rejection is the backstop (save_icm_page now takes generation, T15... NOTE: T15's list did not include save_icm_page — ADD IT THERE: `save_icm_page` gains an optional `generation` argument, nil = skip check for backward compat during the transition, and the editor always passes it. If you are implementing this task and T15 shipped without it, make the backend+codegen change here with the same pattern and regenerate).
- Vitest: switch with a clean editor proceeds; switch with a dirty editor that flushes OK proceeds; failed flush aborts with error; stale-generation save aborts locally.

**Steps:** TDD on the stores, then the component; `bun run check && bun run test`; manual dev verification: create a second workspace via onboarding path, switch back and forth, tree/Today swap cleanly. Commit:

```bash
git add frontend/src backend frontend/src/lib/api
git commit -m "feat: workspace switcher with dirty-editor flush guard and stale-save rejection"
```

---

### Task 22: Docs + acceptance pass

**Files:**
- Modify: `docs/VISION.md` (principle 3 wording; principle 5 file-first rationale; roadmap: mark Phase 3 shipped-pending-merge, reword items 4–5 as sync-to-files engines, add ICM mounts item)
- Modify: `docs/ARCHITECTURE.md` (agent runtime, permission model + trust model, queue/audit flow, control-plane auth, workspace runtime/generations, ICM layer mapping table incl. `icm/Workflows` as Valea adaptation)
- Modify: `README.md` if it lists workspace layout (workflows/ → icm/Workflows/, AGENTS.md)

**Acceptance checklist (spec §Testing — run ALL, document results in the ledger):**
1. Doctor: rename the adapter binary away → doctor shows failed adapter with the npm remedy; restore; log out state (if testable) or verify auth probe returns ok/unknown honestly.
2. Live chat (real adapter, dev stack): ask "What does the Founder Coaching Package cost?" — agent reads ICM pages (tool-call card), answers; attempt to make it read `secrets/` (ask it to) — denied (deny decision in audit log, no card).
3. Priya end-to-end (dev stack): Today → Prepare a reply → watch transcript → pending item → approval card → Review the draft → full to/subject/body visible → Approve → `sources/mail/drafts/<run_id>.md` exists, item in `approved/`, audit chain complete INCLUDING `approval_intent` before `action_executed`.
4. Chat write test: ask the agent in chat to write a file into `icm/` → permission card appears (chat has no write root); answer "Don't allow"; verify audit.
5. Restart the backend (`just dev` restart) → Chat lists the prior sessions; opening one replays the transcript read-only.
6. Switch workspace with a dirty editor → flush-or-block behavior; after switch, old workspace's sessions/queue processes are gone (`:observer` or list_sessions returns the new workspace's sessions only).
7. Packaged .app: `just package-backend && just desktop-bundle`, launch, run a real chat turn inside the packaged app (adapter + auth present), quit → `pgrep -f claude-agent-acp` and `pgrep -f exec-port` both empty.
8. `just test` fully green (backend suite, codegen staleness gate, svelte-check, vitest).

Steps: update docs, run the checklist, fix anything it surfaces (each fix its own commit), final commit:

```bash
git add docs README.md
git commit -m "docs: phase 3 — agent slice architecture, vision amendments"
```

---

## Execution notes for the controller

- Tasks 1–3 are sequential foundations. 4–7 are independent of each other (but all depend on 2–3 landing). 8 → 9 → 10 is a strict chain; 11 slots after 9; 12–13 need 9+11; 14 needs 7; 15 needs 10+12+13+14; 16 needs 15; 17–21 need 16 (17 before 18). 22 last. Dispatch strictly sequentially regardless (SDD rule: one implementer at a time).
- Model guidance: T1 opus (packaging risk), T2/T3 sonnet, T4/T5 sonnet, T6 opus (three-surface security change), T7 haiku-to-sonnet, T8 opus (protocol subtlety), T9 opus, T10 sonnet, T11 opus (security), T12/T13 sonnet, T14 haiku-to-sonnet, T15 sonnet, T16 sonnet, T17/T18 sonnet, T19/T20 sonnet, T21 sonnet, T22 sonnet. Reviews: opus for T6/T8/T9/T11/T13, sonnet elsewhere; final whole-branch review on the most capable model.
- The fake adapter grows scenarios in T12 (`workflow_happy`) — implementers extending it must keep existing scenarios untouched.
- Donor repos are READ-ONLY (`/Users/daniel/Development/legend`).
