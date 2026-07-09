defmodule ValeaWeb.RpcChannel do
  use Phoenix.Channel

  @impl true
  def join("ash_typescript_rpc:" <> _rest, _payload, socket), do: {:ok, socket}

  @impl true
  def handle_in("run", params, socket) do
    {:reply, {:ok, AshTypescript.Rpc.run_action(:valea, socket, params)}, socket}
  end

  def handle_in("validate", params, socket) do
    {:reply, {:ok, AshTypescript.Rpc.validate_action(:valea, socket, params)}, socket}
  end
end
