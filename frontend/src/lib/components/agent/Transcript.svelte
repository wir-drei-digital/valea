<script lang="ts">
  /**
   * Renders one agent session's timeline (`store.items`) in the Paper & ink
   * chat vocabulary (docs/DESIGN_SYSTEM.md §9). Dispatches by `item.type`:
   *  - message (role user)      -> right-aligned green bubble
   *  - message (role assistant) -> mirrored card bubble
   *  - thought                  -> collapsed "Thinking" strip
   *  - tool                     -> ToolCallCard
   *  - permission                -> PermissionCard, wired to
   *    `store.answerPermission(item.id, kind)` directly (this component
   *    holds the store, not just its items, precisely so this wiring can
   *    live here rather than forcing every call site to thread an
   *    onAnswerPermission callback through)
   *  - turn                     -> a hairline + the stop reason, but ONLY
   *    when it's not the boring "end_turn" case
   *  - plan/config/usage/commands/meta/session_info -> NOT rendered here.
   *    They're dock singletons: T18 renders PlanBar/UsageLine/Composer
   *    alongside this component, deriving each one's item from the same
   *    `store.items`.
   *
   * SECURITY: every field below that carries agent- or user-authored text
   * (item.text, and everything MessageItem/ThoughtItem/ToolCallCard/
   * PermissionCard render) reaches the DOM through plain Svelte
   * interpolation ({value}), which auto-escapes. `{@html}` is FORBIDDEN in
   * this component and every component it renders — do not introduce it
   * here, and do not add a markdown renderer for agent output.
   */
  import type { AgentSessionStore } from '$lib/stores/agent-session.svelte';
  import MessageItem from './MessageItem.svelte';
  import ThoughtItem from './ThoughtItem.svelte';
  import ToolCallCard from './ToolCallCard.svelte';
  import PermissionCard from './PermissionCard.svelte';
  import { asString } from './item-shapes';

  let { store }: { store: AgentSessionStore } = $props();
</script>

<div class="flex flex-col gap-3.5 px-4 py-4">
  {#each store.items as item (item.id)}
    {#if item.type === 'message' && item.role === 'user'}
      <MessageItem role="user" text={asString(item.text)} />
    {:else if item.type === 'message'}
      <MessageItem role="assistant" text={asString(item.text)} />
    {:else if item.type === 'thought'}
      <ThoughtItem text={asString(item.text)} />
    {:else if item.type === 'tool'}
      <ToolCallCard {item} />
    {:else if item.type === 'permission'}
      <PermissionCard {item} onAnswer={(kind) => store.answerPermission(item.id, kind)} />
    {:else if item.type === 'turn' && asString(item.stop_reason) && asString(item.stop_reason) !== 'end_turn'}
      <div class="flex items-center gap-2 py-1" role="status">
        <span class="bg-paper-hairline h-px flex-1" aria-hidden="true"></span>
        <span class="text-ink-meta text-[11px]">{asString(item.stop_reason)}</span>
        <span class="bg-paper-hairline h-px flex-1" aria-hidden="true"></span>
      </div>
    {/if}
  {/each}
</div>
