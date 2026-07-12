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
  alias Valea.Workspace.Adopt
  alias Valea.Workspace.Manager
  alias Valea.Workspace.Scaffold

  actions do
    action :current, :map do
      run fn _input, _ctx ->
        case Manager.current() do
          {:ok, info} ->
            {:ok,
             %{
               "open" => true,
               "path" => info.path,
               "name" => info.name,
               "generation" => Manager.generation()
             }}

          {:error, :no_workspace} ->
            {:ok, %{"open" => false, "path" => nil, "name" => nil, "generation" => nil}}
        end
      end
    end

    action :create_workspace, :map do
      argument :parent_dir, :string, allow_nil?: false
      argument :name, :string, allow_nil?: false

      run fn input, _ctx ->
        case Manager.create(input.arguments.parent_dir, input.arguments.name) do
          {:ok, info} -> {:ok, opened_payload(info)}
          {:error, reason} -> {:error, error_message(reason)}
        end
      end
    end

    action :open_workspace, :map do
      argument :path, :string, allow_nil?: false

      run fn input, _ctx ->
        case Manager.open(input.arguments.path) do
          {:ok, info} -> {:ok, opened_payload(info)}
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

    # Classifies `path` for the open/create dialog's branch decision — see
    # `Valea.Workspace.Adopt.classify_path/1` moduledoc for the full
    # kind/rationale writeup, notably why a knowledge-shaped folder with no
    # (or an unparseable) `icm.yaml` classifies as "other", not "icm".
    # `name`/`description` come from the loaded manifest for kind "icm" and
    # are `nil` otherwise — deliberately unconstrained (no `constraints
    # fields:`) like `inspect_workspace` above, so no frontend call site
    # needs an explicit field-selection list for this action.
    action :inspect_path, :map do
      argument :path, :string, allow_nil?: false

      run fn input, _ctx ->
        case Adopt.classify_path(input.arguments.path) do
          {:workspace, nil} ->
            {:ok, %{"kind" => "workspace", "name" => nil, "description" => nil}}

          {:icm, manifest} ->
            {:ok,
             %{"kind" => "icm", "name" => manifest.name, "description" => manifest.description}}

          {:other, nil} ->
            {:ok, %{"kind" => "other", "name" => nil, "description" => nil}}
        end
      end
    end

    # Adopts an existing, non-workspace knowledge folder into a brand-new
    # workspace BY MOVE — see `Valea.Workspace.Adopt` moduledoc for the full
    # rejection list and the never-copy invariant. Returns the same
    # opened-workspace payload shape as `create_workspace`/`open_workspace`
    # above on success.
    action :adopt_workspace, :map do
      argument :parent_dir, :string, allow_nil?: false
      argument :name, :string, allow_nil?: false
      argument :icm_source_path, :string, allow_nil?: false

      run fn input, _ctx ->
        %{parent_dir: parent_dir, name: name, icm_source_path: icm_source_path} = input.arguments

        case Adopt.create_with_icm(parent_dir, name, icm_source_path) do
          {:ok, info} -> {:ok, opened_payload(info)}
          {:error, reason} -> {:error, error_message(reason)}
        end
      end
    end

    action :runtime_check, :map do
      constraints fields: [
                    ok: [type: :boolean, allow_nil?: false],
                    detail: [type: :string, allow_nil?: false]
                  ]

      run fn _input, _ctx ->
        cat = System.find_executable("cat") || "/bin/cat"

        with {:ok, handle} <-
               Valea.Agents.ProcessRuntime.start(
                 %{cmd: cat, args: [], env: %{}, cd: System.tmp_dir!()},
                 self()
               ),
             :ok <- Valea.Agents.ProcessRuntime.write(handle, "ping\n") do
          receive do
            {:runtime_output, "ping\n"} ->
              Valea.Agents.ProcessRuntime.stop(handle)
              {:ok, %{"ok" => true, "detail" => "spawn/echo/kill ok"}}
          after
            3_000 ->
              Valea.Agents.ProcessRuntime.stop(handle)
              {:ok, %{"ok" => false, "detail" => "no echo within 3s"}}
          end
        else
          {:error, reason} -> {:ok, %{"ok" => false, "detail" => reason}}
        end
      end
    end
  end

  defp opened_payload(info) do
    %{
      "open" => true,
      "path" => info.path,
      "name" => info.name,
      "generation" => Manager.generation()
    }
  end

  defp error_message(:not_a_workspace), do: Error.new("not_a_workspace")
  defp error_message(:target_not_empty), do: Error.new("target_not_empty")
  defp error_message(:workspace_changed), do: Error.new("workspace_changed")
  # `Valea.Workspace.Adopt.create_with_icm/3`'s rejection atoms (see its
  # moduledoc) — each already stringifies to the exact code the frontend
  # matches on, but listed explicitly (rather than falling through to the
  # generic `inspect/1` clause below) so a typo in either place is a
  # compile-time-visible pattern-match, not a silently wrong wire string.
  defp error_message(:source_not_found), do: Error.new("source_not_found")
  defp error_message(:source_is_workspace), do: Error.new("source_is_workspace")
  defp error_message(:source_in_workspace), do: Error.new("source_in_workspace")
  defp error_message(:source_is_open_workspace), do: Error.new("source_is_open_workspace")
  defp error_message(:cycle), do: Error.new("cycle")
  defp error_message(:cross_device), do: Error.new("cross_device")
  defp error_message(other), do: Error.new(inspect(other))
end
