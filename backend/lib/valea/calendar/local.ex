defmodule Valea.Calendar.Local do
  @moduledoc """
  The agent-writable Valea calendar (calendar spec F, §The Valea
  calendar): markdown event files under
  `sources/calendar/valea/events/<name>.md`, validated FAIL-CLOSED (the
  `Valea.Mail.DraftFile` posture) and read LIVE — no engine, no watcher,
  no index. `list/1` re-reads the (few) event files at query time, so
  agent-written files appear on the next query; the served feed and the
  RPC surface both consume the same listing.

  ## Validation (fail-closed, spec §The Valea calendar verbatim)

    * unknown frontmatter keys reject (allowed:
      `title`/`start`/`end`/`location`/`all_day`/`status` — the
      description IS the body, never a frontmatter key);
    * control characters reject in every frontmatter field; the body may
      contain newlines and tabs, any other C0 (and DEL) rejects;
    * `title` required, non-empty, ≤ 500 characters;
    * timed events: `start` ISO 8601 WITH a UTC offset, `start < end`,
      `end` omitted → start + 1 hour. The offset is PRESERVED from the
      file (a fixed-offset `%DateTime{}`); consumers UTC-normalize;
    * `all_day: true` ⇒ `start`/`end` are plain dates, `end` EXCLUSIVE
      (RFC 5545 DATE-typed DTEND) and STRICTLY after `start` — equal
      dates reject; `end` omitted → start + 1 day;
    * `status` ∈ confirmed | tentative | cancelled, default confirmed;
    * body ≤ 16384 bytes (measured on the trailing-newline-trimmed
      description, symmetric with what `write/4` composes back);
    * symlinked/hard-linked entries are rejected UNREAD (no-follow
      `File.lstat/1`, the drafts posture).

  A file that fails validation is listed under `invalid:` with its
  reason and rendered NOWHERE (neither grid nor served feed).

  ## Identity

  `uid/1` is deterministic from the FILE NAME only:
  `valea-<first 16 hex of sha256(basename incl. ".md")>@valea.local` —
  edits keep the UID stable (calendar clients track events by UID), a
  rename is intentionally a new event. The engine never stamps agent
  files.

  ## Containment

  Every filesystem access re-checks `Valea.Paths.resolve_real/2`
  containment under the workspace root, and `valid_name?/1` rejects a
  bad name BEFORE any path is constructed from it (the `get_mail_draft`
  posture).

  ## Write serialization

  `write/5` and `delete/3` are invoked directly by concurrent RPCs, so
  their disk sections (mode check through rename/rm) run inside
  `Valea.Calendar.Supervisor.lifecycle/1`, the `Valea.Calendar.Settings`
  legacy-convergence posture: the `:create`-refuses-existing /
  `:update`-requires-existing check is RE-EVALUATED inside the
  serialized section, so two racing creates of one name resolve to
  exactly one `{:ok, _}` and one `{:error, :exists}` instead of both
  "succeeding". There is NO unserialized fallback: when the serializer
  is not running (no open workspace, mid-teardown) mutations refuse with
  `{:error, :not_running}` — a stale RPC captured before a workspace
  switch can never write the old root behind the lock's back, and a
  serializer that dies out from under a queued call surfaces the same
  refusal instead of degrading to a direct write.

  The optional `verify:` hook (a zero-arity closure returning
  `{:ok, root}` — the root to mutate — or `{:error, reason}`) runs
  FIRST, INSIDE the serialized section, after any queued mutation ahead
  of it: `Valea.Api.Calendar` passes the workspace generation check plus
  the live root resolution there, so a stale RPC that reaches a NEW
  workspace's serializer fails its generation check before touching
  disk. Absent, the positional `root` is used unchanged (internal/test
  callers).

  `lifecycle/1` is re-entrant, so a write issued from within a
  lifecycle'd operation calls straight through without deadlocking. Each
  write installs through a UNIQUE hidden temp name (removed on failure),
  so a crashed writer can never rename another writer's bytes or leave
  visible debris. `list/1` stays lock-free — live reads, agent-written
  files are the API there.
  """

  alias Valea.Paths

  @events_rel Path.join(["sources", "calendar", "valea", "events"])

  # Bare basename, no extension: 1-80 chars of [a-z0-9._-], starting
  # alphanumeric — and never any ".." sequence (belt-and-braces: the
  # grammar already forbids separators, so ".." could never traverse, but
  # a name that even LOOKS like traversal is refused outright).
  # \A/\z anchors, not ^/$ — `$` would tolerate a trailing newline.
  @name_re ~r/\A[a-z0-9][a-z0-9._-]{0,79}\z/

  @allowed_keys ~w(title start end location all_day status)
  @statuses ~w(confirmed tentative cancelled)
  @max_title_chars 500
  @max_body_bytes 16_384

  defmodule Event do
    @moduledoc """
    One validated Valea-calendar event. Timed events carry `%DateTime{}`
    start/end (offset preserved from the file, UTC-comparable); all-day
    events carry `%Date{}` with `end` EXCLUSIVE. `mtime` is the file's
    lstat mtime as a UTC `%DateTime{}` truncated to seconds —
    `Valea.Calendar.Render` consumes it for DTSTAMP + LAST-MODIFIED.
    """
    defstruct [
      :name,
      :path,
      :title,
      :start,
      :end,
      :all_day,
      :location,
      :status,
      :description,
      :mtime
    ]

    @type t :: %__MODULE__{
            name: String.t(),
            path: String.t(),
            title: String.t(),
            start: DateTime.t() | Date.t(),
            end: DateTime.t() | Date.t(),
            all_day: boolean(),
            location: String.t() | nil,
            status: String.t(),
            description: String.t(),
            mtime: DateTime.t()
          }
  end

  @type invalid_entry :: %{name: String.t(), reason: String.t()}

  @doc "Bare-basename grammar `^[a-z0-9][a-z0-9._-]{0,79}$`, never any `..`."
  @spec valid_name?(String.t()) :: boolean()
  def valid_name?(name) when is_binary(name),
    do: Regex.match?(@name_re, name) and not String.contains?(name, "..")

  def valid_name?(_name), do: false

  @doc """
  The event's deterministic UID: `"valea-"` plus the first 16 hex of
  `sha256(name <> ".md")` (the basename INCLUDING the extension) plus
  `"@valea.local"`. Stable across edits; a rename is a new event.
  """
  @spec uid(String.t()) :: String.t()
  def uid(name) when is_binary(name) do
    hash16 =
      :crypto.hash(:sha256, name <> ".md")
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    "valea-" <> hash16 <> "@valea.local"
  end

  @doc """
  Live listing of `sources/calendar/valea/events/*.md`. Valid events
  come back sorted by name; every failing file lands in `invalid:` with
  its reason. Hidden entries (leading `.`, e.g. the template's
  `.gitkeep`) are skipped — the name grammar could never produce them.
  An events directory that fails containment (e.g. swapped for a
  symlink) lists NOTHING — fail-closed, never fail-open.
  """
  @spec list(String.t()) :: %{valid: [Event.t()], invalid: [invalid_entry()]}
  def list(root) when is_binary(root) do
    dir = Path.join(root, @events_rel)

    with {:ok, %File.Stat{type: :directory}} <- File.lstat(dir),
         {:ok, _real} <- Paths.resolve_real(dir, root),
         {:ok, entries} <- File.ls(dir) do
      {valid, invalid} =
        entries
        |> Enum.reject(&String.starts_with?(&1, "."))
        |> Enum.sort()
        |> Enum.reduce({[], []}, fn filename, {valid_acc, invalid_acc} ->
          case load_event(dir, filename) do
            {:ok, event} -> {[event | valid_acc], invalid_acc}
            {:error, reason} -> {valid_acc, [%{name: filename, reason: reason} | invalid_acc]}
          end
        end)

      %{valid: Enum.reverse(valid), invalid: Enum.reverse(invalid)}
    else
      _absent_or_outside -> %{valid: [], invalid: []}
    end
  end

  @doc """
  Composes and atomically writes `<name>.md` from `attrs` (atom keys:
  `:title`, `:start`, `:end`, `:all_day`, `:location`, `:status`,
  `:description` — start/end as the SAME strings the file format takes).
  The attrs are validated through the exact listing validation table
  BEFORE anything is composed or written — a control character or a bad
  date is `{:error, {:invalid, reason}}` with nothing on disk, never
  laundered. `:create` refuses an existing name (`{:error, :exists}`);
  `:update` requires one (`{:error, :not_found}`) — both re-checked
  inside the lifecycle-serialized disk section (moduledoc §Write
  serialization), so concurrent writes of one name cannot both pass.

  `opts` takes `verify:` (moduledoc §Write serialization): a zero-arity
  closure run FIRST, INSIDE the serialized section, returning
  `{:ok, root}` (the root actually mutated) or `{:error, reason}`
  (propagated, nothing written). Absent, `root` is used unchanged.
  Without a running `Valea.Calendar.Supervisor` the write refuses
  `{:error, :not_running}` — there is no unserialized fallback.
  """
  @spec write(String.t(), String.t(), map(), :create | :update, keyword()) ::
          {:ok, String.t()}
          | {:error, :exists | :not_found | :not_running | {:invalid, String.t()} | term()}
  def write(root, name, attrs, mode, opts \\ [])
      when is_binary(root) and is_map(attrs) and mode in [:create, :update] and is_list(opts) do
    with :ok <- require_valid_name(name),
         {:ok, raw, body} <- attrs_to_raw(attrs),
         {:ok, _fields} <- wrap_invalid(validate(raw, body)) do
      serialized(root, opts, fn verified_root ->
        checked_write(verified_root, name, raw, body, mode)
      end)
    end
  end

  @doc """
  Deletes `<name>.md`. `{:error, :not_found}` for an invalid name (never
  path-constructed), a missing file, or an entry that fails containment
  (a planted symlink is refused, not followed — remove it by hand). The
  disk section is lifecycle-serialized like `write/5`'s, `opts` takes
  the same `verify:` hook, and without a running serializer the delete
  refuses `{:error, :not_running}` — no unserialized fallback.
  """
  @spec delete(String.t(), String.t(), keyword()) ::
          :ok | {:error, :not_found | :not_running | term()}
  def delete(root, name, opts \\ []) when is_binary(root) and is_list(opts) do
    if valid_name?(name) do
      serialized(root, opts, fn verified_root -> checked_delete(verified_root, name) end)
    else
      {:error, :not_found}
    end
  end

  # -- loading one file ---------------------------------------------------------

  defp load_event(dir, filename) do
    with {:ok, name} <- event_name(filename),
         path = Path.join(dir, filename),
         {:ok, mtime} <- lstat_regular(path),
         {:ok, bytes} <- read_utf8(path),
         {:ok, fields} <- parse_and_validate(bytes) do
      {:ok,
       %Event{
         name: name,
         path: Path.join(@events_rel, filename),
         title: fields.title,
         start: fields.start,
         end: fields.end,
         all_day: fields.all_day,
         location: fields.location,
         status: fields.status,
         description: fields.description,
         mtime: mtime
       }}
    end
  end

  defp event_name(filename) do
    name = Path.basename(filename, ".md")

    if String.ends_with?(filename, ".md") and valid_name?(name) do
      {:ok, name}
    else
      {:error, "invalid event file name (want <name>.md, name #{inspect(@name_re.source)})"}
    end
  end

  # No-follow lstat: regular, single-link files only. The mtime rides
  # along as the UTC DateTime the Event carries (truncated to seconds by
  # construction — posix seconds in, seconds out).
  defp lstat_regular(path) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular, links: 1, mtime: mtime}} ->
        {:ok, DateTime.from_unix!(mtime)}

      {:ok, %File.Stat{type: :regular}} ->
        {:error, "symlink or hard-linked file refused (hard link count > 1)"}

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, "symlink or hard-linked file refused"}

      {:ok, %File.Stat{}} ->
        {:error, "not a regular file"}

      {:error, reason} ->
        {:error, "unreadable: #{inspect(reason)}"}
    end
  end

  defp read_utf8(path) do
    case File.read(path) do
      {:ok, bytes} ->
        if String.valid?(bytes) do
          {:ok, bytes}
        else
          {:error, "event file is not valid UTF-8"}
        end

      {:error, reason} ->
        {:error, "unreadable: #{inspect(reason)}"}
    end
  end

  # -- parsing + validation -----------------------------------------------------

  # Parses one event file's bytes through the full fail-closed table.
  defp parse_and_validate(bytes) when is_binary(bytes) do
    with {:ok, block, body} <- split_frontmatter(bytes),
         {:ok, raw} <- parse_yaml_map(block) do
      validate(raw, body)
    end
  end

  defp split_frontmatter("---\n" <> rest) do
    case String.split(rest, "\n---\n", parts: 2) do
      [block, body] -> {:ok, block, body}
      _no_terminator -> {:error, "missing frontmatter terminator"}
    end
  end

  defp split_frontmatter(_other), do: {:error, "event file has no leading frontmatter block"}

  defp parse_yaml_map(block) do
    case YamlElixir.read_from_string(block) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _other} -> {:error, "frontmatter is not a mapping"}
      {:error, %{message: message}} when is_binary(message) -> {:error, message}
      {:error, other} -> {:error, "invalid frontmatter yaml: #{inspect(other)}"}
    end
  rescue
    error -> {:error, "invalid frontmatter yaml: #{Exception.message(error)}"}
  end

  # The one validation table — shared verbatim by the read path (yaml
  # map) and the write path (attrs map), so write can never produce a
  # file list would refuse.
  defp validate(raw, body) do
    with :ok <- check_known_keys(raw),
         {:ok, title} <- validate_title(raw),
         {:ok, location} <- validate_location(raw),
         {:ok, status} <- validate_status(raw),
         {:ok, all_day} <- validate_all_day(raw),
         {:ok, start_value, end_value} <- validate_times(raw, all_day),
         {:ok, description} <- validate_body(body) do
      {:ok,
       %{
         title: title,
         start: start_value,
         end: end_value,
         all_day: all_day,
         location: location,
         status: status,
         description: description
       }}
    end
  end

  defp check_known_keys(raw) do
    case Enum.reject(Map.keys(raw), &(&1 in @allowed_keys)) do
      [] -> :ok
      extra -> {:error, "unknown frontmatter field(s): #{Enum.join(Enum.sort(extra), ", ")}"}
    end
  end

  defp validate_title(raw) do
    case Map.get(raw, "title") do
      value when is_binary(value) and value != "" ->
        cond do
          has_control?(value) -> {:error, "control character in title"}
          String.length(value) > @max_title_chars -> {:error, "title too long (max 500 chars)"}
          true -> {:ok, value}
        end

      _missing_empty_or_not_string ->
        {:error, "title must be a non-empty string"}
    end
  end

  defp validate_location(raw) do
    case Map.get(raw, "location") do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        if has_control?(value) do
          {:error, "control character in location"}
        else
          {:ok, value}
        end

      _other ->
        {:error, "location must be a string"}
    end
  end

  defp validate_status(raw) do
    case Map.get(raw, "status") do
      nil ->
        {:ok, "confirmed"}

      value when is_binary(value) ->
        cond do
          has_control?(value) -> {:error, "control character in status"}
          value in @statuses -> {:ok, value}
          true -> {:error, "invalid status #{inspect(value)} (confirmed|tentative|cancelled)"}
        end

      _other ->
        {:error, "status must be a string"}
    end
  end

  defp validate_all_day(raw) do
    case Map.get(raw, "all_day") do
      nil -> {:ok, false}
      value when is_boolean(value) -> {:ok, value}
      _other -> {:error, "all_day must be a boolean"}
    end
  end

  # -- times --------------------------------------------------------------------

  defp validate_times(raw, all_day) do
    with {:ok, start_raw} <- fetch_time(raw, "start"),
         {:ok, end_raw} <- fetch_optional_time(raw, "end") do
      if all_day do
        validate_all_day_times(start_raw, end_raw)
      else
        validate_timed_times(start_raw, end_raw)
      end
    end
  end

  defp fetch_time(raw, key) do
    case Map.get(raw, key) do
      value when is_binary(value) and value != "" ->
        if has_control?(value) do
          {:error, "control character in #{key}"}
        else
          {:ok, value}
        end

      nil ->
        {:error, "#{key} is required"}

      _other ->
        {:error, "#{key} must be a string"}
    end
  end

  defp fetch_optional_time(raw, key) do
    case Map.get(raw, key) do
      nil -> {:ok, nil}
      _present -> fetch_time(raw, key)
    end
  end

  defp validate_timed_times(start_raw, end_raw) do
    with {:ok, start_dt} <- parse_offset_datetime(start_raw, "start"),
         {:ok, end_dt} <- parse_timed_end(end_raw, start_dt) do
      if DateTime.compare(start_dt, end_dt) == :lt do
        {:ok, start_dt, end_dt}
      else
        {:error, "start must be before end"}
      end
    end
  end

  defp parse_timed_end(nil, start_dt), do: {:ok, add_fixed(start_dt, 3600)}
  defp parse_timed_end(end_raw, _start_dt), do: parse_offset_datetime(end_raw, "end")

  # ISO 8601 WITH offset, the offset PRESERVED: `DateTime.from_iso8601/1`
  # hands back the UTC instant plus the original offset; the fixed-offset
  # struct is rebuilt from the pair. Purely arithmetic — no time-zone
  # database is consulted for these values, ever.
  defp parse_offset_datetime(value, key) do
    case DateTime.from_iso8601(value) do
      {:ok, utc, offset} ->
        {:ok, restore_offset(utc, offset)}

      {:error, :missing_offset} ->
        {:error, "#{key} must be an ISO 8601 datetime with a UTC offset"}

      {:error, _reason} ->
        {:error, "#{key} must be an ISO 8601 datetime with a UTC offset"}
    end
  end

  defp restore_offset(%DateTime{} = utc, 0), do: utc

  defp restore_offset(%DateTime{} = utc, offset) do
    wall = utc |> DateTime.to_naive() |> NaiveDateTime.add(offset, :second)
    iso = format_offset(offset)

    %DateTime{
      year: wall.year,
      month: wall.month,
      day: wall.day,
      hour: wall.hour,
      minute: wall.minute,
      second: wall.second,
      microsecond: wall.microsecond,
      time_zone: iso,
      zone_abbr: iso,
      utc_offset: offset,
      std_offset: 0
    }
  end

  defp format_offset(offset) do
    sign = if offset < 0, do: "-", else: "+"
    total = abs(offset)
    hours = div(total, 3600)
    minutes = div(rem(total, 3600), 60)

    sign <>
      String.pad_leading(Integer.to_string(hours), 2, "0") <>
      ":" <> String.pad_leading(Integer.to_string(minutes), 2, "0")
  end

  # Adds seconds to a (possibly fixed-offset) DateTime without touching
  # any time-zone database: shift in UTC, restore the same offset.
  defp add_fixed(%DateTime{utc_offset: uo, std_offset: so} = dt, seconds) do
    utc =
      dt
      |> DateTime.to_naive()
      |> NaiveDateTime.add(-(uo + so) + seconds, :second)
      |> DateTime.from_naive!("Etc/UTC")

    restore_offset(utc, uo + so)
  end

  defp validate_all_day_times(start_raw, end_raw) do
    with {:ok, start_date} <- parse_plain_date(start_raw, "start"),
         {:ok, end_date} <- parse_all_day_end(end_raw, start_date) do
      if Date.compare(end_date, start_date) == :gt do
        {:ok, start_date, end_date}
      else
        {:error, "all-day end must be strictly after start (end is exclusive)"}
      end
    end
  end

  defp parse_all_day_end(nil, start_date), do: {:ok, Date.add(start_date, 1)}
  defp parse_all_day_end(end_raw, _start_date), do: parse_plain_date(end_raw, "end")

  defp parse_plain_date(value, key) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, "all-day #{key} must be a plain ISO date (YYYY-MM-DD)"}
    end
  end

  # -- body ---------------------------------------------------------------------

  # The description is the body with trailing newlines trimmed (write/5
  # composes them back), capped at 16384 bytes; newlines and tabs are the
  # only control characters a body may carry.
  defp validate_body(body) do
    description = String.trim_trailing(body, "\n")

    cond do
      has_control?(description, [?\n, ?\t]) -> {:error, "control character in body"}
      byte_size(description) > @max_body_bytes -> {:error, "body too large (max 16384 bytes)"}
      true -> {:ok, description}
    end
  end

  # C0 controls and DEL, minus the explicitly allowed set.
  defp has_control?(value, allowed \\ []) when is_binary(value) do
    value
    |> String.to_charlist()
    |> Enum.any?(fn c -> (c < 0x20 or c == 0x7F) and c not in allowed end)
  end

  # -- the write path -----------------------------------------------------------

  # The disk section of write/5 — everything that must not interleave
  # with another writer of the same name: the events-dir check, the
  # containment re-check, the mode check, and the temp-write + rename.
  # Runs inside serialized/1, so the mode check is authoritative at
  # install time, not at request time.
  defp checked_write(root, name, raw, body, mode) do
    with :ok <- ensure_events_dir(root),
         {:ok, abs} <- contain(root, name),
         :ok <- check_mode(abs, mode) do
      File.mkdir_p!(Path.dirname(abs))
      atomic_install!(abs, compose(raw, body))
      {:ok, Path.join(@events_rel, name <> ".md")}
    end
  end

  # The disk section of delete/3 (the name is grammar-validated by the
  # caller, so no path was ever constructed from a bad one).
  defp checked_delete(root, name) do
    with {:ok, %File.Stat{type: :directory}} <- File.lstat(Path.join(root, @events_rel)),
         {:ok, abs} <- contain(root, name),
         {:ok, %File.Stat{type: :regular}} <- File.lstat(abs),
         :ok <- File.rm(abs) do
      :ok
    else
      _missing_or_outside -> {:error, :not_found}
    end
  end

  # Unique per-write hidden temp name (the `Valea.Calendar.Settings`
  # posture): a shared fixed `.tmp` would let one writer rename another
  # writer's bytes into place and then crash on its own vanished temp;
  # with a unique name every rename installs exactly the bytes its writer
  # composed. Dotted, so a crashed write leaves only a hidden entry the
  # listing skips (the name grammar forbids a leading dot, so it can
  # never collide with or masquerade as an event) — and the temp is
  # removed on ANY write/rename failure, so no debris survives an error.
  defp atomic_install!(abs, bytes) do
    tmp =
      Path.join(
        Path.dirname(abs),
        "." <> Path.basename(abs) <> ".tmp-#{:erlang.unique_integer([:positive])}"
      )

    try do
      File.write!(tmp, bytes)
      File.rename!(tmp, abs)
    rescue
      error ->
        File.rm(tmp)
        reraise error, __STACKTRACE__
    end
  end

  # Serializes a disk section through `Valea.Calendar.Supervisor.lifecycle/1`.
  # The `verify:` closure (default: hand back the positional root) runs
  # FIRST, INSIDE the serialized section — after any queued mutation
  # ahead of it — and only its `{:ok, root}` reaches the disk section, so
  # a stale caller's generation check cannot pass against a root it
  # captured before a workspace switch. `lifecycle/1` degrades a raising
  # fun to `{:error, {:lifecycle_failed, message}}`; a disk failure here
  # is re-raised, preserving write/5's and delete/3's raise-on-disk-error
  # contract. The funs' own returns never carry that shape, so the match
  # is unambiguous.
  defp serialized(root, opts, fun) do
    verify = Keyword.get(opts, :verify, fn -> {:ok, root} end)

    result =
      serialize_through_lifecycle(fn ->
        with {:ok, verified_root} <- verify.() do
          fun.(verified_root)
        end
      end)

    case result do
      {:error, {:lifecycle_failed, message}} ->
        raise "valea calendar event mutation failed: #{message}"

      other ->
        other
    end
  end

  # The `Valea.Calendar.Settings.serialize_through_lifecycle/1` shape,
  # MINUS the direct fallback: `lifecycle/1` is re-entrant (a fun already
  # running inside the supervisor process calls straight through), but a
  # serializer that is not running — or that exits between the whereis
  # check and the call, or out from under the queued call (workspace
  # closing) — REFUSES `{:error, :not_running}` instead of degrading to
  # an unserialized direct write: a stale RPC must never mutate a root it
  # resolved before a workspace switch behind the lock's back.
  defp serialize_through_lifecycle(fun) do
    if is_pid(Process.whereis(Valea.Calendar.Supervisor)) do
      try do
        Valea.Calendar.Supervisor.lifecycle(fun)
      catch
        :exit, {:noproc, {GenServer, :call, _args}} -> {:error, :not_running}
        :exit, {:shutdown, {GenServer, :call, _args}} -> {:error, :not_running}
        :exit, {{:shutdown, _reason}, {GenServer, :call, _args}} -> {:error, :not_running}
      end
    else
      {:error, :not_running}
    end
  end

  defp require_valid_name(name) do
    if valid_name?(name), do: :ok, else: {:error, {:invalid, "invalid event name"}}
  end

  # The validation table speaks bare reason strings (the listing's
  # vocabulary); write/5's contract wraps them as `{:invalid, reason}`.
  defp wrap_invalid({:ok, _fields} = ok), do: ok
  defp wrap_invalid({:error, reason}), do: {:error, {:invalid, reason}}

  # write/5 may bootstrap the directory (mkdir_p), but an EXISTING entry
  # at that path that is not a real directory is refused, matching
  # list/1's no-follow posture.
  defp ensure_events_dir(root) do
    case File.lstat(Path.join(root, @events_rel)) do
      {:error, :enoent} -> :ok
      {:ok, %File.Stat{type: :directory}} -> :ok
      _link_or_special -> {:error, {:invalid, "events directory is not a directory"}}
    end
  end

  # attrs (atom keys, nil/"" optionals dropped) → the same string-keyed
  # raw map the yaml parser produces, so validate/2 applies identically.
  defp attrs_to_raw(attrs) do
    unknown =
      Map.keys(attrs) -- [:title, :start, :end, :all_day, :location, :status, :description]

    if unknown == [] do
      raw =
        [
          {"title", :title},
          {"start", :start},
          {"end", :end},
          {"location", :location},
          {"status", :status}
        ]
        |> Enum.reduce(%{}, fn {key, attr}, acc ->
          case Map.get(attrs, attr) do
            nil -> acc
            "" -> acc
            value -> Map.put(acc, key, value)
          end
        end)
        |> then(fn acc ->
          case Map.get(attrs, :all_day) do
            true -> Map.put(acc, "all_day", true)
            _false_or_nil -> acc
          end
        end)

      {:ok, raw, Map.get(attrs, :description) || ""}
    else
      {:error,
       {:invalid, "unknown attribute(s): #{Enum.map_join(Enum.sort(unknown), ", ", &inspect/1)}"}}
    end
  end

  # Composition mirrors the file grammar exactly; every scalar goes
  # through the shared injection-hardened `Valea.Yaml.escape/1`. The
  # values were validated FIRST, so escaping here never launders —
  # control characters have already rejected.
  defp compose(raw, body) do
    lines =
      for key <- @allowed_keys, Map.has_key?(raw, key) do
        case Map.fetch!(raw, key) do
          value when is_boolean(value) -> "#{key}: #{value}\n"
          value -> "#{key}: #{Valea.Yaml.escape(value)}\n"
        end
      end

    trimmed = String.trim_trailing(body, "\n")
    rendered_body = if trimmed == "", do: "", else: trimmed <> "\n"

    "---\n" <> Enum.join(lines) <> "---\n" <> rendered_body
  end

  defp check_mode(abs, :create) do
    case File.lstat(abs) do
      {:ok, _anything_there} -> {:error, :exists}
      {:error, _absent} -> :ok
    end
  end

  defp check_mode(abs, :update) do
    case File.lstat(abs) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      _absent_or_link -> {:error, :not_found}
    end
  end

  # Lexical + real containment (the FilesController `contain/2` shape):
  # the name is grammar-validated already, but every access still runs
  # back through `Paths.resolve_real/2` — never trust a lexically built
  # path for I/O.
  defp contain(root, name) do
    abs = Path.expand(Path.join(@events_rel, name <> ".md"), root)

    if String.starts_with?(abs, root <> "/") do
      case Paths.resolve_real(abs, root) do
        {:ok, _real} -> {:ok, abs}
        {:error, _reason} -> {:error, {:invalid, "event path escapes the workspace"}}
      end
    else
      {:error, {:invalid, "event path escapes the workspace"}}
    end
  end
end
