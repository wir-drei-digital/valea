defmodule Valea.Api.Workspace do
  @moduledoc """
  Data-layer-less Ash resource exposing workspace lifecycle over RPC.

  Thin wrapper around `Valea.Workspace.Manager` / `Valea.Workspace.Scaffold`;
  it owns no logic of its own — it adapts their return shapes into the
  string-keyed maps the frontend consumes.

  ## C9 id-based surface (Phase 2)

  `current`/`create_workspace`/`open_workspace`/`recent`/
  `workspace_switch_preflight` are the id-based lifecycle (spec §C9): every
  payload carries `id`, never `path` — no caller supplies or receives a
  filesystem path (`opened_payload/1`, `recent_payload/1`).

  Phase 11 deleted the OLD, path-based surface this moduledoc used to
  describe: `create_workspace_at_path`/`open_workspace_at_path` (formerly
  `create_workspace`/`open_workspace`, unreachable from the frontend since
  Task 10.3's onboarding rework) and `inspect_workspace`/`inspect_path`/
  `adopt_workspace` (the open/create dialog's classify-and-adopt-by-move
  flow, superseded by the by-reference mount onboarding — see
  `Valea.Mounts`/`Valea.Api.Icms`). `Valea.Workspace.Adopt`, the module
  those three backed, is deleted alongside them.

  `Valea.Workspace.Manager.create/2`/`open_path/1` (the legacy, path-based
  Manager entry points those actions used to call into) are NOT deleted
  yet — a large share of the backend test suite still scaffolds its
  fixture workspaces through them pending Task 11.3's v5 flip. See that
  task's punch list.
  """
  use Ash.Resource, domain: Valea.Api, extensions: [AshTypescript.Resource]

  typescript do
    type_name("Workspace")
  end

  alias Valea.Api.Error
  alias Valea.App.Config
  alias Valea.Workspace.Manager

  actions do
    action :current, :map do
      run fn _input, _ctx ->
        case Manager.current() do
          {:ok, info} ->
            {:ok, opened_payload(info)}

          {:error, :no_workspace} ->
            {:ok, %{"open" => false, "id" => nil, "name" => nil, "generation" => nil}}
        end
      end
    end

    action :create_workspace, :map do
      argument :name, :string, allow_nil?: false

      run fn input, _ctx ->
        case Manager.create(input.arguments.name) do
          {:ok, info} -> {:ok, opened_payload(info)}
          {:error, reason} -> {:error, error_message(reason)}
        end
      end
    end

    action :open_workspace, :map do
      argument :id, :string, allow_nil?: false
      # Optional, mirroring `Valea.Api.ICM`'s `save_page` `generation`
      # (`icm.ex`'s moduledoc/comment) — `nil` (onboarding's first-ever
      # open, no current workspace to guard) skips the check entirely; once
      # present (an already-open workspace initiating a switch, e.g. the
      # sidebar switcher), a stale generation is rejected BEFORE the switch
      # via `check_generation_if_present/1`, guarding against a race where
      # another window already switched workspaces out from under this call.
      argument :generation, :integer, allow_nil?: true, default: nil

      run fn input, _ctx ->
        generation = Map.get(input.arguments, :generation)

        with :ok <- check_generation_if_present(generation),
             {:ok, info} <- Manager.open(input.arguments.id) do
          {:ok, opened_payload(info)}
        else
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
      run fn _input, _ctx ->
        {:ok, Enum.map(Config.recent(), &recent_payload/1)}
      end
    end

    # Read-only preflight for a workspace switch (Task 2.4's
    # `Manager.switch_preflight/1`) — reports the CURRENTLY open workspace's
    # live agent sessions a switch to `id` would stop, so the UI can confirm
    # before switching. A self-switch (`id` == the currently open
    # workspace's own id) is a graceful no-op here: nothing would actually
    # be torn down, so it always reports an empty `live_sessions` rather
    # than the current workspace's own (irrelevant) live sessions or an
    # error.
    action :workspace_switch_preflight, :map do
      argument :id, :string, allow_nil?: false

      run fn input, _ctx ->
        id = input.arguments.id

        if self_switch?(id) do
          {:ok, %{"target_id" => id, "live_sessions" => []}}
        else
          case Manager.switch_preflight(id) do
            {:ok, %{live_sessions: sessions, target_id: target_id}} ->
              {:ok,
               %{
                 "target_id" => target_id,
                 "live_sessions" => Enum.map(sessions, &session_payload/1)
               }}

            {:error, reason} ->
              {:error, error_message(reason)}
          end
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

  # id-based (C9) — never carries `path`.
  defp opened_payload(info) do
    %{
      "open" => true,
      "id" => info.id,
      "name" => info.name,
      "generation" => Manager.generation()
    }
  end

  # id-based (C9) — strips `path`/`slug` off `Valea.App.Config.recent/0`'s
  # registry entries, keeping only what the UI needs to list and pick a
  # workspace to open by id.
  defp recent_payload(entry) do
    %{
      "id" => entry["id"],
      "name" => entry["name"],
      "last_opened_at" => entry["last_opened_at"]
    }
  end

  defp session_payload(%{id: id, title: title, icm_mount: icm_mount}) do
    %{"id" => id, "title" => title, "icm_mount" => icm_mount}
  end

  defp self_switch?(id) do
    case Manager.current() do
      {:ok, %{id: current_id}} -> current_id == id
      {:error, :no_workspace} -> false
    end
  end

  defp check_generation_if_present(nil), do: :ok
  defp check_generation_if_present(generation), do: Manager.check_generation(generation)

  defp error_message(:not_a_workspace), do: Error.new("not_a_workspace")
  defp error_message(:target_not_empty), do: Error.new("target_not_empty")
  defp error_message(:workspace_changed), do: Error.new("workspace_changed")
  defp error_message(:unknown_workspace), do: Error.new("unknown_workspace")
  defp error_message(other), do: Error.new(inspect(other))
end
