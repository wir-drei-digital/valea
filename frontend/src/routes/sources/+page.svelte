<script lang="ts">
  // Sources hub — the one place that answers "what does Valea read from the
  // outside world, and where do I manage it?" Mail accounts (Spec E) and
  // calendar feeds (Spec F) each have their real management surface on
  // their own route; this page links out and shows a one-line live status
  // per connection so the nav item stays honest instead of a stale stub.
  import { onMount } from 'svelte';
  import { AppFrame } from '$lib/components/shell';
  import { Button } from '$lib/components/ui/button/index.js';
  import Inbox from '@lucide/svelte/icons/inbox';
  import CalendarDays from '@lucide/svelte/icons/calendar-days';
  import { goto } from '$app/navigation';
  import { mailStore } from '$lib/stores/mail.svelte';
  import { calendarStore } from '$lib/stores/calendar.svelte';

  onMount(() => {
    void mailStore.refreshStatus();
    void calendarStore.refreshStatus();
  });

  const mailLine = $derived.by((): string => {
    const configured = mailStore.accounts.filter((a) => a.configured);
    if (configured.length === 0) return 'No mailbox connected yet.';
    return configured.map((a) => `${a.account}: ${a.state}`).join(' · ');
  });

  const calendarLine = $derived.by((): string => {
    const feeds = calendarStore.sources;
    const valea = `Valea calendar: ${calendarStore.valeaEventCount} ${calendarStore.valeaEventCount === 1 ? 'event' : 'events'}`;
    if (feeds.length === 0) return `No feeds subscribed yet · ${valea}`;
    return feeds.map((s) => `${s.source}: ${s.valid ? s.state : 'invalid config'}`).join(' · ') + ` · ${valea}`;
  });
</script>

<AppFrame>
  {#snippet main()}
    <div class="flex flex-col gap-5 px-7 pt-6 pb-7">
      <header>
        <h1 class="font-display text-ink-heading text-[22px] leading-tight font-medium">Sources</h1>
        <p class="text-ink-secondary mt-1 text-[13px] leading-relaxed">
          What Valea reads from the outside world. Everything lands as plain files under
          <span class="font-mono text-[12px]">sources/</span> in your workspace folder.
        </p>
      </header>

      <section class="border-paper-hairline flex items-start justify-between gap-4 rounded-[9px] border p-4">
        <div class="flex items-start gap-3">
          <Inbox class="text-ink-secondary mt-0.5 size-4.5" strokeWidth={1.5} aria-hidden="true" />
          <div>
            <p class="text-ink-heading text-[13.5px] font-semibold">Mail</p>
            <p class="text-ink-secondary mt-0.5 text-[12.5px] leading-relaxed">
              IMAP mailboxes mirrored read-safe into <span class="font-mono text-[12px]">sources/mail/</span>.
            </p>
            <p class="text-ink-meta mt-1 text-[12px]">{mailLine}</p>
          </div>
        </div>
        <Button type="button" variant="outline" size="sm" onclick={() => void goto('/mail?setup=1')}>
          Manage accounts
        </Button>
      </section>

      <section class="border-paper-hairline flex items-start justify-between gap-4 rounded-[9px] border p-4">
        <div class="flex items-start gap-3">
          <CalendarDays class="text-ink-secondary mt-0.5 size-4.5" strokeWidth={1.5} aria-hidden="true" />
          <div>
            <p class="text-ink-heading text-[13.5px] font-semibold">Calendar</p>
            <p class="text-ink-secondary mt-0.5 text-[12.5px] leading-relaxed">
              ICS feeds mirrored read-only into <span class="font-mono text-[12px]">sources/calendar/</span>, plus
              the agent-writable Valea calendar and its served feed.
            </p>
            <p class="text-ink-meta mt-1 text-[12px]">{calendarLine}</p>
          </div>
        </div>
        <Button type="button" variant="outline" size="sm" onclick={() => void goto('/calendar?setup=1')}>
          Manage feeds
        </Button>
      </section>
    </div>
  {/snippet}
</AppFrame>
