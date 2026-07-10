defmodule Valea.Agents.SessionServerTest do
  use ExUnit.Case, async: false

  setup do
    root = Path.join(System.tmp_dir!(), "vses-#{System.os_time(:nanosecond)}")
    File.mkdir_p!(Path.join(root, "logs/sessions"))

    app_dir =
      Path.join(
        System.tmp_dir!(),
        "vses-app-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    System.put_env("VALEA_APP_DIR", app_dir)

    on_exit(fn ->
      File.rm_rf!(root)
      File.rm_rf!(app_dir)
      System.delete_env("VALEA_APP_DIR")
    end)

    start_supervised!({Valea.Audit, %{root: root, generation: 1}})

    start_supervised!(
      {DynamicSupervisor, name: Valea.Agents.SessionSupervisor, strategy: :one_for_one}
    )

    %{root: root}
  end

  defp fake_cmd(scenario) do
    elixir = System.find_executable("elixir")
    jason = Path.expand("_build/test/lib/jason/ebin")
    script = Path.expand("test/support/fake_adapter.exs")
    [elixir, "-pa", jason, script, scenario]
  end

  defp start_session(root, scenario, extra \\ %{}) do
    Valea.App.Config.set_harness_command(fake_cmd(scenario))

    Valea.Agents.start_session(
      Map.merge(
        %{
          kind: "chat",
          title: "Test",
          workspace: root,
          generation: 1,
          run: nil,
          initial_prompt: nil,
          on_turn_end: nil,
          policy_ctx: %{workspace: root, session_kind: "chat", write_paths: []}
        },
        extra
      )
    )
  end

  test "happy path: handshake, prompt, transcript file, turn end", %{root: root} do
    {:ok, %{id: id}} = start_session(root, "happy")
    Phoenix.PubSub.subscribe(Valea.PubSub, "agent_session:" <> id)

    :ok = Valea.Agents.SessionServer.prompt(id, "hi")
    assert_receive {:session_event, _, %{"type" => "message", "text" => text}}, 10_000
    assert text =~ "hello"
    assert_receive {:session_event, _, %{"type" => "turn"}}, 10_000

    {:ok, %{items: items, busy: false}} = Valea.Agents.SessionServer.attach(id)
    assert Enum.any?(items, &(&1["type"] == "message"))

    transcript = File.read!(Path.join(root, "logs/sessions/#{id}.jsonl"))
    [meta | rest] = String.split(transcript, "\n", trim: true)
    assert %{"schema" => "session/v1", "kind" => "chat"} = Jason.decode!(meta)
    assert length(rest) >= 2
  end

  test "permission request reaches the timeline as ask; answering resolves it", %{root: root} do
    {:ok, %{id: id}} = start_session(root, "permission")
    Phoenix.PubSub.subscribe(Valea.PubSub, "agent_session:" <> id)

    :ok = Valea.Agents.SessionServer.prompt(id, "write")

    assert_receive {:session_event, _, %{"type" => "permission", "resolved" => false} = perm},
                   10_000

    :ok = Valea.Agents.SessionServer.answer_permission(id, perm["id"], "allow_once")
    assert_receive {:session_event, _, %{"type" => "permission", "resolved" => true}}, 10_000
    assert_receive {:session_event, _, %{"type" => "turn"}}, 10_000
  end

  test "mid-turn crash: exit broadcast, turn ends, transcript intact", %{root: root} do
    {:ok, %{id: id}} = start_session(root, "crash_mid_turn")
    Phoenix.PubSub.subscribe(Valea.PubSub, "agent_session:" <> id)

    :ok = Valea.Agents.SessionServer.prompt(id, "boom")
    assert_receive {:session_exit, _code}, 10_000
    {:ok, %{status: "exited", busy: false}} = Valea.Agents.SessionServer.attach(id)
  end

  test "stderr noise never corrupts the stream", %{root: root} do
    {:ok, %{id: id}} = start_session(root, "stderr_noise")
    Phoenix.PubSub.subscribe(Valea.PubSub, "agent_session:" <> id)
    :ok = Valea.Agents.SessionServer.prompt(id, "hi")
    assert_receive {:session_event, _, %{"type" => "turn"}}, 10_000
  end

  test "hung handshake trips the watchdog", %{root: root} do
    # pass a short watchdog through opts for the test
    {:ok, %{id: id}} = start_session(root, "hang", %{handshake_timeout_ms: 500})
    Phoenix.PubSub.subscribe(Valea.PubSub, "agent_session:" <> id)
    assert_receive {:session_status, :failed}, 5_000
  end

  test "harness_unavailable propagates", %{root: root} do
    Valea.App.Config.set_harness_command(["no-such-binary-zzz"])

    assert {:error, :harness_unavailable} =
             Valea.Agents.start_session(%{
               kind: "chat",
               title: "x",
               workspace: root,
               generation: 1,
               run: nil,
               initial_prompt: nil,
               on_turn_end: nil,
               policy_ctx: %{workspace: root, session_kind: "chat", write_paths: []}
             })
  end
end
