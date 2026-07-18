defmodule Valea.Calendar.Supervisor do
  @moduledoc """
  One `Valea.Calendar.Engine` child per VALID source in
  `config/calendar.yaml` (calendar spec F, §Sync engine) — the
  `Valea.Mail.Supervisor` shape, PLUS the per-slug lifecycle serializer:
  setup, set-url, remove, purge, and config rehash all execute through
  this ONE process (`lifecycle/1`), so no two lifecycle mutations for a
  slug can interleave — a purge re-checks the slug is unconfigured while
  holding that serialization, and a concurrent setup for the same slug
  queues behind the purge rather than racing the deletion.

  Because an OTP `Supervisor` callback module cannot serve custom calls,
  this module is a `GenServer` that owns a linked, anonymous
  `Supervisor` for the engine children: the GenServer IS the serializer;
  the inner supervisor restarts crashed engines; killing either tears
  down both (the inner supervisor shuts its children down on its parent's
  exit), so `Valea.Workspace.Runtime` sees one child with mail-supervisor
  semantics. `lifecycle/1` is re-entrant — a fun already running inside
  the supervisor process calls straight through, so a composed operation
  (config write + `rehash/0`) can run as ONE serialized unit without
  deadlocking; the root/sup context those re-entrant helpers need lives
  in the process dictionary, put there by `init/1`, because `lifecycle/1`
  is pinned to zero-arity funs.

  A source `Valea.Calendar.Settings.load/1` drops as invalid gets NO
  engine at all — its problem is surfaced by the API layer merging the
  `invalid:` map, not by a degraded engine (the mail posture).
  """

  use GenServer

  alias Valea.Calendar.Engine
  alias Valea.Calendar.Settings
  alias Valea.Calendar.Store
  alias Valea.Workspace.Manager

  @call_timeout 120_000
  @ctx_key :valea_calendar_supervisor_ctx

  def start_link(cfg), do: GenServer.start_link(__MODULE__, cfg, name: __MODULE__)

  @doc """
  Serializes `fun` through the one supervisor process (generous timeout).
  Re-entrant: called from INSIDE a lifecycle fun it runs directly instead
  of deadlocking on a self-call.
  """
  @spec lifecycle((-> any())) :: any()
  def lifecycle(fun) when is_function(fun, 0) do
    if self() == Process.whereis(__MODULE__) do
      fun.()
    else
      GenServer.call(__MODULE__, {:lifecycle, fun}, @call_timeout)
    end
  end

  @doc """
  Re-reads `config/calendar.yaml` and starts/stops/restarts engines to
  match (inside `lifecycle/1`): new valid slugs get self-activating
  engines (no `workspace_opened` broadcast is coming mid-session),
  removed/invalid slugs are stopped, changed configs are restarted,
  unchanged ones are left running untouched (their RAM-only URL closure
  survives a sibling's setup/removal).
  """
  @spec rehash() :: :ok
  def rehash do
    lifecycle(fn -> do_rehash(ctx()) end)
  end

  @doc """
  Deletes `sources/calendar/<slug>` and its index rows — inside
  `lifecycle/1`, in the pinned order: refuse while the slug is still
  configured (remove first — the rehash stops its engine), await/stop any
  engine still running (terminating it awaits its LINKED in-flight pass
  task), re-check the slug is still unconfigured, then delete the
  slug-validated + `Valea.Paths.resolve_real/2`-contained directory and
  `Store.clear_source!/1`. A degraded-but-polling engine can never
  resurrect a purged mirror.
  """
  @spec purge!(String.t()) :: :ok | {:error, :still_configured | term()}
  def purge!(slug) when is_binary(slug) do
    lifecycle(fn -> do_purge(ctx(), slug) end)
  end

  # -- GenServer --------------------------------------------------------------

  @impl true
  def init(%{root: root, generation: generation}) do
    children =
      for {slug, config} <- valid_sources(root) do
        engine_spec(root, generation, slug, config, false)
      end

    {:ok, sup} = Supervisor.start_link(children, strategy: :one_for_one)
    Process.put(@ctx_key, %{root: root, sup: sup})

    {:ok, %{root: root, generation: generation, sup: sup}}
  end

  @impl true
  def handle_call({:lifecycle, fun}, _from, state) do
    {:reply, run_lifecycle(fun), state}
  end

  # A raising lifecycle fun must not fell the supervisor (and with it every
  # engine's RAM-only URL closure); degrade to a typed error.
  defp run_lifecycle(fun) do
    fun.()
  rescue
    error -> {:error, {:lifecycle_failed, Exception.message(error)}}
  catch
    :exit, _reason -> {:error, {:lifecycle_failed, "exit"}}
  end

  defp ctx, do: Process.get(@ctx_key)

  # -- rehash -----------------------------------------------------------------

  defp do_rehash(%{root: root, sup: sup}) do
    desired = valid_sources(root)
    desired_slugs = desired |> Enum.map(&elem(&1, 0)) |> MapSet.new()
    running = running_children(sup)
    running_slugs = running |> Map.keys() |> MapSet.new()

    Enum.each(running_slugs, fn slug ->
      unless MapSet.member?(desired_slugs, slug), do: stop_child(sup, slug)
    end)

    generation = Manager.generation()

    Enum.each(desired, fn {slug, config} ->
      cond do
        not Map.has_key?(running, slug) ->
          start_child(sup, root, generation, slug, config)

        running[slug] != config ->
          stop_child(sup, slug)
          start_child(sup, root, generation, slug, config)

        true ->
          :ok
      end
    end)

    :ok
  end

  # -- purge ------------------------------------------------------------------

  defp do_purge(%{root: root, sup: sup}, slug) do
    with :ok <- validate_purge_slug(slug),
         :ok <- refuse_configured(root, slug),
         # Terminating the engine child awaits it (and, via the link, any
         # in-flight pass task) — nothing can write into the tree after.
         :ok <- stop_child(sup, slug),
         # Re-check while still holding the lifecycle serialization.
         :ok <- refuse_configured(root, slug),
         :ok <- delete_source_dir(root, slug) do
      Store.clear_source!(slug)
      :ok
    end
  end

  defp validate_purge_slug(slug) do
    if Settings.valid_slug?(slug), do: :ok, else: {:error, :invalid_slug}
  end

  defp refuse_configured(root, slug) do
    case Settings.load(root) do
      {:ok, settings} ->
        if Map.has_key?(settings.sources, slug) or Map.has_key?(settings.invalid, slug) do
          {:error, :still_configured}
        else
          :ok
        end

      {:error, :absent} ->
        :ok

      # A whole-file-invalid config can't prove the slug is unconfigured —
      # refuse rather than delete under uncertainty.
      {:error, {:invalid, _reason} = invalid} ->
        {:error, invalid}
    end
  end

  defp delete_source_dir(root, slug) do
    rel = Path.join(["sources", "calendar", slug])

    case Valea.Paths.resolve_real(rel, root) do
      {:ok, abs} ->
        File.rm_rf!(abs)
        :ok

      {:error, _outside_or_invalid} ->
        {:error, :invalid_path}
    end
  end

  # -- children ---------------------------------------------------------------

  defp valid_sources(root) do
    case Settings.load(root) do
      {:ok, %{sources: sources}} -> sources |> Map.to_list() |> Enum.sort_by(&elem(&1, 0))
      _not_ok -> []
    end
  end

  # `%{slug => config}` for every currently-running child, read off each
  # Engine's own state — a rehash always diffs against what the engine is
  # actually holding (the mail pattern).
  defp running_children(sup) do
    sup
    |> Supervisor.which_children()
    |> Enum.filter(fn {_id, pid, _type, _mods} -> is_pid(pid) end)
    |> Map.new(fn {id, pid, _type, _mods} -> {id, GenServer.call(pid, :current_config)} end)
  end

  defp stop_child(sup, slug) do
    case Supervisor.terminate_child(sup, slug) do
      :ok ->
        Supervisor.delete_child(sup, slug)
        :ok

      {:error, :not_found} ->
        :ok
    end
  end

  defp start_child(sup, root, generation, slug, config) do
    Supervisor.start_child(sup, engine_spec(root, generation, slug, config, true))
  end

  defp engine_spec(root, generation, slug, config, activate) do
    args = %{root: root, generation: generation, source: slug, config: config, activate: activate}
    Supervisor.child_spec({Engine, args}, id: slug)
  end
end
