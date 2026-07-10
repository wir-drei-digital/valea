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
            # True once the agent has advertised session config options (via the
            # session response result or a config_option_update). Selects the
            # set_config_option wire method vs the deprecated set_mode fallback.
            has_config_options?: false

  @type t :: %__MODULE__{}

  @doc "Per-tool accumulated-output byte cap. Exposed for tests/inspection."
  @spec max_tool_output() :: pos_integer()
  def max_tool_output, do: @max_tool_output

  @doc "Test/inspection helper: whether a key is present in the reducer map."
  @spec reduce_has_key?(t(), String.t()) :: boolean()
  def reduce_has_key?(state, key), do: Map.has_key?(state.reduce, key)

  @spec new(map()) :: {t(), [binary()]}
  def new(launch) do
    state = %__MODULE__{launch: launch}

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

    Enum.reduce(lines, {state, overflow_items, [], []}, fn line, {st, items, replies, effects} ->
      case Jason.decode(line) do
        {:ok, msg} ->
          {st, i, r, e} = dispatch(st, msg)
          {st, items ++ i, replies ++ r, effects ++ e}

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

  # --- outbound client->agent operations ---

  @spec prompt(t(), String.t() | [map()]) :: {t(), [map()], [binary()]}
  def prompt(state, content) do
    blocks = to_blocks(content)
    turn = state.turn + 1
    # Drop the prior turn's accumulated conversational entries (bounded growth):
    # msg-/thought-/user- of the turn we're leaving. Tool entries are pruned on
    # completion in reduce_update/3. A live prompt starts a fresh turn, so reset
    # the replay turn-boundary flag too.
    reduce =
      Map.drop(state.reduce, [
        "msg-#{state.turn}",
        "thought-#{state.turn}",
        "user-#{state.turn}"
      ])

    state = %{state | turn: turn, reduce: reduce, turn_seen_response: false}

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

  @spec answer_permission(t(), String.t(), String.t()) :: {t(), [map()], [binary()]}
  def answer_permission(state, perm_item_id, kind) when kind in ["allow_once", "reject_once"] do
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
    # Surface as a soft error item; do not crash.
    item = %{"id" => "error-#{id}", "type" => "error", "text" => inspect(err)}
    # Effects by tag:
    #   * :prompt — a failed prompt must still complete the turn lifecycle,
    #     otherwise the server stays "busy" forever and the queue never drains.
    #   * handshake tags — an ERROR here is fatal per spec: emit
    #     {:handshake_failed, reason} so the SessionServer transitions to :failed
    #     (the soft error item alone has no effect and would leave it :running).
    #   * anything else (e.g. :set_config_option) — keep just the error item.
    effects =
      cond do
        tag == :prompt ->
          [{:turn, "error"}]

        tag in [:initialize, :session_new, :session_load, :session_resume] ->
          [{:handshake_failed, error_message(err)}]

        true ->
          []
      end

    {%{state | pending: pending}, [item], [], effects}
  end

  defp dispatch(state, msg), do: dispatch_incoming(state, msg)

  # Best-effort human-readable reason from a JSON-RPC error object.
  defp error_message(%{"message" => m}) when is_binary(m), do: m
  defp error_message(err), do: inspect(err)

  defp handle_response(state, :initialize, result) do
    negotiated = result["protocolVersion"]

    if negotiated != 1 do
      {state, [], [], [{:handshake_failed, "protocol version mismatch: #{inspect(negotiated)}"}]}
    else
      caps = %{
        load?: get_in(result, ["agentCapabilities", "loadSession"]) == true,
        resume?:
          get_in(result, ["agentCapabilities", "sessionCapabilities", "resume"]) == true ||
            get_in(result, ["sessionCapabilities", "resume"]) == true
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
  defp open_session_frames(%{launch: launch} = state, caps) do
    base = %{"cwd" => launch.cwd, "mcpServers" => []}

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
    %{
      "id" => "config-" <> to_string(option["configId"] || option["id"]),
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
        accumulate(state, "msg-#{state.turn}", "message", %{"role" => "assistant"}, text(u))
    end
  end

  defp reduce_update(state, u, "agent_thought_chunk") do
    state = mark_agent_output(state)
    accumulate(state, "thought-#{state.turn}", "thought", %{}, text(u))
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
            %{state | turn: state.turn + 1, turn_seen_response: false}
          else
            state
          end

        accumulate(state, "user-#{state.turn}", "message", %{"role" => "user"}, text(u))
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

  # session/load replay dedup: a chunk carrying a messageId already known (from
  # the launch, or seen earlier this replay) is skipped; a new messageId is
  # recorded so intra-replay duplicates also collapse. Chunks without a
  # messageId (live stream) always pass through.
  defp dedup(state, u) do
    case u["messageId"] do
      nil ->
        {:keep, state}

      id ->
        known = Map.get(state.launch, :known_message_ids, MapSet.new())

        if MapSet.member?(known, id) or MapSet.member?(state.seen_message_ids, id) do
          {:skip, state}
        else
          {:keep, %{state | seen_message_ids: MapSet.put(state.seen_message_ids, id)}}
        end
    end
  end

  # Record that the current turn has produced agent-side output, so the next
  # user_message_chunk during session/load replay opens a new turn.
  defp mark_agent_output(state), do: %{state | turn_seen_response: true}

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
