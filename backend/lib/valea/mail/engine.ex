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

  alias Valea.Mail.Index
  alias Valea.Mail.MailboxOps
  alias Valea.Mail.Settings
  alias Valea.Mail.SyncPass
  alias Valea.Queue

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
          account: String.t() | nil
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
  Re-runs the post-approval mailbox ops for `run_id` — the UI's retry button.
  Unlike the activation recovery scan (which re-attempts only `"pending"`
  ops), this re-attempts BOTH `"pending"` and `"failed"` ops, since it is an
  explicit, user-driven request. Refuses with the same gate as `sync_now/0`
  (inactive/not-configured/no-credential); the actual work runs in an
  unlinked task and never blocks this call.
  """
  @spec retry_ops(String.t()) :: :ok | {:error, :inactive | :no_credential | :not_configured}
  def retry_ops(run_id) when is_binary(run_id),
    do: GenServer.call(__MODULE__, {:retry_ops, run_id})

  # -- GenServer --------------------------------------------------------------

  @impl true
  def init(%{root: root, generation: generation}) do
    Phoenix.PubSub.subscribe(Valea.PubSub, "workspace")
    Phoenix.PubSub.subscribe(Valea.PubSub, "mail_ops")

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

  def handle_call({:retry_ops, run_id}, _from, state) do
    case validate_sync(state) do
      :ok -> {:reply, :ok, execute_ops(state, run_id)}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_info({:workspace_opened, _info, generation}, %{generation: generation} = state) do
    {:noreply, activate(state)}
  end

  def handle_info({:workspace_opened, _info, _other_generation}, state), do: {:noreply, state}

  # A decided item's mailbox ops became pending (an approve/reject just
  # landed). Execute them if we can reach the mailbox; otherwise leave them
  # pending for the activation recovery scan or a later retry.
  def handle_info({:mailbox_ops_pending, run_id}, state) do
    {:noreply, maybe_execute_ops(state, run_id)}
  end

  # Our own update broadcast (and any other mail_ops chatter): ignore.
  def handle_info({:mailbox_ops_updated, _run_id}, state), do: {:noreply, state}

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
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

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
          status: "idle"
      }
      |> schedule_poll()

    broadcast_status(new_state)
    recover_mailbox_ops(new_state)
    new_state
  end

  # Activation recovery scan: any decided item whose mailbox ops are still
  # "pending" (an approve/reject whose broadcast we missed, e.g. a crash or a
  # switch-away before it ran) is re-executed. "failed" ops are deliberately
  # NOT swept here — they wait for the user's explicit retry (`retry_ops/1`),
  # since a failure is a signal worth showing, not silently re-attempting on
  # every open. Gated by the same active/configured/credentialed check as a
  # sync: with no credential the ops simply wait.
  defp recover_mailbox_ops(state) do
    case validate_sync(state) do
      :ok -> Enum.each(pending_op_run_ids(), &execute_ops(state, &1))
      {:error, _reason} -> :ok
    end
  end

  defp pending_op_run_ids do
    case Queue.list_decided() do
      {:ok, entries} ->
        for %{run_id: run_id, mailbox_ops: ops} <- entries, any_pending?(ops), do: run_id

      {:error, _reason} ->
        []
    end
  end

  defp any_pending?(ops) when is_map(ops) do
    Enum.any?(ops, fn {_name, op} -> is_map(op) and Map.get(op, "status") == "pending" end)
  end

  defp any_pending?(_ops), do: false

  # Runs the mailbox ops for `run_id` in an unlinked task so a slow or
  # crashing pass can never block or take down the Engine. `MailboxOps.execute`
  # is idempotent and self-guarding, so a duplicate trigger (recovery scan +
  # the pending broadcast, say) is safe. Callers gate on `validate_sync/1`.
  defp maybe_execute_ops(state, run_id) do
    case validate_sync(state) do
      :ok -> execute_ops(state, run_id)
      {:error, _reason} -> state
    end
  end

  defp execute_ops(state, run_id) do
    args = %{
      root: state.root,
      run_id: run_id,
      transport: state.transport,
      settings: state.settings,
      credential: state.credential
    }

    spawn(fn -> MailboxOps.execute(args) end)
    state
  end

  defp load_settings(root) do
    case Settings.load(root) do
      {:ok, settings} -> {settings, nil}
      {:error, :not_configured} -> {nil, nil}
      {:error, {:invalid, reason}} -> {nil, reason}
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

  # Runs `SyncPass.run/1` in a monitored (unlinked) process so a crashing
  # pass can never take the Engine down — the `spawn_monitor` result is
  # tracked so a later `sync_now`/poll no-ops and the result/`:DOWN` message
  # can be matched back. The credential closure travels into the task and is
  # only ever called inside `SyncPass`, at the `connect/3` boundary.
  defp start_pass(state) do
    broadcast_event({:mail_sync_started})

    parent = self()

    args = %{
      root: state.root,
      settings: state.settings,
      credential: state.credential,
      transport: state.transport
    }

    {pid, ref} =
      spawn_monitor(fn -> send(parent, {:sync_result, self(), SyncPass.run(args)}) end)

    new_state = %{state | sync_task: {pid, ref}, status: "syncing"}
    broadcast_status(new_state)
    new_state
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

  defp finish_pass(state, {:error, reason}) do
    message = "sync failed: #{inspect(reason)}"
    broadcast_event({:mail_sync_finished, %{new_messages: 0, errors: [message]}})

    %{state | sync_task: nil, status: "idle", last_error: message}
    |> tap_broadcast_status()
  end

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
      account: state.settings && state.settings.account
    }
  end

  defp broadcast_status(state) do
    broadcast_event({:mail_status_changed, build_status(state)})
  end

  defp broadcast_event(event) do
    Phoenix.PubSub.broadcast(Valea.PubSub, "mail", event)
  end
end
