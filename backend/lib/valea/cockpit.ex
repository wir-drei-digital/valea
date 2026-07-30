defmodule Valea.Cockpit do
  @moduledoc """
  The Today cockpit payload: a lenient view over `today.json` files that
  AGENTS maintain (Spec D §C — Valea itself never writes them), merged
  across enabled ICMs in `Valea.Mounts.enabled/0` order with per-section
  provenance, plus the live state Valea owns: mail counts and recent
  sessions. String keys throughout (JSON-ready; also required for
  legitimate `false` values — see `Valea.Api.Agents.harness_doctor`).

  Leniency contract: absent `today.json` → no section for that ICM;
  unreadable/malformed → a section with `"ok" => false` (the FE renders a
  calm note, never an error state); unknown fields ignored; wrong-typed
  fields degrade to nil/[] rather than failing the parse. `today.json`
  changes ride the existing `icm_changed` watcher events — no new
  watcher wiring here.

  ## The tasks line and schedule notices (tasks+schedules spec §UI surfaces)

  `open_loops` is GONE from the section: the ICM's own `tasks.json` says what
  is open, so a per-section `"tasks"` line (counts + top 3) replaces the array
  agents used to hand-maintain in `today.json`. It reads a DIFFERENT file, so it
  degrades on its own: a malformed task ledger yields `"tasks" => nil` with the
  section's `"ok"` untouched (the `mail_summary/0` posture — one broken input
  never kills a section), and an absent ledger yields a zeroed line. The section
  itself still exists only where `today.json` does; the Tasks route is the
  complete view.

  `"schedule_notices"` is top-level, across every ICM: parked (`waiting`),
  `failed`, and newly `registered` schedules from the last 24 h. Notices carry
  NO captured output — the run-history RPC is where output lives (capped) —
  and `waiting` is derived by joining live session state, never read from a
  stored outcome (`Valea.Schedules.Runs`).
  """

  # Completed statuses never count toward the tasks line (`Valea.Tasks`' own
  # `done`/`dropped` pair).
  @completed ~w(done dropped)

  # Notices are a "what happened today" feed, not a log: the spec surfaces
  # parked/failed/registered events "the day they happen".
  @notice_window 86_400

  # A payload bound, not a policy: a workspace that failed 200 command runs
  # overnight has a broken schedule, not 200 things for the cockpit to say.
  @notice_cap 20

  @doc """
  Returns the Today cockpit payload as a map with string keys, ready for JSON.

  Returns `{:ok, map}` with keys:
    - "sections": one per enabled ICM that has a readable `today.json`, in
      `Valea.Mounts.enabled/0` order — `%{"mount_key", "icm_name", "ok",
      "updated_at", "notes", "prepared", "tasks"}` (see moduledoc for
      the leniency contract). `"tasks"` is the ICM's task line —
      `%{"due_today", "overdue", "in_progress", "top" => [%{"id", "title",
      "due", "today", "priority"}]}` — or `nil` when `tasks.json` cannot be
      parsed
    - "schedule_notices": across every enabled ICM, the last 24 h of schedule
      notices, newest first — `%{"kind" => "waiting" | "failed" |
      "registered", "mount_key", "schedule_id", "title", "at"}`; no captured
      output rides here
    - "mail": a LIST, one entry per running `Valea.Mail.Engine` (i.e. one
      per valid account) — `%{"account", "configured" => true, "state",
      "pending_ops", "notices"}`, live off `Valea.Mail.Engine.statuses/0`
      (Registry enumeration; empty list when no workspace is open or no
      account is configured yet)
    - "calendar": the Today calendar line (calendar spec F, §UI) —
      `%{"events_today" => n, "next" => %{"time" => "09:30", "title" => t}
      | nil}`, computed through the SAME query path as
      `list_calendar_events` (`Valea.Api.Calendar.events_in_range/4`) for
      host-zone today; lenient like "mail" — ANY failure (no workspace,
      Repo down, zone trouble) degrades to a `nil` entry, never a crash
    - "recent_sessions": up to 5 most recent sessions, newest first —
      `%{"id", "title", "started_at", "status", "live"}`
  """
  def today do
    {:ok,
     %{
       "sections" => icm_sections(),
       "mail" => mail_summary(),
       "calendar" => calendar_summary(),
       "recent_sessions" => recent_sessions(),
       "schedule_notices" => schedule_notices()
     }}
  end

  defp icm_sections do
    case Valea.Mounts.enabled() do
      {:ok, mounts} ->
        # Task 14: synthetic `kind: :mail` mounts have no manifest and no
        # `today.json` — the cockpit sections are ICM content only.
        mounts
        |> Enum.filter(&(&1.kind == :icm))
        |> Enum.map(&icm_section/1)
        |> Enum.reject(&is_nil/1)

      {:error, :no_workspace} ->
        []
    end
  end

  # The tasks line is computed for EVERY section, `today.json`'s own fate
  # included: the two files are independent, and an ICM whose `today.json` is
  # broken still has real tasks to show.
  defp icm_section(mount) do
    base = %{"mount_key" => mount.name, "icm_name" => mount.manifest.name}

    case File.read(Path.join(mount.root, "today.json")) do
      {:error, :enoent} ->
        nil

      {:error, _reason} ->
        unreadable_section(base, mount)

      {:ok, raw} ->
        case parse_today(raw) do
          {:ok, fields} ->
            base |> Map.put("ok", true) |> Map.merge(fields) |> with_tasks(mount)

          :error ->
            unreadable_section(base, mount)
        end
    end
  end

  defp unreadable_section(base, mount) do
    base |> Map.put("ok", false) |> Map.merge(empty_fields()) |> with_tasks(mount)
  end

  defp empty_fields do
    %{"updated_at" => nil, "notes" => nil, "prepared" => []}
  end

  defp parse_today(raw) do
    case Jason.decode(raw) do
      {:ok, %{} = doc} ->
        {:ok,
         %{
           "updated_at" => str_or_nil(doc["updated_at"]),
           "notes" => str_or_nil(doc["notes"]),
           "prepared" => items(doc["prepared"], ["title", "summary", "page"])
         }}

      _ ->
        :error
    end
  end

  # -- the tasks line (tasks+schedules spec §UI surfaces → Cockpit) ------------

  # Counts + the top 3 off the ICM's `tasks.json`. `nil` for an UNREADABLE
  # ledger — the FE's calm "fix by hand" note — and a zeroed line for an absent
  # or empty one, which is the difference between "nothing to do" and "I cannot
  # read your file". Never raises: a task line is not worth a failed cockpit.
  defp with_tasks(section, mount) do
    Map.put(section, "tasks", tasks_line(mount))
  end

  defp tasks_line(mount) do
    case Valea.Tasks.list(mount.root) do
      %{status: :unreadable} ->
        nil

      %{tasks: tasks} ->
        open = Enum.reject(tasks, &(&1["status"] in @completed))
        today = host_today()

        %{
          "due_today" => Enum.count(open, &(due_date(&1) == today)),
          "overdue" => Enum.count(open, &overdue?(&1, today)),
          "in_progress" => Enum.count(open, &(&1["status"] == "in_progress")),
          "top" => top_tasks(open)
        }
    end
  rescue
    _ -> nil
  end

  # Ordering, exactly as the spec words it: today-flag first, then due
  # ascending (a task with no parseable due sorts after every dated one), then
  # priority high > medium > low > anything else.
  defp top_tasks(open) do
    open
    |> Enum.sort_by(fn task ->
      {if(task["today"] == true, do: 0, else: 1), due_sort_key(task), priority_rank(task)}
    end)
    |> Enum.take(3)
    |> Enum.map(fn task ->
      %{
        "id" => str_or_nil(task["id"]),
        "title" => str_or_nil(task["title"]),
        "due" => str_or_nil(task["due"]),
        "today" => task["today"] == true,
        "priority" => str_or_nil(task["priority"])
      }
    end)
  end

  defp due_sort_key(task) do
    case due_date(task) do
      nil -> {1, ""}
      date -> {0, Date.to_iso8601(date)}
    end
  end

  defp priority_rank(task) do
    case task["priority"] do
      "high" -> 0
      "medium" -> 1
      "low" -> 2
      _absent_or_unknown -> 3
    end
  end

  defp overdue?(task, today) do
    case due_date(task) do
      nil -> false
      date -> Date.compare(date, today) == :lt
    end
  end

  # `due` is a plain calendar date in the spec's shape ("2026-07-30"); anything
  # else is simply not a date (lenient display).
  defp due_date(task) do
    case task["due"] do
      value when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> date
          {:error, _not_a_date} -> nil
        end

      _absent_or_wrong_typed ->
        nil
    end
  end

  # "Today" is a wall-clock question, so it resolves through the SAME zone
  # source the calendar line uses. A zone the tz database cannot resolve
  # degrades to the UTC date rather than dropping the whole line.
  defp host_today do
    case DateTime.now(Valea.Calendar.Engine.host_zone()) do
      {:ok, local} -> DateTime.to_date(local)
      {:error, _unknown_zone} -> Date.utc_today()
    end
  end

  # -- schedule notices --------------------------------------------------------

  # The last `@notice_window` seconds of schedule events, newest first: parked
  # runs (`waiting`, JOINED off live session state — never a stored outcome),
  # `failed` runs, and schedules newly seen in this workspace (`registered`).
  #
  # Lenient exactly like `mail_summary/0`, and for the same reason: these reads
  # touch `Valea.Repo`, which goes down BEFORE the runtime on every
  # close/switch — any surprise degrades to no notices, never a crashed
  # `today/0`.
  #
  # Titles come from each ICM's `schedules.json` (run records carry ids, not
  # labels); an entry that has since been deleted keeps its id as the label, so
  # a notice about a schedule that is gone still says which one.
  defp schedule_notices do
    case Valea.Mounts.enabled() do
      {:ok, mounts} -> notices_for(Enum.filter(mounts, &(&1.kind == :icm)))
      {:error, :no_workspace} -> []
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp notices_for(mounts) do
    since = DateTime.utc_now() |> DateTime.add(-@notice_window, :second)
    %{failed: failed, registered: registered} = Valea.Schedules.Store.notices_since(since)
    index = schedule_index(mounts)

    (Enum.map(Valea.Schedules.Runs.waiting_since(since), &{"waiting", &1, &1.fired_at}) ++
       Enum.map(failed, &{"failed", &1, &1.fired_at}) ++
       Enum.map(registered, &{"registered", &1, &1.first_seen_at}))
    |> Enum.map(fn {kind, row, at} -> notice(kind, row, at, index) end)
    |> Enum.sort_by(& &1["at"], :desc)
    |> Enum.take(@notice_cap)
  end

  # `(icm_id, schedule_id)` -> `%{mount_key, title}`. Run records carry their
  # own `mount_key` as display metadata, but `schedule_state` rows do not — and
  # the ICM id is the identity that survives a mount rename, so both kinds
  # resolve their label through this index.
  defp schedule_index(mounts) do
    for mount <- mounts,
        entry <- Valea.Schedules.File.load(mount.root).entries,
        is_binary(entry.id),
        into: %{} do
      {{mount.manifest.id, entry.id}, %{mount_key: mount.name, title: entry.title}}
    end
  end

  defp notice(kind, row, at, index) do
    known = Map.get(index, {row.icm_id, row.schedule_id})

    %{
      "kind" => kind,
      "mount_key" => (known && known.mount_key) || Map.get(row, :mount_key),
      "schedule_id" => row.schedule_id,
      "title" => (known && known.title) || row.schedule_id,
      "at" => Valea.Schedules.Runs.iso(at)
    }
  end

  defp items(list, keys) when is_list(list) do
    list
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn m -> Map.new(keys, fn k -> {k, str_or_nil(m[k])} end) end)
  end

  defp items(_other, _keys), do: []

  defp str_or_nil(v) when is_binary(v), do: v
  defp str_or_nil(_), do: nil

  # Live state Valea owns. `list_sessions/0`'s own `@spec` (`agents.ex`)
  # guarantees `{:ok, [map()]}` in every case — including no workspace open,
  # where it short-circuits to `{:ok, []}` before touching the filesystem —
  # so there is no error/raise shape here to degrade from (unlike
  # `live_mail_summary/0`, which genuinely can hit a dead Repo).
  defp recent_sessions do
    {:ok, sessions} = Valea.Agents.list_sessions()

    sessions
    |> Enum.sort_by(&(&1["started_at"] || ""), :desc)
    |> Enum.take(5)
    |> Enum.map(&Map.take(&1, ["id", "title", "started_at", "status", "live"]))
  end

  # `Valea.Mail.Engine.statuses/0` enumerates the `Valea.Mail.Registry` —
  # the SAME kind of "no workspace open (or one mid-switch/mid-close) means
  # nothing's registered" degradation `Process.whereis/1` gave the old
  # singleton Engine, but for free: an empty Registry just yields `%{}`, no
  # `:noproc` exit to guard against.
  #
  # `Valea.Mail.Store` (i.e. `Valea.Repo`) reads inside `Engine.status/1`'s
  # own `build_status/1` are a separate race, though: the Repo is NOT a
  # `Valea.Workspace.Runtime` child — the Manager starts it directly under
  # `Valea.Workspace.DynamicSupervisor` BEFORE the Runtime (`manager.ex`:
  # `start_repo` → `migrate` → `start_runtime`), and `do_close/1` terminates
  # `state.children` in that same list order, so on every close/switch the
  # Repo goes down FIRST while an account Engine's Registry entry can still
  # be briefly live. A `today/0` call landing in that window (or racing an
  # Engine crash) would otherwise raise/exit instead of degrading gracefully
  # — the rescue/catch below is deliberately broad, since the failure modes
  # here are "some dependency of the read is down" (`DBConnection.
  # ConnectionError`, `Exqlite.Error`, Ash wrappers, or a `:noproc` exit if
  # an Engine dies mid-call), not one specific exception type.
  defp mail_summary do
    Valea.Mail.Engine.statuses()
    |> Enum.map(fn {slug, status} -> mail_summary_entry(slug, status) end)
    |> Enum.sort_by(& &1["account"])
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp mail_summary_entry(slug, status) do
    {unread_count, unread} = unread_inbox(slug)

    %{
      "account" => slug,
      "configured" => true,
      "state" => status.state,
      "pending_ops" => status.pending_ops,
      "notices" => status.notices,
      "unread_count" => unread_count,
      "unread" => unread
    }
  end

  # The account's newest unread INBOX messages ("new emails by account" on
  # Today): unread = no maildir `S` (Seen) flag, over the newest
  # `@unread_window` indexed rows — a recency window, not a full-mailbox
  # count, which is the honest scope for a cockpit line. Own rescue, NOT
  # `mail_summary/0`'s: a dead Repo mid-close must degrade one account's
  # unread list to empty, never drop the whole account entry (the "Repo is
  # down but the Engine is still registered" case `cockpit_test.exs` pins).
  @unread_window 100
  @unread_shown 5

  defp unread_inbox(slug) do
    unread =
      slug
      |> Valea.Mail.Store.list_messages("INBOX", @unread_window)
      |> Enum.reject(fn row -> String.contains?(row.flags || "", "S") end)

    shown =
      unread
      |> Enum.take(@unread_shown)
      |> Enum.map(fn row ->
        %{
          "msg_id" => row.msg_id,
          "from_name" => row.from_name,
          "from_email" => row.from_email,
          "subject" => row.subject,
          "date" => row.date
        }
      end)

    {length(unread), shown}
  rescue
    _ -> {0, []}
  catch
    :exit, _ -> {0, []}
  end

  # The Today calendar line, through the SAME query path as
  # `list_calendar_events` (`Valea.Api.Calendar.events_in_range/4`) for
  # host-zone today. Lenient exactly like `mail_summary/0`, and for the
  # same reasons plus one more: the query touches `Valea.Repo` (external
  # occurrence rows) AND live-reads valea event files — a close/switch
  # window, a dead Repo, or any surprise degrades to a `nil` entry, never
  # a crashed `today/0`.
  defp calendar_summary do
    with {:ok, %{path: root}} <- Valea.Workspace.Manager.current(),
         zone = Valea.Calendar.Engine.host_zone(),
         {:ok, local_now} <- DateTime.now(zone),
         today = DateTime.to_date(local_now),
         {:ok, events} <-
           Valea.Api.Calendar.events_in_range(
             root,
             Date.to_iso8601(today),
             Date.to_iso8601(Date.add(today, 1)),
             zone
           ) do
      %{
        "events_today" => length(events),
        "next" => next_event(events, local_now, zone)
      }
    else
      _any_failure -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  # The next TIMED event at or after now, as local wall-clock "HH:MM" +
  # title. All-day rows carry no clock time and never become "next".
  defp next_event(events, local_now, zone) do
    events
    |> Enum.filter(&(&1["all_day"] == false))
    |> Enum.flat_map(fn row ->
      with {:ok, instant, _offset} <- DateTime.from_iso8601(row["start"]),
           {:ok, local} <- DateTime.shift_zone(instant, zone),
           false <- DateTime.compare(local, local_now) == :lt do
        [{DateTime.to_unix(local), Calendar.strftime(local, "%H:%M"), row["summary"]}]
      else
        _past_or_unparseable -> []
      end
    end)
    |> Enum.sort()
    |> case do
      [] -> nil
      [{_unix, time, title} | _later] -> %{"time" => time, "title" => title}
    end
  end
end
