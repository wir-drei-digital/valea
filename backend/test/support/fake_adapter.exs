# Scripted ACP adapter for SessionServer integration tests.
# Scenarios: happy | permission | permission_risk_tier | crash_mid_turn |
# stderr_noise | hang | workflow_happy
#
# Speaks NDJSON JSON-RPC on stdio. Dependency-free apart from Jason, which the
# test harness puts on the code path via `elixir -pa _build/test/lib/jason/ebin`.
defmodule FakeAdapter do
  def main([scenario]) do
    loop(%{scenario: scenario, session: "fake-sess-1"})
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

  defp handle(%{"method" => "session/new", "id" => id}, ctx) do
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
        # Three asks in one turn, each against a real path under the
        # session's own workspace (ProcessRuntime sets the subprocess cwd
        # to the workspace) — one behavior-bearing (high), one ordinary
        # knowledge page (medium), one outside any mount (no tier at all).
        # Waits for the answer between each so the SessionServer.answer_
        # permission driving pattern matches the existing "permission"
        # scenario.
        cwd = File.cwd!()

        targets = [
          {"pr1", "Write Workflows page",
           Path.join([cwd, "mounts/primary/Workflows/New Inquiry Triage.md"])},
          {"pr2", "Write knowledge page",
           Path.join([cwd, "mounts/primary/Pricing/Current Pricing.md"])},
          {"pr3", "Write source file", Path.join([cwd, "sources/mail/inbox.md"])}
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

  defp staging_path!(text) do
    case Regex.run(~r{queue/staging/[^"\s]+/proposal\.json}, text) do
      [path] -> path
      nil -> raise "workflow_happy: no queue/staging/.../proposal.json path in prompt"
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
