<script lang="ts">
  // Side-panes pass: the fallback viewer — any file format without a
  // dedicated viewer is shown as read-only text. Display is capped so
  // opening a huge (or binary) file can't lock up the pane; a fetch failure
  // stays IN the view rather than bubbling out as a broken page.
  // The fetch carries the control token: `/files/raw` only exempts image
  // extensions (an `<img>` tag can't send headers — this can), so a bare
  // request for a text file gets the route's opaque 404.
  //
  // The cap is enforced on the WIRE, not after the fact (final review, I2):
  // admission to `/files/raw` is extension-free and the serve path has no
  // size limit, so `await res.text()` — read the whole body, then slice —
  // meant one click on a video or a rotated log buffered the entire file
  // into the renderer before anything was capped. The body is read chunk by
  // chunk instead, the reader is cancelled the moment CAP bytes are in
  // hand, and an `AbortController` makes closing or re-pointing the pane
  // stop the transfer rather than merely ignore its result.
  import { rawFileHeaders, rawFileUrl } from './raw-url';

  let { mountKey, path }: { mountKey: string; path: string } = $props();

  /** Bytes off the wire, not characters — "500 KB" is what the note below promises. */
  const CAP = 500_000;
  let text = $state<string | null>(null);
  let truncated = $state(false);
  let error = $state<string | null>(null);

  /**
   * Reads at most `CAP` bytes of `body`, decoded incrementally. Returns the
   * text plus whether bytes were left unread — which is asked EXACTLY: a
   * file whose size is a precise multiple of the chunking is not reported
   * truncated on a guess, it costs one more `read()` to know.
   */
  async function readCapped(
    body: ReadableStream<Uint8Array>
  ): Promise<{ text: string; truncated: boolean }> {
    const reader = body.getReader();
    const decoder = new TextDecoder();
    let out = '';
    let received = 0;
    let more = false;

    try {
      while (received < CAP) {
        const { done, value } = await reader.read();
        if (done) break;
        if (!value?.byteLength) continue;
        const room = CAP - received;
        if (value.byteLength > room) {
          // A cut can land mid-codepoint; the flush below emits the
          // replacement char rather than a mojibake tail.
          out += decoder.decode(value.subarray(0, room), { stream: true });
          received = CAP;
          more = true;
          break;
        }
        received += value.byteLength;
        out += decoder.decode(value, { stream: true });
      }
      if (received >= CAP && !more) {
        more = !(await reader.read()).done;
      }
      out += decoder.decode();
      return { text: out, truncated: more };
    } finally {
      // Releases the connection: without this a capped read would leave the
      // rest of a multi-gigabyte body streaming into a reader nobody holds.
      void reader.cancel().catch(() => {});
    }
  }

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
        // `res.body` is null only where streams are unavailable (and on a
        // 204, which this route never sends) — fall back to the whole-body
        // read there rather than showing an error for a readable file.
        const result = res.body
          ? await readCapped(res.body)
          : await res.text().then((whole) => ({
              text: whole.slice(0, CAP),
              truncated: whole.length > CAP
            }));
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
</script>

{#if error}
  <p class="text-ink-meta text-[13px]">{error}</p>
{:else if text === null}
  <p class="text-ink-meta text-[13px]">Loading…</p>
{:else}
  {#if truncated}
    <p class="text-ink-meta pb-2 text-[11.5px]">Showing the first 500 KB.</p>
  {/if}
  <pre
    class="text-ink-body font-mono text-[12px] leading-relaxed break-words whitespace-pre-wrap">{text}</pre>
{/if}
