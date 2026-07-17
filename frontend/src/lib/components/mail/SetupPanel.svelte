<script lang="ts">
  // Mail account management (mail design spec E §Account setup + doctor /
  // §Credentials): the configured-account list with per-account maintenance
  // (doctor, held-folder discard, re-adopt/purge recovery, remove), plus
  // the add-account form. Rendered from `routes/mail/+page.svelte` in TWO
  // places: the explicit `?setup=1` destination and the main-pane empty
  // state when no account is configured — so this component owns its own
  // heading/copy rather than expecting a wrapper to supply page chrome.
  //
  // Submit flow is `submitMailSetup` (`mail-shapes.ts`) — this component
  // only wires it to the real `api`, `keychain.ts`, and `mailStore`. The
  // password is `secret` below: component-local `$state`, read only at
  // submit time, cleared immediately after (success OR failure) — never
  // assigned into any store, never logged, `autocomplete="off"`.
  //
  // Destructive/recovery actions (purge, re-adopt, held-folder discard)
  // each require the user to TYPE the slug/folder name — the backend
  // re-verifies the confirmation, this UI just collects it
  // (`purge_mail_account_files`'s `require_confirmation`).
  import { Button } from '$lib/components/ui/button/index.js';
  import { Input } from '$lib/components/ui/input/index.js';
  import { Label } from '$lib/components/ui/label/index.js';
  import { api } from '$lib/api/client';
  import { inDesktop, keychainSet } from '$lib/keychain';
  import { mailStore, type MailAccountStatus } from '$lib/stores/mail.svelte';
  import { workspaceStore } from '$lib/stores/workspace.svelte';
  import {
    submitMailSetup,
    mailSetupErrorMessage,
    mailMaintenanceErrorMessage,
    mailStateLabel,
    mailSlugValid
  } from './mail-shapes';
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

  // Which account row has its doctor open, and which maintenance action is
  // collecting a typed confirmation. A structured value, not a joined
  // string key — IMAP folder names may contain any separator character.
  // One open confirmation at a time keeps the list scannable.
  type PendingConfirm = { kind: 'purge' | 'readopt'; account: string } | { kind: 'discard'; account: string; folder: string };
  let doctorFor: string | null = $state(null);
  let confirm: PendingConfirm | null = $state(null);
  let confirmText = $state('');
  let actionBusy = $state(false);
  let actionError: string | null = $state(null);

  const generation = $derived(workspaceStore.generation ?? 0);

  function validate(): string | null {
    if (!mailSlugValid(account.trim())) {
      return 'Account id must be lowercase letters, digits, and dashes (up to 32 characters).';
    }
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
        generation
      },
      {
        api,
        inDesktop,
        refreshWorkspaceId: async () => {
          await mailStore.refreshStatus();
          return mailStore.accounts.find((a) => a.workspaceId)?.workspaceId ?? null;
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

  function beginConfirm(pending: PendingConfirm): void {
    confirm = pending;
    confirmText = '';
    actionError = null;
  }

  function cancelConfirm(): void {
    confirm = null;
    confirmText = '';
    actionError = null;
  }

  async function runAction(call: () => Promise<{ ok: boolean; error?: string }>): Promise<void> {
    actionBusy = true;
    actionError = null;
    const result = await call();
    actionBusy = false;
    if (!result.ok) {
      actionError = mailMaintenanceErrorMessage(result.error ?? '');
      return;
    }
    cancelConfirm();
    void mailStore.refreshStatus();
  }

  async function purge(slug: string): Promise<void> {
    await runAction(() => api.purgeMailAccountFiles(slug, confirmText, generation));
  }

  async function readopt(slug: string): Promise<void> {
    await runAction(() => api.readoptMailAccount(slug, confirmText, generation));
  }

  async function discardHeld(slug: string, folder: string): Promise<void> {
    await runAction(() => api.discardHeldFolder(slug, folder, confirmText, generation));
  }

  async function remove(slug: string): Promise<void> {
    await runAction(() => api.removeMailAccount(slug, generation));
  }

  // Recovery states that swap the row's normal affordances for explanatory
  // copy + their specific CTAs (spec E §safety invariants: both are
  // fail-closed, user-decided states).
  function needsRecovery(status: MailAccountStatus): boolean {
    return status.state === 'identity_mismatch' || status.state === 'mailbox_replaced';
  }
</script>

<div class="flex flex-col items-start gap-3 py-10">
  <p class="text-overline">Mail</p>

  {#if mailStore.accounts.length > 0}
    <h1 class="font-display text-ink-heading text-[21px]">Mail accounts</h1>

    <ul class="flex w-full max-w-xl flex-col gap-3">
      {#each mailStore.accounts as status (status.account)}
        <li class="border-paper-border bg-paper-card rounded-xl border px-4 py-3">
          <div class="flex items-center gap-2.5">
            <span class="text-ink-heading text-[13.5px] font-medium">{status.account}</span>
            <span class="text-ink-meta text-[12px]">{mailStateLabel(status.state)}</span>
            <span class="min-w-2 flex-1" aria-hidden="true"></span>
            {#if status.valid && !needsRecovery(status)}
              <Button
                type="button"
                variant="ghost"
                size="sm"
                onclick={() => (doctorFor = doctorFor === status.account ? null : status.account)}
              >
                {doctorFor === status.account ? 'Hide checks' : 'Check'}
              </Button>
            {/if}
            <Button type="button" variant="ghost" size="sm" disabled={actionBusy} onclick={() => void remove(status.account)}>
              Remove
            </Button>
          </div>

          {#if status.username}
            <p class="text-ink-meta mt-0.5 text-[12px]">{status.username}</p>
          {/if}

          {#if !status.valid}
            <p class="text-warn-ink mt-1.5 text-[12.5px]">
              Invalid configuration{status.reason ? ` — ${status.reason}` : ''}. Fix
              <code class="bg-paper-track rounded px-1 py-0.5 text-[11.5px]">config/mail.yaml</code> by hand, then reopen
              the workspace.
            </p>
          {/if}

          {#each status.notices as notice (notice)}
            <p class="text-suggest-ink mt-1 text-[12px]">{notice}</p>
          {/each}

          {#if status.state === 'identity_mismatch'}
            <p class="text-warn-ink mt-1.5 text-[12.5px]">
              The folder on disk belongs to a different account identity. Purge its local files to start over — your
              mailbox on the server is untouched.
            </p>
            <div class="mt-2">
              <Button
                type="button"
                variant="outline"
                size="sm"
                onclick={() => beginConfirm({ kind: 'purge', account: status.account })}
              >
                Purge local files…
              </Button>
            </div>
          {:else if status.state === 'mailbox_replaced'}
            <p class="text-warn-ink mt-1.5 text-[12.5px]">
              The mailbox on the server looks replaced (all folders reset). Syncing is stopped until you decide:
              re-adopt the server's current state, or purge the local mirror and start over.
            </p>
            <div class="mt-2 flex items-center gap-2">
              <Button
                type="button"
                variant="outline"
                size="sm"
                onclick={() => beginConfirm({ kind: 'readopt', account: status.account })}
              >
                Re-adopt…
              </Button>
              <Button
                type="button"
                variant="ghost"
                size="sm"
                onclick={() => beginConfirm({ kind: 'purge', account: status.account })}
              >
                Purge local files…
              </Button>
            </div>
          {/if}

          {#each status.heldFolders as folder (folder)}
            <div class="mt-1.5 flex flex-wrap items-center gap-2">
              <p class="text-suggest-ink text-[12.5px]">
                Folder <span class="font-mono text-[11.5px]">{folder}</span> disappeared from the server — its local
                copy is held.
              </p>
              <Button
                type="button"
                variant="ghost"
                size="sm"
                onclick={() => beginConfirm({ kind: 'discard', account: status.account, folder })}
              >
                Discard…
              </Button>
            </div>
          {/each}

          {#if confirm && confirm.account === status.account}
            {@const pending = confirm}
            {@const discardFolder = pending.kind === 'discard' ? pending.folder : null}
            <div class="bg-paper-pill mt-2.5 flex flex-col gap-2 rounded-lg px-3 py-2.5">
              <p class="text-ink-body text-[12.5px]">
                {#if pending.kind === 'purge'}
                  Type <strong>{status.account}</strong> to delete this account's local files (the server is not
                  touched).
                {:else if pending.kind === 'readopt'}
                  Type <strong>{status.account}</strong> to re-adopt the server's current mailbox state.
                {:else}
                  Type <strong>{discardFolder}</strong> to discard the held local copy of this folder.
                {/if}
              </p>
              <div class="flex items-center gap-2">
                <Input class="max-w-[220px]" bind:value={confirmText} disabled={actionBusy} autocomplete="off" />
                <Button
                  type="button"
                  size="sm"
                  disabled={actionBusy}
                  onclick={() => {
                    if (pending.kind === 'purge') void purge(status.account);
                    else if (pending.kind === 'readopt') void readopt(status.account);
                    else if (discardFolder) void discardHeld(status.account, discardFolder);
                  }}
                >
                  Confirm
                </Button>
                <Button type="button" variant="ghost" size="sm" disabled={actionBusy} onclick={() => cancelConfirm()}>
                  Cancel
                </Button>
              </div>
              {#if actionError}
                <p class="text-warn-ink text-[12px]" role="alert">{actionError}</p>
              {/if}
            </div>
          {/if}

          {#if doctorFor === status.account}
            <div class="mt-2">
              <MailDoctorPanel account={status.account} {generation} />
            </div>
          {/if}
        </li>
      {/each}
    </ul>

    <h2 class="font-display text-ink-heading mt-6 text-[17px]">Add another account</h2>
  {:else}
    <h1 class="font-display text-ink-heading text-[21px]">Connect your mailbox</h1>
  {/if}

  {#if submitted}
    <div class="flex flex-col gap-3">
      <p class="text-ink-body text-[13.5px]">Mailbox connected.</p>
      {#if devModeNote}
        <p class="text-suggest-ink text-[12.5px]">
          Dev mode — the password is held in memory only and not persisted.
        </p>
      {/if}
      <Button type="button" variant="outline" size="sm" onclick={() => ((submitted = false), (account = ''))}>
        Add another
      </Button>
    </div>
  {:else}
    <p class="text-ink-body max-w-[480px] text-[13.5px]">
      Valea mirrors your mailbox over IMAP with TLS. Your password is handed off once and never written into the
      workspace.
    </p>

    <div class="flex w-full max-w-md flex-col gap-4">
      <div class="flex flex-col gap-1.5">
        <Label for="mail-setup-account">Account id</Label>
        <Input id="mail-setup-account" bind:value={account} disabled={submitting} placeholder="work" />
        <p class="text-ink-meta text-[11.5px]">Lowercase letters, digits, and dashes — names the folder under sources/mail/</p>
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
  {/if}
</div>
