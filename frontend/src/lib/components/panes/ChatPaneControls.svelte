<script lang="ts">
  /**
   * The Chat pane's header control, rendered by PaneHost INSIDE the shared
   * pane header — same arrangement as `FilesPaneControls`: the host owns the
   * state, the header and the body both read it, and neither parents the
   * other. No accent colour: showing a navigator has no consequence.
   */
  import PanelLeft from '@lucide/svelte/icons/panel-left';
  import type { ChatPaneState } from '$lib/panes/chat-pane-runtime.svelte';

  let { state }: { state: ChatPaneState } = $props();
</script>

<button
  type="button"
  title={state.sessionsVisible ? 'Hide sessions' : 'Show sessions'}
  aria-label={state.sessionsVisible ? 'Hide sessions' : 'Show sessions'}
  aria-pressed={state.sessionsVisible}
  onclick={() => state.toggleSessions()}
  class="hover:bg-paper-pill focus-visible:ring-ring/50 -my-1.5 flex size-8 items-center justify-center rounded-md transition-colors outline-none focus-visible:ring-2 {state.sessionsVisible
    ? 'text-ink-heading'
    : 'text-ink-meta hover:text-ink-heading'}"
>
  <PanelLeft class="size-3.5" strokeWidth={1.5} />
</button>
