<script lang="ts">
  // Block half of the agent-markdown renderer (see `agent-markdown.ts`'s
  // moduledoc for the security contract): walks marked's block token tree
  // emitting real elements, recursing via self-import for blockquotes and
  // list items. {@html} is FORBIDDEN in this family — raw `html` blocks
  // render as literal text.
  import MarkdownBlocks from './MarkdownBlocks.svelte';
  import MarkdownInline from './MarkdownInline.svelte';
  import { unescapeMarked, type Token } from '$lib/markdown/agent-markdown';

  let { tokens }: { tokens: Token[] } = $props();

  type Cell = { tokens?: Token[] };
  type T = Token & {
    text?: string;
    depth?: number;
    ordered?: boolean;
    items?: Array<{ tokens?: Token[]; task?: boolean; checked?: boolean }>;
    tokens?: Token[];
    header?: Cell[];
    rows?: Cell[][];
    escaped?: boolean;
  };
  const items = $derived(tokens as T[]);

  const headingClass: Record<number, string> = {
    1: 'text-[15.5px] font-semibold text-ink-heading mt-1',
    2: 'text-[14.5px] font-semibold text-ink-heading mt-1',
    3: 'text-[13.5px] font-semibold text-ink-heading'
  };
</script>

<div class="flex min-w-0 flex-col gap-2">
  {#each items as token, i (i)}
    {#if token.type === 'paragraph'}
      <p class="break-words"><MarkdownInline tokens={token.tokens ?? []} /></p>
    {:else if token.type === 'heading'}
      <p class={headingClass[token.depth ?? 3] ?? headingClass[3]}>
        <MarkdownInline tokens={token.tokens ?? []} />
      </p>
    {:else if token.type === 'list'}
      {#if token.ordered}
        <ol class="flex list-decimal flex-col gap-1 pl-5">
          {#each token.items ?? [] as item, j (j)}
            <li>
              {#if item.task}<span aria-hidden="true">{item.checked ? '☑' : '☐'} </span>{/if}
              <MarkdownBlocks tokens={item.tokens ?? []} />
            </li>
          {/each}
        </ol>
      {:else}
        <ul class="flex list-disc flex-col gap-1 pl-5">
          {#each token.items ?? [] as item, j (j)}
            <li>
              {#if item.task}<span aria-hidden="true">{item.checked ? '☑' : '☐'} </span>{/if}
              <MarkdownBlocks tokens={item.tokens ?? []} />
            </li>
          {/each}
        </ul>
      {/if}
    {:else if token.type === 'code'}
      <pre
        class="bg-paper-track overflow-x-auto rounded-lg px-3 py-2.5 font-mono text-[12px] leading-[1.5] whitespace-pre">{unescapeMarked(
          token.text ?? ''
        )}</pre>
    {:else if token.type === 'blockquote'}
      <blockquote class="border-paper-border text-ink-secondary border-l-2 pl-3">
        <MarkdownBlocks tokens={token.tokens ?? []} />
      </blockquote>
    {:else if token.type === 'table'}
      <div class="overflow-x-auto">
        <table class="border-collapse text-[13px]">
          <thead>
            <tr>
              {#each token.header ?? [] as cell, j (j)}
                <th class="border-paper-hairline text-ink-heading border-b px-2.5 py-1.5 text-left font-medium">
                  <MarkdownInline tokens={cell.tokens ?? []} />
                </th>
              {/each}
            </tr>
          </thead>
          <tbody>
            {#each token.rows ?? [] as row, j (j)}
              <tr>
                {#each row as cell, k (k)}
                  <td class="border-paper-hairline border-b px-2.5 py-1.5 align-top">
                    <MarkdownInline tokens={cell.tokens ?? []} />
                  </td>
                {/each}
              </tr>
            {/each}
          </tbody>
        </table>
      </div>
    {:else if token.type === 'hr'}
      <hr class="border-paper-hairline" />
    {:else if token.type === 'text'}
      <!-- Loose block-level text (list-item bodies land here). -->
      <p class="break-words">
        {#if token.tokens?.length}
          <MarkdownInline tokens={token.tokens} />
        {:else}
          {token.escaped ? unescapeMarked(token.text ?? '') : (token.text ?? '')}
        {/if}
      </p>
    {:else if token.type === 'html'}
      <p class="break-words whitespace-pre-wrap">{token.text ?? ''}</p>
    {:else if token.type === 'space'}
      <!-- blank separation is the container's gap -->
    {:else}
      <p class="break-words whitespace-pre-wrap">{token.raw ?? ''}</p>
    {/if}
  {/each}
</div>
