<script lang="ts">
  // Renders one `tool` item: kind label -> title -> status glyph, plus an
  // optional diff and/or output block.
  //
  // SECURITY: `title`, `output`, and the diff's `path`/old/new lines are
  // tool-call content the agent (or the tool it invoked) produced — untrusted
  // the same as any other agent output. Every one of them is rendered below
  // with plain Svelte interpolation ({value}); {@html} is FORBIDDEN here.
  import Check from '@lucide/svelte/icons/check';
  import X from '@lucide/svelte/icons/x';
  import type { AcpItemLike } from './item-shapes';
  import { asString, asPresentString, toolDiff, diffLines } from './item-shapes';

  let { item }: { item: AcpItemLike } = $props();

  const kind = $derived(asString(item.kind));
  const title = $derived(asString(item.title));
  const status = $derived(asString(item.status));
  const output = $derived(asPresentString(item.output));

  const diff = $derived(toolDiff(item));
  const oldLines = $derived(diffLines(diff?.oldText));
  const newLines = $derived(diffLines(diff?.newText));
  const hasDiff = $derived(Boolean(diff && (oldLines.length || newLines.length)));
</script>

<div class="border-paper-border bg-paper-card w-full max-w-[82%] self-start overflow-hidden rounded-xl border">
  <div class="flex items-center gap-2 px-3 py-2">
    {#if kind}
      <span class="font-mono text-[10.5px] font-bold tracking-[0.05em] text-ink-meta uppercase">{kind}</span>
    {/if}
    <span class="min-w-0 flex-1 truncate font-mono text-[12.5px] font-medium text-ink-body">{title}</span>
    <span class="ml-auto flex shrink-0 items-center gap-1.5">
      {#if status === 'completed'}
        <Check class="text-act-dot size-3.5" aria-label="completed" />
      {:else if status === 'failed'}
        <X class="text-warn-ink size-3.5" aria-label="failed" />
      {:else if status}
        <span class="bg-suggest-dash size-2 animate-pulse rounded-full" role="status" aria-label="running"></span>
      {/if}
    </span>
  </div>

  {#if hasDiff}
    <div class="border-paper-hairline overflow-x-auto border-t font-mono text-[11px] leading-relaxed">
      {#if diff?.path}
        <div class="px-3 py-0.5 text-ink-meta">{diff.path}</div>
      {/if}
      {#each oldLines as line, i (`-${i}`)}
        <div class="bg-warn-tint px-3 py-px whitespace-pre text-warn-ink">-&nbsp;{line}</div>
      {/each}
      {#each newLines as line, i (`+${i}`)}
        <div class="bg-act-tint px-3 py-px whitespace-pre text-act">+&nbsp;{line}</div>
      {/each}
    </div>
  {/if}

  {#if output}
    <pre
      class="border-paper-hairline max-h-[200px] overflow-auto border-t px-3 py-2 font-mono text-[11px] whitespace-pre-wrap break-words text-ink-secondary">{output}</pre>
  {/if}
</div>
