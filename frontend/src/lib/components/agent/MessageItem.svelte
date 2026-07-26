<script lang="ts">
  // Chat bubble for one `message` item (docs/DESIGN_SYSTEM.md §9).
  //
  // SECURITY: `text` is agent- or user-authored content. {@html} is
  // FORBIDDEN here and in every other component under agent/. Assistant
  // messages render as MARKDOWN — but through marked's token TREE
  // (`lexAgentMarkdown` + MarkdownBlocks/MarkdownInline), never a
  // markdown→HTML string: every text leaf still reaches the DOM through
  // plain Svelte interpolation, raw HTML tokens render as literal text,
  // and links only materialize for vetted schemes. User messages stay
  // plain interpolated text.
  import MarkdownBlocks from './markdown/MarkdownBlocks.svelte';
  import { lexAgentMarkdown } from '$lib/markdown/agent-markdown';

  let { role, text }: { role: 'user' | 'assistant'; text: string } = $props();

  const tokens = $derived(role === 'assistant' && text ? lexAgentMarkdown(text) : []);
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
      class="border-paper-border bg-paper-card shadow-card max-w-[78%] min-w-0 self-start rounded-tl-[14px] rounded-tr-[14px] rounded-br-[14px] rounded-bl-[4px] border px-4 py-3 text-[13.5px] leading-[1.55] text-ink-body"
    >
      <MarkdownBlocks {tokens} />
    </div>
  {/if}
{/if}
