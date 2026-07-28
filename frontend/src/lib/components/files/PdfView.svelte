<script lang="ts">
  // Side-panes pass: PDFs render page-by-page onto canvases via pdf.js.
  // `pdfjs-dist` (and its worker asset) is imported LAZILY inside the effect
  // so the ~1 MB library only ships to readers who actually open a PDF —
  // it stays out of the initial bundle for everyone else.
  import { rawFileUrl } from './raw-url';

  let { mountKey, path }: { mountKey: string; path: string } = $props();

  let container = $state<HTMLDivElement | null>(null);
  let error = $state<string | null>(null);
  let rendering = $state(true);

  $effect(() => {
    const el = container;
    const url = rawFileUrl(mountKey, path);
    if (!el) return;
    // Every await below re-checks this: switching files (or unmounting)
    // mid-render must not keep appending canvases for the old document.
    // The in-flight page render is aborted outright rather than left to
    // finish painting a canvas nobody will see.
    let cancelled = false;
    let inFlight: { cancel: () => void } | null = null;
    rendering = true;
    error = null;
    el.replaceChildren();
    void (async () => {
      try {
        const pdfjs = await import('pdfjs-dist');
        const worker = await import('pdfjs-dist/build/pdf.worker.min.mjs?url');
        pdfjs.GlobalWorkerOptions.workerSrc = worker.default;
        const doc = await pdfjs.getDocument({ url }).promise;
        if (cancelled) return;
        for (let n = 1; n <= doc.numPages; n++) {
          const page = await doc.getPage(n);
          if (cancelled) return;
          // Fit each page to the pane's current width, then oversample by
          // the device pixel ratio (canvas pixels) while keeping the CSS
          // box at layout size — the same HiDPI shape pdf.js's own viewer
          // uses (an extra `transform`, applied before the viewport one).
          const base = page.getViewport({ scale: 1 });
          const scale = (el.clientWidth || 640) / base.width;
          const viewport = page.getViewport({ scale });
          const ratio = window.devicePixelRatio || 1;
          const canvas = document.createElement('canvas');
          canvas.width = Math.floor(viewport.width * ratio);
          canvas.height = Math.floor(viewport.height * ratio);
          canvas.style.width = `${viewport.width}px`;
          canvas.style.height = `${viewport.height}px`;
          canvas.className = 'mb-3 rounded-md border border-paper-hairline';
          el.appendChild(canvas);
          const task = page.render({
            canvas,
            viewport,
            transform: ratio === 1 ? undefined : [ratio, 0, 0, ratio, 0, 0]
          });
          inFlight = task;
          await task.promise;
          inFlight = null;
          if (cancelled) return;
        }
      } catch {
        if (cancelled) return;
        el.replaceChildren();
        error = "This PDF can't be displayed. Open it in your file manager instead.";
      } finally {
        if (!cancelled) rendering = false;
      }
    })();
    return () => {
      cancelled = true;
      // Rejects the awaited promise with pdf.js's cancellation error, which
      // the `catch` above discards on the `cancelled` check.
      inFlight?.cancel();
    };
  });
</script>

<!-- The container stays mounted in every state (error included): it is what
     `bind:this` — and therefore this component's own effect dependency —
     hangs off, so hiding it behind an `{:else}` would strand a failed view
     with no way to re-render the next file opened here. -->
{#if error}
  <p class="text-ink-meta text-[13px]">{error}</p>
{:else if rendering}
  <p class="text-ink-meta pb-2 text-[13px]">Rendering…</p>
{/if}
<div bind:this={container}></div>
