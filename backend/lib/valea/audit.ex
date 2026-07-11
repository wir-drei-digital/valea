defmodule Valea.Audit do
  @moduledoc """
  Append-only audit trail at {root}/logs/audit.jsonl. One GenServer
  serializes writes; failures are logged loudly but never crash callers —
  file moves are the source of truth, audit is the trail (spec §Queue).
  """
  use GenServer
  require Logger

  def start_link(cfg), do: GenServer.start_link(__MODULE__, cfg, name: __MODULE__)

  def append(type, fields \\ %{}) do
    GenServer.cast(__MODULE__, {:append, type, fields})
  end

  @doc """
  Synchronous variant of `append/2`: blocks until the entry has been
  encoded and written (or the failure logged), so callers that need the
  entry durably on disk before proceeding (e.g. an approval-intent audit
  that must precede execution) can rely on the write having happened by
  the time this returns. Same "never crash callers" contract as
  `append/2` — a call timeout or a dead Audit process is caught and this
  still returns `:ok`.
  """
  def append_sync(type, fields \\ %{}) do
    GenServer.call(__MODULE__, {:append, type, fields})
  catch
    :exit, reason ->
      Logger.error("audit append_sync failed: #{inspect(reason)}")
      :ok
  end

  @doc """
  Most-recent `limit` audit entries, newest-first. Guarded like `append/2`:
  with no workspace open (or mid-switch) the named Audit process does not
  exist, so this degrades to `{:ok, []}` instead of exiting `:noproc` and
  taking the calling RPC/channel process down.
  """
  def entries(limit) do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, {:entries, limit})
    else
      {:ok, []}
    end
  end

  @impl true
  def init(%{root: root, generation: gen}) do
    path = Path.join(root, "logs/audit.jsonl")
    File.mkdir_p!(Path.dirname(path))
    {:ok, %{path: path, generation: gen}}
  end

  @impl true
  def handle_cast({:append, type, fields}, state) do
    write_entry(type, fields, state)
    {:noreply, state}
  end

  @impl true
  def handle_call({:append, type, fields}, _from, state) do
    write_entry(type, fields, state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:entries, limit}, _from, state) do
    entries =
      case File.read(state.path) do
        {:ok, data} ->
          data
          |> String.split("\n", trim: true)
          |> Enum.reverse()
          |> Enum.take(limit)
          |> Enum.flat_map(fn line ->
            case Jason.decode(line) do
              {:ok, map} -> [map]
              _ -> []
            end
          end)

        _ ->
          []
      end

    {:reply, {:ok, entries}, state}
  end

  ## shared write path for handle_cast/handle_call append

  defp write_entry(type, fields, state) do
    entry =
      %{
        "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "type" => type,
        "generation" => state.generation
      }
      |> Map.merge(fields)

    case Jason.encode(entry) do
      {:ok, json} ->
        case File.write(state.path, json <> "\n", [:append]) do
          :ok -> :ok
          {:error, reason} -> Logger.error("audit append failed: #{inspect(reason)}")
        end

      {:error, reason} ->
        Logger.error("audit append failed to encode entry: #{inspect(reason)}")
    end

    :ok
  end
end
