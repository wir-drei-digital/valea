defmodule ValeaWeb.AgentSessionChannel do
  @moduledoc """
  Live attach (+ file replay for ended sessions) to one agent session.
  Topic `agent_session:<id>`; join reply mirrors `SessionServer.attach/1`:
  `%{items, cursor, busy, status}`. A LIVE session (Registry hit) attaches
  through the running `SessionServer`; an ENDED session (no process, but a
  transcript file) replays from disk with `busy: false, status: "ended"`. An
  unknown id (neither) is a join error.

  Inbound events on an ENDED session all reply `session_not_found` — there is
  no process left to act on.
  """

  use Phoenix.Channel

  alias Valea.Agents
  alias Valea.Agents.SessionServer

  @impl true
  def join("agent_session:" <> id, _payload, socket) do
    # Subscribe BEFORE reading the attach/replay snapshot (not after): any
    # event racing the snapshot then arrives via BOTH the snapshot and a
    # PubSub broadcast, and the `seq > cursor` gate in handle_info/2 below
    # drops the duplicate. The reverse order risks a genuine gap instead —
    # unrecoverable — so it always favors a filterable duplicate.
    Phoenix.PubSub.subscribe(Valea.PubSub, "agent_session:" <> id)

    case Agents.attach_or_replay(id) do
      {:ok, reply} ->
        socket =
          assign(socket,
            session_id: id,
            cursor: reply.cursor,
            ended: reply.status == "ended"
          )

        {:ok, reply, socket}

      {:error, :not_found} ->
        {:error, %{reason: "session_not_found"}}
    end
  end

  # An ended session has no live process to act on — every inbound control
  # event on it replies the same error, regardless of which event it is. This
  # clause runs BEFORE the specific handlers below because it matches first.
  @impl true
  def handle_in(_event, _payload, %{assigns: %{ended: true}} = socket) do
    {:reply, {:error, %{reason: "session_not_found"}}, socket}
  end

  def handle_in("prompt", %{"content" => content}, socket) when is_binary(content) do
    SessionServer.prompt(socket.assigns.session_id, content)
    {:noreply, socket}
  end

  def handle_in("cancel", _payload, socket) do
    SessionServer.cancel(socket.assigns.session_id)
    {:noreply, socket}
  end

  def handle_in("permission", %{"item_id" => item_id, "kind" => kind}, socket)
      when kind in ["allow_once", "reject_once"] do
    SessionServer.answer_permission(socket.assigns.session_id, item_id, kind)
    {:noreply, socket}
  end

  def handle_in("permission", _payload, socket) do
    {:reply, {:error, %{reason: "invalid_permission_kind"}}, socket}
  end

  def handle_in("set_config_option", %{"config_id" => config_id, "value" => value}, socket) do
    SessionServer.set_config_option(socket.assigns.session_id, config_id, value)
    {:noreply, socket}
  end

  def handle_in("stop", _payload, socket) do
    SessionServer.stop(socket.assigns.session_id)
    {:noreply, socket}
  end

  # Catch-all: an unknown event, or a known event with a payload matching no
  # clause above, must not crash the per-viewer channel process.
  def handle_in(_event, _payload, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:session_event, seq, item}, socket) do
    if seq > socket.assigns.cursor do
      push(socket, "event", %{seq: seq, item: item})
      {:noreply, assign(socket, :cursor, seq)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:session_status, status}, socket) do
    push(socket, "status", %{status: to_string(status)})
    {:noreply, socket}
  end

  def handle_info({:session_exit, exit_code}, socket) do
    push(socket, "exit", %{exit_code: exit_code})
    {:noreply, socket}
  end
end
