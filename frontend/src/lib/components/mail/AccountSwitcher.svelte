<script lang="ts">
  // Account selector for the mail list pane (mail design spec E §UI) — a
  // plain native <select> over `mailStore.accounts`, same understated
  // chrome as the shell's other pane controls. Invalid-config accounts are
  // listed but disabled: they're visible (so a broken entry isn't silently
  // hidden) yet not selectable — their maintenance lives in SetupPanel.
  // Hidden entirely when only one account exists; the switcher earns its
  // pixels only in the actual multi-account case.
  import { mailStore } from '$lib/stores/mail.svelte';
  import { accountLabel } from './mail-shapes';
</script>

{#if mailStore.accounts.length > 1}
  <select
    class="border-paper-border bg-paper-card text-ink-secondary w-full rounded-md border px-2 py-1 text-[12.5px]"
    value={mailStore.selectedAccount ?? ''}
    aria-label="Mail account"
    onchange={(event) => void mailStore.selectAccount(event.currentTarget.value)}
  >
    {#each mailStore.accounts as account (account.account)}
      <option value={account.account} disabled={!account.valid}>{accountLabel(account)}</option>
    {/each}
  </select>
{/if}
