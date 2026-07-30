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
  class="flex flex-wrap items-center gap-2"
  onsubmit={(event) => {
    event.preventDefault();
    submit();
  }}
>
  <label class="sr-only" for="task-quick-add-title">New task</label>
  <Input
    id="task-quick-add-title"
    type="text"
    bind:value={title}
    placeholder="Add a task…"
    disabled={busy}
    class="min-w-[220px] flex-1"
  />

  {#if icms.length > 1}
    <label class="sr-only" for="task-quick-add-icm">Project</label>
    <NativeSelect id="task-quick-add-icm" bind:value={mountKey} disabled={busy} class="w-auto">
      {#each icms as icm (icm.mountKey)}
        <option value={icm.mountKey}>{icm.icmName || icm.mountKey}</option>
      {/each}
    </NativeSelect>
  {/if}

  <Button type="submit" size="sm" disabled={!canAdd}>Add</Button>
</form>

{#if error}
  <p class="text-warn-ink mt-1 text-[12.5px]" role="alert">{error}</p>
{/if}
