<script lang="ts">
  // Segmented view toggle (§4 "segmented / filter pills"): 999px radius on
  // the paper track, active segment lifted onto card paper. One shared
  // component so every view toggle (knowledge Friendly/Raw, calendar
  // Day/Week, …) renders identically — and, since the Tasks polish pass, the
  // one filter-pill grammar too: a mutually-exclusive set is a segmented
  // control, whatever the view calls it (the old `FilterPill` painted the
  // track color on its ACTIVE pill, inverting this component's vocabulary,
  // and is retired).
  //
  // Idle labels are `text-ink-secondary`, not `text-ink-meta`: on the darker
  // `#EEE8D9` track, meta ink measured 2.79:1 — under even the design
  // system's own floor. Secondary keeps the quiet-vs-lifted contrast without
  // the illegibility.
  // A `quiet` variant drops the track and the lift, keeping only the geometry
  // and the semantics. It exists for a control the reader mostly does not need
  // — the page view's Friendly/Raw toggle, which sat in the same visual weight
  // class as the tab strip above it and competed with it for attention. The
  // track is what forced idle labels up to `text-ink-secondary`; on plain paper
  // `text-ink-meta` is the weight the rest of the page's furniture already uses
  // (the path line right below it), so quiet can go a step lighter without the
  // contrast problem that note describes.
  //
  // Quiet carries NO persistent fill, not even a lighter one: `--paper-pill` is
  // darker than the `--paper-card` the tab strip's chips use, so a filled quiet
  // pill would have weighed MORE than the thing it is meant to sit under. The
  // selected segment is ink weight alone, with the fill moved to hover so the
  // control still announces itself as clickable.
  //
  // Geometry is deliberately UNCHANGED between the variants: this is a paint
  // change, and shrinking a control nobody needs is how it becomes a control
  // nobody can hit.
  let {
    options,
    value,
    label,
    quiet = false,
    onChange
  }: {
    options: { value: string; label: string; count?: number }[];
    value: string;
    /** Accessible name for the control. */
    label: string;
    /** Recede: no track, no lift, lighter ink. Same size, same semantics. */
    quiet?: boolean;
    onChange: (value: string) => void;
  } = $props();
</script>

<div
  role="tablist"
  aria-label={label}
  class={[
    'inline-flex items-center rounded-full',
    quiet ? '' : 'bg-paper-track p-0.5'
  ]}
>
  {#each options as option (option.value)}
    <button
      type="button"
      role="tab"
      aria-selected={value === option.value}
      class={[
        'rounded-full px-3 py-1 text-[12px] whitespace-nowrap transition-colors',
        quiet && 'hover:bg-paper-pill',
        value === option.value
          ? quiet
            ? 'text-ink-heading'
            : 'bg-paper-card text-ink-heading shadow-card'
          : quiet
            ? 'text-ink-meta hover:text-ink-heading'
            : 'text-ink-secondary hover:text-ink-heading'
      ]}
      onclick={() => onChange(option.value)}
    >
      {option.label}{#if option.count !== undefined && option.count > 0}<span
          class={['ml-1 tabular-nums', value === option.value ? 'text-ink-subtitle' : 'text-ink-meta']}
          >{option.count}</span
        >{/if}
    </button>
  {/each}
</div>
