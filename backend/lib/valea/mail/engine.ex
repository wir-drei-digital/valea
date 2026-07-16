defmodule Valea.Mail.Engine do
  @moduledoc """
  Per-workspace mail sync GenServer (mail design spec, §Engine). State:
  `Settings` (from `config/mail.yaml`), credential (RAM only), sync status,
  poll timer.

  ## Activation gating

  `Valea.Workspace.Runtime`'s children start *before* the Manager runs the
  workspace migration (manager.ex order: repo → runtime → migrate →
  broadcast) — a v3-shaped `mail.yaml` may not exist yet at Runtime-start
  time even on an up-to-date workspace, and definitely doesn't on one being
  migrated in place. So `init/1` does **no file reads at all**: it only
  subscribes to the `"workspace"` PubSub topic and returns an inert state
  (`active: false`). The Engine activates — loads `Settings`, rebuilds the
  message index, starts the poll timer — only on the
  `{:workspace_opened, info, generation}` broadcast, which the Manager fires
  strictly after migration succeeds. A broadcast for any other generation
  (a stale open, or a switch that landed before this Engine's own open
  finished) is ignored; a rolled-back open just kills the still-inert
  Engine along with the rest of that `Runtime`.

  ## Credential handling

  The credential is process memory only — never written to disk, never
  logged, never part of the workspace. It is held as a **zero-arity
  closure** (`fn -> secret end`) rather than the raw string: `inspect/1` on
  a function value never renders its closed-over environment, so an
  operator inspecting this process's state (`:sys.get_state/1`, a crash
  dump, an ad hoc inspect of `state` while debugging) cannot see the secret
  by accident. Callers that need the raw value call the closure, not
  pattern-match into state.

  Two ways a credential arrives: the `mail_set_credential` RPC (via
  `set_credential/1`, wired to later tasks) or — dev-only, browser-mode
  fallback documented in the design spec's §Credentials — the
  `VALEA_MAIL_PASSWORD` env var, read once at activation and only if no
  credential has already been supplied.

  ## Sync passes

  A pass (`Valea.Mail.SyncPass.run/1`) runs in a monitored `Task`, triggered
  by the poll timer or `sync_now/0` (per the design spec, §Engine, its only
  two triggers). At most one runs at a time: the in-flight task's `{pid,
  ref}` is tracked in `state.sync_task`, so a second `sync_now` (or a poll
  tick) while syncing is a no-op that leaves the running pass untouched.
  Status shows `"syncing"` for the duration; the task's result flips it back
  to `"idle"` (or `"auth_failed"`) and broadcasts `mail_sync_finished`. The
  credential closure is handed to the task and only ever called inside
  `SyncPass` at the `transport.connect/3` boundary.

  ## Errors

  A pass returning `{:error, :auth_failed}` pauses the poll timer (no retry
  storm against a bad password) until `set_credential/1` supplies a new one,
  which clears the failure and re-arms polling. `set_credential/1` itself
  never starts a pass directly — it only re-arms the timer, and the next
  tick runs one.
  """
  use GenServer

  alias Valea.Mail.Doctor
  alias Valea.Mail.Index
  alias Valea.Mail.Redact
  alias Valea.Mail.Settings
  alias Valea.Mail.SyncPass

  @default_interval_minutes 5

  @typedoc """
  `credential` is `"present"` or `"missing"`; `state` is `"idle"`,
  `"inactive"`, `"syncing"`, or `"auth_failed"` — plain `String.t()` below
  because Elixir/Dialyzer typespecs don't support singleton-string
  (as opposed to singleton-atom) literal types.
  """
  @type status :: %{
          configured: boolean(),
          credential: String.t(),
          state: String.t(),
          last_sync_at: String.t() | nil,
          last_error: String.t() | nil,
          account: String.t() | nil,
          username: String.t() | nil,
          workspace_id: String.t() | nil
        }

  def start_link(cfg), do: GenServer.start_link(__MODULE__, cfg, name: __MODULE__)

  @doc "Current status. Callable whether the Engine is active or still inert."
  @spec status() :: status()
  def status, do: GenServer.call(__MODULE__, :status)

  @doc """
  Stores `secret` as the Engine's credential (RAM only, never logged) and
  broadcasts the updated status. If the Engine had paused on `auth_failed`,
  this clears it and re-arms polling — the next poll tick runs a pass; this
  call never starts one itself.
  """
  @spec set_credential(String.t()) :: :ok
  def set_credential(secret) when is_binary(secret),
    do: GenServer.call(__MODULE__, {:set_credential, secret})

  @doc """
  Triggers a sync pass immediately (in a monitored `Task`). Refuses when the
  Engine hasn't activated yet, has no usable `Settings`, or has no
  credential. A no-op `:ok` when a pass is already running (single-flight).
  """
  @spec sync_now() :: :ok | {:error, :not_configured | :no_credential | :inactive}
  def sync_now, do: GenServer.call(__MODULE__, :sync_now)

  @doc """
  Re-reads `config/mail.yaml` from `root` and broadcasts the refreshed
  status. The `setup_mail_account` RPC calls this right after
  `Settings.write!/2` lands a fresh file — the Engine otherwise only reloads
  `Settings` on its own `workspace_opened` activation, so account setup would
  otherwise need a full workspace re-open to take effect. A cheap,
  synchronous `GenServer.call` (no filesystem work happens off this
  process's mailbox) — mirrors `status/0`.
  """
  @spec reload_settings() :: :ok
  def reload_settings, do: GenServer.call(__MODULE__, :reload_settings)

  @doc """
  Runs the mail connection doctor (mail design spec, §Account setup +
  doctor) — `Valea.Mail.Doctor.run/1` against a snapshot of the Engine's
  settings/credential/transport. Never errors: an inactive/unconfigured/
  uncredentialed Engine, an unreachable server, or a bad password are all
  *reported* as checks, not raised. The snapshot is fetched via a fast
  `GenServer.call` (mirroring `status/0`); the actual network probing that
  follows — which can take several seconds — runs in the calling process,
  never inside the Engine's own loop.
  """
  @spec doctor() :: {:ok, %{checks: [Doctor.check()], ok: boolean}}
  def doctor, do: Doctor.run(GenServer.call(__MODULE__, :doctor_ctx))

  @doc """
  Connects and creates whichever of the AI/Review and AI/Processed folders
  are currently missing on the server — the doctor panel's "Create AI
  folders" action. Guarded exactly like `sync_now/0`
  (inactive/not_configured/no_credential), since it needs the same
  settings + credential to connect. Same non-blocking shape as `doctor/0`:
  a fast snapshot call, then the connect runs in the caller's process.
  """
  @spec create_folders() ::
          {:ok, [String.t()]} | {:error, :inactive | :not_configured | :no_credential | term()}
  def create_folders do
    case GenServer.call(__MODULE__, :doctor_ctx_gated) do
      {:ok, ctx} -> Doctor.create_folders(ctx)
      {:error, _reason} = error -> error
    end
  end

  # -- GenServer --------------------------------------------------------------

  @impl true
  def init(%{root: root, generation: generation}) do
    # Trap exits so the sync task can be LINKED (not just monitored):
    # linking makes it die with this Engine when Runtime tears it down on a
    # workspace switch — a monitored-only task blocked in :ssl.recv would
    # otherwise outlive the Engine and write the old workspace's rows into the
    # new one. Trapping turns a linked task's crash into a handled `{:EXIT, _,
    # _}` message rather than killing the Engine; the paired monitor still
    # drives result/cleanup (see `handle_info` below).
    Process.flag(:trap_exit, true)
    Phoenix.PubSub.subscribe(Valea.PubSub, "workspace")

    {:ok,
     %{
       root: root,
       generation: generation,
       transport: Application.get_env(:valea, :mail_transport, Valea.Mail.ImapClient),
       active: false,
       settings: nil,
       credential: nil,
       status: "inactive",
       last_sync_at: nil,
       last_error: nil,
       workspace_id: nil,
       poll_timer: nil,
       sync_task: nil
     }}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, build_status(state), state}

  def handle_call({:set_credential, secret}, _from, state) do
    new_state =
      state
      |> Map.put(:credential, fn -> secret end)
      |> clear_auth_failed()

    broadcast_status(new_state)
    {:reply, :ok, new_state}
  end

  def handle_call(:sync_now, _from, state) do
    case validate_sync(state) do
      :ok -> {:reply, :ok, start_pass_unless_running(state)}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call(:reload_settings, _from, state) do
    {settings, error} = load_settings(state.root)
    new_state = %{state | settings: settings, last_error: error}
    broadcast_status(new_state)
    {:reply, :ok, new_state}
  end

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

  @impl true
  def handle_info({:workspace_opened, _info, generation}, %{generation: generation} = state) do
    {:noreply, activate(state)}
  end

  def handle_info({:workspace_opened, _info, _other_generation}, state), do: {:noreply, state}

  # `auth_failed` pauses polling: no re-arm until `set_credential/1` clears
  # it (see moduledoc §Errors).
  def handle_info(:poll, %{status: "auth_failed"} = state),
    do: {:noreply, %{state | poll_timer: nil}}

  def handle_info(:poll, state), do: {:noreply, state |> maybe_start_pass() |> schedule_poll()}

  # A pass Task reported its result: flush the pending :DOWN, then apply it.
  def handle_info({:sync_result, pid, result}, %{sync_task: {pid, ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish_pass(state, result)}
  end

  # The pass Task crashed before reporting (SyncPass returns tuples, so this
  # is an unexpected raise/exit) — treat it as a failed pass, not a wedge.
  def handle_info({:DOWN, ref, :process, pid, reason}, %{sync_task: {pid, ref}} = state) do
    {:noreply, finish_pass(state, {:error, {:sync_task_down, reason}})}
  end

  # Stale task chatter (already handled/superseded): ignore.
  def handle_info({:sync_result, _pid, _result}, state), do: {:noreply, state}

  # A LINKED sync task exited (normal completion or crash). Because the
  # Engine traps exits, the exit signal arrives here as a message; the paired
  # monitor's `:DOWN` (matched above) is what actually drives result handling
  # and single-flight cleanup, so the `{:EXIT, _, _}` is intentionally a no-op.
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  # -- activation ---------------------------------------------------------

  defp activate(state) do
    {settings, error} = load_settings(state.root)
    {:ok, _count} = Index.rebuild(state.root)

    new_state =
      %{
        state
        | active: true,
          settings: settings,
          credential: state.credential || env_credential(),
          last_error: error,
          status: "idle",
          workspace_id: load_workspace_id(state.root)
      }
      |> schedule_poll()

    broadcast_status(new_state)
    new_state
  end

  # Snapshot of exactly the fields `Valea.Mail.Doctor` needs — the same
  # settings/credential/transport a sync pass would use. Built inside a fast
  # `handle_call` so the slow network probing that consumes it always runs
  # outside the Engine's own loop (see `doctor/0`/`create_folders/0`).
  defp doctor_ctx(state) do
    %{
      root: state.root,
      settings: state.settings,
      credential: state.credential,
      transport: state.transport
    }
  end

  defp load_settings(root) do
    case Settings.load(root) do
      {:ok, settings} -> {settings, nil}
      {:error, :not_configured} -> {nil, nil}
      {:error, {:invalid, reason}} -> {nil, reason}
    end
  end

  # `config/workspace.yaml`'s persistent id (mail design spec, §Credentials —
  # keychain entries key on it). Read once, at activation, into state rather
  # than on every `status/0` call: `Scaffold.create/1` writes it once and
  # `Migration` keeps it stable across opens, so it never changes for the
  # lifetime of an activated Engine. `nil` on any absent/malformed file — a
  # workspace scaffolded before this field existed, or a hand-edited one,
  # must never crash activation.
  defp load_workspace_id(root) do
    case YamlElixir.read_from_file(Path.join(root, "config/workspace.yaml")) do
      {:ok, %{"id" => id}} when is_binary(id) -> id
      _ -> nil
    end
  end

  defp env_credential do
    case System.get_env("VALEA_MAIL_PASSWORD") do
      nil -> nil
      secret -> fn -> secret end
    end
  end

  # -- sync gating ----------------------------------------------------------

  defp validate_sync(%{active: false}), do: {:error, :inactive}
  defp validate_sync(%{settings: nil}), do: {:error, :not_configured}
  defp validate_sync(%{credential: nil}), do: {:error, :no_credential}
  defp validate_sync(_state), do: :ok

  defp maybe_start_pass(state) do
    case validate_sync(state) do
      :ok -> start_pass_unless_running(state)
      {:error, _reason} -> state
    end
  end

  # Single-flight: only start a pass when none is in flight.
  defp start_pass_unless_running(%{sync_task: nil} = state), do: start_pass(state)
  defp start_pass_unless_running(state), do: state

  # Runs `SyncPass.run/1` in a LINKED + monitored process. The link ties the
  # task's lifetime to the Engine's: a Runtime teardown on a workspace switch
  # kills the Engine, which kills this task, so a pass blocked in :ssl.recv
  # can never survive to write the old workspace's data into the new one. The
  # Engine traps exits, so the task crashing is a handled message, not a
  # take-down; the monitor still delivers the result/`:DOWN` used for
  # single-flight tracking. The credential closure travels into the task and
  # is only ever called inside `SyncPass`, at the `connect/3` boundary.
  defp start_pass(state) do
    broadcast_event({:mail_sync_started})

    parent = self()

    args = %{
      root: state.root,
      settings: state.settings,
      credential: state.credential,
      transport: state.transport
    }

    task = spawn_linked_task(fn -> send(parent, {:sync_result, self(), SyncPass.run(args)}) end)

    new_state = %{state | sync_task: task, status: "syncing"}
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

  defp finish_pass(state, {:ok, %{new_messages: new_messages, errors: errors}}) do
    broadcast_event({:mail_sync_finished, %{new_messages: new_messages, errors: errors}})

    %{state | sync_task: nil, status: "idle", last_sync_at: now_iso(), last_error: nil}
    |> tap_broadcast_status()
  end

  defp finish_pass(state, {:error, :auth_failed}) do
    cancel_timer(state.poll_timer)
    broadcast_event({:mail_sync_finished, %{new_messages: 0, errors: ["authentication failed"]}})

    %{
      state
      | sync_task: nil,
        status: "auth_failed",
        poll_timer: nil,
        last_error: "authentication failed"
    }
    |> tap_broadcast_status()
  end

  # `reason` is a connect failure or a `{:sync_task_down, _}` crash reason.
  # It is broadcast in `mail_sync_finished` AND stored as `last_error` (pushed
  # to the UI in every mail_status), so the credential must never survive into
  # it. `Redact.text/2` scrubs the secret (and its inspect-escaped form) out of
  # the built string as defense-in-depth behind the literal-LOGIN fix.
  defp finish_pass(state, {:error, reason}) do
    message = Redact.text("sync failed: #{inspect(reason)}", current_secret(state))
    broadcast_event({:mail_sync_finished, %{new_messages: 0, errors: [message]}})

    %{state | sync_task: nil, status: "idle", last_error: message}
    |> tap_broadcast_status()
  end

  # The raw secret, materialized only here (it already lives in this process's
  # state) and only to scrub it back out of an error string — never stored,
  # never returned.
  defp current_secret(%{credential: fun}) when is_function(fun, 0), do: fun.()
  defp current_secret(_state), do: nil

  defp tap_broadcast_status(state) do
    broadcast_status(state)
    state
  end

  defp now_iso, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp clear_auth_failed(%{status: "auth_failed"} = state) do
    state |> Map.put(:status, "idle") |> schedule_poll()
  end

  defp clear_auth_failed(state), do: state

  # -- poll timer -----------------------------------------------------------

  defp schedule_poll(state) do
    cancel_timer(state.poll_timer)
    timer = Process.send_after(self(), :poll, interval_minutes(state) * 60_000)
    %{state | poll_timer: timer}
  end

  defp interval_minutes(%{settings: %Settings{sync: %{interval_minutes: minutes}}}), do: minutes
  defp interval_minutes(_state), do: @default_interval_minutes

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref), do: Process.cancel_timer(ref)

  # -- status -----------------------------------------------------------

  defp build_status(state) do
    %{
      configured: state.settings != nil,
      credential: if(state.credential, do: "present", else: "missing"),
      state: state.status,
      last_sync_at: state.last_sync_at,
      last_error: state.last_error,
      account: state.settings && state.settings.account,
      # The IMAP login, distinct from `account` (the display label) — the
      # frontend keys its OS-keychain lookup on `workspace_id:username`
      # (spec §Credentials), so the login must be surfaced explicitly
      # rather than approximated from `account`.
      username: state.settings && state.settings.imap.username,
      workspace_id: state.workspace_id
    }
  end

  defp broadcast_status(state) do
    broadcast_event({:mail_status_changed, build_status(state)})
  end

  defp broadcast_event(event) do
    Phoenix.PubSub.broadcast(Valea.PubSub, "mail", event)
  end
end
