<script lang="ts">
  import type { OpenLoop } from '$lib/today/cockpit';

  // Checklist rows (§8 task rows). The checkbox is purely visual this phase —
  // completing a loop is a later capability, so no interactive control yet.
  let { loops }: { loops: OpenLoop[] } = $props();
</script>

<ul class="divide-paper-hairline flex flex-col divide-y">
  {#each loops as loop (loop.title)}
    <li class="flex items-start gap-2.5 py-2.5">
      <span
        class="border-paper-button-border bg-paper-card mt-0.5 size-[15px] shrink-0 rounded-[4px] border"
        aria-hidden="true"
      ></span>
      <div class="min-w-0">
        <p class="text-ink-body text-[13.5px]">{loop.title}</p>
        <p class="text-ink-meta text-[12px]">{loop.source}</p>
      </div>
    </li>
  {/each}
</ul>
