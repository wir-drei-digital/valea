<script lang="ts">
  // Sandboxed renderer for one HTML mail body. The containment model, in
  // layers (none alone is load-bearing):
  //
  //  1. The `html` prop is ALREADY sanitized backend-side
  //     (`Valea.Mail.HtmlSanitizer` — scripts/embeds/handlers/URL schemes
  //     stripped) before it ever reaches this component.
  //  2. It renders inside an iframe with `sandbox="allow-same-origin"` —
  //     and deliberately WITHOUT `allow-scripts`: nothing in the framed
  //     document can execute, open popups, submit forms, or navigate the
  //     app. `allow-same-origin` is what lets the PARENT reach in — to
  //     measure the height and intercept link clicks — while the inert
  //     document itself has no script of its own to abuse the origin with.
  //  3. A CSP `<meta>` injected into the srcdoc gates every network load:
  //     remote http(s) images/fonts load ONLY when `allowRemote` says so
  //     (trusted sender, or this render's one-time allow); otherwise only
  //     `data:` images render and every remote fetch — tracking pixels
  //     included — is blocked by the browser itself.
  //
  // Link clicks are intercepted from the parent and routed through
  // `openExternal` (the user's real browser / the desktop's open_external
  // command) — inside the sandbox they would otherwise just dead-end.
  import { openExternal } from '$lib/shell/external-link';

  let { html, allowRemote = false }: { html: string; allowRemote?: boolean } = $props();

  let iframeEl = $state<HTMLIFrameElement | null>(null);
  let height = $state(240);

  const csp = $derived(
    allowRemote
      ? "default-src 'none'; style-src 'unsafe-inline'; img-src data: cid: https: http:; font-src data: https:"
      : "default-src 'none'; style-src 'unsafe-inline'; img-src data: cid:"
  );

  // White reading surface on purpose, both themes — HTML mail is authored
  // against a light background and inverting it mangles most messages.
  const srcdoc = $derived(
    `<!doctype html><html><head><meta charset="utf-8">` +
      `<meta http-equiv="Content-Security-Policy" content="${csp}">` +
      `<style>` +
      `html{background:#fff}` +
      `body{margin:12px;font:14px/1.55 -apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;color:#1c1c1c;word-break:break-word}` +
      `img{max-width:100%;height:auto}` +
      `</style></head><body>${html}</body></html>`
  );

  function measure(): void {
    const doc = iframeEl?.contentDocument;
    if (!doc) return;
    const measured = Math.max(doc.documentElement?.scrollHeight ?? 0, doc.body?.scrollHeight ?? 0);
    if (measured > 0) height = Math.min(measured + 4, 20_000);
  }

  function onLoad(): void {
    measure();
    // Images finishing after the load event change the height — re-measure
    // shortly after (cheap; capped at two follow-ups).
    setTimeout(measure, 250);
    setTimeout(measure, 1200);

    const doc = iframeEl?.contentDocument;
    if (!doc) return;
    doc.addEventListener('click', (event) => {
      const target = event.target as Element | null;
      const anchor = target?.closest?.('a[href]');
      if (!anchor) return;
      event.preventDefault();
      const href = anchor.getAttribute('href') ?? '';
      // Only http(s) leaves the app; `openExternal` drops everything else.
      openExternal(href);
    });
  }
</script>

<iframe
  bind:this={iframeEl}
  title="Message content"
  {srcdoc}
  sandbox="allow-same-origin"
  referrerpolicy="no-referrer"
  onload={onLoad}
  style={`height: ${height}px`}
  class="border-paper-hairline w-full rounded-lg border bg-white"
></iframe>
