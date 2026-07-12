<script lang="ts">
  // Segmented filter pill for list-pane header rows (mail's Review/Inbox,
  // etc.) — DESIGN_SYSTEM §4 "segmented / filter pills": 999px radius, the
  // active pill sits filled on the paper track, idle ones are plain text.
  let {
    label,
    count,
    active = false,
    onclick
  }: {
    label: string;
    count?: number;
    active?: boolean;
    onclick: () => void;
  } = $props();
</script>

<button
  type="button"
  role="tab"
  aria-selected={active}
  {onclick}
  class={[
    'inline-flex items-center gap-1 rounded-full px-2.5 py-1 text-[12px] whitespace-nowrap transition-colors',
    active
      ? 'bg-paper-track font-semibold text-ink-heading'
      : 'text-ink-secondary hover:text-ink-heading'
  ]}
>
  {label}{#if count !== undefined}<span
      class={['tabular-nums', active ? 'text-ink-subtitle' : 'text-ink-meta']}>· {count}</span
    >{/if}
</button>
