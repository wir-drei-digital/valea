<script lang="ts">
  // One `message` item (docs/DESIGN_SYSTEM.md §9): user messages are
  // right-aligned green bubbles; assistant messages render bubble-less at
  // full container width.
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

  let {
    role,
    text,
    onOpenFile
  }: {
    role: 'user' | 'assistant';
    text: string;
    /** Forwarded to the markdown renderer so assistant prose can open files (assistant only). */
    onOpenFile?: (relPath: string) => void;
  } = $props();

  const tokens = $derived(role === 'assistant' && text ? lexAgentMarkdown(text) : []);
</script>

{#if text}
  {#if role === 'user'}
    <div
      class="max-w-[78%] self-end rounded-tl-[14px] rounded-tr-[14px] rounded-br-[4px] rounded-bl-[14px] bg-act px-4 py-3 text-[13.5px] leading-[1.55] whitespace-pre-wrap break-words text-primary-foreground"
    >
      {text}
    </div>
  {:else}
    <!-- Assistant replies read as the page's own prose — full container
         width, no bubble chrome; only USER messages keep the bubble. -->
    <div class="w-full min-w-0 self-stretch text-[13.5px] leading-[1.55] text-ink-body">
      <MarkdownBlocks {tokens} {onOpenFile} />
    </div>
  {/if}
{/if}
