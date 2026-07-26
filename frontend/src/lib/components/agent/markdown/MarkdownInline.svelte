<script lang="ts">
  // Inline half of the agent-markdown renderer (see `agent-markdown.ts`'s
  // moduledoc for the security contract). Recursive over marked's inline
  // token tree via self-import; every leaf reaches the DOM through plain
  // interpolation — {@html} is FORBIDDEN in this family.
  import MarkdownInline from './MarkdownInline.svelte';
  import { safeLinkHref, unescapeMarked, type Token } from '$lib/markdown/agent-markdown';

  let { tokens }: { tokens: Token[] } = $props();

  // Loose local view of marked's inline token union — only the fields this
  // template dereferences.
  type T = Token & { text?: string; href?: string; tokens?: Token[]; escaped?: boolean };
  const items = $derived(tokens as T[]);

  function leafText(token: T): string {
    const text = token.text ?? '';
    return token.escaped ? unescapeMarked(text) : text;
  }
</script>

{#each items as token, i (i)}
  {#if token.type === 'text' || token.type === 'escape'}
    {#if token.tokens?.length}
      <MarkdownInline tokens={token.tokens} />
    {:else}
      {leafText(token)}
    {/if}
  {:else if token.type === 'strong'}
    <strong class="text-ink-heading font-semibold"><MarkdownInline tokens={token.tokens ?? []} /></strong>
  {:else if token.type === 'em'}
    <em><MarkdownInline tokens={token.tokens ?? []} /></em>
  {:else if token.type === 'del'}
    <del><MarkdownInline tokens={token.tokens ?? []} /></del>
  {:else if token.type === 'codespan'}
    <code class="bg-paper-track rounded px-1 py-0.5 font-mono text-[12px]">{unescapeMarked(token.text ?? '')}</code>
  {:else if token.type === 'br'}
    <br />
  {:else if token.type === 'link'}
    {@const href = safeLinkHref(token.href)}
    {#if href}
      <a
        {href}
        target="_blank"
        rel="noopener noreferrer"
        class="text-ink-heading decoration-paper-button-border underline underline-offset-2 hover:decoration-ink-secondary"
        ><MarkdownInline tokens={token.tokens ?? []} /></a
      >
    {:else}
      <MarkdownInline tokens={token.tokens ?? []} />
    {/if}
  {:else if token.type === 'image'}
    <!-- Never fetch an agent-chosen URL; show the alt text as a quiet tag. -->
    <span class="text-ink-meta">[image{token.text ? `: ${token.text}` : ''}]</span>
  {:else if token.type === 'html'}
    {token.text ?? ''}
  {:else}
    {token.raw ?? ''}
  {/if}
{/each}
