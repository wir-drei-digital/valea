defmodule Valea.Agents do
  @moduledoc """
  Public API for the agent session runtime. Owns starting sessions under the
  workspace-scoped `Valea.Agents.SessionSupervisor` and keeps the harness
  command resolution SYNCHRONOUS so `{:error, :harness_unavailable}` surfaces
  to the caller before any process is spawned.

  Also fans out over the whole workspace: `attach_or_replay/1` (live via the
  Registry, or ENDED via transcript file replay for the
  `ValeaWeb.AgentSessionChannel` join reply) and `list_sessions/0` (a
  workspace-wide session index for the SPA's session list).
  """

  alias Valea.Agents.SessionServer
  alias Valea.Workspace.Manager

  @doc """
  Starts a session. Resolves the harness command FIRST (so an unavailable
  harness returns synchronously), generates the backend session id, then starts
  the `SessionServer` child under `Valea.Agents.SessionSupervisor`.

  `opts` keys: `:kind`, `:title`, `:workspace`, `:generation`, `:run`,
  `:initial_prompt`, `:on_turn_end`, `:policy_ctx`, and optionally
  `:handshake_timeout_ms` (test override).
  """
  @spec start_session(map()) :: {:ok, %{id: String.t()}} | {:error, term()}
  def start_session(opts) when is_map(opts) do
    with {:ok, spec} <-
           Valea.Harnesses.ClaudeCode.acp_command(%{env: Valea.Agents.Env.minimal()}) do
      id = generate_id()
      child_opts = opts |> Map.put(:id, id) |> Map.put(:spec, spec)

      case DynamicSupervisor.start_child(
             Valea.Agents.SessionSupervisor,
             {SessionServer, child_opts}
           ) do
        {:ok, _pid} -> {:ok, %{id: id}}
        {:ok, _pid, _info} -> {:ok, %{id: id}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # Backend-generated session id: UTC timestamp + "-" + 6-byte hex suffix.
  defp generate_id do
    stamp =
      DateTime.utc_now()
      |> DateTime.to_iso8601(:basic)

    suffix = :crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)
    stamp <> "-" <> suffix
  end

  @doc """
  Join-reply snapshot for `ValeaWeb.AgentSessionChannel`: `SessionServer.attach/1`
  when the id is a live Registry hit, otherwise a replay reconstructed from
  the workspace's transcript file (`busy: false, status: "ended"`).
  `{:error, :not_found}` when neither a live process nor a transcript file
  exists for `id`.
  """
  @spec attach_or_replay(String.t()) :: {:ok, map()} | {:error, :not_found}
  def attach_or_replay(id) do
    case SessionServer.attach(id) do
      {:ok, reply} -> {:ok, reply}
      {:error, :not_running} -> replay(id)
    end
  end

  defp replay(id) do
    with {:ok, %{path: workspace}} <- Manager.current() do
      path = transcript_path(workspace, id)

      if File.regular?(path) do
        {:ok, replay_reply(path)}
      else
        {:error, :not_found}
      end
    else
      {:error, :no_workspace} -> {:error, :not_found}
    end
  end

  defp replay_reply(path) do
    {items, cursor} =
      path
      |> File.stream!()
      # Line 1 is session metadata, not a timeline item — see SessionServer.
      |> Stream.drop(1)
      |> Enum.reduce({[], 0}, fn line, {items, cursor} ->
        case Jason.decode(line) do
          {:ok, %{"seq" => seq, "item" => item}} -> {upsert(items, item), seq}
          _ -> {items, cursor}
        end
      end)

    %{items: items, cursor: cursor, busy: false, status: "ended"}
  end

  # Mirrors SessionServer's in-memory timeline fold: later lines for the same
  # item id (e.g. a permission's resolved:false -> resolved:true transition)
  # REPLACE in place rather than appending a duplicate.
  defp upsert(timeline, item) do
    id = item["id"]

    if Enum.any?(timeline, &(&1["id"] == id)) do
      Enum.map(timeline, fn i -> if i["id"] == id, do: item, else: i end)
    else
      timeline ++ [item]
    end
  end

  @doc """
  Workspace-wide session index for the SPA's session list: scans
  `{workspace}/logs/sessions/*.jsonl` for their metadata (line 1), newest
  `started_at` first, merging in live status from the Registry via
  `SessionServer.attach/1`. `{:ok, []}` when no workspace is open or it has
  no sessions yet — this never fails the caller.
  """
  @spec list_sessions() :: {:ok, [map()]}
  def list_sessions do
    case Manager.current() do
      {:ok, %{path: workspace}} ->
        {:ok,
         workspace
         |> sessions_dir()
         |> transcript_files()
         |> Enum.map(&session_summary/1)
         |> Enum.reject(&is_nil/1)
         |> Enum.sort_by(& &1["started_at"], :desc)}

      {:error, :no_workspace} ->
        {:ok, []}
    end
  end

  defp sessions_dir(workspace), do: Path.join([workspace, "logs", "sessions"])
  defp transcript_path(workspace, id), do: Path.join(sessions_dir(workspace), id <> ".jsonl")

  defp transcript_files(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
        |> Enum.map(&Path.join(dir, &1))

      {:error, _reason} ->
        []
    end
  end

  defp session_summary(path) do
    with {:ok, meta} <- read_meta(path) do
      id = meta["id"]
      {live?, status} = live_status(id)

      %{
        "id" => id,
        "kind" => meta["kind"],
        "title" => meta["title"],
        "workflow" => meta["workflow"],
        "run_id" => meta["run_id"],
        "started_at" => meta["started_at"],
        "status" => status,
        "live" => live?
      }
    else
      _ -> nil
    end
  end

  defp live_status(id) do
    case SessionServer.attach(id) do
      {:ok, %{status: status}} -> {true, status}
      {:error, :not_running} -> {false, "ended"}
    end
  end

  # `Stream.resource`'s cleanup runs on early halt too, so `Enum.at/2` reading
  # just the first line still closes the file handle — no explicit open/close.
  defp read_meta(path) do
    case path |> File.stream!() |> Enum.at(0) do
      nil -> :error
      line -> Jason.decode(line)
    end
  rescue
    File.Error -> :error
  end
end
