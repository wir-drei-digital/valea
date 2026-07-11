<script lang="ts">
  // ListPane footer: engine state + last-synced-at relative time, error (if
  // any) in warn-ink, and a "Sync now" button wired to `store.syncNow`. The
  // engine's own `state`/`lastError` (pushed live via `mail_status`, wired
  // once at the layout — see `wireMailEvents`) and a local request error
  // (the `syncNow` RPC call itself failing, e.g. `workspace_not_open`) are
  // both surfaced through the same warn-ink line — `syncErrorText` prefers
  // the local one since it's the freshest signal the user just triggered.
  //
  // `onSettings` (Task 17) is an optional second small button next to "Sync
  // now" — routes to `/mail?setup=1` (the route owns navigation; this
  // component just renders whatever the caller passes). Omitted entirely
  // when no handler is given, so nothing else using this component changes.
  import { Button } from '$lib/components/ui/button/index.js';
  import type { MailStatus } from '$lib/stores/mail.svelte';
  import { mailStateLabel, relativeTime, syncErrorText, syncNowErrorMessage } from './mail-shapes';

  let {
    status,
    onSyncNow,
    onSettings
  }: {
    status: MailStatus | null;
    /** Returns the error code on failure, `null` on success — same shape as `MailStore.syncNow`. */
    onSyncNow: () => Promise<string | null>;
    onSettings?: () => void;
  } = $props();

  let requesting = $state(false);
  let requestError: string | null = $state(null);

  const stateLabel = $derived(mailStateLabel(status?.state));
  const syncedLabel = $derived(relativeTime(status?.lastSyncAt));
  const error = $derived(syncErrorText(status, requestError));
  const busy = $derived(requesting || status?.state === 'syncing');

  async function handleSyncNow(): Promise<void> {
    requesting = true;
    requestError = null;
    const code = await onSyncNow();
    requesting = false;
    if (code) requestError = syncNowErrorMessage(code);
  }
</script>

<div class="flex flex-col gap-1.5">
  <div class="flex items-center justify-between gap-2">
    <p class="text-ink-secondary min-w-0 flex-1 truncate text-[12px]">
      {stateLabel}{#if syncedLabel} · synced {syncedLabel}{/if}
    </p>
    {#if onSettings}
      <Button type="button" variant="ghost" size="sm" onclick={() => onSettings?.()}>Mail settings</Button>
    {/if}
    <Button
      type="button"
      variant="outline"
      size="sm"
      disabled={busy}
      onclick={() => void handleSyncNow()}
    >
      Sync now
    </Button>
  </div>
  {#if error}
    <p class="text-warn-ink text-[11.5px]" role="alert">{error}</p>
  {/if}
</div>
