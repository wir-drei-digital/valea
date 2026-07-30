<script lang="ts">
  // Mail account management (mail design spec E §Account setup + doctor /
  // §Credentials): the configured-account list with per-account maintenance
  // (edit, doctor, held-folder discard, re-adopt/purge recovery, remove),
  // per-project session access toggles (the CONTEXT.md `mail-<slug>`
  // opt-in grammar, edited in place — see `Valea.Mounts.Context`),
  // plus the add-account form. Rendered from `routes/mail/+page.svelte`
  // inside the settings DIALOG (the calendar route's Sources pattern;
  // `?setup=1` deep-links it open) — this component owns its own
  // heading/copy, rendered through `Dialog.Header`/`Dialog.Title` so the
  // title sits on the close button's row like every other modal (which is
  // also why this component is only ever mounted inside that dialog).
  //
  // The connection form has three modes, and each non-closed mode REPLACES
  // the modal's content as its own view (a Cancel next to the submit returns
  // to the account list) rather than stacking the form under the list:
  //  - CLOSED (the default once any account exists) — just the list and an
  //    "Add account" button; the form only appears on demand.
  //  - ADD — the empty form. The username field drives best-effort
  //    autodiscovery (`mail_autoconfig`): on blur of an email-looking
  //    username with the host still blank, the backend probes
  //    ISPDB/DNS and prefills host/port (and the SMTP block when that
  //    checkbox is on) — every guessed field stays editable.
  //  - EDIT — the same form prefilled from `get_mail_account_settings`
  //    (non-secret config only), slug fixed. Blank password fields mean
  //    "keep the stored credential" (`submitMailSetup` skips those slots).
  //
  // Submit flow is `submitMailSetup` (`mail-shapes.ts`) — this component
  // only wires it to the real `api`, `keychain.ts`, and `mailStore`. The
  // password is `secret` below: component-local `$state`, read only at
  // submit time, cleared immediately after (success OR failure) — never
  // assigned into any store, never logged, `autocomplete="off"`.
  //
  // Two ROUTES cut across those modes (M6 task 16, `useOauth` below): a
  // mailbox whose host has an OAuth2 preset (Gmail, Microsoft 365) collects no
  // password at all — the submit saves the account with `auth: oauth2` and then
  // opens the provider's consent page, and the refresh token lands entirely
  // backend-side via `/oauth/callback`. Everything else keeps the password
  // fields. The routing is by DETECTED HOST in add mode and by the STORED mode
  // in edit mode, with an explicit "use a password instead" escape on the add
  // form: app passwords remain valid for both providers, and a tenant that
  // hasn't approved this build's client id has no other way in.
  //
  // Destructive/recovery actions (purge, re-adopt, held-folder discard)
  // each require the user to TYPE the slug/folder name — the backend
  // re-verifies the confirmation, this UI just collects it
  // (`purge_mail_account_files`'s `require_confirmation`).
  import { Button } from '$lib/components/ui/button/index.js';
  import * as Dialog from '$lib/components/ui/dialog/index.js';
  import { Input } from '$lib/components/ui/input/index.js';
  import { Label } from '$lib/components/ui/label/index.js';
  import { api, type MailAuthMode } from '$lib/api/client';
  import { inDesktop, keychainSet } from '$lib/keychain';
  import { requestNotifyPermission } from '$lib/notify';
  import { prepareExternalOpen } from '$lib/shell/external-link';
  import { mailStore } from '$lib/stores/mail.svelte';
  import { workspaceStore } from '$lib/stores/workspace.svelte';
  import {
    submitMailSetup,
    mailAccessErrorMessage,
    mailSetupErrorMessage,
    mailMaintenanceErrorMessage,
    mailAuthMode,
    mailOauthProvider,
    mailOauthProviderLabel,
    mailOauthSignInLabel,
    mailSignInErrorMessage,
    mailStateLabel,
    mailSlugValid,
    needsMailSignIn,
    smtpFormError,
    startMailSignIn,
    type MailSetupSmtpInput,
    accountRecovery
  } from './mail-shapes';
  import MailDoctorPanel from './MailDoctorPanel.svelte';

  type FormMode = 'closed' | 'add' | 'edit';

  let formMode = $state<FormMode>('closed');
  let editingSlug: string | null = $state(null);

  let account = $state('');
  let host = $state('');
  let portText = $state('993');
  let username = $state('');
  let secret = $state('');

  // The optional SMTP block (spec G). Off by default: an account with no
  // `smtp:` is a push-only account, which is what every account was before
  // spec G and what most should stay. Both password fields are
  // component-local `$state` on exactly the same terms as `secret` above —
  // read at submit time, cleared immediately after, never stored.
  let smtpEnabled = $state(false);
  let smtpHost = $state('');
  let smtpPortText = $state('587');
  let smtpSecurity: '' | 'starttls' | 'tls' = $state('');
  let smtpUsername = $state('');
  let smtpFrom = $state('');
  let smtpFromName = $state('');
  let smtpSecret = $state('');
  let smtpSameAsImap = $state(true);

  // The account's SASL mode. In EDIT mode it is read from the stored account and
  // handed straight back on save — without that round trip, saving any other
  // change to an oauth2 account would rewrite it as a password account and the
  // engine would start offering its access token as a LOGIN password (M6 task
  // 15). In ADD mode it follows `useOauth` below rather than any control of its
  // own: the user picks a PROVIDER by typing their address, not a SASL mode.
  let authMode = $state<MailAuthMode>('password');

  // The account's PUBLIC OAuth2 client-id override (M6 task 16). Read-only
  // prefill, exactly like `authMode`: there is no control for it — a user who
  // needs one hand-edits `config/mail.yaml` — but the save re-renders the whole
  // entry, so a value never read back is a value silently dropped.
  let oauthClientId = $state<string | null>(null);

  // The "use a password instead" escape (add mode only). App passwords remain
  // perfectly valid for Gmail/M365, and some accounts can only use one (a
  // tenant that hasn't approved this build's client id, a legacy mailbox), so
  // the OAuth route is never a dead end.
  let passwordOverride = $state(false);

  // New-mail notifications, opt-in per account (M5 task 13), OFF by default.
  // The OS permission is requested LAZILY — here, on the first enable, never
  // on app load. A refusal turns the toggle straight back off and says so:
  // the switch always reflects what will actually happen, never an intent the
  // OS has already vetoed.
  let notificationsEnabled = $state(false);
  let notificationsDenied = $state(false);

  async function toggleNotifications(wanted: boolean): Promise<void> {
    notificationsDenied = false;
    // Follow the DOM first, then correct: the checkbox is one-way bound
    // (`checked={...}`) so it can be refused, and a state that never LEFT
    // `false` would leave a refused box visually ticked.
    notificationsEnabled = wanted;
    if (!wanted) return;

    const permission = await requestNotifyPermission();
    if (permission === 'granted') return;

    notificationsEnabled = false;
    notificationsDenied = true;
  }

  function smtpInput(): MailSetupSmtpInput {
    const port = Number(smtpPortText.trim());
    return {
      host: smtpHost,
      port: smtpPortText.trim() === '' ? null : port,
      security: smtpSecurity,
      username: smtpUsername,
      from: smtpFrom,
      fromName: smtpFromName,
      secret: smtpSecret,
      sameAsImap: smtpSameAsImap
    };
  }

  let submitting = $state(false);
  let error: string | null = $state(null);
  let submitted = $state(false);
  /** Whether the confirmation panel should say "finish in your browser" rather than "connected". */
  let awaitingSignIn = $state(false);
  let devModeNote = $state(false);
  let editLoadError = $state(false);

  // The add form is only the DEFAULT view while no account exists yet —
  // once accounts are listed it collapses behind the "Add account" button.
  const formVisible = $derived(formMode !== 'closed' || mailStore.accounts.length === 0);
  const editing = $derived(formMode === 'edit');

  /**
   * Which provider this HOST signs in with, if any. Driven by the host field —
   * which autodiscovery fills from the address the user typed — so the form
   * re-routes itself the moment `imap.gmail.com` lands in it.
   */
  const oauthProvider = $derived(mailOauthProvider(host));

  /**
   * Whether this form is a sign-in rather than a password entry. In EDIT mode
   * the STORED mode decides (an existing app-password Gmail account keeps its
   * password fields); in ADD mode the detected provider does, unless the user
   * has taken the escape.
   */
  const useOauth = $derived(
    editing ? authMode === 'oauth2' : !passwordOverride && oauthProvider !== null
  );

  const signInLabel = $derived(mailOauthSignInLabel(host) ?? 'Sign in');

  function resetForm(): void {
    account = '';
    host = '';
    portText = '993';
    username = '';
    secret = '';
    smtpEnabled = false;
    smtpHost = '';
    smtpPortText = '587';
    smtpSecurity = '';
    smtpUsername = '';
    smtpFrom = '';
    smtpFromName = '';
    smtpSecret = '';
    smtpSameAsImap = true;
    authMode = 'password';
    oauthClientId = null;
    passwordOverride = false;
    notificationsEnabled = false;
    notificationsDenied = false;
    error = null;
    editLoadError = false;
    guessNote = null;
    lastGuess = null;
  }

  function openAdd(): void {
    resetForm();
    submitted = false;
    awaitingSignIn = false;
    editingSlug = null;
    formMode = 'add';
  }

  function closeForm(): void {
    resetForm();
    submitted = false;
    awaitingSignIn = false;
    editingSlug = null;
    formMode = 'closed';
  }

  async function openEdit(slug: string): Promise<void> {
    resetForm();
    submitted = false;
    awaitingSignIn = false;
    editingSlug = slug;
    formMode = 'edit';
    account = slug;

    const result = await api.getMailAccountSettings(slug);
    // A slower response for a row the user has already navigated away from
    // (closed the form, opened another edit) must not repopulate the form.
    if (formMode !== 'edit' || editingSlug !== slug) return;
    if (!result.ok) {
      editLoadError = true;
      return;
    }

    const data = result.data as {
      notifications: boolean;
      account: {
        host: string;
        port: number;
        username: string;
        auth: string;
        oauthClientId: string | null;
        smtp: {
          host: string;
          port: number;
          security: string;
          username: string;
          from: string | null;
          fromName: string | null;
        } | null;
      };
    };
    host = data.account.host;
    portText = String(data.account.port);
    username = data.account.username;
    // Read back so `handleSubmit` can return them unchanged — see `authMode`.
    authMode = mailAuthMode(data.account.auth);
    oauthClientId = data.account.oauthClientId ?? null;
    // Prefilled WITHOUT re-asking the OS: an account already opted in has a
    // permission from before, and re-prompting on every edit-form open is
    // exactly what "lazily, on the first enable" rules out.
    notificationsEnabled = data.notifications === true;
    if (data.account.smtp) {
      smtpEnabled = true;
      smtpHost = data.account.smtp.host;
      smtpPortText = String(data.account.smtp.port);
      smtpSecurity = data.account.smtp.security === 'tls' ? 'tls' : 'starttls';
      smtpUsername = data.account.smtp.username;
      smtpFrom = data.account.smtp.from ?? '';
      smtpFromName = data.account.smtp.fromName ?? '';
      // Editing must never silently overwrite the stored SMTP secret with
      // the (blank) IMAP one — both fields start blank = both kept.
      smtpSameAsImap = false;
    }
  }

  // -- autodiscovery (add mode) ---------------------------------------------

  type GuessedServer = { host: string; port: number; security: string };
  let guessing = $state(false);
  let guessNote = $state<string | null>(null);
  let lastGuess = $state<{ imap: GuessedServer | null; smtp: GuessedServer | null } | null>(null);

  /**
   * On username blur: if it looks like an address and the host is still
   * blank, ask the backend to guess (`mail_autoconfig`). Fills only fields
   * the user hasn't typed; also suggests an account id from the domain when
   * that is still blank. Best-effort — failures stay silent, the form just
   * remains manual.
   */
  async function guessFromUsername(): Promise<void> {
    const email = username.trim();
    if (formMode === 'edit' || guessing) return;
    if (!email.includes('@') || host.trim() !== '') return;

    guessing = true;
    try {
      const result = await api.mailAutoconfig(email);
      if (!result.ok) return;
      const data = result.data as {
        imap: GuessedServer | null;
        smtp: GuessedServer | null;
        source: string | null;
      };
      if (!data.imap) return;

      lastGuess = { imap: data.imap, smtp: data.smtp };
      if (host.trim() === '') {
        host = data.imap.host;
        portText = String(data.imap.port);
      }
      applySmtpGuess();
      if (account.trim() === '') {
        const domain = email.split('@')[1] ?? '';
        const suggestion = domain.split('.')[0]?.toLowerCase().replace(/[^a-z0-9-]/g, '') ?? '';
        if (mailSlugValid(suggestion)) account = suggestion;
      }
      guessNote = `Server settings guessed from ${email.split('@')[1]} — check them before connecting.`;
    } finally {
      guessing = false;
    }
  }

  /**
   * Applies a cached SMTP guess once the send checkbox is on and the SMTP
   * host is still blank; also seeds the SMTP username from the IMAP one
   * (they match for virtually every provider — still editable).
   */
  function applySmtpGuess(): void {
    if (!smtpEnabled) return;
    if (smtpUsername.trim() === '' && !editing) smtpUsername = username.trim();
    const smtp = lastGuess?.smtp;
    if (!smtp || smtpHost.trim() !== '') return;
    smtpHost = smtp.host;
    smtpPortText = String(smtp.port);
    smtpSecurity = smtp.security === 'tls' ? 'tls' : smtp.security === 'starttls' ? 'starttls' : '';
  }

  // Which account row has its doctor open, and which maintenance action is
  // collecting a typed confirmation. A structured value, not a joined
  // string key — IMAP folder names may contain any separator character.
  // One open confirmation at a time keeps the list scannable.
  type PendingConfirm =
    | { kind: 'purge' | 'readopt'; account: string }
    | { kind: 'discard'; account: string; folder: string };
  let doctorFor: string | null = $state(null);
  let confirm: PendingConfirm | null = $state(null);
  let confirmText = $state('');
  let actionBusy = $state(false);
  let actionError: string | null = $state(null);

  const generation = $derived(workspaceStore.generation ?? 0);

  function validate(): string | null {
    if (!editing && !mailSlugValid(account.trim())) {
      return 'Account id must be lowercase letters, digits, and dashes (up to 32 characters).';
    }
    if (!host.trim()) return 'Enter the mail server host.';
    const port = Number(portText);
    if (!Number.isFinite(port) || port <= 0) return 'Enter a valid port.';
    if (!username.trim()) return 'Enter the mailbox username.';
    // Edit mode: blank = keep the stored password. On the OAuth route there is
    // no password at all — the provider's consent screen is the credential.
    if (!editing && !useOauth && !secret) return 'Enter the mailbox password.';
    // `setup_mail_account` answers a reason-free `invalid_smtp`, so
    // everything checkable is checked here first (see `smtpFormError`).
    if (smtpEnabled) return smtpFormError(smtpInput(), editing ? 'edit' : 'add');
    return null;
  }

  function submitErrorMessage(code: string): string {
    // Editing the server host or username collides with the on-disk store
    // identity (`Valea.Mail.Account.verify/3`) — the generic setup wording
    // ("a different account owns this folder") reads backwards here.
    if (editing && code === 'identity_mismatch') {
      return 'Changing the host or username would point this account at a different mailbox. Remove the account and add it fresh instead (its local files stay until you purge them).';
    }
    return mailSetupErrorMessage(code);
  }

  /**
   * The one submit path, for both routes. `openUrl` is present only on the
   * OAuth route: it is `prepareExternalOpen()`'s callback, reserved by the
   * click handler BEFORE this function's first await so the browser half
   * survives a popup blocker (see `shell/external-link.ts`). On failure it is
   * always called with `null`, which closes the reserved tab rather than
   * leaving a blank one parked.
   */
  async function handleSubmit(openUrl?: (url: string | null) => void): Promise<void> {
    error = null;
    const validationError = validate();
    if (validationError) {
      error = validationError;
      openUrl?.(null);
      return;
    }

    const slug = editing ? (editingSlug ?? account.trim()) : account.trim();
    // The mode is decided by the ROUTE, not by a control: an add form that
    // detected a provider (and wasn't overridden) writes an oauth2 account.
    const mode: MailAuthMode = useOauth ? 'oauth2' : 'password';

    submitting = true;
    const outcome = await submitMailSetup(
      {
        account: slug,
        host: host.trim(),
        port: Number(portText),
        username: username.trim(),
        // Nothing to hand off on the OAuth route — the account's credential is
        // a refresh token the callback route stores, never a typed secret.
        secret: useOauth ? '' : secret,
        generation,
        smtp: smtpEnabled ? smtpInput() : null,
        notifications: notificationsEnabled,
        auth: mode,
        oauthClientId
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
    // Cleared immediately after submit either way — never held longer than
    // the RPC call that needed it, never put in a store.
    secret = '';
    smtpSecret = '';

    if (!outcome.ok) {
      submitting = false;
      error = submitErrorMessage(outcome.error);
      openUrl?.(null);
      return;
    }

    // The account entry exists now, which is what `start_mail_oauth` needs (it
    // reads the host to pick a provider and parks the flow in that account's
    // engine). Only then is the consent screen opened.
    if (openUrl) {
      const started = await startMailSignIn(slug, generation, { api, openUrl });
      submitting = false;
      void mailStore.refreshStatus();

      if (!started.ok) {
        error = mailSignInErrorMessage(started.error);
        return;
      }

      awaitingSignIn = true;
      submitted = true;
      return;
    }

    submitting = false;
    void mailStore.refreshStatus();
    if (editing) {
      // Edits return to the list — the row itself is the confirmation.
      closeForm();
      return;
    }
    devModeNote = outcome.devMode;
    submitted = true;
  }

  /**
   * The OAuth submit. `prepareExternalOpen()` runs FIRST and synchronously —
   * the click gesture is still on the stack here, and it is what lets the
   * browser half navigate a tab it already owns after the awaits.
   */
  function submitSignIn(): void {
    void handleSubmit(prepareExternalOpen());
  }

  // -- signing an existing account back in -------------------------------------

  /**
   * Which account's sign-in is in flight, and the last one that failed —
   * per-account, not a shared string: several rows can want a sign-in at once,
   * and a shared error would appear under all of them.
   */
  let signingIn = $state<string | null>(null);
  let signInError = $state<{ account: string; message: string } | null>(null);

  /**
   * "Sign in again" on an account row (`needsMailSignIn`): the same flow as the
   * add form's, minus the save — the account already exists, so this only mints
   * a fresh authorization. Same synchronous `prepareExternalOpen()` first.
   */
  function signInAgain(slug: string): void {
    const openUrl = prepareExternalOpen();
    signingIn = slug;
    signInError = null;

    void (async () => {
      const started = await startMailSignIn(slug, generation, { api, openUrl });
      signingIn = null;
      if (!started.ok) signInError = { account: slug, message: mailSignInErrorMessage(started.error) };
      void mailStore.refreshStatus();
    })();
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

  // -- per-project mail access (the CONTEXT.md opt-in grammar) ---------------
  //
  // Which projects' sessions may read each mailbox — the settings UI over
  // the `related_icms: - mail-<slug>` bare-string grammar. The FILE stays
  // the source of truth: `list_icm_mail_access` reads every enabled ICM's
  // CONTEXT.md, `set_icm_mail_access` edits the one entry line in place.
  // Loaded once when this panel opens, like the trusted senders below.
  type MailAccessRow = { mountKey: string; name: string; accounts: string[] };
  let mailAccess = $state<MailAccessRow[]>([]);
  let accessBusy = $state(false);
  let accessError = $state<string | null>(null);
  /** Which account's row shows `accessError` — errors render where the click happened. */
  let accessErrorAccount = $state<string | null>(null);

  $effect(() => {
    void (async () => {
      const result = await api.listIcmMailAccess(generation);
      if (result.ok) mailAccess = (result.data as { access: MailAccessRow[] }).access;
    })();
  });

  /**
   * One toggle at a time, optimistic with a revert: the checkbox is one-way
   * bound (`checked={...}`), so the DOM has already flipped when this runs —
   * state follows it immediately and is put back on a refusal, the same
   * follow-the-DOM-then-correct dance `toggleNotifications` documents.
   */
  async function toggleAccess(mountKey: string, account: string, enabled: boolean): Promise<void> {
    const before = mailAccess;
    accessBusy = true;
    accessError = null;
    accessErrorAccount = null;
    mailAccess = mailAccess.map((row) =>
      row.mountKey === mountKey
        ? {
            ...row,
            accounts: enabled
              ? [...row.accounts, account]
              : row.accounts.filter((a) => a !== account)
          }
        : row
    );

    const result = await api.setIcmMailAccess(mountKey, account, enabled, generation);
    accessBusy = false;

    if (!result.ok) {
      mailAccess = before;
      accessError = mailAccessErrorMessage(result.error, account);
      accessErrorAccount = account;
      return;
    }

    const data = result.data as { accounts: string[] };
    mailAccess = mailAccess.map((row) => (row.mountKey === mountKey ? { ...row, accounts: data.accounts } : row));
  }

  // -- trusted senders (HTML mail's remote-content gate) ----------------------
  //
  // The workspace-wide list behind "Always trust <sender>" in the read pane
  // (`Valea.Mail.Trust`) — surfaced here so a trust decision can be
  // reviewed and revoked. Loaded once when this panel opens.
  let trustedSenders = $state<string[]>([]);
  let trustBusy = $state<string | null>(null);

  $effect(() => {
    void (async () => {
      const result = await api.listTrustedMailSenders();
      if (result.ok) trustedSenders = (result.data as { senders: string[] }).senders;
    })();
  });

  async function untrust(email: string): Promise<void> {
    trustBusy = email;
    const result = await api.setMailSenderTrust(email, false, generation);
    trustBusy = null;
    if (result.ok) trustedSenders = trustedSenders.filter((s) => s !== email);
  }

  // A recovery state (`accountRecovery`, computed once per row below) swaps
  // the row's normal affordances for explanatory copy + its own CTAs
  // (spec E §safety invariants: fail-closed, user-decided states). That
  // function owns the branch — including the one `identity_mismatch` case
  // that must NOT offer a purge (a corrupt `.account`, windows-support spec
  // C1) — so both arms stay unit-tested without a render harness.
</script>

<!-- `min-w-0` is load-bearing: as a grid item of Dialog.Content, this div's
     automatic minimum width would otherwise be min-content — and the account
     card's unbreakable mono path line would push the whole MODAL into
     horizontal scroll instead of scrolling inside its own block. -->
<div class="flex w-full min-w-0 flex-col items-start gap-3">
  {#if submitted}
    <Dialog.Header>
      <Dialog.Title class="font-display text-ink-heading text-[19px]">
        {awaitingSignIn ? 'Finish signing in' : 'Mailbox connected'}
      </Dialog.Title>
    </Dialog.Header>
    {#if awaitingSignIn}
      <p class="text-ink-body max-w-[420px] text-[13px]">
        Your browser has opened your provider's sign-in page. Once you allow access, come back here — this
        account starts syncing on its own.
      </p>
    {/if}
    {#if devModeNote && !awaitingSignIn}
      <p class="text-suggest-ink text-[12.5px]">
        Dev mode: the password is held in memory only and never persisted.
      </p>
    {/if}
    <div class="mt-1 flex items-center gap-2">
      <Button type="button" variant="outline" size="sm" onclick={() => openAdd()}>Add another</Button>
      <Button type="button" variant="ghost" size="sm" onclick={() => closeForm()}>Done</Button>
    </div>
  {:else if !formVisible}
    <Dialog.Header>
      <Dialog.Title class="font-display text-ink-heading text-[19px]">Mail accounts</Dialog.Title>
    </Dialog.Header>

    <ul class="flex w-full flex-col gap-3">
      {#each mailStore.accounts as status (status.account)}
        {@const recovery = accountRecovery(status)}
        <li class="border-paper-border bg-paper-card rounded-xl border px-4 py-3">
          <div class="flex items-center gap-2.5">
            <span class="text-ink-heading text-[13.5px] font-medium">{status.account}</span>
            <span class="text-ink-meta text-[12px]">{mailStateLabel(status.state)}</span>
            <span class="min-w-2 flex-1" aria-hidden="true"></span>
            {#if needsMailSignIn(status)}
              <!-- An oauth2 account whose sign-in expired, was never finished,
                   or didn't survive a restart: one click re-runs the same flow
                   the add form uses. -->
              <Button
                type="button"
                variant="outline"
                size="sm"
                disabled={signingIn === status.account}
                onclick={() => signInAgain(status.account)}
              >
                {status.state === 'reauth_required' ? 'Sign in again' : 'Sign in'}
              </Button>
            {/if}
            {#if status.valid && !recovery}
              <Button type="button" variant="ghost" size="sm" onclick={() => void openEdit(status.account)}>
                Edit
              </Button>
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

          {#if status.root}
            <!-- The §1 ownership signature: where this mailbox lives on disk,
                 in mono — plain files the user can open, back up, or take.
                 A scrollable block, not a truncating line: these paths are
                 long and the point is being able to read (and copy) them. -->
            <pre
              class="border-paper-hairline bg-paper-surface text-ink-meta mt-1.5 w-full overflow-x-auto rounded-md border px-2.5 py-1.5 font-mono text-[11px] whitespace-pre">{status.root}</pre>
          {/if}

          {#if signInError && signInError.account === status.account}
            <p class="text-warn-ink mt-1.5 text-[12.5px]" role="alert">{signInError.message}</p>
          {/if}

          {#if status.valid && mailAccess.length > 0}
            <!-- Which projects' sessions may read this mailbox — each
                 checkbox edits the ONE `mail-<slug>` line in that project's
                 CONTEXT.md (the file stays the source of truth). Sessions
                 started from Mail itself always get access, regardless. -->
            <div class="border-paper-hairline mt-2.5 border-t pt-2">
              <p class="text-ink-meta text-[11.5px]">Let sessions in these projects read this mailbox:</p>
              <div class="mt-1.5 flex flex-wrap items-center gap-x-4 gap-y-1">
                {#each mailAccess as row (row.mountKey)}
                  <label class="text-ink-body flex items-center gap-1.5 text-[12.5px]">
                    <input
                      type="checkbox"
                      checked={row.accounts.includes(status.account)}
                      disabled={accessBusy}
                      onchange={(event) =>
                        void toggleAccess(row.mountKey, status.account, event.currentTarget.checked)}
                    />
                    {row.name}
                  </label>
                {/each}
              </div>
              {#if accessError && accessErrorAccount === status.account}
                <p class="text-warn-ink mt-1.5 text-[12px]" role="alert">{accessError}</p>
              {/if}
            </div>
          {/if}

          {#if !status.valid}
            <p class="text-warn-ink mt-1.5 text-[12.5px]">
              Invalid configuration{status.reason ? `: ${status.reason}` : ''}. Fix
              <code class="bg-paper-track rounded px-1 py-0.5 text-[11.5px]">config/mail.yaml</code> by hand, then reopen
              the workspace.
            </p>
          {/if}

          {#each status.notices as notice (notice)}
            <p class="text-suggest-ink mt-1 text-[12px]">{notice}</p>
          {/each}

          {#if recovery}
            <p class="text-warn-ink mt-1.5 text-[12.5px]">{recovery.message}</p>
            {#if recovery.actions.length > 0}
              <div class="mt-2 flex items-center gap-2">
                {#each recovery.actions as action, i (action)}
                  <!-- First action is the primary recovery; a second one (always the
                       destructive purge) is de-emphasized. -->
                  <Button
                    type="button"
                    variant={i === 0 ? 'outline' : 'ghost'}
                    size="sm"
                    onclick={() => beginConfirm({ kind: action, account: status.account })}
                  >
                    {action === 'readopt' ? 'Re-adopt…' : 'Purge local files…'}
                  </Button>
                {/each}
              </div>
            {/if}
          {/if}

          {#each status.heldFolders as folder (folder)}
            <div class="mt-1.5 flex flex-wrap items-center gap-2">
              <p class="text-suggest-ink text-[12.5px]">
                Folder <span class="font-mono text-[11.5px]">{folder}</span> disappeared from the server. Its local
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

    <div class="mt-3">
      <Button type="button" variant="outline" size="sm" onclick={() => openAdd()}>Add account</Button>
    </div>

    {#if trustedSenders.length > 0}
      <div class="border-paper-hairline mt-6 w-full border-t pt-4">
        <h2 class="font-display text-ink-heading text-[17px]">Trusted senders</h2>
        <p class="text-ink-meta mt-1 max-w-[480px] text-[12px]">
          Messages from these addresses load remote images automatically.
        </p>
        <ul class="mt-2 flex flex-col">
          {#each trustedSenders as sender (sender)}
            <li class="flex items-center justify-between gap-2 py-0.5">
              <span class="text-ink-secondary min-w-0 truncate text-[12.5px]">{sender}</span>
              <Button
                type="button"
                variant="ghost"
                size="sm"
                disabled={trustBusy === sender}
                onclick={() => void untrust(sender)}
              >
                Remove
              </Button>
            </li>
          {/each}
        </ul>
      </div>
    {/if}
  {:else}
    <!-- The form as its own modal view (add / edit / first-run connect): it
         replaces the account list wholesale, and Cancel next to the submit
         returns to it. The first run has no list to go back to, so no
         Cancel is offered there. -->
    <Dialog.Header>
      <Dialog.Title class="font-display text-ink-heading text-[19px]">
        {mailStore.accounts.length === 0 ? 'Connect your mailbox' : editing ? `Edit ${editingSlug}` : 'Add account'}
      </Dialog.Title>
    </Dialog.Header>

    {#if editing}
      {#if editLoadError}
        <p class="text-warn-ink text-[12.5px]" role="alert">
          Could not load this account's settings. Close and try again.
        </p>
      {/if}
      <p class="text-ink-body max-w-[480px] text-[13.5px]">
        Change the server settings for this account. Leave the password fields blank to keep the stored ones.
      </p>
    {:else if useOauth}
      <p class="text-ink-body max-w-[480px] text-[13.5px]">
        {signInLabel} to let Valea mirror this mailbox over IMAP. You sign in on your provider's own page —
        Valea never sees your password, and the sign-in it keeps is stored in your system keychain, not in the
        workspace.
      </p>
    {:else}
      <p class="text-ink-body max-w-[480px] text-[13.5px]">
        Valea mirrors your mailbox over IMAP with TLS. Your password is handed off once and never written into the
        workspace. Start with your email address as the username — the server settings are guessed for you.
      </p>
    {/if}

    <div class="flex w-full max-w-md flex-col gap-4">
      <div class="flex flex-col gap-1.5">
        <Label for="mail-setup-username">Username</Label>
        <Input
          id="mail-setup-username"
          bind:value={username}
          disabled={submitting}
          placeholder="you@example.com"
          onblur={() => void guessFromUsername()}
        />
        {#if guessing}
          <p class="text-ink-meta text-[11.5px]">Looking up server settings…</p>
        {:else if guessNote}
          <p class="text-suggest-ink text-[11.5px]">{guessNote}</p>
        {/if}
      </div>

      <div class="flex flex-col gap-1.5">
        <Label for="mail-setup-account">Account id</Label>
        <Input id="mail-setup-account" bind:value={account} disabled={submitting || editing} placeholder="work" />
        {#if !editing}
          <p class="text-ink-meta text-[11.5px]">Lowercase letters, digits, and dashes. Names the folder under sources/mail/</p>
        {/if}
      </div>

      <div class="flex flex-col gap-1.5">
        <Label for="mail-setup-host">Host</Label>
        <Input id="mail-setup-host" bind:value={host} disabled={submitting} placeholder="imap.example.com" />
      </div>

      <div class="flex flex-col gap-1.5">
        <Label for="mail-setup-port">Port</Label>
        <Input id="mail-setup-port" inputmode="numeric" bind:value={portText} disabled={submitting} />
        <p class="text-ink-meta text-[11.5px]">TLS, always on</p>
      </div>

      {#if useOauth}
        <!-- No password field at all on this route: the credential is the
             provider's own sign-in. The escape below stays because app
             passwords remain valid for Gmail and M365, and some accounts can
             only use one (a tenant that hasn't approved this build's client
             id, a legacy mailbox). -->
        <div class="border-paper-hairline flex flex-col gap-2 border-t pt-4">
          <p class="text-ink-meta max-w-[420px] text-[11.5px]">
            {oauthProvider
              ? `This mailbox signs in through ${mailOauthProviderLabel(oauthProvider)}. No password is stored.`
              : 'This account signs in with your mail provider. No password is stored.'}
          </p>
          {#if !editing}
            <button
              type="button"
              class="text-suggest-ink self-start text-[12px] underline underline-offset-2"
              disabled={submitting}
              onclick={() => (passwordOverride = true)}
            >
              Use a password instead
            </button>
          {/if}
        </div>
      {:else}
        <div class="flex flex-col gap-1.5">
          <Label for="mail-setup-password">Password</Label>
          <Input
            id="mail-setup-password"
            type="password"
            autocomplete="off"
            bind:value={secret}
            disabled={submitting}
            placeholder={editing ? 'Leave blank to keep the stored password' : ''}
          />
          {#if !editing && oauthProvider !== null}
            <button
              type="button"
              class="text-suggest-ink self-start text-[12px] underline underline-offset-2"
              disabled={submitting}
              onclick={() => (passwordOverride = false)}
            >
              {signInLabel} instead
            </button>
          {/if}
        </div>
      {/if}

      <!-- New-mail notifications, per account (M5 task 13). Off by default;
           the OS permission is asked for on the first enable, and a refusal
           snaps the switch back off rather than promising a banner that will
           never appear. -->
      <div class="border-paper-hairline flex flex-col gap-2 border-t pt-4">
        <label class="text-ink-body flex items-center gap-2 text-[13px]">
          <input
            type="checkbox"
            checked={notificationsEnabled}
            disabled={submitting}
            onchange={(event) => void toggleNotifications(event.currentTarget.checked)}
          />
          Notify me when new mail arrives
        </label>
        <p class="text-ink-meta max-w-[420px] text-[11.5px]">
          One notification per sync, for unread mail landing in this account's inbox.
        </p>
        {#if notificationsDenied}
          <p role="alert" class="text-warn-ink text-[11.5px]">
            Your system is blocking notifications for Valea. Allow them in your notification
            settings, then turn this back on.
          </p>
        {/if}
      </div>

      <!-- Sending is opt-in, per account (spec G §Configuration &
           credentials). Without this block the account is push-only: Valea
           can place drafts in your mailbox but has no transport to send. -->
      <div class="border-paper-hairline flex flex-col gap-3 border-t pt-4">
        <label class="text-ink-body flex items-center gap-2 text-[13px]">
          <input
            type="checkbox"
            bind:checked={smtpEnabled}
            disabled={submitting}
            onchange={() => applySmtpGuess()}
          />
          Also let me send from this account
        </label>

        {#if smtpEnabled}
          <p class="text-ink-meta max-w-[420px] text-[11.5px]">
            Only you can send — your assistant prepares drafts and you confirm each one. TLS is always on.
          </p>

          <div class="flex flex-col gap-1.5">
            <Label for="mail-smtp-host">SMTP host</Label>
            <Input id="mail-smtp-host" bind:value={smtpHost} disabled={submitting} placeholder="smtp.example.com" />
          </div>

          <div class="flex items-end gap-2">
            <div class="flex flex-1 flex-col gap-1.5">
              <Label for="mail-smtp-port">Port</Label>
              <Input id="mail-smtp-port" inputmode="numeric" bind:value={smtpPortText} disabled={submitting} />
            </div>
            <div class="flex flex-1 flex-col gap-1.5">
              <Label for="mail-smtp-security">Security</Label>
              <select
                id="mail-smtp-security"
                class="border-paper-hairline bg-paper-surface rounded-[7px] border px-2 py-1.5 text-[12.5px]"
                bind:value={smtpSecurity}
                disabled={submitting}
              >
                <option value="">Match the port</option>
                <option value="starttls">STARTTLS (587)</option>
                <option value="tls">TLS (465)</option>
              </select>
            </div>
          </div>

          <div class="flex flex-col gap-1.5">
            <Label for="mail-smtp-username">SMTP username</Label>
            <Input
              id="mail-smtp-username"
              bind:value={smtpUsername}
              disabled={submitting}
              placeholder={username.trim() || 'you@example.com'}
            />
          </div>

          <!-- From is CONFIG-OWNED: a draft can never set or override it.
               It defaults to the SMTP username, which only works when that
               username is itself an address — otherwise `smtpFormError`
               requires this field before the RPC is ever called. -->
          <div class="flex flex-col gap-1.5">
            <Label for="mail-smtp-from">Send as</Label>
            <Input
              id="mail-smtp-from"
              bind:value={smtpFrom}
              disabled={submitting}
              placeholder={smtpUsername.trim() || 'you@example.com'}
            />
            <p class="text-ink-meta text-[11.5px]">
              The From address on everything you send. Leave blank to use the SMTP username.
            </p>
          </div>

          <div class="flex flex-col gap-1.5">
            <Label for="mail-smtp-from-name">Display name</Label>
            <Input id="mail-smtp-from-name" bind:value={smtpFromName} disabled={submitting} placeholder="Mara Vance" />
          </div>

          {#if useOauth}
            <!-- One authorization covers both protocols, so there is no second
                 secret to collect: the engine mints the access token the SMTP
                 session uses from the same sign-in. -->
            <p class="text-ink-meta max-w-[420px] text-[11.5px]">
              Sending uses the same sign-in — there is no separate SMTP password.
            </p>
          {:else}
            <!-- The SMTP secret is a SEPARATE keychain entry from the IMAP one;
                 "same as IMAP" copies the typed password into it (a copy, not
                 an alias — rotation stays independent). -->
            <label class="text-ink-body flex items-center gap-2 text-[13px]">
              <input type="checkbox" bind:checked={smtpSameAsImap} disabled={submitting} />
              Same password as IMAP
            </label>

            {#if !smtpSameAsImap}
              <div class="flex flex-col gap-1.5">
                <Label for="mail-smtp-password">SMTP password</Label>
                <Input
                  id="mail-smtp-password"
                  type="password"
                  autocomplete="off"
                  bind:value={smtpSecret}
                  disabled={submitting}
                  placeholder={editing ? 'Leave blank to keep the stored password' : ''}
                />
              </div>
            {/if}
          {/if}
        {/if}
      </div>

      {#if error}
        <p role="alert" class="text-warn-ink text-[12.5px]">{error}</p>
      {/if}

      <div class="flex items-center gap-2">
        {#if useOauth && !editing}
          <!-- `prepareExternalOpen()` must run inside this click gesture, which
               is why `submitSignIn` is synchronous and reserves the tab before
               it awaits anything. -->
          <Button type="button" onclick={() => submitSignIn()} disabled={submitting}>
            {submitting ? 'Opening your browser…' : signInLabel}
          </Button>
        {:else}
          <!-- Disabled on a failed edit prefill: the form holds defaults rather
               than the stored account, and this action re-renders the entry
               WHOLE — saving would downgrade `auth`, drop the smtp block and
               turn notifications off. -->
          <Button
            type="button"
            onclick={() => void handleSubmit()}
            disabled={submitting || (editing && editLoadError)}
          >
            {submitting ? (editing ? 'Saving…' : 'Connecting…') : editing ? 'Save changes' : 'Connect mailbox'}
          </Button>
        {/if}
        {#if mailStore.accounts.length > 0}
          <Button type="button" variant="ghost" disabled={submitting} onclick={() => closeForm()}>Cancel</Button>
        {/if}
      </div>
    </div>
  {/if}
</div>
