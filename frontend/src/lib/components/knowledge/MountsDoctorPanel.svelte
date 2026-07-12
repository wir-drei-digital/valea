<script lang="ts">
  // Mounts doctor (A2-T7/T9) — same presentation pattern as
  // `agent/DoctorPanel.svelte` / `mail/MailDoctorPanel.svelte` (status icon,
  // detail, a copyable remedy): check-row markup/classes reused verbatim.
  // The label comes straight off the check payload (`check.label`), same as
  // `MailDoctorPanel` (not a hardcoded id->label map like the agent
  // harness's fixed-4-check doctor) — `Valea.Mounts.Doctor.run/1` runs over
  // a VARIABLE number of subjects (every discovered mount), so its own
  // `"<check>:<mount name>"` ids and human `label`s are the only stable
  // thing to key off (see `normalizeMountsDoctorChecks` in
  // `mount-sections.ts`).
  //
  // Backend contract: `Valea.Mounts.Doctor.run/1` via
  // `mountsStore.doctor(generation)` — status is "ok" | "failed" |
  // "unknown" ("unknown" means an earlier check in that mount's own gate
  // failed, so this one was never attempted, OR the mount is disabled —
  // never rendered as a false "broken" claim). `remedy` is only ever
  // present on a "failed" check.
  import Check from '@lucide/svelte/icons/check';
  import X from '@lucide/svelte/icons/x';
  import CircleHelp from '@lucide/svelte/icons/circle-help';
  import Copy from '@lucide/svelte/icons/copy';
  import { Button } from '$lib/components/ui/button/index.js';
  import { mountsStore } from '$lib/stores/mounts.svelte';
  import { normalizeMountsDoctorChecks, type MountsDoctorCheck } from './mount-sections';

  let { generation }: { generation: number } = $props();

  let checks: MountsDoctorCheck[] = $state([]);
  let loading = $state(true);
  let loadFailed = $state(false);
  let copiedId: string | null = $state(null);

  async function run(): Promise<void> {
    loading = true;
    loadFailed = false;
    const result = await mountsStore.doctor(generation);
    if (result.ok) {
      checks = normalizeMountsDoctorChecks(result.data.checks);
    } else {
      loadFailed = true;
    }
    loading = false;
  }

  $effect(() => {
    void generation;
    void run();
  });

  async function copy(id: string, remedy: string): Promise<void> {
    await navigator.clipboard.writeText(remedy);
    copiedId = id;
    setTimeout(() => {
      if (copiedId === id) copiedId = null;
    }, 1500);
  }
</script>

<div class="flex flex-col gap-4 py-2">
  <div class="flex flex-col gap-1.5">
    <h2 class="font-display text-[19px] text-ink-heading">Checking your mounts</h2>
    <p class="max-w-[480px] text-[13px] text-ink-body">
      Reference resolution, manifests, secrets hygiene, and watcher coverage for every mount — embedded and
      by-reference.
    </p>
  </div>

  {#if loading}
    <p class="text-ink-meta text-[13px]">Running checks…</p>
  {:else if loadFailed}
    <p class="text-warn-ink text-[13px]">Couldn't run the checks just now. Try again in a moment.</p>
  {:else if checks.length === 0}
    <p class="text-ink-meta text-[13px]">No mounts to check yet.</p>
  {:else}
    <ul class="flex flex-col gap-2.5">
      {#each checks as check (check.id)}
        <li class="border-paper-border bg-paper-card rounded-xl border px-4 py-3">
          <div class="flex items-center gap-2.5">
            <span class="flex size-4 shrink-0 items-center justify-center" aria-hidden="true">
              {#if check.status === 'ok'}
                <Check class="text-act-dot size-4" />
              {:else if check.status === 'failed'}
                <X class="text-warn-ink size-4" />
              {:else}
                <CircleHelp class="text-suggest-ink size-4" />
              {/if}
            </span>
            <span class="text-[13.5px] font-medium text-ink-heading">
              {check.label}
            </span>
          </div>
          <p class="mt-1 pl-[26px] text-[12.5px] text-ink-body">{check.detail}</p>
          {#if check.remedy}
            <div class="mt-2 ml-[26px] flex items-center gap-2 rounded-lg bg-paper-pill px-3 py-2">
              <code class="min-w-0 flex-1 truncate font-mono text-[11.5px] text-ink-secondary">
                {check.remedy}
              </code>
              <button
                type="button"
                onclick={() => copy(check.id, check.remedy as string)}
                class="text-ink-meta hover:text-ink-heading shrink-0"
              >
                {#if copiedId === check.id}
                  <span class="text-act-dot text-[11px]">Copied</span>
                {:else}
                  <Copy class="size-3.5" aria-label="Copy remedy" />
                {/if}
              </button>
            </div>
          {/if}
        </li>
      {/each}
    </ul>
  {/if}

  <div>
    <Button type="button" variant="outline" size="sm" onclick={() => run()} disabled={loading}>
      Check again
    </Button>
  </div>
</div>
