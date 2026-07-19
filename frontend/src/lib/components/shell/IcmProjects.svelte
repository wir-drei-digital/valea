<script lang="ts">
  // Phase 9 sidebar "ICM project groups" (Task 9.2) — one row per
  // enabled-or-degraded ICM (`icm-projects.ts`'s `orderGroups`), each with a
  // quick "+" to start a new chat session there, a kebab of secondary
  // actions, and up to five recent sessions underneath. NOT wired into the
  // app shell yet — that's Task 9.3's job; this component only needs to
  // exist and pass its own tests until then. Presentational over
  // `icm-projects.ts`'s pure ordering/capping/expansion helpers — every
  // decision beyond "how does a row read" lives there, unit-tested.
  import { goto } from '$app/navigation';
  import { api } from '$lib/api/client';
  import { mountsStore } from '$lib/stores/mounts.svelte';
  import { recentSessionsStore } from '$lib/stores/recent-sessions.svelte';
  import { workspaceStore } from '$lib/stores/workspace.svelte';
  import { degradedChipLabel } from '$lib/components/knowledge/mount-sections';
  import type { AgentSessionSummary } from '$lib/stores/sessions-list.svelte';
  import { orderGroups, isGroupExpanded, diagnosisSummary } from './icm-projects';
  import {
    normalizeMountsDoctorChecks,
    type MountsDoctorCheck
  } from '$lib/components/knowledge/mount-sections';
  import * as DropdownMenu from '$lib/components/ui/dropdown-menu/index.js';
  import * as Dialog from '$lib/components/ui/dialog/index.js';
  import ChevronRight from '@lucide/svelte/icons/chevron-right';
  import Plus from '@lucide/svelte/icons/plus';
  import Ellipsis from '@lucide/svelte/icons/ellipsis';
  import TriangleAlert from '@lucide/svelte/icons/triangle-alert';
  import MessageSquarePlus from '@lucide/svelte/icons/message-square-plus';
  import FolderOpen from '@lucide/svelte/icons/folder-open';
  import PowerOff from '@lucide/svelte/icons/power-off';
  import Stethoscope from '@lucide/svelte/icons/stethoscope';

  let {
    /**
     * The ICM the current route is scoped to (e.g. a `/knowledge?icm=`
     * page) — its group always renders expanded, overriding local collapse
     * state (`icm-projects.ts`'s `isGroupExpanded`). `null` (default) until
     * Task 9.3 wires a real caller passing route state in.
     */
    activeMountKey = null
  }: { activeMountKey?: string | null } = $props();

  const groups = $derived(orderGroups(mountsStore.mounts, recentSessionsStore.groups));

  // Local, in-memory only (not persisted) — same "collapse is an opt-in the
  // user reaches for" default `isGroupExpanded` documents.
  let collapsed: Record<string, boolean> = $state({});
  let starting: Record<string, boolean> = $state({});
  let startError: Record<string, string> = $state({});
  let disabling: Record<string, boolean> = $state({});
  let diagnosing: Record<string, boolean> = $state({});
  /** The open Diagnose dialog's payload — detailed checks in a modal, never inline in the tree. */
  let doctorModal: {
    name: string;
    ok: boolean;
    summary: string;
    checks: MountsDoctorCheck[];
  } | null = $state(null);

  function toggle(mountKey: string): void {
    collapsed = { ...collapsed, [mountKey]: !collapsed[mountKey] };
  }

  function sessionTitle(session: AgentSessionSummary): string {
    if (session.title && session.title.trim().length > 0) return session.title;
    if (session.kind === 'workflow') return 'Workflow run';
    return 'Chat session';
  }

  function startSessionErrorMessage(code: string): string {
    switch (code) {
      case 'workspace_changed':
        return 'Your workspace changed. Reopen it and try again.';
      case 'workspace_not_open':
        return 'No workspace is open.';
      case 'icm_unavailable':
        return "That ICM isn't available right now.";
      case 'harness_unavailable':
        return "The assistant isn't ready yet. Check Chat for details.";
      default:
        return 'The session could not be started. Please try again.';
    }
  }

  // The kebab's "New session" is deliberately the SAME handler as the row's
  // own "+" (ambiguity resolution, task brief) — both start a chat session
  // against this ICM and land on it.
  async function startSession(mountKey: string): Promise<void> {
    startError = { ...startError, [mountKey]: '' };
    starting = { ...starting, [mountKey]: true };
    const result = await api.createAgentSession(mountKey, workspaceStore.generation ?? 0);
    starting = { ...starting, [mountKey]: false };

    if (result.ok) {
      const data = result.data as { id: string };
      // No workspace-level push fires for "a session was just created" (see
      // `wireRecentSessionsEvents`'s doc comment in `recent-sessions.svelte.ts`)
      // — refresh directly so the new session appears under its group
      // without waiting for the next unrelated refresh.
      void recentSessionsStore.refresh();
      void goto(`/chat?session=${data.id}`);
    } else {
      startError = { ...startError, [mountKey]: startSessionErrorMessage(result.error) };
    }
  }

  async function disable(mountKey: string): Promise<void> {
    disabling = { ...disabling, [mountKey]: true };
    await mountsStore.setEnabled(mountKey, false, workspaceStore.generation ?? 0);
    disabling = { ...disabling, [mountKey]: false };
  }

  // "Diagnose" (kebab) — runs `icm_doctor` against this one ICM and shows
  // the DETAILED checks in a modal (same shape `MountsDoctorPanel` renders
  // on the Files page; `normalizeMountsDoctorChecks` shapes both). The
  // one-line verdict is `icm-projects.ts`'s `diagnosisSummary` — counts
  // every non-"ok" check, not just "failed", so an `ok: false` result made
  // of "unknown" checks doesn't misread as healthy.
  async function diagnose(mountKey: string, name: string): Promise<void> {
    diagnosing = { ...diagnosing, [mountKey]: true };
    const result = await api.icmDoctor(mountKey, workspaceStore.generation ?? 0);
    diagnosing = { ...diagnosing, [mountKey]: false };

    if (!result.ok) {
      doctorModal = { name, ok: false, summary: 'Could not run checks. Try again.', checks: [] };
      return;
    }

    const data = result.data as { ok: boolean; checks: unknown };
    doctorModal = {
      name,
      ...diagnosisSummary(data as { ok: boolean; checks: Array<{ status?: string }> }),
      checks: normalizeMountsDoctorChecks(data.checks)
    };
  }
</script>

<div class="flex flex-col gap-0.5">
  {#each groups as group (group.mountKey)}
    {@const expanded = isGroupExpanded(group, activeMountKey, collapsed)}
    <div class="group/icm relative">
      <div class="flex items-center gap-1 rounded-md py-[3px] pr-9 pl-2">
        <button
          type="button"
          onclick={() => toggle(group.mountKey)}
          aria-label={expanded ? `Collapse ${group.name}` : `Expand ${group.name}`}
          class="text-ink-meta shrink-0"
        >
          <ChevronRight
            class={['size-3 transition-transform', expanded ? 'rotate-90' : '']}
            strokeWidth={1.5}
          />
        </button>
        <a
          href={`/knowledge?icm=${encodeURIComponent(group.mountKey)}`}
          class={[
            'min-w-0 flex-1 truncate text-[12.5px]',
            group.mountKey === activeMountKey ? 'text-ink-heading font-semibold' : 'text-ink-secondary'
          ]}
        >
          {group.name}
        </a>
        {#if group.degraded}
          <TriangleAlert class="text-warn-ink size-3.5 shrink-0" strokeWidth={1.5} aria-hidden="true" />
        {:else}
          <!-- Opening the project's file browser is the row's first-class
               quick action (the name link goes there too); starting a
               session lives as the labeled "+ New session" child below. -->
          <button
            type="button"
            onclick={() => void goto(`/knowledge?icm=${encodeURIComponent(group.mountKey)}`)}
            aria-label={`Open files of ${group.name}`}
            class="text-ink-meta hover:bg-paper-card hover:text-ink-heading shrink-0 rounded-md p-0.5 opacity-0 transition-opacity group-hover/icm:opacity-100 group-focus-within/icm:opacity-100 focus-visible:opacity-100"
          >
            <FolderOpen class="size-3.5" strokeWidth={1.5} />
          </button>
        {/if}
      </div>

      <DropdownMenu.Root>
        <DropdownMenu.Trigger>
          {#snippet child({ props })}
            <button
              type="button"
              {...props}
              aria-label={`Actions for ${group.name}`}
              class="text-ink-meta hover:bg-paper-card hover:text-ink-heading absolute top-1/2 right-0.5 flex size-6 -translate-y-1/2 items-center justify-center rounded-md opacity-0 transition-colors group-hover/icm:opacity-100 group-focus-within/icm:opacity-100 focus-visible:opacity-100 data-[state=open]:bg-paper-card data-[state=open]:opacity-100"
            >
              <Ellipsis class="size-3.5" strokeWidth={1.5} />
            </button>
          {/snippet}
        </DropdownMenu.Trigger>
        <DropdownMenu.Content align="end">
          {#if !group.degraded}
            <DropdownMenu.Item
              disabled={!!starting[group.mountKey]}
              onSelect={() => void startSession(group.mountKey)}
            >
              <MessageSquarePlus class="size-3.5" strokeWidth={1.5} />
              New session
            </DropdownMenu.Item>
          {/if}
          <DropdownMenu.Item onSelect={() => void goto(`/knowledge?icm=${encodeURIComponent(group.mountKey)}`)}>
            <FolderOpen class="size-3.5" strokeWidth={1.5} />
            Open files
          </DropdownMenu.Item>
          <DropdownMenu.Item
            disabled={!!diagnosing[group.mountKey]}
            onSelect={() => void diagnose(group.mountKey, group.name)}
          >
            <Stethoscope class="size-3.5" strokeWidth={1.5} />
            {diagnosing[group.mountKey] ? 'Diagnosing…' : 'Diagnose'}
          </DropdownMenu.Item>
          <DropdownMenu.Item disabled={!!disabling[group.mountKey]} onSelect={() => void disable(group.mountKey)}>
            <PowerOff class="size-3.5" strokeWidth={1.5} />
            Disable
          </DropdownMenu.Item>
        </DropdownMenu.Content>
      </DropdownMenu.Root>
    </div>

    {#if expanded}
      <div class="border-paper-chip-border ml-[17px] flex flex-col gap-0.5 border-l pl-2">
        {#if group.degraded}
          <p class="text-warn-ink px-2 py-1 text-[11px]">{degradedChipLabel(group)}</p>
        {:else}
          <button
            type="button"
            onclick={() => void startSession(group.mountKey)}
            disabled={!!starting[group.mountKey]}
            class="text-ink-meta hover:text-ink-heading flex items-center gap-1.5 px-2 py-1 text-left text-[12px]"
          >
            <Plus class="size-3" strokeWidth={1.5} aria-hidden="true" />
            New session
          </button>
          {#each group.sessions as session (session.id)}
            <a
              href={`/chat?session=${session.id}`}
              class="text-ink-secondary hover:bg-paper-pill flex items-center gap-1.5 rounded-md px-2 py-[3px] text-[12px] transition-colors"
            >
              {#if session.live}
                <span class="bg-act-dot size-1.5 shrink-0 rounded-full" aria-hidden="true"></span>
              {:else}
                <span class="size-1.5 shrink-0" aria-hidden="true"></span>
              {/if}
              <span class="min-w-0 flex-1 truncate">{sessionTitle(session)}</span>
            </a>
          {/each}
          {#if group.hasMore}
            <a
              href={`/chat?icm=${encodeURIComponent(group.mountKey)}`}
              class="text-ink-meta hover:text-ink-heading px-2 py-1 text-[11.5px]"
            >
              Show all…
            </a>
          {/if}
        {/if}

        {#if startError[group.mountKey]}
          <p class="text-warn-ink px-2 py-0.5 text-[11px]" role="alert">{startError[group.mountKey]}</p>
        {/if}
      </div>
    {/if}
  {/each}
</div>

<!-- Diagnose result — a modal with the full gated checks, never inline in
     the project tree (same ✓/✕/○ vocabulary as the calendar setup panel;
     "unknown" = gated behind an earlier failure, muted, not failed). -->
<Dialog.Root open={doctorModal !== null} onOpenChange={(open) => !open && (doctorModal = null)}>
  <Dialog.Content class="sm:max-w-md">
    {#if doctorModal}
      <Dialog.Header>
        <Dialog.Title class="font-display text-[19px] text-ink-heading">
          Diagnose: {doctorModal.name}
        </Dialog.Title>
        <Dialog.Description class={doctorModal.ok ? 'text-ink-body' : 'text-warn-ink'}>
          {doctorModal.summary}
        </Dialog.Description>
      </Dialog.Header>
      {#if doctorModal.checks.length > 0}
        <ul class="flex flex-col gap-1.5">
          {#each doctorModal.checks as check (check.id)}
            <li class="text-[12px]">
              <span
                class={check.status === 'ok'
                  ? 'text-act'
                  : check.status === 'failed'
                    ? 'text-warn-ink'
                    : 'text-ink-meta'}
              >
                {check.status === 'ok' ? '✓' : check.status === 'failed' ? '✕' : '○'}
              </span>
              <span class="text-ink-body">{check.label}</span>
              {#if check.detail}
                <span class="text-ink-meta"> · {check.detail}</span>
              {/if}
              {#if check.status === 'failed' && check.remedy}
                <p class="text-ink-meta mt-0.5 pl-4 font-mono text-[11px]">{check.remedy}</p>
              {/if}
            </li>
          {/each}
        </ul>
      {/if}
    {/if}
  </Dialog.Content>
</Dialog.Root>
