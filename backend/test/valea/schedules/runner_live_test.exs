defmodule Valea.Schedules.RunnerLiveTest do
  # async: false — `Valea.AgentCase.open_workspace!/1` mutates `VALEA_APP_DIR`
  # (VM-global) and opens a real workspace.
  use ExUnit.Case, async: false

  alias Valea.AgentCase
  alias Valea.Schedules.Entry
  alias Valea.Schedules.Runner

  @slot ~U[2026-07-30 09:00:00Z]

  # -- the preamble, pinned verbatim -------------------------------------------

  describe "preamble/2 and initial_prompt/2" do
    test "the preamble is the spec's sentence, word for word" do
      entry = entry("Morning inbox brief", "Work the inbox-triage workflow.")

      # Double-quoted, never `~S(...)`: the sentence under test contains a `)`,
      # which is precisely how the implementation of this string was broken for
      # a while (the sigil closed early and the rest parsed as `binary in
      # binary`). A test that cannot express the expected value is no test.
      assert Runner.Live.preamble(entry, meta()) ==
               "Scheduled run \"Morning inbox brief\" (s-morning) in Work. " <>
                 "You are running unattended; if you get blocked, record what's needed in " <>
                 "tasks.json and end the session."
    end

    test "the initial prompt is the preamble, a blank line, then the schedule's prompt verbatim" do
      entry = entry("Nightly", "Summarise today.\n\n- keep the bullets\n")

      assert Runner.Live.initial_prompt(entry, meta()) ==
               "Scheduled run \"Nightly\" (s-morning) in Work. " <>
                 "You are running unattended; if you get blocked, record what's needed in " <>
                 "tasks.json and end the session." <>
                 "\n\nSummarise today.\n\n- keep the bullets\n"
    end

    test "a title with quotes or parentheses composes as written" do
      entry = entry("Review \"Q3 (draft)\" notes", "go")

      assert Runner.Live.preamble(entry, meta()) ==
               "Scheduled run \"Review \"Q3 (draft)\" notes\" (s-morning) in Work. " <>
                 "You are running unattended; if you get blocked, record what's needed in " <>
                 "tasks.json and end the session."
    end
  end

  # -- a real prompt fire ------------------------------------------------------

  describe "start_prompt/3 end to end" do
    setup do
      workspace = AgentCase.open_workspace!("Sched")
      icm = AgentCase.mount_test_icm!(workspace.path, name: "Work", pages: %{"Doc.md" => "# Doc"})
      Valea.App.Config.set_harness_command(AgentCase.fake_cmd("titled"))

      %{workspace: workspace, icm: icm}
    end

    test "starts a scheduled session whose FIRST prompt is the composed initial prompt", ctx do
      entry = entry("Morning inbox brief", "Work the inbox-triage workflow.")
      meta = live_meta(ctx)

      assert {:ok, session_id} = Runner.Live.start_prompt(mount(ctx), entry, meta)

      Phoenix.PubSub.subscribe(Valea.PubSub, "agent_session:" <> session_id)

      assert_receive {:session_event, _seq,
                      %{"type" => "message", "role" => "user", "text" => text}},
                     15_000

      assert text == Runner.Live.initial_prompt(entry, meta)
      assert text =~ "Scheduled run \"Morning inbox brief\" (s-morning) in Work."
      assert text =~ "Work the inbox-triage workflow."
    end

    test "the session is kind \"scheduled\" and titled with the slot's local date", ctx do
      entry = entry("Morning inbox brief", "go")

      assert {:ok, session_id} = Runner.Live.start_prompt(mount(ctx), entry, live_meta(ctx))

      {:ok, sessions} = Valea.Agents.list_sessions()
      session = Enum.find(sessions, &(&1["id"] == session_id))

      assert session["kind"] == "scheduled"
      assert session["title"] == "Morning inbox brief — 2026-07-30"
    end

    test "a context_doc that names nothing fails the fire instead of starting a blind session",
         ctx do
      entry =
        entry("Morning", "go", %{
          kind: :prompt,
          prompt: "go",
          context_doc: "Missing/Nowhere.md"
        })

      assert {:error, :context_doc_unavailable} =
               Runner.Live.start_prompt(mount(ctx), entry, live_meta(ctx))
    end

    test "a context_doc that exists is passed through as a stable ICM locator", ctx do
      entry = entry("Morning", "go", %{kind: :prompt, prompt: "go", context_doc: "Doc.md"})

      assert {:ok, session_id} = Runner.Live.start_prompt(mount(ctx), entry, live_meta(ctx))

      path = Path.join([ctx.workspace.path, "logs", "sessions", session_id <> ".jsonl"])

      meta =
        path
        |> await_file!()
        |> String.split("\n", trim: true)
        |> hd()
        |> Jason.decode!()

      assert meta["context_doc"] == %{
               "kind" => "icm",
               "icm_id" => ctx.icm.id,
               "path" => "Doc.md"
             }
    end

    # M3: `SessionScope.resolve/1` talks to `Valea.Workspace.Manager` on its own
    # 5 s leash, and this call happens INSIDE the scheduler process — a Runtime
    # child, which the Manager waits for while closing. A suspended Manager
    # stands in for "busy closing": the launch must give up quickly with an
    # error the fire can record, not block for five seconds and exit the caller.
    test "a Manager that cannot answer times the launch out instead of blocking on it", ctx do
      # Built BEFORE the suspend: `live_meta/1` reads the generation, which is
      # itself a Manager call.
      meta = live_meta(ctx)
      mount = mount(ctx)
      entry = entry("Morning", "go")

      :sys.suspend(Valea.Workspace.Manager)
      on_exit(fn -> safe_resume() end)

      task = Task.async(fn -> Runner.Live.start_prompt(mount, entry, meta) end)

      # Inside the 2 s scope leash, and well inside the 5 s the un-bounded call
      # would have burned before exiting the caller.
      assert {:error, :scope_timeout} = Task.await(task, 4_000)
      safe_resume()
    end
  end

  # -- helpers -----------------------------------------------------------------

  # The transcript is written by the session process, so it appears a beat after
  # `start_prompt/3` returns. Bounded poll — no fixed sleep.
  defp await_file!(path, attempts \\ 100) do
    case File.read(path) do
      {:ok, data} when data != "" ->
        data

      _not_yet when attempts > 0 ->
        Process.sleep(25)
        await_file!(path, attempts - 1)

      _giving_up ->
        flunk("transcript never appeared at #{path}")
    end
  end

  defp safe_resume do
    if Process.whereis(Valea.Workspace.Manager), do: :sys.resume(Valea.Workspace.Manager)
  catch
    _kind, _reason -> :ok
  end

  defp entry(title, prompt, payload \\ nil) do
    %Entry{
      id: "s-morning",
      title: title,
      timezone: "Etc/UTC",
      payload: payload || %{kind: :prompt, prompt: prompt, context_doc: nil},
      disposition: :executable,
      fingerprint: "fp1",
      paused: false,
      catchup: false,
      raw: %{}
    }
  end

  # A meta for the pure-composition tests: no workspace needed.
  defp meta do
    %{
      icm_id: "icm-1",
      icm_name: "Work",
      mount_key: "work",
      schedule_id: "s-morning",
      fingerprint: "fp1",
      slot: @slot,
      trigger: "scheduled",
      coalesced_count: 1,
      generation: 1,
      run_id: "run-1",
      workspace_root: "/nowhere"
    }
  end

  defp live_meta(ctx) do
    %{
      meta()
      | icm_id: ctx.icm.id,
        mount_key: ctx.icm.mount_key,
        generation: Valea.Workspace.Manager.generation(),
        workspace_root: ctx.workspace.path
    }
  end

  defp mount(ctx) do
    %{
      name: ctx.icm.mount_key,
      root: ctx.icm.root,
      manifest: %Valea.Mounts.Manifest{format: 2, id: ctx.icm.id, name: "Work"},
      enabled: true,
      degraded: nil,
      kind: :icm
    }
  end
end
