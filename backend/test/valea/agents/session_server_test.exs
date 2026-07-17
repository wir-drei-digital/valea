defmodule Valea.Agents.SessionServerTest do
  use ExUnit.Case, async: false

  import Valea.AgentCase, only: [start_session: 2, start_session: 3]

  # Since Task 5.4 every session launches through a `SessionScope`
  # (`Valea.Agents.SessionScope.resolve/1`), which resolves against the
  # CURRENTLY OPEN workspace (`Valea.Workspace.Manager.current/0`) and a
  # mounted, enabled primary ICM — a bare tmp dir (this suite's pre-5.4
  # setup) is no longer enough. `open_workspace!/1` opens a real (legacy v4)
  # workspace via the Manager — which also starts `Valea.Workspace.Runtime`
  # (Audit, the agent SessionSupervisor, ...), so the manual
  # `start_supervised!` calls this suite used to need are gone too —
  # and `mount_test_icm!/2` mounts the "Primary" ICM every test in this
  # file uses as its session's primary (see `AgentCase.start_session/3`'s
  # own moduledoc: the first enabled mount is the implicit default).
  setup do
    ws = Valea.AgentCase.open_workspace!()
    icm = Valea.AgentCase.mount_test_icm!(ws.path, name: "Primary")
    %{root: ws.path, ws: ws, icm: icm}
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

  test "transcript line 1 (session/v1) snapshots workspace + ICM identity", %{
    root: root,
    ws: ws,
    icm: icm
  } do
    {:ok, %{id: id}} = start_session(root, "happy")

    transcript = File.read!(Path.join(root, "logs/sessions/#{id}.jsonl"))
    [meta_line | _rest] = String.split(transcript, "\n", trim: true)
    meta = Jason.decode!(meta_line)

    assert meta == %{
             "schema" => "session/v1",
             "id" => id,
             "acp_session_id" => nil,
             "workspace_id" => ws.id,
             "workspace_name" => ws.name,
             "icm_mount" => icm.mount_key,
             "icm_id" => icm.id,
             "icm_name" => "Primary",
             "icm_root" => icm.root,
             "kind" => "chat",
             "workflow" => nil,
             "run_id" => nil,
             "context_doc" => nil,
             "input" => nil,
             "include_mounts" => [],
             "title" => "Test",
             "harness" => "claude_code",
             "generation" => meta["generation"],
             "started_at" => meta["started_at"]
           }

    assert is_integer(meta["generation"])
    assert is_binary(meta["started_at"])
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
    # Every mount is EXTERNAL (`Valea.Mounts` is config-truth over `icms:`
    # only) — the `setup` block above already mounted "Primary" (this
    # session's cwd, per Task 5.4). `permission_risk_tier`'s two in-mount
    # targets are built by the fake adapter against its OWN `cwd` (now the
    # ICM root already); the third, out-of-mount target needs the
    # WORKSPACE root instead, threaded through `:harness_args` (see
    # `fake_adapter.exs`'s `main/1` two-arg clause).
    {:ok, %{id: id}} =
      start_session(root, "permission_risk_tier", %{harness_args: [root]})

    Phoenix.PubSub.subscribe(Valea.PubSub, "agent_session:" <> id)

    :ok = Valea.Agents.SessionServer.prompt(id, "write")

    assert_receive {:session_event, _,
                    %{"type" => "permission", "title" => "Write client CONTEXT.md"} = high_perm},
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

  # -- Task 5.4: the redesign's core invariant ------------------------------

  test "process cwd, ACP session/new cwd, additionalDirectories, and managedSettings all come from the scope",
       %{root: root, icm: icm} do
    related_id = Ecto.UUID.generate()
    related = Valea.AgentCase.mount_test_icm!(root, name: "Related", id: related_id)

    File.write!(Path.join(icm.root, "CONTEXT.md"), """
    ---
    format: 1
    related_icms:
      - id: #{related_id}
        name: "Related"
    ---
    """)

    {:ok, %{id: id}} = start_session(root, "happy", %{mount_key: icm.mount_key})
    Phoenix.PubSub.subscribe(Valea.PubSub, "agent_session:" <> id)
    # The handshake only reaches :running once `session/new`'s reply is
    # processed — by then the fake adapter has already written the echo
    # file (it writes BEFORE replying, see fake_adapter.exs).
    assert_receive {:session_status, :running}, 10_000

    # The subprocess's own cwd is the primary ICM root — never the
    # workspace — proven by where the fake adapter's echo file landed at
    # all (ProcessRuntime set `{:cd, icm.root}`; ProcessRuntime.write/2's
    # relay would have failed to spawn entirely under a bogus cwd).
    echo_path = Path.join(icm.root, ".fake_adapter_session_new_params.json")
    assert File.regular?(echo_path)
    params = echo_path |> File.read!() |> Jason.decode!()

    assert params["cwd"] == icm.root
    assert related.root in (params["additionalDirectories"] || [])
    assert is_binary(get_in(params, ["_meta", "claudeCode", "options", "managedSettings"]))
  end

  test "a relative Read resolves against the ICM cwd and is allowed; a workspace source path is :ask",
       %{root: root} do
    {:ok, %{id: id}} =
      start_session(root, "permission_read_policy", %{harness_args: [root]})

    Phoenix.PubSub.subscribe(Valea.PubSub, "agent_session:" <> id)

    :ok = Valea.Agents.SessionServer.prompt(id, "read")

    # AGENTS.md (relative, resolves against cwd == the ICM root, a
    # read_root member) is auto-ALLOWED by the split PermissionPolicy — no
    # test-side answer needed, the server already answered it.
    # `Connection.answer_permission/3`'s resolved item drops `title` (it's
    # a minimal `%{id, type, resolved, outcome}` record — see its own
    # moduledoc note on the earlier risk-tier test) — matched by `id`
    # (`perm-rp1`, the fake adapter's own `toolCallId`) instead.
    assert_receive {:session_event, _,
                    %{
                      "type" => "permission",
                      "id" => "perm-rp1",
                      "resolved" => true,
                      "outcome" => "allow_once"
                    }},
                   10_000

    # The absolute workspace `sources/...` path is granted to no
    # read_root, so it falls through to :ask — never auto-allowed for a
    # chat session, even though it's a plain Read.
    assert_receive {:session_event, _,
                    %{
                      "type" => "permission",
                      "title" => "Read workspace source",
                      "resolved" => false
                    } = ask},
                   10_000

    :ok = Valea.Agents.SessionServer.answer_permission(id, ask["id"], "allow_once")
    assert_receive {:session_event, _, %{"type" => "turn"}}, 10_000
  end
end
