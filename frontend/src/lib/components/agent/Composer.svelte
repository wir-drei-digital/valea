<script lang="ts">
  // Prompt input dock: autogrow textarea + ConfigChips row. Presentational —
  // takes plain data (`busy`, `configItems`) and callback props; the caller
  // (T18's Chat route) wires the callbacks to an AgentSessionStore
  // (`onSend` -> `store.prompt`, `onStop` -> `store.stop`, `onSetConfig` ->
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

<div class="border-paper-hairline border-t px-4 py-3">
  <textarea
    bind:this={textareaEl}
    bind:value={text}
    oninput={autogrow}
    onkeydown={onKeydown}
    disabled={busy}
    rows="1"
    placeholder="Message the agent…"
    class="text-ink-body placeholder:text-ink-meta block max-h-[160px] min-h-[20px] w-full resize-none overflow-y-auto bg-transparent text-[13.5px] leading-[1.5] focus:outline-none disabled:opacity-60"
  ></textarea>

  <div class="mt-2 flex flex-wrap items-center gap-1.5">
    {#each configItems as item (item.id)}
      <ConfigChip {item} onSelect={(value) => onSetConfig(item.id, value)} />
    {/each}

    <span class="flex-1"></span>

    {#if busy}
      <span class="text-ink-meta text-[12px]">Working…</span>
      <button type="button" onclick={onStop} class="text-ink-secondary hover:text-ink-heading text-[12px]">
        Stop
      </button>
    {:else}
      <button
        type="button"
        onclick={submit}
        disabled={!text.trim()}
        class="bg-act hover:bg-act-hover rounded-md px-3 py-1.5 text-[12.5px] font-medium text-white disabled:opacity-40"
      >
        Send
      </button>
    {/if}
  </div>
</div>
