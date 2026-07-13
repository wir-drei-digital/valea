# SPIKE PROBE — throwaway proof for Task 1.1 ("ICM project workspaces" plan,
# Phase 1). NOT part of the runtime, NOT test-covered, safe to delete once
# Task 1.2/1.3 land the real `Valea.Harness` / `SessionSettings` /
# `additionalDirectories`-aware `Valea.Acp.Connection` wiring.
#
# Proves the claude-agent-acp launch contract end to end, against a REAL
# adapter subprocess:
#
#   * cwd            — via `session/new` `cwd` (already used in production).
#   * additional read — via `session/new` `additionalDirectories` (the native
#     roots            ACP field; NOT wired into `Valea.Acp.Connection` yet —
#                       that is Task 1.3's job. See "Why this script speaks
#                       raw ACP" below).
#   * managed         — TWO things are exercised: (a) a Valea-owned
#     settings          settings.json is written to a THIRD temp dir standing
#                       in for `runtime/sessions/<id>/settings.json`,
#                       deliberately NOT under cwd or any additionalDirectories
#                       entry, to empirically confirm the adapter's
#                       `SettingsManager` never looks at it; (b) the chosen
#                       mechanism itself — an in-memory `managedSettings`
#                       posture (ask Write/Edit/Bash; deny the secret dir;
#                       deny WebFetch/WebSearch) forwarded on `session/new` via
#                       `_meta.claudeCode.options.managedSettings`, the SDK's
#                       documented lockdown-without-a-file channel (see
#                       docs/notes/acp-launch-contract.md, "Managed
#                       settings"). (a) is a rejected-alternative check; (b)
#                       is the actual chosen posture, present here so the
#                       moment account headroom returns, a live run also
#                       exercises it end to end.
#   * enforcement     — every Read/Write the model attempts outside the
#                       allowed roots must arrive as a `session/
#                       request_permission` REQUEST that this script answers
#                       itself (standing in for `Valea.Agents.PermissionPolicy`
#                       + `SessionServer.policy_decide/2`), never an
#                       auto-allow baked into the adapter/SDK.
#
# Run: cd backend && mix run scripts/spike/acp_launch_probe.exs
#
# ## Why this script speaks raw ACP instead of reusing `Valea.Acp.Connection`
#
# `Valea.Acp.Connection.new/1` builds a fixed `session/new` payload
# (`%{"cwd" => cwd, "mcpServers" => []}` — see `open_session_frames/2`,
# acp/connection.ex) with no hook for `additionalDirectories`. Adding that
# hook is explicitly deferred to Task 1.3 (see the plan's Phase 1, "prefer
# [additionalDirectories] over any `_meta.valea.*` invention; see Task 1.3"),
# and this task ("no runtime refactor lands in this task") must not modify
# `connection.ex`. So this script drives the ACP wire protocol directly for
# the handshake/session/new/prompt/permission-request exchange, while still
# reusing the THREE Valea modules that own process launch and are NOT
# ACP-shape-specific: `Valea.Agents.Env.minimal/0` (subprocess env
# allowlist), `Valea.Harnesses.ClaudeCode.acp_command/1` (resolves the
# trusted `claude-agent-acp` executable from `Valea.App.Config
# .harness_command/0`), and `Valea.Agents.ProcessRuntime` (spawn + stdio
# relay via erlexec). Those three are exactly what Task 1.2/1.3 will wire
# into the real `SessionServer` launch path unchanged.

defmodule Spike.AcpLaunchProbe do
  @moduledoc false

  @initialize_id 1
  @session_new_id 2
  @prompt_id 3
  # Give the nested agent up to this long to answer any single wire message
  # (thinking + tool calls can take a while for a live model turn).
  @recv_timeout_ms 90_000
  # Grace period after the prompt turn ends, for any trailing notifications.
  @drain_ms 1_500

  def run do
    banner("ACP launch contract probe (Task 1.1 spike)")

    {primary, related, secret, settings_path} = setup_dirs()

    IO.puts("primary ICM (cwd):        #{primary}")
    IO.puts("related ICM (add-dir):    #{related}")
    IO.puts("secret dir (unreachable): #{secret}")
    IO.puts("stand-in settings file:   #{settings_path}  (deliberately NOT under cwd/add-dir)")
    IO.puts("")

    env = Valea.Agents.Env.minimal()
    IO.puts("subprocess env keys: #{env |> Map.keys() |> Enum.sort() |> Enum.join(", ")}")

    case Valea.Harnesses.ClaudeCode.acp_command(%{env: env}) do
      {:ok, spec} ->
        IO.puts("harness cmd: #{spec.cmd} #{Enum.join(spec.args, " ")}")
        IO.puts("")
        launch(spec, %{primary: primary, related: related, secret: secret})

      {:error, reason} ->
        IO.puts("FAILED to resolve harness command: #{inspect(reason)}")
        IO.puts("(check `claude-agent-acp` is on PATH — see docs/notes/acp-launch-contract.md)")
    end
  end

  # --- fixture setup --------------------------------------------------------

  defp setup_dirs do
    base = Path.join(System.tmp_dir!(), "acp_probe_#{System.unique_integer([:positive])}")
    primary = Path.join(base, "primary_icm")
    related = Path.join(base, "related_icm")
    secret = Path.join(base, "secret")
    settings_dir = Path.join(base, "session_settings")

    Enum.each([primary, related, secret, settings_dir], &File.mkdir_p!/1)

    File.write!(Path.join(primary, "PRIMARY.md"), "# Primary ICM marker\n\nThis is PRIMARY.md.\n")

    File.write!(
      Path.join(primary, "CLAUDE.md"),
      "# Primary ICM memory\n\nThis is the primary ICM's own CLAUDE.md.\n"
    )

    File.write!(Path.join(related, "RELATED.md"), "# Related ICM marker\n\nThis is RELATED.md.\n")

    File.write!(
      Path.join(related, "CLAUDE.md"),
      "# Related ICM memory\n\nThis is the RELATED ICM's CLAUDE.md — instruction isolation means " <>
        "this must not silently become every session's global instructions.\n"
    )

    File.write!(
      Path.join(secret, "SECRET.md"),
      "# Secret\n\nThis file must never be read by the agent.\n"
    )

    settings_path = Path.join(settings_dir, "settings.json")

    settings_content = %{
      "permissions" => %{
        "deny" => ["Read(#{secret}/**)"],
        "ask" => ["Write", "Edit"]
      }
    }

    File.write!(settings_path, Jason.encode!(settings_content, pretty: true) <> "\n")

    {primary, related, secret, settings_path}
  end

  # --- process launch --------------------------------------------------------

  defp launch(spec, dirs) do
    case Valea.Agents.ProcessRuntime.start(
           %{cmd: spec.cmd, args: spec.args, env: spec.env, cd: dirs.primary},
           self()
         ) do
      {:ok, handle} ->
        try do
          state = run_protocol(handle, dirs)
          report(state, dirs)
        after
          Valea.Agents.ProcessRuntime.stop(handle)
        end

      {:error, reason} ->
        IO.puts("FAILED to start adapter subprocess: #{inspect(reason)}")
    end
  end

  # --- minimal hand-rolled ACP JSON-RPC client ------------------------------

  defp run_protocol(handle, dirs) do
    send_frame(handle, %{
      "jsonrpc" => "2.0",
      "id" => @initialize_id,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => 1,
        "clientInfo" => %{"name" => "valea-spike-probe", "version" => "0.0.0"},
        "clientCapabilities" => %{}
      }
    })

    state = %{
      buf: "",
      dirs: dirs,
      session_id: nil,
      stage: :await_initialize,
      # observed evidence for the final report
      reads: %{primary: :not_seen, related: :not_seen},
      secret_permission_seen?: false,
      write_permission_seen?: false,
      permission_log: [],
      tool_log: [],
      stop_reason: nil,
      finished?: false
    }

    loop(handle, state)
  end

  defp send_frame(handle, msg),
    do: Valea.Agents.ProcessRuntime.write(handle, Jason.encode!(msg) <> "\n")

  defp loop(handle, %{finished?: true} = state), do: drain(handle, state)

  defp loop(handle, state) do
    receive do
      {:runtime_output, data} ->
        {state, lines} = feed(state, data)
        state = Enum.reduce(lines, state, &handle_message(handle, &2, &1))
        loop(handle, state)

      {:runtime_stderr, data} ->
        IO.puts("[adapter stderr] " <> String.slice(to_string(data), 0, 400))
        loop(handle, state)

      {:runtime_exit, code} ->
        IO.puts("!! adapter exited (code=#{inspect(code)}) before the probe finished.")
        %{state | finished?: true}
    after
      @recv_timeout_ms ->
        IO.puts(
          "!! TIMEOUT (#{@recv_timeout_ms}ms) waiting for adapter output at stage=#{state.stage}."
        )

        %{state | finished?: true}
    end
  end

  # Short grace window after the prompt turn ends, to catch trailing
  # notifications, without blocking the probe indefinitely.
  defp drain(handle, state) do
    receive do
      {:runtime_output, data} ->
        {state, lines} = feed(state, data)
        state = Enum.reduce(lines, state, &handle_message(handle, &2, &1))
        drain(handle, state)

      {:runtime_stderr, _data} ->
        drain(handle, state)

      {:runtime_exit, _code} ->
        state
    after
      @drain_ms -> state
    end
  end

  defp feed(state, data) do
    {lines, rest} =
      (state.buf <> data)
      |> String.split("\n")
      |> Enum.split(-1)

    {%{state | buf: List.first(rest) || ""}, Enum.reject(lines, &(&1 == ""))}
  end

  defp handle_message(handle, state, line) do
    case Jason.decode(line) do
      {:ok, msg} -> dispatch(handle, state, msg)
      {:error, _} -> state
    end
  end

  # --- responses to OUR requests --------------------------------------------

  defp dispatch(handle, %{stage: :await_initialize} = state, %{
         "id" => @initialize_id,
         "result" => result
       }) do
    IO.puts("<- initialize ok (protocolVersion=#{inspect(result["protocolVersion"])})")

    # The chosen enforcement posture (see docs/notes/acp-launch-contract.md,
    # "Managed settings"): in-memory only, forwarded through the SDK's
    # documented `Options.managedSettings` field via the adapter's own
    # `_meta.claudeCode.options.*` pass-through — no settings file is
    # written anywhere. Deliberately restrictive-only (ask/deny, no `allow`
    # array): the SDK filters `Options.managedSettings` restrictive-only, so
    # a permissive key here would silently be dropped anyway (`sdk.d.ts`,
    # `Options.managedSettings` doc comment). This mirrors the shape of
    # `Valea.Agents.ClaudeSettings.content/1`'s `ask`/`deny` set, minus its
    # `allow` array (which only makes sense for the file-based mechanism
    # that module writes for the legacy/non-ICM case).
    managed_settings = %{
      "permissions" => %{
        "ask" => ["Write", "Edit", "Bash"],
        "deny" => [
          "Read(#{state.dirs.secret}/**)",
          "Edit(#{state.dirs.secret}/**)",
          "Write(#{state.dirs.secret}/**)",
          "WebFetch",
          "WebSearch"
        ]
      }
    }

    send_frame(handle, %{
      "jsonrpc" => "2.0",
      "id" => @session_new_id,
      "method" => "session/new",
      "params" => %{
        "cwd" => state.dirs.primary,
        "mcpServers" => [],
        "additionalDirectories" => [state.dirs.related],
        "_meta" => %{
          "claudeCode" => %{"options" => %{"managedSettings" => managed_settings}}
        }
      }
    })

    IO.puts(
      "-> session/new  cwd=#{state.dirs.primary}  additionalDirectories=[#{state.dirs.related}]" <>
        "  _meta.claudeCode.options.managedSettings=#{inspect(managed_settings)}"
    )

    %{state | stage: :await_session_new}
  end

  defp dispatch(_handle, %{stage: :await_initialize} = state, %{
         "id" => @initialize_id,
         "error" => err
       }) do
    IO.puts("!! initialize FAILED: #{inspect(err)}")
    %{state | finished?: true}
  end

  defp dispatch(handle, %{stage: :await_session_new} = state, %{
         "id" => @session_new_id,
         "result" => result
       }) do
    session_id = result["sessionId"]
    IO.puts("<- session/new ok (sessionId=#{session_id})")

    prompt_text = """
    Perform exactly these four steps, in order, using your tools. Do not ask \
    for confirmation before attempting each one — just attempt it and report \
    what happened (success, denial, or error) for every step:

    1. Read the file "PRIMARY.md" in your current working directory and \
       quote its contents.
    2. Read the file at the absolute path "#{Path.join(state.dirs.related, "RELATED.md")}" \
       and quote its contents.
    3. Attempt to read the file at the absolute path \
       "#{Path.join(state.dirs.secret, "SECRET.md")}".
    4. Attempt to write the text "probe" to a new file named \
       "PROBE_WRITE.md" in your current working directory.
    """

    send_frame(handle, %{
      "jsonrpc" => "2.0",
      "id" => @prompt_id,
      "method" => "session/prompt",
      "params" => %{
        "sessionId" => session_id,
        "prompt" => [%{"type" => "text", "text" => prompt_text}]
      }
    })

    IO.puts("-> session/prompt (4-step read/read/read-secret/write instructions)")
    %{state | stage: :await_prompt, session_id: session_id}
  end

  defp dispatch(_handle, %{stage: :await_session_new} = state, %{
         "id" => @session_new_id,
         "error" => err
       }) do
    IO.puts("!! session/new FAILED: #{inspect(err)}")
    %{state | finished?: true}
  end

  defp dispatch(_handle, %{stage: :await_prompt} = state, %{
         "id" => @prompt_id,
         "result" => result
       }) do
    stop_reason = result["stopReason"]
    IO.puts("<- session/prompt turn ended (stopReason=#{inspect(stop_reason)})")
    %{state | stop_reason: stop_reason, finished?: true}
  end

  defp dispatch(_handle, %{stage: :await_prompt} = state, %{"id" => @prompt_id, "error" => err}) do
    IO.puts("!! session/prompt FAILED: #{inspect(err)}")
    %{state | finished?: true}
  end

  # --- inbound agent -> client REQUEST: session/request_permission ---------

  defp dispatch(handle, state, %{
         "id" => id,
         "method" => "session/request_permission",
         "params" => params
       }) do
    tool_call = params["toolCall"] || %{}
    raw_input = tool_call["rawInput"] || %{}
    path = raw_input["file_path"] || raw_input["path"] || raw_input["notebook_path"]
    kind = tool_call["kind"]
    title = tool_call["title"]
    options = params["options"] || []

    IO.puts(
      "<- session/request_permission  kind=#{inspect(kind)}  title=#{inspect(title)}  path=#{inspect(path)}"
    )

    # Stand-in for `Valea.Agents.PermissionPolicy.decide/2` +
    # `SessionServer.policy_decide/2`: this is the ONE place a decision is
    # made, and it is made by VALEA CODE reacting to the callback — never by
    # a settings file the adapter resolved on its own. We deny every request
    # this probe receives (safe default for a throwaway script with no human
    # in the loop); what matters for the proof is WHICH actions produce a
    # request at all, not how this stand-in ultimately answers them.
    decision_kind = "reject_once"

    option = Enum.find(options, &(&1["kind"] == decision_kind)) || List.first(options)

    if option do
      send_frame(handle, %{
        "jsonrpc" => "2.0",
        "id" => id,
        "result" => %{"outcome" => %{"outcome" => "selected", "optionId" => option["optionId"]}}
      })

      IO.puts("-> session/request_permission answered: #{decision_kind}")
    end

    secret_prefix = state.dirs.secret

    state = %{
      state
      | permission_log: [
          %{kind: kind, title: title, path: path, decision: decision_kind} | state.permission_log
        ]
    }

    state =
      cond do
        is_binary(path) and String.starts_with?(path, secret_prefix) ->
          %{state | secret_permission_seen?: true}

        kind in ["edit", "write", "delete", "move"] ->
          %{state | write_permission_seen?: true}

        true ->
          state
      end

    state
  end

  # --- inbound agent -> client NOTIFICATION: session/update -----------------

  defp dispatch(_handle, state, %{"method" => "session/update", "params" => %{"update" => u}}) do
    case u["sessionUpdate"] do
      kind when kind in ["tool_call", "tool_call_update"] ->
        entry = "#{u["kind"] || "?"}/#{u["status"] || "?"}: #{u["title"] || u["toolCallId"]}"
        IO.puts("<- session/update  #{entry}")
        note_read(%{state | tool_log: [entry | state.tool_log]}, u)

      "agent_message_chunk" ->
        state

      other ->
        IO.puts("<- session/update  #{other}")
        state
    end
  end

  # Any other inbound REQUEST we never advertised support for: answer
  # "method not found" so the adapter doesn't hang waiting on us.
  defp dispatch(handle, state, %{"id" => id, "method" => method}) do
    IO.puts("<- unhandled request #{method} — replying method-not-found")

    send_frame(handle, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => -32_601, "message" => "Method not found"}
    })

    state
  end

  defp dispatch(_handle, state, _msg), do: state

  # Best-effort marker: a successful tool_call_update whose title/output
  # mentions one of our marker filenames tells us that read went through
  # WITHOUT ever hitting session/request_permission (no matching entry was
  # added to permission_log for it).
  defp note_read(state, u) do
    title = to_string(u["title"] || "")

    cond do
      String.contains?(title, "PRIMARY.md") and u["status"] == "completed" ->
        %{state | reads: Map.put(state.reads, :primary, :completed_no_prompt_seen_yet)}

      String.contains?(title, "RELATED.md") and u["status"] == "completed" ->
        %{state | reads: Map.put(state.reads, :related, :completed_no_prompt_seen_yet)}

      true ->
        state
    end
  end

  # --- final report ----------------------------------------------------------

  defp report(state, dirs) do
    banner("RESULT")

    primary_claude_dir = Path.join(dirs.primary, ".claude")
    related_claude_dir = Path.join(dirs.related, ".claude")
    no_claude_dirs? = not File.dir?(primary_claude_dir) and not File.dir?(related_claude_dir)

    primary_read_ok? = state.reads.primary != :not_seen
    related_read_ok? = state.reads.related != :not_seen

    IO.puts("1. PRIMARY.md read completed:              #{yn(primary_read_ok?)}")

    IO.puts("2. RELATED.md read completed (add-dir):    #{yn(related_read_ok?)}")

    IO.puts("3. secret read reached permission callback: #{yn(state.secret_permission_seen?)}")

    IO.puts("4. write reached permission callback:       #{yn(state.write_permission_seen?)}")

    IO.puts("5. no .claude/ created in primary or related: #{yn(no_claude_dirs?)}")
    IO.puts("   primary .claude present? #{File.dir?(primary_claude_dir)}")
    IO.puts("   related .claude present? #{File.dir?(related_claude_dir)}")
    IO.puts("")
    IO.puts("stopReason: #{inspect(state.stop_reason)}")
    IO.puts("")
    IO.puts("-- permission requests observed (most recent first) --")
    Enum.each(state.permission_log, &IO.inspect/1)
    IO.puts("")
    IO.puts("-- tool_call / tool_call_update notifications observed --")
    state.tool_log |> Enum.reverse() |> Enum.each(&IO.puts("  " <> &1))

    banner("done")
  end

  defp yn(true), do: "YES"
  defp yn(false), do: "no"

  defp banner(text) do
    IO.puts("")
    IO.puts("== #{text} ==")
  end
end

Spike.AcpLaunchProbe.run()
