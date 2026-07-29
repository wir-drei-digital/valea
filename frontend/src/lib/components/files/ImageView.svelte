<script lang="ts">
  // Side-panes pass: an image file leaf opened as a view — the bytes come
  // straight from `/files/raw` (same endpoint the editor's inline images
  // already use), so there is nothing to fetch or decode here ourselves.
  //
  // Deliberately NO `rawFileHeaders()`: an `<img>` src cannot send headers,
  // which is exactly why the route leaves image extensions token-exempt.
  // This component is that exemption's whole remaining scope — and the
  // reason `file-leaf.ts`'s `IMAGE_EXTS` must stay a SUBSET of the route's
  // `@allowed_types` (final review, I1).
  import { rawFileUrl } from './raw-url';

  let { mountKey, path }: { mountKey: string; path: string } = $props();

  const src = $derived(rawFileUrl(mountKey, path));

  // A failure stays IN the view instead of leaving the browser's broken
  // -image glyph with no explanation (final review, I1) — same in-view
  // message shape as `PdfView`/`PlainTextView`. Keyed on the SRC that
  // failed rather than a bare boolean, so re-pointing the pane at another
  // file clears the error without an effect having to race the load.
  let failedSrc = $state<string | null>(null);
  const failed = $derived(failedSrc === src);
</script>

{#if failed}
  <p class="text-ink-meta text-[13px]">This image can't be displayed.</p>
{:else}
  <img
    {src}
    alt={path.split('/').pop()}
    onerror={() => (failedSrc = src)}
    class="border-paper-hairline max-w-full rounded-md border"
  />
{/if}
