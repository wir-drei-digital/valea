# Scripted ACP adapter for SessionServer integration tests.
# Scenarios: happy | permission | crash_mid_turn | stderr_noise | hang
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

  defp handle(%{"method" => "session/prompt", "id" => id}, ctx) do
    case ctx.scenario do
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
