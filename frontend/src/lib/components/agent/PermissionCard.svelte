<script lang="ts">
  // Consequence card for a `permission` item (docs/DESIGN_SYSTEM.md §6: amber
  // suggestion ground). Two buttons, keyed off item.options[].kind:
  //   allow_once  -> secondary-outline "Allow once"
  //   reject_once -> terracotta-outline "Don't allow" (NEVER green/filled —
  //     rejecting is never styled as the safe default).
  // A resolved item (`resolved: true`) only carries `{id, type, resolved,
  // outcome}` — the server's resolution echo replaces the item wholesale,
  // dropping title/command/options (see Connection.answer_permission/3) — so
  // the receipt line below is driven by `outcome` alone, not by re-deriving
  // from options that are no longer there.
  //
  // SECURITY: `title` and `command` are agent-supplied (from the tool call
  // the agent is requesting permission for). Plain interpolation only —
  // {@html} is FORBIDDEN here, same as every other agent-content component.
  import { Button } from '$lib/components/ui/button/index.js';
  import type { AcpItemLike } from './item-shapes';
  import { asStringOr, asPresentString, permissionOptions, isRejectKind } from './item-shapes';

  let { item, onAnswer }: { item: AcpItemLike; onAnswer: (kind: string) => void } = $props();

  const title = $derived(asStringOr(item.title, 'Permission request'));
  const command = $derived(asPresentString(item.command));
  const resolved = $derived(item.resolved === true);
  const outcome = $derived(asStringOr(item.outcome, ''));
  const options = $derived(permissionOptions(item));

  const receipt = $derived(
    outcome === 'allow_once' || outcome.startsWith('allow')
      ? 'Allowed once'
      : outcome === 'reject_once' || outcome.startsWith('reject')
        ? 'Not allowed'
        : 'Resolved'
  );

  function labelFor(kind: string, name: string): string {
    if (kind === 'allow_once') return 'Allow once';
    if (kind === 'reject_once') return "Don't allow";
    return name;
  }
</script>

<div class="bg-suggest-bg border-suggest-border w-full max-w-[82%] self-start overflow-hidden rounded-xl border">
  <div class="flex items-center gap-2 px-4 py-2.5">
    <span class="min-w-0 flex-1 truncate text-[13.5px] font-medium text-ink-heading">{title}</span>
  </div>

  {#if command}
    <div class="border-suggest-border/60 border-t px-4 py-1.5 font-mono text-[11.5px] text-ink-secondary">
      {command}
    </div>
  {/if}

  <div class="border-suggest-border/60 flex flex-wrap items-center gap-2 border-t px-4 py-2.5">
    {#if resolved}
      <span class="text-[12.5px] text-ink-meta opacity-75">{receipt}</span>
    {:else}
      {#each options as option (option.optionId)}
        <Button
          type="button"
          variant="outline"
          size="sm"
          class={isRejectKind(option.kind) ? 'border-warn-border text-warn-ink hover:bg-warn-tint hover:text-warn-ink' : ''}
          onclick={() => onAnswer(option.kind)}
        >
          {labelFor(option.kind, option.name)}
        </Button>
      {/each}
    {/if}
  </div>
</div>
