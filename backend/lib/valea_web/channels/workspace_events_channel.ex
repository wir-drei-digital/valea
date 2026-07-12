defmodule ValeaWeb.WorkspaceEventsChannel do
  use Phoenix.Channel

  @impl true
  def join("workspace:events", _payload, socket) do
    Phoenix.PubSub.subscribe(Valea.PubSub, "workspace")
    Phoenix.PubSub.subscribe(Valea.PubSub, "icm")
    Phoenix.PubSub.subscribe(Valea.PubSub, "queue")
    Phoenix.PubSub.subscribe(Valea.PubSub, "mail")
    Phoenix.PubSub.subscribe(Valea.PubSub, "mail_ops")
    Phoenix.PubSub.subscribe(Valea.PubSub, "mounts")
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

  def handle_info({:queue_changed}, socket) do
    push(socket, "queue_changed", %{})
    {:noreply, socket}
  end

  def handle_info({:mail_status_changed, status}, socket) do
    push(socket, "mail_status", stringify(status))
    {:noreply, socket}
  end

  def handle_info({:mail_sync_started}, socket) do
    push(socket, "mail_sync", %{"phase" => "started", "newMessages" => 0})
    {:noreply, socket}
  end

  def handle_info({:mail_sync_finished, %{new_messages: new_messages}}, socket) do
    push(socket, "mail_sync", %{"phase" => "finished", "newMessages" => new_messages})
    {:noreply, socket}
  end

  def handle_info({:mail_message_upserted, %{path: path}}, socket) do
    push(socket, "mail_message", %{"path" => path})
    {:noreply, socket}
  end

  def handle_info({:mailbox_ops_updated, run_id}, socket) do
    push(socket, "mailbox_ops", %{"runId" => run_id})
    {:noreply, socket}
  end

  # `:mailbox_ops_pending` is the Engine's own internal trigger (an
  # approve/reject just landed, or the activation recovery scan re-firing
  # it) — nothing here for the UI to react to yet; `:mailbox_ops_updated`
  # (above) is the terminal, UI-relevant signal once the op actually runs.
  def handle_info({:mailbox_ops_pending, _run_id}, socket), do: {:noreply, socket}

  # `Valea.Mail.Engine.status/0`'s map is atom-keyed; the channel payload
  # must be string keys (mirrors `Valea.Api.Mail.mail_status`'s identical
  # top-level stringify for the RPC surface).
  defp stringify(status), do: Map.new(status, fn {k, v} -> {to_string(k), v} end)
end
