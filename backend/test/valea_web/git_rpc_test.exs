defmodule ValeaWeb.GitRpcTest do
  @moduledoc """
  The git RPC surface over the REAL transport (`/rpc/run`), mirroring
  `ValeaWeb.AgentsRpcTest`'s harness — deliberately not the direct
  `Ash.run_action/1` style of `Valea.Api.IcmsTest`, because half of what
  this task promises is an ash_typescript EXTRACTION property: repo rows
  ride an untyped `{:array, :map}` so their snake_case keys and their
  `false`s survive, and `session_id` comes back camelCased while the rows'
  own `mount_key` does not.

  Everything here needs a real git binary and a real repo topology
  (`GitFixtures`), and a real open workspace — so the whole module skips
  without git and is `async: false` (the Manager, the `VALEA_APP_DIR` env
  var and the singleton `Valea.Git.Engine` are all process-global).
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  @endpoint ValeaWeb.Endpoint

  alias Valea.AgentCase
  alias Valea.Git.Engine
  alias Valea.Mounts
  alias Valea.Mounts.Manifest
  alias Valea.Workspace.Manager

  if not GitFixtures.git_available?(), do: @moduletag(:skip)

  setup do
    # The Engine is started by the workspace Runtime, so every seam it reads
    # has to be in place BEFORE the workspace opens. The poll is pushed out of
    # reach: every pass in this suite is one a test asked for.
    Application.put_env(:valea, :git_sync_probe, self())
    Application.put_env(:valea, :git_poll_interval_ms, 3_600_000)
    Application.put_env(:valea, :git_poll_jitter, 0)

    on_exit(fn ->
      Application.delete_env(:valea, :git_sync_probe)
      Application.delete_env(:valea, :git_poll_interval_ms)
      Application.delete_env(:valea, :git_poll_jitter)
    end)

    ws = AgentCase.open_workspace!("Primary")

    fx = GitFixtures.remote_and_clones!(tmp_dir!("vgit-rpc"))

    # The clone becomes a real ICM, manifest COMMITTED — so the repo starts
    # clean and any `dirty` a row reports is something a test did.
    Manifest.write!(fx.work, %{id: Ecto.UUID.generate(), name: "Work ICM", description: ""})
    GitFixtures.git!(fx.work, ["add", "-A"])
    GitFixtures.git!(fx.work, ["commit", "-m", "icm manifest"])
    GitFixtures.git!(fx.work, ["push", "origin", "main"])

    {:ok, %{mount_key: key}} = Mounts.mount(ws.path, fx.work)

    %{workspace: ws.path, generation: Manager.generation(), fx: fx, key: key}
  end

  # -- helpers -----------------------------------------------------------------

  defp rpc(action, input, fields) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-valea-token", "valea-dev-token")
    |> post("/rpc/run", %{"action" => action, "input" => input, "fields" => fields})
    |> json_response(200)
  end

  defp tmp_dir!(prefix) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "#{prefix}-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  # What Valea itself puts into every ICM root — the folder the offer is
  # about.
  defp materialize_valea!(root) do
    File.mkdir_p!(Path.join(root, ".valea"))
    File.write!(Path.join(root, ".valea/briefing.md"), "valea's own working data\n")
  end

  # Triggers a pass and waits for one whose row for `key` reads `want`. Passes
  # this suite did not ask for (the Engine's own activation pass) are simply
  # skipped rather than asserted against.
  defp sync!(key, want) do
    :ok = Engine.sync_now(key)
    await_row!(key, want)
  end

  defp await_row!(key, want, timeout \\ 20_000) do
    await_row!(key, want, System.monotonic_time(:millisecond) + timeout, nil)
  end

  defp await_row!(key, want, deadline, last) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      flunk("#{key} never reached #{want} (last row: #{inspect(last)})")
    else
      receive do
        {:git_pass_finished, statuses} ->
          case Map.get(statuses, key) do
            %{state: ^want} = row -> row
            other -> await_row!(key, want, deadline, other)
          end
      after
        remaining -> flunk("#{key} never reached #{want} (last row: #{inspect(last)})")
      end
    end
  end

  defp transcript_lines(workspace, id) do
    Path.join([workspace, "logs", "sessions", id <> ".jsonl"]) |> File.stream!()
  end

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never became true")
      true -> Process.sleep(20) && wait_until(fun, tries - 1)
    end
  end

  # -- git_status ----------------------------------------------------------------

  describe "git_status" do
    test "returns the engine's rows, snake-keyed, without the engine's internal bookkeeping",
         %{generation: generation, key: key} do
      sync!(key, "ok")

      assert %{"success" => true, "data" => %{"repos" => [row]}} =
               rpc("git_status", %{"generation" => generation}, ["repos"])

      assert row["mount_key"] == key
      assert row["icm_name"] == "Work ICM"
      assert row["state"] == "ok"
      assert row["mode"] == "pull"
      assert row["branch"] == "main"
      assert row["ahead"] == 0
      assert row["behind"] == 0
      # A legitimate `false` inside an ARRAY item survives ash_typescript's
      # extraction (the top-level falsy rule is what needs string keys) —
      # this is the assertion that says the row shape is honest.
      assert row["dirty"] == false
      assert row["last_error"] == nil
      assert row["conflict_session_id"] == nil
      assert is_binary(row["last_sync_at"])
      assert is_binary(row["local_sha"])

      # `block_fingerprint` is the Engine's own memory of a tree git refused
      # to fast-forward. It is not a thing any UI renders, and it must never
      # reach one.
      refute Map.has_key?(row, "block_fingerprint")
    end

    test "a stale generation is refused before the engine is asked", %{generation: generation} do
      assert %{"success" => false, "errors" => errors} =
               rpc("git_status", %{"generation" => generation + 1}, ["repos"])

      assert inspect(errors) =~ "workspace_changed"
    end
  end

  # -- git_sync_now / set_icm_git_sync -------------------------------------------

  describe "git_sync_now and set_icm_git_sync" do
    test "sync_now starts a pass and set_icm_git_sync persists the mode", %{
      workspace: workspace,
      generation: generation,
      key: key
    } do
      assert %{"success" => true, "data" => %{"started" => true}} =
               rpc("git_sync_now", %{"mountKey" => key, "generation" => generation}, ["started"])

      assert await_row!(key, "ok")

      assert Mounts.git_config(workspace, key).sync == :pull

      assert %{"success" => true, "data" => %{"saved" => true}} =
               rpc(
                 "set_icm_git_sync",
                 %{"mountKey" => key, "sync" => "full", "generation" => generation},
                 ["saved"]
               )

      assert Mounts.git_config(workspace, key).sync == :full

      # The write broadcasts `{:mounts_changed}`, which the Engine takes as
      # "the set of rows I own may be different now" — the row's mode follows
      # without anyone asking for a sync.
      assert %{mode: "full"} = await_row!(key, "ok")
    end

    test "an unknown mount key is not a syncing repository", %{generation: generation} do
      assert %{"success" => false, "errors" => errors} =
               rpc("git_sync_now", %{"mountKey" => "ghost", "generation" => generation}, [
                 "started"
               ])

      assert inspect(errors) =~ "not a syncing git repository"
    end

    test "a bad sync mode never reaches disk", %{generation: generation, key: key} do
      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "set_icm_git_sync",
                 %{"mountKey" => key, "sync" => "sideways", "generation" => generation},
                 ["saved"]
               )

      assert inspect(errors) =~ "full, pull, off"
    end

    test "a stale generation is refused by both mutations", %{generation: generation, key: key} do
      assert %{"success" => false, "errors" => errors} =
               rpc("git_sync_now", %{"mountKey" => key, "generation" => generation + 1}, [
                 "started"
               ])

      assert inspect(errors) =~ "workspace_changed"

      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "set_icm_git_sync",
                 %{"mountKey" => key, "sync" => "off", "generation" => generation + 1},
                 ["saved"]
               )

      assert inspect(errors) =~ "workspace_changed"
    end
  end

  # -- start_git_conflict_session -------------------------------------------------

  describe "start_git_conflict_session" do
    test "composes the briefing, starts a chat session in the ICM, and re-routes to it", %{
      workspace: workspace,
      generation: generation,
      key: key,
      fx: fx
    } do
      Valea.App.Config.set_harness_command(AgentCase.fake_cmd("happy"))

      GitFixtures.diverge!(fx)
      sync!(key, "diverged")

      assert %{"success" => true, "data" => %{"sessionId" => id, "routed" => "new"}} =
               rpc(
                 "start_git_conflict_session",
                 %{"mountKey" => key, "generation" => generation},
                 ["sessionId", "routed"]
               )

      on_exit(fn -> AgentCase.kill_session(id) end)

      assert {:ok, meta} = Valea.Agents.session_meta(id)
      assert meta["kind"] == "chat"
      assert meta["icm_mount"] == key
      assert meta["title"] == "Git sync conflict — Work ICM"

      # The briefing is enqueued SERVER-side as the session's first user turn
      # — there is no client here to replay it from.
      wait_until(fn ->
        workspace
        |> transcript_lines(id)
        |> Stream.drop(1)
        |> Enum.any?(fn line ->
          case Jason.decode(line) do
            {:ok, %{"item" => %{"role" => "user", "text" => text}}} ->
              String.contains?(text, "Local-only commits")

            _other ->
              false
          end
        end)
      end)

      # The Engine remembers the session, so the second click joins it rather
      # than starting a rival agent over the same working tree.
      assert %{"success" => true, "data" => %{"sessionId" => ^id, "routed" => "existing"}} =
               rpc(
                 "start_git_conflict_session",
                 %{"mountKey" => key, "generation" => generation},
                 ["sessionId", "routed"]
               )

      assert %{conflict_session_id: ^id} = Engine.statuses()[key]

      assert {:ok, entries} = Valea.Audit.entries(20)

      assert Enum.any?(entries, fn entry ->
               entry["type"] == "session_started" and entry["session_id"] == id and
                 entry["mount_key"] == key
             end)
    end

    # The regression this pins: `conflict_handoff` is serialized by the
    # Engine, but starting a session is not — scope resolution plus an agent
    # handshake is hundreds of milliseconds during which a second click (or a
    # second tab) used to read the same empty slot and spawn a RIVAL agent
    # with write scope over the same conflicted working tree. The claim is
    # taken inside the Engine before any of that, so exactly one caller wins
    # no matter what the UI does.
    test "two simultaneous clicks produce ONE session, never two rival agents", %{
      generation: generation,
      key: key,
      fx: fx
    } do
      Valea.App.Config.set_harness_command(AgentCase.fake_cmd("happy"))

      GitFixtures.diverge!(fx)
      sync!(key, "diverged")

      results =
        [1, 2]
        |> Enum.map(fn _click ->
          Task.async(fn ->
            rpc(
              "start_git_conflict_session",
              %{"mountKey" => key, "generation" => generation},
              ["sessionId", "routed"]
            )
          end)
        end)
        |> Task.await_many(60_000)

      ids =
        Enum.map(results, fn %{"success" => true, "data" => %{"sessionId" => id}} -> id end)

      on_exit(fn -> Enum.each(Enum.uniq(ids), &AgentCase.kill_session/1) end)

      assert Enum.uniq(ids) |> length() == 1, "rival sessions started: #{inspect(ids)}"

      assert results |> Enum.map(& &1["data"]["routed"]) |> Enum.sort() == ["existing", "new"]

      # And only ONE agent session exists for this ICM.
      assert {:ok, sessions} = Valea.Agents.list_sessions()
      conflict_sessions = Enum.filter(sessions, &(&1["icm_mount"] == key))
      assert length(conflict_sessions) == 1
    end

    # The session start happens in the action's BODY, past the `with` chain
    # that maps every other failure — so it needs its own mapping, or the
    # reason is discarded on the way out and the panel says "unknown error"
    # for a perfectly diagnosable one.
    test "a session that cannot start surfaces WHY, not a bare unknown error", %{
      generation: generation,
      key: key,
      fx: fx
    } do
      Valea.App.Config.set_harness_command(["no-such-binary-zzz"])
      on_exit(fn -> Valea.App.Config.set_harness_command(["claude-agent-acp"]) end)

      GitFixtures.diverge!(fx)
      sync!(key, "diverged")

      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "start_git_conflict_session",
                 %{"mountKey" => key, "generation" => generation},
                 ["sessionId", "routed"]
               )

      assert inspect(errors) =~ "harness_unavailable"
    end

    test "a converged repo has no conflict to resolve", %{generation: generation, key: key} do
      sync!(key, "ok")

      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "start_git_conflict_session",
                 %{"mountKey" => key, "generation" => generation},
                 ["sessionId", "routed"]
               )

      assert inspect(errors) =~ "No git conflict"
    end

    test "a stale generation is refused before the handoff", %{generation: generation, key: key} do
      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "start_git_conflict_session",
                 %{"mountKey" => key, "generation" => generation + 1},
                 ["sessionId", "routed"]
               )

      assert inspect(errors) =~ "workspace_changed"
    end
  end

  # -- add_valea_gitignore / dismiss_git_offer -----------------------------------

  describe "add_valea_gitignore" do
    test "writes the line, and the row it refreshes retires the offer", %{
      generation: generation,
      key: key,
      fx: fx
    } do
      materialize_valea!(fx.work)
      assert %{valea_ignored: false, valea_tracked: false} = sync!(key, "ok")

      assert %{"success" => true, "data" => %{"saved" => true, "untracked" => false}} =
               rpc("add_valea_gitignore", %{"mountKey" => key, "generation" => generation}, [
                 "saved",
                 "untracked"
               ])

      assert File.read!(Path.join(fx.work, ".gitignore")) == ".valea/\n"

      # The action asks for a pass of its own, so the card goes away without
      # waiting five minutes for the poll.
      assert %{valea_ignored: true} = await_row!(key, "ok")
    end

    test "appends to an existing .gitignore, and is idempotent", %{
      generation: generation,
      key: key,
      fx: fx
    } do
      materialize_valea!(fx.work)
      # No trailing newline: a naive append would produce `node_modules/.valea/`.
      File.write!(Path.join(fx.work, ".gitignore"), "node_modules/")
      sync!(key, "ok")

      assert %{"success" => true} =
               rpc("add_valea_gitignore", %{"mountKey" => key, "generation" => generation}, [
                 "saved",
                 "untracked"
               ])

      assert File.read!(Path.join(fx.work, ".gitignore")) == "node_modules/\n.valea/\n"

      assert %{"success" => true} =
               rpc("add_valea_gitignore", %{"mountKey" => key, "generation" => generation}, [
                 "saved",
                 "untracked"
               ])

      # A second click writes nothing — one line, not two.
      assert File.read!(Path.join(fx.work, ".gitignore")) == "node_modules/\n.valea/\n"
    end

    test "the bare `.valea` spelling also counts as already ignored", %{
      generation: generation,
      key: key,
      fx: fx
    } do
      materialize_valea!(fx.work)
      File.write!(Path.join(fx.work, ".gitignore"), "  .valea  \n")
      sync!(key, "ok")

      assert %{"success" => true} =
               rpc("add_valea_gitignore", %{"mountKey" => key, "generation" => generation}, [
                 "saved",
                 "untracked"
               ])

      assert File.read!(Path.join(fx.work, ".gitignore")) == "  .valea  \n"
    end

    test "a tracked .valea is untracked too — staged, never deleted from disk", %{
      generation: generation,
      key: key,
      fx: fx
    } do
      materialize_valea!(fx.work)
      GitFixtures.git!(fx.work, ["add", "-f", ".valea"])
      GitFixtures.git!(fx.work, ["commit", "-m", "user committed .valea"])
      assert %{valea_tracked: true} = sync!(key, "ok")

      assert %{"success" => true, "data" => %{"saved" => true, "untracked" => true}} =
               rpc("add_valea_gitignore", %{"mountKey" => key, "generation" => generation}, [
                 "saved",
                 "untracked"
               ])

      assert GitFixtures.git!(fx.work, ["ls-files", "--", ".valea"]) |> String.trim() == ""
      assert File.exists?(Path.join(fx.work, ".valea/briefing.md"))
      # In pull mode the staged removal waits for the user to commit it.
      assert GitFixtures.git!(fx.work, ["status", "--porcelain"]) =~ "D  .valea/briefing.md"
    end

    test "an ICM that is not a git repository is refused", %{
      workspace: workspace,
      generation: generation
    } do
      plain = AgentCase.mount_test_icm!(workspace, name: "Plain")

      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "add_valea_gitignore",
                 %{"mountKey" => plain.mount_key, "generation" => generation},
                 ["saved", "untracked"]
               )

      assert inspect(errors) =~ "not a git repository"
      refute File.exists?(Path.join(plain.root, ".gitignore"))
    end

    test "an unknown mount and a stale generation are both refused", %{
      generation: generation,
      key: key,
      fx: fx
    } do
      assert %{"success" => false, "errors" => errors} =
               rpc("add_valea_gitignore", %{"mountKey" => "ghost", "generation" => generation}, [
                 "saved",
                 "untracked"
               ])

      assert inspect(errors) =~ "icm_unavailable"

      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "add_valea_gitignore",
                 %{"mountKey" => key, "generation" => generation + 1},
                 ["saved", "untracked"]
               )

      assert inspect(errors) =~ "workspace_changed"
      refute File.exists?(Path.join(fx.work, ".gitignore"))
    end
  end

  describe "dismiss_git_offer" do
    test "persists on the mount's config entry", %{
      workspace: workspace,
      generation: generation,
      key: key
    } do
      assert %{"success" => true, "data" => %{"saved" => true}} =
               rpc(
                 "dismiss_git_offer",
                 %{"mountKey" => key, "offerId" => "valea_gitignore", "generation" => generation},
                 ["saved"]
               )

      assert Mounts.git_offers_dismissed(workspace, key) == ["valea_gitignore"]
      assert Mounts.git_config(workspace, key).sync == :pull
    end

    test "an unknown offer id is refused and writes nothing", %{
      workspace: workspace,
      generation: generation,
      key: key
    } do
      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "dismiss_git_offer",
                 %{"mountKey" => key, "offerId" => "whatever", "generation" => generation},
                 ["saved"]
               )

      assert inspect(errors) =~ "Unknown git offer"
      assert Mounts.git_offers_dismissed(workspace, key) == []
    end

    test "a stale generation is refused", %{
      workspace: workspace,
      generation: generation,
      key: key
    } do
      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "dismiss_git_offer",
                 %{
                   "mountKey" => key,
                   "offerId" => "valea_gitignore",
                   "generation" => generation + 1
                 },
                 ["saved"]
               )

      assert inspect(errors) =~ "workspace_changed"
      assert Mounts.git_offers_dismissed(workspace, key) == []
    end
  end
end
