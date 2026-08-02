<script lang="ts">
  // Account switcher for the mail list pane — a full-width card button
  // (avatar, the account's address, the inbox count, chevron) opening a
  // popover that lists every account plus "Add account". Shown whenever ANY
  // account exists: with one account it is the mailbox's identity row and
  // the way to a second; the old native <select> appeared only for 2+.
  //
  // Invalid-config accounts are listed but disabled: visible (a broken entry
  // isn't silently hidden) yet not selectable — their maintenance lives in
  // SetupPanel, which "Add account" also opens. Picking an account NAVIGATES
  // (`accountSwitchHref`) rather than writing the store — the mail route
  // reads `?account=`, and that helper's doc explains why the store must not
  // lead. The inbox count renders only for the SELECTED account: folders are
  // fetched per account, so no other row's count is known here.
  import { page } from '$app/state';
  import { goto } from '$app/navigation';
  import Check from '@lucide/svelte/icons/check';
  import ChevronDown from '@lucide/svelte/icons/chevron-down';
  import Plus from '@lucide/svelte/icons/plus';
  import * as Popover from '$lib/components/ui/popover';
  import { mailStore, type MailAccountStatus } from '$lib/stores/mail.svelte';
  import {
    accountDisplayName,
    accountInitial,
    accountMeta,
    accountSwitchHref,
    inboxCount
  } from './mail-shapes';
  import { avatarFillFor } from './avatar-fills';

  let { onAddAccount }: { onAddAccount: () => void } = $props();

  let open = $state(false);

  const selected = $derived(mailStore.selectedStatus);
  const inbox = $derived(inboxCount(mailStore.folders));

  function pick(status: MailAccountStatus): void {
    open = false;
    if (status.account === mailStore.selectedAccount) return;
    void goto(accountSwitchHref(page.url, status.account));
  }
</script>

{#if mailStore.accounts.length > 0}
  <Popover.Root bind:open>
    <Popover.Trigger
      aria-label="Mail account"
      class="border-paper-border bg-paper-card hover:bg-paper-pill data-[state=open]:bg-paper-pill flex w-full items-center gap-2 rounded-lg border px-2.5 py-1.5 transition-colors"
    >
      {#if selected}
        <span
          class="{avatarFillFor(selected.account)} text-primary-foreground flex size-6 shrink-0 items-center justify-center rounded-full text-[11px] font-semibold"
          aria-hidden="true"
        >
          {accountInitial(accountDisplayName(selected))}
        </span>
        <span class="text-ink-heading min-w-0 flex-1 truncate text-left text-[12.5px] font-medium">
          {accountDisplayName(selected)}
        </span>
        {#if inbox !== null}
          <span
            class="bg-paper-pill text-ink-secondary shrink-0 rounded-full px-2 py-0.5 text-[11px] font-semibold tabular-nums"
            title="{inbox} in inbox"
          >
            {inbox}
          </span>
        {/if}
      {:else}
        <span class="text-ink-meta min-w-0 flex-1 truncate text-left text-[12.5px]">Pick an account</span>
      {/if}
      <ChevronDown class="text-ink-meta size-3.5 shrink-0" strokeWidth={1.5} aria-hidden="true" />
    </Popover.Trigger>
    <Popover.Content align="start" class="w-(--bits-popover-anchor-width) min-w-64 p-1">
      <ul class="flex flex-col gap-0.5" aria-label="Mail accounts">
        {#each mailStore.accounts as account (account.account)}
          {@const isActive = account.account === mailStore.selectedAccount}
          <li>
            <button
              type="button"
              disabled={!account.valid}
              aria-current={isActive ? 'true' : undefined}
              class="hover:bg-paper-pill flex w-full items-center gap-2 rounded-md px-2 py-1.5 text-left transition-colors disabled:pointer-events-none disabled:opacity-50"
              onclick={() => pick(account)}
            >
              <span
                class="{avatarFillFor(account.account)} text-primary-foreground flex size-6 shrink-0 items-center justify-center rounded-full text-[11px] font-semibold"
                aria-hidden="true"
              >
                {accountInitial(accountDisplayName(account))}
              </span>
              <span class="flex min-w-0 flex-1 flex-col">
                <span class="text-ink-heading truncate text-[12.5px] font-medium">
                  {accountDisplayName(account)}
                </span>
                <span class="truncate text-[11px]" class:text-warn-ink={!account.valid} class:text-ink-meta={account.valid}>
                  {accountMeta(account, isActive ? inbox : null)}
                </span>
              </span>
              {#if isActive}
                <Check class="text-act size-3.5 shrink-0" strokeWidth={2} aria-hidden="true" />
              {/if}
            </button>
          </li>
        {/each}
      </ul>
      <div class="bg-paper-hairline my-1 h-px" role="separator" aria-orientation="horizontal"></div>
      <button
        type="button"
        class="hover:bg-paper-pill text-ink-secondary hover:text-ink-heading flex w-full items-center gap-2 rounded-md px-2 py-1.5 text-left text-[12.5px] transition-colors"
        onclick={() => {
          open = false;
          onAddAccount();
        }}
      >
        <span class="flex size-6 shrink-0 items-center justify-center" aria-hidden="true">
          <Plus class="size-3.5" strokeWidth={1.5} />
        </span>
        Add account
      </button>
    </Popover.Content>
  </Popover.Root>
{/if}
