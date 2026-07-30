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
  import { lineDiff } from '$lib/diff/line-diff';
  import type { FileActivity } from './file-activity';

  let {
    activities,
    missingKeys,
    onOpenFile,
    onClose
  }: {
    activities: FileActivity[];
    missingKeys: ReadonlySet<string>;
    onOpenFile?: (relPath: string) => void;
    onClose: () => void;
  } = $props();

  const BADGE_LABEL: Record<FileActivity['kindBadge'], string> = {
    read: 'Read',
    edited: 'Edited',
    created: 'Created',
    deleted: 'Deleted',
    renamed: 'Renamed'
  };

  let expandedKeys = $state(new Set<string>());

  function toggle(key: string): void {
    const next = new Set(expandedKeys);
    if (next.has(key)) next.delete(key);
    else next.add(key);
    expandedKeys = next;
  }
</script>

<aside class="border-paper-hairline flex w-[300px] shrink-0 flex-col border-l" aria-label="Files this session touched">
  <div class="border-paper-hairline flex items-center gap-2 border-b px-3 py-2">
    <span class="text-ink-heading text-[12.5px] font-medium">Files</span>
    <span class="text-ink-meta text-[11.5px]">{activities.length}</span>
    <button
      type="button"
      onclick={onClose}
      aria-label="Close files panel"
      class="text-ink-meta hover:bg-paper-pill hover:text-ink-heading ml-auto flex size-5 shrink-0 items-center justify-center rounded-md transition-colors"
    >
      <X class="size-3.5" strokeWidth={1.5} aria-hidden="true" />
    </button>
  </div>

  <div class="min-h-0 flex-1 overflow-y-auto py-1">
    {#each activities as row (row.key)}
      {@const expandable = row.edits.length > 0}
      {@const expanded = expandedKeys.has(row.key)}
      <div class="border-paper-hairline border-b last:border-b-0">
        <div class="flex items-start gap-1.5 px-2 py-1.5">
          <button
            type="button"
            onclick={() => toggle(row.key)}
            disabled={!expandable}
            aria-expanded={expandable ? expanded : undefined}
            class={[
              'flex min-w-0 flex-1 items-start gap-1.5 rounded-md px-1 py-0.5 text-left',
              expandable ? 'hover:bg-paper-pill cursor-pointer' : 'cursor-default'
            ]}
          >
            <ChevronRight
              class={[
                'mt-0.5 size-3 shrink-0 text-ink-meta transition-transform',
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
                  {#if missingKeys.has(row.key)}<span class="italic">no longer exists</span>{/if}
                </span>
              {/if}
            </span>
            <span
              class={[
                'mt-0.5 shrink-0 rounded-md px-1.5 py-0.5 text-[10px] font-bold tracking-[0.04em] uppercase',
                row.kindBadge === 'read' ? 'bg-paper-pill text-ink-meta' : 'bg-act-tint text-act'
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
              class="text-ink-meta hover:bg-paper-pill hover:text-ink-heading mt-0.5 flex size-5 shrink-0 items-center justify-center rounded-md transition-colors"
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
                <DiffBlock rows={d.rows} truncated={d.truncated} />
              {:else}
                <p class="text-ink-meta px-3 text-[11px] italic">no change details available</p>
              {/if}
            {/each}
          </div>
        {/if}
      </div>
    {/each}
  </div>
</aside>
