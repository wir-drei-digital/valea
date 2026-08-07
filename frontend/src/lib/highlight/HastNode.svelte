<script lang="ts">
  // Recursive hast → elements. lowlight emits exactly two node types (`text`
  // and `element`, the latter always a `<span>` carrying `hljs-…` classes),
  // and anything else is ignored rather than guessed at.
  //
  // This component is the whole reason highlighting uses lowlight instead of
  // highlight.js directly: it turns a DATA tree into real elements, so no
  // `{@html}` is needed anywhere in the path from file bytes to the screen.
  //
  // Rendered inside a <pre>: every literal newline between tags below would
  // be visible whitespace, which is why the markup is written unbroken.
  import type { Element, RootContent } from 'hast';
  import HastNode from './HastNode.svelte';

  let { nodes }: { nodes: RootContent[] } = $props();

  function classOf(node: Element): string {
    const raw = node.properties?.className;
    if (Array.isArray(raw)) return raw.join(' ');
    return typeof raw === 'string' ? raw : '';
  }
</script>

{#each nodes as node, i (i)}{#if node.type === 'text'}{node.value}{:else if node.type === 'element'}<span
      class={classOf(node)}><HastNode nodes={node.children as RootContent[]} /></span
    >{/if}{/each}
