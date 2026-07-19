<script lang="ts">
  // Preflight screen for the agent harness (docs/DESIGN_SYSTEM.md §8 row
  // vocabulary, adapted to three fixed checks rather than an open list).
  // Backend contract: `Valea.Agents.Doctor.run/0` via `api.harnessDoctor()`
  // — three independent checks (`node`, `adapter`, `auth`), each
  // `{id, status, detail, remedy}`. `status` is one of "ok" | "failed" |
  // "unknown" — "unknown" (never "failed") means the probe itself couldn't
  // run (e.g. an auth check timing out because no adapter is resolvable),
  // an honest "we don't know" rather than a false "broken" claim. `remedy`
  // is only ever present on a "failed" check (see doctor.ex's `unknown/2`
  // always passing `nil`).
  //
  // Self-contained: calls `api.harnessDoctor()` on mount and again on
  // "Check again" — the caller (Chat route) just renders this in place of
  // the transcript/empty-state, no props needed.
  import { onMount } from 'svelte';
  import Check from '@lucide/svelte/icons/check';
  import X from '@lucide/svelte/icons/x';
  import CircleHelp from '@lucide/svelte/icons/circle-help';
  import Copy from '@lucide/svelte/icons/copy';
  import { Button } from '$lib/components/ui/button/index.js';
  import { api } from '$lib/api/client';

  type DoctorCheck = { id: string; status: string; detail: string; remedy: string | null };

  const CHECK_LABELS: Record<string, string> = {
    node: 'Node.js',
    adapter: 'Claude Code adapter',
    auth: 'Sign-in'
  };

  let checks: DoctorCheck[] = $state([]);
  let loading = $state(true);
  let loadFailed = $state(false);
  let copiedId: string | null = $state(null);

  async function run(): Promise<void> {
    loading = true;
    loadFailed = false;
    const result = await api.harnessDoctor();
    if (result.ok) {
      const data = result.data as { ok: boolean; checks: DoctorCheck[] };
      checks = data.checks ?? [];
    } else {
      loadFailed = true;
    }
    loading = false;
  }

  onMount(() => {
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
    <h2 class="font-display text-[19px] text-ink-heading">Checking your assistant</h2>
    <p class="max-w-[480px] text-[13px] text-ink-body">
      Valea uses your own Claude Code. Nothing to configure in here. Sign in once in a terminal
      and check again.
    </p>
  </div>

  {#if loading}
    <p class="text-ink-meta text-[13px]">Running checks…</p>
  {:else if loadFailed}
    <p class="text-warn-ink text-[13px]">Couldn't run the checks just now. Try again in a moment.</p>
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
              {CHECK_LABELS[check.id] ?? check.id}
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
                  <Copy class="size-3.5" aria-label="Copy command" />
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
