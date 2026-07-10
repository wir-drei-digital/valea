defmodule Valea.Agents do
  @moduledoc """
  Public API for the agent session runtime. Owns starting sessions under the
  workspace-scoped `Valea.Agents.SessionSupervisor` and keeps the harness
  command resolution SYNCHRONOUS so `{:error, :harness_unavailable}` surfaces
  to the caller before any process is spawned.

  Grows in Task 10 (listing / attach fan-out over the whole workspace).
  """

  alias Valea.Agents.SessionServer

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
end
