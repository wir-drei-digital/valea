<script lang="ts">
  // Prompt input dock: autogrow textarea + ConfigChips row. Presentational —
  // takes plain data (`busy`, `configItems`) and callback props; the caller
  // (T18's Chat route) wires the callbacks to an AgentSessionStore
  // (`onSend` -> `store.prompt`, `onStop` -> `store.cancel` (interrupt the
  // in-flight turn, not kill the session), `onSetConfig` ->
  // `store.setConfigOption`).
  //
  // This store has no client-side prompt queue (unlike the legend donor) —
  // `AgentSessionStore.prompt` always sends immediately and raises `busy`,
  // so sending is simply disabled while busy; only Stop stays live.
  import ConfigChip from './ConfigChip.svelte';
  import type { AcpItemLike } from './item-shapes';

  let {
    busy,
    configItems,
    onSend,
    onStop,
    onSetConfig
  }: {
    busy: boolean;
    configItems: AcpItemLike[];
    onSend: (text: string) => void;
    onStop: () => void;
    onSetConfig: (configId: string, value: string) => void;
  } = $props();

  let text = $state('');
  let textareaEl = $state<HTMLTextAreaElement | null>(null);

  const LINE_HEIGHT_PX = 20; // matches text-[13.5px] leading-[1.5] rendered height
  const MAX_LINES = 8;
  const MAX_HEIGHT_PX = LINE_HEIGHT_PX * MAX_LINES;

  function autogrow() {
    if (!textareaEl) return;
    textareaEl.style.height = 'auto';
    textareaEl.style.height = `${Math.min(textareaEl.scrollHeight, MAX_HEIGHT_PX)}px`;
  }

  function submit() {
    if (busy) return;
    const value = text.trim();
    if (!value) return;
    onSend(value);
    text = '';
    // Collapse back to one line after send — the DOM value is already
    // cleared via bind:value; recompute height on the next tick's input event
    // won't fire since no keystroke follows, so reset it directly here.
    if (textareaEl) textareaEl.style.height = 'auto';
  }

  function onKeydown(e: KeyboardEvent) {
    // Ignore Enter while an IME composition is active — CJK input confirms a
    // candidate with Enter, which must not send the message.
    if (e.isComposing) return;
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      submit();
    }
  }
</script>

<!-- Composer per the cockpit chat screen: a bordered card floating on the
     surface with the send action inside it, and the session's config
     selectors as a quiet row underneath — not chrome attached to a
     hairline. -->
<div class="px-4 pt-1 pb-4">
  <div
    class="border-paper-border bg-paper-card shadow-card focus-within:border-paper-button-border rounded-[14px] border transition-colors"
  >
    <div class="flex items-end gap-3 px-4 py-3">
      <textarea
        bind:this={textareaEl}
        bind:value={text}
        oninput={autogrow}
        onkeydown={onKeydown}
        disabled={busy}
        rows="1"
        placeholder="Message the agent…"
        class="text-ink-body placeholder:text-ink-meta block max-h-[160px] min-h-[20px] flex-1 resize-none overflow-y-auto bg-transparent text-[13.5px] leading-[1.5] focus:outline-none disabled:opacity-60"
      ></textarea>

      {#if busy}
        <div class="flex shrink-0 items-center gap-2.5">
          <span class="text-ink-meta text-[12px]">Working…</span>
          <button
            type="button"
            onclick={onStop}
            class="border-paper-button-border text-ink-secondary hover:bg-paper-pill rounded-lg border px-3 py-1.5 text-[12px] font-medium transition-colors"
          >
            Stop
          </button>
        </div>
      {:else}
        <button
          type="button"
          onclick={submit}
          disabled={!text.trim()}
          class="bg-act hover:bg-act-hover shrink-0 rounded-lg px-3.5 py-1.5 text-[12.5px] font-semibold text-white transition-colors disabled:opacity-40"
        >
          Send
        </button>
      {/if}
    </div>
  </div>

  {#if configItems.length > 0}
    <div class="mt-2 flex flex-wrap items-center gap-x-1.5 gap-y-1 px-1">
      {#each configItems as item (item.id)}
        <ConfigChip {item} onSelect={(value) => onSetConfig(item.id, value)} />
      {/each}
    </div>
  {/if}
</div>
