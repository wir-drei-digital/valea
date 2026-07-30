<script lang="ts">
  // ListPane footer: engine state + last-synced-at relative time, and any
  // sync error underneath in warn-ink. The engine's own `state`/`lastError`
  // (pushed live via `mail_status`, wired once at the layout — see
  // `wireMailEvents`) and the route's local request error (the `syncNow`
  // RPC call itself failing, e.g. `workspace_not_open`) are both surfaced
  // through the same warn-ink line — `syncErrorText` prefers the local one
  // since it's the freshest signal the user just triggered. The "Sync now"
  // button and the mail-settings gear both live in the pane header next to
  // the title (the route owns that state and passes the resulting
  // `requestError` down).
  import type { MailAccountStatus } from '$lib/stores/mail.svelte';
  import { mailStateLabel, relativeTime, syncErrorText } from './mail-shapes';

  let {
    status,
    requestError = null
  }: {
    status: MailAccountStatus | null;
    /** The route's last local `syncNow` failure, already user-worded — `null` when the last request succeeded. */
    requestError?: string | null;
  } = $props();

  const syncedLabel = $derived(relativeTime(status?.lastSyncAt));
  const error = $derived(syncErrorText(status, requestError));
  // An idle engine whose last pass FAILED must not claim "Up to date" —
  // the warn line below carries the detail; the state line stays honest
  // (2026-07-19 browser test run: dead-host account read "Up to date").
  const stateLabel = $derived(
    status?.state === 'idle' && error
      ? 'Last sync failed, will retry'
      : mailStateLabel(status?.state, status)
  );
</script>

<div class="flex flex-col gap-1">
  <p class="text-ink-meta min-w-0 truncate text-[12px]">
    {stateLabel}{#if syncedLabel} · synced {syncedLabel}{/if}
  </p>
  {#if error}
    <p class="text-warn-ink text-[11.5px]" role="alert">{error}</p>
  {/if}
</div>
