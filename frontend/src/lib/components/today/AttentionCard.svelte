<script lang="ts">
  // "Needs attention" (redesign spec §Today → Needs attention): the ONE
  // interrupt on the page, and one of only three boxed surfaces §11 allows
  // here. It gathers the two things that are genuinely stuck waiting on the
  // user — a git repo an agent can untangle, and a schedule run that parked or
  // failed — out of the two standalone sections they used to have.
  //
  // What is NOT here, deliberately: `registered` schedule notices (an FYI, not
  // an interrupt — they live on the rail) and git `error` rows (fetch/push/auth
  // failures, which are doctor material; `gitStore.attentionRepos` already
  // withholds them).
  //
  // The card renders NOTHING when it has no rows: an empty tinted box is a
  // standing alarm about nothing.
  import { Button } from '$lib/components/ui/button/index.js';
  import { gitAttentionText, type GitRepoStatus } from '$lib/stores/git.svelte';
  import { scheduleNoticeHref, scheduleNoticeText, type ScheduleNotice } from '$lib/today/cockpit';
  import { formatTimestamp } from '$lib/today/today-view';

  let {
    gitRows,
    notices,
    resolving,
    resolveError,
    onResolve
  }: {
    /** `gitStore.attentionRepos` — the three agent-actionable states, nothing else. */
    gitRows: GitRepoStatus[];
    /** `waiting` and `failed` notices only; the caller does the filtering (it also counts them for the header). */
    notices: ScheduleNotice[];
    /** The mount whose hand-off is in flight — every Resolve button is disabled while one runs. */
    resolving: string | null;
    resolveError: Record<string, string>;
    onResolve: (repo: GitRepoStatus) => void;
  } = $props();
</script>

{#if gitRows.length + notices.length > 0}
  <section class="bg-warn-tint border-warn-border rounded-xl border p-4">
    <h2 class="text-overline text-warn-ink mb-1.5">Needs attention</h2>
    <ul class="flex flex-col">
      {#each gitRows as repo (repo.mountKey)}
        <!-- Git attention rows (ICM git sync spec §Conflict notices). Each
             row's button hands the repo to an agent in one click; once a
             resolution session exists it re-reads "Open session", so a second
             resolver never gets started by accident. -->
        <li class="py-1.5 pr-2">
          <div class="flex items-center gap-2">
            <span class="bg-warn-ink size-1.5 shrink-0 rounded-full" aria-hidden="true"></span>
            <span class="text-ink-body min-w-0 flex-1 text-[13px]">{gitAttentionText(repo)}</span>
            <Button
              variant="outline"
              size="sm"
              disabled={resolving !== null}
              onclick={() => onResolve(repo)}
            >
              {repo.conflictSessionId ? 'Open session' : 'Resolve with agent'}
            </Button>
          </div>
          {#if resolveError[repo.mountKey]}
            <p class="text-warn-ink mt-1 ml-3.5 text-[12px]" role="alert">
              {resolveError[repo.mountKey]}
            </p>
          {/if}
        </li>
      {/each}

      {#each notices as notice, i (`${notice.mountKey ?? ''}/${notice.scheduleId}/${notice.kind}/${i}`)}
        <!-- Every notice points at the Schedules tab, which is where the run
             history, the failure's captured output and the transcript link all
             already live (`scheduleNoticeHref`'s own note). Hover uses the
             card's border tone rather than the page's pill — inside a tinted
             surface, `paper-pill` reads as a hole. -->
        <li>
          <a
            href={scheduleNoticeHref(notice)}
            class="hover:bg-warn-border flex items-baseline gap-2 rounded-md py-1.5 pr-2 transition-colors"
          >
            <span
              class={[
                'size-1.5 shrink-0 self-center rounded-full',
                notice.kind === 'failed' ? 'bg-warn-ink' : 'bg-act'
              ]}
              aria-hidden="true"
            ></span>
            <span class="text-ink-body min-w-0 flex-1 text-[13px]">{scheduleNoticeText(notice)}</span>
            {#if notice.at}
              <span class="text-ink-meta shrink-0 text-[11.5px] tabular-nums">
                {formatTimestamp(notice.at)}
              </span>
            {/if}
          </a>
        </li>
      {/each}
    </ul>
  </section>
{/if}
