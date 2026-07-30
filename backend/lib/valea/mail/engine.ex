defmodule Valea.Mail.Engine do
  @moduledoc """
  Per-ACCOUNT mail sync GenServer (mail-as-maildir design spec E, §Engine).
  One instance per valid account in `config/mail.yaml`, supervised by
  `Valea.Mail.Supervisor` and registered under `{:via, Registry,
  {Valea.Mail.Registry, slug}}` (the Registry itself lives at the app level —
  see `Valea.Application`). State: the account's `Valea.Mail.Settings.t()`
  (handed in at `start_link/1`, not re-read from `config/mail.yaml` by this
  module), credential (RAM only), sync status, poll timer.

  ## Activation gating

  Two ways an Engine comes to life: as one of `Valea.Mail.Supervisor`'s BOOT
  children (started as part of `Valea.Workspace.Runtime`, before the
  workspace's own `:workspace_opened` broadcast fires), or LATER via
  `Valea.Mail.Supervisor.reload_settings_all/1` rehashing a newly-valid
  account into existence mid-session, well after that broadcast already
  fired for every sibling engine. `init/1` handles both without ever
  branching on which one it is at the call site: it always subscribes to the
  `"workspace"` PubSub topic and builds an inert state (`active: false`);
  only a rehash-started Engine additionally carries `activate: true` in its
  start args, which schedules a `{:continue, :activate_now}` that runs the
  EXACT SAME activation path a boot-time Engine reaches via its own
  generation's `{:workspace_opened, info, generation}` broadcast. A
  broadcast for any other generation (a stale open, or a switch that landed
  before this Engine's own open finished) is ignored; a rolled-back open
  just kills the still-inert Engine along with the rest of that `Runtime`.

  ## Identity binding

  Activation calls `Valea.Mail.Account.verify/3` against `sources/mail/
  <slug>/.account` before anything else: `:absent` claims the slug
  (`write_if_absent!/4`) and proceeds; `{:error, :identity_mismatch}` — the
  slug's local subtree was provisioned against a DIFFERENT host/username —
  leaves the Engine inert (`active: false`, `state: "identity_mismatch"`),
  never running `Index.rebuild/2` or a sync pass, but still answering
  `status/1` so the RPC/cockpit surface can show the operator what's wrong.
  Resolving it is a purge (Task 10's `purge_mail_account_files`), not
  `readopt/1` — a mismatched identity is a different account entirely, not
  the SAME account's mailbox getting replaced (see below).

  ## Maildir separator (windows-support spec C1)

  This module owns the separator POLICY; `Valea.Mail.Account` owns the
  durable state and `Valea.Mail.Maildir` the codec. Activation is the one
  place the two meet:

    * claiming an unclaimed slug picks the NEW-store separator from the host
      platform — `;` on Windows (`:` is illegal on NTFS), `:` elsewhere;
    * every activation — new or existing — then READS the separator back
      from `.account` (`Account.separator/2`) and pins it into state, so an
      existing store's recorded convention always wins over the host's;
    * `{:error, :invalid_separator}` takes the same inert, sticky path as
      `:identity_mismatch` — no index rebuild, no pass — with `last_error`
      naming the corrupt field. Encoding filenames against a guess would
      scatter names the rest of the store can't be listed against.

  The pinned separator rides in the args/ctx of every background worker
  (`SyncPass`, `OpsExecutor`) exactly like `root`/`account`: those modules
  never re-derive it, and never default it.

  ## Credential handling

  The credential is process memory only — never written to disk, never
  logged, never part of the workspace. It is held as a **zero-arity
  closure** (`fn -> secret end`) rather than the raw string: `inspect/1` on
  a function value never renders its closed-over environment, so an
  operator inspecting this process's state (`:sys.get_state/1`, a crash
  dump, an ad hoc inspect of `state` while debugging) cannot see the secret
  by accident. Callers that need the raw value call the closure, not
  pattern-match into state.

  Two ways a credential arrives: the `set_mail_credential` RPC (via
  `set_credential/3`) or — dev-only, browser-mode fallback documented in the
  design spec's §Credentials — `Valea.Mail.Settings.env_credential/1`
  (`VALEA_MAIL_PASSWORD_<SLUG>`), read once at activation and only if no
  credential has already been supplied.

  There are TWO such slots, never one: `credential` (IMAP) and
  `smtp_credential` (SMTP, spec G §Configuration & credentials), each with
  its own keychain entry and its own env fallback
  (`VALEA_MAIL_SMTP_PASSWORD_<SLUG>`). `set_credential/3`'s `kind` picks the
  slot; the 2-arity call is IMAP, exactly as before. They are independent on
  purpose — the setup UI's "same as IMAP" writes a COPY, so rotating one
  never silently moves the other, and a bad SMTP password can never pause
  the IMAP sync.

  ### OAuth2 accounts, and where their token comes from

  An account whose settings say `auth: :oauth2` (mail full-client plan, M6)
  changes both halves. The clients authenticate with `XOAUTH2` instead of
  `LOGIN`/`AUTH PLAIN` (task 15), and the secret they are handed comes from
  neither slot above but from a THIRD one plus a cache (task 16):

    * `oauth_refresh` — the long-lived refresh token, the account's real
      durable credential. Same RAM-only zero-arity closure as a password:
      **it never touches disk on this side**. Its durable home is the OS
      keychain, written by the frontend off the `mail_oauth` push
      (`store_oauth_refresh_token/2`) and handed back after a restart through
      `set_credential(slug, token, :oauth)` — the resupply path
      `<slug>:imap`/`<slug>:smtp` already follow.
    * `oauth_token` — the short-lived access token, `%{token: closure,
      expires_at: ...}`, minted from the refresh token by
      `mint_access_token/1` and reused until it comes within one minute of
      expiry (`@token_skew_ms` — a connect starting just under the wire must
      not be handed a token that expires during it).

  Both protocols share ONE authorization (one scope grant covers IMAP and
  SMTP), so both credential closures for an oauth2 account resolve to the
  same token.

  The closure CONTRACT is unchanged, which is the point: every consumer
  (`SyncPass`, `OpsExecutor`, `IdleWatcher`, `Doctor`) still receives a
  zero-arity function returning a binary, and still calls it exactly once at
  its `connect/3` boundary. For an oauth2 account that function calls back
  into this Engine (`mint_access_token/1` → the `:access_token` call), which
  either answers from the cache or refreshes. It cannot deadlock: that
  `handle_call` never waits on the worker — it replies from cache, or parks
  the caller and starts its own monitored Task, exactly like `apply_ops`.

  Refreshes are SINGLE-FLIGHT: N concurrent consumers (a pass, the IDLE
  watcher, a send) produce one token request, and every parked caller is
  answered from its one result. A mint that cannot be satisfied returns `""`
  rather than raising or breaking the contract — see
  `mint_access_token/1` for why, and §Credential epoch below for what keeps
  that empty token from parking the account by mistake.

  `invalid_grant` from a refresh is the one permanent answer: the refresh
  token is dead, so the cache AND the slot are cleared and the account goes
  sticky `reauth_required` immediately, without waiting for a round trip to
  the mail server to tell us the same thing.

  ## Credential epoch (why a stale pass cannot park a fresh credential)

  `credential_epoch` counts every change to the credential MATERIAL this
  Engine considers current: a `set_credential/3` of any kind, a rotated
  refresh token, a refresh token thrown away as `invalid_grant`, and a mint
  that failed (because the `""` it handed out is not a credential this Engine
  holds). `start_pass/1` pins the current value into
  `pass_credential_epoch`.

  An auth failure reported by a pass whose pinned epoch no longer matches is
  therefore NOT authoritative — the secret changed under it — and must not
  make the account sticky: `stale_auth_failure/2` records the error, leaves
  the status decision to whatever the Engine knows NOW, and lets polling
  retry with the current credential. Without this, an ordinary token refresh
  landing mid-pass (or a user re-signing-in during one) parks the account
  `reauth_required` WITH a perfectly good secret already in the slot, and
  nothing re-arms until another `set_credential/3` — the hazard is
  pre-existing for passwords and would be routine once tokens auto-mint.

  ## IMAP IDLE

  Each Engine owns an anonymous `DynamicSupervisor` (started in `init/1`, so
  linked to this process and torn down with it) whose only child is this
  account's `Valea.Mail.IdleWatcher` — a long-lived, INBOX-only IDLE
  connection that pokes this Engine into a sync pass when the server
  announces new mail. The watcher is started, stopped and REBUILT off exactly
  the same gate a pass runs under (`validate_sync/1`): it exists while the
  account is active, configured, credentialed and not sticky-blocked, and not
  otherwise. A new IMAP credential rebuilds it (the connection it holds
  authenticated with the old secret); `auth_failed`/`reauth_required` and
  `mailbox_replaced` stop it, and `readopt/1` brings it back.

  The supervisor in between is not ceremony — it is what keeps a dying IDLE
  connection away from this process, whose in-RAM credential nothing else
  holds a copy of. For the same reason every supervisor call on that path is
  guarded (`safe_start_child/2`, `safe_terminate_child/2`): a supervisor that
  has itself given up must degrade to "no IDLE, still polling", never take
  the Engine's `handle_call` down with a `:noproc` exit.

  IDLE is an accelerator, never a dependency: the poll timer below runs
  unchanged whether or not a watcher exists, and `Valea.Mail.IdleWatcher`'s
  moduledoc explains why every failure there is a latency cost rather than a
  correctness one. `:mail_idle` (application env, default `true`) is the one
  switch — the test seam that keeps a second connection out of the way of the
  suites that script the transport call-for-call. There is no user-facing
  toggle: IDLE is automatic when the server advertises it.

  ## Sync passes

  A pass (`Valea.Mail.SyncPass.run/1`) runs in a monitored `Task`, triggered
  by the poll timer, `sync_now/1`, or an IDLE notification (`idle_activity/1`
  — its only three triggers). At most one runs at a time: the in-flight task's
  `{pid, ref}` is tracked in
  `state.sync_task`, so a second `sync_now` (or a poll tick) while syncing is
  a no-op that leaves the running pass untouched. Status shows `"syncing"`
  for the duration; the task's result flips it back to `"idle"` (or
  `"auth_failed"`/`"reauth_required"`/`"mailbox_replaced"`) and broadcasts
  `mail_sync_finished`.
  The credential closure is handed to the task and only ever called inside
  `SyncPass` at the `transport.connect/3` boundary.

  ## RPC declared ops (`apply_ops`)

  `mail_apply_ops` (the Mail UI's archive/move/flag actions) runs the SAME
  `Valea.Mail.OpsExecutor` core as the ops-file push phase, but it must never
  execute concurrently with a sync pass (or another ops batch) — they mutate
  the same mailbox/ledger/manifests, and a concurrent `recover()` or a
  duplicate-copy on a non-UIDPLUS server would corrupt state. So an ops batch
  runs in its OWN monitored+linked `Task` (exactly like a sync pass), and is
  STRICTLY SERIALIZED against passes: `sync_task` and `ops_current` are two
  faces of the one "background work in flight" slot — `busy?/1` gates both.

  An `apply_ops` arriving while a pass (or an earlier ops batch) is in flight
  is QUEUED (`ops_queue`) rather than run inline; its `GenServer.reply` is
  DEFERRED until its own task finishes (so `handle_call` never blocks the
  Engine loop — `status/1`, `sync_now/1`, `set_credential/2` and the poll tick
  keep answering instantly). Conversely, a `sync_now`/poll tick arriving while
  an ops task runs is a no-op (`start_pass_unless_running/1` sees `busy?`), so
  no pass ever runs alongside an ops batch. In the normal case the queued
  reply still lands within the caller's 60s call timeout. The per-op results
  array is always returned (a connect/executor failure degrades to per-op
  rejections, keeping `mail_apply_ops`'s frozen shape populated).

  ## `mailbox_replaced` stickiness + `readopt`

  A pass reporting `{:error, :mailbox_replaced}` (`Valea.Mail.Reconcile.
  detect_replacement/2` decided this pass's resets amount to a whole-mailbox
  replacement, not ordinary per-folder resets) is STICKY: `state` stays
  `"mailbox_replaced"` and polling pauses (same posture as `auth_failed`)
  until `readopt/1` — which writes the one-shot `sources/mail/<slug>/
  .readopt` marker (`Valea.Mail.Account.authorize_readopt!/2`), flips status
  back to `"idle"`, and re-arms polling. The NEXT pass reads that marker,
  threads `readopt_authorized: true` into `SyncPass.run/1` (which skips
  `detect_replacement` for that one pass and reconciles every reset folder
  individually via `Reconcile.folder_reset/2`), and — only once that pass
  reports success — this Engine clears the marker. A forced SECOND
  replacement after that re-blocks normally: the marker is gone, so the next
  reset pass runs `detect_replacement` again.

  ## Errors

  A pass returning `{:error, :auth_failed}` pauses the poll timer (no retry
  storm against a bad password) until `set_credential/2` supplies a new one,
  which clears the failure and re-arms polling. `set_credential/2` itself
  never starts a pass directly — it only re-arms the timer, and the next
  tick runs one. `{:error, :reauth_required}` — an OAuth2 account's token
  refused rather than a password (M6 task 15) — is the same posture under its
  own status, cleared by the same call.
  """
  use GenServer

  require Logger

  alias Valea.Mail.Account
  alias Valea.Mail.AgentsFile
  alias Valea.Mail.Doctor
  alias Valea.Mail.IdleWatcher
  alias Valea.Mail.Index
  alias Valea.Mail.OAuth
  alias Valea.Mail.OpsExecutor
  alias Valea.Mail.Redact
  alias Valea.Mail.Settings
  alias Valea.Mail.Store
  alias Valea.Mail.SyncPass

  @default_interval_minutes 5
  @max_poll_jitter_ms 60_000

  # How long a minted-but-unused authorization may sit in `oauth_pending`
  # before the callback can no longer redeem it. Generous because the user is
  # in the middle of a provider consent screen (account chooser, 2FA, a
  # policy prompt), and short enough that a state token is never a long-lived
  # thing to guess at.
  @oauth_flow_ttl_ms 10 * 60 * 1_000

  # Refresh an access token this long before it actually expires, so a
  # connect that starts just under the wire isn't handed one that dies during
  # the session it is opening.
  @token_skew_ms 60_000

  # The `:access_token` call's timeout, as seen from a worker Task: long
  # enough to cover one token-endpoint round trip (8s HTTP + 4s connect in
  # `Valea.Mail.OAuth`) plus queueing behind another caller's refresh, with
  # headroom. A timeout here is not a crash — `mint_access_token/1` degrades
  # to `""`.
  @token_call_timeout 30_000

  # The two AUTH failures a fresh IMAP credential clears (`set_credential/3`):
  # a rejected password and a rejected OAuth2 access token. Two states rather
  # than one because the resupply differs — a human re-types a password, an
  # OAuth flow mints a token — and the UI's copy has to say which.
  @auth_failure_statuses ["auth_failed", "reauth_required"]

  # The sticky statuses that PAUSE this account's background work until
  # `set_credential/3` or `readopt/1` clears them: the poll timer is not
  # re-armed, and no IDLE watcher is kept. Deliberately NOT part of
  # `validate_sync/1` — an explicit `sync_now/1` past an `auth_failed` is how a
  # caller retries, and only the automatic triggers back off.
  @paused_statuses @auth_failure_statuses ++ ["mailbox_replaced"]

  @typedoc """
  `credential` is `"present"` or `"missing"`; `state` is one of `"inactive"`,
  `"idle"`, `"syncing"`, `"auth_failed"`, `"reauth_required"`,
  `"identity_mismatch"`, `"mailbox_replaced"` — plain `String.t()` below
  because Elixir/Dialyzer typespecs don't support singleton-string (as opposed
  to singleton-atom) literal types.

  `"reauth_required"` is `"auth_failed"`'s OAuth2 twin (M6 task 15): the server
  refused the access token, so the account needs a fresh SIGN-IN rather than a
  re-typed password. It is sticky and pauses polling identically, and
  `set_credential/3` clears either one.

  `auth` is the account's SASL mode as a string (`"password"` | `"oauth2"`,
  M6 task 16) — the same value `config/mail.yaml` holds. It rides here because
  `credential` alone cannot tell the frontend WHICH keychain slot an account's
  secret lives in (`<slug>:imap` vs `<slug>:oauth`), nor whether "missing"
  means "type a password" or "sign in". A string, never `false`, so the
  falsy-map-field rule below does not apply to it.

  Three fields ride STRING keys — `"smtp_configured"` (boolean),
  `"smtp_credential"` (`"present"` | `"missing"` | `"n/a"`, the last when the
  account has no `smtp:` block at all), and `"notifications"` (boolean, the
  per-account OS-notification opt-in). That is the falsy-map-field rule
  documented in `Valea.Api.Mail`'s moduledoc: ash_typescript nulls an
  atom-keyed field whose value is `false` — at ANY depth in a typed map, not
  only the outermost one — and both booleans are `false` for every account
  that hasn't opted in. (The atom-keyed fields above predate the rule and
  reach the RPC through `mail_status`'s own stringification, which is why
  they still work.)
  """
  @type status :: %{
          :account => String.t(),
          :configured => boolean(),
          :credential => String.t(),
          :auth => String.t(),
          # The account's on-disk mail store (`<ws>/sources/mail/<slug>`) —
          # the ownership signature the settings card shows; absolute,
          # because the frontend is deliberately workspace-path-blind.
          :root => String.t(),
          :state => String.t(),
          :last_sync_at => String.t() | nil,
          :last_error => String.t() | nil,
          :username => String.t() | nil,
          :workspace_id => String.t() | nil,
          :pending_ops => non_neg_integer(),
          :held_folders => [String.t()],
          :backfill => %{String.t() => boolean()} | nil,
          :notices => [String.t()],
          :folders => %{String.t() => String.t()} | nil,
          optional(String.t()) => boolean() | String.t()
        }

  @doc """
  The `{:via, Registry, ...}` name a slug's Engine is registered under.

  The key is the account SLUG ALONE, not `{workspace_id, slug}` — safe only
  because `Valea.Workspace.Manager` serializes workspace open/close through
  its own GenServer, and `do_close/1` terminates the previous workspace's
  Runtime (and with it every Engine) SYNCHRONOUSLY before a new open starts.
  Two workspaces therefore never have a live Engine for the same slug at the
  same time. If that invariant ever changes (concurrent workspaces, an
  overlapping open), this key MUST grow the workspace id — otherwise the
  second workspace's Engine collides with the first's registration and its
  account silently never starts.
  """
  @spec via(String.t()) :: {:via, Registry, {Valea.Mail.Registry, String.t()}}
  def via(slug) when is_binary(slug), do: {:via, Registry, {Valea.Mail.Registry, slug}}

  def start_link(%{account: slug} = cfg),
    do: GenServer.start_link(__MODULE__, cfg, name: via(slug))

  @doc "Current status for `slug`, or `nil` when no Engine is running for it."
  @spec status(String.t()) :: status() | nil
  def status(slug) do
    case whereis(slug) do
      nil -> nil
      pid -> GenServer.call(pid, :status)
    end
  end

  @doc "Every currently-running Engine's status, keyed by account slug."
  @spec statuses() :: %{String.t() => status()}
  def statuses do
    slugs_and_pids()
    |> Map.new(fn {slug, pid} -> {slug, GenServer.call(pid, :status)} end)
  end

  @doc """
  Stores `secret` in `slug`'s `kind` credential slot (RAM only, never logged)
  and broadcasts the updated status. `kind` defaults to `:imap`, so the
  2-arity call means exactly what it always meant.

  For `:imap`: if the Engine had paused on `auth_failed`/`reauth_required`,
  this clears it and re-arms polling — the next poll tick runs a pass; this
  call never starts one itself. For `:smtp` it only fills the send-side slot: SMTP has no poll
  loop to re-arm, and an SMTP auth failure never pauses the IMAP sync.

  `:oauth` is the OAuth2 REFRESH token (moduledoc §OAuth2 accounts): it takes
  the same posture as `:imap` — the watcher is rebuilt, a sticky auth failure
  is cleared, polling re-arms — and additionally drops any cached access
  token, since one minted from a superseded refresh token is not this
  account's credential any more. It is how a restart's keychain resupply
  hands the token back; a NEWLY authorized one goes through
  `store_oauth_refresh_token/2` instead, which also asks the frontend to
  persist it.

  Every kind bumps `credential_epoch` (moduledoc §Credential epoch).
  `{:error, :not_found}` when no Engine is running for `slug`.
  """
  @spec set_credential(String.t(), String.t(), :imap | :smtp | :oauth) ::
          :ok | {:error, :not_found}
  def set_credential(slug, secret, kind \\ :imap)
      when is_binary(slug) and is_binary(secret) and kind in [:imap, :smtp, :oauth] do
    case whereis(slug) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, {:set_credential, secret, kind})
    end
  end

  @doc """
  Starts an OAuth2 authorization for `slug`: mints the `state` + PKCE pair,
  parks them as this account's ONE pending flow (TTL-bounded, replacing any
  earlier one), and returns the provider's consent URL for the caller to open
  in the user's browser.

  Refuses rather than guessing: `:not_oauth` for an account whose settings
  don't say `auth: oauth2` (a refresh token it will never use is not worth
  storing), `:oauth_unsupported` for a host with no provider preset, and
  `:oauth_not_configured` when neither the account nor this build supplies a
  public client id (see `Valea.Mail.OAuth`'s resolution order).

  The verifier stays in this process until the matching callback claims it.
  """
  @spec start_oauth(String.t()) ::
          {:ok, String.t()}
          | {:error,
             :not_found
             | :not_configured
             | :not_oauth
             | :oauth_unsupported
             | :oauth_not_configured}
  def start_oauth(slug) when is_binary(slug) do
    case whereis(slug) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, :start_oauth)
    end
  end

  @doc """
  Redeems the `state` token an OAuth2 redirect arrived with: finds the Engine
  whose pending flow it belongs to and hands that flow over
  (`Valea.Mail.OAuth.flow/0` — account, provider, client id, redirect URI and
  PKCE verifier), CONSUMING it in the process.

  Single-use and TTL-bounded by construction: a matched flow is removed from
  its Engine whether or not it was still valid, so a replayed redirect finds
  nothing. Comparison is constant-time (`Plug.Crypto.secure_compare/2`) and
  the flow is inherently bound to the account that minted it — there is one
  slot per Engine, so a state token cannot be redeemed against a different
  account.

  `{:error, :no_flow}` when nothing matches, `{:error, :expired}` when the
  matching flow had aged out (still consumed).
  """
  @spec claim_oauth_flow(String.t()) :: {:ok, OAuth.flow()} | {:error, :no_flow | :expired}
  def claim_oauth_flow(state) when is_binary(state) do
    Enum.find_value(slugs_and_pids(), {:error, :no_flow}, fn {_slug, pid} ->
      case safe_claim(pid, state) do
        {:error, :no_flow} -> nil
        found -> found
      end
    end)
  end

  # An Engine can exit between the registry read and this call (a workspace
  # close, a crash): that is "no flow here", never a 500 on the callback.
  defp safe_claim(pid, state) do
    GenServer.call(pid, {:claim_oauth_flow, state})
  catch
    :exit, _reason -> {:error, :no_flow}
  end

  @doc """
  Stores a freshly authorized refresh token: the RAM-only slot (via
  `set_credential/3`'s `:oauth` kind) plus the `mail_oauth` push that asks
  the frontend to persist it in the OS keychain — the only durable home a
  refresh token has, since this side never writes one to disk.

  Used by the callback controller on a successful code exchange, and by this
  Engine itself when a provider ROTATES the token on refresh (Microsoft does
  on every one). A push that no client is listening for is simply lost, which
  costs exactly one re-sign-in after the next restart.
  """
  @spec store_oauth_refresh_token(String.t(), String.t()) :: :ok | {:error, :not_found}
  def store_oauth_refresh_token(slug, token) when is_binary(slug) and is_binary(token) do
    with :ok <- set_credential(slug, token, :oauth) do
      broadcast_oauth_token(slug, token)
      :ok
    end
  end

  @doc """
  The access token for an oauth2 account, minted or cached — what the
  credential closures this Engine hands its workers actually call, from
  INSIDE those workers, at their one `connect/3` boundary.

  Always returns a binary, because that is the closure contract every
  consumer was written against (`SyncPass`, `OpsExecutor`, `IdleWatcher`,
  `Doctor`): a token that cannot be minted is `""`, which the server refuses
  like any other bad credential. Raising instead would turn one transient
  token-endpoint hiccup into a crashed pass Task, and returning `nil` would
  make `Valea.Mail.Xoauth2.response/2`'s callers handle a shape they have no
  clause for.

  An empty answer is never left to be interpreted as "this account's sign-in
  is broken" on its own: whatever made the mint fail has already recorded
  itself in this Engine's state (a cleared slot and a sticky
  `reauth_required` for `invalid_grant`, a bumped `credential_epoch` for a
  transient failure), so the resulting auth failure is classified correctly —
  see the moduledoc, §Credential epoch.
  """
  @spec mint_access_token(pid()) :: String.t()
  def mint_access_token(engine) when is_pid(engine) do
    case GenServer.call(engine, :access_token, @token_call_timeout) do
      {:ok, token} -> token
      {:error, _reason} -> ""
    end
  catch
    # The Engine died, or the refresh outlived the call timeout. Either way
    # there is no token to hand over, and the caller must not crash.
    :exit, _reason -> ""
  end

  @doc """
  Triggers a sync pass immediately (in a monitored `Task`). Refuses when the
  Engine hasn't activated yet, has no usable settings, has no credential, or
  is sticky-blocked on a `mailbox_replaced` reset. A no-op `:ok` when a pass
  is already running (single-flight).
  """
  @spec sync_now(String.t()) ::
          :ok | {:error, :not_configured | :no_credential | :inactive | :not_found | :blocked}
  def sync_now(slug) do
    case whereis(slug) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, :sync_now)
    end
  end

  @doc """
  The IDLE watcher's sync trigger (`Valea.Mail.IdleWatcher`): the server
  announced INBOX activity, so run a pass if this account currently can.

  A `cast`, unlike `sync_now/1`'s call, and deliberately so — the watcher is
  a child of this Engine's own supervisor, and the Engine terminates it from
  inside its own loop; a synchronous trigger would put a call in the one
  direction that can deadlock against that. Nothing awaits the outcome
  either: the pass broadcasts its own `mail_sync_started`/`mail_sync_finished`
  exactly as a polled one does.

  Internally identical to a poll tick — the same `validate_sync/1` gate and
  the same single-flighting — so a trigger arriving while a pass or an ops
  batch is in flight is a no-op, and one arriving for an
  inactive/uncredentialed/blocked account does nothing at all.
  """
  @spec idle_activity(pid()) :: :ok
  def idle_activity(engine) when is_pid(engine), do: GenServer.cast(engine, :idle_activity)

  @doc """
  Authorizes exactly one reconciliation pass past a sticky `mailbox_replaced`
  block (see the moduledoc): writes the one-shot `.readopt` marker, clears
  the sticky state, and re-arms polling. `{:error, :not_blocked}` when `slug`
  isn't currently blocked; `{:error, :not_found}` when no Engine is running
  for it.
  """
  @spec readopt(String.t()) :: :ok | {:error, :not_found | :not_blocked}
  def readopt(slug) do
    case whereis(slug) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, :readopt)
    end
  end

  @doc """
  Runs the mail connection doctor (mail design spec, §Account setup +
  doctor) — `Valea.Mail.Doctor.run/1` against a snapshot of `slug`'s
  settings/credential/transport. Never errors on the doctor's own account:
  an inactive/unconfigured/uncredentialed Engine, an unreachable server, or
  a bad password are all *reported* as checks, not raised. `{:error,
  :not_found}` when no Engine is running for `slug`. The snapshot is
  fetched via a fast `GenServer.call` (mirroring `status/1`); the actual
  network probing that follows runs in the calling process, never inside
  the Engine's own loop.
  """
  @spec doctor(String.t()) ::
          {:ok, %{checks: [Doctor.check()], ok: boolean}} | {:error, :not_found}
  def doctor(slug) do
    case whereis(slug) do
      nil -> {:error, :not_found}
      pid -> Doctor.run(GenServer.call(pid, :doctor_ctx))
    end
  end

  @doc """
  Connects and creates whichever of the account's configured special folders
  are currently missing on `slug`'s server — the doctor panel's "Create
  special folders" action. Guarded exactly like `sync_now/1`. Same
  non-blocking shape as `doctor/1`.
  """
  @spec create_folders(String.t()) ::
          {:ok, [String.t()]}
          | {:error, :inactive | :not_configured | :no_credential | :not_found | term()}
  def create_folders(slug) do
    case whereis(slug) do
      nil ->
        {:error, :not_found}

      pid ->
        case GenServer.call(pid, :doctor_ctx_gated) do
          {:ok, ctx} -> Doctor.create_folders(ctx)
          {:error, _reason} = error -> error
        end
    end
  end

  @doc """
  Executes RPC-originated declared ops (the Mail UI's archive/move/flag
  actions), serialized through this account's Engine (spec §RPC surface —
  `mail_apply_ops`). Runs in a monitored `Task`, STRICTLY serialized against
  sync passes and other ops batches (see the moduledoc, §RPC declared ops): it
  connects, reconciles any in-flight ops, runs the same `Valea.Mail.OpsExecutor`
  core as the ops-file push phase (origin `"rpc"`), and returns the per-op
  results array. From the caller's view this is synchronous — the reply is
  deferred until the task finishes, but blocks nothing in the Engine loop
  meanwhile. Gated exactly like `sync_now/1`. `{:error, reason}` when the
  account can't run; `{:error, :not_found}` when no Engine is running for
  `slug`.
  """
  @spec apply_ops(String.t(), [map()]) ::
          {:ok, [map()]}
          | {:error, :inactive | :not_configured | :no_credential | :blocked | :not_found}
  def apply_ops(slug, ops) when is_binary(slug) and is_list(ops) do
    case whereis(slug) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, {:apply_ops, ops}, 60_000)
    end
  end

  @doc """
  Pushes a reviewed draft to the account's Drafts folder — the low-trust
  half of the two user-initiated outbound actions (spec §Drafting & push;
  the transmitting half is `send_draft/4`, and both are reachable only from
  an explicit human click).
  The atomic claim + hash-verified snapshot + compose + fsynced spool run
  synchronously in the Engine loop (all local, no network) — so a concurrent
  double-push sees the first op instead of creating a second — and only the
  idempotent APPEND rides the Engine's single serialized work slot, exactly
  like a sync pass or an ops batch (never a second concurrent connection).
  Returns `{:ok, display_state}` (`"pushing"` | `"pushed"` | `"needs_review"`
  | `"rejected"`); `{:error, reason}` on a gate failure or a pre-append
  rejection (`content_changed`, `status_forged`, `invalid_draft`,
  `not_found`, `invalid_draft_name`). `{:error, :not_found}` when no Engine
  is running for `slug`.
  """
  @spec push_draft(String.t(), String.t(), String.t()) ::
          {:ok, String.t()}
          | {:error,
             :inactive
             | :not_configured
             | :no_credential
             | :blocked
             | :not_found
             | String.t()}
  def push_draft(slug, draft_name, content_hash)
      when is_binary(slug) and is_binary(draft_name) and is_binary(content_hash) do
    case whereis(slug) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, {:push_draft, draft_name, content_hash}, 60_000)
    end
  end

  @doc """
  THE atomic review snapshot behind the send confirm modal (spec G §RPC
  surface): a `GenServer.call` so the parse, the threading resolution, and
  the review fingerprint are all derived from ONE no-follow read under the
  SAME captured `state.settings` the send will later be checked against.
  Read-only — it claims nothing and never touches the network.
  """
  @spec draft_review(String.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found | String.t()}
  def draft_review(slug, draft_name) when is_binary(slug) and is_binary(draft_name) do
    case whereis(slug) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, {:draft_review, draft_name})
    end
  end

  @doc """
  Transmits a reviewed draft over SMTP — the one action in this codebase that
  cannot be undone (spec G §Send pipeline). Human-only by construction: it is
  reachable solely from the control-token-gated RPC surface.

  Settings pinning is an invariant, not an implementation detail: the review
  fingerprint check, the atomic claim, the snapshot, and the wire/record
  composition all happen synchronously in THIS `handle_call`, against the one
  captured `state.settings` — so a settings edit either restarts the Engine
  before the call (and the new Engine refuses the stale fingerprint) or
  arrives after it (and the message composes entirely under the settings the
  human reviewed). Only the transmit + Sent copy ride the serialized work
  slot, exactly like a push.

  A transmit that has to WAIT for that slot is answered `{:ok, "sending"}`
  immediately, before it runs (see `enqueue_send_work/3`): the op is already
  durable, so the alternative is a caller timing out — on the one
  irreversible action — for a message that is on its way.

  `{:ok, display_state}` (`"sending"` | `"send_review"` | `"sent"` |
  `"rejected"`); `{:error, reason}` on a gate failure or a pre-transmit
  refusal (`re_review_required`, `content_changed`, `draft_too_large`,
  `status_forged`, `invalid_draft`, `not_found`, `invalid_draft_name`).
  """
  @spec send_draft(String.t(), String.t(), String.t(), String.t() | nil) ::
          {:ok, String.t()}
          | {:error,
             :inactive
             | :not_configured
             | :smtp_not_configured
             | :no_smtp_credential
             | :blocked
             | :not_found
             | String.t()}
  def send_draft(slug, draft_name, content_hash, review_fingerprint)
      when is_binary(slug) and is_binary(draft_name) and is_binary(content_hash) do
    case whereis(slug) do
      nil ->
        {:error, :not_found}

      pid ->
        GenServer.call(pid, {:send_draft, draft_name, content_hash, review_fingerprint}, 60_000)
    end
  end

  @doc """
  Applies the human's verdict to a send parked in `send_review` (spec G
  §Send pipeline 4): `:sent` runs the idempotent Sent copy and completes the
  op, `:not_sent` rejects it and reverts the draft. Never transmits — it
  rides the same serialized work slot only because the Sent copy needs IMAP.
  """
  @spec resolve_send_review(String.t(), String.t(), :sent | :not_sent) ::
          :ok
          | {:error, :inactive | :not_configured | :blocked | :not_found | :not_reviewable}
  def resolve_send_review(slug, op_id, resolution)
      when is_binary(slug) and is_binary(op_id) and resolution in [:sent, :not_sent] do
    case whereis(slug) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, {:resolve_send_review, op_id, resolution}, 60_000)
    end
  end

  @doc """
  Re-runs ONLY the idempotent Sent-copy append of a send that completed with
  a `sent_copy_failed` notice. The mail is already transmitted; this can
  never reach the SMTP transport.

  `:ok` only when the copy is actually filed. `{:error, :sent_copy_deferred}`
  when the mailbox couldn't be reached (or the search couldn't be answered)
  and nothing was filed — the retry stays available.
  """
  @spec retry_sent_copy(String.t(), String.t()) ::
          :ok
          | {:error,
             :inactive
             | :not_configured
             | :blocked
             | :not_found
             | :not_retryable
             | :sent_copy_deferred}
  def retry_sent_copy(slug, op_id) when is_binary(slug) and is_binary(op_id) do
    case whereis(slug) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, {:retry_sent_copy, op_id}, 60_000)
    end
  end

  defp whereis(slug), do: GenServer.whereis(via(slug))

  defp slugs_and_pids do
    Registry.select(Valea.Mail.Registry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
  end

  # -- GenServer --------------------------------------------------------------

  @impl true
  def init(cfg) do
    # Trap exits so the sync task can be LINKED (not just monitored):
    # linking makes it die with this Engine when Runtime tears it down on a
    # workspace switch — a monitored-only task blocked in :ssl.recv would
    # otherwise outlive the Engine and write the old workspace's rows into the
    # new one. Trapping turns a linked task's crash into a handled `{:EXIT, _,
    # _}` message rather than killing the Engine; the paired monitor still
    # drives result/cleanup (see `handle_info` below).
    Process.flag(:trap_exit, true)
    Phoenix.PubSub.subscribe(Valea.PubSub, "workspace")

    # The IDLE watcher's supervisor (moduledoc §IMAP IDLE). Anonymous on
    # purpose — one per Engine, reachable only through this state, so two
    # accounts (or two workspace generations) can never collide over a name.
    # Started even for an Engine that will never have a watcher: it costs one
    # idle process and keeps every later start/stop decision in one place.
    {:ok, idle_sup} = DynamicSupervisor.start_link(strategy: :one_for_one)

    state = %{
      root: cfg.root,
      generation: cfg.generation,
      account: cfg.account,
      settings: Map.get(cfg, :settings),
      transport: Application.get_env(:valea, :mail_transport, Valea.Mail.ImapClient),
      # Pinned at init exactly like `transport` (and unlike `doctor_ctx/1`'s
      # on-demand resolution): an in-flight send must not have the transport
      # swapped under it mid-op.
      smtp_transport: Application.get_env(:valea, :mail_smtp_transport, Valea.Mail.SmtpClient),
      connect_opts: Map.get(cfg, :connect_opts, []),
      active: false,
      credential: nil,
      # The SEND-side secret, a slot of its own (spec G §Credentials) — same
      # zero-arity-closure discipline as `credential`, never the same value
      # by construction.
      smtp_credential: nil,
      # OAuth2 (moduledoc §OAuth2 accounts). All four are `nil`/empty for a
      # password account and never consulted for one.
      #   * `oauth_refresh` — the refresh token, RAM-only closure, this
      #     account's durable credential (persisted only in the OS keychain,
      #     frontend-side);
      #   * `oauth_token` — `%{token: closure, expires_at: monotonic_ms}`, the
      #     cached access token minted from it;
      #   * `oauth_task`/`oauth_waiters` — the single in-flight refresh Task
      #     and the callers parked on its one result (the `ops_queue`
      #     deferred-reply shape);
      #   * `oauth_pending` — the ONE in-flight authorization's `state` +
      #     PKCE verifier + provider/client id/redirect URI, with a TTL.
      oauth_refresh: nil,
      oauth_token: nil,
      oauth_task: nil,
      oauth_waiters: [],
      oauth_pending: nil,
      # Moduledoc §Credential epoch: which generation of credential material
      # this Engine considers current, and which one the in-flight pass was
      # started under. An auth failure from a pass whose pin has gone stale
      # cannot park the account.
      credential_epoch: 0,
      pass_credential_epoch: 0,
      # Pinned at activation from `.account` (moduledoc §Maildir separator).
      # `nil` until then — deliberately not `":"`, so a separator that ever
      # escaped into an encode would raise rather than write `:` names into a
      # `;` store. Every path that can reach one is behind `validate_sync/1`,
      # which requires BOTH `active` and non-nil `settings` — and the one
      # activation that skips the `.account` read (`activate(%{settings:
      # nil})`, the defensive no-settings clause) is exactly what that second
      # condition excludes.
      separator: nil,
      status: "inactive",
      last_sync_at: nil,
      last_error: nil,
      workspace_id: nil,
      poll_timer: nil,
      sync_task: nil,
      # RPC ops execution — the single in-flight ops Task (`%{task: {pid, ref},
      # from:, ops:}`) plus a FIFO queue of deferred `apply_ops` callers waiting
      # behind whatever background work (a pass or an earlier ops batch) is
      # currently running. See the moduledoc, §RPC declared ops.
      ops_current: nil,
      ops_queue: [],
      pass_readopt_authorized: false,
      notices: [],
      # IMAP IDLE (moduledoc §IMAP IDLE): the watcher's supervisor, and the
      # `{pid, monitor_ref}` of the one watcher under it — `nil` whenever this
      # account has no watcher, including after one exited on its own (a
      # server without the IDLE capability), which the monitor is what tells
      # us.
      idle_sup: idle_sup,
      idle_watcher: nil
    }

    if Map.get(cfg, :activate, false) do
      {:ok, state, {:continue, :activate_now}}
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_continue(:activate_now, state), do: {:noreply, activate(state)}

  @impl true
  def handle_call(:status, _from, state), do: {:reply, build_status(state), state}

  # Internal — `Valea.Mail.Supervisor.reload_settings_all/1`'s own rehash
  # diff, not part of this module's public interface.
  def handle_call(:current_settings, _from, state), do: {:reply, state.settings, state}

  def handle_call({:set_credential, secret, :imap}, _from, state) do
    new_state =
      state
      # REBUILT, not left alone: any watcher already running is holding a
      # connection it authenticated with the PREVIOUS secret, which a rotation
      # has to invalidate (moduledoc §IMAP IDLE).
      |> stop_idle_watcher()
      |> Map.put(:credential, fn -> secret end)
      |> bump_credential_epoch()
      |> clear_auth_failure()
      |> sync_idle_watcher()

    broadcast_status(new_state)
    {:reply, :ok, new_state}
  end

  def handle_call({:set_credential, secret, :smtp}, _from, state) do
    new_state = state |> Map.put(:smtp_credential, fn -> secret end) |> bump_credential_epoch()
    broadcast_status(new_state)
    {:reply, :ok, new_state}
  end

  # The OAuth2 refresh token (moduledoc §OAuth2 accounts). Same posture as
  # `:imap` — it IS this account's IMAP credential, one indirection removed —
  # plus dropping the cached access token: one minted from a superseded
  # refresh token is no longer this account's credential.
  def handle_call({:set_credential, secret, :oauth}, _from, state) do
    new_state =
      state
      |> stop_idle_watcher()
      |> Map.merge(%{oauth_refresh: fn -> secret end, oauth_token: nil})
      |> bump_credential_epoch()
      |> clear_auth_failure()
      |> sync_idle_watcher()

    broadcast_status(new_state)
    {:reply, :ok, new_state}
  end

  # Mints (or replaces) this account's ONE pending authorization. An earlier
  # unfinished flow is dropped rather than kept alongside: the user just asked
  # to sign in again, and two live state tokens for one account would only
  # widen the window in which either is redeemable.
  def handle_call(:start_oauth, _from, state) do
    case build_oauth_flow(state) do
      {:ok, pending, url} -> {:reply, {:ok, url}, %{state | oauth_pending: pending}}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  # The redirect's `state` token, compared CONSTANT-TIME against this
  # account's pending flow. A match consumes the flow either way (single use),
  # so a replay — or a retry of a redemption that already spent it — finds
  # nothing; an aged-out match is consumed and reported `:expired`.
  def handle_call({:claim_oauth_flow, candidate}, _from, %{oauth_pending: pending} = state)
      when pending != nil do
    if Plug.Crypto.secure_compare(pending.state, candidate) do
      consumed = %{state | oauth_pending: nil}

      if pending.expires_at > now_ms() do
        {:reply, {:ok, flow_context(state.account, pending)}, consumed}
      else
        {:reply, {:error, :expired}, consumed}
      end
    else
      {:reply, {:error, :no_flow}, state}
    end
  end

  def handle_call({:claim_oauth_flow, _candidate}, _from, state),
    do: {:reply, {:error, :no_flow}, state}

  # The access-token mint, called from inside a worker's credential closure
  # (`mint_access_token/1`). NEVER blocks this loop: it answers from cache, or
  # refuses outright, or parks the caller behind the ONE refresh Task —
  # single-flight, so N concurrent consumers cost one token request.
  def handle_call(:access_token, from, state) do
    case {cached_access_token(state), state.oauth_task} do
      {token, _task} when is_binary(token) ->
        {:reply, {:ok, token}, state}

      {nil, task} when task != nil ->
        {:noreply, %{state | oauth_waiters: [from | state.oauth_waiters]}}

      {nil, nil} ->
        case oauth_refresh_args(state) do
          {:ok, args} -> {:noreply, start_oauth_refresh(state, args, from)}
          :error -> {:reply, {:error, :reauth_required}, state}
        end
    end
  end

  def handle_call(:sync_now, _from, state) do
    case validate_sync(state) do
      :ok -> {:reply, :ok, start_pass_unless_running(state)}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  # RPC declared ops — strictly serialized against sync passes and other ops
  # batches (moduledoc §RPC declared ops). Gated like `sync_now`; on a gate
  # failure it replies immediately. Otherwise the reply is DEFERRED: the batch
  # either starts its own Task now (if no background work is in flight) or is
  # QUEUED behind the running pass/ops task — never run inline in the Engine
  # loop, so `status`/`sync_now`/`:poll` stay responsive throughout.
  def handle_call({:apply_ops, ops}, from, state) do
    case validate_sync(state) do
      :ok ->
        if busy?(state) do
          {:noreply, %{state | ops_queue: state.ops_queue ++ [%{from: from, ops: ops}]}}
        else
          {:noreply, start_ops_task(state, from, ops)}
        end

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  # Push-to-Drafts (spec §Drafting & push). The LOCAL claim+snapshot+compose+
  # spool runs synchronously here (handle_call is serial, so a concurrent
  # second push sees the first's claim → `:duplicate`); only the network
  # APPEND is deferred to the serialized work slot (own Task, or QUEUED behind
  # in-flight work), its reply deferred until the append resolves. Gated like
  # `sync_now`.
  def handle_call({:push_draft, draft_name, content_hash}, from, state) do
    case validate_sync(state) do
      :ok ->
        # `separator` is here even though nothing about a push WRITES to the
        # maildir: `prepare_push`'s threading resolution reads the replied-to
        # message's canonical file, and when that file is missing the lookup
        # falls back to ENCODING its name. Omitting the key made that fallback
        # raise a KeyError straight through the designed "compose unthreaded"
        # degradation (a `with/else` catches values, not raises) and into the
        # blanket rescue as a generic `push_failed`.
        local_ctx = %{
          root: state.root,
          account: state.account,
          settings: state.settings,
          separator: state.separator
        }

        case safe_prepare_push(local_ctx, draft_name, content_hash) do
          {:ok, op_row} ->
            if busy?(state) do
              entry = %{from: from, push: {op_row.id, draft_name}}
              {:noreply, %{state | ops_queue: state.ops_queue ++ [entry]}}
            else
              {:noreply, start_push_task(state, from, op_row.id, draft_name)}
            end

          {:duplicate, display} ->
            {:reply, {:ok, display}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  # Send (spec G §Send pipeline). Same shape as `push_draft` above — and the
  # shape IS the invariant: fingerprint check, claim, snapshot and composition
  # all run HERE, inline, under this one captured `state.settings`. Only the
  # transmit + Sent copy are deferred to the serialized work slot.
  def handle_call({:send_draft, draft_name, content_hash, review_fingerprint}, from, state) do
    case validate_send(state) do
      :ok ->
        local_ctx = %{root: state.root, account: state.account, settings: state.settings}

        case safe_prepare_send(local_ctx, draft_name, content_hash, review_fingerprint) do
          {:ok, op_row} ->
            enqueue_send_work(state, from, {:send, op_row.id})

          {:duplicate, display} ->
            {:reply, {:ok, display}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  # The human's verdict on a parked send, and the Sent-copy retry: both are
  # ledger acts that WANT IMAP (for the Sent copy) but never require it, and
  # neither can reach SMTP — so they take the weaker send-side gate and ride
  # the work slot only because the append must not race a pass.
  def handle_call({:resolve_send_review, op_id, resolution}, from, state) do
    case validate_active(state) do
      :ok -> enqueue_send_work(state, from, {:resolve, op_id, resolution})
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call({:retry_sent_copy, op_id}, from, state) do
    case validate_active(state) do
      :ok -> enqueue_send_work(state, from, {:retry, op_id})
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  # Read-only and local: answered inline, under the same captured settings a
  # subsequent `send_draft` will be checked against.
  def handle_call({:draft_review, draft_name}, _from, state) do
    {:reply, safe_review_snapshot(state, draft_name), state}
  end

  def handle_call(:readopt, _from, %{status: "mailbox_replaced"} = state) do
    :ok = Account.authorize_readopt!(state.root, state.account)
    new_state = %{state | status: "idle"} |> schedule_poll() |> sync_idle_watcher()
    broadcast_status(new_state)
    {:reply, :ok, new_state}
  end

  def handle_call(:readopt, _from, state), do: {:reply, {:error, :not_blocked}, state}

  # Doctor never gates: it must report on exactly why an inactive/
  # unconfigured/uncredentialed Engine can't connect, not refuse to run.
  def handle_call(:doctor_ctx, _from, state), do: {:reply, doctor_ctx(state), state}

  # create_folders DOES gate, same as sync_now — it needs a real connection
  # to create anything.
  def handle_call(:doctor_ctx_gated, _from, state) do
    case validate_sync(state) do
      :ok -> {:reply, {:ok, doctor_ctx(state)}, state}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  # The IDLE watcher's trigger (`idle_activity/1`) — the poll tick's own gated
  # path, reached by cast so the watcher never blocks on this loop.
  @impl true
  def handle_cast(:idle_activity, state), do: {:noreply, maybe_start_pass(state)}

  @impl true
  def handle_info({:workspace_opened, _info, generation}, %{generation: generation} = state) do
    {:noreply, activate(state)}
  end

  def handle_info({:workspace_opened, _info, _other_generation}, state), do: {:noreply, state}

  # `auth_failed`/`reauth_required`/`mailbox_replaced` pause polling: no re-arm until
  # `set_credential/2`/`readopt/1` clears them (see moduledoc §Errors /
  # §mailbox_replaced stickiness).
  def handle_info(:poll, %{status: status} = state)
      when status in @paused_statuses do
    {:noreply, %{state | poll_timer: nil}}
  end

  def handle_info(:poll, state), do: {:noreply, state |> maybe_start_pass() |> schedule_poll()}

  # A pass Task reported its result: flush the pending :DOWN, apply it, then
  # start any ops batch that queued behind the pass.
  def handle_info({:sync_result, pid, result}, %{sync_task: {pid, ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, state |> finish_pass(result) |> drain_ops()}
  end

  # The pass Task crashed before reporting (SyncPass returns tuples, so this
  # is an unexpected raise/exit) — treat it as a failed pass, not a wedge.
  def handle_info({:DOWN, ref, :process, pid, reason}, %{sync_task: {pid, ref}} = state) do
    {:noreply, state |> finish_pass({:error, {:sync_task_down, reason}}) |> drain_ops()}
  end

  # An ops Task reported its per-op results: flush the pending :DOWN, reply to
  # the deferred caller, then start the next queued batch (if any).
  def handle_info(
        {:ops_result, pid, results},
        %{ops_current: %{task: {pid, ref}, from: from}} = state
      ) do
    Process.demonitor(ref, [:flush])
    GenServer.reply(from, {:ok, results})
    {:noreply, %{state | ops_current: nil} |> drain_ops()}
  end

  # The ops Task died before reporting (its own core rescues, so this is an
  # unexpected raise/exit or a teardown kill) — reply with per-op rejections so
  # the deferred caller never hangs, then drain the queue.
  def handle_info(
        {:DOWN, ref, :process, pid, _reason},
        %{ops_current: %{task: {pid, ref}, from: from, ops: ops}} = state
      ) do
    GenServer.reply(from, {:ok, reject_all_ops(ops, "execution_error")})
    {:noreply, %{state | ops_current: nil} |> drain_ops()}
  end

  # A push Task reported its final display state: flush the pending :DOWN,
  # reply to the deferred caller, then start the next queued work (if any).
  def handle_info(
        {:push_result, pid, display},
        %{ops_current: %{task: {pid, ref}, from: from, push: _push}} = state
      ) do
    Process.demonitor(ref, [:flush])
    GenServer.reply(from, {:ok, display})
    {:noreply, %{state | ops_current: nil} |> drain_ops()}
  end

  # The push Task died before reporting (its own core rescues, so this is an
  # unexpected raise/exit or a teardown kill). The op is durable — a `pending`
  # spool survives, reconciled by the next pass — so reply `"pushing"` rather
  # than hang the caller, then drain.
  def handle_info(
        {:DOWN, ref, :process, pid, _reason},
        %{ops_current: %{task: {pid, ref}, from: from, push: _push}} = state
      ) do
    GenServer.reply(from, {:ok, "pushing"})
    {:noreply, %{state | ops_current: nil} |> drain_ops()}
  end

  # A send-family Task reported: reply to the deferred caller verbatim (a send
  # returns `{:ok, display}`, a resolve/retry `:ok`/`{:error, _}`), then drain.
  def handle_info(
        {:send_work_result, pid, reply},
        %{ops_current: %{task: {pid, ref}, from: from, send_work: _work}} = state
      ) do
    Process.demonitor(ref, [:flush])
    maybe_reply(from, reply)
    {:noreply, %{state | ops_current: nil} |> drain_ops()}
  end

  # The send-family Task died before reporting. Everything it was doing is
  # durable in the ledger — a transmitted op resumes its Sent copy, a parked
  # one waits for its human — so reply rather than hang the caller. A send op
  # STILL `pending` here never reached the transport (the transmit transitions
  # out of `pending` first), and nothing else would resolve it before the next
  # activation, so it is terminated exactly like a dropped queue entry; an op
  # at-or-past DATA is refused by `abandon_send/2` and left to recovery.
  def handle_info(
        {:DOWN, ref, :process, pid, _reason},
        %{ops_current: %{task: {pid, ref}, from: from, send_work: work}} = state
      ) do
    maybe_reply(from, abandon_dropped(state, work))
    {:noreply, %{state | ops_current: nil} |> drain_ops()}
  end

  # The single-flight token refresh reported (moduledoc §OAuth2 accounts).
  def handle_info(
        {:oauth_refresh_result, pid, result},
        %{oauth_task: %{task: {pid, ref}, epoch: epoch}} = state
      ) do
    Process.demonitor(ref, [:flush])
    {:noreply, apply_refresh_result(state, result, epoch)}
  end

  # The refresh Task died before reporting (an unexpected raise, or a teardown
  # kill). `Valea.Mail.OAuth` answers its own failures as tuples, so this is
  # transient by definition — never a reason to throw the refresh token away.
  def handle_info(
        {:DOWN, ref, :process, pid, _reason},
        %{oauth_task: %{task: {pid, ref}, epoch: epoch}} = state
      ) do
    {:noreply, apply_refresh_result(state, {:error, :token_request_failed}, epoch)}
  end

  # The IDLE watcher is gone. Either it stopped `:normal` on its own (the
  # server doesn't advertise IDLE — a permanent answer, never retried) or its
  # supervisor gave up on restarting it. Both mean "this account has no
  # watcher"; clearing the slot is all this Engine does about it. It must NOT
  # start a replacement here: a normal exit is final by design, and re-racing
  # a broken one would be the crash loop the supervisor just stopped.
  def handle_info({:DOWN, ref, :process, pid, _reason}, %{idle_watcher: {pid, ref}} = state) do
    {:noreply, %{state | idle_watcher: nil}}
  end

  # Stale task chatter (already handled/superseded): ignore.
  def handle_info({:sync_result, _pid, _result}, state), do: {:noreply, state}
  def handle_info({:send_work_result, _pid, _reply}, state), do: {:noreply, state}
  def handle_info({:ops_result, _pid, _results}, state), do: {:noreply, state}
  def handle_info({:push_result, _pid, _display}, state), do: {:noreply, state}
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  # A LINKED sync task exited (normal completion or crash). Because the
  # Engine traps exits, the exit signal arrives here as a message; the paired
  # monitor's `:DOWN` (matched above) is what actually drives result handling
  # and single-flight cleanup, so the `{:EXIT, _, _}` is intentionally a no-op.
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  # -- OAuth2: authorization flow + access-token minting --------------------
  #
  # Moduledoc §OAuth2 accounts. Everything in this section runs in the Engine
  # loop EXCEPT the token request itself, which rides a monitored+linked Task
  # exactly like a sync pass.

  # `:start_oauth`'s decision. Refuses in three distinguishable ways rather
  # than handing back a URL that cannot end in a working account.
  defp build_oauth_flow(%{settings: nil}), do: {:error, :not_configured}

  defp build_oauth_flow(%{settings: %Settings{auth: auth}}) when auth != :oauth2,
    do: {:error, :not_oauth}

  defp build_oauth_flow(%{settings: settings}) do
    with {:ok, provider} <- oauth_provider(settings),
         {:ok, client_id} <- oauth_client_id(settings) do
      pkce = OAuth.new_pkce()
      state_token = OAuth.new_state()
      redirect_uri = OAuth.redirect_uri()

      pending = %{
        state: state_token,
        verifier: pkce.verifier,
        provider: provider,
        client_id: client_id,
        redirect_uri: redirect_uri,
        expires_at: now_ms() + @oauth_flow_ttl_ms
      }

      url =
        OAuth.authorize_url(provider, %{
          client_id: client_id,
          redirect_uri: redirect_uri,
          state: state_token,
          challenge: pkce.challenge,
          # Only pre-fills the provider's account chooser. It is the mailbox
          # address the user already typed into the setup form, so it reveals
          # nothing to the provider it isn't about to learn anyway.
          login_hint: settings.imap.username
        })

      {:ok, pending, url}
    end
  end

  defp oauth_provider(settings) do
    case OAuth.provider_for(settings) do
      nil -> {:error, :oauth_unsupported}
      provider -> {:ok, provider}
    end
  end

  defp oauth_client_id(settings) do
    case OAuth.client_id_for(settings) do
      nil -> {:error, :oauth_not_configured}
      client_id -> {:ok, client_id}
    end
  end

  # What a claiming callback receives: the account this flow was minted for
  # (so it can store the resulting token) plus everything the code exchange
  # needs. The `state` token itself is deliberately left behind — it has
  # already done its whole job.
  defp flow_context(account, pending) do
    %{
      account: account,
      provider: pending.provider,
      client_id: pending.client_id,
      redirect_uri: pending.redirect_uri,
      verifier: pending.verifier
    }
  end

  # The cached access token, or `nil` when there is none or it is close enough
  # to expiry that a session opened with it could outlive it.
  defp cached_access_token(%{oauth_token: %{token: fun, expires_at: expires_at}})
       when is_function(fun, 0) do
    if expires_at - now_ms() > @token_skew_ms, do: fun.(), else: nil
  end

  defp cached_access_token(_state), do: nil

  # The refresh request's parameters, or `:error` when this account cannot
  # mint at all (no refresh token, no provider preset, no client id) — each of
  # which means "sign in again", not "retry later".
  defp oauth_refresh_args(%{oauth_refresh: nil}), do: :error
  defp oauth_refresh_args(%{settings: nil}), do: :error

  defp oauth_refresh_args(%{settings: settings} = state) do
    with {:ok, provider} <- oauth_provider(settings),
         {:ok, client_id} <- oauth_client_id(settings) do
      {:ok,
       %{
         provider: provider,
         client_id: client_id,
         refresh_token: resolve_secret(state.oauth_refresh)
       }}
    else
      {:error, _reason} -> :error
    end
  end

  # One refresh, one Task, every caller parked on its result. LINKED as well
  # as monitored for the same reason a pass is: an in-flight HTTPS POST
  # carrying this account's refresh token must die with the Engine rather than
  # outlive a workspace teardown. The epoch is pinned so a result that lands
  # after the credential was replaced underneath is discarded instead of
  # overwriting the newer one.
  defp start_oauth_refresh(state, args, from) do
    parent = self()

    task =
      spawn_linked_task(fn ->
        send(parent, {:oauth_refresh_result, self(), OAuth.refresh(args)})
      end)

    %{
      state
      | oauth_task: %{task: task, epoch: state.credential_epoch},
        oauth_waiters: [from]
    }
  end

  # A result for credential material this Engine no longer holds (a
  # `set_credential/3` landed while the request was in flight). Caching it
  # would serve a token minted from a superseded refresh token, and acting on
  # its `invalid_grant` would throw away the NEWER token that replaced it —
  # so it is dropped entirely and the parked callers retry against the current
  # state.
  defp apply_refresh_result(%{credential_epoch: current} = state, _result, pinned)
       when current != pinned do
    state |> Map.put(:oauth_task, nil) |> reply_oauth_waiters({:error, :superseded})
  end

  defp apply_refresh_result(state, {:ok, tokens}, _pinned) do
    token = tokens.access_token

    %{
      state
      | oauth_task: nil,
        oauth_token: %{token: fn -> token end, expires_at: now_ms() + tokens.expires_in * 1_000}
    }
    |> reply_oauth_waiters({:ok, token})
    |> rotate_refresh_token(tokens.refresh_token)
  end

  # The one PERMANENT failure: this refresh token will never mint again, so
  # the cache and the slot both go, and the account is parked `reauth_required`
  # right here rather than after a pointless round trip to the mail server
  # with an empty token.
  defp apply_refresh_result(state, {:error, :invalid_grant}, _pinned) do
    %{state | oauth_task: nil, oauth_token: nil, oauth_refresh: nil}
    |> bump_credential_epoch()
    |> reply_oauth_waiters({:error, :reauth_required})
    |> park_reauth_required()
  end

  # Transient (network, 5xx, a malformed response, the Task dying): the
  # refresh token is KEPT. The epoch bump is what marks the `""` the parked
  # callers are about to hand their servers as material this Engine does not
  # stand behind — so the auth failure it produces cannot park the account
  # (moduledoc §Credential epoch).
  defp apply_refresh_result(state, {:error, _transient}, _pinned) do
    %{state | oauth_task: nil}
    |> bump_credential_epoch()
    |> reply_oauth_waiters({:error, :token_request_failed})
  end

  defp reply_oauth_waiters(state, reply) do
    Enum.each(state.oauth_waiters, &GenServer.reply(&1, reply))
    %{state | oauth_waiters: []}
  end

  # A provider that rotated the refresh token (Microsoft does on every
  # refresh) has just invalidated the one in the keychain: store the new one
  # and push it so the frontend replaces it, or the next restart resupplies a
  # dead token. A provider that didn't (Google) sends `nil` and nothing moves.
  defp rotate_refresh_token(state, nil), do: state

  defp rotate_refresh_token(state, token) do
    if resolve_secret(state.oauth_refresh) == token do
      state
    else
      broadcast_oauth_token(state.account, token)
      %{state | oauth_refresh: fn -> token end} |> bump_credential_epoch()
    end
  end

  # The sticky park for "this account needs a new authorization", reachable
  # WITHOUT a pass having failed (an `invalid_grant` at refresh time). It
  # deliberately touches only the status/poll/watcher triple — never
  # `sync_task` — because a pass may well still be in flight, and
  # `finish_pass/2` owns that slot.
  defp park_reauth_required(state) do
    cancel_timer(state.poll_timer)

    %{state | status: "reauth_required", poll_timer: nil, last_error: "sign-in expired"}
    |> sync_idle_watcher()
    |> tap_broadcast_status()
  end

  # The `mail_oauth` push (moduledoc §OAuth2 accounts): the ONE place a secret
  # travels outward from this process, and it exists because the frontend's OS
  # keychain is the refresh token's only durable home. Broadcast, never
  # logged; `ValeaWeb.WorkspaceEventsChannel` relays it to the desktop client
  # over the loopback socket.
  defp broadcast_oauth_token(slug, token) do
    Phoenix.PubSub.broadcast(Valea.PubSub, "mail", {:mail_oauth_token, slug, token})
  end

  defp bump_credential_epoch(state),
    do: %{state | credential_epoch: state.credential_epoch + 1}

  defp now_ms, do: System.monotonic_time(:millisecond)

  # -- RPC ops execution --------------------------------------------------

  # True whenever ANY background work is in flight (a sync pass OR an ops
  # batch) — the single mutual-exclusion gate that keeps passes and ops from
  # ever running concurrently against the same mailbox/ledger.
  defp busy?(state), do: state.sync_task != nil or state.ops_current != nil

  # Starts one ops batch in a LINKED + monitored Task (same lifecycle as a sync
  # pass — see `spawn_linked_task/1`), pinning `{from, ops}` so the result
  # handler can reply to the deferred caller. The credential closure travels
  # into the Task and is only ever called there, at `connect/3`.
  defp start_ops_task(state, from, ops) do
    parent = self()

    args = %{
      root: state.root,
      account: state.account,
      settings: state.settings,
      transport: state.transport,
      connect_opts: state.connect_opts,
      credential: imap_credential(state),
      separator: state.separator
    }

    task =
      spawn_linked_task(fn -> send(parent, {:ops_result, self(), run_rpc_ops(args, ops)}) end)

    %{state | ops_current: %{task: task, from: from, ops: ops}}
  end

  # `prepare_push` runs INLINE in handle_call (the claim must be serial with
  # the loop) but does bang I/O + DB writes that can raise on a transient
  # failure (disk full, `database is locked`). `prepare_push` guards itself;
  # this wrapper is defense-in-depth at the one call site inside the Engine
  # loop — a raise here would fell the Engine, and a supervisor restart erases
  # the RAM-only credential closure, silently stopping the account.
  defp safe_prepare_push(local_ctx, draft_name, content_hash) do
    OpsExecutor.prepare_push(local_ctx, draft_name, content_hash)
  rescue
    _error -> {:error, "push_failed"}
  catch
    :exit, _reason -> {:error, "push_failed"}
  end

  # Starts the NETWORK half of a push (the idempotent APPEND) in the same
  # LINKED + monitored Task lifecycle as an ops batch — the local claim/spool
  # already ran in the Engine loop, so this only connects and runs
  # `OpsExecutor.execute_append/2` for the already-`pending` op.
  defp start_push_task(state, from, op_id, draft_name) do
    parent = self()

    args = %{
      root: state.root,
      account: state.account,
      settings: state.settings,
      transport: state.transport,
      connect_opts: state.connect_opts,
      credential: imap_credential(state),
      separator: state.separator
    }

    task =
      spawn_linked_task(fn -> send(parent, {:push_result, self(), run_push(args, op_id)}) end)

    %{state | ops_current: %{task: task, from: from, push: {op_id, draft_name}}}
  end

  # -- send execution ------------------------------------------------------

  # `prepare_send` guards itself; this is the same defense-in-depth wrapper
  # `safe_prepare_push/3` is, at the one call site inside the Engine loop.
  defp safe_prepare_send(local_ctx, draft_name, content_hash, review_fingerprint) do
    OpsExecutor.prepare_send(local_ctx, draft_name, content_hash, review_fingerprint)
  rescue
    _error -> {:error, "send_failed"}
  catch
    :exit, _reason -> {:error, "send_failed"}
  end

  defp safe_review_snapshot(state, draft_name) do
    OpsExecutor.review_snapshot(
      %{root: state.root, account: state.account, settings: state.settings},
      draft_name
    )
  rescue
    _error -> {:error, "review_failed"}
  catch
    :exit, _reason -> {:error, "review_failed"}
  end

  # Send-family work (transmit, resolve, Sent-copy retry) shares ONE task
  # shape: it either starts now or queues behind whatever holds the slot —
  # never run inline, so the Engine loop keeps answering
  # `status`/`sync_now`/`:poll` throughout. A work slot that is free means the
  # caller's reply is deferred until the task reports, verbatim.
  defp enqueue_send_work(state, from, work) do
    if busy?(state) do
      queue_send_work(state, from, work)
    else
      {:noreply, start_send_work_task(state, from, work)}
    end
  end

  # A QUEUED transmit is answered now, not when it drains. By the time we get
  # here `prepare_send` has claimed the draft, spooled the wire bytes and
  # stamped the ledger: the op is durable and WILL transmit when the slot
  # frees — the very argument `send_work_fallback({:send, _})` already makes
  # for a task that dies. Holding the reply instead means a long sync pass
  # times the caller out and the UI says "could not send" about a message
  # that is on its way, on the one action nobody can take back. The entry
  # queues with `from: nil` so the drain (or a drop, or a DOWN) never replies
  # a second time; its outcome still reaches the UI through the ledger-derived
  # draft display state. Resolve/retry are unchanged — neither is
  # irreversible, and both are cheap enough to answer truthfully.
  defp queue_send_work(state, from, {:send, _op_id} = work) do
    GenServer.reply(from, {:ok, "sending"})
    {:noreply, %{state | ops_queue: state.ops_queue ++ [%{from: nil, send_work: work}]}}
  end

  defp queue_send_work(state, from, work) do
    {:noreply, %{state | ops_queue: state.ops_queue ++ [%{from: from, send_work: work}]}}
  end

  # `nil` is a caller that has ALREADY been answered (a queued transmit, above).
  # Every side effect on the path still runs; only the duplicate reply is
  # skipped.
  defp maybe_reply(nil, _reply), do: :ok
  defp maybe_reply(from, reply), do: GenServer.reply(from, reply)

  defp start_send_work_task(state, from, work) do
    parent = self()

    args = %{
      root: state.root,
      account: state.account,
      settings: state.settings,
      transport: state.transport,
      connect_opts: state.connect_opts,
      credential: imap_credential(state),
      smtp_transport: state.smtp_transport,
      smtp_credential: smtp_credential(state)
    }

    task =
      spawn_linked_task(fn ->
        send(parent, {:send_work_result, self(), run_send_work(args, work)})
      end)

    %{state | ops_current: %{task: task, from: from, send_work: work}}
  end

  # Runs INSIDE the send Task. Both credential closures are resolved ONCE,
  # here, before any work: for an oauth2 account calling one MINTS a token
  # (moduledoc §OAuth2 accounts), so the resolved values are threaded down as
  # arguments rather than re-resolved — a `resolve_secret/1` in the rescue
  # below would fire a token request in the middle of handling a failure, and
  # `rescue` cannot see bindings made in the body it guards.
  defp run_send_work(args, work) do
    run_send_work(
      args,
      work,
      resolve_secret(args.credential),
      resolve_secret(args.smtp_credential)
    )
  end

  # The IMAP connection is opened up front and is OPTIONAL: it exists only for
  # the Sent copy, so an unreachable mailbox must never stop a transmit — it
  # only leaves the op `transmitted` for the next connected pass to file.
  defp run_send_work(args, work, imap_secret, smtp_secret) do
    conn = connect_for_send(args, imap_secret)

    try do
      apply_send_work(send_ctx(args, conn, smtp_secret), work)
    after
      if conn, do: safe_logout(args.transport, conn)
    end
  rescue
    # Same reasoning as `run_push/2`: the executor answers its own failures as
    # tuples, so a raise here is a wiring bug that must reach the log rather
    # than dissolve into a display string. Scrubbed of both secrets.
    e ->
      Logger.error(
        Redact.text(
          Redact.text(
            "mail send failed (account #{args.account}, work #{inspect(work)}): " <>
              Exception.format(:error, e, __STACKTRACE__),
            smtp_secret
          ),
          imap_secret
        )
      )

      send_work_fallback(work)
  catch
    :exit, _ -> send_work_fallback(work)
  end

  defp send_ctx(args, conn, smtp_secret) do
    %{
      root: args.root,
      account: args.account,
      settings: args.settings,
      transport: args.transport,
      conn: conn,
      smtp_transport: args.smtp_transport,
      smtp_credential: smtp_secret
    }
  end

  defp apply_send_work(ctx, {:send, op_id}),
    do: {:ok, send_display(OpsExecutor.execute_send(ctx, op_id))}

  defp apply_send_work(ctx, {:resolve, op_id, resolution}),
    do: OpsExecutor.resolve_send_review(ctx, op_id, resolution)

  defp apply_send_work(ctx, {:retry, op_id}), do: OpsExecutor.retry_sent_copy(ctx, op_id)

  defp send_display(:ok), do: "sent"
  defp send_display({:sending, _notice}), do: "sending"
  defp send_display({:send_review, _reason}), do: "send_review"
  defp send_display({:rejected, _reason}), do: "rejected"

  # What to answer when the task never reported: the send op is durable and
  # in flight (`"sending"`), and a resolve/retry simply hasn't been applied
  # yet — the next pass picks both up.
  defp send_work_fallback({:send, _op_id}), do: {:ok, "sending"}
  defp send_work_fallback(_resolve_or_retry), do: :ok

  # A send this Engine will NOT execute — its queue entry was dropped because
  # the account stopped being sendable while it waited, or its task died
  # before transmitting. Nothing else would ever resolve it: `recover_sends`
  # deliberately skips `pending` (a legitimately queued send is `pending` too,
  # and the difference is known exactly HERE), and the classification pass
  # only runs at activation — so the op would hold the draft's claim, stuck
  # rendering `sending`, until the app restarted. Terminate it: a dropped
  # entry is provably un-transmitted, and `abandon_send/2` re-checks that
  # against the op's own state before touching it.
  defp abandon_dropped(state, {:send, op_id}) do
    case safe_abandon_send(state, op_id) do
      :ok -> {:ok, "rejected"}
      {:error, _reason} -> send_work_fallback({:send, op_id})
    end
  end

  # Only the DOWN path reaches this clause (a dropped resolve/retry entry goes
  # through `dropped_entry_reply/2` instead): the task DID run, so the work may
  # well have landed before it died — unlike a drop, where the executor was
  # never called at all.
  defp abandon_dropped(_state, resolve_or_retry), do: send_work_fallback(resolve_or_retry)

  defp safe_abandon_send(state, op_id) do
    OpsExecutor.abandon_send(
      %{root: state.root, account: state.account, settings: state.settings},
      op_id
    )
  rescue
    # Runs in the Engine loop: a Store failure here must never fell the
    # Engine. The op stays `pending` and the next activation classifies it.
    _error -> {:error, :not_abandonable}
  catch
    :exit, _reason -> {:error, :not_abandonable}
  end

  # A connection is a bonus here, never a precondition (see `run_send_work/2`).
  # `secret` arrives already resolved — a parameter, so the rescue can see it,
  # and so an oauth2 account mints its token once per Task, not once per use.
  defp connect_for_send(args, secret) do
    case args.transport.connect(Settings.imap_config(args.settings), secret, args.connect_opts) do
      {:ok, conn} -> conn
      {:error, _reason} -> nil
    end
  rescue
    e ->
      Logger.error(
        Redact.text(
          "mail send: IMAP connect raised (account #{args.account}, Sent copy deferred): " <>
            Exception.format(:error, e, __STACKTRACE__),
          secret
        )
      )

      nil
  catch
    :exit, _ -> nil
  end

  # After a pass / ops batch / push finishes: if nothing is in flight and
  # callers are queued, start the next one. Re-validates each queued caller at
  # drain time (the account may have become blocked meanwhile) — an ops caller
  # that no longer passes the gate is replied the error; a push caller (its op
  # already durable as `pending`) is replied `"pushing"` and reconciled later.
  defp drain_ops(state) do
    cond do
      busy?(state) ->
        state

      state.ops_queue == [] ->
        state

      true ->
        [entry | rest] = state.ops_queue
        drain_entry(%{state | ops_queue: rest}, entry)
    end
  end

  defp drain_entry(state, %{from: from, ops: ops}) do
    case validate_sync(state) do
      :ok ->
        start_ops_task(state, from, ops)

      {:error, _reason} = error ->
        GenServer.reply(from, error)
        drain_ops(state)
    end
  end

  defp drain_entry(state, %{from: from, push: {op_id, draft_name}}) do
    case validate_sync(state) do
      :ok ->
        start_push_task(state, from, op_id, draft_name)

      {:error, _reason} ->
        GenServer.reply(from, {:ok, "pushing"})
        drain_ops(state)
    end
  end

  defp drain_entry(state, %{from: from, send_work: work}) do
    case validate_send_work(state, work) do
      :ok ->
        start_send_work_task(state, from, work)

      {:error, _reason} ->
        maybe_reply(from, dropped_entry_reply(state, work))
        drain_ops(state)
    end
  end

  # A queue entry the Engine will NEVER run, because the account stopped being
  # sendable/active while it waited. A send still has to be TERMINATED (its op
  # is durable and holds the draft's claim). A resolve/retry has no durable
  # half at all — the executor was never called, so nothing was reviewed and
  # nothing was filed — and must say so rather than borrow the send-side
  # fallback's `:ok`, which would report success for work that provably did
  # not happen.
  defp dropped_entry_reply(state, {:send, _op_id} = work), do: abandon_dropped(state, work)
  defp dropped_entry_reply(_state, {:resolve, _op_id, _resolution}), do: {:error, :not_reviewable}
  defp dropped_entry_reply(_state, {:retry, _op_id}), do: {:error, :not_retryable}

  defp validate_send_work(state, {:send, _op_id}), do: validate_send(state)
  defp validate_send_work(state, _resolve_or_retry), do: validate_active(state)

  # Connects and runs the idempotent APPEND for the already-`pending` push op,
  # returning its final display state. A connect failure leaves the durable
  # `pending` op for the next pass — reply `"pushing"`. Runs INSIDE the push
  # Task, never in the Engine loop.
  # `secret` is resolved once in the 2-arity head below and threaded in as a
  # parameter for the same two reasons `run_send_work/4` does it (a `rescue`
  # sees parameters but not body bindings, and resolving an oauth2 closure
  # MINTS).
  defp run_push(args, op_id), do: run_push(args, op_id, resolve_secret(args.credential))

  defp run_push(args, op_id, secret) do
    case args.transport.connect(Settings.imap_config(args.settings), secret, args.connect_opts) do
      {:ok, conn} ->
        try do
          ctx = %{
            root: args.root,
            account: args.account,
            settings: args.settings,
            transport: args.transport,
            conn: conn,
            separator: args.separator
          }

          push_display(OpsExecutor.execute_append(ctx, op_id))
        after
          safe_logout(args.transport, conn)
        end

      {:error, _reason} ->
        "pushing"
    end
  rescue
    # The executor answers its OWN failures as `{:rejected, _}`/
    # `{:needs_review, _}`, so anything RAISED here is unexpected — a wiring
    # bug like the cross-account op-id guard in `OpsExecutor.execute_append/2`,
    # or a malformed settings map. The op is durable either way, so the caller
    # still gets `"pushing"` and the next pass reconciles; but without this log
    # the raise would dissolve into that display string and the push would
    # retry every pass forever with nothing anywhere to explain it. Scrubbed:
    # an exception message can quote whatever was passed to `connect/3`.
    e ->
      Logger.error(
        Redact.text(
          "mail push failed (account #{args.account}, op #{op_id}): " <>
            Exception.format(:error, e, __STACKTRACE__),
          secret
        )
      )

      "pushing"
  catch
    :exit, _ -> "pushing"
  end

  defp push_display(:ok), do: "pushed"
  defp push_display({:needs_review, _reason}), do: "needs_review"
  defp push_display({:rejected, _reason}), do: "rejected"

  # Connects, reconciles in-flight ops, then runs the executor's per-op core
  # against the RPC-supplied raw ops. Always returns a per-op results list;
  # a connect failure maps every op to a `connect_failed` rejection so the
  # RPC's frozen results-array shape stays populated. Runs INSIDE the ops Task,
  # never in the Engine loop.
  defp run_rpc_ops(args, ops) do
    case args.transport.connect(
           Settings.imap_config(args.settings),
           resolve_secret(args.credential),
           args.connect_opts
         ) do
      {:ok, conn} ->
        try do
          ctx = %{
            root: args.root,
            account: args.account,
            settings: args.settings,
            transport: args.transport,
            conn: conn,
            separator: args.separator
          }

          OpsExecutor.recover(ctx)
          OpsExecutor.apply_raw_ops(ctx, ops, "rpc")
        after
          safe_logout(args.transport, conn)
        end

      {:error, _reason} ->
        reject_all_ops(ops, "connect_failed")
    end
  rescue
    # An executor/transport failure must never crash the Task and hang the
    # deferred caller: degrade to per-op rejections so the RPC's frozen
    # results-array shape is always returned.
    _ -> reject_all_ops(ops, "execution_error")
  catch
    :exit, _ -> reject_all_ops(ops, "execution_error")
  end

  defp resolve_secret(fun) when is_function(fun, 0), do: fun.()
  defp resolve_secret(_credential), do: nil

  # -- credential resolution (the one place the auth mode picks a slot) ------
  #
  # Every worker/probe this Engine hands a credential to goes through these
  # two, so a password account and an oauth2 one cannot diverge on one path
  # and agree on another. Both return the SAME zero-arity-closure shape (or
  # `nil` for "this account has no credential"), which is why nothing
  # downstream had to learn about tokens.

  defp imap_credential(state) do
    case account_auth(state) do
      :password -> state.credential
      :oauth2 -> oauth_credential(state)
    end
  end

  # One authorization covers both protocols, so an oauth2 account's send-side
  # credential is the same minted token — never a second secret.
  defp smtp_credential(state) do
    case account_auth(state) do
      :password -> state.smtp_credential
      :oauth2 -> oauth_credential(state)
    end
  end

  # `nil` until the account has a refresh token, so every `credential == nil`
  # gate (`validate_sync/1`, `validate_send/1`, the status field, the doctor's
  # `credential_present` check) keeps meaning exactly what it meant.
  defp oauth_credential(%{oauth_refresh: nil}), do: nil

  defp oauth_credential(_state) do
    # `self()` is the Engine: every caller of this function is an Engine
    # callback (a `handle_call`, a `handle_info`, or `activate/1`). The pid is
    # captured HERE rather than resolved inside the closure because the closure
    # runs in a worker Task, where `self()` would be that Task.
    engine = self()
    fn -> mint_access_token(engine) end
  end

  defp account_auth(%{settings: %Settings{auth: auth}}), do: auth
  defp account_auth(_state), do: :password

  defp credential_present?(state), do: imap_credential(state) != nil

  defp reject_all_ops(ops, reason) do
    ops
    |> Enum.with_index()
    |> Enum.map(fn {_op, index} ->
      %{"op" => index, "result" => "rejected", "reason" => reason}
    end)
  end

  defp safe_logout(transport, conn) do
    transport.logout(conn)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # -- activation ---------------------------------------------------------

  # Defensive: an Engine started with no settings at all (never constructed
  # by `Valea.Mail.Supervisor`, which only ever hands a real `Valea.Mail.Settings.t()`
  # to a valid account's child) still activates — poll timer armed, status
  # "idle" — since there's no identity to verify and no maildir to index;
  # it just has nothing to sync against, which `validate_sync/1`'s
  # `not_configured` gate reports.
  defp activate(%{settings: nil} = state) do
    new_state =
      %{state | active: true, status: "idle", workspace_id: load_workspace_id(state.root)}
      |> schedule_poll()

    broadcast_status(new_state)
    new_state
  end

  defp activate(state) do
    identity = %{host: state.settings.imap.host, username: state.settings.imap.username}

    case Account.verify(state.root, state.account, identity) do
      :absent ->
        :ok = Account.write_if_absent!(state.root, state.account, identity, new_store_separator())
        activate_with_separator(state)

      :ok ->
        activate_with_separator(state)

      {:error, :identity_mismatch} ->
        block_inert(state, nil)
    end
  end

  # The separator is read back from `.account` even for the slug we just
  # claimed: one code path, and the FILE — not this process's idea of the
  # host — is what every subsequent encode is bound to.
  defp activate_with_separator(state) do
    case Account.separator(state.root, state.account) do
      {:ok, separator} ->
        do_activate(%{state | separator: separator})

      {:error, :invalid_separator} ->
        block_inert(state, "invalid maildir_separator in .account")
    end
  end

  # The shared fail-closed activation outcome (moduledoc §Identity binding /
  # §Maildir separator): inert, never indexed, never synced, but still
  # answering `status/1` so the operator can see why.
  defp block_inert(state, last_error) do
    new_state = %{
      state
      | active: false,
        status: "identity_mismatch",
        last_error: last_error,
        workspace_id: load_workspace_id(state.root)
    }

    broadcast_status(new_state)
    new_state
  end

  # New stores only — an EXISTING `.account` is always authoritative over
  # the host (spec C1: absent field = legacy = `:`, never OS-defaulted).
  defp new_store_separator do
    case Valea.Paths.host_platform() do
      :windows -> ";"
      _ -> ":"
    end
  end

  defp do_activate(state) do
    # Engine-owned agent briefing at the account root, refreshed on every
    # activation so it always matches this app version's ops/draft grammar.
    # After the identity gate on purpose: a mismatched mailbox gets nothing.
    :ok = AgentsFile.materialize!(state.root, state.account)

    {:ok, _count} = Index.rebuild(state.root, state.account)

    # Spec G §Crash recovery: resolve every stranded send from the ledger +
    # manifests alone, BEFORE polling starts. Requires no network on purpose —
    # a send stranded pre-transmit must not stay blocked behind a paused or
    # failing IMAP sync (`OpsExecutor.recover/1`, which does need a
    # connection, only ever resumes a Sent copy or reconciles from here on).
    :ok =
      OpsExecutor.classify_sends_local(%{
        root: state.root,
        account: state.account,
        settings: state.settings
      })

    new_state =
      %{
        state
        | active: true,
          credential: state.credential || env_credential(state.account),
          smtp_credential: state.smtp_credential || smtp_env_credential(state.account),
          status: "idle",
          workspace_id: load_workspace_id(state.root)
      }
      |> schedule_poll()
      # After the credential slots are filled (an env-supplied credential
      # counts) — the gate reads `credential`, so this must come last.
      |> sync_idle_watcher()

    broadcast_status(new_state)
    new_state
  end

  # Snapshot of exactly the fields `Valea.Mail.Doctor` needs — the same
  # settings/credential/transport a sync pass would use, plus the account
  # slug (Doctor's `maildir_writable` check needs it to build the probe
  # path). Built inside a fast `handle_call` so the slow network probing
  # that consumes it always runs outside the Engine's own loop.
  defp doctor_ctx(state) do
    %{
      root: state.root,
      account: state.account,
      settings: state.settings,
      credential: imap_credential(state),
      transport: state.transport,
      # The send-side pair (spec G). The doctor only reaches these for a
      # sending account, and `check_auth/3` never issues MAIL FROM — running
      # the doctor can never enqueue a message. Resolved per call rather than
      # pinned into state at init: the doctor is an on-demand probe, so there
      # is nothing to keep stable across a run for it.
      smtp_transport: Application.get_env(:valea, :mail_smtp_transport, Valea.Mail.SmtpClient),
      smtp_credential: smtp_credential(state)
    }
  end

  # `config/workspace.yaml`'s persistent id (mail design spec, §Credentials —
  # keychain entries key on it). Read once, at activation, into state rather
  # than on every `status/1` call: `Scaffold.create/3` writes it once and it
  # stays stable across opens, so it never changes for the lifetime of an
  # activated Engine. `nil` on any absent/malformed file.
  defp load_workspace_id(root) do
    case YamlElixir.read_from_file(Path.join(root, "config/workspace.yaml")) do
      {:ok, %{"id" => id}} when is_binary(id) -> id
      _ -> nil
    end
  end

  defp env_credential(slug), do: wrap_secret(Settings.env_credential(slug))

  defp smtp_env_credential(slug),
    do: wrap_secret(Settings.smtp_env_credential(slug))

  defp wrap_secret(nil), do: nil
  defp wrap_secret(secret), do: fn -> secret end

  # -- sync gating ----------------------------------------------------------

  defp validate_sync(%{active: false}), do: {:error, :inactive}
  defp validate_sync(%{settings: nil}), do: {:error, :not_configured}
  defp validate_sync(%{status: "mailbox_replaced"}), do: {:error, :blocked}

  # `credential_present?/1`, not `state.credential`: for an oauth2 account the
  # credential is the refresh token in its own slot, and reading the password
  # slot here would report every signed-in oauth2 account as uncredentialed.
  defp validate_sync(state) do
    if credential_present?(state), do: :ok, else: {:error, :no_credential}
  end

  # The gate every SEND-side action shares. Deliberately weaker than
  # `validate_sync/1` in one respect: it does NOT require the IMAP
  # credential. Sending is an SMTP act, and resolving or retrying a Sent copy
  # is a ledger act — an account whose mailbox happens to be unreachable must
  # still be able to send and to clear a parked op; the Sent copy simply
  # files itself on the next connected pass.
  defp validate_active(%{active: false}), do: {:error, :inactive}
  defp validate_active(%{settings: nil}), do: {:error, :not_configured}
  defp validate_active(%{status: "mailbox_replaced"}), do: {:error, :blocked}
  defp validate_active(_state), do: :ok

  defp validate_send(state) do
    with :ok <- validate_active(state) do
      cond do
        not Settings.smtp_configured?(state.settings) ->
          {:error, :smtp_not_configured}

        smtp_credential(state) == nil ->
          {:error, :no_smtp_credential}

        true ->
          :ok
      end
    end
  end

  # -- IMAP IDLE watcher ----------------------------------------------------

  # Brings the watcher into line with the account's CURRENT ability to sync
  # (moduledoc §IMAP IDLE): started when `idle_wanted?/1` says yes and nothing
  # is running, stopped when it says no and something is. Idempotent, so every
  # lifecycle edge (activation, credential, auth failure, readopt) can call it
  # unconditionally.
  defp sync_idle_watcher(state) do
    case {idle_wanted?(state), state.idle_watcher} do
      {true, nil} -> start_idle_watcher(state)
      {false, {_pid, _ref}} -> stop_idle_watcher(state)
      _unchanged -> state
    end
  end

  # A watcher is wanted exactly when this account's AUTOMATIC triggers are: it
  # can sync at all (`validate_sync/1`) and its background work isn't paused on
  # a sticky failure (`@paused_statuses` — the same list the poll tick honors,
  # since an IDLE trigger would only produce passes that fail the same way).
  #
  # `:mail_idle` defaults ON. The switch exists so the suites that script a
  # transport call-for-call (and the doubles that report every connect to a
  # probe pid) aren't perturbed by a second, unrelated connection:
  # `config/test.exs` turns it off, and the IDLE tests turn it back on for
  # themselves.
  defp idle_wanted?(state) do
    Application.get_env(:valea, :mail_idle, true) and validate_sync(state) == :ok and
      state.status not in @paused_statuses
  end

  defp start_idle_watcher(state) do
    args = %{
      account: state.account,
      engine: self(),
      settings: state.settings,
      transport: state.transport,
      connect_opts: state.connect_opts,
      credential: imap_credential(state)
    }

    case safe_start_child(state.idle_sup, {IdleWatcher, args}) do
      {:ok, pid} -> %{state | idle_watcher: {pid, Process.monitor(pid)}}
      :error -> %{state | idle_watcher: nil}
    end
  end

  defp stop_idle_watcher(%{idle_watcher: nil} = state), do: state

  defp stop_idle_watcher(%{idle_watcher: {pid, ref}} = state) do
    # Demonitor BEFORE terminating: the `:DOWN` this shutdown produces is one
    # we caused, and letting it arrive would only re-clear a slot this call
    # already cleared — while a LATER watcher could have taken the slot in
    # between, and that stale `:DOWN` would then clear the wrong one.
    Process.demonitor(ref, [:flush])
    safe_terminate_child(state.idle_sup, pid)
    %{state | idle_watcher: nil}
  end

  # Both supervisor calls are guarded: `DynamicSupervisor` calls are
  # `GenServer.call`s, and one against a supervisor that has already given up
  # (its own restart intensity exceeded) EXITS the caller — here, the Engine,
  # in the middle of a `handle_call`. Losing IDLE must degrade to "still
  # polling", never take the account down (moduledoc §IMAP IDLE).
  defp safe_start_child(sup, child_spec) do
    case DynamicSupervisor.start_child(sup, child_spec) do
      {:ok, pid} -> {:ok, pid}
      {:ok, pid, _info} -> {:ok, pid}
      _other -> :error
    end
  rescue
    _error -> :error
  catch
    :exit, _reason -> :error
  end

  defp safe_terminate_child(sup, pid) do
    DynamicSupervisor.terminate_child(sup, pid)
    :ok
  rescue
    _error -> :ok
  catch
    :exit, _reason -> :ok
  end

  defp maybe_start_pass(state) do
    case validate_sync(state) do
      :ok -> start_pass_unless_running(state)
      {:error, _reason} -> state
    end
  end

  # Single-flight: only start a pass when NO background work is in flight —
  # neither another pass NOR an ops batch (they'd contend for the same
  # mailbox/ledger). A `sync_now`/poll landing while an ops task runs is a
  # no-op, exactly like a second `sync_now` during a pass.
  defp start_pass_unless_running(state) do
    if busy?(state), do: state, else: start_pass(state)
  end

  # Runs `SyncPass.run/1` in a LINKED + monitored process. The link ties the
  # task's lifetime to the Engine's: a Runtime teardown on a workspace switch
  # kills the Engine, which kills this task, so a pass blocked in :ssl.recv
  # can never survive to write the old workspace's data into the new one. The
  # Engine traps exits, so the task crashing is a handled message, not a
  # take-down; the monitor still delivers the result/`:DOWN` used for
  # single-flight tracking. The credential closure travels into the task and
  # is only ever called inside `SyncPass`, at the `connect/3` boundary.
  #
  # `readopt_authorized` is read fresh (the `.readopt` marker's presence)
  # right before the pass starts and pinned into `state.pass_readopt_authorized`
  # for `finish_pass/2` to consult — see moduledoc §mailbox_replaced.
  defp start_pass(state) do
    readopt_authorized = Account.readopt_authorized?(state.root, state.account)
    broadcast_event({:mail_sync_started, state.account})

    parent = self()

    args = %{
      root: state.root,
      account: state.account,
      settings: state.settings,
      credential: imap_credential(state),
      transport: state.transport,
      connect_opts: state.connect_opts,
      separator: state.separator,
      readopt_authorized: readopt_authorized
    }

    task = spawn_linked_task(fn -> send(parent, {:sync_result, self(), SyncPass.run(args)}) end)

    new_state = %{
      state
      | sync_task: task,
        status: "syncing",
        pass_readopt_authorized: readopt_authorized,
        # Pinned so `on_auth_failure/3` can tell an authoritative auth failure
        # from one reported by a pass whose credential has since been replaced
        # (moduledoc §Credential epoch).
        pass_credential_epoch: state.credential_epoch
    }

    broadcast_status(new_state)
    new_state
  end

  # Links first (so a task that dies before/at monitor time delivers its exit
  # to the trapping Engine, not a raise), then monitors — the `{pid, ref}`
  # pair the existing single-flight/`:DOWN` handling keys on.
  defp spawn_linked_task(fun) do
    pid = spawn_link(fun)
    ref = Process.monitor(pid)
    {pid, ref}
  end

  defp finish_pass(state, {:ok, result}) do
    new_messages = Map.get(result, :new_messages, 0)
    # The notification counter (`Valea.Mail.SyncPass`, §Result): newly landed
    # INBOX occurrences without `S`. Carried through `mail_sync_finished`
    # ADDITIVELY — every existing consumer keeps reading `new_messages`
    # unchanged, and only the new-mail notification path reads this one.
    new_unread = Map.get(result, :new_unread, 0)
    errors = Map.get(result, :errors, [])
    notices = Map.get(result, :notices, [])

    # The marker's job was to authorize exactly ONE successful pass past the
    # sticky block — clear it now that this pass reported success. A pass
    # that DIDN'T carry the authorization leaves nothing to clear.
    if state.pass_readopt_authorized, do: Account.clear_readopt!(state.root, state.account)

    broadcast_event(
      {:mail_sync_finished, state.account,
       %{new_messages: new_messages, new_unread: new_unread, errors: errors}}
    )

    %{
      state
      | sync_task: nil,
        status: "idle",
        last_sync_at: now_iso(),
        last_error: nil,
        pass_readopt_authorized: false,
        notices: notices
    }
    |> tap_broadcast_status()
  end

  defp finish_pass(state, {:error, :auth_failed}),
    do: on_auth_failure(state, "auth_failed", "authentication failed")

  # The OAuth2 twin (M6 task 15): the token was refused, so this pauses exactly
  # like `auth_failed` — and is cleared by the same `set_credential/3` — but
  # says so in its own words, because "authentication failed" would send the
  # user looking for a password to re-type.
  defp finish_pass(state, {:error, :reauth_required}),
    do: on_auth_failure(state, "reauth_required", "sign-in expired")

  defp finish_pass(state, {:error, :mailbox_replaced}) do
    cancel_timer(state.poll_timer)

    message =
      "the server's mailbox no longer matches local history — readopt or purge to continue"

    broadcast_event(
      {:mail_sync_finished, state.account, %{new_messages: 0, new_unread: 0, errors: [message]}}
    )

    %{
      state
      | sync_task: nil,
        status: "mailbox_replaced",
        poll_timer: nil,
        last_error: message,
        pass_readopt_authorized: false
    }
    # Sticky-blocked: polling is paused until `readopt/1`, and an IDLE trigger
    # would only produce passes this Engine refuses to run.
    |> sync_idle_watcher()
    |> tap_broadcast_status()
  end

  # `reason` is a connect failure or a `{:sync_task_down, _}` crash reason.
  # It is broadcast in `mail_sync_finished` AND stored as `last_error` (pushed
  # to the UI in every mail_status), so the credential must never survive into
  # it. `Redact.text/2` scrubs the secret (and its inspect-escaped form) out of
  # the built string as defense-in-depth behind the literal-LOGIN fix.
  defp finish_pass(state, {:error, reason}) do
    message = scrub_secrets(state, "sync failed: #{inspect(reason)}")

    broadcast_event(
      {:mail_sync_finished, state.account, %{new_messages: 0, new_unread: 0, errors: [message]}}
    )

    %{
      state
      | sync_task: nil,
        status: "idle",
        last_error: message,
        pass_readopt_authorized: false
    }
    |> tap_broadcast_status()
  end

  # Is this pass's auth verdict about the credential the Engine currently
  # holds? Only then may it make the account sticky (moduledoc §Credential
  # epoch). A mismatch means the secret was replaced, rotated, discarded or
  # unmintable while the pass ran, so its refusal says nothing about what is
  # in the slots NOW.
  defp on_auth_failure(
         %{credential_epoch: epoch, pass_credential_epoch: epoch} = state,
         status,
         message
       ),
       do: pause_on_auth_failure(state, status, message)

  defp on_auth_failure(state, _status, message), do: stale_auth_failure(state, message)

  # A pass that failed auth under superseded credential material. The error is
  # reported (it happened, and the user may want to see it), but the STATUS
  # decision is left to what the Engine knows now: back to `"idle"` with
  # polling re-armed if nothing else has parked the account, or the existing
  # park kept intact if something has — `invalid_grant` at refresh time parks
  # `reauth_required` directly, and this must not undo it.
  defp stale_auth_failure(state, message) do
    broadcast_event(
      {:mail_sync_finished, state.account, %{new_messages: 0, new_unread: 0, errors: [message]}}
    )

    status = if state.status in @paused_statuses, do: state.status, else: "idle"

    %{
      state
      | sync_task: nil,
        status: status,
        last_error: message,
        pass_readopt_authorized: false
    }
    |> rearm_unless_paused()
    |> sync_idle_watcher()
    |> tap_broadcast_status()
  end

  defp rearm_unless_paused(%{status: status} = state) when status in @paused_statuses, do: state
  defp rearm_unless_paused(state), do: schedule_poll(state)

  # The shared body of the two AUTH-failure outcomes above: pause polling, drop
  # the watcher, remember why. Both are STICKY — nothing re-arms until
  # `set_credential/3` supplies the secret they are waiting for.
  defp pause_on_auth_failure(state, status, message) do
    cancel_timer(state.poll_timer)

    broadcast_event(
      {:mail_sync_finished, state.account, %{new_messages: 0, new_unread: 0, errors: [message]}}
    )

    %{
      state
      | sync_task: nil,
        status: status,
        poll_timer: nil,
        last_error: message,
        pass_readopt_authorized: false
    }
    # The credential the watcher is holding is the one that just failed: its
    # own reconnects would hammer the server with the same bad secret.
    |> sync_idle_watcher()
    |> tap_broadcast_status()
  end

  # Scrubs EVERY secret this Engine currently holds out of an already-built
  # display string: the two password slots, the OAuth2 refresh token, and the
  # cached access token. Materialized only here (all four already live in this
  # process's state) and only to remove them — never stored, never returned.
  #
  # Deliberately reads the CACHED access token rather than resolving the
  # credential closures: for an oauth2 account those closures MINT, and
  # minting from inside an error path would fire a token request over a failed
  # sync.
  defp scrub_secrets(state, text) do
    [state.credential, state.smtp_credential, state.oauth_refresh, cached_token_closure(state)]
    |> Enum.reduce(text, fn slot, acc -> Redact.text(acc, resolve_secret(slot)) end)
  end

  defp cached_token_closure(%{oauth_token: %{token: fun}}), do: fun
  defp cached_token_closure(_state), do: nil

  defp tap_broadcast_status(state) do
    broadcast_status(state)
    state
  end

  defp now_iso, do: DateTime.utc_now() |> DateTime.to_iso8601()

  # Either AUTH failure state (a rejected password OR a rejected token) is
  # cleared by a fresh IMAP credential — the new secret is exactly what both
  # were waiting for.
  defp clear_auth_failure(%{status: status} = state) when status in @auth_failure_statuses do
    state |> Map.put(:status, "idle") |> schedule_poll()
  end

  defp clear_auth_failure(state), do: state

  # -- poll timer -----------------------------------------------------------

  @doc """
  Delay until the next poll: the account's configured interval PLUS a
  jitter, so the accounts of one workspace don't poll in lockstep.

  Every Engine is started by the same supervisor within milliseconds of its
  siblings, so a bare `interval * 60_000` would have N accounts open N
  connections at the same instant, forever — a self-inflicted thundering
  herd that grows with each mailbox added. The jitter is applied to EVERY
  scheduling (activation included), which is what actually spreads them out;
  re-jittering on each poll also keeps them from re-converging after a pass
  that ran long.

  Jitter is `0..min(60s, interval/4)` — bounded by a quarter of the interval
  so a short interval isn't dominated by it, and capped at a minute so a
  long one still polls when the user expects. `:mail_poll_jitter` overrides
  it with a fixed number of milliseconds (the test seam).
  """
  @spec poll_delay_ms(pos_integer()) :: pos_integer()
  def poll_delay_ms(interval_minutes)
      when is_integer(interval_minutes) and interval_minutes > 0 do
    interval_ms = interval_minutes * 60_000
    interval_ms + poll_jitter_ms(interval_ms)
  end

  defp poll_jitter_ms(interval_ms) do
    case Application.get_env(:valea, :mail_poll_jitter, :random) do
      fixed when is_integer(fixed) -> fixed
      _random -> :rand.uniform(min(@max_poll_jitter_ms, div(interval_ms, 4)) + 1) - 1
    end
  end

  defp schedule_poll(state) do
    cancel_timer(state.poll_timer)
    timer = Process.send_after(self(), :poll, poll_delay_ms(interval_minutes(state)))
    %{state | poll_timer: timer}
  end

  defp interval_minutes(%{settings: %{sync: %{interval_minutes: minutes}}}), do: minutes
  defp interval_minutes(_state), do: @default_interval_minutes

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref), do: Process.cancel_timer(ref)

  # -- status -----------------------------------------------------------

  defp build_status(%{settings: nil} = state) do
    %{
      account: state.account,
      configured: false,
      credential: if(credential_present?(state), do: "present", else: "missing"),
      auth: to_string(account_auth(state)),
      root: account_dir(state),
      state: state.status,
      last_sync_at: state.last_sync_at,
      last_error: state.last_error,
      username: nil,
      workspace_id: state.workspace_id,
      pending_ops: 0,
      held_folders: [],
      backfill: nil,
      notices: state.notices,
      folders: nil
    }
    |> Map.merge(smtp_status(state))
    |> Map.merge(notification_status(state))
  end

  defp build_status(state) do
    %{pending_ops: pending_ops, held_folders: held_folders, backfill: backfill} =
      store_snapshot(state.account)

    %{
      account: state.account,
      configured: true,
      credential: if(credential_present?(state), do: "present", else: "missing"),
      auth: to_string(account_auth(state)),
      root: account_dir(state),
      state: state.status,
      last_sync_at: state.last_sync_at,
      last_error: state.last_error,
      # The IMAP login, distinct from `account` (the slug) — surfaced for
      # display and the setup form; the frontend's OS-keychain entries are
      # keyed `workspace_id` / `<slug>:imap` (spec §Credentials), not on
      # this value.
      username: state.settings.imap.username,
      workspace_id: state.workspace_id,
      pending_ops: pending_ops,
      held_folders: held_folders,
      backfill: backfill,
      notices: state.notices,
      # The account's configured special-folder names (settings v4 defaults
      # or the provider profile) — the UI's archive/flag actions need the
      # real archive name (Gmail: "[Gmail]/All Mail", never "Archive") to
      # compose a valid move op. String keys: this map rides JSON both via
      # the RPC accounts array and the channel push.
      folders: %{
        "drafts" => state.settings.folders.drafts,
        "sent" => state.settings.folders.sent,
        "archive" => state.settings.folders.archive,
        "trash" => state.settings.folders.trash
      }
    }
    |> Map.merge(smtp_status(state))
    |> Map.merge(notification_status(state))
  end

  # The account's mail store on disk — the same `sources/mail/<slug>` join
  # every store/view module makes (`Valea.Mail.Account.account_path/2` et
  # al.), absolute off the workspace root this Engine was activated with.
  defp account_dir(state), do: Path.join([state.root, "sources", "mail", state.account])

  # Whether this account can send at all, and whether its SEND credential is
  # in RAM — `"n/a"` (not `"missing"`) for a push-only account, which has no
  # SMTP credential to be missing. String keys, per the falsy-map-field rule
  # in `Valea.Api.Mail`'s moduledoc: `smtp_configured` is `false` for every
  # push-only account, and an atom-keyed `false` is nulled by ash_typescript.
  defp smtp_status(state) do
    configured =
      state.settings != nil and Settings.smtp_configured?(state.settings)

    %{
      "smtp_configured" => configured,
      "smtp_credential" => smtp_credential_status(configured, smtp_credential(state))
    }
  end

  # The per-account OS-notification opt-in (`config/mail.yaml`'s
  # `notifications:`, default off) — the frontend's gate on raising a
  # notification for this account's `new_unread`. String key for the same
  # reason `smtp_configured` has one: it is `false` for every account that
  # hasn't opted in, and ash_typescript nulls a top-level atom-keyed `false`.
  defp notification_status(%{settings: nil}), do: %{"notifications" => false}

  defp notification_status(state), do: %{"notifications" => state.settings.notifications == true}

  defp smtp_credential_status(false, _credential), do: "n/a"
  defp smtp_credential_status(true, nil), do: "missing"
  defp smtp_credential_status(true, _credential), do: "present"

  # `status/1` must NEVER crash this GenServer, whatever state `Valea.Repo`
  # is in — a `handle_call` that raises takes the WHOLE Engine down (and
  # with it, e.g., an in-RAM credential nothing else holds a copy of), not
  # just this one call. The Repo is not a `Valea.Workspace.Runtime` child
  # (see `Valea.Cockpit`'s moduledoc for the exact close-ordering race), so
  # a `status/1` call landing in that narrow window must degrade to empty/
  # zero rather than propagate the failure.
  defp store_snapshot(account) do
    folders = Store.folders(account)

    %{
      pending_ops: account |> Store.pending_ops() |> length(),
      held_folders: folders |> Enum.filter(& &1.held) |> Enum.map(& &1.folder),
      backfill: Map.new(folders, &{&1.folder, &1.backfill_complete})
    }
  rescue
    _ -> %{pending_ops: 0, held_folders: [], backfill: %{}}
  catch
    :exit, _ -> %{pending_ops: 0, held_folders: [], backfill: %{}}
  end

  defp broadcast_status(state) do
    broadcast_event({:mail_status_changed, state.account, build_status(state)})
  end

  defp broadcast_event(event) do
    Phoenix.PubSub.broadcast(Valea.PubSub, "mail", event)
  end
end
