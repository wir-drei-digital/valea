<script lang="ts">
  // Format dispatch for one file (side-panes pass): `.md` gets the full page
  // editor; known binary formats get their own viewer; everything else is
  // read-only text. Usable both as a route primary and inside a side pane —
  // it takes `mountKey`/`path` as props and never reads the URL itself.
  import MarkdownPageView from './MarkdownPageView.svelte';
  import PlainTextView from '$lib/components/files/PlainTextView.svelte';
  import PdfView from '$lib/components/files/PdfView.svelte';
  import ImageView from '$lib/components/files/ImageView.svelte';
  import { fileLeafKind } from '$lib/components/knowledge/file-leaf';

  let {
    mountKey,
    path,
    onVanished
  }: {
    mountKey: string;
    path: string;
    /** Forwarded to `MarkdownPageView` — see its own prop doc. */
    onVanished?: () => void;
  } = $props();

  // Lowercase, leading dot, `''` when the basename has no extension — the
  // same shape `IcmNode.ext` carries, which is what `fileLeafKind` expects.
  // Derived from the BASENAME so a dot in a folder name ("v1.2/notes") can't
  // be mistaken for the file's extension.
  const ext = $derived.by(() => {
    const name = path.split('/').pop() ?? '';
    const dot = name.lastIndexOf('.');
    return dot > 0 ? name.slice(dot).toLowerCase() : '';
  });

  // `.md` is matched exactly as the route's own optimistic `isPage` always
  // did (case-sensitive `endsWith`), so which files open in the editor
  // doesn't change here. `fileLeafKind` buckets the rest into
  // image/pdf/other — the same mapping the file-leaf ROWS already use, so a
  // row's icon and the viewer it opens can never disagree.
  const format = $derived.by((): 'md' | 'image' | 'pdf' | 'text' => {
    if (path.endsWith('.md')) return 'md';
    const kind = fileLeafKind(ext);
    if (kind === 'image') return 'image';
    if (kind === 'pdf') return 'pdf';
    return 'text';
  });

  let mdRef: MarkdownPageView | null = $state(null);

  /**
   * Flush contract for callers that mutate the open file (rename/delete,
   * workspace switch, pane close). Delegates to the markdown editor and
   * resolves immediately for every read-only format — nothing else here
   * holds unsaved state.
   */
  export async function flushPending(): Promise<void> {
    await mdRef?.flushPending();
  }
</script>

{#if format === 'md'}
  <MarkdownPageView bind:this={mdRef} {mountKey} {path} {onVanished} />
{:else}
  <article class="mx-auto flex w-full max-w-[596px] flex-col gap-3">
    <header class="flex flex-col gap-1.5">
      <p class="text-overline">Files</p>
      <p class="text-ink-meta font-mono text-[11.5px]">{path}</p>
    </header>
    {#if format === 'image'}
      <ImageView {mountKey} {path} />
    {:else if format === 'pdf'}
      <PdfView {mountKey} {path} />
    {:else}
      <PlainTextView {mountKey} {path} />
    {/if}
  </article>
{/if}
