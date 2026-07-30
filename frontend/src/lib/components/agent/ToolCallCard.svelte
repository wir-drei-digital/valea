<script lang="ts">
  // Renders one `tool` item: kind label -> title -> status glyph, plus an
  // optional diff and/or output block. The body (diff/output) is COLLAPSED
  // by default — the header row doubles as the expand toggle — so a busy
  // transcript reads as a compact list of what ran, not walls of output.
  // Read/edit calls whose title merely restates a location ("Read
  // CONTEXT.md" + a CONTEXT.md chip) collapse to one row: verb + chips,
  // no title (see `compactToolAction`).
  //
  // SECURITY: `title` (and the verb sliced out of it), `output`, the diff's
  // `path`/old/new lines AND the location chips below are tool-call content
  // the agent (or the tool it invoked) produced — untrusted the same as any
  // other agent output. Every one of them is rendered below with plain
  // Svelte interpolation ({value}); {@html} is FORBIDDEN here. A chip click
  // only hands its string to the caller, which feeds it into the `?pane=`
  // codec — never to a fetch of its own (the pane's view refetches through
  // the same backend-validated APIs the full view uses, so containment
  // stays the backend's job).
  import Check from '@lucide/svelte/icons/check';
  import X from '@lucide/svelte/icons/x';
  import ChevronRight from '@lucide/svelte/icons/chevron-right';
  import type { AcpItemLike, ToolLocation } from './item-shapes';
  import {
    asString,
    asPresentString,
    toolDiff,
    diffLines,
    toolLocations,
    locationLabel,
    compactToolAction
  } from './item-shapes';

  let { item, onOpenFile }: { item: AcpItemLike; onOpenFile?: (relPath: string) => void } = $props();

  const kind = $derived(asString(item.kind));
  const title = $derived(asString(item.title));
  const status = $derived(asString(item.status));
  const output = $derived(asPresentString(item.output));

  const diff = $derived(toolDiff(item));
  const oldLines = $derived(diffLines(diff?.oldText));
  const newLines = $derived(diffLines(diff?.newText));
  const hasDiff = $derived(Boolean(diff && (oldLines.length || newLines.length)));
  const hasBody = $derived(hasDiff || Boolean(output));

  // The files this call touched, deduped by the identity a chip would open
  // with (the same tool often reports the same path twice — e.g. a read
  // followed by an edit within one call). Entries WITHOUT a `relPath` are in
  // scope for nothing this app can open (outside the ICM, or an absolute
  // path the backend couldn't relativize), so they render as plain text.
  const locations = $derived.by(() => {
    const seen = new Set<string>();
    return toolLocations(item).filter((l) => {
      const key = l.relPath ?? l.path;
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    });
  });

  const compactAction = $derived(compactToolAction(kind, title, locations));

  let expanded = $state(false);
</script>

<div class="border-paper-border bg-paper-card w-full max-w-[82%] self-start overflow-hidden rounded-xl border">
  {#snippet chevron()}
    <ChevronRight
      class={[
        'size-3 shrink-0 text-ink-meta transition-transform',
        expanded ? 'rotate-90' : '',
        hasBody ? '' : 'invisible'
      ]}
      strokeWidth={1.5}
      aria-hidden="true"
    />
  {/snippet}

  {#snippet statusGlyph()}
    <span class="ml-auto flex shrink-0 items-center gap-1.5">
      {#if status === 'completed'}
        <Check class="text-act-dot size-3.5" aria-label="completed" />
      {:else if status === 'failed'}
        <X class="text-warn-ink size-3.5" aria-label="failed" />
      {:else if status}
        <span class="bg-suggest-dash size-2 animate-pulse rounded-full" role="status" aria-label="running"></span>
      {/if}
    </span>
  {/snippet}

  <!-- A chip never wraps and never widens its row: it shrinks, ellipsizing
       the DIRECTORY head while the basename (`tail`, shrink-0) stays whole —
       a chip you can still identify at any width. `title` carries the full
       path, so the hover tooltip shows what the truncation hid. -->
  {#snippet locationChip(loc: ToolLocation)}
    {@const label = locationLabel(loc, compactAction?.range)}
    {#if loc.relPath && onOpenFile}
      {@const relPath = loc.relPath}
      <button
        type="button"
        onclick={() => onOpenFile?.(relPath)}
        title={label.full}
        class="border-paper-chip-border hover:bg-paper-pill text-ink-secondary flex min-w-0 max-w-full items-center overflow-hidden rounded-md border px-1.5 py-0.5 font-mono text-[11px] whitespace-nowrap transition-colors"
      >
        {#if label.head}<span class="truncate">{label.head}</span>{/if}
        <span class="max-w-full shrink-0 truncate">{label.tail}</span>
      </button>
    {:else}
      <span title={label.full} class="text-ink-meta min-w-0 max-w-full truncate font-mono text-[11px]"
        >{label.full}</span
      >
    {/if}
  {/snippet}

  {#if compactAction}
    <!-- Title only restates verb + location: one row, action and path each shown once.
         The row is a div (not a button) because the chips are buttons themselves.
         No wrapping: verb and status hold their size and the chip absorbs the
         squeeze, so a deep path costs an ellipsis instead of a second line. -->
    <div class="flex w-full items-center gap-x-2 px-3 py-2">
      <button
        type="button"
        onclick={() => (expanded = !expanded)}
        disabled={!hasBody}
        aria-expanded={hasBody ? expanded : undefined}
        aria-label={title}
        class={[
          '-mx-1 -my-0.5 flex shrink-0 items-center gap-2 rounded-md px-1 py-0.5 text-left',
          hasBody ? 'hover:bg-paper-pill cursor-pointer' : 'cursor-default'
        ]}
      >
        {@render chevron()}
        <span class="font-mono text-[10.5px] font-bold tracking-[0.05em] text-ink-meta uppercase">{compactAction.verb}</span>
      </button>
      {#each locations as loc (loc.relPath ?? loc.path)}
        {@render locationChip(loc)}
      {/each}
      {@render statusGlyph()}
    </div>
  {:else}
    <button
      type="button"
      onclick={() => (expanded = !expanded)}
      disabled={!hasBody}
      aria-expanded={hasBody ? expanded : undefined}
      class={['flex w-full items-center gap-2 px-3 py-2 text-left', hasBody ? 'hover:bg-paper-pill cursor-pointer' : 'cursor-default']}
    >
      {@render chevron()}
      {#if kind}
        <span class="font-mono text-[10.5px] font-bold tracking-[0.05em] text-ink-meta uppercase">{kind}</span>
      {/if}
      <span class="min-w-0 flex-1 truncate font-mono text-[12.5px] font-medium text-ink-body">{title}</span>
      {@render statusGlyph()}
    </button>

    {#if locations.length}
      <div class="flex flex-wrap gap-1 px-3 pb-2">
        {#each locations as loc (loc.relPath ?? loc.path)}
          {@render locationChip(loc)}
        {/each}
      </div>
    {/if}
  {/if}

  {#if expanded && hasDiff}
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

  {#if expanded && output}
    <pre
      class="border-paper-hairline max-h-[200px] overflow-auto border-t px-3 py-2 font-mono text-[11px] whitespace-pre-wrap break-words text-ink-secondary">{output}</pre>
  {/if}
</div>
