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
  // Above the options, an unresolved item also renders (B11):
  //  - a risk-tier banner (`item.risk_tier`, stamped server-side at B10 —
  //    NEVER re-derived client-side from the target path) when present.
  //  - a diff block (`derivePermissionView`'s `view.diff`) built from the
  //    tool call's `rawInput` — Edit tools diff old_string/new_string,
  //    Write tools preview `content` as an all-add block.
  // A resolved item's server echo is bare `{id, type, resolved, outcome}`
  // (see below), so `rawInput`/`risk_tier` are absent post-resolution and
  // `derivePermissionView` naturally yields no diff/tier — no extra
  // `resolved` branching needed here.
  //
  // SECURITY: `title`, `command`, and everything the diff block renders are
  // agent-supplied (from the tool call the agent is requesting permission
  // for). Plain interpolation only — {@html} is FORBIDDEN here, same as
  // every other agent-content component.
  import { Button } from '$lib/components/ui/button/index.js';
  import DiffBlock from '$lib/components/diff/DiffBlock.svelte';
  import type { AcpItemLike } from './item-shapes';
  import { asStringOr, permissionOptions, isRejectKind } from './item-shapes';
  import { derivePermissionView, tierCopy } from './permission-view';

  let { item, onAnswer }: { item: AcpItemLike; onAnswer: (kind: string) => void } = $props();

  const view = $derived(derivePermissionView(item));
  // `derivePermissionView`'s own fallback only guards `undefined` (its `str`
  // helper doesn't special-case ''); asStringOr's length check preserves the
  // pre-B11 behavior exactly for a (theoretical) blank-string title too.
  const title = $derived(asStringOr(view.title, 'Permission request'));
  const command = $derived(view.command);
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

  {#if view.tier}
    <div class="border-suggest-border/60 border-t px-4 py-2.5">
      <div
        role="alert"
        class="rounded-lg border px-3 py-2 text-[12.5px] {view.tier === 'high'
          ? 'border-warn-border bg-warn-tint text-warn-ink'
          : 'border-suggest-border bg-suggest-tint text-suggest-ink'}"
      >
        {tierCopy(view.tier)}
      </div>
    </div>
  {/if}

  {#if view.diff}
    <div class="border-suggest-border/60 border-t">
      <div class="px-4 pt-2 pb-0.5 font-mono text-[11px] text-ink-meta">{view.diff.path}</div>
      <DiffBlock
        rows={view.diff.rows}
        truncated={view.diff.truncated}
        modeLabel={view.diff.mode === 'write' ? 'New file content' : undefined}
      />
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
