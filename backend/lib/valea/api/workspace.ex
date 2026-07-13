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

  `create_workspace_at_path`/`open_workspace_at_path` are the OLD,
  path-based actions (formerly `create_workspace`/`open_workspace`) —
  renamed here so the id-based actions above could take over their wire
  names. Kept defined (compiling) but deliberately NOT listed in
  `Valea.Api`'s `typescript_rpc` block, so they're unreachable from the
  frontend: nothing calls them anymore (`Valea.Workspace.Adopt` scaffolds
  and opens legacy workspaces directly through `Manager`/`Scaffold`, never
  through this resource). Retained rather than deleted so Phase 10/11's
  removal (alongside `Adopt` itself and the onboarding rework) is a clean,
  isolated diff. `inspect_workspace`/`inspect_path`/`adopt_workspace` stay
  untouched and RPC-exposed — onboarding still needs them until Phase 10.
  """
  use Ash.Resource, domain: Valea.Api, extensions: [AshTypescript.Resource]

  typescript do
    type_name("Workspace")
  end

  alias Valea.Api.Error
  alias Valea.App.Config
  alias Valea.Workspace.Adopt
  alias Valea.Workspace.Manager
  alias Valea.Workspace.Scaffold

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

    # -- LEGACY path-based surface — see moduledoc --------------------------

    action :create_workspace_at_path, :map do
      argument :parent_dir, :string, allow_nil?: false
      argument :name, :string, allow_nil?: false

      run fn input, _ctx ->
        case Manager.create(input.arguments.parent_dir, input.arguments.name) do
          {:ok, info} -> {:ok, opened_payload(info)}
          {:error, reason} -> {:error, error_message(reason)}
        end
      end
    end

    action :open_workspace_at_path, :map do
      argument :path, :string, allow_nil?: false

      run fn input, _ctx ->
        case Manager.open_path(input.arguments.path) do
          {:ok, info} -> {:ok, opened_payload(info)}
          {:error, reason} -> {:error, error_message(reason)}
        end
      end
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
  defp error_message(:target_is_source), do: Error.new("target_is_source")
  defp error_message(:cross_device), do: Error.new("cross_device")

  # A non-EXDEV rename failure (`Adopt.map_move_error/1`'s catch-all). The
  # underlying posix reason (:eacces, ...) is collapsed to the bare code
  # the frontend matches on — its message tells the user the source folder
  # is intact at its original location (Adopt removed the scaffolded
  # target and never touched the source). Without this clause the
  # fallthrough below would emit `inspect({:move_failed, reason})`, a wire
  # string no frontend case matches.
  defp error_message({:move_failed, _reason}), do: Error.new("move_failed")

  defp error_message(other), do: Error.new(inspect(other))
end
