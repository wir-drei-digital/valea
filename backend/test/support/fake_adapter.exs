# Scripted ACP adapter for SessionServer integration tests.
# Scenarios: happy | titled | interleaved | permission | permission_risk_tier |
# permission_read_policy | crash_mid_turn | stderr_noise | hang | slow
#
# "slow" doubles as the manual browser-testing scenario: a multi-second
# streaming turn, scripted tool calls (read/edit with locations + diff,
# execute with output — both ToolCallCard header layouts), config options on
# session/new (echoed refreshed from session/set_config_option, like
# claude-agent-acp), and a usage_update at turn end — enough surface to
# drive the composer's working indicator, prompt queue, config chips,
# tool cards, and context donut without a real agent.
#
# Speaks NDJSON JSON-RPC on stdio. Dependency-free apart from Jason, which the
# test harness puts on the code path via `elixir -pa _build/test/lib/jason/ebin`.
defmodule FakeAdapter do
  # Well-known relative artifact name for the last-received `session/new`
  # params (see the "Task 1.3" comment on the session/new handler below).
  @session_new_echo_file ".fake_adapter_session_new_params.json"

  def main([scenario]) do
    loop(%{scenario: scenario, session: "fake-sess-1"})
  end

  # `permission_risk_tier`/`permission_read_policy` pass a second arg: the
  # WORKSPACE root (minted by the test via `Valea.AgentCase.open_workspace!/1`
  # and threaded through via `start_session/3`'s `:harness_args`). Since
  # Task 5.4, the subprocess's own `cwd` (`File.cwd!/0`) IS the primary ICM's
  # root already (`ProcessRuntime.start(%{cd: scope.cwd})`) — no longer the
  # workspace — so a scenario that needs to build a path OUTSIDE any mount
  # (e.g. a workspace `sources/...` path) has to be told the workspace root
  # separately; a path INSIDE the mount just uses `File.cwd!/0` directly.
  def main([scenario, workspace_root]) do
    loop(%{scenario: scenario, session: "fake-sess-1", workspace_root: workspace_root})
  end

  defp loop(ctx) do
    case IO.gets("") do
      :eof ->
        :ok

      line ->
        msg = Jason.decode!(line)
        handle(msg, ctx)
        loop(ctx)
    end
  end

  defp handle(%{"method" => "initialize", "id" => id}, ctx) do
    if ctx.scenario == "hang", do: Process.sleep(:infinity)

    reply(id, %{
      "protocolVersion" => 1,
      "agentCapabilities" => %{"loadSession" => false}
    })
  end

  # Task 1.3: record the `session/new` params exactly as received over the
  # wire (including `additionalDirectories` / `_meta.claudeCode.options.
  # managedSettings`, once Phase 5's SessionScope starts sending them) so a
  # SessionServer E2E test can assert what actually crossed the ACP pipe —
  # not just what Connection intended to send. Persisted to a JSON file in
  # the subprocess's own cwd (ProcessRuntime sets that to the session's
  # workspace/ICM root). No test in this task reads it back — every launch
  # today omits both fields, so the file always reflects today's unchanged
  # baseline shape (`%{"cwd" => ..., "mcpServers" => []}`).
  defp handle(%{"method" => "session/new", "id" => id, "params" => params}, ctx) do
    File.write!(Path.join(File.cwd!(), @session_new_echo_file), Jason.encode!(params))

    if ctx.scenario == "slow" do
      reply(id, %{"sessionId" => ctx.session, "configOptions" => slow_config_options(%{})})
    else
      reply(id, %{"sessionId" => ctx.session})
    end
  end

  # claude-agent-acp returns the refreshed configOptions array as the
  # RESPONSE to session/set_config_option (no notification) — mirror that,
  # echoing the chosen value as current for the changed option.
  defp handle(%{"method" => "session/set_config_option", "id" => id, "params" => params}, ctx) do
    if ctx.scenario == "slow" do
      reply(id, %{
        "configOptions" => slow_config_options(%{params["configId"] => params["value"]})
      })
    else
      reply(id, %{})
    end
  end

  defp handle(%{"method" => "session/prompt", "id" => id} = msg, ctx) do
    case ctx.scenario do
      "slow" ->
        update(ctx, %{
          "sessionUpdate" => "agent_message_chunk",
          "content" => %{"type" => "text", "text" => "Thinking this through… "}
        })

        # Three scripted tool calls covering ToolCallCard's two header
        # layouts: read/edit titles that merely restate their location (the
        # compact verb+chip row) and an execute command title that doesn't
        # (full title + separate chip row). Paths are cwd-relative so
        # Connection.put_tool_locations derives a relPath and the chips
        # render clickable.
        cwd = File.cwd!()

        update(ctx, %{
          "sessionUpdate" => "tool_call",
          "toolCallId" => "tool-read-1",
          "title" => "Read CONTEXT.md",
          "kind" => "read",
          "status" => "in_progress",
          "locations" => [%{"path" => Path.join(cwd, "CONTEXT.md"), "line" => 1}]
        })

        Process.sleep(1_500)

        update(ctx, %{
          "sessionUpdate" => "tool_call_update",
          "toolCallId" => "tool-read-1",
          "status" => "completed",
          "content" => [
            %{
              "type" => "content",
              "content" => %{"type" => "text", "text" => "# Context\n\nSeed file contents.\n"}
            }
          ]
        })

        # A PARTIAL read, titled the way the real adapter titles one:
        # "<Verb> <path> (<from> - <to>)", against a path deep enough that
        # the chip has to truncate. Covers both compact-row behaviours —
        # the line span folding into the chip's `:line` suffix, and the
        # directory head ellipsizing while the basename stays whole.
        deep = "research/2026/q3/competitive-analysis/vendor-notes/long-form-summary.md"

        update(ctx, %{
          "sessionUpdate" => "tool_call",
          "toolCallId" => "tool-read-2",
          "title" => "Read #{deep} (88 - 93)",
          "kind" => "read",
          "status" => "in_progress",
          "locations" => [%{"path" => Path.join(cwd, deep), "line" => 88}]
        })

        Process.sleep(800)

        update(ctx, %{
          "sessionUpdate" => "tool_call_update",
          "toolCallId" => "tool-read-2",
          "status" => "completed"
        })

        update(ctx, %{
          "sessionUpdate" => "tool_call",
          "toolCallId" => "tool-edit-1",
          "title" => "Edit CONTEXT.md",
          "kind" => "edit",
          "status" => "in_progress",
          "locations" => [%{"path" => Path.join(cwd, "CONTEXT.md"), "line" => 22}],
          "content" => [
            %{
              "type" => "diff",
              "path" => Path.join(cwd, "CONTEXT.md"),
              "oldText" => "- an old bullet\n",
              "newText" => "- a fresh bullet\n"
            }
          ]
        })

        Process.sleep(1_500)

        update(ctx, %{
          "sessionUpdate" => "tool_call_update",
          "toolCallId" => "tool-edit-1",
          "status" => "completed"
        })

        update(ctx, %{
          "sessionUpdate" => "tool_call",
          "toolCallId" => "tool-exec-1",
          "title" => ~s[grep -ril "related" ./notes],
          "kind" => "execute",
          "status" => "in_progress",
          "locations" => [%{"path" => Path.join(cwd, "notes")}]
        })

        Process.sleep(1_000)

        update(ctx, %{
          "sessionUpdate" => "tool_call_update",
          "toolCallId" => "tool-exec-1",
          "status" => "completed",
          "content" => [
            %{
              "type" => "content",
              "content" => %{"type" => "text", "text" => "notes/a.md\nnotes/b.md\n"}
            }
          ]
        })

        Process.sleep(2_000)

        update(ctx, %{
          "sessionUpdate" => "agent_message_chunk",
          "content" => %{
            "type" => "text",
            "text" =>
              "done.\n\nThe note you asked about is `CONTEXT.md` — reference docs at " <>
                "`https://valea.example.com/docs`.\n\nStill a longer reply with running " <>
                "prose so the full-width assistant layout stays visible, plus a list:\n\n" <>
                "- first point\n- second point\n\nAnd a closing line."
          }
        })

        # `used`/`size` — byte-for-byte the pair claude-agent-acp actually
        # sends, so the composer's donut is exercised on the real shape.
        update(ctx, %{
          "sessionUpdate" => "usage_update",
          "used" => 82_000,
          "size" => 200_000
        })

        reply(id, %{"stopReason" => "end_turn"})

      "titled" ->
        # ACP `session_info_update`: an agent-generated session title pushed
        # at turn end (protocol-level — any ACP agent, not just Claude).
        # Derived from the prompt text so each turn can push a DIFFERENT
        # title without the script needing mutable state. The two title-less
        # pushes after it are the guard cases: neither may clobber the title.
        text = get_in(msg, ["params", "prompt", Access.at(0), "text"]) || ""

        update(ctx, %{"sessionUpdate" => "session_info_update", "title" => "T: " <> text})
        update(ctx, %{"sessionUpdate" => "session_info_update"})
        update(ctx, %{"sessionUpdate" => "session_info_update", "title" => ""})

        update(ctx, %{
          "sessionUpdate" => "agent_message_chunk",
          "content" => %{"type" => "text", "text" => "ok"}
        })

        reply(id, %{"stopReason" => "end_turn"})

      "interleaved" ->
        # The shape every real turn has: the agent narrates, calls a tool,
        # narrates again. The two prose halves belong on either side of the
        # tool card, so they must NOT reduce to one item — and `tool-1`'s
        # completion, landing after the second half started, must not push
        # its card below that prose. `slow` without the sleeps.
        say = fn text ->
          update(ctx, %{
            "sessionUpdate" => "agent_message_chunk",
            "content" => %{"type" => "text", "text" => text}
          })
        end

        say.("Let me read it.")

        update(ctx, %{
          "sessionUpdate" => "tool_call",
          "toolCallId" => "tool-1",
          "title" => "Read CONTEXT.md",
          "kind" => "read",
          "status" => "in_progress"
        })

        say.("Reading")

        update(ctx, %{
          "sessionUpdate" => "tool_call_update",
          "toolCallId" => "tool-1",
          "status" => "completed"
        })

        # Continues the SAME bubble: the completion above revised a card that
        # was already placed, it did not open a new slot in the conversation.
        say.(" it now.")

        reply(id, %{"stopReason" => "end_turn"})

      "crash_mid_turn" ->
        update(ctx, %{
          "sessionUpdate" => "agent_message_chunk",
          "content" => %{"type" => "text", "text" => "part"}
        })

        System.halt(9)

      "permission" ->
        # Target an ordinary knowledge page inside the primary ICM (the
        # adapter's own cwd, Task 5.4) so `PermissionPolicy.decide/2`
        # genuinely returns :ask and the HUMAN answer is what resolves the
        # item. The old "/ws/queue/staging/r1/proposal.json" relic escaped
        # the test workspace, so the policy AUTO-DENIED (reject_once)
        # before any test-driven answer — every "answering resolves it"
        # test was silently exercising the auto-deny echo instead (their
        # `resolved => true` assertions never checked `outcome`).
        request(50, "session/request_permission", %{
          "sessionId" => ctx.session,
          "toolCall" => %{
            "toolCallId" => "t1",
            "title" => "Write file",
            "kind" => "edit",
            "rawInput" => %{"file_path" => Path.join(File.cwd!(), "Pricing/Current Pricing.md")}
          },
          "options" => [
            %{"optionId" => "y", "name" => "Allow", "kind" => "allow_once"},
            %{"optionId" => "ya", "name" => "Always allow", "kind" => "allow_always"},
            %{"optionId" => "n", "name" => "Reject", "kind" => "reject_once"}
          ]
        })

        # wait for the answer before finishing the turn
        answer = IO.gets("") |> Jason.decode!()
        _ = answer

        update(ctx, %{
          "sessionUpdate" => "agent_message_chunk",
          "content" => %{"type" => "text", "text" => "done"}
        })

        reply(id, %{"stopReason" => "end_turn"})

      "permission_risk_tier" ->
        # Three asks in one turn: one behavior-bearing path inside the
        # mounted external ICM (high — a NESTED `CONTEXT.md`, since
        # `RiskTier.classify/1` tiers "high" by basename
        # (AGENTS.md/CLAUDE.md/CONTEXT.md) at ANY depth, or the exact
        # `icm.yaml` path; there is no more path-prefix rule like the old
        # `Workflows/` convention), one ordinary knowledge page inside it
        # (medium), one under the session's own workspace — outside any
        # mount (no tier at all). Since Task 5.4 the subprocess `cwd` IS the
        # primary ICM's own root, so `icm_root` needs no separate arg any
        # more; `ctx.workspace_root` (see `main/1`'s two-arg clause) is only
        # used for the no-tier path. Waits for the answer between each so
        # the SessionServer.answer_permission driving pattern matches the
        # existing "permission" scenario.
        icm_root = File.cwd!()
        workspace_root = Map.get(ctx, :workspace_root, icm_root)

        targets = [
          {"pr1", "Write client CONTEXT.md", Path.join([icm_root, "clients/CONTEXT.md"])},
          {"pr2", "Write knowledge page", Path.join([icm_root, "Pricing/Current Pricing.md"])},
          {"pr3", "Write source file", Path.join([workspace_root, "sources/notes/todo.md"])}
        ]

        Enum.each(targets, fn {rpc_id, title, path} ->
          request(rpc_id, "session/request_permission", %{
            "sessionId" => ctx.session,
            "toolCall" => %{
              "toolCallId" => rpc_id,
              "title" => title,
              "kind" => "edit",
              "rawInput" => %{"file_path" => path}
            },
            "options" => [
              %{"optionId" => "y", "name" => "Allow", "kind" => "allow_once"},
              %{"optionId" => "n", "name" => "Reject", "kind" => "reject_once"}
            ]
          })

          _ = IO.gets("") |> Jason.decode!()
        end)

        update(ctx, %{
          "sessionUpdate" => "agent_message_chunk",
          "content" => %{"type" => "text", "text" => "done"}
        })

        reply(id, %{"stopReason" => "end_turn"})

      "permission_read_policy" ->
        # Two Read asks in one turn, proving the split PermissionPolicy
        # (Task 5.3) is wired against the RIGHT bases post-5.4: a RELATIVE
        # path resolves against `cwd` (== the primary ICM root) and is
        # auto-allowed (it's a `read_root` member); an ABSOLUTE path under
        # the WORKSPACE's own `sources/` is granted to no `read_root`, so it
        # falls through to `:ask` — never auto-allowed for a chat session.
        # `ctx.workspace_root` (see `main/1`'s two-arg clause) builds the
        # second path; the first never needs `cwd` at all, since a relative
        # `rawInput.file_path` is exactly the point being tested.
        workspace_root = Map.get(ctx, :workspace_root, File.cwd!())

        request("rp1", "session/request_permission", %{
          "sessionId" => ctx.session,
          "toolCall" => %{
            "toolCallId" => "rp1",
            "title" => "Read AGENTS.md",
            "kind" => "read",
            "rawInput" => %{"file_path" => "AGENTS.md"}
          },
          "options" => [
            %{"optionId" => "y", "name" => "Allow", "kind" => "allow_once"},
            %{"optionId" => "n", "name" => "Reject", "kind" => "reject_once"}
          ]
        })

        # The FIRST ask is auto-allowed by PermissionPolicy — SessionServer
        # answers it without any test-side intervention, so this just drains
        # that answer off stdin before sending the next request.
        _ = IO.gets("") |> Jason.decode!()

        request("rp2", "session/request_permission", %{
          "sessionId" => ctx.session,
          "toolCall" => %{
            "toolCallId" => "rp2",
            "title" => "Read workspace source",
            "kind" => "read",
            "rawInput" => %{
              "file_path" => Path.join([workspace_root, "sources/notes/todo.md"])
            }
          },
          "options" => [
            %{"optionId" => "y", "name" => "Allow", "kind" => "allow_once"},
            %{"optionId" => "n", "name" => "Reject", "kind" => "reject_once"}
          ]
        })

        # The SECOND ask is `:ask` — nothing auto-answers it; this blocks
        # until the TEST calls `SessionServer.answer_permission/3`.
        _ = IO.gets("") |> Jason.decode!()

        update(ctx, %{
          "sessionUpdate" => "agent_message_chunk",
          "content" => %{"type" => "text", "text" => "done"}
        })

        reply(id, %{"stopReason" => "end_turn"})

      _ ->
        if ctx.scenario == "stderr_noise", do: IO.puts(:stderr, "noise {not json}")

        update(ctx, %{
          "sessionUpdate" => "agent_message_chunk",
          "content" => %{"type" => "text", "text" => "hello"}
        })

        reply(id, %{"stopReason" => "end_turn"})
    end
  end

  defp handle(%{"method" => "session/cancel"}, _ctx), do: :ok
  defp handle(_other, _ctx), do: :ok

  # The "slow" scenario's config surface — three visible options so
  # chip-order regressions are visible, plus an "agent" option (the id
  # claude-agent-acp's AGENT_CONFIG_ID uses) that the composer must HIDE.
  # Stateless across turns: `overrides` only echoes the just-changed
  # option's value as current, defaults otherwise.
  defp slow_config_options(overrides) do
    [
      {"model", "Model", [{"sonnet", "Sonnet"}, {"opus", "Opus"}, {"haiku", "Haiku"}]},
      {"permission-mode", "Permissions",
       [{"default", "Ask"}, {"acceptEdits", "Accept edits"}, {"bypass", "Bypass"}]},
      {"effort", "Effort", [{"low", "Low"}, {"medium", "Medium"}, {"high", "High"}]},
      {"agent", "Agent", [{"main", "Main"}, {"reviewer", "Reviewer"}]}
    ]
    |> Enum.map(fn {id, name, options} ->
      [{default_value, _} | _] = options

      %{
        "configId" => id,
        "name" => name,
        "value" => Map.get(overrides, id, default_value),
        "options" =>
          Enum.map(options, fn {value, label} -> %{"value" => value, "name" => label} end)
      }
    end)
  end

  defp reply(id, result), do: emit(%{"jsonrpc" => "2.0", "id" => id, "result" => result})

  defp request(id, method, params),
    do: emit(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})

  defp update(ctx, u),
    do:
      emit(%{
        "jsonrpc" => "2.0",
        "method" => "session/update",
        "params" => %{"sessionId" => ctx.session, "update" => u}
      })

  defp emit(map), do: IO.puts(Jason.encode!(map))
end

FakeAdapter.main(System.argv())
