defmodule Valea.Calendar.Ics do
  @moduledoc """
  Hand-written RFC 5545 (iCalendar) parser and recurrence expansion — the
  pure, no-I/O core of the calendar subsystem (Spec F, §The ICS parser).

  Scope and posture:

    * Tokenizer: line unfolding (CRLF or LF, continuation = one leading
      space OR tab), `NAME;PARAM=val;PARAM="quoted":value` splitting, and
      backslash unescaping (`\\n`/`\\N`, `\\,`, `\\;`, `\\\\`) applied to
      TEXT values only.
    * Component reader: VCALENDAR → VEVENT list. VTIMEZONE (and any other
      component, VALARM included) is read past, never interpreted. Unknown
      properties and parameters are skipped silently.
    * Fail-soft per component: a malformed VEVENT is skipped, counted, and
      noticed; `acceptable?/2` is the feed-level guard that decides whether
      the response as a whole may replace a mirror.
    * Unsupported recurrence is UNAVAILABLE, never fabricated: an RRULE
      part outside the supported set, a THISANDFUTURE override, or an
      unresolvable TZID makes `expand/5` return `{:unsupported, reason}` —
      NO occurrences are emitted, not even DTSTART.
    * Timezone resolution is ONE chain (`resolve/2`): IANA via tzdata →
      `Valea.Calendar.WindowsZones.to_iana/1` → `{:error, :unknown_tzid}`.
      DST is deterministic: an ambiguous local time takes the EARLIER UTC
      instant; a nonexistent one takes the first instant AFTER the gap —
      applied identically to DTSTART, expansion, EXDATE/RDATE, and
      RECURRENCE-ID canonicalization.
  """

  alias Valea.Calendar.WindowsZones

  defmodule Event do
    @moduledoc """
    One parsed VEVENT. Times are TAGGED VALUES, unresolved until expansion:

        {:date, %Date{}} | {:utc, %DateTime{}} | {:floating, %NaiveDateTime{}}
        | {:zoned, %NaiveDateTime{}, tzid :: String.t()}

    `duration` is integer seconds (from a DURATION property), `rrule` is
    `%{raw: String.t(), parts: [{String.t(), String.t()}] | :invalid}` —
    raw is preserved verbatim for views; parts are validated at expansion
    time, not at parse time, so an unsupported rule still parses into an
    event (its VIEW exists; its occurrences do not).
    """

    defstruct [
      :uid,
      :summary,
      :dtstart,
      :dtend,
      :duration,
      :rrule,
      :rdate,
      :exdate,
      :recurrence_id,
      :thisandfuture,
      :location,
      :description,
      :status,
      :transp,
      :last_modified,
      :sequence,
      :all_day
    ]
  end

  defmodule Feed do
    @moduledoc """
    Result of `Valea.Calendar.Ics.parse/1`: the parseable events plus the
    accounting the feed-level acceptance guard needs (`total_vevents`,
    `malformed`, per-component `notices`).
    """

    defstruct events: [], total_vevents: 0, malformed: 0, notices: []
  end

  @type tagged_time ::
          {:date, Date.t()}
          | {:utc, DateTime.t()}
          | {:floating, NaiveDateTime.t()}
          | {:zoned, NaiveDateTime.t(), String.t()}

  @type occurrence ::
          %{all_day: false, start: DateTime.t(), end: DateTime.t(), event: Event.t()}
          | %{all_day: true, start_date: Date.t(), end_date: Date.t(), event: Event.t()}

  @iteration_cap 100_000
  @utc_db Calendar.UTCOnlyTimeZoneDatabase
  @supported_rrule_parts ~w(FREQ COUNT UNTIL INTERVAL BYDAY BYMONTHDAY BYMONTH BYSETPOS WKST)
  @day_numbers %{"MO" => 1, "TU" => 2, "WE" => 3, "TH" => 4, "FR" => 5, "SA" => 6, "SU" => 7}

  # ------------------------------------------------------------------ parse

  @doc """
  Parses raw ICS bytes into a `%Feed{}`.

  `{:error, :not_ics}` when no VCALENDAR wrapper parses at all (an HTML
  error page served as 200). A malformed VEVENT increments `malformed`,
  appends a notice, and is skipped — parsing itself never fails on one
  bad component.
  """
  @spec parse(binary()) :: {:ok, %Feed{}} | {:error, :not_ics}
  def parse(binary) when is_binary(binary) do
    lines =
      binary
      |> split_lines()
      |> unfold()
      |> Enum.flat_map(fn line ->
        case parse_line(line) do
          {:ok, parsed} -> [parsed]
          :skip -> []
        end
      end)

    has_vcalendar? =
      Enum.any?(lines, fn {name, _params, value} ->
        name == "BEGIN" and String.upcase(value) == "VCALENDAR"
      end)

    if has_vcalendar? do
      {:ok, walk(lines)}
    else
      {:error, :not_ics}
    end
  end

  defp split_lines(binary) do
    binary
    |> String.split("\n")
    |> Enum.map(&String.trim_trailing(&1, "\r"))
  end

  # RFC 5545 unfolding: a physical line starting with SPACE or HTAB is a
  # continuation of the previous line, minus that one octet.
  defp unfold(lines) do
    lines
    |> Enum.reduce([], fn
      <<c, rest::binary>>, [prev | acc] when c in [?\s, ?\t] -> [prev <> rest | acc]
      line, acc -> [line | acc]
    end)
    |> Enum.reverse()
  end

  # "NAME;PARAM=val;PARAM="quoted":value" → {NAME, params, value}.
  # The first ":" outside DQUOTEs splits value; ";" outside DQUOTEs splits
  # parameters. Lines without a ":" are skipped (blank lines, shredded
  # fragments) — truncation is caught by the unterminated-VEVENT rule.
  defp parse_line(line) do
    case split_outside_quotes(line, ?:) do
      {left, value} ->
        [name | params] = split_all_outside_quotes(left, ?;)

        params =
          Map.new(params, fn param ->
            case String.split(param, "=", parts: 2) do
              [k, v] -> {String.upcase(k), unquote_param(v)}
              [k] -> {String.upcase(k), ""}
            end
          end)

        {:ok, {String.upcase(name), params, value}}

      :none ->
        :skip
    end
  end

  defp unquote_param(<<?", rest::binary>>) do
    case :binary.split(rest, "\"") do
      [inner, _] -> inner
      [inner] -> inner
    end
  end

  defp unquote_param(v), do: v

  defp split_outside_quotes(binary, sep), do: split_outside_quotes(binary, sep, false, [])

  defp split_outside_quotes(<<>>, _sep, _quoted, _acc), do: :none

  defp split_outside_quotes(<<?", rest::binary>>, sep, quoted, acc),
    do: split_outside_quotes(rest, sep, not quoted, [?" | acc])

  defp split_outside_quotes(<<c, rest::binary>>, sep, false, acc) when c == sep,
    do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp split_outside_quotes(<<c, rest::binary>>, sep, quoted, acc),
    do: split_outside_quotes(rest, sep, quoted, [c | acc])

  defp split_all_outside_quotes(binary, sep) do
    case split_outside_quotes(binary, sep) do
      :none -> [binary]
      {head, rest} -> [head | split_all_outside_quotes(rest, sep)]
    end
  end

  # Component walk. VEVENTs directly under VCALENDAR are collected; any
  # sub-component (VALARM, even a stray nested VEVENT) is read past.
  defp walk(lines) do
    state = %{stack: [], props: nil, depth: 0, feed: %Feed{}, index: 0}

    state = Enum.reduce(lines, state, &walk_line/2)

    %Feed{} =
      feed =
      case state.props do
        nil -> state.feed
        _open -> reject_event(state.feed, state.index, "unterminated VEVENT")
      end

    %Feed{feed | events: Enum.reverse(feed.events), notices: Enum.reverse(feed.notices)}
  end

  defp walk_line({name, params, value}, state) do
    case name do
      "BEGIN" -> begin_component(String.upcase(value), state)
      "END" -> end_component(String.upcase(value), state)
      _ -> collect_prop(name, params, value, state)
    end
  end

  defp begin_component(comp, state) do
    stack = [comp | state.stack]
    state = %{state | stack: stack}

    if comp == "VEVENT" and tl(stack) != [] and hd(tl(stack)) == "VCALENDAR" and
         state.props == nil do
      %Feed{} = feed = state.feed
      feed = %Feed{feed | total_vevents: feed.total_vevents + 1}
      %{state | props: [], depth: length(stack), feed: feed, index: state.index + 1}
    else
      state
    end
  end

  defp end_component(comp, state) do
    if comp in state.stack do
      close_until(comp, state)
    else
      state
    end
  end

  defp close_until(comp, state) do
    [top | rest] = state.stack
    state = %{state | stack: rest}

    state =
      if state.props != nil and top == "VEVENT" and length(state.stack) == state.depth - 1 do
        feed = finalize_event(state.feed, state.index, Enum.reverse(state.props))
        %{state | props: nil, depth: 0, feed: feed}
      else
        state
      end

    if top == comp, do: state, else: close_until(comp, state)
  end

  defp collect_prop(name, params, value, state) do
    if state.props != nil and length(state.stack) == state.depth do
      %{state | props: [{name, params, value} | state.props]}
    else
      state
    end
  end

  defp finalize_event(%Feed{} = feed, index, props) do
    case build_event(props) do
      {:ok, event} -> %Feed{feed | events: [event | feed.events]}
      {:error, reason} -> vevent_notice(feed, index, reason)
    end
  end

  defp reject_event(%Feed{} = feed, index, reason), do: vevent_notice(feed, index, reason)

  defp vevent_notice(%Feed{} = feed, index, reason) do
    %Feed{
      feed
      | malformed: feed.malformed + 1,
        notices: ["VEVENT #{index}: #{reason}" | feed.notices]
    }
  end

  # ------------------------------------------------------------ build_event

  defp build_event(props) do
    by_name = Enum.group_by(props, fn {name, _, _} -> name end)

    with {:ok, uid} <- required_text(by_name, "UID", "missing UID"),
         {:ok, dtstart} <- required_time(by_name, "DTSTART"),
         {:ok, dtend} <- optional_time(by_name, "DTEND"),
         :ok <- check_end_type(dtstart, dtend),
         {:ok, duration} <- optional_duration(by_name),
         {:ok, recurrence_id, thisandfuture} <- optional_recurrence_id(by_name),
         {:ok, exdate} <- time_list(by_name, "EXDATE"),
         {:ok, rdate} <- time_list(by_name, "RDATE") do
      {:ok,
       %Event{
         uid: uid,
         summary: last_text(by_name, "SUMMARY"),
         dtstart: dtstart,
         dtend: dtend,
         duration: duration,
         rrule: parse_rrule(by_name),
         rdate: rdate,
         exdate: exdate,
         recurrence_id: recurrence_id,
         thisandfuture: thisandfuture,
         location: last_text(by_name, "LOCATION"),
         description: last_text(by_name, "DESCRIPTION"),
         status: last_token(by_name, "STATUS"),
         transp: last_token(by_name, "TRANSP"),
         last_modified: lenient_time(by_name, "LAST-MODIFIED"),
         sequence: lenient_int(by_name, "SEQUENCE"),
         all_day: match?({:date, _}, dtstart)
       }}
    end
  end

  defp last_prop(by_name, name) do
    case by_name do
      %{^name => props} -> List.last(props)
      _ -> nil
    end
  end

  defp required_text(by_name, name, missing_reason) do
    case last_prop(by_name, name) do
      nil ->
        {:error, missing_reason}

      {_, _, value} ->
        case unescape_text(value) do
          "" -> {:error, missing_reason}
          text -> {:ok, text}
        end
    end
  end

  defp last_text(by_name, name) do
    case last_prop(by_name, name) do
      nil -> nil
      {_, _, value} -> unescape_text(value)
    end
  end

  defp last_token(by_name, name) do
    case last_prop(by_name, name) do
      nil -> nil
      {_, _, value} -> value |> String.trim() |> String.upcase()
    end
  end

  defp required_time(by_name, name) do
    case last_prop(by_name, name) do
      nil ->
        {:error, "missing #{name}"}

      {_, params, value} ->
        case parse_time(value, params) do
          {:ok, tagged} -> {:ok, tagged}
          :error -> {:error, "invalid #{name}"}
        end
    end
  end

  defp optional_time(by_name, name) do
    case last_prop(by_name, name) do
      nil ->
        {:ok, nil}

      {_, params, value} ->
        case parse_time(value, params) do
          {:ok, tagged} -> {:ok, tagged}
          :error -> {:error, "invalid #{name}"}
        end
    end
  end

  defp lenient_time(by_name, name) do
    case optional_time(by_name, name) do
      {:ok, tagged} -> tagged
      {:error, _} -> nil
    end
  end

  defp lenient_int(by_name, name) do
    with {_, _, value} <- last_prop(by_name, name),
         {n, ""} <- Integer.parse(String.trim(value)) do
      n
    else
      _ -> nil
    end
  end

  defp check_end_type(_dtstart, nil), do: :ok
  defp check_end_type({:date, _}, {:date, _}), do: :ok
  defp check_end_type({:date, _}, _), do: {:error, "DTEND type mismatch"}
  defp check_end_type(_, {:date, _}), do: {:error, "DTEND type mismatch"}
  defp check_end_type(_, _), do: :ok

  defp optional_duration(by_name) do
    case last_prop(by_name, "DURATION") do
      nil ->
        {:ok, nil}

      {_, _, value} ->
        case parse_duration(value) do
          {:ok, seconds} -> {:ok, seconds}
          :error -> {:error, "invalid DURATION"}
        end
    end
  end

  defp optional_recurrence_id(by_name) do
    case last_prop(by_name, "RECURRENCE-ID") do
      nil ->
        {:ok, nil, false}

      {_, params, value} ->
        case parse_time(value, params) do
          {:ok, tagged} ->
            thisandfuture = String.upcase(Map.get(params, "RANGE", "")) == "THISANDFUTURE"
            {:ok, tagged, thisandfuture}

          :error ->
            {:error, "invalid RECURRENCE-ID"}
        end
    end
  end

  defp time_list(by_name, name) do
    props = Map.get(by_name, name, [])

    Enum.reduce_while(props, {:ok, []}, fn {_, params, value}, {:ok, acc} ->
      entries =
        value
        |> String.split(",")
        |> Enum.reduce_while([], fn entry, entry_acc ->
          case parse_time(entry, params) do
            {:ok, tagged} -> {:cont, [tagged | entry_acc]}
            :error -> {:halt, :error}
          end
        end)

      case entries do
        :error -> {:halt, {:error, "invalid #{name}"}}
        list -> {:cont, {:ok, acc ++ Enum.reverse(list)}}
      end
    end)
  end

  defp parse_rrule(by_name) do
    case last_prop(by_name, "RRULE") do
      nil -> nil
      {_, _, value} -> %{raw: value, parts: parse_rrule_parts(value)}
    end
  end

  defp parse_rrule_parts(raw) do
    raw
    |> String.split(";")
    |> Enum.reduce_while([], fn part, acc ->
      case String.split(part, "=", parts: 2) do
        [k, v] when k != "" and v != "" -> {:cont, [{String.upcase(k), v} | acc]}
        _ -> {:halt, :invalid}
      end
    end)
    |> case do
      :invalid -> :invalid
      list -> Enum.reverse(list)
    end
  end

  # ------------------------------------------------------------ value types

  defp parse_time(value, params) do
    cond do
      Map.get(params, "VALUE") == "DATE" -> parse_date(value)
      Regex.match?(~r/^\d{8}$/, value) -> parse_date(value)
      true -> parse_datetime(value, Map.get(params, "TZID"))
    end
  end

  defp parse_date(<<y::binary-size(4), m::binary-size(2), d::binary-size(2)>>) do
    with true <- digits?(y) and digits?(m) and digits?(d),
         {:ok, date} <-
           Date.new(String.to_integer(y), String.to_integer(m), String.to_integer(d)) do
      {:ok, {:date, date}}
    else
      _ -> :error
    end
  end

  defp parse_date(_), do: :error

  defp parse_datetime(value, tzid) do
    case Regex.run(~r/^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})(Z?)$/, value) do
      [_, y, mo, d, h, mi, s, z] ->
        with {:ok, date} <-
               Date.new(String.to_integer(y), String.to_integer(mo), String.to_integer(d)),
             {:ok, time} <-
               Time.new(String.to_integer(h), String.to_integer(mi), String.to_integer(s)) do
          ndt = NaiveDateTime.new!(date, time)

          cond do
            z == "Z" -> {:ok, {:utc, DateTime.from_naive!(ndt, "Etc/UTC", @utc_db)}}
            is_binary(tzid) and tzid != "" -> {:ok, {:zoned, ndt, tzid}}
            true -> {:ok, {:floating, ndt}}
          end
        else
          _ -> :error
        end

      nil ->
        :error
    end
  end

  defp digits?(s), do: Regex.match?(~r/^\d+$/, s)

  @duration_re ~r/^([+-])?P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$/

  defp parse_duration(value) do
    case Regex.run(@duration_re, value) do
      [_ | groups] ->
        [sign, w, d, h, mi, s] = pad_groups(groups, 6)

        if Enum.all?([w, d, h, mi, s], &(&1 == "")) or sign == "-" do
          :error
        else
          seconds =
            int_or_zero(w) * 604_800 + int_or_zero(d) * 86_400 + int_or_zero(h) * 3600 +
              int_or_zero(mi) * 60 + int_or_zero(s)

          {:ok, seconds}
        end

      nil ->
        :error
    end
  end

  defp pad_groups(groups, n), do: groups ++ List.duplicate("", n - length(groups))

  defp int_or_zero(""), do: 0
  defp int_or_zero(s), do: String.to_integer(s)

  # TEXT unescaping, byte-safe (UIDs can be arbitrary bytes).
  defp unescape_text(value), do: unescape_text(value, [])

  defp unescape_text(<<?\\, c, rest::binary>>, acc) do
    replacement =
      case c do
        ?n -> ?\n
        ?N -> ?\n
        ?\\ -> ?\\
        ?, -> ?,
        ?; -> ?;
        other -> [?\\, other]
      end

    unescape_text(rest, [replacement | acc])
  end

  defp unescape_text(<<c, rest::binary>>, acc), do: unescape_text(rest, [c | acc])
  defp unescape_text(<<>>, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  # ---------------------------------------------------------------- resolve

  @doc """
  The ONE timezone resolution. IANA via tzdata → `WindowsZones.to_iana/1`
  → `{:error, :unknown_tzid}` — an unknown TZID is never guessed as local
  or floating time. Floating times resolve against the host zone. DST is
  pinned: ambiguous → EARLIER UTC instant; nonexistent → first instant
  AFTER the gap. Returned datetimes are always in Etc/UTC.
  """
  @spec resolve(tagged_time(), String.t()) ::
          {:ok, DateTime.t()} | {:date, Date.t()} | {:error, :unknown_tzid}
  def resolve({:date, %Date{} = date}, _host_zone), do: {:date, date}
  def resolve({:utc, %DateTime{} = dt}, _host_zone), do: {:ok, to_utc(dt)}

  def resolve({:floating, %NaiveDateTime{} = ndt}, host_zone),
    do: wall_to_utc(ndt, host_zone)

  def resolve({:zoned, %NaiveDateTime{} = ndt, tzid}, _host_zone) do
    case wall_to_utc(ndt, tzid) do
      {:error, :unknown_tzid} ->
        case WindowsZones.to_iana(tzid) do
          {:ok, zone} -> wall_to_utc(ndt, zone)
          :error -> {:error, :unknown_tzid}
        end

      ok ->
        ok
    end
  end

  defp wall_to_utc(ndt, zone) do
    case DateTime.from_naive(ndt, zone) do
      {:ok, dt} -> {:ok, to_utc(dt)}
      {:ambiguous, earlier, _later} -> {:ok, to_utc(earlier)}
      {:gap, _just_before, just_after} -> {:ok, to_utc(just_after)}
      {:error, _} -> {:error, :unknown_tzid}
    end
  end

  defp to_utc(%DateTime{} = dt) do
    {:ok, utc} = DateTime.shift_zone(dt, "Etc/UTC", @utc_db)
    utc
  end

  # ------------------------------------------------------------- identities

  @doc """
  Canonical RECURRENCE-ID string: `""` for masters, UTC ISO8601 for timed
  values, the ISO date for all-day — resolved via `resolve/2`. An
  unresolvable TZID falls back to the raw naive ISO plus `@tzid` (stable
  and collision-free; such series are unsupported anyway, but their views
  still need a deterministic id).
  """
  @spec canonical_recurrence_id(Event.t(), String.t()) :: String.t()
  def canonical_recurrence_id(%Event{recurrence_id: nil}, _host_zone), do: ""

  def canonical_recurrence_id(%Event{recurrence_id: rid}, host_zone) do
    case resolve(rid, host_zone) do
      {:ok, dt} -> DateTime.to_iso8601(dt)
      {:date, date} -> Date.to_iso8601(date)
      {:error, :unknown_tzid} -> unresolved_rid(rid)
    end
  end

  defp unresolved_rid({:zoned, ndt, tzid}), do: NaiveDateTime.to_iso8601(ndt) <> "@" <> tzid
  defp unresolved_rid({:floating, ndt}), do: NaiveDateTime.to_iso8601(ndt)

  @doc """
  Stable per-view id: `"ev-"` plus the first 16 hex chars of
  `sha256(slug <> "\\0" <> uid <> "\\0" <> canonical_rid)`. External UIDs
  are arbitrary, possibly hostile bytes — they never become filename
  material directly.
  """
  @spec view_id(String.t(), String.t(), String.t()) :: String.t()
  def view_id(slug, uid, canonical_rid)
      when is_binary(slug) and is_binary(uid) and is_binary(canonical_rid) do
    hash =
      :crypto.hash(:sha256, [slug, 0, uid, 0, canonical_rid])
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    "ev-" <> hash
  end

  # ------------------------------------------------------------- acceptance

  @doc """
  Feed-level acceptance guard (error-page-as-200 and truncation guards):

    * `{:error, :zero_parseable}` when the feed has zero parseable events
      where the previous snapshot had events;
    * `{:error, :too_many_malformed}` when at least 2 VEVENTs are malformed
      AND they exceed 20% of the response's VEVENT components.

  A legitimately shrunken feed — fewer events, all parseable — passes; the
  guard keys on parse failures, never on event-count reduction.
  """
  @spec acceptable?(%Feed{}, boolean()) :: :ok | {:error, :zero_parseable | :too_many_malformed}
  def acceptable?(%Feed{} = feed, previous_had_events?) do
    cond do
      feed.events == [] and previous_had_events? ->
        {:error, :zero_parseable}

      feed.malformed >= 2 and feed.malformed > 0.2 * feed.total_vevents ->
        {:error, :too_many_malformed}

      true ->
        :ok
    end
  end

  # --------------------------------------------------------------- expand/5

  @doc """
  Expands one master VEVENT (plus its same-UID override VEVENTs) into
  concrete occurrences overlapping the window `[from 00:00, to+1 00:00)`
  in `host_zone` (inclusive dates). Timed occurrences are UTC instants;
  all-day occurrences are plain dates with an EXCLUSIVE end.

  Override matching happens on CANONICAL INSTANTS (all-day compares as
  plain dates, floating only against floating); an unmatched override is
  emitted as a standalone occurrence with a notice. `{:unsupported, reason}`
  covers unsupported RRULE parts, THISANDFUTURE overrides, unknown TZIDs,
  and the iteration cap — in every such case NO occurrences are emitted.
  """
  @spec expand(Event.t(), [Event.t()], Date.t(), Date.t(), String.t()) ::
          {:ok, [occurrence()], [String.t()]} | {:unsupported, String.t()}
  def expand(%Event{} = master, overrides, %Date{} = from, %Date{} = to, host_zone)
      when is_list(overrides) and is_binary(host_zone) do
    cond do
      cancelled?(master) ->
        {:ok, [], []}

      Enum.any?([master | overrides], & &1.thisandfuture) ->
        {:unsupported, "THISANDFUTURE override"}

      true ->
        try do
          do_expand(master, overrides, from, to, host_zone)
        catch
          {:unsupported, reason} -> {:unsupported, reason}
        end
    end
  end

  defp cancelled?(%Event{status: status}), do: status == "CANCELLED"

  defp do_expand(master, overrides, from, to, host_zone) do
    {records, notices} =
      case master.dtstart do
        {:date, _} -> expand_all_day(master, overrides, from, to, host_zone)
        _ -> expand_timed(master, overrides, from, to, host_zone)
      end

    occurrences =
      records
      |> Enum.filter(&in_window?(&1, from, to, host_zone))
      |> Enum.sort_by(&sort_key/1)
      |> Enum.map(&Map.delete(&1, :key))

    {:ok, occurrences, notices}
  end

  defp sort_key(%{all_day: false, start: start}), do: {DateTime.to_unix(start), 0}

  defp sort_key(%{all_day: true, start_date: date}),
    do: {Date.diff(date, ~D[1970-01-01]) * 86_400, -1}

  # ------------------------------------------------------------ timed series

  defp expand_timed(master, overrides, _from, to, host_zone) do
    {start_ndt, frame} = timed_frame(master.dtstart, host_zone)
    start_date = NaiveDateTime.to_date(start_ndt)
    time_of_day = NaiveDateTime.to_time(start_ndt)
    duration = master_duration_seconds(master, host_zone)

    window_end = window_instant(Date.add(to, 1), host_zone)
    stop_date = Date.add(local_date(window_end, frame), 1)

    resolve_candidate = fn date ->
      resolve_frame!(NaiveDateTime.new!(date, time_of_day), frame)
    end

    beyond_until? = build_beyond_until(master, start_ndt, resolve_candidate)
    dates = rule_dates(master, start_date, stop_date, beyond_until?)

    records =
      Enum.map(dates, fn date ->
        start_utc = resolve_candidate.(date)

        %{
          all_day: false,
          start: start_utc,
          end: DateTime.add(start_utc, duration, :second, @utc_db),
          key: {frame.class, DateTime.to_unix(start_utc)},
          event: master
        }
      end)

    records = apply_exdate(records, master, host_zone)
    records = apply_rdate(records, master, duration, host_zone)
    apply_overrides(records, overrides, host_zone)
  end

  defp timed_frame({:zoned, ndt, tzid}, _host_zone),
    do: {ndt, %{class: :abs, zone: iana_zone!(tzid, ndt)}}

  defp timed_frame({:utc, dt}, _host_zone),
    do: {DateTime.to_naive(dt), %{class: :abs, zone: :utc}}

  defp timed_frame({:floating, ndt}, host_zone) do
    case wall_to_utc(ndt, host_zone) do
      {:ok, _} -> {ndt, %{class: :float, zone: host_zone}}
      {:error, :unknown_tzid} -> throw({:unsupported, "unknown TZID " <> host_zone})
    end
  end

  defp iana_zone!(tzid, probe_ndt) do
    case wall_to_utc(probe_ndt, tzid) do
      {:ok, _} ->
        tzid

      {:error, :unknown_tzid} ->
        with {:ok, zone} <- WindowsZones.to_iana(tzid),
             {:ok, _} <- wall_to_utc(probe_ndt, zone) do
          zone
        else
          _ -> throw({:unsupported, "unknown TZID " <> tzid})
        end
    end
  end

  defp resolve_frame!(ndt, %{zone: :utc}), do: DateTime.from_naive!(ndt, "Etc/UTC", @utc_db)

  defp resolve_frame!(ndt, %{zone: zone}) do
    case wall_to_utc(ndt, zone) do
      {:ok, dt} -> dt
      {:error, :unknown_tzid} -> throw({:unsupported, "unknown TZID " <> zone})
    end
  end

  defp master_duration_seconds(master, host_zone) do
    cond do
      master.dtend != nil ->
        start_utc = resolve_instant!(master.dtstart, host_zone)
        end_utc = resolve_instant!(master.dtend, host_zone)
        max(DateTime.diff(end_utc, start_utc), 0)

      is_integer(master.duration) ->
        max(master.duration, 0)

      true ->
        0
    end
  end

  defp resolve_instant!(tagged, host_zone) do
    case resolve(tagged, host_zone) do
      {:ok, dt} -> dt
      {:date, _} -> throw({:unsupported, "mixed DATE and DATE-TIME values"})
      {:error, :unknown_tzid} -> throw({:unsupported, "unknown TZID " <> tzid_of(tagged)})
    end
  end

  defp tzid_of({:zoned, _, tzid}), do: tzid
  defp tzid_of(_), do: "?"

  defp window_instant(date, host_zone) do
    case wall_to_utc(NaiveDateTime.new!(date, ~T[00:00:00]), host_zone) do
      {:ok, dt} -> dt
      {:error, :unknown_tzid} -> throw({:unsupported, "unknown TZID " <> host_zone})
    end
  end

  defp local_date(utc_dt, %{zone: :utc}), do: DateTime.to_date(utc_dt)

  defp local_date(utc_dt, %{zone: zone}),
    do: DateTime.shift_zone!(utc_dt, zone) |> DateTime.to_date()

  # ---------------------------------------------------------- all-day series

  defp expand_all_day(master, overrides, _from, to, host_zone) do
    {:date, start_date} = master.dtstart
    span = all_day_span(master, start_date)
    stop_date = Date.add(to, 2)

    beyond_until? = build_beyond_until(master, NaiveDateTime.new!(start_date, ~T[00:00:00]), nil)
    dates = rule_dates(master, start_date, stop_date, beyond_until?)

    records =
      Enum.map(dates, fn date ->
        %{
          all_day: true,
          start_date: date,
          end_date: Date.add(date, span),
          key: {:date, date},
          event: master
        }
      end)

    records = apply_exdate(records, master, host_zone)
    records = apply_rdate(records, master, span, host_zone)
    apply_overrides(records, overrides, host_zone)
  end

  defp all_day_span(master, start_date) do
    cond do
      match?({:date, _}, master.dtend) ->
        {:date, end_date} = master.dtend
        max(Date.diff(end_date, start_date), 1)

      is_integer(master.duration) ->
        max(div(master.duration, 86_400), 1)

      true ->
        1
    end
  end

  # ------------------------------------------------------- EXDATE and RDATE

  defp apply_exdate(records, master, host_zone) do
    exclusions = MapSet.new(master.exdate || [], &canonical_key!(&1, host_zone))
    Enum.reject(records, &MapSet.member?(exclusions, &1.key))
  end

  defp apply_rdate(records, master, duration_or_span, host_zone) do
    existing = MapSet.new(records, & &1.key)

    Enum.reduce(master.rdate || [], {records, existing}, fn tagged, {acc, seen} ->
      key = canonical_key!(tagged, host_zone)

      cond do
        MapSet.member?(seen, key) ->
          {acc, seen}

        not type_matches_series?(tagged, master) ->
          {acc, seen}

        true ->
          record = rdate_record(tagged, master, duration_or_span, host_zone, key)
          {acc ++ [record], MapSet.put(seen, key)}
      end
    end)
    |> elem(0)
  end

  defp type_matches_series?({:date, _}, %Event{dtstart: {:date, _}}), do: true
  defp type_matches_series?({:date, _}, _), do: false
  defp type_matches_series?(_, %Event{dtstart: {:date, _}}), do: false
  defp type_matches_series?(_, _), do: true

  defp rdate_record({:date, date}, master, span, _host_zone, key) do
    %{all_day: true, start_date: date, end_date: Date.add(date, span), key: key, event: master}
  end

  defp rdate_record(tagged, master, duration, host_zone, key) do
    start_utc = resolve_instant!(tagged, host_zone)

    %{
      all_day: false,
      start: start_utc,
      end: DateTime.add(start_utc, duration, :second, @utc_db),
      key: key,
      event: master
    }
  end

  # Canonical matching keys: all-day compares as plain dates, floating only
  # against floating, absolute (UTC or zoned) as UTC instants.
  defp canonical_key!({:date, date}, _host_zone), do: {:date, date}

  defp canonical_key!(tagged, host_zone) do
    class = if match?({:floating, _}, tagged), do: :float, else: :abs

    case resolve(tagged, host_zone) do
      {:ok, dt} -> {class, DateTime.to_unix(dt)}
      {:error, :unknown_tzid} -> throw({:unsupported, "unknown TZID " <> tzid_of(tagged)})
    end
  end

  # -------------------------------------------------------------- overrides

  defp apply_overrides(records, overrides, host_zone) do
    Enum.reduce(overrides, {records, []}, fn override, {acc, notices} ->
      rid_key = canonical_key!(override.recurrence_id, host_zone)
      index = Enum.find_index(acc, &(&1.key == rid_key))

      cond do
        index != nil and cancelled?(override) ->
          {List.delete_at(acc, index), notices}

        index != nil ->
          record = override |> single_record!(host_zone) |> Map.put(:key, rid_key)
          {List.replace_at(acc, index, record), notices}

        cancelled?(override) ->
          {acc, notices ++ [unmatched_notice(override, host_zone)]}

        true ->
          record = override |> single_record!(host_zone) |> Map.put(:key, rid_key)
          {acc ++ [record], notices ++ [unmatched_notice(override, host_zone)]}
      end
    end)
  end

  defp single_record!(event, host_zone) do
    case event.dtstart do
      {:date, start_date} ->
        %{
          all_day: true,
          start_date: start_date,
          end_date: Date.add(start_date, all_day_span(event, start_date)),
          event: event
        }

      _ ->
        start_utc = resolve_instant!(event.dtstart, host_zone)
        duration = master_duration_seconds(event, host_zone)

        %{
          all_day: false,
          start: start_utc,
          end: DateTime.add(start_utc, duration, :second, @utc_db),
          event: event
        }
    end
  end

  defp unmatched_notice(override, host_zone) do
    "override " <>
      sanitize(override.uid) <>
      " at " <> canonical_recurrence_id(override, host_zone) <> " matches no occurrence"
  end

  # Notices reach status surfaces; external UIDs are arbitrary bytes, so
  # keep printable ASCII only and truncate.
  defp sanitize(nil), do: "?"

  defp sanitize(binary) do
    binary
    |> :binary.bin_to_list()
    |> Enum.filter(&(&1 in 32..126))
    |> Enum.take(60)
    |> List.to_string()
  end

  # ----------------------------------------------------------------- window

  defp in_window?(%{all_day: true, start_date: start_date, end_date: end_date}, from, to, _zone) do
    Date.compare(start_date, to) != :gt and Date.compare(end_date, from) == :gt
  end

  defp in_window?(%{all_day: false, start: start, end: end_}, from, to, host_zone) do
    window_start = window_instant(from, host_zone)
    window_end = window_instant(Date.add(to, 1), host_zone)

    DateTime.compare(start, window_end) == :lt and
      (DateTime.compare(end_, window_start) == :gt or
         (DateTime.compare(end_, start) == :eq and
            DateTime.compare(start, window_start) != :lt))
  end

  # -------------------------------------------------------- rule generation

  defp rule_dates(%Event{rrule: nil}, start_date, _stop_date, _beyond?), do: [start_date]

  defp rule_dates(%Event{rrule: %{parts: :invalid}}, _start, _stop, _beyond?),
    do: throw({:unsupported, "invalid RRULE"})

  defp rule_dates(%Event{rrule: %{parts: parts}}, start_date, stop_date, beyond_until?) do
    config = rule_config(parts, start_date)
    generate(0, config, start_date, stop_date, beyond_until?, config.count, 0, [])
  end

  defp build_beyond_until(%Event{rrule: %{parts: parts}} = master, start_ndt, resolve_candidate)
       when is_list(parts) do
    case List.keyfind(parts, "UNTIL", 0) do
      nil ->
        fn _date -> false end

      {"UNTIL", value} ->
        until_predicate(parse_until!(value), master, start_ndt, resolve_candidate)
    end
  end

  defp build_beyond_until(_master, _start_ndt, _resolve), do: fn _date -> false end

  defp parse_until!(value) do
    case parse_time(value, %{}) do
      {:ok, tagged} -> tagged
      :error -> throw({:unsupported, "invalid RRULE"})
    end
  end

  defp until_predicate({:date, until_date}, _master, _start_ndt, _resolve) do
    fn date -> Date.compare(date, until_date) == :gt end
  end

  defp until_predicate({:floating, until_ndt}, _master, start_ndt, _resolve) do
    time_of_day = NaiveDateTime.to_time(start_ndt)

    fn date ->
      NaiveDateTime.compare(NaiveDateTime.new!(date, time_of_day), until_ndt) == :gt
    end
  end

  defp until_predicate({:utc, until_dt}, %Event{dtstart: {:date, _}}, _start_ndt, _resolve) do
    until_date = DateTime.to_date(until_dt)
    fn date -> Date.compare(date, until_date) == :gt end
  end

  defp until_predicate({:utc, until_dt}, _master, _start_ndt, resolve_candidate) do
    fn date -> DateTime.compare(resolve_candidate.(date), until_dt) == :gt end
  end

  defp rule_config(parts, start_date) do
    Enum.each(parts, fn {name, _value} ->
      unless name in @supported_rrule_parts do
        throw({:unsupported, "rrule part " <> name})
      end
    end)

    map = Map.new(parts)
    freq = parse_freq!(map)
    interval = positive_int!(Map.get(map, "INTERVAL", "1"))
    count = optional_positive_int!(Map.get(map, "COUNT"))
    byday = Enum.map(csv(Map.get(map, "BYDAY")), &byday_entry!/1)
    bymonthday = Enum.map(csv(Map.get(map, "BYMONTHDAY")), &ranged_int!(&1, 31))
    bymonth = Enum.map(csv(Map.get(map, "BYMONTH")), &month_int!/1)
    bysetpos = Enum.map(csv(Map.get(map, "BYSETPOS")), &ranged_int!(&1, 366))
    wkst = wkst!(Map.get(map, "WKST", "MO"))

    if freq in [:daily, :weekly] and Enum.any?(byday, fn {ordinal, _} -> ordinal != nil end) do
      throw({:unsupported, "rrule BYDAY ordinal with FREQ=#{String.upcase(to_string(freq))}"})
    end

    if freq == :weekly and bymonthday != [] do
      throw({:unsupported, "rrule BYMONTHDAY with FREQ=WEEKLY"})
    end

    %{
      freq: freq,
      interval: interval,
      count: count,
      byday: byday,
      bymonthday: bymonthday,
      bymonth: bymonth,
      bysetpos: bysetpos,
      wkst: wkst,
      start_date: start_date
    }
  end

  defp parse_freq!(map) do
    case Map.fetch(map, "FREQ") do
      :error ->
        throw({:unsupported, "rrule missing FREQ"})

      {:ok, value} ->
        case String.upcase(value) do
          "DAILY" ->
            :daily

          "WEEKLY" ->
            :weekly

          "MONTHLY" ->
            :monthly

          "YEARLY" ->
            :yearly

          sub when sub in ["SECONDLY", "MINUTELY", "HOURLY"] ->
            throw({:unsupported, "rrule FREQ " <> sub})

          _ ->
            throw({:unsupported, "invalid RRULE"})
        end
    end
  end

  defp csv(nil), do: []
  defp csv(value), do: String.split(value, ",")

  defp strict_int!(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> throw({:unsupported, "invalid RRULE"})
    end
  end

  defp positive_int!(value) do
    case strict_int!(value) do
      n when n >= 1 -> n
      _ -> throw({:unsupported, "invalid RRULE"})
    end
  end

  defp optional_positive_int!(nil), do: nil
  defp optional_positive_int!(value), do: positive_int!(value)

  defp ranged_int!(value, limit) do
    case strict_int!(value) do
      0 -> throw({:unsupported, "invalid RRULE"})
      n when abs(n) <= limit -> n
      _ -> throw({:unsupported, "invalid RRULE"})
    end
  end

  defp month_int!(value) do
    case strict_int!(value) do
      n when n in 1..12 -> n
      _ -> throw({:unsupported, "invalid RRULE"})
    end
  end

  defp byday_entry!(value) do
    case Regex.run(~r/^([+-]?\d{1,2})?(MO|TU|WE|TH|FR|SA|SU)$/, value) do
      [_, "", day] ->
        {nil, Map.fetch!(@day_numbers, day)}

      [_, ordinal, day] ->
        case String.to_integer(ordinal) do
          0 -> throw({:unsupported, "invalid RRULE"})
          n -> {n, Map.fetch!(@day_numbers, day)}
        end

      nil ->
        throw({:unsupported, "invalid RRULE"})
    end
  end

  defp wkst!(value) do
    case Map.fetch(@day_numbers, String.upcase(value)) do
      {:ok, n} -> n
      :error -> throw({:unsupported, "invalid RRULE"})
    end
  end

  # Iterative generation, one interval period at a time, hard-capped.
  defp generate(period, config, start_date, stop_date, beyond?, remaining, iterations, acc) do
    iterations = bump_iterations(iterations, 1)
    period_start = period_start(config, start_date, period)

    cond do
      remaining == 0 ->
        Enum.reverse(acc)

      Date.compare(period_start, stop_date) == :gt ->
        Enum.reverse(acc)

      true ->
        candidates = period_candidates(config, start_date, period_start)
        iterations = bump_iterations(iterations, length(candidates))

        candidates =
          candidates
          |> apply_bysetpos(config.bysetpos)
          |> seed_start(period == 0, start_date)
          |> Enum.filter(&(Date.compare(&1, start_date) != :lt))
          |> Enum.sort(Date)
          |> Enum.dedup()

        {taken, remaining, halted?} = take_candidates(candidates, remaining, beyond?)
        acc = Enum.reverse(taken) ++ acc

        if halted? do
          Enum.reverse(acc)
        else
          generate(period + 1, config, start_date, stop_date, beyond?, remaining, iterations, acc)
        end
    end
  end

  defp bump_iterations(iterations, n) do
    iterations = iterations + n
    if iterations > @iteration_cap, do: throw({:unsupported, "iteration cap"})
    iterations
  end

  defp seed_start(candidates, false, _start_date), do: candidates
  defp seed_start(candidates, true, start_date), do: [start_date | candidates]

  defp take_candidates(candidates, remaining, beyond?) do
    Enum.reduce_while(candidates, {[], remaining, false}, fn date, {taken, left, _halted} ->
      cond do
        left == 0 -> {:halt, {taken, 0, true}}
        beyond?.(date) -> {:halt, {taken, left, true}}
        true -> {:cont, {[date | taken], decrement(left), false}}
      end
    end)
  end

  defp decrement(nil), do: nil
  defp decrement(n), do: n - 1

  defp period_start(%{freq: :daily, interval: interval}, start_date, k),
    do: Date.add(start_date, k * interval)

  defp period_start(%{freq: :weekly, interval: interval, wkst: wkst}, start_date, k),
    do: Date.add(week_start(start_date, wkst), k * interval * 7)

  defp period_start(%{freq: :monthly, interval: interval}, start_date, k) do
    {year, month} = shift_month(start_date.year, start_date.month, k * interval)
    Date.new!(year, month, 1)
  end

  defp period_start(%{freq: :yearly, interval: interval}, start_date, k),
    do: Date.new!(start_date.year + k * interval, 1, 1)

  defp week_start(date, wkst),
    do: Date.add(date, -rem(Date.day_of_week(date) - wkst + 7, 7))

  defp shift_month(year, month, delta) do
    total = year * 12 + (month - 1) + delta
    {div(total, 12), rem(total, 12) + 1}
  end

  defp period_candidates(%{freq: :daily} = config, _start_date, period_start) do
    if daily_match?(config, period_start), do: [period_start], else: []
  end

  defp period_candidates(%{freq: :weekly} = config, start_date, period_start) do
    days =
      case config.byday do
        [] -> [Date.day_of_week(start_date)]
        byday -> Enum.map(byday, fn {nil, day} -> day end)
      end

    for offset <- 0..6,
        date = Date.add(period_start, offset),
        Date.day_of_week(date) in days,
        month_allowed?(config, date.month) do
      date
    end
  end

  defp period_candidates(%{freq: :monthly} = config, start_date, period_start) do
    monthly_candidates(config, start_date, period_start.year, period_start.month)
  end

  defp period_candidates(%{freq: :yearly} = config, start_date, period_start) do
    yearly_candidates(config, start_date, period_start.year)
  end

  defp daily_match?(config, date) do
    month_allowed?(config, date.month) and
      (config.bymonthday == [] or monthday_match?(date, config.bymonthday)) and
      (config.byday == [] or
         Date.day_of_week(date) in Enum.map(config.byday, fn {nil, day} -> day end))
  end

  defp month_allowed?(%{bymonth: []}, _month), do: true
  defp month_allowed?(%{bymonth: bymonth}, month), do: month in bymonth

  defp monthday_match?(date, bymonthday) do
    days_in_month = Date.days_in_month(date)

    Enum.any?(bymonthday, fn
      n when n > 0 -> date.day == n
      n -> date.day == days_in_month + n + 1
    end)
  end

  defp monthly_candidates(config, start_date, year, month) do
    cond do
      not month_allowed?(config, month) ->
        []

      config.bymonthday != [] ->
        days = expand_monthdays(year, month, config.bymonthday)

        if config.byday == [] do
          days
        else
          limit = MapSet.new(byday_dates(year, month, config.byday))
          Enum.filter(days, &MapSet.member?(limit, &1))
        end

      config.byday != [] ->
        byday_dates(year, month, config.byday)

      true ->
        case Date.new(year, month, start_date.day) do
          {:ok, date} -> [date]
          {:error, _} -> []
        end
    end
  end

  defp yearly_candidates(config, start_date, year) do
    candidates =
      cond do
        config.byday == [] ->
          months =
            cond do
              config.bymonth != [] -> config.bymonth
              config.bymonthday != [] -> Enum.to_list(1..12)
              true -> [start_date.month]
            end

          Enum.flat_map(months, fn month ->
            if config.bymonthday != [] do
              expand_monthdays(year, month, config.bymonthday)
            else
              case Date.new(year, month, start_date.day) do
                {:ok, date} -> [date]
                {:error, _} -> []
              end
            end
          end)

        config.bymonth != [] ->
          base = Enum.flat_map(config.bymonth, &byday_dates(year, &1, config.byday))

          if config.bymonthday == [] do
            base
          else
            allowed =
              config.bymonth
              |> Enum.flat_map(&expand_monthdays(year, &1, config.bymonthday))
              |> MapSet.new()

            Enum.filter(base, &MapSet.member?(allowed, &1))
          end

        true ->
          base = year_byday_dates(year, config.byday)

          if config.bymonthday == [] do
            base
          else
            allowed =
              Enum.flat_map(1..12, &expand_monthdays(year, &1, config.bymonthday))
              |> MapSet.new()

            Enum.filter(base, &MapSet.member?(allowed, &1))
          end
      end

    candidates |> Enum.sort(Date) |> Enum.dedup()
  end

  defp expand_monthdays(year, month, bymonthday) do
    days_in_month = Date.days_in_month(Date.new!(year, month, 1))

    bymonthday
    |> Enum.map(fn
      n when n > 0 -> n
      n -> days_in_month + n + 1
    end)
    |> Enum.filter(&(&1 >= 1 and &1 <= days_in_month))
    |> Enum.sort()
    |> Enum.dedup()
    |> Enum.map(&Date.new!(year, month, &1))
  end

  # The dates a BYDAY entry denotes within one month: plain `MO` is every
  # Monday; `2MO` the second Monday; `-1FR` the last Friday.
  defp byday_dates(year, month, entries) do
    entries
    |> Enum.flat_map(fn {ordinal, day} ->
      dates = weekday_dates_in_month(year, month, day)

      case ordinal do
        nil -> dates
        n when n > 0 -> List.wrap(Enum.at(dates, n - 1))
        n -> List.wrap(Enum.at(dates, n))
      end
    end)
    |> Enum.sort(Date)
    |> Enum.dedup()
  end

  defp weekday_dates_in_month(year, month, day_of_week) do
    first = Date.new!(year, month, 1)
    days_in_month = Date.days_in_month(first)

    for day <- 1..days_in_month,
        date = Date.new!(year, month, day),
        Date.day_of_week(date) == day_of_week do
      date
    end
  end

  defp year_byday_dates(year, entries) do
    entries
    |> Enum.flat_map(fn {ordinal, day} ->
      dates = weekday_dates_in_year(year, day)

      case ordinal do
        nil -> dates
        n when n > 0 -> List.wrap(Enum.at(dates, n - 1))
        n -> List.wrap(Enum.at(dates, n))
      end
    end)
    |> Enum.sort(Date)
    |> Enum.dedup()
  end

  defp weekday_dates_in_year(year, day_of_week) do
    first = Date.new!(year, 1, 1)
    offset = rem(day_of_week - Date.day_of_week(first) + 7, 7)
    last = Date.new!(year, 12, 31)

    first
    |> Date.add(offset)
    |> Stream.iterate(&Date.add(&1, 7))
    |> Enum.take_while(&(Date.compare(&1, last) != :gt))
  end

  defp apply_bysetpos(candidates, []), do: candidates

  defp apply_bysetpos(candidates, bysetpos) do
    bysetpos
    |> Enum.map(fn
      pos when pos > 0 -> Enum.at(candidates, pos - 1)
      pos -> Enum.at(candidates, pos)
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort(Date)
    |> Enum.dedup()
  end
end
