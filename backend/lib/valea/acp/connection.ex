# Vendored from legend backend/lib/legend/core/acp/connection.ex (2026-07-10)
# and updated to current ACP (v1 + session config options, resume, clientInfo,
# cancellation outcomes). Pure codec: no IO, no processes — the SessionServer
# owns both.
defmodule Valea.Acp.Connection do
  @moduledoc """
  In-process Agent Client Protocol codec. Holds JSON-RPC framing state (line
  buffer, request-id correlation, per-turn reduction state) for one ACP session.
  Pure functions: the SessionServer owns the process and the runtime IO.

  The only permitted side effect is `Logger` for undecodable frames — every
  other output is returned as data (`{state, items, frames, effects}`).
  """

  require Logger

  @protocol_version 1

  # Cap each tool entry's accumulated "output" so a long-running / chatty tool
  # cannot grow state.reduce without bound. We keep the TAIL (most recent output
  # is the most relevant) plus a leading truncation marker. The timeline holds
  # the canonical copy by id; this only bounds the per-update reducer working set.
  @max_tool_output 65_536
  @tool_output_truncation_marker "…[output truncated]…\n"

  # Cap the incomplete-line buffer so a newline-less flood from the agent cannot
  # grow state.buf without bound. When exceeded we RESET buf and emit a soft
  # error item so a malformed / oversized frame can't exhaust memory; subsequent
  # valid frames still parse.
  @max_line_bytes 1_048_576

  @doc "Inbound incomplete-line buffer byte cap. Exposed for tests/inspection."
  @spec max_line_bytes() :: pos_integer()
  def max_line_bytes, do: @max_line_bytes

  defstruct buf: "",
            next_id: 1,
            pending: %{},
            launch: nil,
            turn: 0,
            # Whether the CURRENT turn has seen any agent-side output yet. Drives
            # session/load replay turn-boundary detection: a user chunk that
            # follows agent output begins a new turn (see reduce_update/3).
            turn_seen_response: false,
            reduce: %{},
            session_id: nil,
            # Pending agent->client permission requests: item_id => jsonrpc_id.
            perms: %{},
            # Options list for each pending permission item, kept so we can
            # resolve kind ("allow_once"/"reject_once") -> optionId after emit.
            perm_options: %{},
            # Message ids seen during session/load replay, so intra-replay
            # duplicates collapse in addition to launch.known_message_ids.
            seen_message_ids: MapSet.new(),
            # The messageId of the message currently being accumulated — the
            # last id dedup/2 kept. Chunks of ONE streaming message all carry
            # the same messageId (claude-agent-acp 0.58.1+ stamps live chunks
            # too), so "already seen" must not skip the ACTIVE message's own
            # continuation chunks — only a NON-consecutive repeat of an older
            # id is a duplicate.
            active_message_id: nil,
            # Chronology bookkeeping for the CURRENT turn (all three reset by
            # start_turn/2). Agent prose and tool calls interleave — "let me
            # read this" / tool / "it says X" — so a message may not simply
            # accumulate for the whole turn: the two halves belong on either
            # side of the tool card, and one item can only sit in one place.
            #
            #   * `open_streams` — "message"/"thought" => the item id currently
            #     accumulating, absent once closed. A stream closes the moment
            #     another item takes a position (see place_item/2), so the next
            #     chunk opens a NEW item that sorts after it.
            #   * `segment` — monotonic within the turn; mints those ids
            #     (`msg-<turn>-<segment>`).
            #   * `turn_positions` — conversational ids already placed this
            #     turn, so an item's own later UPDATES (a tool_call_update, a
            #     permission resolution) are not mistaken for a new position
            #     and don't fragment prose streaming alongside them.
            open_streams: %{},
            segment: 0,
            turn_positions: MapSet.new(),
            # True once the agent has advertised session config options (via the
            # session response result or a config_option_update). Selects the
            # set_config_option wire method vs the deprecated set_mode fallback.
            has_config_options?: false

  # Item types that take a POSITION in the conversation (what the transcript
  # renders in order). Everything else an update can produce — plan, usage,
  # config, mode, commands, session_info — is a dock singleton the client
  # renders outside the timeline, so it must never break a prose stream.
  @conversational_types ~w(message thought tool permission error)

  @type t :: %__MODULE__{}

  @doc "Per-tool accumulated-output byte cap. Exposed for tests/inspection."
  @spec max_tool_output() :: pos_integer()
  def max_tool_output, do: @max_tool_output

  @doc "Test/inspection helper: whether a key is present in the reducer map."
  @spec reduce_has_key?(t(), String.t()) :: boolean()
  def reduce_has_key?(state, key), do: Map.has_key?(state.reduce, key)

  @spec new(map()) :: {t(), [binary()]}
  def new(launch) do
    # Turn numbering CONTINUES past a resumed transcript's history rather than
    # restarting at 0. Every per-turn id carries the turn number, and the
    # SessionServer merges its timeline BY ID across the revival — so a reused
    # `msg-1-0` would rewrite the pre-resume reply in place, near the top of
    # the transcript, instead of appending the new one below it. The resume
    # watermark (`resume.seq`, the last seq of the history) is >= every turn
    # number the earlier runs reached, since each of their turns wrote at
    # least one item, so seeding from it keeps every run's ids disjoint.
    state = %__MODULE__{launch: launch, turn: Map.get(launch, :resume_seq, 0)}

    {state, frame} =
      request(
        state,
        "initialize",
        %{
          "protocolVersion" => @protocol_version,
          "clientInfo" => %{"name" => "valea", "version" => launch.client_version},
          # Phase 1: no client-side fs/terminal capabilities.
          "clientCapabilities" => %{}
        },
        :initialize
      )

    {state, [frame]}
  end

  @spec handle_bytes(t(), binary()) :: {t(), [map()], [binary()], [tuple()]}
  def handle_bytes(state, bytes) do
    {lines, buf} = split_lines(state.buf <> bytes)
    {state, overflow_items} = cap_buf(%{state | buf: buf})
    state = place_items(state, overflow_items)

    Enum.reduce(lines, {state, overflow_items, [], []}, fn line, {st, items, replies, effects} ->
      case Jason.decode(line) do
        {:ok, msg} ->
          {st, i, r, e} = dispatch(st, msg)
          # Placement runs AFTER the frame that produced these items, so it
          # only ever affects what the NEXT frame accumulates into.
          {place_items(st, i), items ++ i, replies ++ r, effects ++ e}

        {:error, _} ->
          # Malformed frame: skip, never crash the session. Log it so framing
          # corruption (e.g. stderr spliced into the JSON-RPC stream) is
          # observable rather than silently lost. Logging is the ONE permitted
          # side effect.
          prefix = binary_part(line, 0, min(byte_size(line), 200))
          Logger.warning("[acp] dropped undecodable frame: #{inspect(prefix)}")

          {st, items, replies, effects}
      end
    end)
  end

  # Guard against an unbounded incomplete-line buffer: if the leftover buf after
  # consuming complete lines exceeds @max_line_bytes, RESET it and surface a soft
  # error item. Returns the (possibly reset) state plus any overflow items.
  defp cap_buf(%{buf: buf} = state) when byte_size(buf) > @max_line_bytes do
    item = %{
      "id" => "error-buf",
      "type" => "error",
      "text" => "frame exceeded #{@max_line_bytes} bytes; buffer reset"
    }

    {%{state | buf: ""}, [item]}
  end

  defp cap_buf(state), do: {state, []}

  # --- conversation chronology ---

  # Record each emitted item's place in the turn. The FIRST time a
  # conversational id is seen it occupies a new slot in the conversation, which
  # closes every open prose stream except its own — so prose resuming after it
  # starts a fresh item that sorts after it, instead of flowing back into a
  # bubble that was placed earlier. Repeat appearances of an id (a
  # tool_call_update, a permission resolution) are the SAME slot being revised
  # and change nothing.
  defp place_items(state, items), do: Enum.reduce(items, state, &place_item(&2, &1))

  defp place_item(state, %{"id" => id, "type" => type})
       when type in @conversational_types do
    if MapSet.member?(state.turn_positions, id) do
      state
    else
      state = close_streams_except(state, id)
      %{state | turn_positions: MapSet.put(state.turn_positions, id)}
    end
  end

  defp place_item(state, _item), do: state

  # Closed accumulators can never take another chunk (ids are minted once and
  # never reused), so they leave the reducer working set with the stream.
  defp close_streams_except(state, keep_id) do
    closed = state.open_streams |> Map.values() |> Enum.reject(&(&1 == keep_id))

    %{
      state
      | open_streams: Map.filter(state.open_streams, fn {_kind, id} -> id == keep_id end),
        reduce: Map.drop(state.reduce, closed)
    }
  end

  # The id the given prose stream is accumulating into, opening a new one (next
  # segment of this turn) when it is closed.
  defp open_stream(state, kind, prefix) do
    case Map.fetch(state.open_streams, kind) do
      {:ok, id} ->
        {state, id}

      :error ->
        id = "#{prefix}-#{state.turn}-#{state.segment}"

        {%{
           state
           | segment: state.segment + 1,
             open_streams: Map.put(state.open_streams, kind, id)
         }, id}
    end
  end

  # Begin turn `turn`: nothing streams across a turn boundary, and the leaving
  # turn's still-open accumulators drop out of the reducer working set.
  defp start_turn(state, turn) do
    %{
      state
      | turn: turn,
        segment: 0,
        open_streams: %{},
        turn_positions: MapSet.new(),
        reduce: Map.drop(state.reduce, Map.values(state.open_streams))
    }
  end

  # --- outbound client->agent operations ---

  @spec prompt(t(), String.t() | [map()]) :: {t(), [map()], [binary()]}
  def prompt(state, content) do
    blocks = to_blocks(content)
    turn = state.turn + 1
    # Drop the prior turn's accumulated conversational entries (bounded growth):
    # the user echo of the turn we're leaving, plus — via start_turn/2 — any
    # prose stream still open. Tool entries are pruned on completion in
    # reduce_update/3. A live prompt starts a fresh turn, so reset the replay
    # turn-boundary flag too.
    reduce = Map.drop(state.reduce, ["user-#{state.turn}"])

    state = start_turn(%{state | reduce: reduce, turn_seen_response: false}, turn)

    {state, frame} =
      request(
        state,
        "session/prompt",
        %{"sessionId" => state.session_id, "prompt" => blocks},
        :prompt
      )

    {state, [], [frame]}
  end

  @doc """
  True when a `session/prompt` request is still awaiting its response — i.e. a
  turn is in flight. Single source of truth for "a turn is running".
  """
  @spec turn_in_flight?(t()) :: boolean()
  def turn_in_flight?(state) do
    Enum.any?(state.pending, fn {_id, tag} -> tag == :prompt end)
  end

  defp to_blocks(text) when is_binary(text), do: [%{"type" => "text", "text" => text}]
  defp to_blocks(blocks) when is_list(blocks), do: blocks
  # Defense in depth: a non-string/non-list content must never crash the session.
  defp to_blocks(_), do: []

  @spec cancel(t()) :: {t(), [binary()]}
  def cancel(%{perms: perms} = state) do
    # Cancellation contract: answer EVERY pending permission request with a
    # "cancelled" outcome FIRST, THEN send session/cancel, THEN clear perms. A
    # later human answer for one of those ids becomes a no-op (perms cleared).
    cancelled_frames =
      Enum.map(perms, fn {_item_id, jsonrpc_id} ->
        encode(%{
          "jsonrpc" => "2.0",
          "id" => jsonrpc_id,
          "result" => %{"outcome" => %{"outcome" => "cancelled"}}
        })
      end)

    notify_frame = notify("session/cancel", %{"sessionId" => state.session_id})

    {%{state | perms: %{}, perm_options: %{}}, cancelled_frames ++ [notify_frame]}
  end

  @spec set_config_option(t(), String.t(), term()) :: {t(), [binary()]}
  def set_config_option(state, config_id, value) do
    {state, frame} =
      if state.has_config_options? do
        request(
          state,
          "session/set_config_option",
          %{
            "sessionId" => state.session_id,
            "configId" => config_id,
            "value" => value
          },
          :set_config_option
        )
      else
        # Deprecated fallback for adapters that never advertised config options.
        request(
          state,
          "session/set_mode",
          %{"sessionId" => state.session_id, "modeId" => value},
          :set_mode
        )
      end

    {state, [frame]}
  end

  # All four ACP permission-option kinds — the harness decides which of them
  # it offers on a given request (the UI renders one button per offered
  # option), and resolution below is kind->optionId lookup against exactly
  # those offered options, so an unoffered kind still falls through to the
  # no-op branch. `allow_always`/`reject_always` persistence is the
  # HARNESS's concern (it remembers the rule); Valea just relays the answer.
  @permission_kinds ["allow_once", "allow_always", "reject_once", "reject_always"]

  @doc false
  def permission_kinds, do: @permission_kinds

  @spec answer_permission(t(), String.t(), String.t()) :: {t(), [map()], [binary()]}
  def answer_permission(state, perm_item_id, kind) when kind in @permission_kinds do
    with {jsonrpc_id, perms} <- Map.pop(state.perms, perm_item_id),
         true <- jsonrpc_id != nil,
         %{"options" => options} <- get_item(state, perm_item_id),
         %{"optionId" => option_id} <- Enum.find(options, &(&1["kind"] == kind)) do
      frame =
        encode(%{
          "jsonrpc" => "2.0",
          "id" => jsonrpc_id,
          "result" => %{"outcome" => %{"outcome" => "selected", "optionId" => option_id}}
        })

      resolved = %{
        "id" => perm_item_id,
        "type" => "permission",
        "resolved" => true,
        "outcome" => kind
      }

      state = %{state | perms: perms, perm_options: Map.delete(state.perm_options, perm_item_id)}
      {state, [resolved], [frame]}
    else
      _ -> {state, [], []}
    end
  end

  # Read the stored options for a pending permission item, so kind->optionId
  # resolution works after the permission item was emitted.
  defp get_item(state, perm_item_id) do
    case Map.get(state.perm_options, perm_item_id) do
      nil -> nil
      options -> %{"options" => options}
    end
  end

  # --- framing helpers ---

  defp encode(map), do: Jason.encode!(map) <> "\n"

  defp split_lines(buf) do
    parts = String.split(buf, "\n")
    {complete, [rest]} = Enum.split(parts, -1)
    {complete |> Enum.reject(&(&1 == "")), rest}
  end

  defp request(state, method, params, tag) do
    id = state.next_id
    frame = encode(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})
    {%{state | next_id: id + 1, pending: Map.put(state.pending, id, tag)}, frame}
  end

  defp notify(method, params) do
    encode(%{"jsonrpc" => "2.0", "method" => method, "params" => params})
  end

  # --- dispatch: responses to our requests ---

  defp dispatch(state, %{"id" => id, "result" => result}) when is_map_key(state.pending, id) do
    {tag, pending} = Map.pop(state.pending, id)
    handle_response(%{state | pending: pending}, tag, result)
  end

  defp dispatch(state, %{"id" => id, "error" => err}) when is_map_key(state.pending, id) do
    {tag, pending} = Map.pop(state.pending, id)
    # Surface as a soft error item; do not crash. `error_message/1` keeps the
    # item's text human-readable ("Authentication required"), never a raw
    # inspect of the JSON-RPC error map — the transcript renders this string
    # verbatim.
    item = %{"id" => "error-#{id}", "type" => "error", "text" => error_message(err)}
    # Items/effects by tag:
    #   * :prompt — a failed prompt must still complete the turn lifecycle,
    #     otherwise the server stays "busy" forever and the queue never drains.
    #     That means the turn ITEM too, not just the {:turn, _} effect: the
    #     client's busy falling edge listens for a `turn` item exactly as it
    #     does on a successful turn.
    #   * handshake tags — an ERROR here is fatal per spec: emit
    #     {:handshake_failed, reason} so the SessionServer transitions to :failed
    #     (the soft error item alone has no effect and would leave it :running).
    #   * anything else (e.g. :set_config_option) — keep just the error item.
    {items, effects} =
      cond do
        tag == :prompt ->
          turn = %{"id" => "turn-#{state.turn}", "type" => "turn", "stop_reason" => "error"}
          {[item, turn], [{:turn, "error"}]}

        tag in [:initialize, :session_new, :session_load, :session_resume] ->
          {[item], [{:handshake_failed, error_message(err)}]}

        true ->
          {[item], []}
      end

    {%{state | pending: pending}, items, [], effects}
  end

  defp dispatch(state, msg), do: dispatch_incoming(state, msg)

  # Best-effort human-readable reason from a JSON-RPC error object.
  defp error_message(%{"message" => m}) when is_binary(m), do: m
  defp error_message(err), do: inspect(err)

  defp cap?(true), do: true
  defp cap?(cap) when is_map(cap), do: true
  defp cap?(_), do: false

  defp handle_response(state, :initialize, result) do
    negotiated = result["protocolVersion"]

    if negotiated != 1 do
      {state, [], [], [{:handshake_failed, "protocol version mismatch: #{inspect(negotiated)}"}]}
    else
      # A capability may be advertised as `true` OR as an (even empty)
      # object — claude-agent-acp 0.58.1 sends `resume: {}`. Presence of
      # either form counts.
      caps = %{
        load?: cap?(get_in(result, ["agentCapabilities", "loadSession"])),
        resume?:
          cap?(get_in(result, ["agentCapabilities", "sessionCapabilities", "resume"])) ||
            cap?(get_in(result, ["sessionCapabilities", "resume"]))
      }

      {state, frame} = open_session_frames(state, caps)
      {state, [], [frame], []}
    end
  end

  defp handle_response(state, :session_new, result) do
    cid = result["sessionId"]

    state = %{
      state
      | session_id: cid,
        has_config_options?: state.has_config_options? or has_config?(result)
    }

    # {:session_ready} disarms the SessionServer's handshake watchdog;
    # {:conversation_id} persists the agent-assigned session id.
    {state, config_items(result), [], [{:session_ready}, {:conversation_id, cid}]}
  end

  defp handle_response(state, :session_load, result) do
    # session/load has no sessionId in the result — keep the launch conversation_id.
    # History replays as session/update notifications (deduped by messageId).
    ready_from_load(state, result)
  end

  defp handle_response(state, :session_resume, result) do
    # session/resume mirrors session/load: no replay, keep the launch id.
    ready_from_load(state, result)
  end

  defp handle_response(state, :prompt, result) do
    stop = result["stopReason"]
    item = %{"id" => "turn-#{state.turn}", "type" => "turn", "stop_reason" => stop}
    {state, [item], [], [{:turn, stop}]}
  end

  # `session/set_config_option`'s RESPONSE carries the refreshed
  # configOptions — claude-agent-acp returns the full array here instead of
  # pushing a `config_option_update` notification (that notification only
  # fires on the adapter's own internal changes, e.g. plan-mode exit). Left
  # to the catch-all below, the change lands agent-side but the composer
  # chips keep their stale `current` forever. Re-emit as config items: ids
  # are stable (`config-<id>`), so the client upserts them in place.
  defp handle_response(state, :set_config_option, result) do
    {state, config_items(result), [], []}
  end

  defp handle_response(state, _tag, _result), do: {state, [], [], []}

  defp ready_from_load(state, result) do
    state = %{
      state
      | session_id: state.launch.conversation_id,
        has_config_options?: state.has_config_options? or has_config?(result)
    }

    {state, config_items(result), [], [{:session_ready}]}
  end

  # session/resume (preferred) > session/load > session/new. All carry cwd +
  # mcpServers: []. resume/load require a conversation id and the matching
  # runtime-advertised capability; otherwise degrade to a fresh session/new.
  #
  # `additional_roots`/`managed_settings`/`system_prompt_append` are optional
  # fields on the launch map (see docs/notes/acp-launch-contract.md), each
  # gated on presence — a launch map without them keeps `base` at the bare
  # `%{"cwd" => ..., "mcpServers" => []}`.
  defp open_session_frames(%{launch: launch} = state, caps) do
    base =
      %{"cwd" => launch.cwd, "mcpServers" => []}
      |> put_additional_directories(launch)
      |> put_managed_settings(launch)
      |> put_system_prompt(launch)

    cond do
      (launch.mode in [:resume, :load] and launch.conversation_id) && caps.resume? ->
        request(
          state,
          "session/resume",
          Map.put(base, "sessionId", launch.conversation_id),
          :session_resume
        )

      (launch.mode in [:resume, :load] and launch.conversation_id) && caps.load? ->
        request(
          state,
          "session/load",
          Map.put(base, "sessionId", launch.conversation_id),
          :session_load
        )

      true ->
        request(state, "session/new", base, :session_new)
    end
  end

  # additionalDirectories is a native session/new field (per the contract
  # note's "Additional read roots" section) — not a Valea `_meta` invention.
  # Gated: only added when the launch map carries a non-empty list.
  defp put_additional_directories(base, launch) do
    case Map.get(launch, :additional_roots) do
      roots when is_list(roots) and roots != [] -> Map.put(base, "additionalDirectories", roots)
      _ -> base
    end
  end

  # The in-memory managed-settings posture rides the adapter's SDK-options
  # pass-through channel `_meta.claudeCode.options.managedSettings` (per the
  # contract note's "Managed settings" section) — never written to disk.
  # Gated: only added when the launch map carries a JSON string.
  defp put_managed_settings(base, launch) do
    case Map.get(launch, :managed_settings) do
      json when is_binary(json) ->
        put_meta(base, "claudeCode", %{"options" => %{"managedSettings" => json}})

      _ ->
        base
    end
  end

  # The session-context bootstrap (`SessionSettings.context/1` — the same
  # text the harness materializes as context.md) rides the adapter's
  # `_meta.systemPrompt` channel: an OBJECT there is forwarded to the SDK
  # locked to `{type: "preset", preset: "claude_code", ...}`, so `append`
  # ADDS to Claude Code's own system prompt rather than replacing it (see
  # the contract note's "System prompt append" section). Gated: only added
  # when the launch map carries non-empty text.
  defp put_system_prompt(base, launch) do
    case Map.get(launch, :system_prompt_append) do
      text when is_binary(text) and text != "" ->
        put_meta(base, "systemPrompt", %{"append" => text})

      _ ->
        base
    end
  end

  # `_meta` accumulates across the put_* helpers above — merged at the top
  # level so `claudeCode` (SDK options) and `systemPrompt` coexist on one
  # frame instead of the last write clobbering the map.
  defp put_meta(base, key, value) do
    Map.update(base, "_meta", %{key => value}, &Map.put(&1, key, value))
  end

  defp has_config?(result) do
    case result["configOptions"] do
      list when is_list(list) and list != [] -> true
      _ -> false
    end
  end

  # Build the config render items from a session response result. Prefer the
  # current `configOptions` array; fall back to legend's `modes`/`models` objects
  # for older adapters. An absent config object yields no item.
  defp config_items(result) do
    case result["configOptions"] do
      list when is_list(list) and list != [] ->
        Enum.map(list, &config_item_from_option/1)

      _ ->
        Enum.reject(
          [
            legacy_config_item("mode", result["modes"]),
            legacy_config_item("model", result["models"])
          ],
          &is_nil/1
        )
    end
  end

  # Normalize a session config option to the `config` render item.
  defp config_item_from_option(option) do
    config_id = to_string(option["configId"] || option["id"])

    %{
      "id" => "config-" <> config_id,
      # The RAW wire id `session/set_config_option` expects back as
      # `configId`. The render item's own "id" above is prefixed for
      # timeline uniqueness and must NEVER be echoed to the adapter — it
      # rejects it as `Unknown config option: config-<...>` (which is
      # exactly how every composer model/effort/mode change used to fail).
      "config_id" => config_id,
      "type" => "config",
      "name" => option["name"],
      "category" => option["category"],
      "current" => option["value"] || option["currentValue"],
      "options" => option["options"] || []
    }
  end

  # Legacy fallback: mode/model selector objects ({currentXId, availableXs}).
  defp legacy_config_item(id, %{} = config) do
    available = config["availableModes"] || config["availableModels"]

    if is_list(available) do
      %{
        "id" => id,
        "type" => id,
        "current" => config["currentModeId"] || config["currentModelId"],
        "available" => Enum.map(available, &legacy_config_option/1)
      }
    end
  end

  defp legacy_config_item(_id, _), do: nil

  defp legacy_config_option(o) do
    %{"id" => o["id"] || o["modelId"], "name" => o["name"]}
    |> then(fn opt ->
      if o["description"], do: Map.put(opt, "description", o["description"]), else: opt
    end)
  end

  # --- inbound agent->client requests ---

  defp dispatch_incoming(state, %{
         "id" => id,
         "method" => "session/request_permission",
         "params" => p
       }) do
    perm_id = "perm-#{id}"
    options = p["options"] || []

    item = %{
      "id" => perm_id,
      "type" => "permission",
      "title" => get_in(p, ["toolCall", "title"]) || "Permission request",
      "command" => get_in(p, ["toolCall", "rawInput", "command"]),
      "rawInput" => get_in(p, ["toolCall", "rawInput"]),
      "kind" => get_in(p, ["toolCall", "kind"]),
      "options" => options,
      "resolved" => false
    }

    state = %{
      state
      | perms: Map.put(state.perms, perm_id, id),
        perm_options: Map.put(state.perm_options, perm_id, options)
    }

    {state, [item], [], [{:permission_requested, item}]}
  end

  # Any other inbound agent->client REQUEST (has both "id" and "method") targets a
  # client capability we never advertised (e.g. fs/read_text_file). Reply with
  # JSON-RPC -32601 so the agent gets a response instead of hanging. Notifications
  # (no "id") fall through to session/update handling and the catch-all.
  defp dispatch_incoming(state, %{"id" => id, "method" => _method}) do
    reply =
      encode(%{
        "jsonrpc" => "2.0",
        "id" => id,
        "error" => %{"code" => -32_601, "message" => "Method not found"}
      })

    {state, [], [reply], []}
  end

  # --- session/update reduction (agent->client notifications) ---

  defp dispatch_incoming(state, %{"method" => "session/update", "params" => %{"update" => u}}) do
    {state, item} = reduce_update(state, u, u["sessionUpdate"])
    if item, do: {state, [item], [], []}, else: {state, [], [], []}
  end

  defp dispatch_incoming(state, _msg), do: {state, [], [], []}

  defp reduce_update(state, u, "agent_message_chunk") do
    case dedup(state, u) do
      {:skip, state} ->
        {state, nil}

      {:keep, state} ->
        state = mark_agent_output(state)
        {state, id} = open_stream(state, "message", "msg")
        {state, item} = accumulate(state, id, "message", %{"role" => "assistant"}, text(u))

        {state, put_message_id(item, u)}
    end
  end

  defp reduce_update(state, u, "agent_thought_chunk") do
    state = mark_agent_output(state)
    {state, id} = open_stream(state, "thought", "thought")
    accumulate(state, id, "thought", %{}, text(u))
  end

  defp reduce_update(state, u, "user_message_chunk") do
    case dedup(state, u) do
      {:skip, state} ->
        {state, nil}

      {:keep, state} ->
        # Turn-boundary detection: a user message that FOLLOWS agent output in
        # the notification stream begins a new turn. This is how session/load
        # replay — which never calls prompt/2 — produces distinct user-N/msg-N
        # per turn. Consecutive user chunks stay in one turn.
        state =
          if state.turn_seen_response do
            start_turn(%{state | turn_seen_response: false}, state.turn + 1)
          else
            state
          end

        {state, item} =
          accumulate(state, "user-#{state.turn}", "message", %{"role" => "user"}, text(u))

        {state, put_message_id(item, u)}
    end
  end

  defp reduce_update(state, u, kind) when kind in ["tool_call", "tool_call_update"] do
    state = mark_agent_output(state)
    id = u["toolCallId"]
    prev = Map.get(state.reduce, id, %{"id" => id, "type" => "tool"})

    item =
      prev
      |> merge_present(u, "title")
      |> merge_present(u, "kind")
      |> merge_present(u, "status")
      |> put_tool_content(u["content"])
      |> put_tool_locations(u["locations"], state.launch.cwd)

    # Once a tool reaches a terminal status, drop it from the working set AFTER
    # emitting the final item. The timeline holds the canonical copy by id; a
    # later stray update just rebuilds a bare base entry (acceptable).
    reduce =
      if item["status"] in ["completed", "failed"] do
        Map.delete(state.reduce, id)
      else
        Map.put(state.reduce, id, item)
      end

    {%{state | reduce: reduce}, item}
  end

  defp reduce_update(state, u, "plan"),
    do: {state, %{"id" => "plan", "type" => "plan", "entries" => plan_entries(u["entries"])}}

  defp reduce_update(state, u, "available_commands_update"),
    do:
      {state,
       %{"id" => "commands", "type" => "commands", "commands" => u["availableCommands"] || []}}

  defp reduce_update(state, u, "current_mode_update"),
    # Legacy fallback: only `current` — the timeline merge-by-id preserves the
    # `available` list captured at handshake.
    do: {state, %{"id" => "mode", "type" => "mode", "current" => u["currentModeId"]}}

  defp reduce_update(state, u, "config_option_update") do
    option = u["configOption"] || u
    {%{state | has_config_options?: true}, config_item_from_option(option)}
  end

  defp reduce_update(state, u, "session_info_update") do
    {state, %{"id" => "session_info", "type" => "session_info", "title" => u["title"]}}
  end

  defp reduce_update(state, u, "usage_update") do
    {state, Map.merge(%{"id" => "usage", "type" => "usage"}, Map.drop(u, ["sessionUpdate"]))}
  end

  defp reduce_update(state, _u, _other), do: {state, nil}

  # Message dedup, two layers:
  #
  #   * `launch.known_message_ids` — messages already persisted in the
  #     transcript; every chunk of one of those is a session/load replay of
  #     history we already have, skipped unconditionally.
  #   * `seen_message_ids` — ids kept earlier in THIS connection, so a
  #     duplicate re-delivery collapses. Crucially, "seen" only skips once the
  #     message is no longer the ACTIVE one (`active_message_id`): live
  #     streams (claude-agent-acp 0.58.1+) stamp the SAME messageId on every
  #     chunk of one message, so a seen-but-active id is a continuation chunk
  #     that must accumulate, not a duplicate. The one shape this cannot
  #     distinguish is an identical full-message re-delivery arriving
  #     IMMEDIATELY consecutively (indistinguishable from a continuation
  #     without comparing content) — accepted; nothing sends that.
  #
  # Chunks without a messageId always pass through.
  defp dedup(state, u) do
    case u["messageId"] do
      nil ->
        {:keep, state}

      id ->
        known = Map.get(state.launch, :known_message_ids, MapSet.new())

        cond do
          MapSet.member?(known, id) ->
            {:skip, state}

          MapSet.member?(state.seen_message_ids, id) and id != state.active_message_id ->
            {:skip, state}

          true ->
            {:keep,
             %{
               state
               | seen_message_ids: MapSet.put(state.seen_message_ids, id),
                 active_message_id: id
             }}
        end
    end
  end

  # Record that the current turn has produced agent-side output, so the next
  # user_message_chunk during session/load replay opens a new turn.
  defp mark_agent_output(state), do: %{state | turn_seen_response: true}

  # Persist the chunk's messageId on the item (and so into the transcript):
  # a later same-transcript RESUME seeds `known_message_ids` from exactly
  # these, so the session/load fallback's history replay dedups instead of
  # duplicating what the timeline already holds.
  defp put_message_id(item, %{"messageId" => mid}) when is_binary(mid),
    do: Map.put(item, "message_id", mid)

  defp put_message_id(item, _u), do: item

  defp accumulate(state, id, type, base, chunk) do
    prev = Map.get(state.reduce, id, Map.merge(%{"id" => id, "type" => type, "text" => ""}, base))
    item = %{prev | "text" => prev["text"] <> chunk}
    {%{state | reduce: Map.put(state.reduce, id, item)}, item}
  end

  defp text(%{"content" => %{"text" => t}}) when is_binary(t), do: t
  defp text(_), do: ""

  defp merge_present(item, u, key) do
    case u[key] do
      nil -> item
      v -> Map.put(item, key, v)
    end
  end

  defp put_tool_content(item, nil), do: item

  defp put_tool_content(item, content) when is_list(content) do
    diff = Enum.find(content, &(&1["type"] == "diff"))

    text =
      content
      |> Enum.filter(&(&1["type"] in ["content", "text"]))
      |> Enum.map_join("", &(get_in(&1, ["content", "text"]) || &1["text"] || ""))

    # Only overwrite "diff" when THIS update carries one — a later content-only
    # update must not erase a diff set by an earlier tool_call(_update).
    item
    |> then(fn item ->
      if diff,
        do: Map.put(item, "diff", Map.take(diff, ["path", "oldText", "newText"])),
        else: item
    end)
    |> Map.update("output", cap_output(text), &cap_output(&1 <> text))
  end

  defp put_tool_content(item, _content), do: item

  # Relay ACP `toolCall.locations` (file paths a tool touched) onto the tool
  # item so the frontend can offer "open this file" affordances (side-panes
  # pass). Only set when THIS update carries a non-empty list — a later
  # location-less update must not erase them (same rule as "diff"). Each
  # entry keeps the raw "path" verbatim and gains "relPath" only when
  # `location_rel/3` proves the path resolves INSIDE the session's cwd (the
  # ICM root).
  defp put_tool_locations(item, locations, cwd) when is_list(locations) do
    rendered =
      for loc <- locations,
          is_map(loc),
          path = loc["path"],
          is_binary(path),
          path != "" do
        %{"path" => path}
        |> put_location_line(loc["line"])
        |> put_location_rel(path, cwd)
      end

    if rendered == [], do: item, else: Map.put(item, "locations", rendered)
  end

  defp put_tool_locations(item, _locations, _cwd), do: item

  defp put_location_line(entry, line) when is_integer(line), do: Map.put(entry, "line", line)
  defp put_location_line(entry, _line), do: entry

  defp put_location_rel(entry, path, cwd) when is_binary(cwd) do
    # Normalize BEFORE comparing: the agent reports raw OS paths, so a Windows
    # agent sends `C:\ws\notes.md` against a normalized `C:/ws` cwd.
    # `absolute?/1` and `relative_to/2` normalize internally, but `ancestor?/2`
    # only case-folds — feeding it the backslash form answers false and every
    # in-ICM location would silently lose its relPath. Identity on unix.
    # "path" keeps the agent's ORIGINAL string; only "relPath" is derived from
    # the normalized (forward-slash) form, which is what the frontend joins.
    case location_rel(path, cwd) do
      {:ok, rel} -> Map.put(entry, "relPath", rel)
      :none -> entry
    end
  end

  defp put_location_rel(entry, _path, _cwd), do: entry

  @doc """
  The mount-relative form of an agent-reported tool-call location, or `:none`
  when the path does not provably resolve INSIDE `cwd`.

  `relPath` is the one TRUSTED field on a location entry: the frontend joins
  it into a `/knowledge/...` href and navigates there, so whatever reaches it
  is agent-controlled routing input. A purely lexical prefix/relativize pair
  is not enough for that job — `Valea.Paths.relative_to/3` deliberately does
  NOT collapse `.`/`..` (see its doc), so a raw `/ws/icm/../../etc/passwd`
  used to answer `ancestor?` true on the string prefix alone and hand back
  `../../etc/passwd`, which the browser's own URL parser then normalized
  straight out of the app's route space.

  So the path is RESOLVED first: `resolve_lexical/3` floors `..` against the
  root, and containment is asked of the RESOLVED form. Three further rules
  keep it closed:

    * `cwd` must classify `:absolute` — there is no root to floor `..`
      against otherwise, and `resolve_lexical/3` raises rather than guess;
    * only `:absolute` and `:relative` paths resolve at all —
      `:drive_relative` (`C:foo`) and `:invalid` (`/x`, `\\\\.\\…`, bare
      `//host`) are the ambiguous Windows shapes the `Valea.Paths` moduledoc
      requires to fail closed, and they used to fall into the relative bucket
      and emit a relPath verbatim;
    * a surviving `..` segment is rejected outright. `resolve_lexical/3`
      cannot leave one behind today; the check is what keeps "no `..` in a
      relPath" a property of THIS function rather than an inherited
      implementation detail of that one.

  `platform` is explicit so the Windows classifications are testable on any
  host — the same pure-seam convention `Valea.Paths` documents for its own
  functions; `put_location_rel/3` passes the host's.
  """
  @spec location_rel(String.t(), String.t(), Valea.Paths.platform()) ::
          {:ok, String.t()} | :none
  def location_rel(path, cwd, platform \\ Valea.Paths.host_platform()) do
    # Normalize BEFORE comparing: the agent reports raw OS paths, so a Windows
    # agent sends `C:\ws\notes.md` against an already-normalized `C:/ws` cwd,
    # and `ancestor?/3` only case-folds — it never normalizes. Identity on
    # unix. The caller keeps the agent's ORIGINAL string in "path"; only
    # "relPath" is derived from the normalized (forward-slash) form, which is
    # what the frontend joins.
    p = Valea.Paths.normalize(path, platform)
    root = Valea.Paths.normalize(cwd, platform)

    with :absolute <- Valea.Paths.classify(root, platform),
         kind when kind in [:absolute, :relative] <- Valea.Paths.classify(p, platform),
         resolved = Valea.Paths.resolve_lexical(p, root, platform),
         true <- Valea.Paths.ancestor?(root, resolved, platform),
         rel when rel != "." <- Valea.Paths.relative_to(resolved, root, platform),
         false <- ".." in String.split(rel, "/") do
      {:ok, rel}
    else
      _ -> :none
    end
  end

  # Bound accumulated tool output to @max_tool_output bytes, keeping the tail
  # (most recent output) behind a leading truncation marker.
  defp cap_output(output) when byte_size(output) <= @max_tool_output, do: output

  defp cap_output(output) do
    keep = @max_tool_output - byte_size(@tool_output_truncation_marker)

    tail =
      output
      |> binary_part(byte_size(output) - keep, keep)
      |> trim_to_codepoint_boundary()

    @tool_output_truncation_marker <> tail
  end

  # Byte-slicing UTF-8 can land mid-codepoint; drop leading continuation bytes
  # (0b10xxxxxx) so the kept tail starts on a valid boundary and the result is
  # always valid UTF-8 (and therefore JSON-encodable over the channel).
  defp trim_to_codepoint_boundary(<<0b10::2, _::6, rest::binary>>),
    do: trim_to_codepoint_boundary(rest)

  defp trim_to_codepoint_boundary(tail), do: tail

  defp plan_entries(nil), do: []

  defp plan_entries(entries),
    do: Enum.map(entries, &%{"text" => &1["content"] || &1["title"], "status" => &1["status"]})
end
