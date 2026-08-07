<script lang="ts">
  // Side-panes pass: the fallback viewer — any file format without a
  // dedicated viewer is shown as read-only text. Display is capped so
  // opening a huge (or binary) file can't lock up the pane; a fetch failure
  // stays IN the view rather than bubbling out as a broken page.
  // The fetch carries the control token: `/files/raw` only exempts image
  // extensions (an `<img>` tag can't send headers — this can), so a bare
  // request for a text file gets the route's opaque 404.
  //
  // The cap lives in `capped-text.ts` (shared with `CsvView`) and is enforced
  // on the WIRE, not after the fact — see that module's header. An
  // `AbortController` makes closing or re-pointing the pane stop the
  // transfer rather than merely ignore its result.
  import { rawFileHeaders, rawFileUrl } from './raw-url';
  import { cappedResponseText } from './capped-text';
  import CodeBlock from '$lib/highlight/CodeBlock.svelte';
  import { grammarForFilename } from '$lib/highlight/languages';

  let { mountKey, path }: { mountKey: string; path: string } = $props();

  let text = $state<string | null>(null);
  let truncated = $state(false);
  let error = $state<string | null>(null);

  $effect(() => {
    // Captured before the await so a response for a file the reader has
    // since navigated away from is dropped rather than shown.
    const target = { mountKey, path };
    const controller = new AbortController();
    let cancelled = false;
    text = null;
    error = null;
    truncated = false;
    void (async () => {
      try {
        const res = await fetch(rawFileUrl(target.mountKey, target.path), {
          headers: rawFileHeaders(),
          signal: controller.signal
        });
        if (!res.ok) throw new Error(String(res.status));
        const result = await cappedResponseText(res);
        if (cancelled) return;
        truncated = result.truncated;
        text = result.text;
      } catch {
        if (!cancelled) error = "This file can't be displayed.";
      }
    })();
    return () => {
      cancelled = true;
      // Real cancellation, not just a discarded result: an in-flight
      // `read()` rejects with AbortError, which the `catch` above swallows
      // on the `cancelled` check.
      controller.abort();
    };
  });

  // A truncated read is a PREFIX of a file, and highlighting a prefix ends
  // in whatever state the cut left open — an unterminated string swallowing
  // the tail in one colour. Plain text is the honest rendering of a partial
  // file.
  const grammar = $derived(truncated ? null : grammarForFilename(path));
  // `text` is `string | null` while the fetch is in flight; the template
  // below only renders this branch once it is a string, but the derivation
  // runs regardless.
  const code = $derived(text ?? '');
</script>

{#if error}
  <p class="text-ink-meta text-[13px]">{error}</p>
{:else if text === null}
  <p class="text-ink-meta text-[13px]">Loading…</p>
{:else}
  {#if truncated}
    <p class="text-ink-meta pb-2 text-[11.5px]">Showing the first 500 KB.</p>
  {/if}
  <CodeBlock
    {code}
    {grammar}
    class="text-ink-body font-mono text-[12px] leading-relaxed break-words whitespace-pre-wrap"
  />
{/if}
