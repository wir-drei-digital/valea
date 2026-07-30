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

  # windows-support spec B2/B3a. The start spec is what the process adapter
  # sees, so pinning it needs an adapter — a recorder that forwards to the
  # host's real one, injected through the same app-env seam
  # `ProcessRuntime.select_adapter!/0` owns.
  defmodule SpecRecorder do
    @behaviour Valea.Agents.ProcessAdapter

    @impl true
    def start(spec, owner) do
      send(Application.fetch_env!(:valea, :spec_recorder_probe), {:start_spec, spec})
      real().start(spec, owner)
    end

    @impl true
    def write(handle, data), do: real().write(handle, data)

    @impl true
    def stop(handle), do: real().stop(handle)

    defp real, do: Application.fetch_env!(:valea, :spec_recorder_target)
  end

  test "the start spec carries a stderr path under logs/sessions/", %{root: root} do
    Application.put_env(:valea, :spec_recorder_target, Valea.Agents.ProcessRuntime.adapter())
    Application.put_env(:valea, :spec_recorder_probe, self())
    Application.put_env(:valea, :process_adapter, SpecRecorder)

    on_exit(fn ->
      Valea.Agents.ProcessRuntime.select_adapter!()
      Application.delete_env(:valea, :spec_recorder_target)
      Application.delete_env(:valea, :spec_recorder_probe)
    end)

    {:ok, %{id: id}} = start_session(root, "happy")

    assert_receive {:start_spec, spec}, 10_000
    assert spec.cd
    assert String.starts_with?(spec.stderr_path, Path.join([root, "logs", "sessions"]))
    assert String.starts_with?(Path.basename(spec.stderr_path), id <> "-")
    assert String.ends_with?(spec.stderr_path, ".stderr.log")
    # The shim only creates the FILE; the directory has to already exist.
    assert File.dir?(Path.dirname(spec.stderr_path))
  end

  # The liveness question without `attach/1`'s cost: `attach/1` answers it by
  # copying the session's entire timeline back to the caller, which a caller
  # that only wants a yes/no should never pay for (`Valea.Api.Git`'s conflict
  # routing asks it on every "resolve" click).
  test "running?/1 answers liveness without attaching", %{root: root} do
    refute Valea.Agents.SessionServer.running?("no-such-session")

    {:ok, %{id: id}} = start_session(root, "happy")
    assert Valea.Agents.SessionServer.running?(id)

    Valea.AgentCase.kill_session(id)
    refute Valea.Agents.SessionServer.running?(id)
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

  test "interleaved prose and tool calls keep conversation order", %{root: root} do
    {:ok, %{id: id}} = start_session(root, "interleaved")
    Phoenix.PubSub.subscribe(Valea.PubSub, "agent_session:" <> id)

    :ok = Valea.Agents.SessionServer.prompt(id, "hi")
    assert_receive {:session_event, _, %{"type" => "turn"}}, 10_000

    {:ok, %{items: items}} = Valea.Agents.SessionServer.attach(id)

    conversation =
      Enum.flat_map(items, fn
        %{"type" => "message", "role" => "assistant", "text" => text} -> [{:said, text}]
        %{"type" => "tool", "title" => title} -> [{:tool, title}]
        _ -> []
      end)

    # The narration BEFORE the tool stays above its card, and the narration
    # after it is its own bubble below — including the part streamed while
    # the tool was still running, which belongs with what followed it.
    assert conversation == [
             {:said, "Let me read it."},
             {:tool, "Read CONTEXT.md"},
             {:said, "Reading it now."}
           ]
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

  # Spec G Task 7: `:initial_prompt` has existed on `start_session/1` since the
  # first session task but nothing ever asserted it actually reaches the
  # adapter — `revise_mail_draft` now depends on it as its ONLY way to seed a
  # freshly created session (the FE never calls `prompt/2` for that flow), so
  # the enqueue path is pinned here.
  test "initial_prompt is enqueued and sent without any prompt/2 call", %{root: root} do
    {:ok, %{id: id}} = start_session(root, "happy", %{initial_prompt: "seeded hello"})
    Phoenix.PubSub.subscribe(Valea.PubSub, "agent_session:" <> id)

    assert_receive {:session_event, _,
                    %{"type" => "message", "role" => "user", "text" => "seeded hello"}},
                   10_000

    assert_receive {:session_event, _, %{"type" => "message", "role" => "assistant"}}, 10_000
    assert_receive {:session_event, _, %{"type" => "turn"}}, 10_000
  end

  # The Registry VALUE now carries the session's input locator, so a caller
  # holding a file can ask "is a live session already working on this?"
  # without reading a single transcript.
  test "list_running_session_inputs reports each live session's input locator", %{root: root} do
    locator = %{"kind" => "workspace", "path" => "sources/notes/msg.md"}

    {:ok, %{id: with_input}} = start_session(root, "happy", %{input: locator})
    {:ok, %{id: without_input}} = start_session(root, "happy")

    running = Valea.Agents.list_running_session_inputs()

    assert {^with_input, ^locator} = Enum.find(running, &(elem(&1, 0) == with_input))
    assert {^without_input, nil} = Enum.find(running, &(elem(&1, 0) == without_input))
  end

  test "session_info_update title is persisted into transcript meta and listings", %{root: root} do
    {:ok, %{id: id}} = start_session(root, "titled")
    Phoenix.PubSub.subscribe(Valea.PubSub, "agent_session:" <> id)

    path = Path.join(root, "logs/sessions/#{id}.jsonl")
    [meta_line | _] = path |> File.read!() |> String.split("\n", trim: true)
    original = Jason.decode!(meta_line)
    assert original["title"] == "Test"

    :ok = Valea.Agents.SessionServer.prompt(id, "fix the login flow")

    assert_receive {:session_event, _,
                    %{"type" => "session_info", "title" => "T: fix the login flow"}},
                   10_000

    assert_receive {:session_event, _, %{"type" => "turn"}}, 10_000

    # Line 1 now carries the agent's title — and ONLY the title changed; the
    # scenario's trailing nil/"" info pushes must not have clobbered it. The
    # item lines after line 1 survive the rewrite untouched.
    [meta_line | item_lines] = path |> File.read!() |> String.split("\n", trim: true)
    assert Jason.decode!(meta_line) == Map.put(original, "title", "T: fix the login flow")
    assert Enum.any?(item_lines, &(Jason.decode!(&1)["item"]["type"] == "session_info"))

    # The session listing (which reads only line 1) surfaces it.
    {:ok, sessions} = Valea.Agents.list_sessions()
    assert %{"title" => "T: fix the login flow"} = Enum.find(sessions, &(&1["id"] == id))

    # A later turn's fresh title replaces the earlier one.
    :ok = Valea.Agents.SessionServer.prompt(id, "now the signup flow")

    assert_receive {:session_event, _,
                    %{"type" => "session_info", "title" => "T: now the signup flow"}},
                   10_000

    assert_receive {:session_event, _, %{"type" => "turn"}}, 10_000

    [meta_line | _] = path |> File.read!() |> String.split("\n", trim: true)
    assert Jason.decode!(meta_line)["title"] == "T: now the signup flow"
  end

  test "permission request reaches the timeline as ask; answering resolves it", %{root: root} do
    {:ok, %{id: id}} = start_session(root, "permission")
    Phoenix.PubSub.subscribe(Valea.PubSub, "agent_session:" <> id)

    :ok = Valea.Agents.SessionServer.prompt(id, "write")

    assert_receive {:session_event, _, %{"type" => "permission", "resolved" => false} = perm},
                   10_000

    :ok = Valea.Agents.SessionServer.answer_permission(id, perm["id"], "allow_once")

    # `outcome` pinned so this keeps testing the HUMAN answer path — a bare
    # `resolved => true` also matches a policy auto-deny echo.
    assert_receive {:session_event, _,
                    %{"type" => "permission", "resolved" => true, "outcome" => "allow_once"}},
                   10_000

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

    # The session-context injection reaches the ADAPTER, end to end: the
    # same text materialized as context.md rides `_meta.systemPrompt.append`
    # (the adapter locks type/preset and hands `append` to the SDK).
    appended = get_in(params, ["_meta", "systemPrompt", "append"])
    assert is_binary(appended)
    assert appended =~ "Session context (Valea-managed)"
    assert appended =~ icm.mount_key
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
