<script lang="ts">
  // The Tasks route (tasks+schedules spec §UI surfaces): ONE route, two tabs —
  // Tasks and Schedules — over the per-ICM `tasks.json` / `schedules.json`
  // ledgers. `?tab=schedules` is deep-linkable, so a cockpit notice can send the
  // user straight at the failing schedule.
  //
  // Refresh wiring mirrors the Today page's: both ledgers are plain files in
  // user-owned ICM roots that agents and hands edit directly, so the shared
  // `icm_changed` push (one `workspace:events` join, subscriber sets — never a
  // second racing `channel.on`) is how this page learns they moved.
  import { onMount } from 'svelte';
  import { page } from '$app/state';
  import { replaceState } from '$app/navigation';
  import { AppFrame, MainColumn, PageHeader, SegmentedControl } from '$lib/components/shell';
  import { Button } from '$lib/components/ui/button/index.js';
  import { Skeleton } from '$lib/components/ui/skeleton/index.js';
  import { icmStore } from '$lib/stores/icm.svelte';
  import { recentSessionsStore } from '$lib/stores/recent-sessions.svelte';
  import { mostRecentMountKey } from '$lib/today/quick-session';
  import { tasksStore } from '$lib/tasks/store.svelte';
  import TasksTab from '$lib/components/tasks/TasksTab.svelte';
  import SchedulesTab from '$lib/components/tasks/SchedulesTab.svelte';

  type Tab = 'tasks' | 'schedules';

  const tab = $derived<Tab>(page.url.searchParams.get('tab') === 'schedules' ? 'schedules' : 'tasks');

  // Local calendar date — "due today" is a wall-clock question, and the backend
  // asks it in the host zone (`Valea.Cockpit.tasks_line/2`); the browser's own
  // local date is the same answer on the same machine.
  const todayIso = $derived.by(() => {
    const now = new Date();
    const month = String(now.getMonth() + 1).padStart(2, '0');
    const day = String(now.getDate()).padStart(2, '0');
    return `${now.getFullYear()}-${month}-${day}`;
  });

  // Quick-add's default project: the ICM the user last worked in (Today's
  // quick-composer precedent), falling back to the first mounted one.
  const defaultMountKey = $derived(
    mostRecentMountKey(recentSessionsStore.groups, icmStore.groups[0]?.mount ?? null)
  );

  function selectTab(next: string) {
    const url = new URL(page.url);
    if (next === 'schedules') {
      url.searchParams.set('tab', 'schedules');
    } else {
      url.searchParams.delete('tab');
    }
    // `replaceState`, not `goto`: switching tabs is not a navigation worth a
    // history entry, but the URL must stay shareable.
    replaceState(url, page.state);
  }

  onMount(() => {
    // The ICM tree and the sidebar's project stores are refreshed by `AppFrame`
    // and the root layout respectively — this route only owns the ledgers, plus
    // the `icm_changed` subscription that keeps them live. A workspace switch is
    // handled by `handleWorkspaceEvent` (which resets AND refreshes this store),
    // since a live switch never remounts the route.
    void tasksStore.refresh();
    const unsubIcm = icmStore.onIcmChanged(() => void tasksStore.refresh());
    return () => unsubIcm();
  });
</script>

<AppFrame>
  {#snippet main()}
    <MainColumn>
      <div class="flex flex-col gap-5 px-7 pt-6 pb-7">
        <PageHeader
          title="Tasks"
          subtitle="One shared work ledger per project, plus the schedules Valea fires while it runs. Both are plain JSON files in the project folder — yours to edit by hand or hand to an agent."
        >
          <div class="flex items-center gap-3">
            <SegmentedControl
              label="Tasks or schedules"
              value={tab}
              options={[
                { value: 'tasks', label: 'Tasks' },
                { value: 'schedules', label: 'Schedules' }
              ]}
              onChange={selectTab}
            />
          </div>
        </PageHeader>

        {#if !tasksStore.loaded && !tasksStore.failed}
          <div class="flex flex-col gap-3" aria-hidden="true">
            <Skeleton class="h-8 w-full max-w-[380px] rounded-lg" />
            <Skeleton class="h-3 w-28" />
            <Skeleton class="h-16 w-full rounded-xl" />
            <Skeleton class="h-16 w-full rounded-xl" />
          </div>
        {:else if tasksStore.failed}
          <div class="flex flex-col items-start gap-3 py-6">
            <p class="text-ink-body text-[13.5px]">
              Couldn't read the ledgers. The backend may still be starting.
            </p>
            <Button variant="outline" size="sm" onclick={() => void tasksStore.refresh()}>Retry</Button>
          </div>
        {:else if tab === 'schedules'}
          <SchedulesTab />
        {:else}
          <TasksTab {todayIso} {defaultMountKey} />
        {/if}
      </div>
    </MainColumn>
  {/snippet}
</AppFrame>
