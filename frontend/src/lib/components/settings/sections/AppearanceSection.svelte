<script lang="ts">
  // Theme choice. A mutually-exclusive set of three is a segmented control
  // by this codebase's own grammar (SegmentedControl.svelte's header).
  //
  // Per-machine, not per-workspace: it lives in localStorage because that is
  // the only store `theme-init.js` can read before first paint.
  //
  // No `start()` here — the root layout owns the single call site, and the
  // store is a module singleton, so this pane only reads and writes it.
  import SegmentedControl from '$lib/components/shell/SegmentedControl.svelte';
  import { themeStore } from '$lib/stores/theme.svelte';
  import type { ThemePreference } from '$lib/stores/theme';

  const OPTIONS = [
    { value: 'light', label: 'Light' },
    { value: 'dark', label: 'Dark' },
    { value: 'system', label: 'System' }
  ];
</script>

<div class="flex flex-col gap-3">
  <div>
    <h2 class="font-display text-ink-heading text-[17px]">Appearance</h2>
    <p class="text-ink-body text-[12.5px]">How Valea looks on this machine.</p>
  </div>

  <div class="flex flex-col gap-2">
    <p class="text-overline">Theme</p>
    <!-- The cast is safe: `setPreference` runs `parsePreference` on the way in
         (theme.svelte.ts), so an out-of-vocabulary string sanitises to
         'system' rather than reaching the store. -->
    <!-- The plain wrapper div is load-bearing: this column's flex children
         stretch, and a stretched track reads as an input field, not a
         segmented control. The div takes the stretch; the inline-flex track
         inside it shrink-wraps back to its options. -->
    <div>
      <SegmentedControl
        options={OPTIONS}
        value={themeStore.preference}
        label="Theme"
        onChange={(value) => themeStore.setPreference(value as ThemePreference)}
      />
    </div>
    <p class="text-ink-meta text-[12px]">
      {#if themeStore.preference === 'system'}
        Following your operating system, which is currently {themeStore.resolved}.
      {:else}
        Always {themeStore.preference}, whatever your operating system does.
      {/if}
    </p>
  </div>
</div>
