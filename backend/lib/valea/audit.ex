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

  def entries(limit) do
    GenServer.call(__MODULE__, {:entries, limit})
  end

  @impl true
  def init(%{root: root, generation: gen}) do
    path = Path.join(root, "logs/audit.jsonl")
    File.mkdir_p!(Path.dirname(path))
    {:ok, %{path: path, generation: gen}}
  end

  @impl true
  def handle_cast({:append, type, fields}, state) do
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

    {:noreply, state}
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
end
