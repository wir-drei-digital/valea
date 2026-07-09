defmodule ValeaWeb.UserSocket do
  use Phoenix.Socket

  channel "ash_typescript_rpc:*", ValeaWeb.RpcChannel
  channel "workspace:events", ValeaWeb.WorkspaceEventsChannel

  @impl true
  def connect(_params, socket, _connect_info), do: {:ok, socket}

  @impl true
  def id(_socket), do: nil
end
