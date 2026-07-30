<script lang="ts">
  // Inline half of the agent-markdown renderer (see `agent-markdown.ts`'s
  // moduledoc for the security contract). Recursive over marked's inline
  // token tree via self-import; every leaf reaches the DOM through plain
  // interpolation — {@html} is FORBIDDEN in this family.
  //
  // Codespans can earn an affordance: a real link when the text is a
  // `safeLinkHref`-vetted destination (http(s) AND mailto, same vetting as
  // markdown links), or a file-open button when it looks like an
  // ICM-relative path (`codespanFilePath`) and a handler is present.
  // Either way the codespan's TEXT still reaches the DOM through plain
  // interpolation — only the wrapping element changes. `linked` is set on
  // the recursion inside a real `<a>` so we never nest an interactive
  // element inside a link.
  import MarkdownInline from './MarkdownInline.svelte';
  import { codespanFilePath, safeLinkHref, unescapeMarked, type Token } from '$lib/markdown/agent-markdown';
  import { inDesktop } from '$lib/keychain';
  import { openExternal } from '$lib/shell/external-link';

  let {
    tokens,
    onOpenFile,
    linked = false
  }: {
    tokens: Token[];
    /** Opens an in-mount file by relPath — same handler the tool-card chips use (see Transcript). */
    onOpenFile?: (relPath: string) => void;
    /** True when already rendering inside an <a> — suppresses nested interactive codespans. */
    linked?: boolean;
  } = $props();

  // Desktop: the Tauri webview has no window factory, so `target="_blank"`
  // silently does nothing — route the click through the desktop-aware
  // opener instead (see external-link.ts). Browser: default behavior.
  function onLinkClick(event: MouseEvent, href: string): void {
    if (!inDesktop()) return;
    event.preventDefault();
    openExternal(href);
  }

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
      <MarkdownInline tokens={token.tokens} {onOpenFile} {linked} />
    {:else}
      {leafText(token)}
    {/if}
  {:else if token.type === 'strong'}
    <strong class="text-ink-heading font-semibold"
      ><MarkdownInline tokens={token.tokens ?? []} {onOpenFile} {linked} /></strong
    >
  {:else if token.type === 'em'}
    <em><MarkdownInline tokens={token.tokens ?? []} {onOpenFile} {linked} /></em>
  {:else if token.type === 'del'}
    <del><MarkdownInline tokens={token.tokens ?? []} {onOpenFile} {linked} /></del>
  {:else if token.type === 'codespan'}
    {@const codeText = unescapeMarked(token.text ?? '')}
    {@const codeHref = linked ? null : safeLinkHref(codeText)}
    {@const codePath = linked || codeHref ? undefined : codespanFilePath(codeText)}
    {#if codeHref}
      <a
        href={codeHref}
        target="_blank"
        rel="noopener noreferrer"
        onclick={(event) => onLinkClick(event, codeHref)}
        class="bg-paper-track text-ink-heading decoration-paper-button-border rounded px-1 py-0.5 font-mono text-[12px] underline underline-offset-2 hover:decoration-ink-secondary"
        >{codeText}</a
      >
    {:else if codePath && onOpenFile}
      <button
        type="button"
        onclick={() => onOpenFile?.(codePath)}
        aria-label={`Open ${codeText}`}
        class="bg-paper-track hover:bg-paper-pill text-ink-body decoration-paper-button-border cursor-pointer rounded px-1 py-0.5 text-left font-mono text-[12px] underline underline-offset-2 transition-colors hover:decoration-ink-secondary"
        >{codeText}</button
      >
    {:else}
      <code class="bg-paper-track rounded px-1 py-0.5 font-mono text-[12px]">{codeText}</code>
    {/if}
  {:else if token.type === 'br'}
    <br />
  {:else if token.type === 'link'}
    {@const href = safeLinkHref(token.href)}
    {#if href}
      <a
        {href}
        target="_blank"
        rel="noopener noreferrer"
        onclick={(event) => onLinkClick(event, href)}
        class="text-ink-heading decoration-paper-button-border underline underline-offset-2 hover:decoration-ink-secondary"
        ><MarkdownInline tokens={token.tokens ?? []} {onOpenFile} linked={true} /></a
      >
    {:else}
      <MarkdownInline tokens={token.tokens ?? []} {onOpenFile} {linked} />
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
