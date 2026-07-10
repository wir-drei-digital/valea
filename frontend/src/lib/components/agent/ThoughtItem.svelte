<script lang="ts">
  // Reasoning strip for a `thought` item — collapsed by default (the model's
  // scratch thinking is meta, not the answer). "Thinking" overline per the
  // task brief; ink-meta italic body when expanded.
  //
  // SECURITY: `text` is agent-authored. Plain interpolation only — no
  // {@html}, no markdown rendering. See MessageItem.svelte for the same note.
  import ChevronRight from '@lucide/svelte/icons/chevron-right';

  let { text }: { text: string } = $props();

  let expanded = $state(false);
</script>

{#if text}
  <div class="max-w-[82%] self-start">
    <button
      type="button"
      onclick={() => (expanded = !expanded)}
      aria-expanded={expanded}
      class="text-overline flex items-center gap-1 py-0.5"
    >
      <ChevronRight class="size-3 transition-transform {expanded ? 'rotate-90' : ''}" aria-hidden="true" />
      Thinking
    </button>
    {#if expanded}
      <p class="border-paper-hairline mt-1 border-l-2 pl-3 text-[12.5px] whitespace-pre-wrap break-words text-ink-meta italic">
        {text}
      </p>
    {/if}
  </div>
{/if}
