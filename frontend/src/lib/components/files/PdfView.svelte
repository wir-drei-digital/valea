<script lang="ts">
  // Side-panes pass: PDFs render page-by-page onto canvases via pdf.js.
  // `pdfjs-dist` (and its worker asset) is imported LAZILY inside the effect
  // so the ~1 MB library only ships to readers who actually open a PDF —
  // it stays out of the initial bundle for everyone else.
  // pdf.js fetches the bytes itself, so the control token goes to it as
  // `httpHeaders` rather than on a fetch we make: `/files/raw` exempts only
  // image extensions, and an unauthenticated `.pdf` request gets the
  // route's opaque 404 (which surfaces here as the error message below).
  import { rawFileHeaders, rawFileUrl } from './raw-url';

  let { mountKey, path }: { mountKey: string; path: string } = $props();

  let container = $state<HTMLDivElement | null>(null);
  let error = $state<string | null>(null);
  let rendering = $state(true);
  /** Layout width the pages are fitted to; a resize re-runs the render below. */
  let fitWidth = $state(0);
  /**
   * `mountKey|path` of what is currently painted. It tells a REFIT (same
   * document, new width — the old canvases stay up, CSS-scaled, until the
   * crisp ones are ready) from a file switch (clear first: the pane must
   * never show the previous file's pages while the new one decodes).
   */
  let paintedKey = '';

  // A ResizeObserver, not a window listener: a pane splitter or the context
  // rail resizes this container without the window changing size at all —
  // and observing the element also covers the window case for free.
  // Declared BEFORE the render effect so `fitWidth` is already measured on
  // the first flush, and the initial render doesn't run twice.
  $effect(() => {
    const el = container;
    if (!el) return;
    fitWidth = Math.round(el.clientWidth);
    let timer: ReturnType<typeof setTimeout> | undefined;
    const observer = new ResizeObserver((entries) => {
      const next = Math.round(entries[0]?.contentRect.width ?? 0);
      // Debounced, and only on a REAL change: a drag fires this every frame
      // and each re-render decodes every page of the document again.
      if (next === 0 || next === fitWidth) return;
      clearTimeout(timer);
      timer = setTimeout(() => (fitWidth = next), 200);
    });
    observer.observe(el);
    return () => {
      observer.disconnect();
      clearTimeout(timer);
    };
  });

  $effect(() => {
    const el = container;
    const url = rawFileUrl(mountKey, path);
    const width = fitWidth;
    if (!el) return;
    // Every await below re-checks this: switching files (or unmounting)
    // mid-render must not keep appending canvases for the old document.
    // The in-flight page render is aborted outright rather than left to
    // finish painting a canvas nobody will see.
    let cancelled = false;
    let inFlight: { cancel: () => void } | null = null;
    const key = `${mountKey}|${path}`;
    const refit = key === paintedKey && el.childElementCount > 0;
    // A refit paints into a DETACHED div and swaps the finished set in at
    // once: the pages already on screen scale with the container (CSS width
    // 100%), so they read correctly — just soft — instead of blanking out
    // mid-drag. A first paint keeps appending straight into the container,
    // so a long document shows page 1 without waiting for page N.
    const target = refit ? document.createElement('div') : el;
    rendering = !refit;
    error = null;
    if (!refit) el.replaceChildren();
    void (async () => {
      try {
        const pdfjs = await import('pdfjs-dist');
        const worker = await import('pdfjs-dist/build/pdf.worker.min.mjs?url');
        pdfjs.GlobalWorkerOptions.workerSrc = worker.default;
        const doc = await pdfjs.getDocument({ url, httpHeaders: rawFileHeaders() }).promise;
        if (cancelled) return;
        for (let n = 1; n <= doc.numPages; n++) {
          const page = await doc.getPage(n);
          if (cancelled) return;
          // Fit each page to the pane's current width, then oversample by
          // the device pixel ratio (canvas pixels) while keeping the CSS
          // box at layout size — the same HiDPI shape pdf.js's own viewer
          // uses (an extra `transform`, applied before the viewport one).
          // The CSS box is stated as 100%/auto rather than the pixel pair:
          // same size at render time, but it also means a width change
          // rescales what is on screen IMMEDIATELY (correct, just soft)
          // while the debounced re-render catches up with crisp pixels.
          const base = page.getViewport({ scale: 1 });
          const scale = (width || el.clientWidth || 640) / base.width;
          const viewport = page.getViewport({ scale });
          const ratio = window.devicePixelRatio || 1;
          const canvas = document.createElement('canvas');
          canvas.width = Math.floor(viewport.width * ratio);
          canvas.height = Math.floor(viewport.height * ratio);
          canvas.style.width = '100%';
          canvas.style.height = 'auto';
          canvas.className = 'mb-3 rounded-md border border-paper-hairline';
          target.appendChild(canvas);
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
        if (target !== el) el.replaceChildren(...target.childNodes);
        paintedKey = key;
      } catch {
        if (cancelled) return;
        el.replaceChildren();
        paintedKey = '';
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
