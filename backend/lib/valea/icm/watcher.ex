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
    * a write to a MAIL DRAFT — `sources/mail/<slug>/drafts/<name>.md`,
      and nothing else under `sources/` — broadcasts
      `{:mail_draft_changed, slug}` on `"mail"` for each touched account
      that is actually configured in `config/mail.yaml` (spec G: a draft
      composed or edited by an agent, or by hand, shows up in the UI
      without a manual refresh)
    * every other change under `sources/` produces no event at all — the
      tree is watched (see "why the fixed trees are created up front"
      below) for the drafts above, and the engine's own maildir/view
      writes already announce themselves through `Valea.Mail.Engine`'s
      broadcasts rather than needing a second, fs-derived hint

  Each tree gets its own debounce timer so a burst of activity in one does
  not delay or coalesce with the other — `draft_timer`/`draft_pending`
  deliberately do NOT reuse the discovery pair below: a draft burst must
  never drag the mount-set recompute in behind it (and vice versa).
  `discovery_timer`/`discovery_pending` cover every discovery-relevant
  source above (each ICM root's own `icm.yaml`, and `config/workspace.yaml`)
  rather than a separate timer per source: every event seen during the
  window is classified as it arrives, and on flush the handler emits
  `icm_changed` unconditionally plus `mounts_changed` only if something
  discovery-relevant was seen — so a manifest touch inside a content burst
  still gets both events, exactly once, together. Events carry no payload
  beyond the account slug a draft flush names (nothing at all, for the
  other two) by design — consumers refetch (cheap to rebuild, and the fs
  events themselves are noisy).

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

  ## When the FS backend is unavailable (spec A5)

  `file_system` is not guaranteed to start on every platform — on Windows
  the native backend may be missing entirely. A failure to start the FIXED
  listener is NOT a workspace-boot crash: `init/1` catches the
  `{:error, reason}`, logs once, and enters a DISABLED state —
  `watching: false`, both listeners `nil`, and `start_icm_watcher/2` a
  guaranteed no-op (so `recompute_dirs/1` cannot resurrect a listener
  either). The GenServer stays alive and keeps serving its read API:
  `watching?/1` reports `false` and `watched_roots/1` reports an EMPTY set
  (a disabled watcher covers nothing — NOT the would-be set of `sources/`
  plus the enabled roots). A workspace therefore opens normally; its tree
  just refreshes on navigation instead of live. `Valea.Mounts.Doctor`'s
  `watcher_live` check reads `watching?/1` to surface this honestly — an
  enabled mount reports "unknown, file watching unavailable" rather than a
  stale "failed". Only listener START errors degrade this way; a
  bad-argument or bad-shape config still raises (a config error is a bug,
  not an unsupported platform).

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

  alias Valea.Mail.Settings
  alias Valea.Mounts

  @debounce_ms 200

  @doc """
  Starts the watcher. Accepts either a bare workspace `root` — the
  supervisor child spec `{Valea.ICM.Watcher, root}` in
  `Valea.Workspace.Runtime`, unchanged — or `{root, opts}`:

    * `opts[:fs_mod]` — the `FileSystem`-shaped module the listeners are
      started with (default: the `:icm_watcher_fs_mod` app-env seam, itself
      defaulting to the real `FileSystem`). Reading the seam HERE, not in
      `init/1`, is what lets the real workspace-runtime path — which only
      ever passes a bare `root` — be driven through a stub too (spec A5's
      "a workspace still opens with watching disabled" acceptance).
    * `opts[:name]` — the registered name (default: `__MODULE__`, the
      singleton). Tests that must not collide with the singleton pass a
      private name.
  """
  def start_link(arg) do
    {root, opts} =
      case arg do
        {root, opts} when is_binary(root) and is_list(opts) -> {root, opts}
        root when is_binary(root) -> {root, []}
      end

    fs_mod =
      Keyword.get(opts, :fs_mod, Application.get_env(:valea, :icm_watcher_fs_mod, FileSystem))

    name = Keyword.get(opts, :name, __MODULE__)

    GenServer.start_link(__MODULE__, {root, Keyword.put(opts, :fs_mod, fs_mod)}, name: name)
  end

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
  workspace open, or a race during open/close) OR when file watching is
  disabled (the FS backend was unavailable at open — `watching?/1` is
  `false`; see spec A5) rather than raising — a doctor check must degrade
  gracefully, never crash its caller. Mirrors the `Process.whereis/1` guard
  `Valea.Audit`/`Valea.Cockpit` already use for the same "this process may
  legitimately not exist" situation. Takes an optional `server` (default
  singleton) so a privately-named instance can be addressed in tests.
  """
  @spec watched_roots(GenServer.server()) :: MapSet.t(String.t())
  def watched_roots(server \\ __MODULE__) do
    if Process.whereis(server) do
      GenServer.call(server, :watched_roots)
    else
      MapSet.new()
    end
  end

  @doc """
  Whether this watcher's `FileSystem` backend is live — `true` when the
  FIXED listener started and subscribed, `false` when it could not start
  (spec A5: the backend is unavailable on this platform) and the watcher is
  running in its DISABLED state.

  Optimistically `true` when no watcher process is registered (no workspace
  open, or a race during open/close): "no process" is a TRANSIENT absence,
  not a statement that the backend is unavailable — `Valea.Mounts.Doctor`
  tells the two apart via `watched_roots/1` (an empty set from a
  not-running watcher ⇒ a stale "failed", not "unavailable"). Only a
  RUNNING watcher can truthfully report the backend down. Takes an optional
  `server` (default singleton) so a privately-named instance can be
  addressed in tests.
  """
  @spec watching?(GenServer.server()) :: boolean()
  def watching?(server \\ __MODULE__) do
    if Process.whereis(server) do
      GenServer.call(server, :watching?)
    else
      true
    end
  end

  @impl true
  def init({root, opts}) do
    fs_mod = Keyword.get(opts, :fs_mod, FileSystem)

    sources_path = Path.join(root, "sources")
    config_path = Path.join(root, "config")

    File.mkdir_p!(sources_path)
    File.mkdir_p!(config_path)

    icm_roots = compute_icm_roots(root)

    # Two listeners — see moduledoc. The fixed one is started once here
    # and never restarted; only the dynamic (ICM-root) one is ever
    # swapped by `recompute_dirs/1`. A fixed-listener START error is not
    # fatal (spec A5): log once and fall into the DISABLED state
    # (`watching: false`, both listeners `nil`) instead of crashing the
    # workspace open. `FileSystem.subscribe/1` is the real module in both
    # arms — it is only reached on success, where `fs_mod` is `FileSystem`
    # anyway.
    {fixed_watcher, watching} =
      case fs_mod.start_link(dirs: fixed_dirs(root)) do
        {:ok, watcher} ->
          FileSystem.subscribe(watcher)
          {watcher, true}

        {:error, reason} ->
          Logger.warning(
            "ICM file watching disabled (#{inspect(reason)}) — tree refreshes on navigation only"
          )

          {nil, false}
      end

    icm_watcher = start_icm_watcher(Map.keys(icm_roots), %{fs_mod: fs_mod, watching: watching})

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
       fs_mod: fs_mod,
       watching: watching,
       sources_path: canonical(sources_path),
       config_path: canonical(config_path),
       icm_roots: icm_roots,
       discovery_timer: nil,
       discovery_pending: false,
       draft_timer: nil,
       draft_pending: MapSet.new()
     }}
  end

  @impl true
  def handle_call(:watching?, _from, state) do
    {:reply, state.watching, state}
  end

  # A disabled watcher (the FS backend was unavailable at open) runs no
  # listeners, so it covers nothing — an empty set, NOT the would-be set of
  # `sources/` plus the enabled ICM roots. Keeps `watched_roots/1` honest
  # with `watching?/1` and lets `Valea.Mounts.Doctor` short-circuit to
  # "unknown" (see moduledoc, spec A5).
  def handle_call(:watched_roots, _from, %{watching: false} = state) do
    {:reply, MapSet.new(), state}
  end

  def handle_call(:watched_roots, _from, state) do
    {:reply, MapSet.new([state.sources_path | Map.keys(state.icm_roots)]), state}
  end

  @impl true
  def handle_info({:file_event, _pid, {path, _events}}, state) do
    case classify_path(path, state) do
      :config -> {:noreply, note_config_event(path, state)}
      {:icm, root} -> {:noreply, note_icm_event(path, root, state)}
      {:mail_draft, slug} -> {:noreply, note_mail_draft_event(slug, state)}
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

  # One broadcast per DISTINCT account touched during the window, and only
  # for accounts `config/mail.yaml` actually declares: the path grammar
  # alone can't know that, and a stray `sources/mail/<anything>/drafts/`
  # tree (a leftover from a removed account, a hand-made folder) must not
  # push a phantom account at the UI. Settings are read HERE, on flush,
  # rather than cached in state — the file changes independently of this
  # process, and one YAML read per debounce window is cheap.
  def handle_info(:flush_drafts, state) do
    configured = configured_slugs(state.root)

    for slug <- state.draft_pending, slug in configured do
      Phoenix.PubSub.broadcast(Valea.PubSub, "mail", {:mail_draft_changed, slug})
    end

    {:noreply, %{state | draft_timer: nil, draft_pending: MapSet.new()}}
  end

  defp configured_slugs(root) do
    case Settings.load(root) do
      {:ok, %{accounts: accounts}} -> Map.keys(accounts)
      _other -> []
    end
  end

  # -- classification --------------------------------------------------

  defp classify_path(path, state) do
    cond do
      under?(path, state.sources_path) -> classify_sources(path, state.sources_path)
      under?(path, state.config_path) -> :config
      true -> classify_icm_root(path, state.icm_roots)
    end
  end

  # `sources/` carries exactly ONE live-refresh consumer: mail drafts.
  # Deliberately narrow — the path must be a `.md` file sitting DIRECTLY in
  # `sources/mail/<slug>/drafts/` (four segments, no deeper), with `<slug>`
  # matching the account slug grammar (`Valea.Mail.Settings.valid_slug?/1`,
  # the same grammar `config/mail.yaml` accepts) so an arbitrary directory
  # name can never enter the pending set. Everything else under `sources/`
  # — the engine's own maildir and view writes above all, which run in
  # bursts on every sync pass — stays an explicit `:ignore` rather than
  # falling through to ICM-root classification (which would coincidentally
  # also land on `:ignore`, since no ICM root can live inside the
  # workspace), so the intent is documented here rather than incidental.
  defp classify_sources(path, sources_path) do
    case relative_segments(path, sources_path) do
      ["mail", slug, "drafts", file] ->
        if Settings.valid_slug?(slug) and String.ends_with?(file, ".md"),
          do: {:mail_draft, slug},
          else: :ignore

      _other ->
        :ignore
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

  # Per-account accumulation: the flush broadcasts once per DISTINCT slug
  # touched during the window, so an agent writing five drafts for one
  # account produces one refetch hint, not five. Its own timer — a draft
  # burst must not arm (or postpone) the discovery flush, which recomputes
  # the whole mount set.
  defp note_mail_draft_event(slug, state) do
    state = arm(:draft_timer, :flush_drafts, state)
    %{state | draft_pending: MapSet.put(state.draft_pending, slug)}
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
        | icm_watcher: start_icm_watcher(Map.keys(new_icm_roots), state),
          icm_roots: new_icm_roots
      }
    end
  end

  # No dynamic listener when file watching is disabled — the fixed listener
  # already failed to start, so the FS backend is unavailable process-wide
  # (spec A5); there is nothing to subscribe to. This clause short-circuits
  # every recompute back to `nil`, so `recompute_dirs/1` no-ops naturally in
  # the disabled state. `ctx` is any map carrying `:fs_mod`/`:watching` —
  # the fresh `%{fs_mod:, watching:}` from `init/1` or the whole `state`
  # from `recompute_dirs/1`.
  defp start_icm_watcher(_roots, %{watching: false}), do: nil

  # No dynamic listener while there is nothing to watch — `nil`, never a
  # `FileSystem` process with an empty dir list.
  defp start_icm_watcher([], _ctx), do: nil

  defp start_icm_watcher(roots, %{fs_mod: fs_mod}) do
    case fs_mod.start_link(dirs: roots) do
      {:ok, watcher} ->
        FileSystem.subscribe(watcher)
        watcher

      # A dynamic-start error degrades exactly like the fixed listener's:
      # log once, return `nil`, don't crash. We only reach here with
      # `watching: true` (the fixed listener came up), so the workspace's
      # own trees stay covered; only these ICM roots fall back to a
      # navigation refresh.
      {:error, reason} ->
        Logger.warning(
          "ICM root watching unavailable (#{inspect(reason)}) — those roots refresh on navigation only"
        )

        nil
    end
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
