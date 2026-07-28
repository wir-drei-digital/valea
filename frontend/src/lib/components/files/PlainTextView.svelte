<script lang="ts">
  // Side-panes pass: the fallback viewer — any file format without a
  // dedicated viewer is shown as read-only text. Display is capped so
  // opening a huge (or binary) file can't lock up the pane; a fetch failure
  // stays IN the view rather than bubbling out as a broken page.
  import { rawFileUrl } from './raw-url';

  let { mountKey, path }: { mountKey: string; path: string } = $props();

  const CAP = 500_000;
  let text = $state<string | null>(null);
  let truncated = $state(false);
  let error = $state<string | null>(null);

  $effect(() => {
    // Captured before the await so a response for a file the reader has
    // since navigated away from is dropped rather than shown.
    const target = { mountKey, path };
    let cancelled = false;
    text = null;
    error = null;
    truncated = false;
    void (async () => {
      try {
        const res = await fetch(rawFileUrl(target.mountKey, target.path));
        if (!res.ok) throw new Error(String(res.status));
        const body = await res.text();
        if (cancelled) return;
        truncated = body.length > CAP;
        text = truncated ? body.slice(0, CAP) : body;
      } catch {
        if (!cancelled) error = "This file can't be displayed.";
      }
    })();
    return () => {
      cancelled = true;
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
