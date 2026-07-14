# Scripted ACP adapter for SessionServer integration tests.
# Scenarios: happy | permission | permission_risk_tier | permission_read_policy |
# crash_mid_turn | stderr_noise | hang | workflow_happy
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
  # workspace/ICM root), the same externally-observable-artifact pattern
  # `workflow_happy` already uses for its staged proposal.json. No test in
  # this task reads it back — every launch today omits both fields, so the
  # file always reflects today's unchanged baseline shape
  # (`%{"cwd" => ..., "mcpServers" => []}`).
  defp handle(%{"method" => "session/new", "id" => id, "params" => params}, ctx) do
    File.write!(Path.join(File.cwd!(), @session_new_echo_file), Jason.encode!(params))
    reply(id, %{"sessionId" => ctx.session})
  end

  defp handle(%{"method" => "session/prompt", "id" => id, "params" => params}, ctx) do
    case ctx.scenario do
      "workflow_happy" ->
        params
        |> prompt_text()
        |> staging_path!()
        |> File.write!(Jason.encode!(workflow_proposal()))

        update(ctx, %{
          "sessionUpdate" => "agent_message_chunk",
          "content" => %{"type" => "text", "text" => "Drafted a reply for review."}
        })

        reply(id, %{"stopReason" => "end_turn"})

      "crash_mid_turn" ->
        update(ctx, %{
          "sessionUpdate" => "agent_message_chunk",
          "content" => %{"type" => "text", "text" => "part"}
        })

        System.halt(9)

      "permission" ->
        request(50, "session/request_permission", %{
          "sessionId" => ctx.session,
          "toolCall" => %{
            "toolCallId" => "t1",
            "title" => "Write file",
            "kind" => "edit",
            "rawInput" => %{"file_path" => "/ws/queue/staging/r1/proposal.json"}
          },
          "options" => [
            %{"optionId" => "y", "name" => "Allow", "kind" => "allow_once"},
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
        # mounted external ICM (high), one ordinary knowledge page inside
        # it (medium), one under the session's own workspace — outside any
        # mount (no tier at all). Since Task 5.4 the subprocess `cwd` IS the
        # primary ICM's own root, so `icm_root` needs no separate arg any
        # more; `ctx.workspace_root` (see `main/1`'s two-arg clause) is only
        # used for the no-tier path. Waits for the answer between each so
        # the SessionServer.answer_permission driving pattern matches the
        # existing "permission" scenario.
        icm_root = File.cwd!()
        workspace_root = Map.get(ctx, :workspace_root, icm_root)

        targets = [
          {"pr1", "Write Workflows page",
           Path.join([icm_root, "Workflows/New Inquiry Triage.md"])},
          {"pr2", "Write knowledge page", Path.join([icm_root, "Pricing/Current Pricing.md"])},
          {"pr3", "Write source file", Path.join([workspace_root, "sources/mail/inbox.md"])}
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
              "file_path" => Path.join([workspace_root, "sources/mail/inbox.md"])
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

  # `workflow_happy` never receives its output path as an argument — it reads
  # the prompt Valea.Workflows.Runner composed and greps out the exact
  # staging path the run named, matching how a real ACP agent would.
  defp prompt_text(%{"prompt" => blocks}) when is_list(blocks) do
    blocks
    |> Enum.filter(&(is_map(&1) and &1["type"] == "text"))
    |> Enum.map_join("", &(&1["text"] || ""))
  end

  defp prompt_text(_params), do: ""

  # Task 5.5: `Valea.Workflows.Runner.prompt/3` now embeds the ABSOLUTE
  # `write_paths` grant (never a workspace-relative path) — cwd is the
  # owning ICM's own root, not the workspace, so only an absolute
  # destination is unambiguous. Capture whatever's inside the surrounding
  # quotes, not just a "queue/staging/..." suffix, so this scenario writes
  # to the SAME location the real ACP write-permission check would resolve
  # against.
  defp staging_path!(text) do
    case Regex.run(~r{"([^"]*/proposal\.json)"}, text) do
      [_, path] -> path
      nil -> raise "workflow_happy: no .../proposal.json path in prompt"
    end
  end

  defp workflow_proposal do
    %{
      "schema" => "proposal/v1",
      "kind" => "email_draft",
      "title" => "Reply to Priya Nair — coaching inquiry",
      "summary" => "Good-fit inquiry. Drafted a warm reply proposing a discovery call.",
      "sources" => ["sources/mail/messages/2026-07-09-priya-nair-seed0001.md"],
      "proposed_action" => %{
        "type" => "create_email_draft",
        "to" => "priya@example.com",
        "subject" => "Re: Question about leadership coaching",
        "body_markdown" => "Hi Priya, thanks for reaching out — here's a bit more detail."
      },
      "reasoning" => "Classified good-fit because the inquiry matches the founder coaching offer."
    }
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
