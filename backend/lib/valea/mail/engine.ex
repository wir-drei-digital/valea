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

  ## Errors

  Auth failure pauses the poll timer (no retry storm against a bad
  password) until `set_credential/1` supplies a new one, which clears the
  failure and re-arms polling. This task only lays the seam: the actual
  sync pass (`run_pass/1`) is a no-op placeholder wired up in a later task,
  so `state: "auth_failed"` is never actually reached yet — the
  transition exists so that task doesn't have to touch the poll-pause
  contract.
  """
  use GenServer

  alias Valea.Mail.Index
  alias Valea.Mail.Settings

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
  this clears it and re-arms polling. Triggers a sync pass if the Engine is
  active and configured (a no-op this task — see the moduledoc).
  """
  @spec set_credential(String.t()) :: :ok
  def set_credential(secret) when is_binary(secret),
    do: GenServer.call(__MODULE__, {:set_credential, secret})

  @doc """
  Triggers a sync pass immediately. Refuses when the Engine hasn't
  activated yet, has no usable `Settings`, or has no credential — the sync
  pass itself is a no-op stub this task (wired up in a later task).
  """
  @spec sync_now() :: :ok | {:error, :not_configured | :no_credential | :inactive}
  def sync_now, do: GenServer.call(__MODULE__, :sync_now)

  @doc "Stub this task — wired to the post-approval mailbox-ops recovery/retry path later."
  @spec retry_ops(String.t()) :: {:error, :not_implemented}
  def retry_ops(_run_id), do: {:error, :not_implemented}

  # -- GenServer --------------------------------------------------------------

  @impl true
  def init(%{root: root, generation: generation}) do
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
       poll_timer: nil
     }}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, build_status(state), state}

  def handle_call({:set_credential, secret}, _from, state) do
    new_state =
      state
      |> Map.put(:credential, fn -> secret end)
      |> clear_auth_failed()
      |> maybe_run_pass()

    broadcast_status(new_state)
    {:reply, :ok, new_state}
  end

  def handle_call(:sync_now, _from, state) do
    case validate_sync(state) do
      :ok -> {:reply, :ok, run_pass(state)}
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

  def handle_info(:poll, state), do: {:noreply, state |> run_pass() |> schedule_poll()}

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
    new_state
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

  defp maybe_run_pass(state) do
    case validate_sync(state) do
      :ok -> run_pass(state)
      {:error, _reason} -> state
    end
  end

  # Seam for a later task: the real connect/select/fetch/normalize/land pass
  # over `state.transport`. Deliberately a no-op here.
  defp run_pass(state), do: state

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
    Phoenix.PubSub.broadcast(Valea.PubSub, "mail", {:mail_status_changed, build_status(state)})
  end
end
