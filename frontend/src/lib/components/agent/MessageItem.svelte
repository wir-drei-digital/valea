<script lang="ts">
  // Chat bubble for one `message` item (docs/DESIGN_SYSTEM.md §9).
  //
  // SECURITY: `text` is agent- or user-authored content. It is rendered
  // below with plain Svelte interpolation ({text}), which auto-escapes.
  // {@html} is FORBIDDEN here and in every other component under agent/ —
  // never render agent output as markup, and never add a markdown renderer.
  let { role, text }: { role: 'user' | 'assistant'; text: string } = $props();
</script>

{#if text}
  {#if role === 'user'}
    <div
      class="max-w-[78%] self-end rounded-tl-[14px] rounded-tr-[14px] rounded-br-[4px] rounded-bl-[14px] bg-act px-4 py-3 text-[13.5px] leading-[1.55] whitespace-pre-wrap break-words text-white"
    >
      {text}
    </div>
  {:else}
    <div
      class="border-paper-border bg-paper-card shadow-card max-w-[78%] self-start rounded-tl-[14px] rounded-tr-[14px] rounded-br-[14px] rounded-bl-[4px] border px-4 py-3 text-[13.5px] leading-[1.55] whitespace-pre-wrap break-words text-ink-body"
    >
      {text}
    </div>
  {/if}
{/if}
