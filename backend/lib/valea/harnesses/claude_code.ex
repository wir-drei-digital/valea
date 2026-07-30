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
  alias Valea.Paths

  # PATHEXT's own default, for the case where the variable is unset.
  @default_pathext ~w(.exe .cmd .bat .com)

  @impl true
  def definition, do: %{id: "claude_code", name: "Claude Code"}

  @doc """
  The command to spawn, resolved against this machine.

  `opts` carries `:env` (merged into the returned spec) and, TEST-ONLY,
  `:platform` — which platform's command-RESOLUTION strategy to apply, so
  Windows resolution is provable on a Unix host (spec §D testing split).
  It does NOT relax the gates below: absoluteness and regular-file checks
  always ask the real host, because what they gate is a real host path.
  """
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
  #
  # `system_prompt_append` is the context.md TEXT itself: the on-disk file is
  # the user-inspectable record, but delivery is this in-memory copy — the
  # adapter appends it to Claude Code's system prompt via `_meta.systemPrompt`
  # (see `Valea.Acp.Connection.put_system_prompt/2`). The file alone was
  # write-only chrome: it sits under runtime/sessions/, outside the agent's
  # cwd and every additional root, so nothing would ever read it.
  @impl true
  def launch(scope, _session_dir) do
    SessionSettings.materialize!(scope)

    {:ok,
     %{
       cwd: scope.cwd,
       additional_roots: related_and_input_roots(scope),
       context_path: scope.managed_context,
       managed_settings: Jason.encode!(SessionSettings.content(scope)),
       system_prompt_append: SessionSettings.context(scope),
       env: Env.minimal(),
       argv_extra: []
     }}
  end

  defp related_and_input_roots(scope) do
    Enum.map(scope.related_icms, & &1.root) ++ scope.read_paths
  end

  # The configured command is a CONFIG-supplied path, so `Paths.normalize/1` is
  # its ingress (spec §D2) and `Paths.absolute?/1` its absoluteness gate: an
  # absolute command is taken as named, a bare command name goes through PATH.
  # `System.find_executable/1`'s answer is re-gated the same way — only a
  # root-anchored, regular file is ever spawned.
  defp resolve(cmd, args, opts) do
    cmd = Paths.normalize(cmd)
    resolved = if Paths.absolute?(cmd), do: cmd, else: search(cmd, resolver_platform(opts))

    case resolved do
      abs when is_binary(abs) ->
        if Paths.absolute?(abs) and File.regular?(abs),
          do: {:ok, %CommandSpec{cmd: abs, args: args, env: opts[:env] || %{}}},
          else: {:error, :harness_unavailable}

      _ ->
        {:error, :harness_unavailable}
    end
  end

  defp resolver_platform(opts), do: Map.get(opts, :platform) || Paths.host_platform()

  # On unix, PATH is the whole story. On Windows an executable's name usually
  # is not its filename (spec B3): `claude-agent-acp` is really
  # `claude-agent-acp.cmd`, so PATHEXT decides what "on PATH" even means, and
  # npm's global bin is frequently not on PATH at all for a GUI-launched
  # process. Hence the three-step search — PATH, PATH×PATHEXT, then the two
  # install locations.
  defp search(cmd, :windows) do
    System.find_executable(cmd) || search_pathext(cmd) || search_install_locations(cmd)
  end

  defp search(cmd, _unix), do: System.find_executable(cmd)

  defp search_pathext(cmd) do
    Enum.find_value(pathext(), fn ext -> System.find_executable(cmd <> ext) end)
  end

  defp pathext do
    case System.get_env("PATHEXT") do
      value when is_binary(value) and value != "" ->
        value |> String.split(";", trim: true) |> Enum.map(&String.downcase/1)

      _ ->
        @default_pathext
    end
  end

  # Derived from the CONFIGURED name — never a hardcoded basename. `claude.exe`
  # is the interactive CLI, not the ACP adapter; resolving it would spawn an
  # executable that does not speak the protocol. Only a BARE name is probed:
  # anything with a separator in it is a path the user chose, and looking
  # elsewhere for it would resolve something they did not ask for.
  defp search_install_locations(cmd) do
    if bare_name?(cmd) do
      appdata = System.get_env("APPDATA")
      profile = System.get_env("USERPROFILE")

      [
        appdata && Path.join([appdata, "npm", cmd <> ".cmd"]),
        profile && Path.join([profile, ".local", "bin", cmd <> ".exe"]),
        profile && Path.join([profile, ".local", "bin", cmd <> ".cmd"])
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.find(&File.regular?/1)
    end
  end

  defp bare_name?(cmd), do: not String.contains?(cmd, ["/", "\\"])
end
