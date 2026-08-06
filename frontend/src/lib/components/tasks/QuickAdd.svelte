<script lang="ts">
  // Quick-add composer for the Tasks tab (spec §UI surfaces: "title + ICM
  // picker, MRU default"). The MRU default comes from the caller — Today's
  // quick-composer precedent, `lib/today/quick-session.ts`'s
  // `mostRecentMountKey` — so this component stays a dumb form and the "which
  // ICM did I last work in" question keeps exactly one owner.
  //
  // Title only: everything else (due, priority, assignee) is one row-click away
  // in the editor, and a composer that asked for six fields would stop being
  // quick. `assignee` defaults to `"user"` backend-side.
  //
  // Shape (redesign spec §List rows): it is the list's FIRST ROW, not a card
  // above it — `+` in the checkbox column, a borderless input on the title's
  // line, the project picker where the row's chips sit, and the same hairline
  // under it that separates every other row. Typing in a list adds to the list;
  // a bordered composer floating above one is a different, heavier promise.
  // The input drops its border but KEEPS the system focus ring — with no border
  // of its own, the ring is the only thing left that can say "you are here".
  //
  // The `Add` button appears only once there is something to add: Enter submits,
  // and a permanent button on the resting row would be the loudest thing on a
  // page whose whole point is the rows beneath it.
  import { Button } from '$lib/components/ui/button/index.js';
  import { Input } from '$lib/components/ui/input/index.js';
  import { NativeSelect } from '$lib/components/ui/native-select/index.js';

  let {
    icms,
    mountKey = $bindable(),
    busy = false,
    error = null,
    onAdd
  }: {
    icms: { mountKey: string; icmName: string }[];
    /** Bound so the caller keeps the picker's state (it survives a re-list). */
    mountKey: string;
    busy?: boolean;
    error?: string | null;
    onAdd: (mountKey: string, title: string) => void;
  } = $props();

  let title = $state('');

  const canAdd = $derived(title.trim() !== '' && mountKey !== '' && !busy);

  function submit() {
    if (!canAdd) return;
    onAdd(mountKey, title.trim());
    title = '';
  }
</script>

<form
  class="border-paper-hairline flex flex-wrap items-center gap-1 border-b pb-2"
  onsubmit={(event) => {
    event.preventDefault();
    submit();
  }}
>
  <!-- The checkbox column, so the input starts exactly where every row's title
       does (32px — the same box `TaskRow`'s checkbox button occupies). -->
  <span class="text-ink-meta flex size-8 shrink-0 items-center justify-center text-[15px]" aria-hidden="true">+</span>

  <label class="sr-only" for="task-quick-add-title">New task</label>
  <Input
    id="task-quick-add-title"
    type="text"
    bind:value={title}
    placeholder="Add a task…"
    disabled={busy}
    class="min-w-[180px] flex-1 border-0 px-0"
  />

  {#if icms.length > 1}
    <label class="sr-only" for="task-quick-add-icm">Project</label>
    <NativeSelect id="task-quick-add-icm" bind:value={mountKey} disabled={busy} class="w-auto">
      {#each icms as icm (icm.mountKey)}
        <option value={icm.mountKey}>{icm.icmName || icm.mountKey}</option>
      {/each}
    </NativeSelect>
  {/if}

  {#if title.trim() !== ''}
    <Button type="submit" size="sm" disabled={!canAdd}>Add</Button>
  {/if}
</form>

{#if error}
  <p class="text-warn-ink mt-1 text-[12.5px]" role="alert">{error}</p>
{/if}
