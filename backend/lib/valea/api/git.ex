defmodule Valea.Api.Git do
  @moduledoc """
  The git-sync RPC surface (ICM git sync spec §RPC): read the engine's rows,
  ask for a pass, change an ICM's sync mode, and hand a held repo to a
  resolution session.

  Top-level booleans use STRING keys (the ash_typescript falsy rule —
  canonical note in `Valea.Api.Mail`'s moduledoc: a top-level atom-keyed
  `false` is nulled on the way out). Repo rows ride an UNTYPED
  `{:array, :map}` so their snake_case string keys and their `false`s pass
  through unmangled — array items are exempt from that bug, and the row shape
  is `Valea.Git.Engine`'s to define, not this module's to restate.
  `Engine.public_rows/1` is the single place the wire shape is decided, so
  the RPC, the channel push and the cockpit block cannot drift (and the
  engine's internal `block_fingerprint` cannot leak from any of them).

  ## Error vocabulary

  Unlike its sibling resources, this one's `error_for/1` returns HUMAN
  sentences for the git-specific atoms rather than machine codes: they are
  the copy the git panel shows verbatim, and there is nothing for a frontend
  to branch on beyond "it failed, here is why". The shared codes
  (`workspace_changed`, `workspace_not_open`, `icm_unavailable`) keep their
  machine spelling, because the frontend DOES branch on those.

  ## Why the engine calls are wrapped

  `Engine.sync_now/1` and `Engine.conflict_handoff/1` resolve the singleton
  and then `GenServer.call` it — with no `catch :exit` of their own (unlike
  `statuses/0`). A workspace closing or switching under an in-flight RPC
  would otherwise take the RPC channel process down with a raw exit instead
  of answering. `engine_call/1` is that guard, and it deliberately does not
  add a call timeout: `conflict_handoff/1` runs several git commands inside
  the engine loop and owns its own 30 s bound.
  """
  use Ash.Resource, domain: Valea.Api, extensions: [AshTypescript.Resource]

  typescript do
    type_name("Git")
  end

  alias Valea.Api.Error
  alias Valea.Git.Engine
  alias Valea.Workspace.Manager

  actions do
    action :git_status, :map do
      constraints fields: [repos: [type: {:array, :map}, allow_nil?: false]]
      argument :generation, :integer, allow_nil?: false

      # Read-only, and still generation-guarded: rows describe repos of ONE
      # workspace, and answering a stale caller with the new workspace's
      # repos is the one wrong answer available here.
      run fn input, _ctx ->
        with :ok <- Manager.check_generation(input.arguments.generation) do
          {:ok, %{"repos" => Engine.public_rows(Engine.statuses())}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :git_sync_now, :map do
      constraints fields: [started: [type: :boolean, allow_nil?: false]]
      argument :mount_key, :string, allow_nil?: false
      argument :generation, :integer, allow_nil?: false

      # "Started", not "finished": the pass runs in its own task and reports
      # through the `"git"` broadcast. This is also the one thing that clears
      # a repo's backoff — an explicit request from a human is exactly the
      # signal that the situation may have changed.
      run fn input, _ctx ->
        %{mount_key: key, generation: generation} = input.arguments

        with :ok <- Manager.check_generation(generation),
             :ok <- engine_call(fn -> Engine.sync_now(key) end) do
          {:ok, %{"started" => true}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :set_icm_git_sync, :map do
      constraints fields: [saved: [type: :boolean, allow_nil?: false]]
      argument :mount_key, :string, allow_nil?: false
      argument :sync, :string, allow_nil?: false
      argument :generation, :integer, allow_nil?: false

      # The mode lives in the workspace's own `icms:` config, so the engine
      # learns about it exactly the way it learns about a mount being added
      # or disabled: `{:mounts_changed}`, which triggers a pass.
      run fn input, _ctx ->
        %{mount_key: key, sync: sync, generation: generation} = input.arguments

        with :ok <- Manager.check_generation(generation),
             {:ok, %{path: root}} <- Manager.current(),
             :ok <- Valea.Mounts.set_git_sync(root, key, sync) do
          Phoenix.PubSub.broadcast(Valea.PubSub, "mounts", {:mounts_changed})
          {:ok, %{"saved" => true}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :start_git_conflict_session, :map do
      constraints fields: [
                    session_id: [type: :string, allow_nil?: false],
                    routed: [type: :string, allow_nil?: false]
                  ]

      argument :mount_key, :string, allow_nil?: false
      argument :generation, :integer, allow_nil?: false

      # The "resolve" button. Correlation is the thing this must get right —
      # a second click means "take me back to the agent working on it", never
      # "start a rival one over the same working tree" — so the engine's
      # recorded session wins whenever it is still alive.
      #
      # The briefing is composed by the engine (LIVE, from the repo as it is
      # right now, not from a row that may be minutes old), which is why a
      # repo that converged in the meantime gets `:no_conflict` here instead
      # of a session telling an agent to fix nothing.
      run fn input, _ctx ->
        %{mount_key: key, generation: generation} = input.arguments

        with :ok <- Manager.check_generation(generation),
             {:ok, _workspace} <- Manager.current(),
             {:ok, handoff} <- engine_call(fn -> Engine.conflict_handoff(key) end) do
          route(key, generation, handoff)
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end
  end

  # -- conflict-session routing ---------------------------------------------------

  defp route(key, generation, %{existing_session_id: id} = handoff) when is_binary(id) do
    if Valea.Agents.SessionServer.running?(id),
      do: {:ok, %{"session_id" => id, "routed" => "existing"}},
      else: start_conflict_session(key, generation, handoff)
  end

  defp route(key, generation, handoff), do: start_conflict_session(key, generation, handoff)

  # RESERVE the repo's conflict slot before spending a single millisecond on
  # starting anything. Resolving a scope and handshaking an agent subprocess
  # takes hundreds of milliseconds, and a double-click (or a second tab) lands
  # squarely inside that window: without the claim, both callers would read an
  # empty slot and point two agents with write scope at the same conflicted
  # working tree. The claim is decided inside the Engine's own loop, so the
  # race is closed for every caller, not just for a UI that remembers to
  # disable its button.
  #
  # Losing the claim is not an error — it is the answer the user wanted:
  # "take me to the session that is already on this". The winner may still be
  # mid-handshake, so that session's transcript can be a beat behind the
  # navigation; joining a session that is starting is right either way, and
  # far better than a rival agent.
  defp start_conflict_session(key, generation, handoff) do
    id = Valea.Agents.generate_session_id()

    case engine_call(fn -> Engine.claim_conflict_session(key, id) end) do
      :ok ->
        start_claimed_session(key, generation, id, handoff)

      {:error, {:already_claimed, existing}} ->
        {:ok, %{"session_id" => existing, "routed" => "existing"}}

      {:error, reason} ->
        {:error, error_for(reason)}
    end
  end

  # The session runs INSIDE the ICM whose repo is stuck — the working tree it
  # has to reason about is that ICM's own content, and the scope it gets is
  # the ordinary chat scope for that mount, with no extra grants.
  defp start_claimed_session(key, generation, id, %{briefing: briefing, icm_name: icm_name}) do
    with {:ok, scope} <-
           Valea.Agents.SessionScope.resolve(%{
             kind: "chat",
             mount_key: key,
             generation: generation,
             session_id: id,
             read_paths: []
           }),
         {:ok, %{id: ^id}} <-
           Valea.Agents.start_session(%{
             id: id,
             kind: "chat",
             title: "Git sync conflict — #{icm_name}",
             scope: scope,
             run: nil,
             initial_prompt: briefing,
             on_turn_end: nil,
             context_doc: nil,
             input: nil
           }) do
      # Confirms the claim as a live session. A cast, so a dead engine
      # (workspace closing under the click) cannot fail a session that has
      # already started — the CLAIM is what reserved the slot, so nothing is
      # racing on this.
      Engine.record_conflict_session(key, id)

      Valea.Audit.append("session_started", %{
        "session_id" => id,
        "mount_key" => key,
        "context_doc" => nil,
        "input" => nil,
        "include_mounts" => []
      })

      {:ok, %{"session_id" => id, "routed" => "new"}}
    else
      # This runs in the action's BODY, not one of its `with` clauses, so it
      # is the last place a scope/harness failure (`:icm_unavailable`,
      # `:harness_unavailable`) can be turned into an error the frontend can
      # read — an unmapped `{:error, atom}` reaches ash_typescript as a bare
      # "unknown_error" with the reason discarded.
      {:error, reason} -> abandon(key, id, reason)
      # `start_session/1` answering with an id that is not the one we
      # generated cannot happen (we pass `:id`), but a `WithClauseError`
      # raised out of an RPC action would be a far worse way to find that
      # out than an error the caller can read.
      other -> abandon(key, id, other)
    end
  end

  # A claim whose session never started must go back SYNCHRONOUSLY, before
  # this error reaches the user: they will click again, and a retry that
  # found its own abandoned claim still standing would be told to join a
  # session that does not exist and never will.
  defp abandon(key, id, reason) do
    engine_call(fn -> Engine.release_conflict_session(key, id) end)
    {:error, error_for(reason)}
  end

  # -- guards ---------------------------------------------------------------------

  # See the moduledoc: neither engine call catches its own exits, and an RPC
  # must answer rather than die. A `:timeout` is told apart from everything
  # else because it means the opposite thing — the engine is there and busy,
  # not gone — and "try again in a moment" is the only honest remedy for it.
  defp engine_call(fun) do
    fun.()
  catch
    :exit, {:timeout, _call} -> {:error, :engine_busy}
    :exit, _reason -> {:error, :not_running}
  end

  # Central error mapping. The first four are this surface's own copy (see
  # the moduledoc on why they are sentences); the tail is
  # `Valea.Api.Icms.error_for/1`'s shared vocabulary verbatim, so
  # `workspace_changed` / `workspace_not_open` / `icm_unavailable` spell the
  # same on this surface as on every other.
  defp error_for(:no_conflict),
    do: Error.new("No git conflict to resolve — it may have just cleared.")

  defp error_for(:not_found), do: Error.new("This ICM is not a syncing git repository.")
  defp error_for(:not_running), do: Error.new("Git engine is not running — is a workspace open?")

  defp error_for(:engine_busy),
    do: Error.new("Git is still working on this repository — try again in a moment.")

  defp error_for(:invalid_git_sync), do: Error.new("sync must be one of: full, pull, off.")
  defp error_for(:no_workspace), do: Error.new("workspace_not_open")
  defp error_for(:mount_not_found), do: Error.new("icm_unavailable")
  defp error_for(reason) when is_atom(reason), do: Error.new(to_string(reason))
  defp error_for(reason), do: Error.new(inspect(reason))
end
