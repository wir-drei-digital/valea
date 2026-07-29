defmodule Valea.Agents do
  @moduledoc """
  Public API for the agent session runtime. Owns starting sessions under the
  workspace-scoped `Valea.Agents.SessionSupervisor` and keeps the harness
  command resolution SYNCHRONOUS so `{:error, :harness_unavailable}` surfaces
  to the caller before any process is spawned.

  Also fans out over the whole workspace: `attach_or_replay/1` (live via the
  Registry, or ENDED via transcript file replay for the
  `ValeaWeb.AgentSessionChannel` join reply) and `list_sessions/0` (a
  workspace-wide session index for the SPA's session list).
  """

  alias Valea.Agents.SessionServer
  alias Valea.Mounts
  alias Valea.Workspace.Manager

  @doc """
  Starts a session. Resolves the harness command FIRST (so an unavailable
  harness returns synchronously), then starts the `SessionServer` child
  under `Valea.Agents.SessionSupervisor`.

  `opts` keys: `:kind`, `:title`, `:scope` (the C6 launch object from
  `Valea.Agents.SessionScope.resolve/1` — the primary ICM root, related
  ICMs, read/write grants, and the harness's folded launch directives;
  `SessionServer.init/1` derives the subprocess/ACP cwd and the split
  `PermissionPolicy` ctx from it), `:run`, `:initial_prompt`,
  `:on_turn_end`, and optionally `:id` (a caller-generated session id — a
  caller that already resolved `scope` with a specific `session_id` MUST
  pass the SAME id here, so the running session and its `scope`'s
  `managed_context` stay keyed to one identity; generated here when
  absent), `:handshake_timeout_ms` (test override), and `:context_doc`/
  `:input` (Spec D §B — the session-with-context primitive's own two
  locators, opaque here: passed straight through to `SessionServer.init/1`,
  never inspected or resolved in this module; both land in the transcript
  meta, and `:input` additionally becomes the session's Registry
  registration value, which `list_running_session_inputs/0` reads back).
  """
  @spec start_session(map()) :: {:ok, %{id: String.t()}} | {:error, term()}
  def start_session(opts) when is_map(opts) do
    with {:ok, spec} <-
           Valea.Harnesses.ClaudeCode.acp_command(%{env: Valea.Agents.Env.minimal()}) do
      id = Map.get(opts, :id) || generate_session_id()
      child_opts = opts |> Map.put(:id, id) |> Map.put(:spec, spec)

      case DynamicSupervisor.start_child(
             Valea.Agents.SessionSupervisor,
             {SessionServer, child_opts}
           ) do
        {:ok, _pid} -> {:ok, %{id: id}}
        {:ok, _pid, _info} -> {:ok, %{id: id}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Backend-generated session id: UTC timestamp + "-" + 6-byte hex suffix.
  Public (Task 5.5) so a caller that needs to resolve a `SessionScope`
  BEFORE starting the session (`SessionScope.resolve/1` requires a
  `session_id` up front, to derive `managed_context`'s path) can generate
  the SAME id it then passes to `start_session/1` as `:id` — the recommended
  "generate id -> resolve scope -> start_session(scope)" flow
  `Valea.Api.Agents.create_session` follows. `start_session/1` itself still
  falls back to calling this when no `:id` is given, so an existing caller
  that doesn't need the scope-first ordering is unaffected.
  """
  @spec generate_session_id() :: String.t()
  def generate_session_id do
    stamp =
      DateTime.utc_now()
      |> DateTime.to_iso8601(:basic)

    suffix = :crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)
    stamp <> "-" <> suffix
  end

  @doc """
  Every LIVE session paired with the input locator it was started with —
  `{session_id, input}`, `input` being the raw string-keyed locator map (or
  `nil` for a session started without one).

  Read straight off the Registry's registration VALUE
  (`Valea.Agents.SessionServer`'s `via/2`), never off transcripts: this is a
  routing decision on the hot path of a UI action ("is a session already
  working on this file?" — `Valea.Api.Mail`'s `revise_mail_draft`), and a
  directory scan would both cost more and answer the wrong question (ENDED
  sessions have transcripts too).

  The locators come back UNRESOLVED, exactly as their callers supplied them:
  resolving one is the caller's job (`Valea.Icm.Locator.resolve/2`), since
  only the caller knows which workspace it means to resolve against and what
  a resolution failure should mean.

  RUNNING means running, and the filter below is the only thing making that
  true. A dead session's registry entry OUTLIVES it — reaping waits on the
  `DOWN` the Registry's partition still has to process — and neither
  `Registry.select/2` nor `Registry.lookup/2` screens for liveness, so both
  keep reporting the entry until then. Nothing downstream would catch the
  mistake either: `GenServer.cast/2` to a dead pid is silently `:ok`, so a
  caller acting on an unfiltered list would address a corpse and be told it
  worked.
  """
  @spec list_running_session_inputs() :: [{String.t(), map() | nil}]
  def list_running_session_inputs do
    Valea.Agents.SessionRegistry
    |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])
    |> Enum.filter(fn {_id, pid, _value} -> Process.alive?(pid) end)
    |> Enum.map(fn
      {id, _pid, %{input: input}} -> {id, input}
      # Defensive: a registration value from anything but `via/2` has no
      # locator to report, and must never crash the enumeration.
      {id, _pid, _other} -> {id, nil}
    end)
  end

  @doc """
  Join-reply snapshot for `ValeaWeb.AgentSessionChannel`: `SessionServer.attach/1`
  when the id is a live Registry hit, otherwise a replay reconstructed from
  the workspace's transcript file (`busy: false, status: "ended"`).
  `{:error, :not_found}` when neither a live process nor a transcript file
  exists for `id`.
  """
  @spec attach_or_replay(String.t()) :: {:ok, map()} | {:error, :not_found}
  def attach_or_replay(id) do
    case SessionServer.attach(id) do
      {:ok, reply} -> {:ok, reply}
      {:error, :not_running} -> replay(id)
    end
  end

  defp replay(id) do
    with {:ok, %{path: workspace}} <- Manager.current() do
      path = transcript_path(workspace, id)

      if File.regular?(path) do
        {:ok, replay_reply(path)}
      else
        {:error, :not_found}
      end
    else
      {:error, :no_workspace} -> {:error, :not_found}
    end
  end

  defp replay_reply(path) do
    {items, cursor} =
      path
      |> File.stream!()
      # Line 1 is session metadata, not a timeline item — see SessionServer.
      |> Stream.drop(1)
      |> Enum.reduce({[], 0}, fn line, {items, cursor} ->
        case Jason.decode(line) do
          {:ok, %{"seq" => seq, "item" => item}} -> {upsert(items, item), seq}
          _ -> {items, cursor}
        end
      end)

    %{items: items, cursor: cursor, busy: false, status: "ended"}
  end

  # Mirrors SessionServer's in-memory timeline fold: later lines for the same
  # item id (e.g. a permission's resolved:false -> resolved:true transition)
  # REPLACE in place rather than appending a duplicate.
  defp upsert(timeline, item) do
    id = item["id"]

    if Enum.any?(timeline, &(&1["id"] == id)) do
      Enum.map(timeline, fn i -> if i["id"] == id, do: item, else: i end)
    else
      timeline ++ [item]
    end
  end

  @doc """
  Archives a session: moves its transcript from `logs/sessions/` into
  `logs/sessions/archived/` — a plain file move, file-first and
  hand-reversible. Archived transcripts disappear from every listing and
  from `attach_or_replay/1` (all of them scan only `logs/sessions/*.jsonl`;
  the `archived/` entry fails the `.jsonl` filename filter).

  A LIVE session is stopped first: its `SessionServer` owns the transcript
  file (appends, plus the sanctioned line-1 title rewrite) while running,
  so the server is shut down synchronously — `terminate/2` kills the
  adapter subprocess — before the file moves (`stop_live_server/1`).
  `{:error, :not_found}` when no transcript matches. The id becomes a
  filename component, so it is guarded with a `Path.basename/1` round-trip
  — a traversal-shaped id can never resolve outside `logs/sessions/`.
  """
  @spec archive_session(String.t()) ::
          :ok | {:error, :no_workspace | :not_found | File.posix()}
  def archive_session(id) when is_binary(id) do
    with {:ok, %{path: workspace}} <- Manager.current() do
      path = transcript_path(workspace, id)

      cond do
        Path.basename(path) != id <> ".jsonl" ->
          {:error, :not_found}

        not File.regular?(path) ->
          {:error, :not_found}

        true ->
          stop_live_server(id)
          dest_dir = Path.join(sessions_dir(workspace), "archived")
          File.mkdir_p!(dest_dir)

          case File.rename(path, Path.join(dest_dir, id <> ".jsonl")) do
            :ok ->
              Valea.Audit.append("session_archived", %{"session_id" => id})
              :ok

            {:error, reason} ->
              {:error, reason}
          end
      end
    end
  end

  @doc """
  Deletes a session permanently: removes its transcript from
  `logs/sessions/` — unlike `archive_session/1` there is no archived copy
  and no way back, which is why the UI collects an explicit confirmation
  before calling this. A LIVE session is stopped first, exactly like the
  archive path (`stop_live_server/1`); the same `Path.basename/1` traversal
  guard applies.
  """
  @spec delete_session(String.t()) ::
          :ok | {:error, :no_workspace | :not_found | File.posix()}
  def delete_session(id) when is_binary(id) do
    with {:ok, %{path: workspace}} <- Manager.current() do
      path = transcript_path(workspace, id)

      cond do
        Path.basename(path) != id <> ".jsonl" ->
          {:error, :not_found}

        not File.regular?(path) ->
          {:error, :not_found}

        true ->
          stop_live_server(id)

          case File.rm(path) do
            :ok ->
              Valea.Audit.append("session_deleted", %{"session_id" => id})
              :ok

            {:error, reason} ->
              {:error, reason}
          end
      end
    end
  end

  # Archiving a live session stops it first — the `SessionServer` appends to
  # the transcript while alive, so the file must never move under it.
  # `GenServer.stop/3` is synchronous: it returns after `terminate/2` ran
  # (which kills the adapter subprocess via `ProcessRuntime.stop/1`). The
  # catch absorbs the race where the server exits between lookup and stop.
  defp stop_live_server(id) do
    case Registry.lookup(Valea.Agents.SessionRegistry, id) do
      [{pid, _}] ->
        try do
          GenServer.stop(pid, :normal, 10_000)
        catch
          :exit, _ -> :ok
        end

      [] ->
        :ok
    end
  end

  @doc """
  Workspace-wide session index for the SPA's session list: scans
  `{workspace}/logs/sessions/*.jsonl` for their metadata (line 1), newest
  `started_at` first, merging in live status from the Registry via
  `SessionServer.attach/1`. `{:ok, []}` when no workspace is open or it has
  no sessions yet — this never fails the caller.

  Each summary carries the C8 workspace + ICM identity snapshot
  (`workspace_id`, `workspace_name`, `icm_mount`, `icm_id`, `icm_name`,
  `icm_root`, `generation`) straight off that transcript's own line 1 —
  never re-resolved against the live mount table — so a transcript from an
  ICM that's since been unmounted/renamed still reports what it actually
  ran against. `icm_mount` is the grouped-by-ICM listing's (Task 6.2) group
  key.
  """
  @spec list_sessions() :: {:ok, [map()]}
  def list_sessions do
    case Manager.current() do
      {:ok, %{path: workspace}} ->
        {:ok, workspace |> raw_sessions() |> Enum.sort_by(& &1["started_at"], :desc)}

      {:error, :no_workspace} ->
        {:ok, []}
    end
  end

  @doc """
  Grouped-by-ICM recent-session feed for the sidebar's project groups (Task
  6.2, spec §"ICM group behavior") — one group per `icm_mount` that has at
  least one session (an enabled/degraded mount with NO sessions yet is the
  sidebar's own concern to render via `Valea.Mounts.list/1` directly, not
  this listing's job), at most `limit` sessions each, **live sessions
  first** (newest-live first), **then newest-ended** — `Enum.split_with/2`
  is stable, so splitting the already-`started_at`-desc-sorted group
  preserves recency within each half.

  Groups are ordered by `Valea.Mounts.list/1`'s own order (sorted by mount
  key — the workspace's `icms:` config order) rather than by session
  recency or insertion order; a group whose `icm_mount` isn't found there
  (e.g. a transcript from an ICM since unmounted) sorts after every known
  mount, keyed by its own mount_key for stability.

  Each summary is the trimmed `%{id, kind, title, workflow, run_id,
  started_at, status, live}` shape (`trim_summary/1`) — NOT the full C8
  identity-snapshot map `list_sessions/0` returns (that stays untouched;
  `Valea.Workspace.Manager.switch_preflight/1` depends on its string-keyed
  shape). `[]` when no workspace is open or it has no sessions yet.
  """
  @spec list_recent_sessions_by_icm(pos_integer()) :: [
          %{mount_key: String.t(), icm_name: String.t(), sessions: [map()]}
        ]
  def list_recent_sessions_by_icm(limit \\ 5) do
    case Manager.current() do
      {:ok, %{path: workspace}} ->
        order_index =
          workspace |> Mounts.list() |> Enum.map(& &1.name) |> Enum.with_index() |> Map.new()

        workspace
        |> raw_sessions()
        |> Enum.group_by(& &1["icm_mount"])
        |> Enum.sort_by(fn {mount_key, _sessions} ->
          {Map.get(order_index, mount_key, :unmounted), mount_key}
        end)
        |> Enum.map(fn {mount_key, sessions} -> build_group(mount_key, sessions, limit) end)

      {:error, :no_workspace} ->
        []
    end
  end

  defp build_group(mount_key, sessions, limit) do
    sorted = Enum.sort_by(sessions, & &1["started_at"], :desc)
    {live, ended} = Enum.split_with(sorted, & &1["live"])

    %{
      mount_key: mount_key,
      icm_name: sorted |> List.first() |> Map.get("icm_name"),
      sessions: (live ++ ended) |> Enum.take(limit) |> Enum.map(&trim_summary/1)
    }
  end

  @page_size 20

  @doc """
  Full, filtered session history for a single ICM (Task 6.2's "Show all…"
  history view) — every session whose `icm_mount == mount_key`, newest
  `started_at` first, `@page_size` (#{@page_size}) per page.

  Keyset-paged on session id (unique, and lexically sortable since
  `generate_session_id/0`'s timestamp prefix): `cursor` is `nil` for the
  first page, otherwise the previous page's `next_cursor` — the id of its
  LAST (oldest-in-page) session. A `cursor` that no longer matches any
  session (e.g. an ended session's transcript vanished) is treated as
  "start from the top" rather than raising, since the caller can't tell the
  difference from here.

  `next_cursor` is `nil` once the page reaches the end of the filtered set.
  `%{sessions: [], next_cursor: nil}` when no workspace is open or
  `mount_key` has no sessions.

  `page_size` is a third, optional argument (default `@page_size`) purely
  so tests can exercise multi-page traversal without creating dozens of
  real sessions — no RPC caller ever passes it.
  """
  @spec list_sessions_for(String.t(), String.t() | nil, pos_integer()) :: %{
          sessions: [map()],
          next_cursor: String.t() | nil
        }
  def list_sessions_for(mount_key, cursor, page_size \\ @page_size) do
    case Manager.current() do
      {:ok, %{path: workspace}} ->
        remaining =
          workspace
          |> raw_sessions()
          |> Enum.filter(&(&1["icm_mount"] == mount_key))
          |> Enum.sort_by(& &1["started_at"], :desc)
          |> skip_to_cursor(cursor)

        {page, rest} = Enum.split(remaining, page_size)
        next_cursor = if rest == [], do: nil, else: List.last(page)["id"]

        %{sessions: Enum.map(page, &trim_summary/1), next_cursor: next_cursor}

      {:error, :no_workspace} ->
        %{sessions: [], next_cursor: nil}
    end
  end

  defp skip_to_cursor(sorted, nil), do: sorted

  defp skip_to_cursor(sorted, cursor) do
    case Enum.find_index(sorted, &(&1["id"] == cursor)) do
      nil -> sorted
      idx -> Enum.drop(sorted, idx + 1)
    end
  end

  defp trim_summary(s) do
    %{
      id: s["id"],
      kind: s["kind"],
      title: s["title"],
      workflow: s["workflow"],
      run_id: s["run_id"],
      started_at: s["started_at"],
      status: s["status"],
      live: s["live"],
      busy: s["busy"] == true,
      # The session's primary-ICM identity snapshot (session/v1 metadata) —
      # the chat header renders "in <icm_name>" off the summary alone.
      icm_mount: s["icm_mount"],
      icm_name: s["icm_name"]
    }
  end

  @doc """
  Line-1 (`session/v1`) metadata of `id`'s transcript in the open
  workspace — the resume path's read of the original session's identity
  (`icm_mount`, `acp_session_id`, `context_doc`/`input`, `include_mounts`,
  `title`). The id becomes a filename component, so it carries the same
  `Path.basename/1` round-trip guard `archive_session/1` uses.
  """
  @spec session_meta(String.t()) :: {:ok, map()} | {:error, :not_found}
  def session_meta(id) when is_binary(id) do
    case Manager.current() do
      {:ok, %{path: workspace}} ->
        path = transcript_path(workspace, id)

        with true <- Path.basename(path) == id <> ".jsonl",
             {:ok, meta} <- read_meta(path) do
          {:ok, meta}
        else
          _ -> {:error, :not_found}
        end

      {:error, :no_workspace} ->
        {:error, :not_found}
    end
  end

  @doc """
  Revives an ENDED session IN ITS OWN transcript — same id, same file, same
  chat URL; "continue", not "new session". The new `SessionServer` seeds
  its timeline and seq from the transcript's existing items (so appends
  stay monotonic after the history the channel replay already delivered),
  and launches the adapter preferring ACP `session/resume` with the
  recorded `acp_session_id` (the codec falls back to `session/load` —
  whose history replay dedups against the persisted `message_id`s — per
  the adapter's capabilities). A session that died before its handshake
  ever recorded an acp id resumes as a FRESH agent conversation in the
  same transcript. Idempotent by goal state: an already-live session
  returns `{:ok, %{id: id}}`.

  The caller (the `resume_agent_session` RPC) supplies a freshly resolved
  `scope` — grants are re-resolved at resume time, never widened beyond
  what the original session recorded.
  """
  @spec resume_session(%{id: String.t(), scope: map(), meta: map()}) ::
          {:ok, %{id: String.t()}} | {:error, term()}
  def resume_session(%{id: id, scope: scope, meta: meta}) do
    case Registry.lookup(Valea.Agents.SessionRegistry, id) do
      [_ | _] ->
        {:ok, %{id: id}}

      [] ->
        %{items: timeline, cursor: seq} = replay_reply(transcript_path(scope.workspace.root, id))

        known =
          timeline
          |> Enum.map(& &1["message_id"])
          |> Enum.filter(&is_binary/1)
          |> MapSet.new()

        # The agent-assigned conversation id lives in the TIMELINE's
        # `acp_session` meta item (the `{:conversation_id}` effect APPENDS an
        # item — line 1's own `acp_session_id` field is written once as nil
        # and never rewritten). The timeline upserts by id, so this is always
        # the LATEST conversation id, including one minted by an earlier
        # resume that itself fell back to a fresh conversation.
        acp_id =
          meta["acp_session_id"] ||
            Enum.find_value(timeline, fn
              %{"id" => "acp_session", "acp_session_id" => cid} when is_binary(cid) -> cid
              _ -> nil
            end)

        case start_session(%{
               id: id,
               kind: meta["kind"] || "chat",
               title: meta["title"],
               scope: scope,
               run: nil,
               initial_prompt: nil,
               on_turn_end: nil,
               # Re-register the input locator the ORIGINAL start recorded, so
               # `list_running_session_inputs/0` keeps answering "a session is
               # already working on this file" across a revival. Read-only
               # here: the resume path never rewrites line 1 (see
               # `SessionServer.open_transcript/2`), so this only ever restores
               # what that line already says.
               input: meta["input"],
               resume: %{
                 conversation_id: acp_id,
                 known_message_ids: known,
                 timeline: timeline,
                 seq: seq
               }
             }) do
          {:ok, %{id: ^id}} -> {:ok, %{id: id}}
          # Lost the Registry race to a concurrent resume — goal state met.
          {:error, {:already_started, _pid}} -> {:ok, %{id: id}}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp sessions_dir(workspace), do: Path.join([workspace, "logs", "sessions"])
  defp transcript_path(workspace, id), do: Path.join(sessions_dir(workspace), id <> ".jsonl")

  # Shared scan: every transcript's line-1 metadata + live status, UNSORTED
  # (each caller sorts/groups/pages for its own purpose) — the common base
  # `list_sessions/0`, `list_recent_sessions_by_icm/1`, and
  # `list_sessions_for/3` all build on.
  defp raw_sessions(workspace) do
    workspace
    |> sessions_dir()
    |> transcript_files()
    |> Enum.map(&session_summary/1)
    |> Enum.reject(&is_nil/1)
  end

  defp transcript_files(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
        |> Enum.map(&Path.join(dir, &1))

      {:error, _reason} ->
        []
    end
  end

  # `session/v1` (C8) is the only transcript schema this reader understands
  # — a transcript whose line 1 isn't stamped with it (a pre-redesign
  # transcript, or anything else that doesn't parse to this shape) is
  # silently skipped rather than surfaced half-formed (spec §"Session
  # persistence": no reader for old transcripts).
  defp session_summary(path) do
    with {:ok, meta} <- read_meta(path),
         %{"schema" => "session/v1"} <- meta do
      id = meta["id"]
      {live?, status, busy?} = live_status(id)

      %{
        "id" => id,
        "kind" => meta["kind"],
        "title" => meta["title"],
        "workflow" => meta["workflow"],
        "run_id" => meta["run_id"],
        "started_at" => meta["started_at"],
        "status" => status,
        "live" => live?,
        # A turn is in flight right now (attach's own `busy`) — drives the
        # sidebar's "agent is working" indicator. Snapshot-fresh only, like
        # `live`: listings refresh on demand, there is no per-session push.
        "busy" => busy?,
        # C8 identity fields (Task 6.1) — carried through so the grouped-by-ICM
        # listing (Task 6.2) can key off `icm_mount` without re-reading every
        # transcript's line 1 itself.
        "workspace_id" => meta["workspace_id"],
        "workspace_name" => meta["workspace_name"],
        "icm_mount" => meta["icm_mount"],
        "icm_id" => meta["icm_id"],
        "icm_name" => meta["icm_name"],
        "icm_root" => meta["icm_root"],
        "generation" => meta["generation"]
      }
    else
      _ -> nil
    end
  end

  defp live_status(id) do
    case SessionServer.attach(id) do
      {:ok, %{status: status, busy: busy}} -> {true, status, busy}
      {:error, :not_running} -> {false, "ended", false}
    end
  end

  # `Stream.resource`'s cleanup runs on early halt too, so `Enum.at/2` reading
  # just the first line still closes the file handle — no explicit open/close.
  defp read_meta(path) do
    case path |> File.stream!() |> Enum.at(0) do
      nil -> :error
      line -> Jason.decode(line)
    end
  rescue
    File.Error -> :error
  end
end
