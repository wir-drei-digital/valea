defmodule Valea.Agents.ProcessRuntime do
  @moduledoc """
  The ONE way anything in Valea spawns an agent subprocess. Relays its
  output to an owner process as messages:

      {:runtime_output, binary}   # stdout — the NDJSON stream
      {:runtime_stderr, binary}   # stderr — NEVER fed to the JSON decoder
      {:runtime_exit, code | nil} # nil when the code is unknown (signal kill)

  Since windows-support spec B1 this module is a facade over
  `Valea.Agents.ProcessAdapter`: the erlexec implementation moved verbatim to
  `Valea.Agents.ProcessRuntime.Exec`, and Windows gets
  `Valea.Agents.ProcessRuntime.PortShim` (an Erlang Port onto the
  `valea-spawn` shim). The public API — `start/2`, `write/2`, `stop/1` and
  the three owner messages — did not change, so `Valea.Agents.SessionServer`
  neither knows nor cares which one is live.

  Selection happens ONCE at boot: `Valea.Application.start/2` calls
  `select_adapter!/0`, which pins the platform's adapter into app env. Doing
  it once (rather than branching on `:os.type()` per spawn) is what makes the
  choice inspectable and the boundary testable — the app-env slot doubles as
  the test seam: `Application.put_env(:valea, :process_adapter, Fake)`, reset
  with `select_adapter!/0` in `on_exit`. `adapter/0` falls back to the
  platform default so a call that beats boot (or a test that forgot the
  reset) still spawns correctly rather than crashing on `nil`.
  """

  @behaviour Valea.Agents.ProcessAdapter

  @doc """
  Pins this host's adapter into app env. Called first in
  `Valea.Application.start/2`, and by tests to undo an injected fake.
  """
  @spec select_adapter!() :: :ok
  def select_adapter!, do: Application.put_env(:valea, :process_adapter, default_adapter())

  @doc "The adapter every call routes through."
  @spec adapter() :: module()
  def adapter, do: Application.get_env(:valea, :process_adapter) || default_adapter()

  defp default_adapter do
    case :os.type() do
      {:win32, _} -> Valea.Agents.ProcessRuntime.PortShim
      _ -> Valea.Agents.ProcessRuntime.Exec
    end
  end

  @impl true
  @spec start(map(), pid()) :: {:ok, map()} | {:error, String.t()}
  def start(spec, owner), do: adapter().start(spec, owner)

  @impl true
  @spec write(map(), iodata()) :: :ok
  def write(handle, data), do: adapter().write(handle, data)

  @impl true
  @spec stop(map()) :: :ok
  def stop(handle), do: adapter().stop(handle)
end
