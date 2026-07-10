defmodule ValeaWeb.UserSocket do
  use Phoenix.Socket

  channel "ash_typescript_rpc:*", ValeaWeb.RpcChannel
  channel "workspace:events", ValeaWeb.WorkspaceEventsChannel
  channel "agent_session:*", ValeaWeb.AgentSessionChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) when is_binary(token) do
    if Plug.Crypto.secure_compare(token, ValeaWeb.ControlToken.expected()),
      do: {:ok, socket},
      else: :error
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(_socket), do: nil
end
