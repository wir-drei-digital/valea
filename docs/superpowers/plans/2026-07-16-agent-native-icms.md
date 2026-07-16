# Agent-Native ICMs (Spec D) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Delete the workflow/queue subsystem, replace "run" with one session-with-context primitive, render Today from `today.json` files agents maintain, and remove every structural assumption real ICMs violate (spec: `docs/superpowers/specs/2026-07-16-agent-native-icms-design.md`).

**Architecture:** Valea becomes cockpit + guardrails + building blocks. The agent interprets ICM prose; Valea supplies containment (`Valea.Paths.resolve_real/2` everywhere), identity (`icm.yaml`), approval-by-ask (`PermissionPolicy` + managedSettings), sync, and UI that renders what the files say. Deletions run first (FE surfaces → backend queue → today.json rewrite → backend workflows), each leaving the whole repo green including codegen freshness; additions (session primitive, riders) follow.

**Tech Stack:** Elixir 1.20/Phoenix 1.8/Ash 3 + ash_typescript codegen (backend), SvelteKit static SPA with Svelte 5 runes + Bun + vitest (frontend).

## Global Constraints

- Product contract (spec, verbatim): "A Valea workspace is a private local operational profile. An ICM is a portable user-owned context project whose internal structure belongs to the user and their agent — Valea never requires reserved folders, frontmatter contracts, or schemas inside it. Every agent session runs inside exactly one primary ICM with only the context the ICM or task explicitly names, and every side effect passes through the live permission ask-gate. Valea's UI renders what the files say."
- Every path decision goes through `Valea.Paths.resolve_real/2` with segment-boundary membership checks. Never weaken the permission boundary.
- No prod users: deletions are clean cuts with test updates, no migrations, no backwards compatibility. Historical audit lines from deleted flows remain on disk; the audit renderer treats unknown types leniently (generic humanized sentence, never a crash).
- Deletion completeness bar (same as Phase 11): repo greps for removed module/function names must return zero hits in `backend/lib`, `backend/test`, `frontend/src` (docs/specs hits are fine).
- After ANY RPC surface change: run `cd backend && mix ash_typescript.codegen` and commit the regenerated `frontend/src/lib/api/ash_rpc.ts` + `frontend/src/lib/api/ash_types.ts` in the same commit. `just test` fails on stale codegen.
- Test commands: `cd backend && mix test` · `cd frontend && bun run test` · `cd frontend && bun run check`. Full gate: `just test` from repo root.
- `frontend/src/lib/api/client.ts` is the ONLY module allowed to import `./ash_rpc` (grep-able boundary — keep it that way).
- Valea itself never writes `today.json`; agents (and later Spec-F scripts) do.
- ICM-internal secrets are DENY (auto `reject_once`), not ask — mirrors the workspace-protected tier.
- Every commit message ends with the trailer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- NEVER push to origin. All work stays local.
- Backend maps returned by generic `:map` actions stay STRING-keyed when any field can be a legitimate `false` (ash_typescript 0.17.3 nulls a top-level atom-keyed `false` — see `Valea.Api.Agents.harness_doctor`'s comment). `Valea.Cockpit.today/0` already returns string keys throughout; keep that.

## Task order rationale

FE deletions go first (T1) so backend RPC removals (T2, T4) can regenerate the TS client without breaking `bun run check`. The Today rewrite (T3) precedes the workflows-module deletion (T4) because `Valea.Cockpit` still calls `Valea.Workflows.*` until T3 replaces it. Riders and the session primitive follow; docs and the final grep gate close.

---

### Task 1: Frontend deletion wave — workflows, queue, triage, distill surfaces

**Files:**
- Create: `frontend/src/lib/shell/provenance.ts` (relocated `mountProvenanceLabel`)
- Delete (each with its test file where one exists):
  - `frontend/src/routes/workflows/+page.svelte`
  - `frontend/src/routes/queue/[run_id]/+page.svelte` (delete the whole `frontend/src/routes/queue/` directory)
  - `frontend/src/lib/components/workflows/WorkflowCard.svelte`
  - `frontend/src/lib/components/workflows/workflowHref.ts` + `workflowHref.test.ts` (AFTER relocating `mountProvenanceLabel`; delete the now-empty `components/workflows/` dir)
  - `frontend/src/lib/stores/workflows.svelte.ts` + `frontend/src/lib/stores/workflows.test.ts`
  - `frontend/src/lib/stores/queue.svelte.ts` + `frontend/src/lib/stores/queue.test.ts`
  - `frontend/src/lib/components/mail/triage-workflows.ts` + `.test.ts`
  - `frontend/src/lib/today/distill.ts` + `frontend/src/lib/today/distill.test.ts`
  - `frontend/src/lib/components/today/InquiryTriageCard.svelte`, `frontend/src/lib/components/today/triage-card.ts` + `triage-card.test.ts`, `frontend/src/lib/components/today/PreparedItemCard.svelte`
  - `frontend/src/lib/components/queue/` — the entire directory: `ApprovalCard.svelte`, `MemoryUpdateReview.svelte`, `DraftReview.svelte`, `QueueSourceChips.svelte`, `memory-review.ts` + test, `queue-ops.ts` + test, `sourceDot.ts` + test
- Modify:
  - `frontend/src/lib/shell/nav.ts:64` (drop Workflows nav item + `RefreshCw` import at `:7`) + `frontend/src/lib/shell/nav.test.ts`
  - `frontend/src/lib/shell/icm-route.ts:53,76` (doc comments naming `/workflows`) + `frontend/src/lib/shell/icm-route.test.ts:58-60` (retarget the `?icm` case to `/knowledge`)
  - `frontend/src/lib/components/shell/IcmProjects.svelte:196-199` (drop "Show workflows" kebab item + `RefreshCw` import at `:25`) + `frontend/src/lib/components/shell/icm-projects.test.ts`
  - `frontend/src/lib/stores/icm.svelte.ts` (drop `workflowsStore` import at `:9` and `workflowsStore.refetch()` at `:352`; drop `wireQueueEvents` import at `:5` and its call at `:356`; update the `:253-263` comment block)
  - `frontend/src/lib/stores/audit.svelte.ts:40-60` (drop the `queue_changed` listener wiring — audit refetches on route load; the backend event dies in Task 2)
  - `frontend/src/lib/components/audit/sentence.ts` (drop cases `workflow_run_started`, `workflow_run_finished`, `queue_item_created`, `approval_intent`, `item_approved`, `item_rejected`, `action_executed`, `approval_recovered`; drop helpers `basename`/`workflowName` at `:45-67` and `reviewHref` at `:173-177`; drop the workflow/target branches of `auditIcmId` at `:214-231`; KEEP the `default:` humanize fallback at `:144-147`, the `permission_*` cases, `session_exited`, and `auditDot`'s neutral fallback) + rewrite `sentence.test.ts` (drop workflow/queue cases; keep/add: unknown type → humanized sentence, blank type → "Unrecognized event.", permission cases unchanged)
  - `frontend/src/lib/components/audit/AuditRow.svelte:14,37` (import `mountProvenanceLabel` from `$lib/shell/provenance`; drop `reviewHref` usage)
  - `frontend/src/lib/components/mail/MessageView.svelte` (drop the whole Run-triage action block at `:199-243` except the outer `<div>` wrapper and the `Processed` badge branch — Task 11 fills the empty branch; drop `runTriage` at `:107-122`, the `candidates` prop, the `TriageCandidate` type import at `:51`, and `canRunTriage` usage)
  - `frontend/src/lib/components/mail/mail-shapes.ts` (drop `canRunTriage`) + `frontend/src/lib/components/mail/mail-components.test.ts`
  - `frontend/src/routes/mail/+page.svelte:18,34,188` (drop triage-workflows import + `candidates` wiring)
  - `frontend/src/routes/+page.svelte` (drop imports/usages of `InquiryTriageCard`, `PreparedItemCard`, `queueStore`, distill state/handlers/buttons at `:13,45-47,136-152,237-261`; keep the page rendering the REMAINING seeded payload — `ScheduleList`, `OpenLoops`, `AwayList`, mail summary line — Task 3 replaces the page wholesale)
  - `frontend/src/lib/api/client.ts` (drop the handwritten wrappers + `fields` consts + type imports + channel helpers for: `runWorkflow` `:1276-1297`, `distillDecisions` `:1299-1306`, `listWorkflows` `:1311-1312`, `listQueueItems` `:1314-1317`, `getQueueItem` `:1319-1329`, `approveQueueItem` `:1331-1338`, `rejectQueueItem` `:1340-1351`, `listDecidedQueueItems` `:1423-1426`, `retryMailboxOps`; line numbers are pre-edit anchors — grep each name) + `client.test.ts` fixtures referencing `Workflows/…` paths
- Test: run the full FE suite; the generated `ash_rpc.ts` still exports the RPC functions until Tasks 2/4 regenerate it — that is expected and fine (nothing imports them anymore).

**Interfaces:**
- Consumes: nothing from other tasks (first task).
- Produces: `mountProvenanceLabel(mount: string | null | undefined): string` in `frontend/src/lib/shell/provenance.ts` — moved VERBATIM from `workflowHref.ts` (same signature, same behavior, its `workflowHref.test.ts` cases for it move to a new `provenance.test.ts`). Task 3's Today page and the surviving `AuditRow.svelte` import it from there.

**Steps:**

- [ ] **Step 1: Relocate `mountProvenanceLabel`.** Create `frontend/src/lib/shell/provenance.ts` containing the `mountProvenanceLabel` function copied verbatim from `frontend/src/lib/components/workflows/workflowHref.ts`, with its doc comment. Create `frontend/src/lib/shell/provenance.test.ts` by moving the `mountProvenanceLabel` describe block verbatim from `workflowHref.test.ts` (adjust the import path only). Update `AuditRow.svelte:14` to import from `$lib/shell/provenance`.

- [ ] **Step 2: Run the moved test.**
Run: `cd frontend && bun run test -- provenance`
Expected: PASS (the moved cases).

- [ ] **Step 3: Delete the workflow/queue surfaces.** Delete every file in the Delete list above. Apply every Modify above. Where a modify step removes a component usage, remove the corresponding import too. `MessageView.svelte`'s actions area keeps this exact interim shape:

```svelte
<div class="border-paper-hairline flex flex-wrap items-center gap-2.5 border-t pt-4">
  {#if status === 'processed'}
    <span class="text-ink-meta text-[11px] tracking-[0.08em] uppercase">Processed</span>
  {/if}
</div>
```

- [ ] **Step 4: Grep for stragglers.**
Run (from repo root):
```bash
grep -rn "WorkflowCard\|workflowEditHref\|workflowsStore\|triageCandidates\|queueStore\|wireQueueEvents\|buildMemoryReview\|distillButtonState\|InquiryTriageCard\|PreparedItemCard\|ApprovalCard\|MemoryUpdateReview\|runWorkflow\|listWorkflows\|distillDecisions\|listQueueItems\|approveQueueItem\|rejectQueueItem\|listDecidedQueueItems\|retryMailboxOps\|canRunTriage\|reviewHref" frontend/src --include="*.ts" --include="*.svelte" | grep -v "lib/api/ash_rpc.ts" | grep -v "lib/api/ash_types.ts"
```
Expected: zero lines (generated files excluded until Tasks 2/4 regenerate them).

- [ ] **Step 5: Run the FE suite.**
Run: `cd frontend && bun run check && bun run test`
Expected: 0 errors, all tests pass (test count drops — that is the deletion).

- [ ] **Step 6: Commit.**
```bash
git add -A frontend
git commit -m "feat(frontend)!: delete workflow/queue/triage/distill surfaces (Spec D §A)"
```

---

### Task 2: Backend queue + MailboxOps deletion, audit RPC relocation

**Files:**
- Delete: `backend/lib/valea/queue.ex`, `backend/lib/valea/api/queue_api.ex`, `backend/lib/valea/mail/mailbox_ops.ex`, `backend/lib/valea/mail/draft_mime.ex`, `backend/test/valea/queue_test.exs`, `backend/test/valea_web/queue_rpc_test.exs`, `backend/test/valea/mail/mailbox_ops_test.exs`, the DraftMime test file if one exists (`ls backend/test/valea/mail/`), `backend/priv/workspace_template/queue/` (whole tree)
- Create: `backend/lib/valea/api/audit.ex`
- Modify: `backend/lib/valea/api.ex` (`:50-57` Queue rpc block, `:88` resource registration → replace with the Audit resource), `backend/lib/valea/api/mail.ex:284` (drop `retry_mailbox_ops` action) + its decl `backend/lib/valea/api.ex:69`, `backend/lib/valea/mail/engine.ex` (drop `alias Valea.Mail.MailboxOps` `:64`, `alias Valea.Queue` `:69` if Queue-only, the `"mail_ops"` PubSub subscribe `:180`, `handle_info({:mailbox_ops_pending, ...})` `:257` + `handle_info({:mailbox_ops_updated, ...})` `:262`, `recover_mailbox_ops` call `:319` + defn `:329-341`, `execute_ops`/`clear_ops_task` `:373-395`, the `ops_tasks` state field + its init + any `:DOWN` handling that only served ops tasks), `backend/lib/valea_web/channels/workspace_events_channel.ex` (drop the `"queue"` and `"mail_ops"` PubSub subscribes and the `{:queue_changed}`/`{:mailbox_ops_updated}`/`{:mailbox_ops_pending}` handle_infos `:42-45,67-76`), `backend/lib/valea/icm/watcher.ex` (drop `queue/` from `fixed_dirs/1` `:329`, the `:queue` branch of `classify_path/2` `:234`, the `:flush_queue` handler `:227-230` + its timer state), `backend/lib/valea/workspace/runtime.ex:22` (drop the `Valea.Queue.recover(root)` line — keep the boot task with `Runner.recover_staging` until Task 4), `backend/lib/valea/workspace/scaffold.ex:14` (drop `queue` + `queue/staging` + `queue/processing` from `@marker_dirs`)
- Test: `backend/test/valea/mail/engine_test.exs` (delete `EngineMailboxOpsTest` `:669,709,939` + `mailbox_ops` assertions), `backend/test/valea/workspace/scaffold_test.exs` (drop queue-dir assertions), `backend/test/valea/icm/watcher_test.exs` (drop `queue_changed` cases), plus a new `backend/test/valea_web/audit_rpc_test.exs` if `list_audit_entries` coverage currently lives only in `queue_rpc_test.exs` (move those test cases, don't lose them)

**Interfaces:**
- Consumes: Task 1 (no FE code references the removed RPCs).
- Produces: `Valea.Api.Audit` — a data-layer-less Ash resource whose `:list_audit_entries` action is the EXACT action block currently in `backend/lib/valea/api/queue_api.ex` (the one calling `Valea.Audit.entries/1` at `queue_api.ex:157`), moved verbatim with any private helpers it uses. External RPC name stays `list_audit_entries`, so the generated `listAuditEntries` TS function and the FE wrapper keep working unchanged.

**Steps:**

- [ ] **Step 1: Move the audit RPC.** Create `backend/lib/valea/api/audit.ex`:

```elixir
defmodule Valea.Api.Audit do
  @moduledoc """
  Data-layer-less Ash resource exposing the audit log over RPC.

  Relocated from the deleted `Valea.Api.Queue` (Spec D §A): `Valea.Audit`
  is queue-independent (a `Valea.Workspace.Runtime` child writing
  `logs/audit.jsonl`), so its RPC surface survives the queue deletion.
  """
  use Ash.Resource, domain: Valea.Api, extensions: [AshTypescript.Resource]

  typescript do
    type_name("Audit")
  end

  actions do
    # Moved VERBATIM from Valea.Api.Queue (queue_api.ex): the
    # :list_audit_entries action block and any private helpers it calls.
  end
end
```

Copy the `:list_audit_entries` action block (its `constraints fields:`, arguments, and `run fn`) verbatim from `queue_api.ex` into the `actions do` block, plus any private helper functions it references (check the `run fn` body — copy those too). In `backend/lib/valea/api.ex`: replace the whole `resource Valea.Api.Queue do ... end` block (lines 50-57) with:

```elixir
    resource Valea.Api.Audit do
      rpc_action(:list_audit_entries, :list_audit_entries)
    end
```

and replace `resource Valea.Api.Queue` at `:88` with `resource Valea.Api.Audit`.

- [ ] **Step 2: Delete queue/MailboxOps/DraftMime and unwire.** Delete the files in the Delete list; apply every Modify. In `engine.ex`, after removing the ops plumbing, verify no other code used `state.ops_tasks` (grep `ops_tasks` within the file — zero after the edit).

- [ ] **Step 3: Update tests.** Delete/trim the test files listed above. Move any `list_audit_entries` RPC test cases from the deleted `queue_rpc_test.exs` into `backend/test/valea_web/audit_rpc_test.exs` (same assertions, new file).

- [ ] **Step 4: Grep for stragglers.**
Run:
```bash
grep -rn "Valea\.Queue\|MailboxOps\|DraftMime\|queue_changed\|mail_ops\|retry_mailbox_ops" backend/lib backend/test
```
Expected: zero lines. (`Valea.Workflows.Runner` still writes `queue/pending` paths internally — those greps hit `runner.ex`, which Task 4 deletes; if this grep shows ONLY `backend/lib/valea/workflows/` hits for `queue`, that is acceptable here — re-run the exact grep above, which targets the module names, not the word "queue".)

- [ ] **Step 5: Regenerate codegen + run suites.**
Run: `cd backend && mix ash_typescript.codegen && mix test`
Expected: all backend tests pass; `frontend/src/lib/api/ash_rpc.ts` no longer contains `listQueueItems`/`approveQueueItem`/`rejectQueueItem`/`getQueueItem`/`listDecidedQueueItems`/`retryMailboxOps` but still contains `listAuditEntries`.
Run: `cd frontend && bun run check && bun run test`
Expected: green (Task 1 already removed all FE consumers).

- [ ] **Step 6: Commit.**
```bash
git add -A backend frontend/src/lib/api
git commit -m "feat(backend)!: delete Valea.Queue + MailboxOps + DraftMime; relocate audit RPC (Spec D §A)"
```

---
### Task 3: Today = `today.json` — backend cockpit + API + frontend page

**Files:**
- Modify: `backend/lib/valea/cockpit.ex` (full rewrite), `backend/lib/valea/api/cockpit.ex` (full rewrite of the `:today` constraints), `backend/test/valea/cockpit_test.exs` (keep the mail describes, replace everything else), `backend/test/valea_web/rpc_test.exs` (cockpit payload assertions)
- Modify (FE): `frontend/src/lib/today/cockpit.ts` (full rewrite) + `frontend/src/lib/today/cockpit.test.ts`, `frontend/src/routes/+page.svelte` (full rewrite of the content area)
- Delete (FE): `frontend/src/lib/components/today/ScheduleList.svelte`, `frontend/src/lib/components/today/AwayList.svelte`, `frontend/src/lib/components/today/SourceChips.svelte` (verify with grep that its only remaining consumers were the cards Task 1 deleted; if anything else imports it, keep it), keep `frontend/src/lib/components/today/OpenLoops.svelte` (reused — its item shape `{title, source}` matches the new payload)
- Codegen: regenerate after the API change

**Interfaces:**
- Consumes: `mountProvenanceLabel` from `$lib/shell/provenance` (Task 1); `knowledgeHref(mountKey, path)` from `$lib/shell/nav` (existing).
- Produces: `Valea.Cockpit.today/0` returning `{:ok, %{"sections" => [...], "mail" => %{...}, "recent_sessions" => [...]}}` (string keys throughout); FE `normalizeCockpitToday(raw): CockpitToday` with `CockpitToday = { sections: TodaySection[]; mail: MailSummary; recentSessions: RecentSession[] }`. Task 4 relies on `Valea.Cockpit` no longer referencing `Valea.Workflows`.

**Contract (spec §C):** `today.json` at an ICM's root, lenient schema, all fields optional, unknown fields ignored:
```json
{
  "updated_at": "2026-07-16T08:00:00Z",
  "prepared": [{ "title": "", "summary": "", "page": "relative/path.md" }],
  "open_loops": [{ "title": "", "source": "" }],
  "notes": ""
}
```
Absent file → the ICM contributes no section. Malformed/unreadable → a section with `"ok" => false` (FE renders a calm "today.json couldn't be read" note). Aggregation follows `Valea.Mounts.enabled/0` order with per-section ICM provenance. Valea never writes the file; changes ride the existing `icm_changed` watcher events.

**Steps:**

- [ ] **Step 1: Write the failing backend tests.** Replace the non-mail parts of `backend/test/valea/cockpit_test.exs` (keep the existing `describe "today/0 mail summary"` block and its setup helpers). Use the existing test-support helpers in this file/`agent_case.ex` for opening a workspace and mounting an ICM (mirror how the deleted triage-path describes created mounts). New cases:

```elixir
describe "today/0 sections" do
  test "no workspace open → empty sections, zero mail, empty recent_sessions" do
    {:ok, today} = Valea.Cockpit.today()
    assert today["sections"] == []
    assert today["recent_sessions"] == []
    assert today["mail"] == %{"review_count" => 0, "inbox_count" => 0, "configured" => false}
  end

  test "enabled ICM without today.json contributes no section" do
    # open workspace + mount one ICM (no today.json written)
    {:ok, today} = Valea.Cockpit.today()
    assert today["sections"] == []
  end

  test "valid today.json becomes a section with provenance" do
    # open workspace + mount ICM at `root`
    File.write!(Path.join(root, "today.json"), ~s({
      "updated_at": "2026-07-16T08:00:00Z",
      "prepared": [{"title": "Prep Lea", "summary": "One page", "page": "clients/lea.md"}],
      "open_loops": [{"title": "Send proposal", "source": "mail"}],
      "notes": "Quiet day.",
      "unknown_field": {"ignored": true}
    }))
    {:ok, %{"sections" => [section]}} = Valea.Cockpit.today()
    assert section["mount_key"] == mount_key
    assert section["icm_name"] == icm_name
    assert section["ok"] == true
    assert section["updated_at"] == "2026-07-16T08:00:00Z"
    assert section["notes"] == "Quiet day."
    assert section["prepared"] == [%{"title" => "Prep Lea", "summary" => "One page", "page" => "clients/lea.md"}]
    assert section["open_loops"] == [%{"title" => "Send proposal", "source" => "mail"}]
    refute Map.has_key?(section, "unknown_field")
  end

  test "malformed JSON → ok false section, never an error" do
    File.write!(Path.join(root, "today.json"), "{not json")
    {:ok, %{"sections" => [section]}} = Valea.Cockpit.today()
    assert section["ok"] == false
    assert section["prepared"] == []
    assert section["open_loops"] == []
  end

  test "lenient field handling: wrong types dropped to nil/[]" do
    File.write!(Path.join(root, "today.json"), ~s({
      "updated_at": 42,
      "prepared": [{"title": "ok", "summary": 7}, "not-a-map"],
      "open_loops": "nope",
      "notes": ["x"]
    }))
    {:ok, %{"sections" => [section]}} = Valea.Cockpit.today()
    assert section["ok"] == true
    assert section["updated_at"] == nil
    assert section["notes"] == nil
    assert section["prepared"] == [%{"title" => "ok", "summary" => nil, "page" => nil}]
    assert section["open_loops"] == []
  end

  test "disabled mount contributes no section; order follows Mounts.enabled/0" do
    # mount two ICMs with today.json each, disable the second,
    # assert exactly one section; re-enable, assert two sections in
    # Mounts.enabled/0 order (compare mount_key lists).
  end
end

describe "today/0 recent_sessions" do
  test "no sessions → []" do
    {:ok, today} = Valea.Cockpit.today()
    assert today["recent_sessions"] == []
  end
  # Sessions require the harness; assert shape indirectly by writing two
  # session/v1 transcript meta lines under <ws>/logs/sessions/ the way
  # backend/test/valea/agents_test.exs fixtures do, then:
  test "newest-first, capped at 5, trimmed fields" do
    # write 6 session meta files with ascending started_at
    {:ok, %{"recent_sessions" => recent}} = Valea.Cockpit.today()
    assert length(recent) == 5
    assert List.first(recent)["started_at"] > List.last(recent)["started_at"]
    assert Map.keys(List.first(recent)) |> Enum.sort() == ["id", "live", "started_at", "status", "title"]
  end
end
```

Fill the setup plumbing by mirroring the existing patterns in this same test file (workspace open + `Valea.Mounts.create/3` or `mount/2` of a tmp ICM) and in `backend/test/valea/agents_test.exs` (session transcript fixtures).

- [ ] **Step 2: Run to verify failure.**
Run: `cd backend && mix test test/valea/cockpit_test.exs`
Expected: FAIL — `today/0` still returns the seeded narrative (no `"sections"` key).

- [ ] **Step 3: Rewrite `Valea.Cockpit`.** Replace `backend/lib/valea/cockpit.ex` with (keep `mail_summary/0`, `live_mail_summary/0`, `zero_mail_summary/0` and their comments VERBATIM from the current file):

```elixir
defmodule Valea.Cockpit do
  @moduledoc """
  The Today cockpit payload: a lenient view over `today.json` files that
  AGENTS maintain (Spec D §C — Valea itself never writes them), merged
  across enabled ICMs in `Valea.Mounts.enabled/0` order with per-section
  provenance, plus the live state Valea owns: mail counts and recent
  sessions. String keys throughout (JSON-ready; also required for
  legitimate `false` values — see `Valea.Api.Agents.harness_doctor`).

  Leniency contract: absent `today.json` → no section for that ICM;
  unreadable/malformed → a section with `"ok" => false` (the FE renders a
  calm note, never an error state); unknown fields ignored; wrong-typed
  fields degrade to nil/[] rather than failing the parse. `today.json`
  changes ride the existing `icm_changed` watcher events — no new
  watcher wiring here.
  """

  def today do
    {:ok,
     %{
       "sections" => icm_sections(),
       "mail" => mail_summary(),
       "recent_sessions" => recent_sessions()
     }}
  end

  defp icm_sections do
    case Valea.Mounts.enabled() do
      {:ok, mounts} -> mounts |> Enum.map(&icm_section/1) |> Enum.reject(&is_nil/1)
      {:error, :no_workspace} -> []
    end
  end

  defp icm_section(mount) do
    base = %{"mount_key" => mount.name, "icm_name" => mount.manifest.name}

    case File.read(Path.join(mount.root, "today.json")) do
      {:error, :enoent} ->
        nil

      {:error, _reason} ->
        unreadable_section(base)

      {:ok, raw} ->
        case parse_today(raw) do
          {:ok, fields} -> base |> Map.put("ok", true) |> Map.merge(fields)
          :error -> unreadable_section(base)
        end
    end
  end

  defp unreadable_section(base) do
    base |> Map.put("ok", false) |> Map.merge(empty_fields())
  end

  defp empty_fields do
    %{"updated_at" => nil, "notes" => nil, "prepared" => [], "open_loops" => []}
  end

  defp parse_today(raw) do
    case Jason.decode(raw) do
      {:ok, %{} = doc} ->
        {:ok,
         %{
           "updated_at" => str_or_nil(doc["updated_at"]),
           "notes" => str_or_nil(doc["notes"]),
           "prepared" => items(doc["prepared"], ["title", "summary", "page"]),
           "open_loops" => items(doc["open_loops"], ["title", "source"])
         }}

      _ ->
        :error
    end
  end

  defp items(list, keys) when is_list(list) do
    list
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn m -> Map.new(keys, fn k -> {k, str_or_nil(m[k])} end) end)
  end

  defp items(_other, _keys), do: []

  defp str_or_nil(v) when is_binary(v), do: v
  defp str_or_nil(_), do: nil

  # Live state Valea owns. `list_sessions/0` degrades to `{:ok, []}`-shaped
  # results without a workspace; anything else degrades to [] here rather
  # than failing the whole cockpit call.
  defp recent_sessions do
    case Valea.Agents.list_sessions() do
      {:ok, sessions} ->
        sessions
        |> Enum.sort_by(&(&1["started_at"] || ""), :desc)
        |> Enum.take(5)
        |> Enum.map(&Map.take(&1, ["id", "title", "started_at", "status", "live"]))

      _ ->
        []
    end
  end

  # ... mail_summary/0, live_mail_summary/0, zero_mail_summary/0 kept
  # verbatim from the previous revision ...
end
```

If `Valea.Agents.list_sessions/0` raises without an open workspace (check its implementation in `backend/lib/valea/agents.ex`), wrap `recent_sessions/0`'s body in the same `rescue`/`catch :exit` pattern `live_mail_summary/0` uses.

- [ ] **Step 4: Rewrite the API constraints.** Replace the `constraints fields:` block of `backend/lib/valea/api/cockpit.ex`'s `:today` action (and trim the moduledoc's Task-history notes down to the new shape):

```elixir
      constraints fields: [
                    sections: [
                      type: {:array, :map},
                      allow_nil?: false,
                      constraints: [
                        items: [
                          fields: [
                            mount_key: [type: :string, allow_nil?: false],
                            icm_name: [type: :string, allow_nil?: false],
                            ok: [type: :boolean, allow_nil?: false],
                            updated_at: [type: :string, allow_nil?: true],
                            notes: [type: :string, allow_nil?: true],
                            prepared: [
                              type: {:array, :map},
                              allow_nil?: false,
                              constraints: [
                                items: [
                                  fields: [
                                    title: [type: :string, allow_nil?: true],
                                    summary: [type: :string, allow_nil?: true],
                                    page: [type: :string, allow_nil?: true]
                                  ]
                                ]
                              ]
                            ],
                            open_loops: [
                              type: {:array, :map},
                              allow_nil?: false,
                              constraints: [
                                items: [
                                  fields: [
                                    title: [type: :string, allow_nil?: true],
                                    source: [type: :string, allow_nil?: true]
                                  ]
                                ]
                              ]
                            ]
                          ]
                        ]
                      ]
                    ],
                    mail: [
                      type: :map,
                      allow_nil?: false,
                      constraints: [
                        fields: [
                          review_count: [type: :integer, allow_nil?: false],
                          inbox_count: [type: :integer, allow_nil?: false],
                          configured: [type: :boolean, allow_nil?: false]
                        ]
                      ]
                    ],
                    recent_sessions: [
                      type: {:array, :map},
                      allow_nil?: false,
                      constraints: [
                        items: [
                          fields: [
                            id: [type: :string, allow_nil?: false],
                            title: [type: :string, allow_nil?: false],
                            started_at: [type: :string, allow_nil?: false],
                            status: [type: :string, allow_nil?: false],
                            live: [type: :boolean, allow_nil?: false]
                          ]
                        ]
                      ]
                    ]
                  ]
```

Note: `ok` and `live` are nested booleans inside string-keyed item maps — the string-keyed source maps are what make a legitimate `false` survive extraction (see the current module's own moduledoc explanation; keep that explanation, updated for `sections[].ok`).

- [ ] **Step 5: Run backend tests + regen.**
Run: `cd backend && mix test test/valea/cockpit_test.exs test/valea_web/rpc_test.exs && mix ash_typescript.codegen`
Expected: PASS after updating `rpc_test.exs`'s cockpit assertions to the new shape; codegen rewrites the `cockpitToday` types.

- [ ] **Step 6: Rewrite the FE cockpit module + tests.** Replace `frontend/src/lib/today/cockpit.ts`:

```ts
/**
 * Types + normalizer for the Spec-D cockpit payload (`cockpit_today` RPC):
 * per-ICM sections read from `today.json` files agents maintain, plus the
 * live state Valea owns (mail counts, recent sessions). The normalizer
 * accepts BOTH snake_case and camelCase keys, same defensive stance the
 * previous revision took toward the generic-action map boundary.
 */
export type TodayPrepared = { title: string | null; summary: string | null; page: string | null };
export type TodayOpenLoop = { title: string | null; source: string | null };
export type TodaySection = {
  mountKey: string;
  icmName: string;
  ok: boolean;
  updatedAt: string | null;
  notes: string | null;
  prepared: TodayPrepared[];
  openLoops: TodayOpenLoop[];
};
export type RecentSession = {
  id: string;
  title: string;
  startedAt: string;
  status: string;
  live: boolean;
};
export type MailSummary = { reviewCount: number; inboxCount: number; configured: boolean };
export type CockpitToday = {
  sections: TodaySection[];
  mail: MailSummary;
  recentSessions: RecentSession[];
};

function str(v: unknown): string | null {
  return typeof v === 'string' ? v : null;
}

function pick(raw: Record<string, unknown>, snake: string, camel: string): unknown {
  return raw[snake] !== undefined ? raw[snake] : raw[camel];
}

function normalizeSection(raw: Record<string, unknown>): TodaySection {
  const prepared = Array.isArray(raw.prepared) ? raw.prepared : [];
  const openLoops = pick(raw, 'open_loops', 'openLoops');
  return {
    mountKey: str(pick(raw, 'mount_key', 'mountKey')) ?? '',
    icmName: str(pick(raw, 'icm_name', 'icmName')) ?? '',
    ok: pick(raw, 'ok', 'ok') === true,
    updatedAt: str(pick(raw, 'updated_at', 'updatedAt')),
    notes: str(raw.notes),
    prepared: prepared
      .filter((p): p is Record<string, unknown> => typeof p === 'object' && p !== null)
      .map((p) => ({ title: str(p.title), summary: str(p.summary), page: str(p.page) })),
    openLoops: (Array.isArray(openLoops) ? openLoops : [])
      .filter((l): l is Record<string, unknown> => typeof l === 'object' && l !== null)
      .map((l) => ({ title: str(l.title), source: str(l.source) }))
  };
}

export function normalizeCockpitToday(raw: Record<string, unknown>): CockpitToday {
  const sections = pick(raw, 'sections', 'sections');
  const mail = (pick(raw, 'mail', 'mail') ?? {}) as Record<string, unknown>;
  const recent = pick(raw, 'recent_sessions', 'recentSessions');
  return {
    sections: (Array.isArray(sections) ? sections : [])
      .filter((s): s is Record<string, unknown> => typeof s === 'object' && s !== null)
      .map(normalizeSection),
    mail: {
      reviewCount: Number(pick(mail, 'review_count', 'reviewCount') ?? 0),
      inboxCount: Number(pick(mail, 'inbox_count', 'inboxCount') ?? 0),
      configured: pick(mail, 'configured', 'configured') === true
    },
    recentSessions: (Array.isArray(recent) ? recent : [])
      .filter((s): s is Record<string, unknown> => typeof s === 'object' && s !== null)
      .map((s) => ({
        id: str(s.id) ?? '',
        title: str(s.title) ?? '',
        startedAt: str(pick(s, 'started_at', 'startedAt')) ?? '',
        status: str(s.status) ?? '',
        live: s.live === true
      }))
  };
}
```

Preserve `mailSummaryLine`/`splitTrustClause` from the old file ONLY if `grep -rn "mailSummaryLine\|splitTrustClause" frontend/src` shows consumers outside this module and its test; port them onto the new `MailSummary` type. Rewrite `cockpit.test.ts`: normalizer cases for both casings, wrong-typed fields, empty payload, `ok:false` section, `live:false` session.

- [ ] **Step 7: Rewrite the Today page.** Replace the content area of `frontend/src/routes/+page.svelte` (keep the AppShell/Sidebar skeleton, load/error handling, and the mail_status-push refetch wiring the page already has; ADD an `icm_changed` listener that refetches the payload the same way):
  - Mail summary line (existing pattern, from `today.mail`).
  - One block per `today.sections` entry: header row = `section.icmName` provenance chip (use `mountProvenanceLabel(section.mountKey)` styling conventions from `AuditRow.svelte`) + `section.updatedAt` when present. If `!section.ok`: render exactly the calm note `today.json couldn't be read` and nothing else for that section. Otherwise: `section.notes` as a paragraph when present; `section.prepared` as a list — each item shows `title ?? '(untitled)'`, `summary` under it, and when `item.page` is set the title links via `knowledgeHref(section.mountKey, item.page)`; `section.openLoops` rendered through the existing `OpenLoops.svelte` component (map `{title, source}`, dropping null-title items).
  - `today.recentSessions`: a "Recent sessions" list — each row links to `/chat?session=${id}` showing `title` + `startedAt` + a live dot when `live`.
  - Empty state (`today.sections.length === 0`): a quiet convention explainer card, exact copy:
    > **Nothing prepared yet.** Today renders a `today.json` file from the root of each ICM — a small JSON file your agent keeps up to date with prepared work, open loops, and notes. Ask your agent to maintain one; the starter ICM's `AGENTS.md` documents the shape.
  - Delete `ScheduleList.svelte`/`AwayList.svelte` (and `SourceChips.svelte` per the grep check in Files above) and all their usage.

- [ ] **Step 8: Run the FE suite.**
Run: `cd frontend && bun run check && bun run test`
Expected: green.

- [ ] **Step 9: Full gate + commit.**
Run: `just test`
Expected: green including codegen freshness.
```bash
git add -A backend frontend
git commit -m "feat!: Today renders today.json sections agents maintain (Spec D §C)"
```

---

### Task 4: Backend workflow-subsystem deletion

**Files:**
- Delete: `backend/lib/valea/workflows.ex`, `backend/lib/valea/workflows/runner.ex`, `backend/lib/valea/workflows/memory_proposal.ex`, `backend/lib/valea/workflows/distill.ex` (then the empty `backend/lib/valea/workflows/` dir), `backend/test/valea/workflows_test.exs`, `backend/test/valea/workflows/runner_test.exs`, `backend/test/valea/workflows/distill_test.exs`, `backend/test/valea/workflows/memory_proposal_test.exs`, `backend/priv/icm_template/Workflows/` (whole dir), `backend/test/fixtures/starter_icm/Workflows/` (whole dir), `backend/test/fixtures/workspace_v2/New Inquiry Triage.md`, `backend/test/fixtures/workspace_v2/priya-nair-inquiry.json` (verify nothing else references these fixtures first: `grep -rn "starter_icm/Workflows\|New Inquiry Triage\|priya-nair-inquiry" backend/test`)
- Modify:
  - `backend/lib/valea/api/agents.ex` — drop the `:run_workflow` (`:229-256`), `:distill_decisions` (`:258-285`), `:list_workflows` (`:322-353`) action blocks; drop private helpers `distill_workflow/0` (`:361-366`), `recent_decisions_digest/1` (`:368-373`), `flatten_workflow/2` (`:423-438`), `icm_names_by_mount_key/0` (`:446-451`); drop the `Valea.Workspace.Manager` alias only if unused after the edit; rewrite the moduledoc (no workflow/distill mentions)
  - `backend/lib/valea/api.ex:44,45,47` — drop the three `rpc_action` decls
  - `backend/lib/valea/api/icm.ex` — drop `alias Valea.Workflows.MemoryProposal` (`:45`); replace `path_exists?/2`'s `MemoryProposal.check_target/2` call (`:393-398`) with a private copy: move `check_target/2` AND its private helpers `find_mount/2`, `most_specific_root/1`, `mount_prefix?/2`, `target_abs/2` VERBATIM (including the doc comments) from `memory_proposal.ex` into `Valea.Api.ICM` as private functions, renaming `check_target` → `contained_target` to avoid any name confusion; `path_exists?/2` becomes:

```elixir
  defp path_exists?(root, path) do
    case contained_target(root, path) do
      {:ok, %{abs: abs}} -> File.regular?(abs)
      {:error, _reason} -> false
    end
  end
```

  - `backend/lib/valea/agents/session_settings.ex` — delete the `@workflow_contract` attribute (`:23-76`) and the `scope.kind == "workflow"` branch of `context/1` (`:126-129`, keep the plain-context path); update the moduledoc
  - `backend/lib/valea/workspace/runtime.ex:19-24` — remove the whole boot recovery task child (its only remaining call is `Runner.recover_staging`)
  - `backend/lib/valea/mail/doctor.ex` — remove the `workflow_contract` check: pipeline entry (`:97`, and its slot in the `checks` list `:99`), `workflow_contract/2` + `workflow_contract_read/2` + `workflow_contract_result/2` + `workflow_contract_absent/0` (`:357-409`), `@workflow_remedy` (`:82-83`), and `@gate_detail` if now unused
  - Moduledoc-only references (update prose, no behavior): `backend/lib/valea/agents/permission_policy.ex:26`, `backend/lib/valea/agents/session_scope.ex:7`, `backend/lib/valea/agents/session_server.ex:233`, `backend/lib/valea/agents.ex:60`
  - `backend/test/support/agent_case.ex:166-167` + `backend/test/support/fake_adapter.exs:233,243` — strip workflow doc-refs/prompt fixtures
- Test updates: `backend/test/valea_web/agents_rpc_test.exs` (delete the `run_workflow`/`distill_decisions`/`list_workflows` describes), `backend/test/valea/mail/doctor_test.exs` (delete workflow_contract cases `:180,209,225,230,244,246,445-501`), `backend/test/valea/mail/engine_test.exs:363,424,426` (workflow_contract/triage assertions), `backend/test/valea/agents/session_settings_test.exs` (delete `@workflow_contract`-injection cases; keep plain `content/1`/`context/1` coverage), `backend/test/valea/agents/session_scope_test.exs` (keep the grants coverage — grants are now generic session inputs; rename descriptions that say "workflow run" to "granted session"), `backend/test/valea/agents/session_read_roots_test.exs` (same treatment), `backend/test/valea/mounts/mounts_mutation_test.exs:164` (replace the `Workflows/Distill Decisions.md` seed assertion with `refute File.dir?(Path.join(root, "Workflows"))` — Task 14 replaces the template wholesale), `backend/test/valea/agents/risk_tier_test.exs:20-22` (change the fixture path `Workflows/Distill Decisions.md` → `Workflows/contract.md` — same behavior until Task 7 rewrites the classifier; this keeps Step 2's grep clean)
- Codegen: regenerate after the RPC removals

**Interfaces:**
- Consumes: Task 3 (`Valea.Cockpit` no longer references `Valea.Workflows`).
- Produces: `Valea.Api.Agents` hosting only `create_session`, `list_sessions` (internal), `list_recent_sessions_by_icm`, `list_sessions_for`, `create_follow_up`, `harness_doctor`. `Valea.Api.ICM.contained_target/2` (private) with the exact `{:ok, %{mount: map, abs: String.t()}} | {:error, :not_in_mount | :mount_not_enabled | :outside_mount}` contract `MemoryProposal.check_target/2` had.

**Steps:**

- [ ] **Step 1: Delete + modify.** Apply every deletion and modification above. Order within the task: move `contained_target` into `api/icm.ex` FIRST (compile check), then delete the four workflow modules, then sweep the callers.

- [ ] **Step 2: Grep for stragglers.**
Run:
```bash
grep -rn "Valea\.Workflows\|MemoryProposal\|Workflows\.Runner\|run_generated\|distill\|triage_path\|workflow_contract" backend/lib backend/test --include="*.ex" --include="*.exs" -i
```
Expected: zero lines. (Case-insensitive `distill`/`triage` may still hit the mail seed message fixture `backend/priv/workspace_template/sources/mail/messages/2026-07-09-priya-nair-seed0001.md` prose — content hits in that seed mail file are acceptable; code hits are not.)

- [ ] **Step 3: Run backend suite + regen.**
Run: `cd backend && mix test && mix ash_typescript.codegen`
Expected: all pass; `ash_rpc.ts` no longer contains `runWorkflow`/`listWorkflows`/`distillDecisions`.

- [ ] **Step 4: FE gate.**
Run: `cd frontend && bun run check && bun run test`
Expected: green (Task 1 removed all consumers).

- [ ] **Step 5: Commit.**
```bash
git add -A backend frontend/src/lib/api
git commit -m "feat(backend)!: delete Valea.Workflows subsystem — registry, Runner, proposals, Distill (Spec D §A)"
```

---
### Task 5: References workflow-union deletion (backend + frontend)

**Files:**
- Delete: `backend/lib/valea/icm/references.ex`, `backend/test/valea/icm/references_test.exs`
- Modify (backend): `backend/lib/valea/icm.ex` (drop the `References` alias; drop `rewrite_children/2` at `:736-748` and its call sites in both `do_rename/7` variants at `:684,:698` — the `LinkRewrite.rewrite_all` calls at `:685,:699` STAY; change `rename/3`'s return from `%{path:, updated_workflows:, updated_pages:}` to `%{path:, updated_pages:}`), `backend/lib/valea/api/icm.ex` (the `:rename` action: drop `updated_workflows` from its `constraints fields:` and its result map at `~:200-210`; the `:references` action at `~:229-260`: drop the whole `workflows:` field from constraints and drop the `References.referencing_workflows` call at `:263` — the action returns `%{pages: [...]}` only)
- Modify (frontend): every consumer of the `icmEntryReferences` / `renameIcmEntry` payloads' workflow fields — find them with `grep -rn "updatedWorkflows\|workflows" frontend/src/lib/components/knowledge frontend/src/lib/stores --include="*.ts" --include="*.svelte"`; expected sites are the C10 backlinks panel + rename/delete impact dialogs and their `fields` consts in `frontend/src/lib/api/client.ts` (`icmEntryReferencesFields`, `renameIcmEntryFields`). Update their impact copy to count pages only (e.g. "3 pages link here"), and their tests.
- Codegen: regenerate after the API change
- Test: `backend/test/valea_web/icm_rpc_test.exs` (references/rename shapes), `backend/test/valea/icm_test.exs` (rename return shape), affected FE dialog/panel tests

**Interfaces:**
- Consumes: Task 4 (workflow modules gone; References was the last `Workflows/`-scanning code).
- Produces: `Valea.ICM.rename/3` → `{:ok, %{path: String.t(), updated_pages: [String.t()]}}`; `icm_entry_references` RPC → `%{pages: [%{source_path, mount, link_text}]}`. Page-link rename integrity remains `Valea.ICM.LinkRewrite`'s job, unchanged.

**Steps:**

- [ ] **Step 1: Update backend tests first.** In `icm_test.exs` and `icm_rpc_test.exs`, change rename/references assertions to the new shapes (no `updated_workflows`, no `workflows:`). Any test that created `Workflows/*.md` files purely to assert frontmatter-`sources:` rewriting is deleted; tests asserting `LinkRewrite` page-link rewriting stay untouched.

- [ ] **Step 2: Run to verify failure.**
Run: `cd backend && mix test test/valea/icm_test.exs test/valea_web/icm_rpc_test.exs`
Expected: FAIL (code still returns the old shapes).

- [ ] **Step 3: Apply the backend deletion/modifications** from Files above.

- [ ] **Step 4: Run backend + regen.**
Run: `cd backend && mix test && mix ash_typescript.codegen`
Expected: PASS; generated `IcmEntryReferences`/rename types lose the workflow fields.

- [ ] **Step 5: Update the FE consumers** (grep from Files above), their copy, and tests.
Run: `cd frontend && bun run check && bun run test`
Expected: green.

- [ ] **Step 6: Grep + commit.**
Run: `grep -rn "referencing_workflows\|updated_workflows\|updatedWorkflows\|workflow_files\|workflows_dir" backend/lib backend/test frontend/src` → zero.
```bash
git add -A backend frontend
git commit -m "feat!: delete workflow-frontmatter reference union; page links keep LinkRewrite (Spec D §A)"
```

---

### Task 6: PermissionPolicy — delete `decide_legacy`, make write grants kind-agnostic

**Files:**
- Modify: `backend/lib/valea/agents/permission_policy.ex`, `backend/test/valea/agents/permission_policy_test.exs`, `docs/ARCHITECTURE.md` (only the stale "decide_legacy / callers not yet migrated" sentences — the full docs sweep is Task 16)

**Interfaces:**
- Consumes: Task 4 (nothing creates `kind: "workflow"` sessions anymore).
- Produces: `PermissionPolicy.decide/2` = the split contract only. Ask-gate semantics after this task: deny (tools/protected/escape) → read-allow (read_roots ∪ root files) → write-allow (any session whose ctx carries explicit `write_paths`/`write_roots` grants — grants are minted only by Valea's own `SessionScope` callers, never by the agent) → ask.

**Steps:**

- [ ] **Step 1: Update the tests.** In `permission_policy_test.exs`: delete the legacy-shape suite (the cases using a ctx WITHOUT `:workspace_root`, roughly lines 1-460 — the split-contract module from `:462` stays). In the surviving split suite, update the write-gate cases: a ctx with `session_kind: "chat"` and populated `write_paths`/`write_roots` now gets `{:allow, "allow_once"}` for contained writes (previously required `session_kind: "workflow"`); keep the cases proving empty grants → `:ask` and out-of-grant writes → deny/ask exactly as they are (only the kind expectation changes). Add one regression case:

```elixir
test "write grants are honored regardless of session kind" do
  # same setup as the existing contained-write case, but session_kind: "chat"
  assert {:allow, "allow_once"} = PermissionPolicy.decide(item, ctx)
end
```

- [ ] **Step 2: Run to verify failure.**
Run: `cd backend && mix test test/valea/agents/permission_policy_test.exs`
Expected: FAIL — chat writes with grants still fall to `:ask`; legacy tests deleted.

- [ ] **Step 3: Apply the deletion.** In `permission_policy.ex`:
  - Delete the whole legacy section, lines `241-388` (banner comment, `@legacy_*` attrs at `:249-252`, `decide_legacy/2` at `:254-293`, and every `legacy_*` helper: `legacy_resolve_candidate/2`, `legacy_escaped_root?/6`, `legacy_base_real/1`, `legacy_denied?/*`, `legacy_all_in_read_roots?/4`, `legacy_root_membership?/4`, `legacy_matches_any_root?/2`, `legacy_under_root?/2`, `legacy_under_lexical?/2`, `legacy_all_in_write_paths?/3`, `legacy_all_in_write_roots?/3`). KEEP the shared section after it: `protected_relative?/4` (`:400-406`) and `extract_paths/1` (`:408-414`).
  - Simplify the entry point: `decide/2` (`:84-91`) loses the `Map.has_key?(ctx, :workspace_root)` dispatch — it calls the split logic directly (fold `decide_split/2`'s body into `decide/2`, or keep the private and have `decide/2` delegate unconditionally).
  - In the cond, change the write clause from
    `kind in @write_kinds and ctx.session_kind == "workflow" and split_all_write?(resolved, write_paths, write_roots)` to
    `kind in @write_kinds and split_all_write?(resolved, write_paths, write_roots)`.
  - Rewrite the moduledoc: remove the "legacy contract pending caller migration" claims; document the grant story ("write grants are explicit, exact, and minted only by Valea's own session-creation paths; an agent can never widen them").

- [ ] **Step 4: Run tests.**
Run: `cd backend && mix test test/valea/agents/permission_policy_test.exs && mix test`
Expected: PASS, whole suite green.

- [ ] **Step 5: Fix the stale doc claims.** In `docs/ARCHITECTURE.md`, find the sentences claiming `decide_legacy` exists pending caller migration (grep `decide_legacy`) and rewrite them to state the split contract is the only path. Grep gate: `grep -rn "decide_legacy" backend docs` → zero in `backend/`, zero stale claims in docs.

- [ ] **Step 6: Commit.**
```bash
git add -A backend docs/ARCHITECTURE.md
git commit -m "feat(backend)!: PermissionPolicy split-contract only; write grants kind-agnostic (Spec D §A/§B)"
```

---

### Task 7: Depth-aware RiskTier

**Files:**
- Modify: `backend/lib/valea/agents/risk_tier.ex`, `backend/test/valea/agents/risk_tier_test.exs`

**Interfaces:**
- Consumes: nothing new (its surviving caller is `Valea.Agents.SessionServer.enrich_item/2` at `session_server.ex:284` — permission-item risk enrichment, untouched).
- Produces: `RiskTier.classify/1` — `"high"` iff the ICM-relative `path`'s basename is one of `AGENTS.md`/`CLAUDE.md`/`CONTEXT.md` (case-sensitive, any depth) or the path is exactly `icm.yaml` (root only); `"medium"` otherwise inside an ICM; `nil` for non-ICM locators. The `Workflows/` prefix rule is deleted.

**Steps:**

- [ ] **Step 1: Rewrite the test file.** Replace the workflow-coupled case and add depth cases:

```elixir
defmodule Valea.Agents.RiskTierTest do
  use ExUnit.Case, async: true

  alias Valea.Agents.RiskTier
  alias Valea.Icm.Locator

  @icm_id "11111111-1111-4111-8111-111111111111"

  test "instruction-spine basenames are high at any depth" do
    for path <- ["AGENTS.md", "CLAUDE.md", "CONTEXT.md", "clients/CONTEXT.md", "a/b/c/AGENTS.md", "deep/CLAUDE.md"] do
      assert RiskTier.classify(Locator.icm(@icm_id, path)) == "high", path
    end
  end

  test "root icm.yaml is high; a nested icm.yaml is not special" do
    assert RiskTier.classify(Locator.icm(@icm_id, "icm.yaml")) == "high"
    assert RiskTier.classify(Locator.icm(@icm_id, "vendor/icm.yaml")) == "medium"
  end

  test "the deleted Workflows/ prefix rule no longer applies" do
    assert RiskTier.classify(Locator.icm(@icm_id, "Workflows/anything.md")) == "medium"
    assert RiskTier.classify(Locator.icm(@icm_id, "notWorkflows/x.md")) == "medium"
  end

  test "ordinary pages are medium" do
    assert RiskTier.classify(Locator.icm(@icm_id, "clients/kita/prep.md")) == "medium"
  end

  test "workspace locators and malformed input are nil" do
    assert RiskTier.classify(Locator.workspace("sources/mail/messages/x.md")) == nil
    assert RiskTier.classify(%{}) == nil
    assert RiskTier.classify(nil) == nil
  end
end
```

(Keep the existing file's `Locator` call conventions — if the current tests build locators differently, e.g. `Locator.icm/2` argument order, mirror them.)

- [ ] **Step 2: Run to verify failure.**
Run: `cd backend && mix test test/valea/agents/risk_tier_test.exs`
Expected: FAIL — nested `CONTEXT.md` currently classifies `"medium"`, `Workflows/` still `"high"`.

- [ ] **Step 3: Rewrite the classifier.** Replace the module body (moduledoc updated to the basename story; drop the `Workflows/` mentions):

```elixir
  @behavior_basenames ["AGENTS.md", "CLAUDE.md", "CONTEXT.md"]

  @doc """
  "high" for the ICM's instruction spine — `AGENTS.md`/`CLAUDE.md`/
  `CONTEXT.md` by basename at ANY depth (real ICMs route with nested
  CONTEXT.md files), plus the root `icm.yaml` identity file. Everything
  else in an ICM is "medium"; non-ICM locators carry no tier.
  """
  @spec classify(map()) :: String.t() | nil
  def classify(%{"kind" => "icm", "path" => path}) when is_binary(path) do
    if Path.basename(path) in @behavior_basenames or path == "icm.yaml" do
      "high"
    else
      "medium"
    end
  end

  def classify(_locator), do: nil
```

- [ ] **Step 4: Run tests.**
Run: `cd backend && mix test test/valea/agents/risk_tier_test.exs && mix test`
Expected: PASS.

- [ ] **Step 5: Commit.**
```bash
git add backend/lib/valea/agents/risk_tier.ex backend/test/valea/agents/risk_tier_test.exs
git commit -m "feat(backend): depth-aware RiskTier — instruction basenames at any depth (Spec D §D3)"
```

---

### Task 8: ICM-internal secrets deny-by-default

**Files:**
- Modify: `backend/lib/valea/agents/permission_policy.ex`, `backend/lib/valea/agents/session_settings.ex`, `backend/lib/valea/agents/session_server.ex` (the policy-ctx construction — find it with `grep -n "session_kind" backend/lib/valea/agents/session_server.ex`), `backend/test/valea/agents/permission_policy_test.exs`, `backend/test/valea/agents/session_settings_test.exs`

**Interfaces:**
- Consumes: Task 6 (split-only policy).
- Produces: policy ctx gains `icm_roots: [String.t()]` (primary + related ICM roots, supplied by SessionServer). `PermissionPolicy` denies (auto `reject_once`) any read/write candidate resolving inside an ICM root whose ICM-relative form matches the secret patterns. `SessionSettings.content/1` mirrors the same patterns into the managedSettings `deny` list.

**Secret patterns (spec §D5, authoritative in the policy layer):** relative to each ICM root, at any depth — a `secrets` directory segment; basenames `.env` and `.env.*` EXCEPT `.env.example`; basenames ending `.pem` or `.key`; basenames containing `credentials` (case-insensitive). Deny, not ask. The managedSettings glob mirror cannot express the `.env.example` exception — it denies `.env.*` wholesale, which is strictly MORE restrictive than the policy layer; that divergence is accepted and documented in the code comment.

**Steps:**

- [ ] **Step 1: Write the failing policy tests.** Add to the split suite in `permission_policy_test.exs` (mirror the existing split-ctx builders; `icm_root` below = the primary ICM root the existing cases already use as `cwd`):

```elixir
describe "ICM-internal secrets deny" do
  # ctx built like the existing split cases, plus: icm_roots: [icm_root]
  test "reads and writes under a secrets/ dir are denied at any depth" do
    for path <- ["#{icm_root}/secrets/api_key.txt", "#{icm_root}/clients/kita/secrets/token"] do
      for kind <- ["read", "write"] do
        assert {:deny, "reject_once"} = PermissionPolicy.decide(item_for(kind, path), ctx)
      end
    end
  end

  test ".env variants are denied; .env.example is not" do
    for path <- ["#{icm_root}/.env", "#{icm_root}/deploy/.env.production"] do
      assert {:deny, "reject_once"} = PermissionPolicy.decide(item_for("read", path), ctx)
    end
    refute match?({:deny, _}, PermissionPolicy.decide(item_for("read", "#{icm_root}/.env.example"), ctx))
  end

  test "key material and credentials basenames are denied" do
    for path <- ["#{icm_root}/certs/server.pem", "#{icm_root}/id.key", "#{icm_root}/ops/aws-credentials.json", "#{icm_root}/CREDENTIALS.md"] do
      assert {:deny, "reject_once"} = PermissionPolicy.decide(item_for("write", path), ctx)
    end
  end

  test "segment boundaries: lookalike names are not denied" do
    for path <- ["#{icm_root}/mysecrets/notes.md", "#{icm_root}/secretsfoo/x.md", "#{icm_root}/env/.envrc.sample.md"] do
      refute match?({:deny, _}, PermissionPolicy.decide(item_for("read", path), ctx))
    end
  end

  test "creating a NEW file under secrets/ is denied (target does not exist yet)" do
    assert {:deny, "reject_once"} =
             PermissionPolicy.decide(item_for("write", "#{icm_root}/secrets/new_key.txt"), ctx)
  end

  test "the same basenames OUTSIDE any icm_root keep their old behavior" do
    # a workspace-relative path not under any icm root: unchanged (existing
    # workspace-protected tier already covers <ws>/secrets)
    refute match?({:deny, _}, PermissionPolicy.decide(item_for("read", "/tmp/elsewhere/.env"), ctx))
  end
end
```

Use the file/dir fixtures the surrounding split tests use (create the files under the tmp ICM root where resolution requires them; the "new file" case must NOT create the file).

- [ ] **Step 2: Run to verify failure.**
Run: `cd backend && mix test test/valea/agents/permission_policy_test.exs`
Expected: FAIL — secrets paths inside read_roots currently auto-allow reads.

- [ ] **Step 3: Implement the policy deny.** In `permission_policy.ex`:
  - In the (former `decide_split`) body, add `icm_roots = Enum.map(ctx[:icm_roots] || [], &split_real/1)` next to the other root normalizations, and insert this cond clause immediately AFTER the `split_protected?` clause (deny wins; order before any allow):

```elixir
      Enum.any?(resolved, &split_icm_secret?(&1, icm_roots)) ->
        {:deny, "reject_once"}
```

  - Add the helpers (public `secret_relative?/1` so SessionSettings tests can reference the same contract; keep it `@doc false`):

```elixir
  # Spec D §D5: ICM-internal secret material is deny-by-default — mirrors
  # the workspace-protected tier. Checked against each ICM root by the
  # candidate's ICM-relative segments, so `mysecrets/` and `secretsfoo/`
  # never match a `secrets` SEGMENT.
  defp split_icm_secret?({:ok, abs}, icm_roots) do
    Enum.any?(icm_roots, fn root ->
      if split_under_root?(abs, root) do
        rel = String.trim_leading(abs, root <> "/")
        secret_relative?(rel)
      else
        false
      end
    end)
  end

  defp split_icm_secret?(_resolved, _icm_roots), do: false

  @doc false
  # Public only so the managedSettings mirror's tests can assert the same
  # pattern set; not part of the module's decision API.
  def secret_relative?(rel) do
    segments = Path.split(rel)
    basename = List.last(segments) || ""
    dir_segments = Enum.drop(segments, -1)

    cond do
      "secrets" in dir_segments -> true
      basename == "secrets" -> true
      basename == ".env" -> true
      String.starts_with?(basename, ".env.") and basename != ".env.example" -> true
      String.ends_with?(basename, ".pem") -> true
      String.ends_with?(basename, ".key") -> true
      String.contains?(String.downcase(basename), "credentials") -> true
      true -> false
    end
  end
```

  (`split_under_root?/2` already exists at `:238`; if its contract is prefix-with-boundary on already-`split_real`ed paths, pass the normalized root. Confirm the non-existent-target case: `split_resolve_candidate/2` resolves create targets to `{:ok, abs}` per `Valea.Paths.resolve_real/2`'s append-remainder contract, so the deny catches new-file creation — the Step 1 test proves it.)
  - Wire `icm_roots` into the ctx: in `session_server.ex`, the map handed to `PermissionPolicy.decide/2` (the one carrying `workspace_root`/`cwd`/`read_roots`/`session_kind`) gains:

```elixir
        icm_roots: [state.scope.primary_icm.root | Enum.map(state.scope.related_icms, & &1.root)],
```

  (adjust to the local variable the ctx builder actually uses for the scope).

- [ ] **Step 4: Run the policy tests.**
Run: `cd backend && mix test test/valea/agents/permission_policy_test.exs`
Expected: PASS.

- [ ] **Step 5: Mirror into managedSettings.** In `session_settings.ex` `content/1`, add after the existing `deny` construction:

```elixir
    icm_roots = [scope.primary_icm.root | Enum.map(scope.related_icms, & &1.root)]

    # Spec D §D5 mirror of PermissionPolicy.secret_relative?/1. Globs cannot
    # express the `.env.example` exception, so this layer denies `.env.*`
    # wholesale — strictly more restrictive than the authoritative policy
    # layer, accepted by design.
    secret_denies =
      Enum.flat_map(icm_roots, fn root ->
        patterns = [
          "#{root}/secrets/**",
          "#{root}/**/secrets/**",
          "#{root}/.env",
          "#{root}/.env.*",
          "#{root}/**/.env",
          "#{root}/**/.env.*",
          "#{root}/**/*.pem",
          "#{root}/**/*.key",
          "#{root}/**/*credentials*",
          "#{root}/*credentials*"
        ]

        for pattern <- patterns, op <- ["Read", "Edit", "Write"], do: "#{op}(#{pattern})"
      end)
```

and append `++ secret_denies` to the `deny` list. Add `session_settings_test.exs` cases: the content's `deny` includes `Read(<primary>/secrets/**)`, `Write(<related>/**/.env.*)`, etc., for both primary and related roots.

- [ ] **Step 6: Run the full backend suite.**
Run: `cd backend && mix test`
Expected: PASS (if any existing fixture ICM contains files matching the deny patterns and a test asserted auto-allow on them, fix the fixture, not the pattern).

- [ ] **Step 7: Commit.**
```bash
git add -A backend
git commit -m "feat(backend): ICM-internal secrets deny-by-default in policy + managedSettings mirror (Spec D §D5)"
```

---
### Task 9: Session-with-context primitive (backend)

**Files:**
- Modify: `backend/lib/valea/api/agents.ex` (the `:create_session` action), `backend/lib/valea/agents/session_server.ex` (session/v1 meta gains `context_doc`/`input`), `backend/test/valea_web/agents_rpc_test.exs`, `backend/test/valea/agents/session_read_roots_test.exs`, `frontend/src/lib/api/client.ts` (wrapper signature) + the two call sites `frontend/src/routes/chat/+page.svelte:116-137` and `frontend/src/lib/components/shell/IcmProjects.svelte:78-95`
- Codegen: regenerate

**Interfaces:**
- Consumes: `SessionScope.resolve/1` unchanged (already accepts optional `read_paths`, folds them into the launch: managedSettings `Read(<path>)` allows via `SessionSettings.content/1` and ACP `additional_roots` via `ClaudeCode.related_and_input_roots/1` — no scope changes needed); `Valea.Icm.Locator.resolve(workspace_root, locator)` → `{:ok, abs} | {:error, reason}`; `Valea.Audit.append(type, fields)` (a cast — safe with no workspace).
- Produces: RPC `create_agent_session(mount_key, generation, context_doc \\ nil, input \\ nil)` returning `%{id, input_path}` — `input_path` is the resolved absolute path of the granted input (nil when no input), so the FE can reference exactly the granted file in its opening prompt. The `kind` ARGUMENT is removed; the server always creates `kind: "chat"` (the field stays in the session schema/summaries). Error atoms: `:input_unavailable`, `:context_doc_unavailable` (both stringify through `error_for/1`). Session/v1 meta records `"context_doc"`/`"input"`; an audit entry `session_started` records `session_id`/`mount_key`/`context_doc`/`input`.

**Locator shapes (string keys, verbatim JSON from the FE — same convention the deleted `run_workflow` used for `input_locator`):**
- `context_doc`: `%{"kind" => "icm", "icm_id" => <uuid>, "path" => <ICM-relative path>}` — a document in the session's own primary (or a related) ICM; validated to resolve + be a regular file; NOT granted anything extra (the primary/related read roots already cover it).
- `input`: any ICM or workspace locator; resolved at creation and granted as ONE exact read path.

**Steps:**

- [ ] **Step 1: Write the failing RPC tests.** In `agents_rpc_test.exs` (mirror the existing `create_agent_session` cases' setup — they use the fake adapter + open workspace):

```elixir
describe "create_agent_session with context" do
  test "kind argument is gone; plain creation returns id and nil input_path" do
    # rpc create_agent_session %{mount_key: ..., generation: ...}
    assert %{"id" => id, "inputPath" => nil} = data   # match the casing the existing tests use
    # session meta line records kind "chat" and nil context_doc/input
  end

  test "input locator is resolved, granted, and returned" do
    # write <ws>/sources/mail/messages/msg1.md
    # rpc with input: %{"kind" => "workspace", "path" => "sources/mail/messages/msg1.md"}
    assert data["inputPath"] =~ "sources/mail/messages/msg1.md"
    # transcript meta line 1: "input" == the locator map
  end

  test "missing input file fails closed" do
    # rpc with input naming a nonexistent path
    assert error code == "input_unavailable"
    # and no session transcript file was created
  end

  test "context_doc is validated and recorded" do
    # create page notes/plan.md in the primary ICM
    # rpc with context_doc: %{"kind" => "icm", "icm_id" => icm_id, "path" => "notes/plan.md"}
    # meta records it; missing page → "context_doc_unavailable"
  end

  test "session_started audit entry carries the context fields" do
    # after a successful create, Valea.Audit.entries(10) includes
    # %{"type" => "session_started", "session_id" => id, ...} with context_doc/input
  end
end
```

Extend `session_read_roots_test.exs` with one case: a chat session created with `read_paths: [input_abs]` (via `SessionScope.resolve/1` directly, as that file's existing cases do) carries `Read(<input_abs>)` in its managedSettings allow list and the path in `additional_roots` — if an equivalent case already exists from the workflow era, just re-point its description.

- [ ] **Step 2: Run to verify failure.**
Run: `cd backend && mix test test/valea_web/agents_rpc_test.exs`
Expected: FAIL (unknown arguments / old return shape).

- [ ] **Step 3: Rewrite the `:create_session` action.** In `backend/lib/valea/api/agents.ex` replace the action with:

```elixir
    action :create_session, :map do
      constraints fields: [
                    id: [type: :string, allow_nil?: false],
                    input_path: [type: :string, allow_nil?: true]
                  ]

      argument :mount_key, :string, allow_nil?: false
      argument :generation, :integer, allow_nil?: false
      # Spec D §B: both optional, both raw string-keyed locator maps
      # (unconstrained :map — same convention the deleted run_workflow used
      # for input_locator; the FE sends "kind"/"icm_id"/"path" verbatim).
      argument :context_doc, :map, allow_nil?: true
      argument :input, :map, allow_nil?: true

      run fn input, _ctx ->
        %{mount_key: mount_key, generation: generation} = input.arguments
        context_doc = Map.get(input.arguments, :context_doc)
        input_locator = Map.get(input.arguments, :input)
        id = Valea.Agents.generate_session_id()

        with :ok <- Manager.check_generation(generation),
             {:ok, %{path: workspace}} <- Manager.current(),
             {:ok, context_doc} <- resolve_context_doc(context_doc, workspace),
             {:ok, input_abs} <- resolve_session_input(input_locator, workspace),
             {:ok, scope} <-
               SessionScope.resolve(%{
                 kind: "chat",
                 mount_key: mount_key,
                 generation: generation,
                 session_id: id,
                 read_paths: if(input_abs, do: [input_abs], else: [])
               }),
             {:ok, %{id: id}} <-
               Valea.Agents.start_session(%{
                 id: id,
                 kind: "chat",
                 title: "New session",
                 scope: scope,
                 run: nil,
                 initial_prompt: nil,
                 on_turn_end: nil,
                 context_doc: context_doc,
                 input: input_locator
               }) do
          Valea.Audit.append("session_started", %{
            "session_id" => id,
            "mount_key" => mount_key,
            "context_doc" => context_doc,
            "input" => input_locator
          })

          {:ok, %{id: id, input_path: input_abs}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end
```

and add the private resolvers (near `error_for/1`):

```elixir
  # Spec D §B fail-closed resolution: a named context that cannot be
  # resolved to a real file aborts session creation with a stable atom the
  # FE renders inline — never a session that silently lacks its context.
  defp resolve_session_input(nil, _workspace), do: {:ok, nil}

  defp resolve_session_input(locator, workspace) do
    case Valea.Icm.Locator.resolve(workspace, locator) do
      {:ok, abs} -> if File.regular?(abs), do: {:ok, abs}, else: {:error, :input_unavailable}
      {:error, _reason} -> {:error, :input_unavailable}
    end
  end

  defp resolve_context_doc(nil, _workspace), do: {:ok, nil}

  defp resolve_context_doc(locator, workspace) do
    case Valea.Icm.Locator.resolve(workspace, locator) do
      {:ok, abs} -> if File.regular?(abs), do: {:ok, locator}, else: {:error, :context_doc_unavailable}
      {:error, _reason} -> {:error, :context_doc_unavailable}
    end
  end
```

(Check `Valea.Icm.Locator.resolve/2`'s argument order in `locator.ex` — it is `resolve(workspace, locator)`. If Task 4 removed the now-unused `alias Valea.Workspace.Manager` from this module, re-add it — this action uses `Manager.check_generation/1` and `Manager.current/0`.)

- [ ] **Step 4: Persist the meta fields.** In `session_server.ex`'s `open_transcript/2` meta map (`:441-468`), add after `"run_id"`:

```elixir
      "context_doc" => Map.get(opts, :context_doc),
      "input" => Map.get(opts, :input),
```

(`start_session/1` passes its whole opts map through to the server — verify the opts plumbing carries unknown keys; if `Valea.Agents.start_session/1` pattern-matches a fixed key set, add the two keys there too.)

- [ ] **Step 5: Run backend tests + regen.**
Run: `cd backend && mix test && mix ash_typescript.codegen`
Expected: PASS; generated `CreateAgentSessionInput` = `{mountKey, generation, contextDoc?, input?}`, result gains `inputPath`.

- [ ] **Step 6: Sync the FE wrapper + call sites.** In `client.ts`:

```ts
  createAgentSession: (
    mountKey: string,
    generation: number,
    opts?: {
      /** Raw string-keyed ICM locator — sent verbatim ({kind:'icm', icm_id, path}). */
      contextDoc?: { kind: 'icm'; icm_id: string; path: string };
      /** Raw string-keyed ICM/workspace locator granted as one exact read path. */
      input?: { kind: 'workspace'; path: string } | { kind: 'icm'; icm_id: string; path: string };
    }
  ) =>
    runRpc(
      (channel) =>
        callCreateAgentSessionChannel(channel, {
          mountKey,
          generation,
          contextDoc: opts?.contextDoc ?? null,
          input: opts?.input ?? null
        }),
      () =>
        httpCreateAgentSession(
          withAuth({
            input: { mountKey, generation, contextDoc: opts?.contextDoc ?? null, input: opts?.input ?? null },
            fields: createAgentSessionFields
          })
        )
    ),
```

with `createAgentSessionFields` = `['id', 'inputPath']`. Update the two call sites to drop the `'chat'` first argument (`api.createAgentSession(mountKey, workspaceStore.generation ?? 0)`). Update `client.test.ts` fixtures.

- [ ] **Step 7: Full gate + commit.**
Run: `just test`
Expected: green.
```bash
git add -A backend frontend
git commit -m "feat!: session-with-context primitive — context_doc + input grants on create_agent_session (Spec D §B)"
```

---

### Task 10: Frontend — initial-prompt mechanism + Knowledge "Start a session with this page"

**Files:**
- Create: `frontend/src/lib/stores/initial-prompt.ts` + `frontend/src/lib/stores/initial-prompt.test.ts`
- Modify: `frontend/src/lib/stores/agent-session.svelte.ts` (constructor accepts an optional initial prompt, pushed once on successful join), `frontend/src/routes/chat/+page.svelte` (the `$effect` at `:66-78` hands the pending prompt to the store), `frontend/src/lib/components/knowledge/EntryMenu.svelte` (new page-row action), its test file if one exists
- Test: `initial-prompt.test.ts`; extend the EntryMenu/knowledge component tests only if that surface already has them (check `frontend/src/lib/components/knowledge/*.test.ts`)

**Interfaces:**
- Consumes: `api.createAgentSession(mountKey, generation, { contextDoc })` (Task 9); `mountsStore` (`$lib/stores/mounts.svelte`) exposing `MountSummary { mountKey, id, ... }` for the mountKey→icm_id lookup; `recentSessionsStore.refresh()` + `goto('/chat?session=...')` (the exact pattern `IcmProjects.startSession` uses at `IcmProjects.svelte:78-95`).
- Produces: `setInitialPrompt(sessionId, text)` / `takeInitialPrompt(sessionId): string | null` in `initial-prompt.ts`; `AgentSessionStore` auto-sending a provided initial prompt on join. Task 11 reuses both.

**Opening prompt copy (spec §B, decided here):**

```ts
export function pageSessionPrompt(relativePath: string): string {
  return [
    `Read \`${relativePath}\` and follow it.`,
    `If it describes a procedure or workflow, execute it step by step — I'll approve any file changes through the permission gate as you go.`,
    `If it's reference material, give me a short summary and wait for my direction.`
  ].join(' ');
}
```

**Steps:**

- [ ] **Step 1: Write the failing test** (`initial-prompt.test.ts`):

```ts
import { describe, expect, test } from 'vitest';
import { setInitialPrompt, takeInitialPrompt, pageSessionPrompt } from './initial-prompt';

describe('initial prompt handoff', () => {
  test('take returns the pending prompt exactly once', () => {
    setInitialPrompt('s1', 'hello');
    expect(takeInitialPrompt('s1')).toBe('hello');
    expect(takeInitialPrompt('s1')).toBeNull();
  });

  test('unknown session id yields null', () => {
    expect(takeInitialPrompt('nope')).toBeNull();
  });

  test('pageSessionPrompt references the cwd-relative path', () => {
    expect(pageSessionPrompt('finances/workflows/inbox-triage.md')).toContain(
      '`finances/workflows/inbox-triage.md`'
    );
  });
});
```

- [ ] **Step 2: Run to verify failure.**
Run: `cd frontend && bun run test -- initial-prompt`
Expected: FAIL (module missing).

- [ ] **Step 3: Implement the handoff module** (`frontend/src/lib/stores/initial-prompt.ts`):

```ts
/**
 * One-shot handoff of a composed opening prompt from a session entry point
 * ("Start a session with this page", "Start a session about this message")
 * to the chat route. The entry point creates the session, stashes the
 * prompt under the new session id, and navigates; the chat page takes it
 * (exactly once) and hands it to AgentSessionStore, which pushes it as the
 * first user turn on join. Module-level state survives SPA navigation and
 * intentionally does NOT survive a reload — a reloaded session simply has
 * no pending prompt, which is safe.
 */
const pending = new Map<string, string>();

export function setInitialPrompt(sessionId: string, text: string): void {
  pending.set(sessionId, text);
}

export function takeInitialPrompt(sessionId: string): string | null {
  const text = pending.get(sessionId) ?? null;
  pending.delete(sessionId);
  return text;
}

export function pageSessionPrompt(relativePath: string): string {
  return [
    `Read \`${relativePath}\` and follow it.`,
    `If it describes a procedure or workflow, execute it step by step — I'll approve any file changes through the permission gate as you go.`,
    `If it's reference material, give me a short summary and wait for my direction.`
  ].join(' ');
}
```

- [ ] **Step 4: Wire the store + chat page.** In `agent-session.svelte.ts`: the constructor gains `opts?: { initialPrompt?: string | null }`; store it privately; in the channel-join `.receive('ok', ...)` callback (`:63-79` region), after the existing join bookkeeping:

```ts
      if (this.#initialPrompt) {
        this.prompt(this.#initialPrompt);
        this.#initialPrompt = null;
      }
```

In `routes/chat/+page.svelte`'s session `$effect`:

```ts
    const session = new AgentSessionStore(id, { initialPrompt: takeInitialPrompt(id) });
```

- [ ] **Step 5: Add the EntryMenu action.** In `EntryMenu.svelte`, for page rows only (`{#if !isFolder}`), add above Rename:

```svelte
    <DropdownMenu.Item onSelect={() => void startSessionWithPage()}>
      <MessageSquarePlus class="size-3.5" strokeWidth={1.5} />
      Start a session with this page
    </DropdownMenu.Item>
```

with (imports: `api`, `mountsStore`, `workspaceStore`, `recentSessionsStore`, `goto`, `setInitialPrompt`/`pageSessionPrompt`, `MessageSquarePlus` icon):

```ts
  let sessionError = $state<string | null>(null);

  async function startSessionWithPage() {
    sessionError = null;
    const icmId = mountsStore.mounts.find((m) => m.mountKey === mountKey)?.id;
    if (!icmId) {
      sessionError = 'This ICM has no loadable identity — run Diagnose from the sidebar.';
      return;
    }
    const result = await api.createAgentSession(mountKey, workspaceStore.generation ?? 0, {
      contextDoc: { kind: 'icm', icm_id: icmId, path }
    });
    if (!result.ok) {
      sessionError = `Couldn't start the session (${result.error}).`;
      return;
    }
    const data = result.data as { id: string };
    setInitialPrompt(data.id, pageSessionPrompt(path));
    await recentSessionsStore.refresh();
    void goto(`/chat?session=${data.id}`);
  }
```

Render `sessionError` as a small `role="alert"` line in the menu's parent (mirror how RenameDialog surfaces errors in this component). Adjust member names to the store's actual API (`mountsStore.mounts` — verify the list accessor name in `mounts.svelte.ts`; the error-message helper conventions live in the same file).

- [ ] **Step 6: Run the FE suite.**
Run: `cd frontend && bun run check && bun run test`
Expected: green.

- [ ] **Step 7: Commit.**
```bash
git add -A frontend
git commit -m "feat(frontend): Start a session with this page — context_doc entry point + initial-prompt handoff (Spec D §B)"
```

---

### Task 11: Frontend — Mail "Start a session about this message"

**Files:**
- Modify: `frontend/src/lib/components/mail/MessageView.svelte` (fill the empty actions branch Task 1 left), `frontend/src/lib/components/mail/mail-shapes.ts` (+ prompt builder), `frontend/src/lib/components/mail/mail-components.test.ts`

**Interfaces:**
- Consumes: `api.createAgentSession(mountKey, generation, { input })` returning `{ id, inputPath }` (Task 9); `setInitialPrompt` (Task 10); `icmStore.groups` first enabled mount (the same default the chat route's `primaryMountKey()` falls back to at `routes/chat/+page.svelte:44-47`); `message.path` — the workspace-relative message file path already on `MailMessageDetail` (`mail.svelte.ts:71-76`).
- Produces: `messageSessionPrompt(inputPath: string): string` in `mail-shapes.ts`.

**Opening prompt copy (decided here):**

```ts
export function messageSessionPrompt(inputPath: string): string {
  return [
    `Read the mail message at \`${inputPath}\` — you have read access to exactly that file.`,
    `Summarize who it's from and what they need, then help me decide how to handle it.`,
    `If a reply is warranted, draft it as a new file in this ICM through the normal approval flow — do not send anything.`
  ].join(' ');
}
```

**Steps:**

- [ ] **Step 1: Write the failing test.** In `mail-components.test.ts`:

```ts
test('messageSessionPrompt references the granted absolute path', () => {
  const prompt = messageSessionPrompt('/ws/sources/mail/messages/m1.md');
  expect(prompt).toContain('`/ws/sources/mail/messages/m1.md`');
  expect(prompt).toContain('do not send anything');
});
```

Run: `cd frontend && bun run test -- mail-components` — Expected: FAIL.

- [ ] **Step 2: Add the prompt builder** to `mail-shapes.ts` (code above). Test passes.

- [ ] **Step 3: Fill the MessageView action.** In the actions `<div>` (the interim shape from Task 1), add the non-processed branch:

```svelte
  {#if status === 'processed'}
    <span class="text-ink-meta text-[11px] tracking-[0.08em] uppercase">Processed</span>
  {:else}
    <Button type="button" disabled={starting || !message.path} onclick={() => void startSession()}>
      Start a session about this message
    </Button>
    {#if sessionError}<p class="text-warn-ink text-[12.5px]" role="alert">{sessionError}</p>{/if}
  {/if}
```

with:

```ts
  let starting = $state(false);
  let sessionError = $state<string | null>(null);

  async function startSession() {
    if (!message.path) return;
    starting = true;
    sessionError = null;
    try {
      const mountKey = icmStore.groups[0]?.mount;
      if (!mountKey) {
        sessionError = 'No enabled ICM to host the session — enable one in the sidebar.';
        return;
      }
      const result = await api.createAgentSession(mountKey, workspaceStore.generation ?? 0, {
        input: { kind: 'workspace', path: message.path }
      });
      if (!result.ok) {
        sessionError =
          result.error === 'input_unavailable'
            ? "This message file isn't available on disk anymore."
            : `Couldn't start the session (${result.error}).`;
        return;
      }
      const data = result.data as { id: string; inputPath: string | null };
      setInitialPrompt(data.id, messageSessionPrompt(data.inputPath ?? message.path));
      void goto(`/chat?session=${data.id}`);
    } finally {
      starting = false;
    }
  }
```

(If the generated result arrives snake_cased, read `data.inputPath ?? (data as any).input_path` — mirror whatever casing Task 9's `client.test.ts` fixtures proved.)

- [ ] **Step 4: Run the FE suite.**
Run: `cd frontend && bun run check && bun run test`
Expected: green.

- [ ] **Step 5: Commit.**
```bash
git add -A frontend
git commit -m "feat(frontend): Start a session about this message — exact-read input grant replaces Run triage (Spec D §B/§E)"
```

---
### Task 12: Adopt-a-folder (backend) — inspect `adoptable`, format-1 acceptance, `adopt_icm` RPC

**Files:**
- Modify: `backend/lib/valea/api/icms.ex` (inspect result + new action), `backend/lib/valea/api.ex` (new decl), `backend/lib/valea/mounts.ex` (`adopt/3`), `backend/lib/valea/mounts/manifest.ex` (only if it lacks a non-raising write — see Step 3), `backend/test/valea/api/icms_test.exs`, `backend/test/valea/mounts/mounts_mutation_test.exs` (or the mounts test file where `mount/2`/`create/3` cases live)
- Codegen: regenerate

**Interfaces:**
- Consumes: `Valea.Mounts` private checks `check_boundaries/2`, `check_icm_glob_safety/1`, `check_folder_exists/1`, `validate_display_name/1`, `resolve_best_effort/1`, `Manifest.load/1`, `Manifest.write!/2`, `mount/2` (all existing in `mounts.ex`).
- Produces: `inspect_icm` result gains `"adoptable" => boolean` (true iff the folder exists, passes boundary checks, and has NO `icm.yaml`); `inspect_icm` now reports `ok: true` for a loadable `format: 1` manifest (aligned with mounting, which already accepts it — `Manifest.load/1` never rejected format 1); `Valea.Mounts.adopt/3 :: (workspace, path, name) -> {:ok, %{mount_key, id}} | {:error, term}`; RPC `adopt_icm(path, name, generation) -> %{mount_key, id}`. Task 13 consumes `adoptable` + `adoptIcm`.

**Steps:**

- [ ] **Step 1: Write the failing tests.** In `icms_test.exs` (mirror the existing `inspect_icm` cases' tmp-dir setup):

```elixir
describe "inspect_icm adoptable" do
  test "manifest-less folder inside boundaries → ok false, adoptable true" do
    # tmp dir, no icm.yaml
    assert %{"ok" => false, "adoptable" => true, "reason" => reason} = inspect(path)
    assert reason =~ "no icm.yaml"
  end

  test "boundary-rejected folder is NOT adoptable" do
    # a path that trips home_or_root?/glob-unsafe/missing-folder
    assert %{"ok" => false, "adoptable" => false} = inspect(bad_path)
  end

  test "format-1 manifest now inspects ok (aligned with mounting)" do
    # icm.yaml with format: 1, valid uuid + name
    assert %{"ok" => true, "adoptable" => false, "name" => _} = inspect(path)
  end

  test "invalid manifest is neither ok nor adoptable" do
    # icm.yaml with garbage
    assert %{"ok" => false, "adoptable" => false} = inspect(path)
  end
end
```

In the mounts test file:

```elixir
describe "adopt/3" do
  test "mints a format-2 manifest and mounts" do
    {:ok, %{mount_key: key, id: id}} = Valea.Mounts.adopt(workspace, folder, "Life")
    manifest = YamlElixir.read_from_file!(Path.join(folder, "icm.yaml"))
    assert manifest["format"] == 2
    assert manifest["id"] == id
    assert manifest["name"] == "Life"
    assert %{enabled: true} = Valea.Mounts.mount_by_key(workspace, key)
  end

  test "refuses a folder that already has a manifest" do
    # write any icm.yaml first
    assert {:error, :already_icm} = Valea.Mounts.adopt(workspace, folder, "X")
  end

  test "boundary violations reject before any write" do
    assert {:error, _} = Valea.Mounts.adopt(workspace, workspace, "X")
    refute File.exists?(Path.join(workspace, "icm.yaml"))
  end

  test "mint failure aborts with the OS reason and mounts nothing" do
    File.chmod!(folder, 0o555)
    assert {:error, {:mint_failed, :eacces}} = Valea.Mounts.adopt(workspace, folder, "X")
    File.chmod!(folder, 0o755)
    assert Valea.Mounts.mount_by_key(workspace, "x") == nil
  end
end
```

(Use the YAML-reading helper the existing manifest tests use if `YamlElixir` isn't referenced directly.)

- [ ] **Step 2: Run to verify failure.**
Run: `cd backend && mix test test/valea/api/icms_test.exs`
Expected: FAIL (no `adoptable` key; format-1 rejected; `adopt/3` undefined).

- [ ] **Step 3: Implement `Valea.Mounts.adopt/3`.** In `mounts.ex`, next to `create/3`:

```elixir
  @doc """
  Spec D §D4 — adopt a manifest-less folder as an ICM: after the SAME
  boundary gates mounting applies, mint a minimal `{format: 2, id, name}`
  identity file (the ONLY write this flow ever performs inside the user's
  folder — user-consented in the FE) and mount by reference. A folder that
  already carries any `icm.yaml` (valid or not) is refused — adopting never
  overwrites identity. A mint failure aborts before any mount config is
  touched (no partial mount).
  """
  def adopt(workspace, path, name)
      when is_binary(workspace) and is_binary(path) and is_binary(name) do
    with :ok <- validate_display_name(name),
         {:ok, resolved} <- check_adoptable(workspace, path),
         :ok <- mint_manifest(resolved, name) do
      mount(workspace, path)
    end
  end

  defp check_adoptable(workspace, path) do
    if absolute_or_tilde?(path) do
      resolved = resolve_best_effort(Path.expand(path))
      ws_resolved = resolve_best_effort(workspace)

      with :ok <- check_boundaries(resolved, ws_resolved),
           :ok <- check_icm_glob_safety(resolved),
           :ok <- check_folder_exists(resolved) do
        case Manifest.load(resolved) do
          {:error, :missing} -> {:ok, resolved}
          _present_or_invalid -> {:error, :already_icm}
        end
      end
    else
      {:error, :not_absolute}
    end
  end

  defp mint_manifest(resolved, name) do
    Manifest.write!(resolved, %{id: Ecto.UUID.generate(), name: name, description: ""})
    :ok
  rescue
    e in File.Error -> {:error, {:mint_failed, e.reason}}
  end
```

(If `Manifest.write!/2` raises something other than `File.Error` on permission failure, rescue what it actually raises — check its implementation; the test in Step 1 pins the observable contract `{:error, {:mint_failed, reason}}`.)

- [ ] **Step 4: Extend inspect + add the RPC.** In `icms.ex`, rework `load_and_validate_manifest/1` and the failure helper so every result carries `"adoptable"`:

```elixir
  defp load_and_validate_manifest(resolved) do
    case Manifest.load(resolved) do
      {:ok, manifest} ->
        %{"ok" => true, "name" => manifest.name, "description" => manifest.description,
          "reason" => nil, "adoptable" => false}

      {:error, :missing} ->
        %{"ok" => false, "name" => nil, "description" => nil,
          "reason" => "no icm.yaml found in that folder", "adoptable" => true}

      {:error, {:invalid, reason}} ->
        inspect_failure(reason)
    end
  end
```

(the `format: 2` pattern-match is gone — any loadable manifest inspects ok, matching what `mount/2` accepts; `inspect_failure/1` gains `"adoptable" => false`). Add `adoptable: [type: :boolean, allow_nil?: false]` to the `:inspect_icm` action's constraints. Add the new action (mirror `:mount_icm`'s structure at `icms.ex:156-177` including `broadcast_mounts_changed/0`):

```elixir
    action :adopt_icm, :map do
      constraints fields: [
                    mount_key: [type: :string, allow_nil?: false],
                    id: [type: :string, allow_nil?: false]
                  ]

      argument :path, :string, allow_nil?: false
      argument :name, :string, allow_nil?: false
      argument :generation, :integer, allow_nil?: false

      run fn input, _ctx ->
        %{path: path, name: name, generation: generation} = input.arguments

        with :ok <- Manager.check_generation(generation),
             {:ok, %{path: workspace}} <- Manager.current(),
             {:ok, result} <- Valea.Mounts.adopt(workspace, path, name) do
          broadcast_mounts_changed()
          {:ok, result}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end
```

Register in `api.ex`'s Icms block: `rpc_action(:adopt_icm, :adopt_icm)`. Make sure this module's `error_for/1` renders `{:mint_failed, reason}` as a string carrying the OS reason (add a clause `error_for({:mint_failed, reason})` → `Error.new("mint_failed: #{inspect(reason)}")` if the generic clause doesn't already).

- [ ] **Step 5: Run + regen + commit.**
Run: `cd backend && mix test && mix ash_typescript.codegen && cd ../frontend && bun run check && bun run test`
Expected: green (the FE ignores the new `adoptable` field until Task 13).
```bash
git add -A backend frontend/src/lib/api
git commit -m "feat(backend): adopt-a-folder — inspect adoptable flag, format-1 alignment, adopt_icm RPC (Spec D §D4)"
```

---

### Task 13: Adopt-a-folder (frontend) — consent step in both mount flows

**Files:**
- Modify: `frontend/src/lib/api/client.ts` (`adoptIcm` wrapper + `inspectIcm` fields gain `adoptable`), `frontend/src/lib/components/onboarding/onboarding-path.ts` (`IcmInspection` + new `adoptExistingIcm`), `frontend/src/lib/components/shell/mount-icm-action.ts` (`mountExisting` surfaces adoptability + new `adoptExisting`), `frontend/src/lib/components/knowledge/MountFromElsewhereDialog.svelte` (consent UI), the onboarding "Use existing" flow component (grep `useExistingIcm` in `frontend/src` — expected `OpenWorkspaceFlow.svelte`; add the same consent UI), and the matching test files (`onboarding-path` tests, `mount-icm-action` tests — extend the existing suites)

**Interfaces:**
- Consumes: `adopt_icm` RPC (Task 12); existing `mountExisting`/`useExistingIcm` orchestration shapes (verbatim contracts in their doc comments).
- Produces: `IcmInspection` gains `adoptable: boolean`; `MountExistingOutcome` gains variant `{ ok: false; stage: 'adoptable'; inspection: IcmInspection }`; `adoptExisting(path, name, generation, deps): Promise<MountExistingOutcome>`; `adoptExistingIcm(path, workspaceName, name, deps): Promise<UseExistingIcmOutcome>` (onboarding twin). Consent copy (spec §D4, exact): **"Add a small identity file (icm.yaml) so Valea can recognize this folder."** with an editable Name field defaulting to the folder's basename.

**Steps:**

- [ ] **Step 1: Write the failing orchestration tests.** In the `mount-icm-action` test suite:

```ts
test('mountExisting surfaces an adoptable folder instead of a dead-end error', async () => {
  const deps = {
    inspectIcm: async () => ({
      ok: true as const,
      data: { ok: false, name: null, description: null, reason: 'no icm.yaml found in that folder', adoptable: true }
    }),
    mountIcm: async () => { throw new Error('must not mount'); }
  };
  const outcome = await mountExisting('/tmp/life', 1, deps);
  expect(outcome).toEqual({
    ok: false,
    stage: 'adoptable',
    inspection: expect.objectContaining({ adoptable: true })
  });
});

test('adoptExisting mints then reports the mount key', async () => {
  const calls: unknown[] = [];
  const deps = {
    adoptIcm: async (path: string, name: string, generation: number) => {
      calls.push([path, name, generation]);
      return { ok: true as const, mountKey: 'life' };
    }
  };
  const outcome = await adoptExisting('/tmp/life', 'Life', 1, deps);
  expect(outcome).toEqual({ ok: true, mountKey: 'life' });
  expect(calls).toEqual([['/tmp/life', 'Life', 1]]);
});

test('a non-adoptable inspect failure keeps the old inspect-stage shape', async () => {
  const deps = {
    inspectIcm: async () => ({
      ok: true as const,
      data: { ok: false, name: null, description: null, reason: 'manifest is garbage', adoptable: false }
    }),
    mountIcm: async () => ({ ok: true as const, mountKey: 'x' })
  };
  const outcome = await mountExisting('/tmp/x', 1, deps);
  expect(outcome).toEqual({ ok: false, stage: 'inspect', error: 'manifest is garbage' });
});
```

Mirror the same three shapes in the `onboarding-path` suite for `useExistingIcm` (adoptable inspect → `{ok:false, stage:'adoptable', inspection}` WITHOUT creating a workspace) and `adoptExistingIcm` (createWorkspace → generation → adoptIcm → goToMountedIcm, with the same pending-error handling `useExistingIcm` gives its mount stage).

- [ ] **Step 2: Run to verify failure.**
Run: `cd frontend && bun run test -- mount-icm-action onboarding-path`
Expected: FAIL.

- [ ] **Step 3: Implement the orchestration.**
  - `onboarding-path.ts`: add `adoptable: boolean` to `IcmInspection` (and default it `false` where the RPC result is cast, i.e. `data.adoptable === true`). Extend `UseExistingIcmOutcome`/`MountExistingOutcome` with the `'adoptable'` variant carrying `inspection`. In `useExistingIcm` and `mountExisting`, replace the `if (!inspection.ok)` early-return with:

```ts
  if (!inspection.ok) {
    if (inspection.adoptable) {
      return { ok: false, stage: 'adoptable', inspection };
    }
    return { ok: false, stage: 'inspect', error: inspection.reason ?? 'not_a_healthy_icm' };
  }
```

  - `mount-icm-action.ts`: add

```ts
export type AdoptExistingDeps = {
  /** `Valea.Api.Icms.adopt_icm` — mints `{format: 2, id, name}` into the folder (the one consented write), then mounts by reference. */
  adoptIcm: (path: string, name: string, generation: number) => Promise<{ ok: true; mountKey: string } | { ok: false; error: string }>;
};

export async function adoptExisting(
  path: string,
  name: string,
  generation: number,
  deps: AdoptExistingDeps
): Promise<MountExistingOutcome> {
  const result = await deps.adoptIcm(path, name, generation);
  if (!result.ok) return { ok: false, stage: 'mount', error: result.error };
  return { ok: true, mountKey: result.mountKey };
}
```

  - `onboarding-path.ts`: add `adoptExistingIcm(path, workspaceName, name, deps)` — a copy of `useExistingIcm`'s post-inspect body (createWorkspace → currentGeneration → mount-stage error handling → goToMountedIcm) with `deps.adoptIcm(path, name, generation)` in place of `deps.mountIcm(path, generation)`, and the ICM display name = the user-entered `name` (not the manifest's — there is none yet).
  - `client.ts`: add the `adoptIcm` wrapper (mirror `mountIcm`'s wrapper exactly, with `input: { path, name, generation }` and fields `['mountKey', 'id']`), and add `'adoptable'` to `inspectIcmFields`.

- [ ] **Step 4: Add the consent UI.** In `MountFromElsewhereDialog.svelte`: when the preview state holds an `inspection` with `ok === false && adoptable === true`, render instead of the failure text:

```svelte
  <div class="flex flex-col gap-2.5">
    <p class="text-ink-body text-[13px]">
      This folder isn't a Valea ICM yet. Add a small identity file (icm.yaml) so Valea can
      recognize this folder. That's the only file Valea will write.
    </p>
    <div class="flex flex-col gap-1.5">
      <Label for="adopt-name">Name</Label>
      <Input id="adopt-name" bind:value={adoptName} disabled={mounting} />
    </div>
    <Button type="button" disabled={mounting || !adoptName.trim()} onclick={() => void submitAdopt()}>
      Add identity file &amp; mount
    </Button>
  </div>
```

with `adoptName` defaulting to the picked path's basename when the adoptable inspection arrives (reuse the module's existing `basename` helper if one exists, else `path.split('/').filter(Boolean).at(-1) ?? ''`), and `submitAdopt()` calling `adoptExisting(path, adoptName.trim(), workspaceStore.generation ?? 0, { adoptIcm: adoptIcmDep })` where `adoptIcmDep` mirrors the dialog's existing `mountIcmDep` (calls `api.adoptIcm`, clears pending errors, refreshes `mountsStore`, returns the mountKey). On success, run the same `onMounted` continuation the normal mount path uses. Apply the same consent block to the onboarding "Use existing" preview card (the `useExistingIcm` consumer found in Step 1's grep), calling `adoptExistingIcm` with its dep set.

- [ ] **Step 5: Run the FE suite.**
Run: `cd frontend && bun run check && bun run test`
Expected: green.

- [ ] **Step 6: Commit.**
```bash
git add -A frontend
git commit -m "feat(frontend): adopt-a-folder consent step in onboarding + mount dialog (Spec D §D4)"
```

---

### Task 14: Starter seed — the 3-layer prose pattern

**Files:**
- Delete: `backend/priv/icm_template/Decisions/` (whole dir), `backend/priv/icm_template/Templates/` (whole dir) (`Workflows/` already deleted in Task 4)
- Create: `backend/priv/icm_template/clients/CONTEXT.md`, `backend/priv/icm_template/clients/docs/working-with-clients.md`
- Modify: `backend/priv/icm_template/AGENTS.md` (replace), `backend/priv/icm_template/CONTEXT.md` (replace), `backend/priv/icm_template/CLAUDE.md` (replace with the one-line fallback content), `backend/priv/icm_template/icm.yaml` (unchanged — verify), `backend/lib/valea/mounts.ex` (`seed_template!/2` gains the symlink step), `backend/test/valea/mounts/mounts_mutation_test.exs` (template assertions)

**Interfaces:**
- Consumes: `seed_template!/2` (`mounts.ex:523-535`) — `File.cp_r!` + `{{name}}` substitution in `AGENTS.md`/`CONTEXT.md`.
- Produces: every `Valea.Mounts.create/3`-minted ICM seeds: `icm.yaml`, `AGENTS.md` (the map, documents `today.json` + secrets + routing), `CLAUDE.md` as a RELATIVE symlink to `AGENTS.md` (fallback: a one-line `@AGENTS.md` import file when symlinking fails), `CONTEXT.md` (prose router + correctly-documented ROOT-level `related_icms` frontmatter), one example domain folder `clients/` with its own `CONTEXT.md` + `docs/`. No `Workflows/`, no `Templates/`, no `Decisions/`.

**Steps:**

- [ ] **Step 1: Write the failing template tests.** Replace the seed assertions in `mounts_mutation_test.exs` (the describe covering `create/3` seeding):

```elixir
test "create/3 seeds the 3-layer prose pattern" do
  {:ok, %{mount_key: key}} = Valea.Mounts.create(workspace, "Mara Coaching", folder)
  root = Valea.Mounts.mount_by_key(workspace, key).root

  agents = File.read!(Path.join(root, "AGENTS.md"))
  assert agents =~ "Mara Coaching"
  assert agents =~ "today.json"
  assert agents =~ "secrets"

  context = File.read!(Path.join(root, "CONTEXT.md"))
  assert context =~ "| Task |"
  assert context =~ "related_icms"

  assert File.exists?(Path.join(root, "clients/CONTEXT.md"))
  assert File.exists?(Path.join(root, "clients/docs/working-with-clients.md"))

  refute File.dir?(Path.join(root, "Workflows"))
  refute File.dir?(Path.join(root, "Templates"))
  refute File.dir?(Path.join(root, "Decisions"))

  claude = Path.join(root, "CLAUDE.md")
  case File.read_link(claude) do
    {:ok, target} -> assert target == "AGENTS.md"
    {:error, _} -> assert File.read!(claude) == "@AGENTS.md\n"
  end
end

test "seeded CONTEXT.md frontmatter parses as an empty related_icms declaration" do
  # create as above, then:
  assert %{related: [], issues: []} = Valea.Mounts.Context.resolve(workspace, mount)
end
```

Also update the AGENTS.md line-count guard: `assert length(String.split(agents, "\n")) < 100`.

- [ ] **Step 2: Run to verify failure.**
Run: `cd backend && mix test test/valea/mounts/mounts_mutation_test.exs`
Expected: FAIL (old template).

- [ ] **Step 3: Write the template files.**

`backend/priv/icm_template/AGENTS.md` (under 100 lines — this is the whole file):

```markdown
# {{name}} — agent map

This folder is an ICM: a portable, user-owned context project. You (the
agent) interpret its prose — nothing in here is a schema, and no folder
name is magic. Start at `CONTEXT.md`, the router, before any task.

## How this ICM is organized

- `CONTEXT.md` — the router: a prose table mapping tasks to places. Every
  domain folder that grows keeps its own `CONTEXT.md` router too.
- One folder per domain of work (`clients/` is the seeded example). Keep
  documents next to the work they describe; nesting is fine and normal.
- `docs/` inside a domain folder holds its reference material.
- Prose files are Markdown. Name files lowercase-with-dashes.

## Conventions you maintain

### today.json

`today.json` at this ICM's root is what Valea's Today page renders. Valea
never writes it — you do, whenever you prepare work or notice open loops.
All fields optional; unknown fields are ignored:

    {
      "updated_at": "2026-07-16T08:00:00Z",
      "prepared": [{ "title": "…", "summary": "…", "page": "relative/path.md" }],
      "open_loops": [{ "title": "…", "source": "…" }],
      "notes": ""
    }

`page` values are paths relative to this ICM's root; Valea renders them as
links into Knowledge.

### Secrets

Documents store POINTERS to secrets ("the API key lives in the system
keychain"), never values. Valea denies reads and writes on `secrets/`
folders, `.env*` files, key material (`*.pem`, `*.key`), and anything named
like credentials — do not route work through such files.

### Routing

When you add a folder or a significant document, add a row to the nearest
`CONTEXT.md` so the next session can find it without searching.

## Working style

- Follow the routing tables rather than globbing the tree.
- Every file change you make is reviewed live by the user through Valea's
  permission gate — propose precise, minimal edits.
```

`backend/priv/icm_template/CONTEXT.md` (whole file):

```markdown
---
format: 1
related_icms: []
---

# {{name}} — router

Find your task, go where the row points. Keep this table current.

| Task | Go here | You'll also need |
| ---- | ------- | ---------------- |
| Anything about a client | `clients/CONTEXT.md` | — |
| Update what Today shows | `today.json` at this root | the shape in `AGENTS.md` |
| Add a new domain of work | create `<domain>/CONTEXT.md`, add a row here | `AGENTS.md` |

<!--
Related ICMs — root CONTEXT.md frontmatter only (nested CONTEXT.md files
route prose; they do not declare context). To give sessions in this ICM
read access to another mounted ICM, list it above:

related_icms:
  - id: <the other ICM's icm.yaml id (UUID)>
    name: <display name>
    entrypoint: CONTEXT.md
-->
```

`backend/priv/icm_template/CLAUDE.md` (whole file — the symlink fallback content; Step 4 turns it into a real symlink where the filesystem allows):

```markdown
@AGENTS.md
```

`backend/priv/icm_template/clients/CONTEXT.md` (whole file):

```markdown
# Clients — router

One folder per client, named after them. Reference material lives in
`docs/`.

| Task | Go here | You'll also need |
| ---- | ------- | ---------------- |
| How we work with clients | `docs/working-with-clients.md` | — |
| Start a new client | create `<client-name>/`, add a row here | `docs/working-with-clients.md` |
```

`backend/priv/icm_template/clients/docs/working-with-clients.md` (whole file):

```markdown
# Working with clients

Seeded example reference. Replace this with how YOU work: intake questions,
tone, boundaries, follow-up cadence. Documents like this are what sessions
read before acting — keep them true.
```

`icm.yaml` stays exactly as-is (placeholder id + `{{name}}`).

- [ ] **Step 4: Symlink the seed.** In `mounts.ex`, extend `seed_template!/2`:

```elixir
  defp seed_template!(dest, name) do
    File.cp_r!(icm_template_dir(), dest)

    for rel <- ["AGENTS.md", "CONTEXT.md"] do
      path = Path.join(dest, rel)

      if File.exists?(path) do
        File.write!(path, path |> File.read!() |> String.replace("{{name}}", name))
      end
    end

    link_claude_md!(dest)
    :ok
  end

  # CLAUDE.md is a RELATIVE symlink to AGENTS.md (one map, two harness
  # entry names). Filesystems/platforms without symlink support keep the
  # template's one-line `@AGENTS.md` import file instead (Spec D §D1).
  defp link_claude_md!(dest) do
    path = Path.join(dest, "CLAUDE.md")

    case File.rm(path) do
      :ok ->
        case File.ln_s("AGENTS.md", path) do
          :ok -> :ok
          {:error, _reason} -> File.write!(path, "@AGENTS.md\n")
        end

      {:error, _reason} ->
        :ok
    end
  end
```

- [ ] **Step 5: Run the suite.**
Run: `cd backend && mix test`
Expected: PASS — including any other test that asserted old template contents (fix any straggler assertions the run surfaces; `grep -rn "Distill\|Decisions/2026\|Templates/Client" backend/test` must end at zero).

- [ ] **Step 6: Commit.**
```bash
git add -A backend
git commit -m "feat(backend): starter seed = 3-layer prose pattern with CLAUDE.md symlink (Spec D §D1)"
```

---

### Task 15: Recursive `templates/` discovery (frontend)

**Files:**
- Modify: `frontend/src/lib/components/knowledge/template-options.ts` (rewrite), `frontend/src/lib/components/knowledge/template-options.test.ts` (rewrite), `frontend/src/lib/components/knowledge/NewEntryDialog.svelte` (`:39` derivation + `:131-146` select → optgroups)

**Interfaces:**
- Consumes: `MountGroup`/`IcmNode` (unchanged); `createIcmPageFromTemplate` RPC (unchanged — it already accepts arbitrary same-mount template paths).
- Produces: `templateGroups(groups: MountGroup[], mountKey: string): TemplateGroup[]` with `TemplateGroup = { label: string; options: TemplateOption[] }`, `TemplateOption = { label: string; path: string }` — one group per folder named `templates` (case-insensitive) at ANY depth, `label` = the folder's tree path, options = the `.md` pages directly inside it, tree order, empty groups dropped. The old `templateOptions` export is deleted.

**Steps:**

- [ ] **Step 1: Rewrite the test file.** Replace `template-options.test.ts` (keep its `MountGroup` fixture-building helpers, extended for nesting):

```ts
import { describe, expect, test } from 'vitest';
import { templateGroups } from './template-options';
// build MountGroup fixtures the way the current file does

describe('templateGroups', () => {
  test('finds a top-level Templates folder (case-insensitive)', () => {
    // tree: Templates/{Client.md, Decision.md}
    expect(templateGroups(groups, 'icm')).toEqual([
      { label: 'Templates', options: [
        { label: 'Client', path: 'Templates/Client.md' },
        { label: 'Decision', path: 'Templates/Decision.md' }
      ]}
    ]);
  });

  test('finds nested lowercase templates/ folders at any depth', () => {
    // tree: clients/kita/templates/{Prep.md}, ops/TEMPLATES/{Runbook.md}
    const result = templateGroups(groups, 'icm');
    expect(result.map((g) => g.label)).toEqual(['clients/kita/templates', 'ops/TEMPLATES']);
    expect(result[0].options).toEqual([{ label: 'Prep', path: 'clients/kita/templates/Prep.md' }]);
  });

  test('only direct .md pages count; subfolders inside a templates dir are not flattened', () => {
    // templates/{A.md, sub/{B.md}} → one group with only A;
    // BUT templates/sub is itself matched only if named templates
    const result = templateGroups(groups, 'icm');
    expect(result[0].options.map((o) => o.label)).toEqual(['A']);
  });

  test('empty templates folders and unknown mounts yield []', () => {
    expect(templateGroups(groupsWithEmpty, 'icm')).toEqual([]);
    expect(templateGroups(groups, 'nope')).toEqual([]);
    expect(templateGroups([], 'icm')).toEqual([]);
  });
});
```

- [ ] **Step 2: Run to verify failure.**
Run: `cd frontend && bun run test -- template-options`
Expected: FAIL (`templateGroups` not exported).

- [ ] **Step 3: Rewrite the module.** Replace `template-options.ts`:

```ts
/**
 * Recursive template discovery for NewEntryDialog's "Start from" select
 * (Spec D §D2): any folder named `templates` (case-insensitive) at ANY
 * depth in the selected mount's tree contributes a group of its direct
 * `.md` pages. The backend RPC (`createIcmPageFromTemplate`) never had a
 * location restriction — this discovery layer was the only thing pinning
 * templates to one top-level folder.
 */
import type { MountGroup } from '$lib/stores/icm.svelte';
import type { IcmNode } from '$lib/shell/nav';

export type TemplateOption = { label: string; path: string };
export type TemplateGroup = { label: string; options: TemplateOption[] };

export function templateGroups(groups: MountGroup[], mountKey: string): TemplateGroup[] {
  const group = groups.find((g) => g.mount === mountKey);
  if (!group) return [];

  const folders: (IcmNode & { type: 'folder' })[] = [];
  const walk = (nodes: IcmNode[] | undefined) => {
    for (const node of nodes ?? []) {
      if (node.type !== 'folder') continue;
      if (node.name.toLowerCase() === 'templates') folders.push(node);
      walk(node.children);
    }
  };
  walk(group.tree);

  return folders
    .map((folder) => ({
      label: folder.path,
      options: (folder.children ?? [])
        .filter((n): n is IcmNode & { type: 'page' } => n.type === 'page')
        .map((n) => ({ label: n.name, path: n.path }))
    }))
    .filter((g) => g.options.length > 0);
}
```

(If `IcmNode`'s folder variant lacks a `path` field, derive the label by joining ancestor names during the walk instead — check `frontend/src/lib/shell/nav.ts:13-31` first.)

- [ ] **Step 4: Update NewEntryDialog.** `:39` becomes `const groups = $derived(mode === 'page' ? templateGroups(icmStore.groups, mountKey) : []);` and the select renders optgroups when more than one group:

```svelte
      <select id="new-entry-template" bind:value={templatePath} disabled={submitting} class="...">
        <option value="">Empty page</option>
        {#if groups.length === 1}
          {#each groups[0].options as option (option.path)}
            <option value={option.path}>{option.label}</option>
          {/each}
        {:else}
          {#each groups as group (group.label)}
            <optgroup label={group.label}>
              {#each group.options as option (option.path)}
                <option value={option.path}>{option.label}</option>
              {/each}
            </optgroup>
          {/each}
        {/if}
      </select>
```

(keep the surrounding `{#if mode === 'page'}` block and submit logic untouched — `templatePath` still carries the ICM-relative path).

- [ ] **Step 5: Run the FE suite + commit.**
Run: `cd frontend && bun run check && bun run test`
Expected: green.
```bash
git add -A frontend
git commit -m "feat(frontend): recursive case-insensitive templates/ discovery with grouped picker (Spec D §D2)"
```

---

### Task 16: Docs sweep, acceptance re-scope, final deletion gate

**Files:**
- Modify: `docs/ARCHITECTURE.md` (delete the Workflow/Runner/Queue/proposal/MailboxOps sections; add: session-with-context primitive with `context_doc`/`input` + fail-closed atoms, today.json cockpit contract, adopt-a-folder, secrets deny tier, depth-aware RiskTier, 3-layer starter seed, `Valea.Api.Audit`), `docs/VISION.md` (workflow-pipeline language → agent-interprets-prose language; check `grep -n "workflow\|queue\|distill\|triage" docs/VISION.md`), `docs/superpowers/acceptance/2026-07-13-icm-project-workspaces.md` (append a short "Spec D re-scope" note: S6's workflow scenario is superseded; its replacement — "start a session with a workflow doc + input, observe ask-gated execution" — was live-verified 2026-07-16 per `docs/notes/acp-launch-contract.md`), `backend/priv/icm_template` — no change here (Task 14 owns it); fix any remaining stale doc claims the greps below surface
- Test: none (docs) — the deliverable is the grep gate + full suite

**Steps:**

- [ ] **Step 1: Run the deletion-completeness gate.** Every one of these must print NOTHING (from repo root):

```bash
grep -rn "Valea\.Workflows\|Workflows\.Runner\|MemoryProposal\|Valea\.Queue\|MailboxOps\|DraftMime\|decide_legacy\|workflow_contract\|run_generated\|distill_decisions\|run_workflow\|list_workflows\|list_queue_items\|approve_queue_item\|reject_queue_item\|retry_mailbox_ops" backend/lib backend/test
grep -rn "runWorkflow\|listWorkflows\|distillDecisions\|listQueueItems\|getQueueItem\|approveQueueItem\|rejectQueueItem\|listDecidedQueueItems\|retryMailboxOps\|queueStore\|wireQueueEvents\|workflowEditHref\|triageCandidates\|buildMemoryReview\|distillButtonState\|templateOptions\b" frontend/src
grep -rn "queue_changed\|mailbox_ops\|mail_ops" backend/lib frontend/src
grep -rn "session_kind == \"workflow\"\|kind == \"workflow\"" backend/lib
```

Fix any straggler before proceeding (a hit in `docs/` or `.superpowers/` is fine; a hit in `backend/lib`, `backend/test`, or `frontend/src` is not).

- [ ] **Step 2: Update the three docs** per the Files list. ARCHITECTURE.md accuracy bar: every module/function/arity you name must exist — verify each claim with a grep before writing it (the [12.1] review failed on exactly this).

- [ ] **Step 3: Full gate.**
Run: `just test`
Expected: backend suite, codegen freshness, `bun run check`, `bun run test` all green.

- [ ] **Step 4: Commit.**
```bash
git add -A docs
git commit -m "docs: architecture/vision/acceptance re-scope for agent-native ICMs (Spec D §D6)"
```

---

## Post-plan (controller, not a task)

After all 16 tasks: dispatch the final whole-branch review (`superpowers:requesting-code-review`, most capable model, review package from the branch's merge base), fix-wave any findings, then `superpowers:finishing-a-development-branch`.




