defmodule Valea.ICM.Watcher do
  @moduledoc """
  Watches `{workspace}/mounts`, `{workspace}/queue`, `{workspace}/config`,
  and every ENABLED external (by-reference) mount's real root, broadcasting
  debounced events on their own PubSub topics:

    * any change under mounts/, or under an enabled external mount's root
      -> `{:icm_changed}` on `"icm"` (consumers refetch the grouped ICM
      tree, which spans `mounts/<name>/` AND every external root)
    * a change that may affect the MOUNT SET itself — a top-level
      `mounts/<name>` directory added or removed, a `mounts/<name>/icm.yaml`
      manifest touched, an external mount root's OWN `icm.yaml` touched, or
      `config/workspace.yaml` itself touched (the source of truth for
      enabled/disabled state AND for external-mount declarations) — ALSO
      broadcasts `{:mounts_changed}` on `"mounts"` (discovery, the registry
      union, and MOUNTS.md may need to recompute)
    * a change under queue/ -> `{:queue_changed}` on `"queue"`

  Each tree gets its own debounce timer so a burst of activity in one does
  not delay or coalesce with the other. `mounts_changed` shares the SAME
  debounce timer as every other discovery-relevant source above (`mounts/`,
  `config/workspace.yaml`, and each external root) rather than getting a
  separate one per source: every event seen during the window is classified
  as it arrives, and on flush the handler emits `icm_changed`
  unconditionally plus `mounts_changed` only if something discovery-relevant
  was seen — so a manifest touch inside a content burst still gets both
  events, exactly once, together. Events carry no payload by design —
  consumers refetch (cheap to rebuild, and the fs events themselves are
  noisy). Only `config/workspace.yaml` itself is discovery-relevant among
  files under `config/` — a change to `config/mail.yaml` or
  `config/calendar.yaml` is unrelated to the mount set and produces no
  event at all.

  ## Regeneration on discovery (closing the hand-edit gap)

  `Valea.Api.Mounts`'s RPC mutations (`set_mount_enabled`, `create_mount`)
  already regenerate `MOUNTS.md` and the managed `.claude/settings.json`
  after writing. A change that reaches the mount set WITHOUT going through
  that RPC layer — a hand-edited `config/workspace.yaml`, a manually
  dropped-in `mounts/<name>/icm.yaml`, an external mount's manifest edited
  in place — previously only broadcast `{:mounts_changed}` with nothing
  actually regenerating those derived files, leaving them stale until the
  next RPC mutation happened to touch them. This module closes that gap:
  on its OWN discovery flush (i.e. when THIS watcher, not some other
  PubSub publisher, detected a discovery-relevant filesystem change),
  after broadcasting it also calls `Valea.Mounts.MountsMd.regenerate/1`
  and `Valea.Agents.ClaudeSettings.write!/1` for the workspace. Both calls
  are rescued and logged — regeneration must never crash the watcher.

  Neither regenerated file can retrigger this watcher: `MOUNTS.md` lives at
  the workspace ROOT (not one of the watched directories) and
  `.claude/settings.json` lives under `.claude/` (also not watched); the
  regeneration itself never writes into `mounts/`, `queue/`, `config/`, or
  any external root. See `watcher_test.exs` for the loop-safety tests.

  ## External mount roots are dynamic

  Which external roots are enabled can change at runtime — a
  `set_mount_enabled`/`create_mount` RPC mutation, or a hand-edited
  `config/workspace.yaml` this watcher itself just noticed. This process
  subscribes to the `"mounts"` PubSub topic (the SAME topic both the RPC
  layer and this watcher's own discovery flush broadcast on) so it hears
  about every source of change, and recomputes the watched directory set
  (`mounts/`, `queue/`, `config/`, plus every currently enabled external
  root) after: (a) its own discovery flush, and (b) a debounced,
  coalesced window after `{:mounts_changed}` arrives via PubSub. Recompute
  is a plain set comparison against the CURRENTLY watched external roots —
  if nothing changed, the underlying `FileSystem` process is left alone;
  only a real difference triggers a stop-and-restart with the new dir
  list. This is what makes it SAFE for this process to receive its own
  broadcast back (Phoenix.PubSub delivers to every subscriber of a topic,
  including the publisher): by the time the self-sent message is handled,
  the recompute already ran synchronously inside the flush that produced
  it, so the redundant recompute finds no diff and never restarts
  anything — no infinite loop, just one harmless extra comparison. A
  declared external mount whose root does not currently exist on disk
  (unmounted drive, moved folder, ...) is silently skipped rather than
  crashing the watcher — `Valea.Mounts.enabled/1` already excludes a
  mount whose root does not resolve to a real folder (it comes back
  degraded), but the check is repeated here too as a defense against the
  narrow TOCTOU window between that computation and this one.

  FSEvents (the macOS backend — and watcher backends generally) only
  reports changes under a path that already existed when the watch stream
  was created; a directory created afterward is invisible to it even once
  populated. `mounts/`, `queue/`, and `config/` are not guaranteed to exist
  yet at workspace-open time, so `init/1` creates all three up front rather
  than assuming the caller already has. External mount roots are never
  created by this module — they live outside the workspace and are the
  user's own folders.

  Started under `Valea.Workspace.Runtime` — it lives and dies with the open
  workspace, same as the audit writer and agent session supervisor.
  """
  use GenServer

  require Logger

  alias Valea.Agents.ClaudeSettings
  alias Valea.Mounts
  alias Valea.Mounts.MountsMd

  @debounce_ms 200

  def start_link(root), do: GenServer.start_link(__MODULE__, root, name: __MODULE__)

  @impl true
  def init(root) do
    mounts_path = Path.join(root, "mounts")
    queue_path = Path.join(root, "queue")
    config_path = Path.join(root, "config")

    File.mkdir_p!(mounts_path)
    File.mkdir_p!(queue_path)
    File.mkdir_p!(config_path)

    :ok = Phoenix.PubSub.subscribe(Valea.PubSub, "mounts")

    external_roots = compute_external_roots(root)

    {:ok, watcher} =
      FileSystem.start_link(dirs: fixed_dirs(root) ++ Map.keys(external_roots))

    FileSystem.subscribe(watcher)

    # FSEvents (the macOS backend) reports paths through their PHYSICAL
    # (symlink-resolved) form — e.g. under `/private/var/...` even when the
    # directory was opened via a `/var/...` alias, as it commonly is under
    # the system temp dir. Resolving our reference paths the same way here,
    # once, keeps the prefix comparison in `under?/2` correct regardless of
    # which alias the caller passed in. External-mount roots are already
    # realpath-resolved by `Valea.Mounts.External`, so `canonical/1` there
    # is idempotent — kept for defense-in-depth/uniformity, not correction.
    {:ok,
     %{
       watcher: watcher,
       root: root,
       mounts_path: canonical(mounts_path),
       queue_path: canonical(queue_path),
       config_path: canonical(config_path),
       external_roots: external_roots,
       # `mounts_timer`/`mounts_discovery_pending` now cover every
       # discovery-relevant source (mounts/, config/workspace.yaml, and
       # each external root's icm.yaml) — see moduledoc.
       mounts_timer: nil,
       mounts_discovery_pending: false,
       queue_timer: nil,
       recompute_timer: nil
     }}
  end

  @impl true
  def handle_info({:file_event, _pid, {path, _events}}, state) do
    case classify_path(path, state) do
      :queue -> {:noreply, arm(:queue_timer, :flush_queue, state)}
      :mounts -> {:noreply, note_mounts_event(path, state)}
      :config -> {:noreply, note_config_event(path, state)}
      {:external, root} -> {:noreply, note_external_event(path, root, state)}
      :ignore -> {:noreply, state}
    end
  end

  def handle_info({:file_event, _pid, :stop}, state), do: {:noreply, state}

  # A `{:mounts_changed}` broadcast from ANY source (an RPC mutation, or
  # this watcher's own discovery flush looping back to itself via its
  # subscription above) may mean the enabled external-root set changed —
  # debounce/coalesce a burst of these into a single recompute rather than
  # restarting `FileSystem` once per message.
  def handle_info({:mounts_changed}, state) do
    {:noreply, arm(:recompute_timer, :flush_recompute, state)}
  end

  def handle_info(:flush_recompute, state) do
    {:noreply, recompute_dirs(%{state | recompute_timer: nil})}
  end

  def handle_info(:flush_mounts, state) do
    Phoenix.PubSub.broadcast(Valea.PubSub, "icm", {:icm_changed})

    state =
      if state.mounts_discovery_pending do
        # Regenerate BEFORE broadcasting — mirrors `Valea.Api.Mounts`'s own
        # ordering (regenerate, then broadcast), so a subscriber that reacts
        # to `{:mounts_changed}` by reading MOUNTS.md/settings.json off disk
        # never observes stale content.
        regenerate_workspace_metadata(state.root)
        Phoenix.PubSub.broadcast(Valea.PubSub, "mounts", {:mounts_changed})
        recompute_dirs(state)
      else
        state
      end

    {:noreply, %{state | mounts_timer: nil, mounts_discovery_pending: false}}
  end

  def handle_info(:flush_queue, state) do
    Phoenix.PubSub.broadcast(Valea.PubSub, "queue", {:queue_changed})
    {:noreply, %{state | queue_timer: nil}}
  end

  # -- classification --------------------------------------------------

  defp classify_path(path, state) do
    cond do
      under?(path, state.queue_path) -> :queue
      under?(path, state.mounts_path) -> :mounts
      under?(path, state.config_path) -> :config
      true -> classify_external(path, state.external_roots)
    end
  end

  defp classify_external(path, external_roots) do
    external_roots
    |> Map.keys()
    |> Enum.filter(&under?(path, &1))
    # Nested external roots are pathological but not impossible — the
    # most-specific (longest) root owns the path, mirroring
    # `Valea.Mounts.mount_for/2`'s own tie-break.
    |> Enum.max_by(&byte_size/1, fn -> nil end)
    |> case do
      nil -> :ignore
      root -> {:external, root}
    end
  end

  # A bare touch on `mounts_path` itself (no sub-path — e.g. the one-time
  # directory-creation event from `init/1`'s own `mkdir_p!`, or a parent
  # mtime bump FSEvents reports alongside a deeper change) names no page or
  # mount and is a pure no-op: nothing to refetch, nothing to reclassify.
  # Any deeper change under mounts/ still lands its own event with its own
  # non-empty segment list, so this never drops real signal.
  defp note_mounts_event(path, state) do
    case relative_segments(path, state.mounts_path) do
      [] ->
        state

      segments ->
        state = arm(:mounts_timer, :flush_mounts, state)

        if discovery_relevant?(segments) do
          %{state | mounts_discovery_pending: true}
        else
          state
        end
    end
  end

  # A change to the mount SET, not just a mount's content: either a
  # top-level `mounts/<name>` entry itself (dir added/removed) or its
  # `icm.yaml` manifest (name/description, and the file whose mere
  # presence marks a mount as non-degraded). Anything deeper — a page or
  # folder inside the mount — is content-only.
  defp discovery_relevant?([_name]), do: true
  defp discovery_relevant?([_name, "icm.yaml"]), do: true
  defp discovery_relevant?(_other), do: false

  # Only `config/workspace.yaml` itself is discovery-relevant — it is the
  # source of truth for enabled/disabled state AND external-mount
  # declarations (see moduledoc). Any other file under `config/`
  # (`mail.yaml`, `calendar.yaml`, a bare touch on `config/` itself, a
  # `.tmp` sibling from an atomic write elsewhere) is unrelated to the
  # mount set and produces no event at all — unlike `mounts/`, content
  # under `config/` never feeds `icm_changed` either.
  defp note_config_event(path, state) do
    if path == Path.join(state.config_path, "workspace.yaml") do
      state = arm(:mounts_timer, :flush_mounts, state)
      %{state | mounts_discovery_pending: true}
    else
      state
    end
  end

  # Mirrors `note_mounts_event/2`'s embedded discovery rule for a single
  # external root: the mount's OWN `icm.yaml`, sitting directly at the
  # root (no intermediate `<name>` segment — the root itself already names
  # exactly one mount), is discovery-relevant; anything else under the
  # root is content-only. A bare touch on the root itself (`[]`) is a
  # no-op, same reasoning as `note_mounts_event/2`'s `[]` clause.
  defp note_external_event(path, root, state) do
    case relative_segments(path, root) do
      [] ->
        state

      ["icm.yaml"] ->
        state = arm(:mounts_timer, :flush_mounts, state)
        %{state | mounts_discovery_pending: true}

      _other ->
        arm(:mounts_timer, :flush_mounts, state)
    end
  end

  defp relative_segments(path, root) do
    cond do
      path == root ->
        []

      String.starts_with?(path, root <> "/") ->
        path |> String.replace_prefix(root <> "/", "") |> Path.split()

      true ->
        []
    end
  end

  # -- external root discovery / re-subscription -----------------------

  # One canonical absolute root path -> mount name, for every ENABLED,
  # non-degraded EXTERNAL mount (`rel_root: nil`) whose root currently
  # exists on disk. `Valea.Mounts.enabled/1` already excludes a mount
  # whose root does not resolve to a real folder (it degrades instead —
  # see `Valea.Mounts.External`), so `File.dir?/1` here is a defensive
  # re-check against the narrow window between that computation and this
  # one, not the primary guard.
  defp compute_external_roots(root) do
    root
    |> Mounts.enabled()
    |> Enum.filter(&(&1.rel_root == nil and File.dir?(&1.root)))
    |> Map.new(fn mount -> {canonical(mount.root), mount.name} end)
  end

  defp fixed_dirs(root),
    do: [Path.join(root, "mounts"), Path.join(root, "queue"), Path.join(root, "config")]

  # Recomputes the enabled-external-mount root set and restarts the
  # underlying `FileSystem` subscription ONLY when that set actually
  # changed — see moduledoc for why this short-circuit is what makes it
  # safe for this process to receive its own `{:mounts_changed}`
  # broadcast back.
  defp recompute_dirs(state) do
    new_external_roots = compute_external_roots(state.root)

    if MapSet.new(Map.keys(new_external_roots)) == MapSet.new(Map.keys(state.external_roots)) do
      state
    else
      restart_filesystem(state, new_external_roots)
    end
  end

  defp restart_filesystem(state, new_external_roots) do
    GenServer.stop(state.watcher)

    {:ok, watcher} =
      FileSystem.start_link(dirs: fixed_dirs(state.root) ++ Map.keys(new_external_roots))

    FileSystem.subscribe(watcher)

    %{state | watcher: watcher, external_roots: new_external_roots}
  end

  # -- regeneration on discovery (see moduledoc) ------------------------

  defp regenerate_workspace_metadata(root) do
    MountsMd.regenerate(root)
    ClaudeSettings.write!(root)
    :ok
  rescue
    error ->
      Logger.error(
        "Valea.ICM.Watcher: workspace metadata regeneration failed: " <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      :ok
  end

  # -- shared helpers ----------------------------------------------------

  defp arm(timer_key, flush_msg, state) do
    if state[timer_key], do: Process.cancel_timer(state[timer_key])
    Map.put(state, timer_key, Process.send_after(self(), flush_msg, @debounce_ms))
  end

  defp under?(path, dir), do: path == dir or String.starts_with?(path, dir <> "/")

  defp canonical(path) do
    case Valea.Paths.resolve_real(".", path) do
      {:ok, resolved} -> resolved
      {:error, _reason} -> path
    end
  end
end
