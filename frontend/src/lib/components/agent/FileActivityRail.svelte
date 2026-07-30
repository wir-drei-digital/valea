<script lang="ts">
  // The session file-activity rail (spec:
  // docs/superpowers/specs/2026-07-30-session-file-activity-design.md).
  // One row per touched file; badges tell read-only from changed; diffs are
  // hidden until a row is expanded. Presentational: aggregation, auto-open,
  // and existence checks are the host's job (ChatView) — this renders what
  // it is given.
  //
  // SECURITY: names, dirs, paths, and diff text are agent-produced content —
  // plain interpolation only, {@html} is FORBIDDEN (same rule as every
  // agent component).
  //
  // A11y (ToolCallCard precedent): the expand toggle and the open icon are
  // separate SIBLING buttons — the row container is a plain div, never a
  // nested-interactive control. The toggle deliberately carries NO aria-label:
  // an aria-label would OVERRIDE its descendant text, so a screen reader would
  // hear only the filename and lose the dir, edit count, "no longer exists"
  // note, and the badge — the badge text is the non-color carrier of
  // read-vs-changed, so masking it breaks information parity. All children are
  // plain text, so the computed name already reads the whole row.
  import X from '@lucide/svelte/icons/x';
  import ChevronRight from '@lucide/svelte/icons/chevron-right';
  import ArrowUpRight from '@lucide/svelte/icons/arrow-up-right';
  import DiffBlock from '$lib/components/diff/DiffBlock.svelte';
  import { lineDiff, type DiffRow } from '$lib/diff/line-diff';
  import type { FileActivity } from './file-activity';

  let {
    activities,
    missingKeys,
    onOpenFile,
    onClose,
    variant = 'rail'
  }: {
    activities: FileActivity[];
    missingKeys: ReadonlySet<string>;
    onOpenFile?: (relPath: string) => void;
    /** Rail variant only — the popover variant dismisses via its own primitive. */
    onClose?: () => void;
    /**
     * 'rail' is the inline right column. 'popover' hosts the same list
     * inside the header pill's popover when the inline rail cannot fit
     * (narrow view, side-pane placement) — no border/panel chrome (the
     * popover card provides it), no ✕, no focus-target id (ids must stay
     * unique: an inline rail elsewhere on the page may hold them).
     */
    variant?: 'rail' | 'popover';
  } = $props();

  const BADGE_LABEL: Record<FileActivity['kindBadge'], string> = {
    read: 'Read',
    edited: 'Edited',
    created: 'Created',
    deleted: 'Deleted',
    renamed: 'Renamed'
  };

  // Quiet-receipt palette (2026-07-30 critique ruling): the rail is a RECORD
  // of what the session touched, not an approval surface — so approval-green
  // never appears on badges. Read is a ghost label (no fill); changed kinds
  // share one neutral paper pill; only Deleted wears terracotta, because
  // "color = consequence" reserves warn for alarm. The green +rows inside
  // the expanded DiffBlock are deliberate and stay (added-line semantics,
  // per the same ruling).
  const BADGE_CLASS: Record<FileActivity['kindBadge'], string> = {
    read: 'text-ink-subtitle',
    edited: 'bg-paper-track text-ink-secondary',
    created: 'bg-paper-track text-ink-secondary',
    renamed: 'bg-paper-track text-ink-secondary',
    deleted: 'bg-warn-tint text-warn-ink'
  };

  let expandedKeys = $state(new Set<string>());

  function toggle(key: string): void {
    const next = new Set(expandedKeys);
    if (next.has(key)) next.delete(key);
    else next.add(key);
    expandedKeys = next;
  }

  // Plain-language first (product principle: technical detail one toggle
  // away — and the mono +/- grammar IS technical detail): each expanded
  // change leads with a human sentence derived from the same rows the
  // DiffBlock renders, so the counts can never disagree with the diff.
  function changeSummary(rows: DiffRow[]): string {
    const added = rows.filter((r) => r.type === 'add').length;
    const removed = rows.filter((r) => r.type === 'del').length;
    const lines = (n: number) => `${n} line${n === 1 ? '' : 's'}`;
    if (added > 0 && removed > 0) return `Replaced ${lines(removed)} with ${lines(added)}`;
    if (added > 0) return `Added ${lines(added)}`;
    if (removed > 0) return `Removed ${lines(removed)}`;
    return 'No lines changed';
  }
</script>

<!-- tabindex="-1" (rail variant): the host moves focus here when the header
     pill reopens the rail, so keyboard users land where they asked to go
     instead of <body>. bg-paper-panel is the design system's dedicated rail
     surface; the popover variant sits on the popover card instead. -->
<aside
  id={variant === 'rail' ? 'file-activity-rail' : undefined}
  tabindex="-1"
  class={[
    'flex flex-col outline-none',
    variant === 'rail'
      ? 'border-paper-hairline bg-paper-panel w-[300px] shrink-0 border-l'
      : 'max-h-96 w-[300px]'
  ]}
  aria-label="Context files this session read or changed"
>
  <!-- Rail variant matches the chat header's vertical band exactly (the
       host column's pt-3 + content + pb-2), so the two border-b lines read
       as one continuous rule across the pane. min-h-6 pins the content row
       to the same 24px the chat header's controls set. -->
  <div
    class={[
      'border-paper-hairline flex items-center gap-2 border-b px-3',
      variant === 'rail' ? 'pt-3 pb-2' : 'py-2'
    ]}
  >
    <!-- h2: gives screen-reader rotor users a landmark inside the aside.
         One string, matching the header pill's "Context · N" exactly. -->
    <h2 class="text-ink-heading flex min-h-6 items-center text-[12.5px] font-medium">
      Context · <span class="text-ink-meta font-normal">&nbsp;{activities.length}</span>
    </h2>
    {#if variant === 'rail' && onClose}
      <!-- size-8 with negative margin: a ≥32px hit target (product floor)
           without growing the header bar. -->
      <button
        type="button"
        onclick={onClose}
        aria-label="Close context panel"
        class="text-ink-meta hover:bg-paper-pill hover:text-ink-heading focus-visible:ring-ring/50 -my-1.5 ml-auto flex size-8 shrink-0 items-center justify-center rounded-md transition-colors outline-none focus-visible:ring-2"
      >
        <X class="size-3.5" strokeWidth={1.5} aria-hidden="true" />
      </button>
    {/if}
  </div>

  <div class="min-h-0 flex-1 overflow-y-auto py-1">
    {#each activities as row (row.key)}
      {@const expandable = row.edits.length > 0}
      {@const expanded = expandedKeys.has(row.key)}
      <div class="border-paper-hairline border-b last:border-b-0">
        <div class="flex items-start gap-1 px-2 py-1">
          <button
            type="button"
            onclick={() => toggle(row.key)}
            disabled={!expandable}
            aria-expanded={expandable ? expanded : undefined}
            class={[
              'focus-visible:ring-ring/50 flex min-h-8 min-w-0 flex-1 items-start gap-1.5 rounded-md px-1 py-1 text-left outline-none focus-visible:ring-2',
              expandable ? 'hover:bg-paper-pill cursor-pointer' : 'cursor-default'
            ]}
          >
            <ChevronRight
              class={[
                'mt-0.5 size-3 shrink-0 text-ink-meta transition-transform motion-reduce:transition-none',
                expanded ? 'rotate-90' : '',
                expandable ? '' : 'invisible'
              ]}
              strokeWidth={1.5}
              aria-hidden="true"
            />
            <span class="min-w-0 flex-1">
              <span class="block truncate text-[12.5px] font-medium text-ink-body">{row.name}</span>
              {#if row.dir}
                <span class="text-ink-meta block truncate font-mono text-[10.5px]">{row.dir}</span>
              {/if}
              {#if row.edits.length > 1 || missingKeys.has(row.key)}
                <span class="text-ink-meta flex flex-wrap gap-x-2 text-[10.5px]">
                  {#if row.edits.length > 1}<span>{row.edits.length} edits</span>{/if}
                  <!-- warn-ink, not italic meta: a gone file is the one alarming
                       state this rail can report, so it speaks in terracotta —
                       with a cause, so it raises a question it also answers. -->
                  {#if missingKeys.has(row.key)}<span class="text-warn-ink"
                      >no longer exists — it may have been moved or removed since</span
                    >{/if}
                </span>
              {/if}
            </span>
            <span
              class={[
                'mt-0.5 shrink-0 rounded-full px-2 py-0.5 text-[10px] font-bold tracking-[0.04em] uppercase',
                BADGE_CLASS[row.kindBadge]
              ]}
            >
              {BADGE_LABEL[row.kindBadge]}
            </span>
          </button>
          {#if row.relPath !== undefined && onOpenFile}
            {@const relPath = row.relPath}
            <button
              type="button"
              onclick={() => onOpenFile?.(relPath)}
              aria-label={`Open ${row.name}`}
              title={`Open ${row.name}`}
              class="text-ink-meta hover:bg-paper-pill hover:text-ink-heading focus-visible:ring-ring/50 flex size-8 shrink-0 items-center justify-center rounded-md transition-colors outline-none focus-visible:ring-2"
            >
              <ArrowUpRight class="size-3.5" strokeWidth={1.5} aria-hidden="true" />
            </button>
          {/if}
        </div>

        {#if expanded}
          <div class="flex flex-col gap-1 pb-1.5">
            {#each row.edits as edit, i (i)}
              <!-- A truthy `diff` proves nothing: `toolDiff` returns an object
                   whenever the call carried a diff map, even with oldText AND
                   newText both absent (a path-only diff, or creating an empty
                   file). Rendering that would expand the row into an EMPTY
                   DiffBlock, which reads as broken — so the text check, not
                   just the object check, decides. Same guard as ToolCallCard's
                   `hasDiff`. -->
              {#if edit.diff && (edit.diff.oldText || edit.diff.newText)}
                {@const d = lineDiff(edit.diff.oldText ?? '', edit.diff.newText ?? '')}
                <p class="text-ink-secondary px-3 text-[11.5px]">{changeSummary(d.rows)}</p>
                <DiffBlock rows={d.rows} truncated={d.truncated} />
              {:else}
                <p class="text-ink-meta px-3 text-[11px] italic">no details recorded for this change</p>
              {/if}
            {/each}
          </div>
        {/if}
      </div>
    {/each}
  </div>
</aside>
