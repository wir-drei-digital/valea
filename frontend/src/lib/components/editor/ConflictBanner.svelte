<script lang="ts">
  // Amber suggestion-card styling (docs/DESIGN_SYSTEM.md §6): floats above
  // the editor when `PageEditorStore.state === 'conflict'` — the page changed
  // on disk while the user had unsaved edits. Both resolutions are
  // reversible from the user's point of view (Reload discards the local
  // edit, Keep mine overwrites disk), so both buttons stay small outline —
  // neither reads as the "safe" default action.
  import { Button } from '$lib/components/ui/button';

  let { onReload, onKeepMine }: { onReload: () => void; onKeepMine: () => void } = $props();
</script>

<div
  role="alert"
  class="flex items-center justify-between gap-4 rounded-xl border border-suggest-border bg-suggest-bg px-4 py-3"
>
  <p class="text-suggest-ink text-[13px]">This page changed outside the editor.</p>
  <div class="flex items-center gap-2">
    <Button variant="outline" size="sm" onclick={onReload}>Reload</Button>
    <Button variant="outline" size="sm" onclick={onKeepMine}>Keep mine</Button>
  </div>
</div>
