<script lang="ts">
  // Segmented view toggle (§4 "segmented / filter pills"): 999px radius on
  // the paper track, active segment lifted onto card paper. One shared
  // component so every view toggle (knowledge Friendly/Raw, calendar
  // Day/Week, …) renders identically.
  let {
    options,
    value,
    label,
    onChange
  }: {
    options: { value: string; label: string }[];
    value: string;
    /** Accessible name for the tablist. */
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
        value === option.value ? 'bg-paper-card text-ink-heading' : 'text-ink-meta hover:text-ink-secondary'
      }`}
      onclick={() => onChange(option.value)}
    >
      {option.label}
    </button>
  {/each}
</div>
