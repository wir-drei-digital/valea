defmodule Valea.Harnesses.ClaudeCode do
  @moduledoc """
  Claude Code over the @agentclientprotocol/claude-agent-acp adapter.
  The executable comes from TRUSTED app config (never workspace files —
  spec §harnesses.yaml removed).
  """
  @behaviour Valea.Harness

  alias Valea.Agents.CommandSpec

  @impl true
  def definition, do: %{id: "claude_code", name: "Claude Code"}

  @impl true
  def acp_command(opts \\ %{}) do
    [cmd | args] = Valea.App.Config.harness_command()

    resolved = if String.starts_with?(cmd, "/"), do: cmd, else: System.find_executable(cmd)

    case resolved do
      nil ->
        {:error, :harness_unavailable}

      abs ->
        if File.exists?(abs),
          do: {:ok, %CommandSpec{cmd: abs, args: args, env: opts[:env] || %{}}},
          else: {:error, :harness_unavailable}
    end
  end
end
