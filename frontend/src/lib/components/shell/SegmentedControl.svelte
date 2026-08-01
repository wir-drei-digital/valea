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
  //
  // `size` is the ONLY axis of variation, and it varies geometry only. An
  // earlier `quiet` variant instead dropped the track and the lift, to keep the
  // page view's Friendly/Raw toggle out of the tab strip's weight class. It
  // worked, but a segmented control without a track has no segments: the pill
  // is what says these two labels are one either/or. So the track comes back
  // and the recessing is done with SIZE — §4's S step (11.5px labels, the same
  // size as the path line it now shares a row with) against the default M
  // (12px). Recessing by size also restores the contrast note above: on the
  // track, idle ink has to be `text-ink-secondary` at any size.
  //
  // The catch is §4's other rule, the ≥32px hit target. A 24px pill breaches
  // it, so `sm` buys the height back with a transparent `::after` strip rather
  // than by growing: the repo's usual `-my-1 min-h-8` trick (SessionHeader,
  // FileActivityRail) enlarges the visible box, and here the visible box is
  // exactly what we were asked to shrink. Pointer events on a pseudo-element
  // hit its originating element, so each segment stays a 32px target while
  // painting 20px.
  let {
    options,
    value,
    label,
    size = 'md',
    onChange
  }: {
    options: { value: string; label: string; count?: number }[];
    value: string;
    /** Accessible name for the control. */
    label: string;
    /** `'sm'`: same pill, same semantics, one type step down (§4's S). */
    size?: 'md' | 'sm';
    onChange: (value: string) => void;
  } = $props();

  const sm = $derived(size === 'sm');
</script>

<div role="tablist" aria-label={label} class="bg-paper-track inline-flex items-center rounded-full p-0.5">
  {#each options as option (option.value)}
    <button
      type="button"
      role="tab"
      aria-selected={value === option.value}
      class={[
        'rounded-full whitespace-nowrap transition-colors',
        sm
          ? "relative px-2.5 py-0.5 text-[11.5px] leading-4 after:absolute after:inset-x-0 after:top-1/2 after:h-8 after:-translate-y-1/2 after:content-['']"
          : 'px-3 py-1 text-[12px]',
        value === option.value
          ? 'bg-paper-card text-ink-heading shadow-card'
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
