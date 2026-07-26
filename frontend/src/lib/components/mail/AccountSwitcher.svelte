<script lang="ts">
  // Account selector for the mail list pane (mail design spec E §UI) — a
  // plain native <select> over `mailStore.accounts`, same understated
  // chrome as the shell's other pane controls. Invalid-config accounts are
  // listed but disabled: they're visible (so a broken entry isn't silently
  // hidden) yet not selectable — their maintenance lives in SetupPanel.
  // Hidden entirely when only one account exists; the switcher earns its
  // pixels only in the actual multi-account case.
  import { page } from '$app/state';
  import { goto } from '$app/navigation';
  import { mailStore } from '$lib/stores/mail.svelte';
  import { accountLabel } from './mail-shapes';

  // Switching accounts also drops any open message: `?message=` names a msg
  // id in the account it was opened from, so carrying it across a switch
  // would either fail to load or (worse) resolve to an unrelated message
  // that happens to share the id in the new account.
  function switchTo(slug: string): void {
    void mailStore.selectAccount(slug);
    if (page.url.searchParams.has('message')) void goto('/mail');
  }
</script>

{#if mailStore.accounts.length > 1}
  <select
    class="border-paper-border bg-paper-card text-ink-secondary w-full rounded-md border px-2 py-1 text-[12.5px]"
    value={mailStore.selectedAccount ?? ''}
    aria-label="Mail account"
    onchange={(event) => switchTo(event.currentTarget.value)}
  >
    {#each mailStore.accounts as account (account.account)}
      <option value={account.account} disabled={!account.valid}>{accountLabel(account)}</option>
    {/each}
  </select>
{/if}
