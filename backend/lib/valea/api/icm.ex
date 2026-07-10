defmodule Valea.Api.ICM do
  @moduledoc """
  Data-layer-less Ash resource exposing the workspace icm/ tree over RPC.

  Wraps `Valea.ICM`; converts its atom-keyed nodes into string-keyed maps
  and translates the `:no_workspace` reason into the frontend's
  `"workspace_not_open"` error string.
  """
  use Ash.Resource, domain: Valea.Api, extensions: [AshTypescript.Resource]

  typescript do
    type_name("ICM")
  end

  alias Valea.Api.Error

  actions do
    action :tree, :map do
      run fn _input, _ctx ->
        case Valea.ICM.tree() do
          {:ok, nodes} -> {:ok, %{"nodes" => stringify(nodes)}}
          {:error, :no_workspace} -> {:error, Error.new("workspace_not_open")}
          {:error, reason} -> {:error, Error.new(to_string(reason))}
        end
      end
    end

    action :page, :map do
      argument :path, :string, allow_nil?: false

      run fn input, _ctx ->
        case Valea.ICM.page(input.arguments.path) do
          {:ok, page} -> {:ok, Map.new(page, fn {k, v} -> {to_string(k), v} end)}
          {:error, :no_workspace} -> {:error, Error.new("workspace_not_open")}
          {:error, reason} -> {:error, Error.new(to_string(reason))}
        end
      end
    end
  end

  defp stringify(nodes) when is_list(nodes), do: Enum.map(nodes, &stringify/1)

  defp stringify(%{} = node) do
    Map.new(node, fn
      {:children, children} -> {"children", stringify(children)}
      {:type, t} -> {"type", to_string(t)}
      {k, v} -> {to_string(k), v}
    end)
  end
end
