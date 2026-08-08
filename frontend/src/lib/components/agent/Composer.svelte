<script lang="ts">
  // Prompt input dock: autogrow textarea + ConfigChips row + context donut +
  // working indicator + queued messages. Presentational — takes plain data
  // (`busy`, `configItems`, `usageItem`, `queued`, `turnStartedAt`) and
  // callback props; the caller (T18's Chat route) wires the callbacks to an
  // AgentSessionStore (`onSend` -> `store.send` (queue-aware), `onStop` ->
  // `store.cancel` (interrupt the in-flight turn, not kill the session),
  // `onSetConfig` -> `store.setConfigOption`, and the queued-message
  // callbacks -> `store.updateQueued`/`dismissQueued`/`sendQueuedNow`).
  //
  // SECURITY: queued message text is user-authored content — plain Svelte
  // interpolation only, {@html} FORBIDDEN (same note as elsewhere under
  // agent/).
  import ArrowUp from '@lucide/svelte/icons/arrow-up';
  import Square from '@lucide/svelte/icons/square';
  import Pencil from '@lucide/svelte/icons/pencil';
  import X from '@lucide/svelte/icons/x';
  import ChevronDown from '@lucide/svelte/icons/chevron-down';
  import ChevronUp from '@lucide/svelte/icons/chevron-up';
  import ConfigChip from './ConfigChip.svelte';
  import {
    configWireId,
    contextUsage,
    usageFields,
    type AcpItemLike
  } from './item-shapes';
  import { activityLabel, type RunningTool } from './activity';
  import type { QueuedMessage } from '$lib/stores/agent-session.svelte';

  let {
    busy,
    configItems,
    usageItem = undefined,
    queued = [],
    turnStartedAt = null,
    activity = [],
    onSend,
    onStop,
    onSetConfig,
    onEditQueued = () => {},
    onDismissQueued = () => {},
    onSendQueuedNow = () => {},
    placeholder = 'Message the agent…',
    draft = $bindable('')
  }: {
    busy: boolean;
    configItems: AcpItemLike[];
    usageItem?: AcpItemLike | undefined;
    queued?: QueuedMessage[];
    turnStartedAt?: number | null;
    /**
     * Tool calls in flight right now (`activity.ts`). Drives what the working
     * indicator SAYS and what it expands to show. Empty is the normal case
     * for a turn that is only streaming text, and the indicator then reads
     * exactly as it always did.
     */
    activity?: RunningTool[];
    onSend: (text: string) => void;
    onStop: () => void;
    onSetConfig: (configId: string, value: string) => void;
    onEditQueued?: (id: string, text: string) => void;
    onDismissQueued?: (id: string) => void;
    onSendQueuedNow?: (id: string) => void;
    placeholder?: string;
    /**
     * The unsent text in the box. Bindable so a caller whose `onSend` can
     * FAIL can hand the text back: `submit` clears it the moment it hands
     * over, and an unbound caller sees exactly the previous internal-state
     * behavior (writes stay local). Only `ChatView`'s new-session composer
     * binds it — creating a session is the one send that can be refused
     * after the box has already been emptied.
     */
    draft?: string;
  } = $props();

  let textareaEl = $state<HTMLTextAreaElement | null>(null);

  const LINE_HEIGHT_PX = 20; // matches text-[13.5px] leading-[1.5] rendered height
  const MAX_LINES = 8;
  // The textarea carries 5px vertical padding each side (see its class) so
  // its single-line box (30px) matches the icon buttons' height inside the
  // items-end row. scrollHeight includes that padding (border-box), so the
  // cap accounts for it too.
  const PAD_Y_TOTAL_PX = 10;
  const MAX_HEIGHT_PX = LINE_HEIGHT_PX * MAX_LINES + PAD_Y_TOTAL_PX;

  function autogrow() {
    if (!textareaEl) return;
    textareaEl.style.height = 'auto';
    textareaEl.style.height = `${Math.min(textareaEl.scrollHeight, MAX_HEIGHT_PX)}px`;
  }

  // The box's height follows the VALUE, not the keystroke: a send empties it
  // and a failed create fills it back in, and neither fires an `input` event,
  // so a keystroke-only autogrow would leave a one-line box wrapped around
  // several lines of restored text (and a several-line box around nothing
  // after a send).
  $effect(() => {
    void draft;
    autogrow();
  });

  // Sending stays live while busy — `onSend` (store.send) queues it then.
  function submit() {
    const value = draft.trim();
    if (!value) return;
    onSend(value);
    draft = '';
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

  // --- Turn timer: ticks once a second while a turn is in flight. ---

  let now = $state(Date.now());

  $effect(() => {
    if (!busy || turnStartedAt === null) return;
    now = Date.now();
    const interval = setInterval(() => {
      now = Date.now();
    }, 1000);
    return () => clearInterval(interval);
  });

  const elapsedLabel = $derived.by(() => {
    if (turnStartedAt === null) return '';
    return formatElapsed(Math.max(0, now - turnStartedAt));
  });

  /** Human-readable elapsed time: "8s", "1m 24s", "1h 12m". */
  function formatElapsed(ms: number): string {
    const totalSeconds = Math.floor(ms / 1000);
    if (totalSeconds < 60) return `${totalSeconds}s`;
    const totalMinutes = Math.floor(totalSeconds / 60);
    if (totalMinutes < 60) return `${totalMinutes}m ${totalSeconds % 60}s`;
    return `${Math.floor(totalMinutes / 60)}h ${totalMinutes % 60}m`;
  }

  const workingLabel = $derived(activityLabel(activity));
  let activityOpen = $state(false);

  // Collapse when the work finishes: leaving an empty expanded list under the
  // composer would be furniture with nothing in it.
  $effect(() => {
    if (activity.length === 0) activityOpen = false;
  });

  // --- Queued message inline editing ---

  let editingId = $state<string | null>(null);
  let editingText = $state('');

  function startEditing(message: QueuedMessage) {
    editingId = message.id;
    editingText = message.text;
  }

  function commitEditing() {
    if (editingId === null) return;
    const value = editingText.trim();
    if (value) onEditQueued(editingId, value);
    editingId = null;
  }

  function onEditKeydown(e: KeyboardEvent) {
    if (e.isComposing) return;
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      commitEditing();
    } else if (e.key === 'Escape') {
      editingId = null;
    }
  }

  // The "agent" selector (claude-agent-acp's AGENT_CONFIG_ID) is hidden by
  // product decision: switching subagents mid-session isn't a Valea
  // affordance, and the chip only added noise under the composer.
  const visibleConfigItems = $derived(configItems.filter((item) => configWireId(item) !== 'agent'));

  // --- Context donut (right end of the options row) ---

  const usage = $derived(contextUsage(usageItem));
  const usageTitle = $derived(
    usageFields(usageItem)
      .map((f) => `${f.label}: ${f.value}`)
      .join(' · ')
  );
</script>

<div class="px-4 pt-1 pb-4">
  {#if busy}
    <!-- Working indicator: three staggered bouncing dots, the name of the
         work actually in flight, and the turn's elapsed time. When tools are
         running the line is a BUTTON that expands to list them — "Working…"
         was equally true of a two-second edit and a five-minute research
         subtask, which made it useless exactly when it mattered.
         SECURITY: tool titles are agent-authored — plain interpolation. -->
    <!-- `role="status"` lives on this wrapper, not the toggle below, so the
         live region holds across BOTH states: a bare streaming turn (the
         toggle is a plain div) and one with tools running (the toggle
         becomes a button once `activity` is non-empty). It used to sit only
         on the div branch, so the announcement stopped the moment the first
         tool started — silent for exactly the long-running subtask a
         screen-reader user most needs to hear about. -->
    <div class="px-1 pb-1.5" role="status" aria-label="Agent working">
      <!-- `role="button"` here just agrees with the tag `this` already picks
           — svelte:element can't statically prove a dynamic tag is
           interactive, so the a11y lint wants a role stated whenever the
           click handler is live; it never overrides anything, since the
           element really is a `<button>` at that point. -->
      <svelte:element
        this={activity.length > 0 ? 'button' : 'div'}
        type={activity.length > 0 ? 'button' : undefined}
        onclick={activity.length > 0 ? () => (activityOpen = !activityOpen) : undefined}
        role={activity.length > 0 ? 'button' : undefined}
        aria-expanded={activity.length > 0 ? activityOpen : undefined}
        class="flex w-full items-center gap-2 text-left"
      >
        <span class="flex items-end gap-[3px]" aria-hidden="true">
          <span class="bg-work-dot size-1.5 animate-bounce rounded-full [animation-delay:-0.32s]"></span>
          <span class="bg-work-dot size-1.5 animate-bounce rounded-full [animation-delay:-0.16s]"></span>
          <span class="bg-work-dot size-1.5 animate-bounce rounded-full"></span>
        </span>
        <span class="text-ink-secondary min-w-0 truncate text-[12px]">{workingLabel}</span>
        {#if activity.length > 1}
          <span class="text-ink-meta shrink-0 text-[11.5px] tabular-nums">
            · {activity.length} running
          </span>
        {/if}
        {#if elapsedLabel}
          <span class="text-ink-meta shrink-0 text-[11.5px] tabular-nums">{elapsedLabel}</span>
        {/if}
        {#if activity.length > 0}
          <span class="ml-auto shrink-0">
            {#if activityOpen}
              <ChevronUp class="text-ink-meta size-3.5" aria-hidden="true" />
            {:else}
              <ChevronDown class="text-ink-meta size-3.5" aria-hidden="true" />
            {/if}
          </span>
        {/if}
      </svelte:element>

      {#if activityOpen && activity.length > 0}
        <ul class="mt-1.5 flex flex-col gap-1 pl-[26px]">
          {#each activity as item (item.id)}
            <li class="text-ink-body flex items-center gap-2 text-[12px]">
              <span class="bg-suggest-dash size-1.5 shrink-0 rounded-full" aria-hidden="true"></span>
              <span class="min-w-0 flex-1 truncate" title={item.title}>{item.title}</span>
            </li>
          {/each}
        </ul>
      {/if}
    </div>
  {/if}

  {#if queued.length > 0}
    <!-- Messages queued behind the in-flight turn — flushed when it ends;
         each stays editable, dismissable, or can jump the queue (which
         interrupts the turn). -->
    <ul class="flex flex-col gap-1 px-1 pb-1.5">
      {#each queued as message (message.id)}
        <li
          class="border-paper-border bg-paper-card/60 flex items-center gap-2 rounded-lg border border-dashed px-3 py-1.5"
        >
          {#if editingId === message.id}
            <!-- svelte-ignore a11y_autofocus -->
            <input
              type="text"
              bind:value={editingText}
              onkeydown={onEditKeydown}
              onblur={commitEditing}
              autofocus
              aria-label="Edit queued message"
              class="text-ink-body min-w-0 flex-1 bg-transparent text-[12.5px] focus:outline-none"
            />
          {:else}
            <span class="text-ink-secondary min-w-0 flex-1 truncate text-[12.5px]" title={message.text}>
              {message.text}
            </span>
          {/if}
          <span class="flex shrink-0 items-center gap-0.5">
            <button
              type="button"
              aria-label="Edit queued message"
              title="Edit"
              onclick={() => startEditing(message)}
              class="text-ink-meta hover:bg-paper-pill hover:text-ink-heading flex size-6 items-center justify-center rounded-md transition-colors"
            >
              <Pencil class="size-3" strokeWidth={1.5} />
            </button>
            <button
              type="button"
              aria-label="Send now, interrupting the current turn"
              title="Send now (interrupts the current turn)"
              onclick={() => onSendQueuedNow(message.id)}
              class="text-ink-meta hover:bg-paper-pill hover:text-ink-heading flex size-6 items-center justify-center rounded-md transition-colors"
            >
              <ArrowUp class="size-3.5" strokeWidth={1.5} />
            </button>
            <button
              type="button"
              aria-label="Dismiss queued message"
              title="Dismiss"
              onclick={() => onDismissQueued(message.id)}
              class="text-ink-meta hover:bg-paper-pill hover:text-ink-heading flex size-6 items-center justify-center rounded-md transition-colors"
            >
              <X class="size-3.5" strokeWidth={1.5} />
            </button>
          </span>
        </li>
      {/each}
    </ul>
  {/if}

  <!-- Composer per the cockpit chat screen: a bordered card floating on the
       surface with the send action inside it, and the session's config
       selectors as a quiet row underneath — not chrome attached to a
       hairline. -->
  <div
    class="border-paper-border bg-paper-card shadow-card focus-within:border-paper-button-border rounded-[14px] border transition-colors"
  >
    <div class="flex items-end gap-3 px-4 py-3">
      <textarea
        bind:this={textareaEl}
        bind:value={draft}
        oninput={autogrow}
        onkeydown={onKeydown}
        rows="1"
        placeholder={busy ? 'Queue a message…' : placeholder}
        class="text-ink-body placeholder:text-ink-meta block max-h-[170px] min-h-[30px] flex-1 resize-none overflow-y-auto bg-transparent py-[5px] text-[13.5px] leading-[1.5] focus:outline-none"
      ></textarea>

      <div class="flex shrink-0 items-center gap-2">
        {#if busy}
          <button
            type="button"
            onclick={onStop}
            aria-label="Stop the current turn"
            title="Stop"
            class="border-paper-button-border text-ink-secondary hover:bg-paper-pill flex size-[30px] items-center justify-center rounded-full border transition-colors"
          >
            <Square class="size-3 fill-current" strokeWidth={0} />
          </button>
        {/if}
        <button
          type="button"
          onclick={submit}
          disabled={!draft.trim()}
          aria-label={busy ? 'Queue message' : 'Send message'}
          title={busy ? 'Queue message' : 'Send'}
          class="bg-act hover:bg-act-hover flex size-[30px] items-center justify-center rounded-full text-primary-foreground transition-colors disabled:opacity-40"
        >
          <ArrowUp class="size-4" strokeWidth={2} />
        </button>
      </div>
    </div>
  </div>

  {#if visibleConfigItems.length > 0 || usage}
    <div class="mt-2 flex flex-wrap items-center gap-x-1.5 gap-y-1 px-1">
      {#each visibleConfigItems as item (item.id)}
        <!-- configWireId, NOT item.id: the render id is `config-`-prefixed
             for timeline uniqueness and the adapter rejects it as an
             unknown option (see item-shapes.ts). -->
        <ConfigChip {item} onSelect={(value) => onSetConfig(configWireId(item), value)} />
      {/each}
      {#if usage}
        <!-- Donut only, never a text fallback: an item without a usable
             used/max pair renders nothing here (a wrong or noisy indicator
             is worse than none). -->
        <span
          class="text-ink-meta ml-auto flex items-center gap-1"
          title={usageTitle}
          aria-label={`Context ${Math.round(usage.fraction * 100)}% used`}
        >
          <svg viewBox="0 0 20 20" class="size-4 -rotate-90" aria-hidden="true">
            <circle
              cx="10"
              cy="10"
              r="8"
              fill="none"
              stroke-width="3.5"
              class="stroke-paper-chip-border"
            />
            <circle
              cx="10"
              cy="10"
              r="8"
              fill="none"
              stroke-width="3.5"
              pathLength="100"
              stroke-dasharray="{Math.max(usage.fraction * 100, 2)} 100"
              stroke-linecap="round"
              class={usage.fraction > 0.8 ? 'stroke-warn-ink' : 'stroke-act'}
            />
          </svg>
          <span class="text-[11px] tabular-nums">{Math.round(usage.fraction * 100)}%</span>
        </span>
      {/if}
    </div>
  {/if}
</div>
