<script lang="ts">
  // Calendar source management (Spec F §UI Setup panel): the configured-
  // source list with per-source status/doctor/sync/remove + typed-confirm
  // purge, the add-source form, and the served-feed block.
  //
  // Add-source runs `CalendarStore.addSource`'s PINNED sequence: setup →
  // set-url (the backend's HTTPS admission gate + `.source` claim) →
  // keychain write ONLY on acceptance — a rejected URL never reaches the
  // keychain. The URL is a credential: component-local `$state`, read at
  // submit, cleared after (success or failure), never logged.
  import { Button } from '$lib/components/ui/button/index.js';
  import { Input } from '$lib/components/ui/input/index.js';
  import { Label } from '$lib/components/ui/label/index.js';
  import { calendarStore, type CalendarSourceStatus } from '$lib/stores/calendar.svelte';
  import { workspaceStore } from '$lib/stores/workspace.svelte';

  let slug = $state('');
  let name = $state('');
  let url = $state('');
  let submitting = $state(false);
  let addError: string | null = $state(null);
  let addWarning: string | null = $state(null);

  let doctorFor: string | null = $state(null);
  let doctorChecks: Record<string, unknown>[] = $state([]);
  let purgeFor: string | null = $state(null);
  let confirmText = $state('');
  let actionError: string | null = $state(null);
  let actionBusy = $state(false);

  const generation = $derived(workspaceStore.generation ?? 0);
  const SLUG_RE = /^[a-z0-9][a-z0-9-]{0,31}$/;

  async function addSource(): Promise<void> {
    addError = null;
    addWarning = null;
    if (!SLUG_RE.test(slug) || slug === 'valea') {
      addError = 'Source id must be lowercase letters/digits/dashes (and not "valea").';
      return;
    }
    if (!name.trim()) {
      addError = 'Name is required.';
      return;
    }

    submitting = true;
    const result = await calendarStore.addSource(slug, name.trim(), url, generation);
    submitting = false;
    url = '';
    if (!result.ok) {
      addError =
        result.error === 'not_https'
          ? 'The feed URL must be https:// — calendar providers only publish secret addresses over HTTPS.'
          : result.error;
      return;
    }
    if (!result.urlStored) {
      addWarning =
        'URL accepted but not saved to the keychain — the source works for this session; after a restart you will be asked for the URL again.';
    }
    slug = '';
    name = '';
  }

  async function runDoctor(source: string): Promise<void> {
    doctorFor = source;
    doctorChecks = [];
    actionError = null;
    const result = await calendarStore.doctor(source, generation);
    if ('error' in result && !Array.isArray(result)) {
      actionError = String(result.error);
      return;
    }
    doctorChecks = result as Record<string, unknown>[];
  }

  async function syncNow(source: string): Promise<void> {
    actionError = (await calendarStore.syncNow(source, generation)) ?? null;
  }

  async function removeSource(source: string): Promise<void> {
    actionBusy = true;
    actionError = (await calendarStore.removeSource(source, generation)) ?? null;
    actionBusy = false;
  }

  async function purge(source: string): Promise<void> {
    actionBusy = true;
    actionError = (await calendarStore.purgeSource(source, confirmText, generation)) ?? null;
    actionBusy = false;
    if (!actionError) {
      purgeFor = null;
      confirmText = '';
    }
  }

  async function enableFeed(): Promise<void> {
    actionError = (await calendarStore.enableFeed(generation)) ?? null;
  }

  async function rotateFeed(): Promise<void> {
    actionError = (await calendarStore.rotateFeed(generation)) ?? null;
  }

  function feedUrl(token: string): string {
    return `${location.origin}/calendar/feed.ics?token=${token}`;
  }

  async function copyFeedUrl(): Promise<void> {
    if (calendarStore.feedToken) await navigator.clipboard.writeText(feedUrl(calendarStore.feedToken));
  }

  function stateLine(source: CalendarSourceStatus): string {
    const pieces = [source.valid ? source.state : 'invalid config'];
    if (source.eventCount > 0) pieces.push(`${source.eventCount} events`);
    if (source.unsupportedSeries > 0) {
      pieces.push(`${source.unsupportedSeries} ${source.unsupportedSeries === 1 ? 'series' : 'series'} unsupported`);
    }
    if (!source.urlPresent && source.valid) pieces.push('URL missing');
    return pieces.join(' · ');
  }
</script>

<section class="flex flex-col gap-5" aria-label="Calendar sources">
  <div>
    <h2 class="font-display text-ink-heading text-[17px] font-medium">Calendar sources</h2>
    <p class="text-ink-secondary mt-1 text-[12.5px] leading-relaxed">
      Subscribed ICS feeds are mirrored read-only into <span class="font-mono">sources/calendar/</span>. The feed URL
      is a credential (Google's "secret address" embeds a private token) — it is stored in the OS keychain, never in
      workspace files.
    </p>
  </div>

  {#if calendarStore.configInvalid}
    <p class="text-warn-ink border-warn-ink/40 rounded-[7px] border px-3 py-2 text-[12px]">
      config/calendar.yaml is invalid: {calendarStore.configInvalid}. Adding a source or enabling the feed rewrites it.
    </p>
  {/if}

  {#if calendarStore.sources.length > 0}
    <ul class="flex flex-col gap-3">
      {#each calendarStore.sources as source (source.source)}
        <li class="border-paper-hairline rounded-[9px] border p-3">
          <div class="flex items-center justify-between gap-2">
            <div>
              <p class="text-ink-heading text-[13px] font-semibold">{source.source}</p>
              <p class="text-ink-subtitle text-[11.5px]">{stateLine(source)}</p>
              {#if source.reason}
                <p class="text-warn-ink text-[11.5px]">{source.reason}</p>
              {/if}
              {#if source.lastError}
                <p class="text-warn-ink text-[11.5px]">{source.lastError}</p>
              {/if}
              {#if calendarStore.urlNotStored.includes(source.source)}
                <p class="text-warn-ink text-[11.5px]">
                  URL not durably stored — re-add it below to retry the keychain write.
                </p>
              {/if}
            </div>
            <div class="flex items-center gap-1.5">
              <Button type="button" variant="outline" size="sm" onclick={() => syncNow(source.source)}>Sync now</Button>
              <Button type="button" variant="outline" size="sm" onclick={() => runDoctor(source.source)}>Doctor</Button>
              <Button
                type="button"
                variant="outline"
                size="sm"
                disabled={actionBusy}
                onclick={() => removeSource(source.source)}
              >
                Remove
              </Button>
              <Button
                type="button"
                variant="outline"
                size="sm"
                onclick={() => {
                  purgeFor = purgeFor === source.source ? null : source.source;
                  confirmText = '';
                }}
              >
                Purge…
              </Button>
            </div>
          </div>

          {#if source.notices.length > 0}
            <ul class="text-ink-meta mt-2 list-disc pl-5 text-[11.5px]">
              {#each source.notices as notice (notice)}
                <li>{notice}</li>
              {/each}
            </ul>
          {/if}

          {#if purgeFor === source.source}
            <div class="mt-2 flex flex-col gap-2">
              <p class="text-ink-meta text-[11.5px]">
                Purge deletes the mirrored files for a REMOVED source. Type
                <span class="font-mono">{source.source}</span> to confirm.
              </p>
              <div class="flex items-center gap-2">
                <Input type="text" bind:value={confirmText} placeholder={source.source} aria-label="Purge confirmation" />
                <Button
                  type="button"
                  variant="outline"
                  size="sm"
                  disabled={confirmText !== source.source || actionBusy}
                  onclick={() => purge(source.source)}
                >
                  Purge files
                </Button>
              </div>
            </div>
          {/if}

          {#if doctorFor === source.source && doctorChecks.length > 0}
            <!-- Wire shape per `Valea.Calendar.Doctor`: {id, label, detail,
                 remedy, status: "ok" | "failed" | "unknown"} — "unknown" =
                 gated behind an earlier failure, rendered muted, not failed. -->
            <ul class="border-paper-hairline mt-2 flex flex-col gap-1 border-t pt-2">
              {#each doctorChecks as check (String(check.id))}
                <li class="text-[11.5px]">
                  <span
                    class={check.status === 'ok'
                      ? 'text-act'
                      : check.status === 'failed'
                        ? 'text-warn-ink'
                        : 'text-ink-meta'}
                  >
                    {check.status === 'ok' ? '✓' : check.status === 'failed' ? '✕' : '○'}
                  </span>
                  <span class="text-ink-body">{String(check.label ?? check.id ?? '')}</span>
                  {#if check.detail}
                    <span class="text-ink-meta"> — {String(check.detail)}</span>
                  {/if}
                  {#if check.status === 'failed' && check.remedy}
                    <p class="text-ink-meta mt-0.5 pl-4 font-mono text-[10.5px]">{String(check.remedy)}</p>
                  {/if}
                </li>
              {/each}
            </ul>
          {/if}
        </li>
      {/each}
    </ul>
  {/if}

  <form
    class="border-paper-hairline flex flex-col gap-2.5 rounded-[9px] border p-3"
    onsubmit={(e) => {
      e.preventDefault();
      void addSource();
    }}
  >
    <p class="text-ink-heading text-[13px] font-semibold">Add a source</p>
    <div class="flex items-center gap-2">
      <div class="flex flex-1 flex-col gap-1">
        <Label for="cal-src-slug">Id</Label>
        <Input id="cal-src-slug" type="text" bind:value={slug} placeholder="work" autocomplete="off" />
      </div>
      <div class="flex flex-1 flex-col gap-1">
        <Label for="cal-src-name">Name</Label>
        <Input id="cal-src-name" type="text" bind:value={name} placeholder="Work (Google)" autocomplete="off" />
      </div>
    </div>
    <div class="flex flex-col gap-1">
      <Label for="cal-src-url">Feed URL (https://…, kept in the OS keychain)</Label>
      <Input id="cal-src-url" type="password" bind:value={url} placeholder="https://calendar.google.com/…/basic.ics" autocomplete="off" />
    </div>
    {#if addError}
      <p class="text-warn-ink text-[11.5px]">{addError}</p>
    {/if}
    {#if addWarning}
      <p class="text-warn-ink text-[11.5px]">{addWarning}</p>
    {/if}
    <div>
      <Button type="submit" size="sm" disabled={submitting}>Add source</Button>
    </div>
  </form>

  <div class="border-paper-hairline flex flex-col gap-2 rounded-[9px] border p-3">
    <p class="text-ink-heading text-[13px] font-semibold">Served feed (Valea calendar)</p>
    <p class="text-ink-secondary text-[12px] leading-relaxed">
      Valea serves your local calendar back out as an ICS feed. Calendar apps ON THIS MACHINE can subscribe
      (Calendar.app "On My Mac", Thunderbird, Outlook local); server-side fetchers — iCloud, Google, Outlook.com —
      cannot reach a loopback address, so the feed does not propagate to phones in this phase.
    </p>
    {#if calendarStore.feedToken}
      <div class="flex items-center gap-2">
        <Input type="text" readonly value={feedUrl(calendarStore.feedToken)} aria-label="Feed URL" />
        <Button type="button" variant="outline" size="sm" onclick={copyFeedUrl}>Copy</Button>
      </div>
      <p class="text-ink-meta text-[11.5px]">Shown once — the token is stored only as a hash.</p>
    {/if}
    <div class="flex items-center gap-2">
      {#if !calendarStore.feedEnabled}
        <Button type="button" size="sm" onclick={enableFeed}>Enable feed</Button>
      {:else}
        <Button type="button" variant="outline" size="sm" onclick={rotateFeed}>Rotate token</Button>
      {/if}
    </div>
  </div>

  {#if actionError}
    <p class="text-warn-ink text-[11.5px]">{actionError}</p>
  {/if}
</section>
