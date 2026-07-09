<script lang="ts">
  import { page } from '$app/state';
  import { AppFrame, ListPane } from '$lib/components/shell';
  import { icmStore } from '$lib/stores/icm.svelte';
  import { api } from '$lib/api/client';
  import { encodePath, type IcmNode } from '$lib/shell/nav';
  import { Skeleton } from '$lib/components/ui/skeleton';

  // Route params arrive URL-encoded per segment (e.g. `Tone%20%26%20Voice`);
  // decode each segment rather than the whole param so a literal `%2F` in a
  // filename would never be mistaken for a path separator.
  const decodedPath = $derived(
    (page.params.path ?? '')
      .split('/')
      .map((segment) => decodeURIComponent(segment))
      .join('/')
  );

  function findNode(nodes: IcmNode[], path: string): IcmNode | undefined {
    for (const node of nodes) {
      if (node.path === path) return node;
      if (node.type === 'folder' && node.children) {
        const found = findNode(node.children, path);
        if (found) return found;
      }
    }
    return undefined;
  }

  const node = $derived(findNode(icmStore.nodes, decodedPath));
  const isPage = $derived(node?.type === 'page');

  type PageContent = { path: string; title: string; uri: string; content: string };

  let content: PageContent | null = $state(null);
  let loadFailed = $state(false);
  let loading = $state(false);
  let loadedPath = $state<string | null>(null);

  async function loadPage(path: string) {
    loading = true;
    loadFailed = false;
    content = null;
    const result = await api.icmPage(path);
    if (result.ok) {
      content = result.data as PageContent;
    } else {
      loadFailed = true;
    }
    loading = false;
    loadedPath = path;
  }

  $effect(() => {
    if (isPage && decodedPath !== loadedPath) {
      void loadPage(decodedPath);
    }
  });
</script>

<AppFrame>
  {#snippet list()}
    <ListPane>
      {#snippet header()}
        <p class="text-overline">{node?.type === 'folder' ? node.name : 'Knowledge'}</p>
      {/snippet}
      {#snippet children()}
        <ul class="flex flex-col py-1">
          {#if node?.type === 'folder'}
            {#each node.children ?? [] as child (child.path)}
              <li>
                <a
                  href={`/knowledge/${encodePath(child.path)}`}
                  class="flex items-center gap-2 px-3 py-2 text-[13px] text-ink-body transition-colors hover:bg-paper-pill"
                >
                  <span class="min-w-0 flex-1 truncate">{child.name}</span>
                  {#if child.type === 'folder'}
                    <span class="text-ink-meta text-[11px] tabular-nums">{child.pageCount ?? 0}</span>
                  {/if}
                </a>
              </li>
            {/each}
          {/if}
        </ul>
      {/snippet}
    </ListPane>
  {/snippet}

  {#snippet main()}
    {#if !icmStore.loaded}
      <div class="flex flex-col gap-3" data-testid="knowledge-loading-skeleton">
        <Skeleton class="h-6 w-1/3" />
        <Skeleton class="h-4 w-2/3" />
        <Skeleton class="h-4 w-1/2" />
      </div>
    {:else if !node}
      <p class="text-ink-body text-[13.5px]">This page doesn't exist anymore.</p>
    {:else if node.type === 'folder'}
      <header class="flex flex-col gap-2">
        <h1 class="font-display text-[24px] text-ink-heading">{node.name}</h1>
        <p class="max-w-[520px] text-[13.5px] text-ink-body">Pick a page from the list to read it.</p>
      </header>
    {:else if loading}
      <p class="text-ink-body text-[13.5px]">Loading…</p>
    {:else if loadFailed || !content}
      <p class="text-ink-body text-[13.5px]">This page doesn't exist anymore.</p>
    {:else}
      <article class="flex flex-col gap-4">
        <p class="font-mono text-ink-meta text-[12px]">icm/{decodedPath}</p>
        <h1 class="font-display text-[24px] text-ink-heading">{content.title}</h1>
        <pre class="whitespace-pre-wrap text-[13.5px] leading-relaxed text-ink-body">{content.content}</pre>
        <div class="bg-paper-pill rounded-xl px-4 py-3">
          <p class="text-[13px] text-ink-body">
            This folder is yours — plain files. Export or hand it over anytime.
          </p>
        </div>
      </article>
    {/if}
  {/snippet}
</AppFrame>
