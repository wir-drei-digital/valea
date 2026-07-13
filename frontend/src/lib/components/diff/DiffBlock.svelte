<script lang="ts">
  // Renders one line-diff's rows (`lineDiff`/`derivePermissionView`'s
  // `DiffRow[]`) in the mono +/- vocabulary shared by PermissionCard (B11)
  // and the queue card's memory-update review (B12). The caller renders the
  // target path (and any other framing) above this block — this component
  // only knows about rows/truncated/a mode label, not what file they belong
  // to, so it stays reusable across both call sites.
  //
  // Colors alone never carry the add/remove distinction (§ a11y): every row
  // also carries a leading "+ "/"- "/two-space glyph, so the diff reads
  // correctly without color.
  //
  // SECURITY: `rows[].text` is agent-authored content (an Edit/Write tool
  // call's old_string/new_string/content). Plain interpolation only —
  // {@html} is FORBIDDEN here, same as every other agent-content component.
  import type { DiffRow } from '$lib/diff/line-diff';

  let {
    rows,
    truncated,
    modeLabel
  }: { rows: DiffRow[]; truncated: boolean; modeLabel?: string } = $props();
</script>

<div class="overflow-x-auto font-mono text-[11px] leading-relaxed whitespace-pre-wrap">
  {#if modeLabel}
    <div class="px-3 py-0.5 text-[10.5px] font-bold tracking-[0.04em] text-ink-meta uppercase">
      {modeLabel}
    </div>
  {/if}
  {#each rows as row, i (`${row.type}-${i}`)}
    {#if row.type === 'del'}
      <div class="bg-warn-tint px-3 py-px text-warn-ink">- {row.text}</div>
    {:else if row.type === 'add'}
      <div class="bg-act-tint px-3 py-px text-act">+ {row.text}</div>
    {:else}
      <div class="px-3 py-px text-ink-secondary">{'  '}{row.text}</div>
    {/if}
  {/each}
  {#if truncated}
    <div class="px-3 py-1 text-[10.5px] text-ink-meta italic">diff truncated</div>
  {/if}
</div>
