<script lang="ts">
  // The one code surface: a <pre> that renders PLAIN first and upgrades to
  // highlighted when the grammar resolves. Same element, same classes, same
  // typography in both states, so the upgrade causes no layout shift and no
  // flash of restyled text.
  //
  // `class` is the caller's, not this component's: the chat's fenced block
  // wants a filled, non-wrapping card and the file viewer wants a bare,
  // wrapping column. Both are the same code, differently framed.
  import type { Root, RootContent } from 'hast';
  import { highlight } from './highlight';
  import type { Grammar } from './languages';
  import HastNode from './HastNode.svelte';

  let {
    code,
    grammar,
    class: className = ''
  }: { code: string; grammar: Grammar | null; class?: string } = $props();

  let tree = $state<Root | null>(null);

  // Captured before the await so a tree for code the reader has since
  // navigated away from is dropped rather than shown — the same shape
  // `PlainTextView`'s own fetch effect uses.
  $effect(() => {
    const target = { code, grammar };
    let cancelled = false;
    tree = null;
    void highlight(target.code, target.grammar).then((result) => {
      if (!cancelled) tree = result;
    });
    return () => {
      cancelled = true;
    };
  });
</script>

{#if tree}<pre class={className}><HastNode
      nodes={tree.children as RootContent[]}
    /></pre>{:else}<pre class={className}>{code}</pre>{/if}
