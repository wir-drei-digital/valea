defmodule ValeaWeb.WorkspaceEventsChannel do
  use Phoenix.Channel

  @impl true
  def join("workspace:events", _payload, socket) do
    Phoenix.PubSub.subscribe(Valea.PubSub, "workspace")
    Phoenix.PubSub.subscribe(Valea.PubSub, "icm")
    Phoenix.PubSub.subscribe(Valea.PubSub, "queue")
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

  def handle_info({:queue_changed}, socket) do
    push(socket, "queue_changed", %{})
    {:noreply, socket}
  end
end
