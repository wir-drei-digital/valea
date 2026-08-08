<script lang="ts">
  // Format dispatch for one file (side-panes pass): `.md` gets the full page
  // editor; known binary formats get their own viewer; everything else is
  // read-only text. Usable both as a route primary and inside a side pane —
  // it takes `mountKey`/`path` as props and never reads the URL itself.
  import MarkdownPageView from './MarkdownPageView.svelte';
  import PlainTextView from '$lib/components/files/PlainTextView.svelte';
  import PdfView from '$lib/components/files/PdfView.svelte';
  import ImageView from '$lib/components/files/ImageView.svelte';
  import CsvView from '$lib/components/files/CsvView.svelte';
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
  // image/pdf/csv/other — a DELIBERATELY DIFFERENT partition from
  // `fileIcon` (`file-icon.ts`), which picks a tree row's glyph off the
  // label instead. The two are allowed to disagree, and do: `.svg` gets
  // `FileImage` in the tree, but `fileLeafKind` leaves it out of its image
  // set on purpose (the raw-file route serves SVG as inert `text/plain`,
  // never `image/svg+xml` — see `file-leaf.ts`), so it opens here as plain
  // text. `.tsv`/`.xlsx` similarly get `FileSpreadsheet` in the tree but
  // still open as text — only `.csv` is a real viewer format so far. One
  // partition picks the row's icon, the other picks the viewer; nothing
  // requires them to land on the same answer for a given extension.
  const format = $derived.by((): 'md' | 'image' | 'pdf' | 'csv' | 'text' => {
    if (path.endsWith('.md')) return 'md';
    const kind = fileLeafKind(ext);
    if (kind === 'image') return 'image';
    if (kind === 'pdf') return 'pdf';
    if (kind === 'csv') return 'csv';
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
  <!-- The reading column is carried BLOCK BY BLOCK, not by the article, so a
       format that needs the pane's real width can opt out of it — the same
       shape `MarkdownPageView` uses for its editor. A CSV table takes the
       full container: columns are the content, and squeezing them into a
       596px prose measure only adds horizontal scrolling. -->
  <article class="flex w-full flex-col gap-3">
    <!-- The header shares its block's width, so it lines up with whatever is
         below it — the reading column for a document, the pane's full width
         for a table. -->
    <!-- No overline. A "FILES" label above the path told you which section of
         the app you were in, and the tab strip above this now names the file
         itself — two labels for one fact, the outer one the less useful. The
         path stays: it is the only thing here that says WHICH file. -->
    <header class={['flex w-full flex-col gap-1.5', format === 'csv' ? '' : 'mx-auto max-w-[596px]']}>
      <p class="text-ink-meta font-mono text-[11.5px]">{path}</p>
    </header>
    {#if format === 'csv'}
      <CsvView {mountKey} {path} />
    {:else}
      <div class="mx-auto w-full max-w-[596px]">
        {#if format === 'image'}
          <ImageView {mountKey} {path} />
        {:else if format === 'pdf'}
          <PdfView {mountKey} {path} />
        {:else}
          <PlainTextView {mountKey} {path} />
        {/if}
      </div>
    {/if}
  </article>
{/if}
