defmodule Valea.Api.Workspace do
  @moduledoc """
  Data-layer-less Ash resource exposing workspace lifecycle over RPC.

  Thin wrapper around `Valea.Workspace.Manager` / `Valea.Workspace.Scaffold`;
  it owns no logic of its own — it adapts their return shapes into the
  string-keyed maps the frontend consumes.
  """
  use Ash.Resource, domain: Valea.Api, extensions: [AshTypescript.Resource]

  typescript do
    type_name("Workspace")
  end

  alias Valea.Api.Error
  alias Valea.Workspace.Manager
  alias Valea.Workspace.Scaffold

  actions do
    action :current, :map do
      run fn _input, _ctx ->
        case Manager.current() do
          {:ok, info} -> {:ok, %{"open" => true, "path" => info.path, "name" => info.name}}
          {:error, :no_workspace} -> {:ok, %{"open" => false, "path" => nil, "name" => nil}}
        end
      end
    end

    action :create_workspace, :map do
      argument :parent_dir, :string, allow_nil?: false
      argument :name, :string, allow_nil?: false

      run fn input, _ctx ->
        case Manager.create(input.arguments.parent_dir, input.arguments.name) do
          {:ok, info} -> {:ok, %{"open" => true, "path" => info.path, "name" => info.name}}
          {:error, reason} -> {:error, error_message(reason)}
        end
      end
    end

    action :open_workspace, :map do
      argument :path, :string, allow_nil?: false

      run fn input, _ctx ->
        case Manager.open(input.arguments.path) do
          {:ok, info} -> {:ok, %{"open" => true, "path" => info.path, "name" => info.name}}
          {:error, reason} -> {:error, error_message(reason)}
        end
      end
    end

    action :close_workspace, :map do
      run fn _input, _ctx ->
        :ok = Manager.close()
        {:ok, %{"open" => false}}
      end
    end

    action :recent, {:array, :map} do
      run fn _input, _ctx -> {:ok, Valea.App.Config.recent()} end
    end

    action :inspect_workspace, :map do
      argument :path, :string, allow_nil?: false

      run fn input, _ctx ->
        summary = Scaffold.inspect_summary(input.arguments.path)
        {:ok, Map.new(summary, fn {k, v} -> {to_string(k), v} end)}
      end
    end
  end

  defp error_message(:not_a_workspace), do: Error.new("not_a_workspace")
  defp error_message(:target_not_empty), do: Error.new("target_not_empty")
  defp error_message(other), do: Error.new(inspect(other))
end
