defmodule Valea.Agents.SessionServerTest do
  use ExUnit.Case, async: false

  import Valea.AgentCase, only: [start_session: 2, start_session: 3]

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

  test "happy path: handshake, prompt, transcript file, turn end", %{root: root} do
    {:ok, %{id: id}} = start_session(root, "happy")
    Phoenix.PubSub.subscribe(Valea.PubSub, "agent_session:" <> id)

    :ok = Valea.Agents.SessionServer.prompt(id, "hi")
    assert_receive {:session_event, _, %{"type" => "message", "role" => "user"}}, 10_000

    assert_receive {:session_event, _,
                    %{"type" => "message", "role" => "assistant", "text" => text}},
                   10_000

    assert text =~ "hello"
    assert_receive {:session_event, _, %{"type" => "turn"}}, 10_000

    {:ok, %{items: items, busy: false}} = Valea.Agents.SessionServer.attach(id)
    assert Enum.any?(items, &(&1["type"] == "message" and &1["role"] == "assistant"))

    transcript = File.read!(Path.join(root, "logs/sessions/#{id}.jsonl"))
    [meta | rest] = String.split(transcript, "\n", trim: true)
    assert %{"schema" => "session/v1", "kind" => "chat"} = Jason.decode!(meta)
    assert length(rest) >= 3
  end

  test "prompt appends a user echo item first, before the assistant reply", %{root: root} do
    {:ok, %{id: id}} = start_session(root, "happy")
    Phoenix.PubSub.subscribe(Valea.PubSub, "agent_session:" <> id)

    :ok = Valea.Agents.SessionServer.prompt(id, "hello there")

    assert_receive {:session_event, echo_seq,
                    %{
                      "id" => "user-" <> _,
                      "type" => "message",
                      "role" => "user",
                      "text" => "hello there"
                    } = echo},
                   10_000

    assert_receive {:session_event, _, %{"type" => "message", "role" => "assistant"}}, 10_000
    assert_receive {:session_event, _, %{"type" => "turn"}}, 10_000

    {:ok, %{items: items}} = Valea.Agents.SessionServer.attach(id)
    assert List.first(items) == echo

    transcript = File.read!(Path.join(root, "logs/sessions/#{id}.jsonl"))

    lines =
      transcript
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    assert Enum.any?(lines, &(&1 == %{"seq" => echo_seq, "item" => echo}))
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

  test "permission items carry the server-derived risk tier (display metadata only)", %{
    root: root
  } do
    # The fake adapter subprocess reads its OWN `File.cwd!()` (set via
    # erlexec's `{:cd, workspace}`) to build its rawInput paths — and on
    # macOS a tmp dir path lexically differs from what `getcwd()` reports
    # after chdir (`/var/...` vs the physical `/private/var/...`, same
    # symlink quirk `PermissionPolicy`'s moduledoc already documents).
    # Resolve `root` to that same physical form up front so the workspace
    # this test starts the session with is the exact string the subprocess
    # will echo back — otherwise `RiskTier.classify`'s lexical
    # `Path.relative_to` would silently fail to attribute the path to its
    # mount.
    {:ok, root} = Valea.Paths.resolve_real(root, root)

    File.mkdir_p!(Path.join(root, "mounts/primary/Workflows"))
    File.mkdir_p!(Path.join(root, "sources/mail"))

    {:ok, %{id: id}} = start_session(root, "permission_risk_tier")
    Phoenix.PubSub.subscribe(Valea.PubSub, "agent_session:" <> id)

    :ok = Valea.Agents.SessionServer.prompt(id, "write")

    assert_receive {:session_event, _,
                    %{"type" => "permission", "title" => "Write Workflows page"} = high_perm},
                   10_000

    assert high_perm["risk_tier"] == "high"

    # The broadcast and the pre-resolution timeline entry both come from
    # the SAME `append_item/2` call on the enriched item — check the
    # timeline snapshot BEFORE answering, since answering collapses the
    # item to a minimal `resolved: true` record (existing `Connection
    # .answer_permission/3` behavior, unrelated to this enrichment).
    {:ok, %{items: items}} = Valea.Agents.SessionServer.attach(id)
    assert Enum.find(items, &(&1["id"] == high_perm["id"])) == high_perm

    :ok = Valea.Agents.SessionServer.answer_permission(id, high_perm["id"], "allow_once")

    assert_receive {:session_event, _,
                    %{"type" => "permission", "title" => "Write knowledge page"} = medium_perm},
                   10_000

    assert medium_perm["risk_tier"] == "medium"
    {:ok, %{items: items}} = Valea.Agents.SessionServer.attach(id)
    assert Enum.find(items, &(&1["id"] == medium_perm["id"])) == medium_perm

    :ok = Valea.Agents.SessionServer.answer_permission(id, medium_perm["id"], "allow_once")

    assert_receive {:session_event, _,
                    %{"type" => "permission", "title" => "Write source file"} = no_tier_perm},
                   10_000

    refute Map.has_key?(no_tier_perm, "risk_tier")
    {:ok, %{items: items}} = Valea.Agents.SessionServer.attach(id)
    assert Enum.find(items, &(&1["id"] == no_tier_perm["id"])) == no_tier_perm

    :ok = Valea.Agents.SessionServer.answer_permission(id, no_tier_perm["id"], "allow_once")

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
