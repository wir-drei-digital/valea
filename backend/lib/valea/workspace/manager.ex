defmodule Valea.Workspace.Manager do
  @moduledoc """
  The open-workspace lifecycle. The app boots workspace-less; this GenServer
  opens/creates workspaces, starting the Repo against {workspace}/app.sqlite,
  running migrations, and starting `Valea.Workspace.Runtime` (the ICM file
  watcher, audit writer, and agent session supervisor). Loud, specific
  failures — a workspace is never presented as healthy when half-opened.

  Every successful open/create stamps a new `generation` — an integer that
  increments once per open and is `nil` while closed. RPC actions that touch
  workspace-bound state guard against acting on a stale generation via
  `check_generation/1`.
  """
  use GenServer

  alias Valea.App.Config
  alias Valea.Workspace.Scaffold

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Mints a workspace id, scaffolds a fresh, app-owned v5 hidden workspace
  named `name` under `Valea.App.Config.workspaces_dir/0`, opens it, and
  records it by id. The NEW, id-based create entry point.
  """
  def create(name), do: GenServer.call(__MODULE__, {:create, name}, 30_000)

  @doc """
  LEGACY (v4, path-based) scaffold at an explicit `parent_dir`. No
  production RPC action calls this anymore (Phase 11 deleted the last one,
  `create_workspace_at_path`, and `Valea.Workspace.Adopt`, its other
  caller) — it survives ONLY because a large share of the backend test
  suite still scaffolds its fixture workspaces through it (`Scaffold.create/2`'s
  starter-mount shape, not the bare v5 `icms: {}` one `create/1` produces).
  Deleting it is Task 11.3's job, once that suite moves off it.
  """
  def create(parent_dir, name),
    do: GenServer.call(__MODULE__, {:create, parent_dir, name}, 30_000)

  @doc "Opens a previously created/recorded workspace by id. The NEW, id-based open entry point."
  def open(id), do: GenServer.call(__MODULE__, {:open, id}, 30_000)

  @doc """
  LEGACY (path-based) open — see `create/2`'s doc: no production RPC action
  calls this anymore, it survives only for the test suite's legacy-scaffold
  fixtures (a workspace `create/2` just scaffolded has no registered id yet
  to `open/1` by).
  """
  def open_path(path), do: GenServer.call(__MODULE__, {:open_path, path}, 30_000)

  def close, do: GenServer.call(__MODULE__, :close)
  def current, do: GenServer.call(__MODULE__, :current)

  @doc "Current workspace generation, or nil when no workspace is open."
  def generation, do: GenServer.call(__MODULE__, :generation)

  @doc """
  Guard for RPC actions that must not act on a stale workspace: `:ok` when
  `g` matches the currently open workspace's generation, otherwise
  `{:error, :workspace_changed}` (including when no workspace is open).
  """
  def check_generation(g), do: GenServer.call(__MODULE__, {:check_generation, g})

  @doc """
  Read-only preflight for a workspace switch: validates `id` names a known
  (registered) workspace, then reports the CURRENTLY open workspace's live
  agent sessions — the ones a switch to `id` would stop — so the UI can
  confirm before switching. Performs no teardown; `open/1` remains the only
  thing that actually closes the current workspace. A plain function (not a
  GenServer call) since it only reads external state
  (`Valea.App.Config`/`Valea.Agents`), never `Manager`'s own process state.
  """
  @spec switch_preflight(String.t()) ::
          {:ok, %{live_sessions: [map()], target_id: String.t()}} | {:error, :unknown_workspace}
  def switch_preflight(id) do
    case Config.workspace_by_id(id) do
      nil ->
        {:error, :unknown_workspace}

      _entry ->
        {:ok, sessions} = Valea.Agents.list_sessions()

        live_sessions =
          sessions
          |> Enum.filter(& &1["live"])
          |> Enum.map(&%{id: &1["id"], title: &1["title"], icm_mount: &1["icm_mount"]})

        {:ok, %{live_sessions: live_sessions, target_id: id}}
    end
  end

  @impl true
  def init(_opts) do
    {:ok, %{workspace: nil, children: [], generation: 0}, {:continue, :auto_open}}
  end

  @impl true
  def handle_continue(:auto_open, state) do
    case Config.last_opened_id() do
      nil ->
        {:noreply, state}

      id ->
        case Config.workspace_by_id(id) do
          nil ->
            Config.clear_last_opened()
            {:noreply, state}

          %{"path" => path} ->
            case do_open(path, state) do
              {:ok, state} ->
                {:noreply, state}

              {:error, _reason, state} ->
                Config.clear_last_opened()
                {:noreply, state}
            end
        end
    end
  end

  @impl true
  def handle_call({:create, name}, _from, state) do
    id = Ecto.UUID.generate()
    slug = Scaffold.slugify(name)
    target = Path.join(Config.workspaces_dir(), "#{slug}-#{String.slice(id, 0, 8)}")

    with :ok <- Scaffold.create(target, name, id),
         {:ok, state} <- do_open(target, state) do
      {:reply, {:ok, state.workspace}, state}
    else
      # Scaffold.create failed before any close — reply with the untouched state.
      {:error, reason} -> {:reply, {:error, reason}, state}
      # do_open closed the previous workspace before failing — reply with the
      # closed state so `current/0` never reports a dead workspace as open.
      {:error, reason, closed_state} -> {:reply, {:error, reason}, closed_state}
    end
  end

  def handle_call({:create, parent_dir, name}, _from, state) do
    target = Path.join(parent_dir, name)

    with :ok <- Scaffold.create(target, name),
         {:ok, state} <- do_open(target, state) do
      {:reply, {:ok, state.workspace}, state}
    else
      # Scaffold.create failed before any close — reply with the untouched state.
      {:error, reason} -> {:reply, {:error, reason}, state}
      # do_open closed the previous workspace before failing — reply with the
      # closed state so `current/0` never reports a dead workspace as open.
      {:error, reason, closed_state} -> {:reply, {:error, reason}, closed_state}
    end
  end

  def handle_call({:open, id}, _from, state) do
    case Config.workspace_by_id(id) do
      nil -> {:reply, {:error, :unknown_workspace}, state}
      %{"path" => path} -> open_reply(path, state)
    end
  end

  def handle_call({:open_path, path}, _from, state), do: open_reply(path, state)

  def handle_call(:close, _from, state) do
    {:reply, :ok, do_close(state)}
  end

  def handle_call(:current, _from, %{workspace: nil} = state) do
    {:reply, {:error, :no_workspace}, state}
  end

  def handle_call(:current, _from, %{workspace: ws} = state) do
    {:reply, {:ok, ws}, state}
  end

  def handle_call(:generation, _from, %{workspace: nil} = state) do
    {:reply, nil, state}
  end

  def handle_call(:generation, _from, %{generation: gen} = state) do
    {:reply, gen, state}
  end

  # A closed workspace never matches any generation — there is nothing
  # current to stay in sync with.
  def handle_call({:check_generation, _g}, _from, %{workspace: nil} = state) do
    {:reply, {:error, :workspace_changed}, state}
  end

  def handle_call({:check_generation, g}, _from, %{generation: g} = state) do
    {:reply, :ok, state}
  end

  def handle_call({:check_generation, _stale}, _from, state) do
    {:reply, {:error, :workspace_changed}, state}
  end

  # Shared reply-building for both open entry points ({:open, id} and
  # {:open_path, path}) once each has resolved its own id/path down to a
  # concrete filesystem path.
  defp open_reply(path, state) do
    case do_open(path, state) do
      {:ok, state} -> {:reply, {:ok, state.workspace}, state}
      {:error, reason, closed_state} -> {:reply, {:error, reason}, closed_state}
    end
  end

  # On any failure, returns `{:error, reason, state}` where `state` reflects
  # whether the previous workspace was closed. A failure BEFORE close carries
  # the untouched state; a failure AFTER close carries the closed state, so a
  # failed switch never leaves the Manager reporting a dead workspace as open.
  defp do_open(path, state) do
    path = Path.expand(path)

    cond do
      not Scaffold.valid?(path) ->
        {:error, :not_a_workspace, state}

      true ->
        state = do_close(state)
        open_workspace(path, state)
    end
  end

  # Starts children one at a time, tracking every started pid. If any step
  # fails, everything already started so far is rolled back before the
  # error is returned, so a half-opened workspace is never left running
  # under a name a future open/create could mistake for success. The
  # workspace Runtime (file watcher, audit writer, session supervisor) is
  # one more step here, accumulating onto `started` after the repo.
  defp open_workspace(path, state) do
    case start_repo(path) do
      {:ok, repo_pid} -> open_workspace(path, state, [repo_pid])
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp open_workspace(path, state, started) do
    case migrate() do
      :ok -> open_workspace_runtime(path, state, started)
      {:error, reason} -> rollback_with(started, reason, state)
    end
  end

  # The generation for this open is tentative until the whole pipeline
  # succeeds — it is only committed into `state.generation` in
  # `finish_open/4`. A failure after this step still rolls the Runtime (and
  # whatever it wrote under this generation) back; the Manager's own
  # counter never advances for an open that didn't finish.
  defp open_workspace_runtime(path, state, started) do
    next_generation = state.generation + 1

    case start_runtime(path, next_generation) do
      {:ok, runtime_pid} ->
        started = started ++ [runtime_pid]
        finish_open(path, state, started, next_generation)

      {:error, reason} ->
        rollback_with(started, reason, state)
    end
  end

  # Finishes the open pipeline once the repo and Runtime are up: reads the
  # workspace's persistent identity off `config/workspace.yaml`, registers
  # it, and broadcasts the open. Runs after the repo/runtime are up (so it
  # acts on a fully mounted workspace) and before the open broadcast, so a
  # failure here rolls back exactly like a failed repo or runtime start —
  # never leaving a half-open workspace behind.
  #
  # Phase 11: this used to run `Valea.Workspace.Migration.migrate/1`
  # (versioned on-disk upgrades — new marker dirs, converted workflow
  # pages, managed Claude settings) before reading identity. That module is
  # deleted — every workspace this Manager can open is born at its final
  # on-disk shape by `Valea.Workspace.Scaffold` (v5 via `create/3`, or the
  # legacy v4 test fixture shape via `create/1,2`), so there is nothing left
  # to migrate. `read_workspace_meta/1` below reads `id`/`name` straight off
  # the config a scaffold already wrote, never regenerated on open.
  defp finish_open(path, state, started, next_generation) do
    %{id: id, name: name} = read_workspace_meta(path)
    info = %{path: path, name: name, id: id}

    # Reads the SAME persistent id back off `config/workspace.yaml` every
    # time this workspace is opened (see `read_workspace_meta/1`), so
    # `record_opened/1`'s id-keyed upsert reuses the one entry rather
    # than minting a fresh registration per open.
    Config.record_opened(%{
      id: id,
      name: name,
      slug: Scaffold.slugify(name),
      path: path
    })

    Phoenix.PubSub.broadcast(
      Valea.PubSub,
      "workspace",
      {:workspace_opened, info, next_generation}
    )

    {:ok, %{state | workspace: info, children: started, generation: next_generation}}
  end

  # The persistent workspace id and (v5+) display name, read straight off
  # `config/workspace.yaml` — the single source of truth both the id-based
  # (`create/1`/`open/1`) and legacy path-based (`create/2`, `open_path/1`)
  # flows converge on by the time this runs: `Migration.migrate/1` (just
  # above) guarantees `id:` is present for every workspace version this
  # Manager can open (v3+; a v5 scaffold writes it directly). `name` falls
  # back to the folder's own basename for legacy (pre-v5) workspaces, which
  # never stored a `name:` key — the folder itself IS the display name
  # there. Falls back to a freshly minted id only in the pathological case
  # of a missing/corrupt `id:` (should not happen for any workspace that
  # already passed `Scaffold.valid?/1` and a successful migration).
  defp read_workspace_meta(path) do
    doc =
      case YamlElixir.read_from_file(Path.join(path, "config/workspace.yaml")) do
        {:ok, %{} = doc} -> doc
        _ -> %{}
      end

    %{id: workspace_meta_id(doc), name: workspace_meta_name(doc, path)}
  end

  defp workspace_meta_id(%{"id" => id}) when is_binary(id) and id not in ["", "TEMPLATE"], do: id
  defp workspace_meta_id(_doc), do: Ecto.UUID.generate()

  defp workspace_meta_name(%{"name" => name}, _path) when is_binary(name) and name != "",
    do: name

  defp workspace_meta_name(_doc, path), do: Path.basename(path)

  defp rollback_with(started, reason, state) do
    rollback(started)
    {:error, reason, state}
  end

  defp rollback(pids) do
    Enum.each(pids, fn pid ->
      DynamicSupervisor.terminate_child(Valea.Workspace.DynamicSupervisor, pid)
    end)
  end

  defp do_close(%{workspace: nil} = state), do: state

  defp do_close(state) do
    Enum.each(state.children, fn pid ->
      DynamicSupervisor.terminate_child(Valea.Workspace.DynamicSupervisor, pid)
    end)

    Phoenix.PubSub.broadcast(Valea.PubSub, "workspace", {:workspace_closed})
    %{state | workspace: nil, children: []}
  end

  defp start_repo(workspace_path) do
    spec = {Valea.Repo, database: Path.join(workspace_path, "app.sqlite"), pool_size: 5}

    case DynamicSupervisor.start_child(Valea.Workspace.DynamicSupervisor, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, {:repo_start_failed, reason}}
    end
  end

  defp start_runtime(workspace_path, generation) do
    spec = {Valea.Workspace.Runtime, %{root: workspace_path, generation: generation}}

    case DynamicSupervisor.start_child(Valea.Workspace.DynamicSupervisor, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, {:runtime_start_failed, reason}}
    end
  end

  # Each workspace's app.sqlite is a fresh, independently-migrated database,
  # so `Ecto.Migrator.run/4` recompiles the migration files from disk on
  # every open (they're only ever pending once each, but for a *different*
  # database each time) — including repeat opens within the same running
  # app session (switching workspaces, tests). `ignore_module_conflict`
  # keeps that from spamming "redefining module" warnings; it's reset
  # immediately after, so it does not affect unrelated compilation.
  defp migrate do
    path =
      Application.get_env(:valea, :migrations_path) || Ecto.Migrator.migrations_path(Valea.Repo)

    previous_compiler_options = Code.compiler_options(ignore_module_conflict: true)

    try do
      Ecto.Migrator.run(Valea.Repo, path, :up, all: true)
      :ok
    rescue
      e -> {:error, {:migration_failed, Exception.message(e)}}
    after
      Code.compiler_options(previous_compiler_options)
    end
  end
end
