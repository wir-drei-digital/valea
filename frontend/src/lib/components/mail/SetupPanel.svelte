<script lang="ts">
  // Account setup for the mail account (mail design spec §Account setup +
  // doctor / §Credentials; Task 17). Self-contained — rendered from
  // `routes/mail/+page.svelte` in TWO places: the explicit `?setup=1`
  // destination (the list footer's "Mail settings" affordance), and the
  // main-pane empty state whenever `mailStore.status.configured` is false —
  // so this component owns its own heading/copy rather than expecting a
  // wrapper to supply page chrome.
  //
  // Submit flow is `submitMailSetup` (`mail-shapes.ts`) — this component
  // only wires it to the real `api`, `keychain.ts`, and `mailStore`; see
  // that function's doc comment for the desktop-vs-browser sequencing and
  // WHY `refreshWorkspaceId` re-fetches status rather than trusting a
  // cached value.
  //
  // The password is `secret` below: component-local `$state`, read only at
  // submit time, cleared immediately after (success OR failure) — never
  // assigned into any store, never logged, `autocomplete="off"`.
  import { Button } from '$lib/components/ui/button/index.js';
  import { Input } from '$lib/components/ui/input/index.js';
  import { Label } from '$lib/components/ui/label/index.js';
  import { api } from '$lib/api/client';
  import { inDesktop, keychainSet } from '$lib/keychain';
  import { mailStore } from '$lib/stores/mail.svelte';
  import { workspaceStore } from '$lib/stores/workspace.svelte';
  import { submitMailSetup, mailSetupErrorMessage, slugifyAccountLabel } from './mail-shapes';
  import MailDoctorPanel from './MailDoctorPanel.svelte';

  let account = $state('');
  let host = $state('');
  let portText = $state('993');
  let username = $state('');
  let secret = $state('');

  let submitting = $state(false);
  let error: string | null = $state(null);
  let submitted = $state(false);
  let devModeNote = $state(false);

  function validate(): string | null {
    if (!account.trim()) return 'Give the account a label.';
    if (!host.trim()) return 'Enter the mail server host.';
    const port = Number(portText);
    if (!Number.isFinite(port) || port <= 0) return 'Enter a valid port.';
    if (!username.trim()) return 'Enter the mailbox username.';
    if (!secret) return 'Enter the mailbox password.';
    return null;
  }

  async function handleSubmit(): Promise<void> {
    error = null;
    const validationError = validate();
    if (validationError) {
      error = validationError;
      return;
    }

    submitting = true;
    const outcome = await submitMailSetup(
      {
        account: account.trim(),
        host: host.trim(),
        port: Number(portText),
        username: username.trim(),
        secret,
        generation: workspaceStore.generation ?? 0
      },
      {
        api,
        inDesktop,
        refreshWorkspaceId: async () => {
          await mailStore.refreshStatus();
          return mailStore.status?.workspaceId ?? null;
        },
        keychainSet
      }
    );
    submitting = false;
    // Cleared immediately after submit either way — never held longer than
    // the RPC call that needed it, never put in a store.
    secret = '';

    if (!outcome.ok) {
      error = mailSetupErrorMessage(outcome.error);
      return;
    }

    devModeNote = outcome.devMode;
    submitted = true;
    void mailStore.refreshStatus();
  }

  // `submitMailSetup` derives the same slug internally (see its doc comment)
  // — recomputed here, off the SAME exported helper, so `MailDoctorPanel`
  // below knows which account to run its checks against without threading
  // an extra return value through `submitMailSetup`'s outcome type.
  const accountSlug = $derived(slugifyAccountLabel(account.trim()));
</script>

{#if submitted}
  <div class="flex flex-col gap-4 py-10">
    <div class="flex flex-col gap-1.5">
      <p class="text-overline">Mail</p>
      <h1 class="font-display text-ink-heading text-[21px]">Mailbox connected</h1>
    </div>
    {#if devModeNote}
      <p class="text-suggest-ink text-[12.5px]">
        Dev mode — the password is held in memory only and not persisted.
      </p>
    {/if}
    <MailDoctorPanel account={accountSlug} generation={workspaceStore.generation ?? 0} />
  </div>
{:else}
  <div class="flex flex-col items-start gap-3 py-10">
    <p class="text-overline">Mail</p>
    <h1 class="font-display text-ink-heading text-[21px]">Connect your mailbox</h1>
    <p class="text-ink-body max-w-[480px] text-[13.5px]">
      Valea reads your inbox over IMAP with TLS. Your password is handed off once and never written into the
      workspace.
    </p>

    <div class="flex w-full max-w-md flex-col gap-4">
      <div class="flex flex-col gap-1.5">
        <Label for="mail-setup-account">Account label</Label>
        <Input id="mail-setup-account" bind:value={account} disabled={submitting} placeholder="Work inbox" />
      </div>

      <div class="flex flex-col gap-1.5">
        <Label for="mail-setup-host">Host</Label>
        <Input id="mail-setup-host" bind:value={host} disabled={submitting} placeholder="imap.example.com" />
      </div>

      <div class="flex flex-col gap-1.5">
        <Label for="mail-setup-port">Port</Label>
        <Input id="mail-setup-port" inputmode="numeric" bind:value={portText} disabled={submitting} />
        <p class="text-ink-meta text-[11.5px]">TLS — always on</p>
      </div>

      <div class="flex flex-col gap-1.5">
        <Label for="mail-setup-username">Username</Label>
        <Input id="mail-setup-username" bind:value={username} disabled={submitting} placeholder="you@example.com" />
      </div>

      <div class="flex flex-col gap-1.5">
        <Label for="mail-setup-password">Password</Label>
        <Input
          id="mail-setup-password"
          type="password"
          autocomplete="off"
          bind:value={secret}
          disabled={submitting}
        />
      </div>

      {#if error}
        <p role="alert" class="text-warn-ink text-[12.5px]">{error}</p>
      {/if}

      <div>
        <Button type="button" onclick={() => void handleSubmit()} disabled={submitting}>
          {submitting ? 'Connecting…' : 'Connect mailbox'}
        </Button>
      </div>
    </div>
  </div>
{/if}
