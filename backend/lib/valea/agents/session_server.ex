defmodule Valea.Agents.SessionServer do
  @moduledoc """
  One GenServer per live agent session. Owns the adapter subprocess (via
  `Valea.Agents.ProcessRuntime`) and every side effect around the pure ACP
  codec (`Valea.Acp.Connection`): the handshake, the render-item timeline, the
  append-only transcript file, PubSub broadcasts, the one-turn-at-a-time prompt
  queue, and the handshake watchdog.

  Slim single-transport peer of legend's `SessionServer` — no PTY, remote, or
  MCP baggage. `restart: :temporary`: the server SURVIVES subprocess exit
  (status `:exited`, transcript still viewable) until the workspace closes.

  PubSub topic `"agent_session:<id>"`:

    * `{:session_event, seq, item}` — a render item, as it arrives
    * `{:session_status, status}`   — starting | running | exited | failed
    * `{:session_exit, code}`       — the subprocess exited
  """

  use GenServer, restart: :temporary

  require Logger

  alias Valea.Acp.Connection
  alias Valea.Agents.ProcessRuntime

  @handshake_timeout_ms 30_000
  @max_prompt_queue 50

  # The permission policy defaults to this module; resolved at runtime so Task 11
  # (and tests) can swap the implementation via app config without touching the
  # effect-handling code path.
  @policy Valea.Agents.PermissionPolicy

  ## Client API — everything is addressed by session id through the Registry.

  def start_link(%{id: id} = opts) do
    GenServer.start_link(__MODULE__, opts, name: via(id))
  end

  @doc "Timeline snapshot: `%{items, cursor, busy, status}`."
  def attach(id), do: call(id, :attach)

  def prompt(id, content), do: cast(id, {:prompt, content})
  def cancel(id), do: cast(id, :cancel)
  def answer_permission(id, item_id, kind), do: cast(id, {:answer_permission, item_id, kind})

  def set_config_option(id, config_id, value),
    do: cast(id, {:set_config_option, config_id, value})

  def stop(id), do: cast(id, :stop)

  defp via(id), do: {:via, Registry, {Valea.Agents.SessionRegistry, id}}

  defp whereis(id) do
    case Registry.lookup(Valea.Agents.SessionRegistry, id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp call(id, msg) do
    case whereis(id) do
      nil -> {:error, :not_running}
      pid -> GenServer.call(pid, msg)
    end
  end

  defp cast(id, msg) do
    case whereis(id) do
      nil -> {:error, :not_running}
      pid -> GenServer.cast(pid, msg)
    end
  end

  ## Server

  @impl true
  def init(opts) do
    # Trap exits so terminate/2 runs and stops the (unsupervised) runtime relay,
    # so an adapter subprocess never orphans.
    Process.flag(:trap_exit, true)

    %{id: id, spec: spec, scope: scope} = opts
    timeout = Map.get(opts, :handshake_timeout_ms, @handshake_timeout_ms)

    # The split PermissionPolicy contract (Task 5.3): `workspace_root`
    # protects operational state, `cwd` (the primary ICM's own root) is the
    # base relative candidate paths resolve against, `read_roots` is the
    # ONE absolute read surface (the primary ICM + every direct related ICM
    # + any exact grant a caller resolved the scope with — already folded
    # together by `SessionScope.resolve/1` into `scope.additional_roots`),
    # `write_paths`/`write_roots` are the workflow-only exact grants.
    # `icm_roots` (Task 8, Spec D §D5) is narrower than `read_roots` — just
    # the primary ICM root plus each DIRECT related ICM's own root, never
    # `scope.additional_roots`'s exact task-input grants — since the
    # ICM-internal secrets deny is scoped to ICM content, not to every
    # granted read surface. This is built FRESH from `scope` at every
    # session start — never cached — so `SessionScope` (the ONE place
    # mount-key lookup, related-ICM resolution, and read/write-root assembly
    # live) is the single source of truth; `SessionServer` never re-derives
    # any of it.
    # `mail_roots_all`/`mail_roots_in_scope` (Task 14) thread straight from
    # the scope, like everything else here: PermissionPolicy's mail tier
    # denies any candidate under `sources/mail` that is not in an in-scope
    # account's root — deny, not ask. `icm_roots` deliberately KEEPS the
    # in-scope mail roots (they're in `related_icms`): the ICM-secrets deny
    # applies inside a mail mount too (e.g. `drafts/.env`).
    # `calendar_in_scope?` (Spec F Task 5) threads the same way for the
    # calendar tier — ONE mount, so a boolean, not a root list; the
    # `sources/calendar` territory root is derived from `workspace_root`
    # inside the policy. Defaults false: fail-closed for any scope built
    # before the calendar kind existed.
    policy_ctx = %{
      workspace_root: scope.workspace.root,
      cwd: scope.cwd,
      read_roots: [scope.primary_icm.root | scope.additional_roots],
      session_kind: scope.kind,
      write_paths: scope.write_paths,
      write_roots: scope.write_roots,
      icm_roots: [scope.primary_icm.root | Enum.map(scope.related_icms, & &1.root)],
      mail_roots_all: Map.get(scope, :mail_roots_all, []),
      mail_roots_in_scope: Map.get(scope, :mail_roots_in_scope, []),
      calendar_in_scope?: Map.get(scope, :calendar_in_scope, false)
    }

    case ProcessRuntime.start(
           %{
             cmd: spec.cmd,
             args: spec.args ++ scope.argv_extra,
             env: Map.merge(spec.env, scope.env),
             cd: scope.cwd
           },
           self()
         ) do
      {:ok, handle} ->
        {conn, frames} =
          Connection.new(%{
            cwd: scope.cwd,
            mode: :new,
            conversation_id: nil,
            known_message_ids: MapSet.new(),
            client_version: version(),
            additional_roots: scope.additional_roots,
            managed_settings: scope.managed_settings
          })

        Enum.each(frames, &ProcessRuntime.write(handle, &1))

        watchdog = Process.send_after(self(), :handshake_timeout, timeout)
        transcript = open_transcript(opts, scope)

        state = %{
          id: id,
          topic: "agent_session:" <> id,
          workspace: scope.workspace.root,
          conn: conn,
          handle: handle,
          transcript: transcript,
          seq: 0,
          timeline: [],
          status: :starting,
          exited?: false,
          queue: [],
          watchdog: watchdog,
          policy_ctx: policy_ctx,
          on_turn_end: Map.get(opts, :on_turn_end),
          finalized?: false
        }

        broadcast(state, {:session_status, :starting})
        state = maybe_enqueue_initial(state, Map.get(opts, :initial_prompt))
        {:ok, state}

      {:error, reason} ->
        {:stop, {:runtime_start_failed, reason}}
    end
  end

  @impl true
  def handle_call(:attach, _from, state) do
    reply = %{
      items: state.timeline,
      cursor: state.seq,
      busy: state.status == :running and Connection.turn_in_flight?(state.conn),
      status: Atom.to_string(state.status)
    }

    {:reply, {:ok, reply}, state}
  end

  @impl true
  def handle_cast(_msg, %{exited?: true} = state), do: {:noreply, state}

  def handle_cast({:prompt, content}, state) do
    {:noreply, send_or_queue(state, content)}
  end

  def handle_cast(:cancel, state) do
    {conn, frames} = Connection.cancel(state.conn)
    write_frames(state, frames)
    {:noreply, %{state | conn: conn}}
  end

  def handle_cast({:answer_permission, item_id, kind}, state) do
    {conn, items, frames} = Connection.answer_permission(state.conn, item_id, kind)
    write_frames(state, frames)
    state = %{state | conn: conn}
    state = Enum.reduce(items, state, &append_item(&2, &1))

    if items != [],
      do: audit(state, "permission_answered", %{"item_id" => item_id, "kind" => kind})

    {:noreply, state}
  end

  def handle_cast({:set_config_option, config_id, value}, state) do
    {conn, frames} = Connection.set_config_option(state.conn, config_id, value)
    write_frames(state, frames)
    {:noreply, %{state | conn: conn}}
  end

  def handle_cast(:stop, state) do
    ProcessRuntime.stop(state.handle)
    {:noreply, state}
  end

  @impl true
  def handle_info({:runtime_output, _data}, %{exited?: true} = state), do: {:noreply, state}

  def handle_info({:runtime_output, data}, state) do
    {conn, items, frames, effects} = Connection.handle_bytes(state.conn, data)
    write_frames(state, frames)
    # Items FIRST (each appended + broadcast in arrival order), THEN effects —
    # so a message chunk lands with a lower seq than the {:turn} it precedes.
    state = %{state | conn: conn}
    state = Enum.reduce(items, state, &append_item(&2, enrich_item(&1, state)))
    state = Enum.reduce(effects, state, &apply_effect(&2, &1))
    {:noreply, state}
  end

  # stderr is a SEPARATE stream — log it, NEVER feed it to the JSON-RPC decoder.
  def handle_info({:runtime_stderr, data}, state) do
    Logger.warning("[acp #{state.id}] stderr: #{String.slice(to_string(data), 0, 500)}")
    {:noreply, state}
  end

  def handle_info({:runtime_exit, _code}, %{exited?: true} = state), do: {:noreply, state}

  def handle_info({:runtime_exit, code}, state) do
    # The adapter died. If a turn already fired on_turn_end this is a no-op;
    # otherwise (handshake/adapter crash BEFORE any turn ended) fire it with a
    # "died" sentinel so the run still reaches its terminus instead of
    # orphaning any in-flight state forever.
    state = fire_turn_end(state, "died")
    state = set_status(%{state | exited?: true}, :exited)
    broadcast(state, {:session_exit, code})
    audit(state, "session_exited", %{"code" => code})
    {:noreply, state}
  end

  # Stale timeout (already ready or already exited): no-op.
  def handle_info(:handshake_timeout, %{watchdog: nil} = state), do: {:noreply, state}
  def handle_info(:handshake_timeout, %{exited?: true} = state), do: {:noreply, state}

  def handle_info(:handshake_timeout, state) do
    {:noreply, fail(%{state | watchdog: nil}, "handshake timed out")}
  end

  # The runtime relay exits normally after forwarding {:runtime_exit}.
  def handle_info({:EXIT, _pid, :normal}, state), do: {:noreply, state}

  def handle_info({:EXIT, _pid, _reason}, %{exited?: false} = state) do
    handle_info({:runtime_exit, nil}, state)
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{exited?: false, handle: handle}) do
    ProcessRuntime.stop(handle)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # A permission ask is the human's decision point — stamp the
  # server-derived risk tier on it, so the dialog can say
  # plainly when an approval changes future agent behavior. Display
  # metadata only; policy decisions never read it. The touched path is
  # physical (absolute, or resolved against `cwd` upstream) — attribute it
  # to a locator first (`Locator.for_path/2`, the same ICM-or-workspace
  # attribution `RiskTier.classify/1` now expects) before classifying; a
  # non-absolute/unattributable path degrades to a workspace locator,
  # which classifies nil exactly as before (Task 7.5).
  defp enrich_item(%{"type" => "permission", "rawInput" => raw} = item, state)
       when is_map(raw) do
    path = raw["file_path"] || raw["path"] || raw["filePath"] || raw["notebook_path"]

    tier =
      if is_binary(path) do
        state.workspace
        |> Valea.Icm.Locator.for_path(path)
        |> Valea.Agents.RiskTier.classify()
      end

    case tier do
      tier when tier in ["high", "medium"] -> Map.put(item, "risk_tier", tier)
      _ -> item
    end
  end

  defp enrich_item(item, _state), do: item

  ## Effects

  defp apply_effect(state, {:session_ready}) do
    state
    |> cancel_watchdog()
    |> set_status(:running)
    |> flush_queue()
  end

  defp apply_effect(state, {:conversation_id, cid}) do
    append_item(state, %{"id" => "acp_session", "type" => "meta", "acp_session_id" => cid})
  end

  defp apply_effect(state, {:turn, stop}) do
    state |> fire_turn_end(stop) |> flush_queue()
  end

  defp apply_effect(state, {:handshake_failed, reason}) do
    state |> cancel_watchdog() |> fail(reason)
  end

  defp apply_effect(state, {:permission_requested, item}) do
    policy_decide(state, item)
  end

  # Defensive: an unknown future effect must not crash the session.
  defp apply_effect(state, _effect), do: state

  ## Permission policy

  defp policy_decide(state, item) do
    case policy().decide(item, state.policy_ctx) do
      {:allow, kind} ->
        audit(state, "permission_auto_allowed", permission_audit(item, kind))
        answer_now(state, item["id"], kind)

      {:deny, kind} ->
        audit(state, "permission_auto_denied", permission_audit(item, kind))
        answer_now(state, item["id"], kind)

      :ask ->
        # The permission item was already appended + broadcast (resolved:false)
        # from the handle_bytes items list — the UI takes over from here.
        audit(state, "permission_asked", permission_audit(item, "ask"))
        state
    end
  end

  # Forensic record for a policy decision — the security audit trail. Carries
  # what was decided, on which tool call, and the human-readable title.
  defp permission_audit(item, decision) do
    %{
      "item_id" => item["id"],
      "title" => item["title"],
      "kind" => item["kind"],
      "decision" => decision
    }
  end

  defp answer_now(state, item_id, kind) do
    {conn, items, frames} = Connection.answer_permission(state.conn, item_id, kind)
    write_frames(state, frames)
    Enum.reduce(items, %{state | conn: conn}, &append_item(&2, &1))
  end

  ## Prompt queue (one turn at a time; also gated on handshake readiness)

  defp send_or_queue(state, content) do
    if ready_to_send?(state) do
      send_prompt(state, content)
    else
      enqueue(state, content)
    end
  end

  defp ready_to_send?(state) do
    state.status == :running and not Connection.turn_in_flight?(state.conn)
  end

  defp enqueue(state, content) do
    if length(state.queue) >= @max_prompt_queue do
      Logger.warning(
        "[acp #{state.id}] prompt queue full (#{@max_prompt_queue}); dropping prompt"
      )

      state
    else
      %{state | queue: state.queue ++ [content]}
    end
  end

  defp flush_queue(%{queue: [content | rest]} = state) do
    if ready_to_send?(state), do: send_prompt(%{state | queue: rest}, content), else: state
  end

  defp flush_queue(state), do: state

  # Neither the adapter nor the codec echoes the user's own prompt back on a
  # fresh (mode: :new) session, so the SessionServer appends it itself — via
  # the SAME append/broadcast path as codec items, so it lands in the
  # timeline, transcript, and PubSub in true turn order. Appended here (not in
  # `send_or_queue`/`enqueue`) so a queued prompt is echoed only once it is
  # actually SENT, not when it is merely queued.
  defp send_prompt(state, content) do
    state = append_item(state, user_echo_item(state.seq + 1, content))
    {conn, _items, frames} = Connection.prompt(state.conn, content)
    write_frames(state, frames)
    %{state | conn: conn}
  end

  defp user_echo_item(seq, content) do
    %{
      "id" => "user-" <> Integer.to_string(seq),
      "type" => "message",
      "role" => "user",
      "text" => echo_text(content)
    }
  end

  defp echo_text(content) when is_binary(content), do: content

  defp echo_text(content) when is_list(content) do
    content
    |> Enum.filter(&(is_map(&1) and &1["type"] == "text"))
    |> Enum.map_join("", &(&1["text"] || ""))
  end

  defp echo_text(_content), do: ""

  defp maybe_enqueue_initial(state, nil), do: state
  defp maybe_enqueue_initial(state, prompt), do: enqueue(state, prompt)

  ## Transcript + timeline

  # Line 1 is the session metadata, written once at start (acp_session_id nil).
  # The later {:conversation_id} effect APPENDS a normal item — never a rewrite.
  # Always anchored to `scope.workspace.root` — the transcript stays keyed to
  # the WORKSPACE (sessions/queue/audit all live there), never the primary
  # ICM's own `cwd`, which is a different physical location entirely.
  #
  # C8 (`session/v1`): the full workspace + ICM identity snapshot, built
  # ENTIRELY from `scope` (never re-derived from a live lookup) so the
  # transcript stays a faithful record of what this session actually ran
  # against, even after the workspace/mount table later changes — grouped
  # listing (Task 6.2) keys off `icm_mount`, and `create_follow_up` (Task
  # 6.3) re-resolves a fresh scope for that same `mount_key`.
  defp open_transcript(opts, scope) do
    %{id: id} = opts
    run = Map.get(opts, :run)

    path = Path.join([scope.workspace.root, "logs", "sessions", id <> ".jsonl"])
    File.mkdir_p!(Path.dirname(path))

    meta = %{
      "schema" => "session/v1",
      "id" => id,
      "acp_session_id" => nil,
      "workspace_id" => scope.workspace.id,
      "workspace_name" => scope.workspace.name,
      "icm_mount" => scope.primary_icm.mount_key,
      "icm_id" => scope.primary_icm.id,
      "icm_name" => scope.primary_icm.manifest.name,
      "icm_root" => scope.primary_icm.root,
      "kind" => Map.get(opts, :kind),
      "workflow" => run_field(run, "workflow"),
      "run_id" => run_field(run, "id"),
      # Spec D §B (Task 9): the session-with-context primitive's own two
      # locators, recorded verbatim (raw string-keyed maps, or nil) — never
      # re-derived from `input_path`, so a follow-up reading this meta later
      # sees exactly what the caller named.
      "context_doc" => Map.get(opts, :context_doc),
      "input" => Map.get(opts, :input),
      # Task 14: the mail mounts the caller explicitly included (mount
      # keys, verbatim) — recorded like `context_doc`/`input`, so a later
      # reader sees exactly what the session was opted into.
      "include_mounts" => Map.get(opts, :include_mounts, []),
      "title" => Map.get(opts, :title),
      "harness" => "claude_code",
      "generation" => scope.workspace.generation,
      "started_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    File.write!(path, Jason.encode!(meta) <> "\n")
    path
  end

  # `run` may carry string or atom keys (or be nil); read both without risking a
  # missing-atom crash on the atom lookup.
  defp run_field(nil, _key), do: nil
  defp run_field(run, key) when is_map(run), do: Map.get(run, key) || Map.get(run, safe_atom(key))

  defp safe_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  # Append a render item: write it to the transcript AS IT ARRIVES (crash loses
  # nothing), fold it into the in-memory timeline (merge-by-id), then broadcast.
  defp append_item(state, item) do
    seq = state.seq + 1
    line = Jason.encode!(%{"seq" => seq, "item" => item}) <> "\n"
    File.write(state.transcript, line, [:append])
    timeline = upsert(state.timeline, item)
    state = %{state | seq: seq, timeline: timeline}
    broadcast(state, {:session_event, seq, item})
    state
  end

  defp upsert(timeline, item) do
    id = item["id"]

    if Enum.any?(timeline, &(&1["id"] == id)) do
      Enum.map(timeline, fn i -> if i["id"] == id, do: item, else: i end)
    else
      timeline ++ [item]
    end
  end

  ## Status / failure

  defp set_status(%{status: status} = state, status), do: state

  defp set_status(state, status) do
    state = %{state | status: status}
    broadcast(state, {:session_status, status})
    state
  end

  # Doctor-readable failure: log, stop the runtime, surface an error item, mark
  # :failed. The server stays alive so the transcript remains viewable.
  defp fail(%{exited?: true} = state, _reason), do: state

  defp fail(state, reason) do
    Logger.warning("[acp #{state.id}] session failed: #{reason}")
    ProcessRuntime.stop(state.handle)

    state
    # A handshake/adapter failure before any turn ends must still terminate a
    # workflow run — same "died" sentinel as the runtime_exit path.
    |> fire_turn_end("died")
    |> append_item(%{"id" => "error", "type" => "error", "text" => reason})
    |> Map.put(:exited?, true)
    |> set_status(:failed)
  end

  # Fire the session's `on_turn_end` callback AT MOST ONCE. The {:turn} effect
  # calls it on a normal turn end; the runtime_exit and fail paths call it with
  # a "died" sentinel so a session that dies before any turn completes still
  # gives its workflow run a terminus. `finalized?` guards against a second
  # invocation (e.g. a turn end followed by the adapter exiting). Spawned so a
  # slow finalize never blocks the session process.
  defp fire_turn_end(%{finalized?: true} = state, _stop), do: state
  defp fire_turn_end(%{on_turn_end: nil} = state, _stop), do: state

  defp fire_turn_end(%{on_turn_end: on_turn_end} = state, stop) do
    spawn(fn -> on_turn_end.(stop) end)
    %{state | finalized?: true}
  end

  ## Helpers

  defp write_frames(state, frames), do: Enum.each(frames, &ProcessRuntime.write(state.handle, &1))

  defp broadcast(state, msg), do: Phoenix.PubSub.broadcast(Valea.PubSub, state.topic, msg)

  # Audit is a fire-and-forget cast to a NAMED process that may not exist in
  # some unit contexts; guard so a dead name is a genuine no-op.
  defp audit(_state, type, fields) do
    if Process.whereis(Valea.Audit), do: Valea.Audit.append(type, fields)
    :ok
  end

  defp cancel_watchdog(%{watchdog: nil} = state), do: state

  defp cancel_watchdog(%{watchdog: ref} = state) do
    Process.cancel_timer(ref)
    %{state | watchdog: nil}
  end

  defp version, do: to_string(Application.spec(:valea, :vsn) || "0.0.0")

  defp policy, do: Application.get_env(:valea, :permission_policy, @policy)
end
