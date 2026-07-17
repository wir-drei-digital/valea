defmodule Valea.ICM.Watcher do
  @moduledoc """
  Watches `{workspace}/sources`, `{workspace}/config`, and every ENABLED,
  non-degraded ICM's real root (`Valea.Mounts.enabled/1` — since Task 3.2
  every mounted ICM is by-reference; there is no more embedded
  `mounts/<name>/` directory concept, so the historical FIXED `mounts/`
  watch is gone as of Task 8.1), broadcasting debounced events on their own
  PubSub topics:

    * any change under an enabled ICM root -> `{:icm_changed}` on `"icm"`
      (consumers refetch the ICM tree, which spans every enabled root)
    * a change that may affect the MOUNT SET itself — an ICM root's OWN
      `icm.yaml` manifest touched, or `config/workspace.yaml` itself
      touched (the source of truth for enabled/disabled state AND for
      every ICM's `path:` declaration) — ALSO broadcasts `{:mounts_changed}`
      on `"mounts"` and triggers a root-set recompute (see below)
    * a change under `sources/` produces no event at all — this tree is
      watched (see "why the fixed trees are created up front" below) but
      has no consumer that needs a live-refresh hint yet

  Each tree gets its own debounce timer so a burst of activity in one does
  not delay or coalesce with the other. `discovery_timer`/`discovery_pending`
  cover every discovery-relevant source above (each ICM root's own
  `icm.yaml`, and `config/workspace.yaml`) rather than a separate timer per
  source: every event seen during the window is classified as it arrives,
  and on flush the handler emits `icm_changed` unconditionally plus
  `mounts_changed` only if something discovery-relevant was seen — so a
  manifest touch inside a content burst still gets both events, exactly
  once, together. Events carry no payload by design — consumers refetch
  (cheap to rebuild, and the fs events themselves are noisy).

  ## No metadata regeneration here (as of Task 8.1)

  Earlier phases had this watcher close a "hand-edit gap" by calling
  `Valea.Mounts.MountsMd.regenerate/1` and
  `Valea.Agents.ClaudeSettings.write!/1` on its own discovery flush, so a
  config change that bypassed the RPC layer (`Valea.Api.Mounts`, deleted
  at Phase 11, which regenerated both on every mutation) didn't leave
  those derived files stale. This watcher no longer does either —
  it only broadcasts and recomputes its own watched set. `MountsMd`/
  `ClaudeSettings`/`Valea.Api.Mounts` are all deleted (Phase 11) — `MOUNTS.md`/managed
  `.claude/settings.json` are retired entirely; session permissioning is
  `Valea.Agents.SessionSettings` now.

  ## ICM roots are dynamic — two listeners, not one

  Which ICM roots are enabled can change at runtime (an RPC mutation, or a
  hand-edited `config/workspace.yaml` this watcher itself just noticed), so
  the underlying `FileSystem` subscription is SPLIT in two:

    * a FIXED listener over `sources/`, `config/` — started once in
      `init/1` and never restarted, so events under the workspace's own
      trees have ZERO loss window across ICM-root recomputes;
    * a DYNAMIC listener over the enabled ICM roots — restarted (or
      started/stopped) whenever the recomputed root set actually differs.
      It is `nil` while there is nothing to watch, rather than a
      `FileSystem` process with an empty dir list.

  Events from both pids flow through the same path-based classification —
  `handle_info` never dispatches on WHICH listener a `:file_event` came
  from, only on the path, so a straggler event from a just-stopped dynamic
  listener is classified against the already-updated root set (a removed
  root's stragglers simply classify to `:ignore`).

  Recompute runs INLINE, synchronously, inside the SAME discovery flush
  that found the change discovery-relevant in the first place. That fs-
  event-driven flush is the ONLY recompute trigger — there is no `"mounts"`
  PubSub subscription here to also recompute on an externally-broadcast
  `{:mounts_changed}` (a prior phase had one, tied to the regeneration this
  watcher no longer performs). Nothing is lost by dropping it: every
  mutation that broadcasts `{:mounts_changed}` (`Valea.Api.Icms`) always
  writes `config/workspace.yaml` first, which this watcher's own fixed
  listener already observes — at most, an RPC-driven
  change now takes one debounce window longer to be reflected in this
  process's OWN watched set than the (separately, immediately broadcast)
  `{:mounts_changed}` message subscribers hear.

  Recompute is a plain set comparison against the CURRENTLY watched ICM
  roots — if nothing changed, neither listener is touched; only a real
  difference stops and replaces the DYNAMIC listener. A declared ICM whose
  root does not currently exist on disk (unmounted drive, moved folder,
  ...) is silently skipped rather than crashing the watcher —
  `Valea.Mounts.enabled/1` already excludes a mount whose root does not
  resolve to a real folder (it comes back degraded), but the check is
  repeated here too as a defense against the narrow TOCTOU window between
  that computation and this one.

  One honest caveat remains: while the DYNAMIC listener is being swapped
  (stop old, start new), a change under an ICM root that survives the swap
  can land in the gap and go unreported. This loss window is inherent to
  re-subscription itself — a watcher backend cannot atomically change its
  dir set — and it is BOUNDED (the swap is a synchronous stop+start, no
  debounce in between) and LOW-STAKES: every event this module emits is a
  payload-less refetch hint, so a consumer that missed one sees correct
  data again on the very next change. The fixed tree — where the
  workspace's source of truth (`config/`) lives — is deliberately kept
  out of this window entirely.

  ## Why the fixed trees are created up front

  FSEvents (the macOS backend — and watcher backends generally) only
  reports changes under a path that already existed when the watch stream
  was created; a directory created afterward is invisible to it even once
  populated. `sources/` and `config/` are not guaranteed to
  exist yet at workspace-open time (a hand-rolled or partially-scaffolded
  workspace), so `init/1` creates both up front rather than assuming
  the caller already has, even though every current template ships them.
  ICM roots are never created by this module — they live outside the
  workspace and are the user's own folders.

  Started under `Valea.Workspace.Runtime` — it lives and dies with the open
  workspace, same as the audit writer and agent session supervisor.
  """
  use GenServer

  require Logger

  alias Valea.Mounts

  @debounce_ms 200

  def start_link(root), do: GenServer.start_link(__MODULE__, root, name: __MODULE__)

  @doc """
  Best-effort snapshot of every root this process's `FileSystem` listeners
  currently cover: every enabled, non-degraded ICM root (the DYNAMIC
  listener's dir set, keyed the same way `Valea.Mounts.enabled/1` resolves
  them — canonical, realpath-resolved absolute paths) plus the workspace's
  own `sources/` tree (the one non-`config/` dir the FIXED listener covers;
  `config/` itself names no mount and nothing checks membership against it,
  so it is omitted). Public so
  `Valea.Mounts.Doctor`'s `watcher_live` check can ask "is THIS mount's
  root currently watched" without reaching into `:sys.get_state` outside
  tests — cleaner than exposing internal state for a single-field read.

  Returns an empty `MapSet` when this GenServer isn't registered (no
  workspace open, or a race during open/close) rather than raising — a
  doctor check must degrade gracefully, never crash its caller. Mirrors the
  `Process.whereis/1` guard `Valea.Audit`/`Valea.Cockpit` already use for the
  same "this process may legitimately not exist" situation.
  """
  @spec watched_roots() :: MapSet.t(String.t())
  def watched_roots do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, :watched_roots)
    else
      MapSet.new()
    end
  end

  @impl true
  def init(root) do
    sources_path = Path.join(root, "sources")
    config_path = Path.join(root, "config")

    File.mkdir_p!(sources_path)
    File.mkdir_p!(config_path)

    icm_roots = compute_icm_roots(root)

    # Two listeners — see moduledoc. The fixed one is started once here
    # and never restarted; only the dynamic (ICM-root) one is ever
    # swapped by `recompute_dirs/1`.
    {:ok, fixed_watcher} = FileSystem.start_link(dirs: fixed_dirs(root))
    FileSystem.subscribe(fixed_watcher)

    icm_watcher = start_icm_watcher(Map.keys(icm_roots))

    # FSEvents (the macOS backend) reports paths through their PHYSICAL
    # (symlink-resolved) form — e.g. under `/private/var/...` even when the
    # directory was opened via a `/var/...` alias, as it commonly is under
    # the system temp dir. Resolving our reference paths the same way here,
    # once, keeps the prefix comparison in `under?/2` correct regardless of
    # which alias the caller passed in. ICM roots are already
    # realpath-resolved by `Valea.Mounts`, so `canonical/1` there is
    # idempotent — kept for defense-in-depth/uniformity, not correction.
    {:ok,
     %{
       fixed_watcher: fixed_watcher,
       icm_watcher: icm_watcher,
       root: root,
       sources_path: canonical(sources_path),
       config_path: canonical(config_path),
       icm_roots: icm_roots,
       discovery_timer: nil,
       discovery_pending: false
     }}
  end

  @impl true
  def handle_call(:watched_roots, _from, state) do
    {:reply, MapSet.new([state.sources_path | Map.keys(state.icm_roots)]), state}
  end

  @impl true
  def handle_info({:file_event, _pid, {path, _events}}, state) do
    case classify_path(path, state) do
      :config -> {:noreply, note_config_event(path, state)}
      {:icm, root} -> {:noreply, note_icm_event(path, root, state)}
      :ignore -> {:noreply, state}
    end
  end

  def handle_info({:file_event, _pid, :stop}, state), do: {:noreply, state}

  def handle_info(:flush_discovery, state) do
    Phoenix.PubSub.broadcast(Valea.PubSub, "icm", {:icm_changed})

    state =
      if state.discovery_pending do
        Phoenix.PubSub.broadcast(Valea.PubSub, "mounts", {:mounts_changed})
        recompute_dirs(state)
      else
        state
      end

    {:noreply, %{state | discovery_timer: nil, discovery_pending: false}}
  end

  # -- classification --------------------------------------------------

  defp classify_path(path, state) do
    cond do
      # sources/ is watched (see moduledoc) but has no discovery- or
      # content-relevant consumer yet — an explicit :ignore, rather than
      # falling through to ICM-root classification (which would
      # coincidentally also land on :ignore, since no ICM root can live
      # inside the workspace), so the intent is documented here rather
      # than incidental.
      under?(path, state.sources_path) -> :ignore
      under?(path, state.config_path) -> :config
      true -> classify_icm_root(path, state.icm_roots)
    end
  end

  defp classify_icm_root(path, icm_roots) do
    icm_roots
    |> Map.keys()
    |> Enum.filter(&under?(path, &1))
    # Nested ICM roots are pathological but not impossible — the
    # most-specific (longest) root owns the path, mirroring
    # `Valea.Mounts.mount_for/2`'s own tie-break.
    |> Enum.max_by(&byte_size/1, fn -> nil end)
    |> case do
      nil -> :ignore
      root -> {:icm, root}
    end
  end

  # A change to the mount SET, not just content: an ICM root's OWN
  # `icm.yaml` manifest (name/description, and the file whose mere
  # presence marks a mount as non-degraded), sitting directly at the root
  # (no intermediate segment — the root itself already names exactly one
  # mount). Anything else under the root is content-only. A bare touch on
  # the root itself (`[]` — e.g. a parent mtime bump FSEvents reports
  # alongside a deeper change) is a pure no-op: nothing to refetch,
  # nothing to reclassify. Any deeper change still lands its own event
  # with its own non-empty segment list, so this never drops real signal.
  defp note_icm_event(path, root, state) do
    case relative_segments(path, root) do
      [] ->
        state

      ["icm.yaml"] ->
        state = arm(:discovery_timer, :flush_discovery, state)
        %{state | discovery_pending: true}

      _other ->
        arm(:discovery_timer, :flush_discovery, state)
    end
  end

  # Only `config/workspace.yaml` itself is discovery-relevant — it is the
  # source of truth for enabled/disabled state AND every ICM's `path:`
  # declaration (see moduledoc). Any other file under `config/`
  # (`mail.yaml`, `calendar.yaml`, a bare touch on `config/` itself, a
  # `.tmp` sibling from an atomic write elsewhere) is unrelated to the
  # mount set and produces no event at all — content under `config/` never
  # feeds `icm_changed` either.
  defp note_config_event(path, state) do
    if path == Path.join(state.config_path, "workspace.yaml") do
      state = arm(:discovery_timer, :flush_discovery, state)
      %{state | discovery_pending: true}
    else
      state
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

  # -- ICM root discovery / re-subscription -----------------------------

  # One canonical absolute root path -> mount name, for every ENABLED,
  # non-degraded ICM (`Valea.Mounts.enabled/1` already excludes disabled
  # and degraded entries) whose root currently exists on disk.
  # `File.dir?/1` here is a defensive re-check against the narrow window
  # between that computation and this one, not the primary guard.
  defp compute_icm_roots(root) do
    root
    |> Mounts.enabled()
    # Task 14: synthetic `kind: :mail` mounts live INSIDE the workspace
    # under `sources/mail/<slug>` — already covered by the FIXED
    # `<root>/sources` listener above; adding them here would double-fire
    # every engine sync write through the dynamic listener.
    |> Enum.filter(&(&1.kind == :icm and File.dir?(&1.root)))
    |> Map.new(fn mount -> {canonical(mount.root), mount.name} end)
  end

  defp fixed_dirs(root), do: [Path.join(root, "sources"), Path.join(root, "config")]

  # Recomputes the enabled-ICM root set and swaps the DYNAMIC `FileSystem`
  # listener ONLY when that set actually changed — the fixed listener is
  # never touched (see moduledoc: this is what gives the workspace's own
  # trees a zero loss window). Called synchronously, inline, from the SAME
  # discovery flush that found the triggering change discovery-relevant in
  # the first place — see moduledoc for why that is the ONLY recompute
  # trigger.
  defp recompute_dirs(state) do
    new_icm_roots = compute_icm_roots(state.root)

    if MapSet.new(Map.keys(new_icm_roots)) == MapSet.new(Map.keys(state.icm_roots)) do
      state
    else
      stop_icm_watcher(state.icm_watcher)

      %{
        state
        | icm_watcher: start_icm_watcher(Map.keys(new_icm_roots)),
          icm_roots: new_icm_roots
      }
    end
  end

  # No dynamic listener while there is nothing to watch — `nil`, never a
  # `FileSystem` process with an empty dir list.
  defp start_icm_watcher([]), do: nil

  defp start_icm_watcher(roots) do
    {:ok, watcher} = FileSystem.start_link(dirs: roots)
    FileSystem.subscribe(watcher)
    watcher
  end

  defp stop_icm_watcher(nil), do: :ok

  # Bounded stop: a hung watcher port must not block this GenServer
  # forever. Unlinked first, so an abandoned (timed-out) pid can neither
  # take this process down when it eventually dies nor leak an exit
  # signal; its straggler `:file_event`s are harmless either way — they
  # classify against the already-updated root set (see moduledoc).
  defp stop_icm_watcher(pid) do
    Process.unlink(pid)
    GenServer.stop(pid, :normal, 5_000)
    :ok
  catch
    :exit, reason ->
      Logger.warning(
        "Valea.ICM.Watcher: ICM FileSystem listener did not stop cleanly, abandoning: " <>
          inspect(reason)
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
