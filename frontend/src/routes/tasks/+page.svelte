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
  import { goto } from '$app/navigation';
  import { AppFrame, MainColumn, PageHeader, SegmentedControl } from '$lib/components/shell';
  import { Button } from '$lib/components/ui/button/index.js';
  import { Skeleton } from '$lib/components/ui/skeleton/index.js';
  import { icmStore } from '$lib/stores/icm.svelte';
  import { recentSessionsStore } from '$lib/stores/recent-sessions.svelte';
  import { mostRecentMountKey } from '$lib/today/quick-session';
  import { localDateIso } from '$lib/tasks/filters';
  import { tasksStore } from '$lib/tasks/store.svelte';
  import TasksTab from '$lib/components/tasks/TasksTab.svelte';
  import SchedulesTab from '$lib/components/tasks/SchedulesTab.svelte';

  type Tab = 'tasks' | 'schedules';

  const tab = $derived<Tab>(page.url.searchParams.get('tab') === 'schedules' ? 'schedules' : 'tasks');

  // Local calendar date — "due today" is a wall-clock question, and the backend
  // asks it in the host zone (`Valea.Cockpit.tasks_line/2`); the browser's own
  // local date is the same answer on the same machine.
  //
  // Held as STATE and re-read on a timer (review round 1, L6): this app stays
  // open for days, and a `$derived` with no dependencies computes once — at
  // 00:01 the Today filter would still be measuring against yesterday, quietly
  // hiding what is now due. The tick is cheap and only ever assigns a string,
  // so the re-render happens on the day boundary and nowhere else.
  let now = $state(new Date());
  const todayIso = $derived(localDateIso(now));

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
    // A REAL navigation, collapsed onto the current history entry: `tab` is
    // derived from `page.url`, and shallow routing (`replaceState` from
    // `$app/navigation`) deliberately does NOT update `page.url` — the first
    // build used it, and clicking the segment changed the address bar while
    // the view stayed put. `goto` with `replaceState` keeps the URL shareable
    // without a history entry per click.
    void goto(url, { replaceState: true, noScroll: true, keepFocus: true });
  }

  onMount(() => {
    // The ICM tree and the sidebar's project stores are refreshed by `AppFrame`
    // and the root layout respectively — this route only owns the ledgers, plus
    // the `icm_changed` subscription that keeps them live. A workspace switch is
    // handled by `handleWorkspaceEvent` (which resets AND refreshes this store),
    // since a live switch never remounts the route.
    void tasksStore.refresh();
    const unsubIcm = icmStore.onIcmChanged(() => void tasksStore.refresh());

    // Midnight watch (L6). A minute's granularity is plenty for a date, and the
    // `visibilitychange` read catches the machine that was asleep at 00:00 and
    // is looked at again at 09:00 — timers do not reliably fire while suspended.
    const tick = setInterval(() => (now = new Date()), 60_000);
    const onVisible = () => {
      if (!document.hidden) now = new Date();
    };
    document.addEventListener('visibilitychange', onVisible);

    return () => {
      unsubIcm();
      clearInterval(tick);
      document.removeEventListener('visibilitychange', onVisible);
    };
  });
</script>

{#snippet loading()}
  <div class="flex flex-col gap-3" aria-hidden="true">
    <Skeleton class="h-8 w-full max-w-[380px] rounded-lg" />
    <Skeleton class="h-3 w-28" />
    <Skeleton class="h-16 w-full rounded-xl" />
    <Skeleton class="h-16 w-full rounded-xl" />
  </div>
{/snippet}

<!-- Calm, and scoped to the ONE list that failed: the other tab is unaffected
     and still renders its rows. -->
{#snippet unreachable(what: string, retry: () => void)}
  <div class="flex flex-col items-start gap-3 py-6">
    <p class="text-ink-body text-[13.5px]">Couldn't read {what}. The backend may still be starting.</p>
    <Button variant="outline" size="sm" onclick={retry}>Retry</Button>
  </div>
{/snippet}

<AppFrame>
  {#snippet main()}
    <MainColumn>
      <div class="flex flex-col gap-5 px-7 pt-6 pb-7">
        <PageHeader
          title="Tasks"
          subtitle="Your work for the day, and what runs on a schedule — you and the assistant share the same list. Everything lives in plain files in your project folders."
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

        <!-- Load state is read PER TAB (review round 1, M2): the two list RPCs
             fail independently, and a tab whose own list never arrived must say
             so. Shared flags let the other list's success flip this tab into its
             "No projects yet" empty state — an unreachable ledger rendered as an
             empty one, which is exactly the lie the leniency contract forbids. -->
        {#if tab === 'schedules'}
          {#if !tasksStore.schedulesLoaded && !tasksStore.schedulesFailed}
            {@render loading()}
          {:else if tasksStore.schedulesFailed}
            {@render unreachable('the schedules', () => void tasksStore.refreshSchedules())}
          {:else}
            <SchedulesTab />
          {/if}
        {:else if !tasksStore.tasksLoaded && !tasksStore.tasksFailed}
          {@render loading()}
        {:else if tasksStore.tasksFailed}
          {@render unreachable('the task ledgers', () => void tasksStore.refreshTasks())}
        {:else}
          <TasksTab {todayIso} {defaultMountKey} />
        {/if}
      </div>
    </MainColumn>
  {/snippet}
</AppFrame>
