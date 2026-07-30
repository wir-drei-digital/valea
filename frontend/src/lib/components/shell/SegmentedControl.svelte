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
  let {
    options,
    value,
    label,
    onChange
  }: {
    options: { value: string; label: string; count?: number }[];
    value: string;
    /** Accessible name for the control. */
    label: string;
    onChange: (value: string) => void;
  } = $props();
</script>

<div role="tablist" aria-label={label} class="bg-paper-track inline-flex items-center rounded-full p-0.5">
  {#each options as option (option.value)}
    <button
      type="button"
      role="tab"
      aria-selected={value === option.value}
      class={`rounded-full px-3 py-1 text-[12px] whitespace-nowrap transition-colors ${
        value === option.value
          ? 'bg-paper-card text-ink-heading shadow-card'
          : 'text-ink-secondary hover:text-ink-heading'
      }`}
      onclick={() => onChange(option.value)}
    >
      {option.label}{#if option.count !== undefined && option.count > 0}<span
          class={['ml-1 tabular-nums', value === option.value ? 'text-ink-subtitle' : 'text-ink-meta']}
          >{option.count}</span
        >{/if}
    </button>
  {/each}
</div>
