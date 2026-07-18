defmodule ValeaWeb.WorkspaceEventsChannel do
  use Phoenix.Channel

  @impl true
  def join("workspace:events", _payload, socket) do
    Phoenix.PubSub.subscribe(Valea.PubSub, "workspace")
    Phoenix.PubSub.subscribe(Valea.PubSub, "icm")
    Phoenix.PubSub.subscribe(Valea.PubSub, "mail")
    Phoenix.PubSub.subscribe(Valea.PubSub, "mounts")
    Phoenix.PubSub.subscribe(Valea.PubSub, "calendar")
    {:ok, socket}
  end

  @impl true
  def handle_info({:workspace_opened, info, generation}, socket) do
    push(socket, "workspace", %{
      "open" => true,
      "name" => info.name,
      "path" => info.path,
      "generation" => generation
    })

    {:noreply, socket}
  end

  def handle_info({:workspace_closed}, socket) do
    push(socket, "workspace", %{"open" => false})
    {:noreply, socket}
  end

  def handle_info({:icm_changed}, socket) do
    push(socket, "icm_changed", %{})
    {:noreply, socket}
  end

  def handle_info({:mounts_changed}, socket) do
    push(socket, "mounts_changed", %{})
    {:noreply, socket}
  end

  def handle_info({:mail_status_changed, slug, status}, socket) do
    push(socket, "mail_status", stringify(status) |> Map.put("account", slug))
    {:noreply, socket}
  end

  def handle_info({:mail_sync_started, slug}, socket) do
    push(socket, "mail_sync", %{"phase" => "started", "newMessages" => 0, "account" => slug})
    {:noreply, socket}
  end

  def handle_info({:mail_sync_finished, slug, %{new_messages: new_messages}}, socket) do
    push(socket, "mail_sync", %{
      "phase" => "finished",
      "newMessages" => new_messages,
      "account" => slug
    })

    {:noreply, socket}
  end

  def handle_info({:mail_message_upserted, slug, %{path: path}}, socket) do
    push(socket, "mail_message", %{"path" => path, "account" => slug})
    {:noreply, socket}
  end

  # Calendar pushes (calendar spec F, §RPC surface "Channel pushes"): the
  # spec's channel table is the wire contract — string keys, SNAKE_CASE
  # `event_count` (deliberately NOT mail's camelCase push style).
  def handle_info({:calendar_status_changed, slug, status}, socket) do
    push(socket, "calendar_status", stringify(status) |> Map.put("source", slug))
    {:noreply, socket}
  end

  def handle_info({:calendar_synced, slug, %{event_count: event_count}}, socket) do
    push(socket, "calendar_synced", %{"source" => slug, "event_count" => event_count})
    {:noreply, socket}
  end

  def handle_info({:calendar_local_changed}, socket) do
    push(socket, "calendar_local_changed", %{})
    {:noreply, socket}
  end

  # `Valea.Mail.Engine.status/0`'s map is atom-keyed; the channel payload
  # must be string keys (mirrors `Valea.Api.Mail.mail_status`'s identical
  # top-level stringify for the RPC surface).
  defp stringify(status), do: Map.new(status, fn {k, v} -> {to_string(k), v} end)
end
