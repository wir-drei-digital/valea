defmodule Valea.Harnesses.ClaudeCode do
  @moduledoc """
  Claude Code over the @agentclientprotocol/claude-agent-acp adapter.
  The executable comes from TRUSTED app config (never workspace files —
  spec §harnesses.yaml removed).
  """
  @behaviour Valea.Harness

  alias Valea.Agents.CommandSpec
  alias Valea.Agents.Env
  alias Valea.Agents.SessionSettings

  @impl true
  def definition, do: %{id: "claude_code", name: "Claude Code"}

  @impl true
  def acp_command(opts \\ %{}) do
    case Valea.App.Config.harness_command() do
      [cmd | args] when is_binary(cmd) ->
        resolve(cmd, args, opts)

      _ ->
        {:error, :harness_unavailable}
    end
  end

  # Materializes context.md only (SessionSettings.materialize!/1 never writes
  # a settings file). The permission posture is rendered by
  # SessionSettings.content/1 and conveyed IN-MEMORY as `managed_settings` —
  # a JSON string the adapter receives via its SDK-options channel
  # (`_meta.claudeCode.options.managedSettings`), never written to disk or
  # into the ICM. `PermissionPolicy` on the ACP `request_permission`
  # callback authoritatively answers the `ask`s the posture produces.
  @impl true
  def launch(scope, _session_dir) do
    SessionSettings.materialize!(scope)

    {:ok,
     %{
       cwd: scope.cwd,
       additional_roots: related_and_input_roots(scope),
       context_path: scope.managed_context,
       managed_settings: Jason.encode!(SessionSettings.content(scope)),
       env: Env.minimal(),
       argv_extra: []
     }}
  end

  defp related_and_input_roots(scope) do
    Enum.map(scope.related_icms, & &1.root) ++ scope.read_paths
  end

  defp resolve(cmd, args, opts) do
    resolved = if String.starts_with?(cmd, "/"), do: cmd, else: System.find_executable(cmd)

    case resolved do
      abs when is_binary(abs) ->
        if String.starts_with?(abs, "/") and File.regular?(abs),
          do: {:ok, %CommandSpec{cmd: abs, args: args, env: opts[:env] || %{}}},
          else: {:error, :harness_unavailable}

      _ ->
        {:error, :harness_unavailable}
    end
  end
end
