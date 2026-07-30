<script lang="ts">
  // A native <select> in the app's own clothes — Input's exact height, border
  // and focus treatment, plus a stroke chevron. The OS picker is kept (it is
  // the best part of a native select); only the closed control is styled, so
  // a paper dialog stops sprouting platform chrome (Tasks critique, P-issue:
  // "native OS form controls inside a paper-and-ink dialog").
  import type { HTMLSelectAttributes } from 'svelte/elements';
  import ChevronDown from '@lucide/svelte/icons/chevron-down';
  import { cn, type WithElementRef } from '$lib/utils.js';

  let {
    ref = $bindable(null),
    value = $bindable(),
    class: className,
    children,
    ...restProps
  }: WithElementRef<HTMLSelectAttributes> = $props();
</script>

<div class={cn('relative inline-flex', className)}>
  <select
    bind:this={ref}
    bind:value
    data-slot="native-select"
    class="border-input focus-visible:border-ring focus-visible:ring-ring/50 text-ink-body h-8 w-full min-w-0 appearance-none rounded-lg border bg-transparent py-1 pr-7 pl-2.5 text-sm transition-colors outline-none focus-visible:ring-3 disabled:pointer-events-none disabled:cursor-not-allowed disabled:opacity-50"
    {...restProps}
  >
    {@render children?.()}
  </select>
  <ChevronDown
    class="text-ink-meta pointer-events-none absolute top-1/2 right-2 size-3.5 -translate-y-1/2"
    strokeWidth={1.5}
    aria-hidden="true"
  />
</div>
