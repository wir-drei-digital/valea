defmodule Valea.Schedules.Cron do
  @moduledoc """
  The cron cadence behind `schedules.json`: parse an expression once, then ask
  it for the next slot (tasks+schedules spec §Cadence, §Clocks, zones, DST).

  Hand-rolled and dependency-free. The grammar is tiny; its *semantics* are the
  part that must never drift, so they are pinned here and vector-tested rather
  than inherited.

  ## Grammar

      minute  hour  day-of-month  month  day-of-week
       0-59   0-23      1-31      1-12   0-6 (7 = Sunday, folded onto 0)

  A field is `*`, a number, an `a-b` range, a `,`-separated list of those, or a
  `*`/range followed by `/step`. Four aliases stand in for a whole expression:
  `@hourly`, `@daily`, `@weekly` (Sunday 00:00) and `@monthly` (the 1st,
  00:00).

  Deliberately **outside** the grammar, so nobody has to guess which dialect
  this is: three-letter month and weekday names, the `L`/`W`/`#` extensions, a
  seconds or year field, backwards ranges (`30-10`), and a bare `5/10` step
  without a range in front of the `/` (Vixie requires `*` or `a-b`). Everything
  refused comes back as `{:error, reason}` with a human-readable reason, which
  `Valea.Schedules.Entry` turns into a visible `invalid cron` disposition — a
  schedule Valea cannot read must never become a schedule that quietly fires at
  the wrong time.

  ## The Vixie day rule

  Day-of-month and day-of-week are **OR'd when both are restricted** and AND'd
  otherwise: `0 0 13 * 5` fires on the 13th *and* on every Friday, `0 0 13 * *`
  only on the 13th, `0 0 * * 5` only on Fridays.

  "Restricted" is read Vixie's way — off the **first character** — so `*/2`
  counts as a star and does not switch the rule to OR. That is a statement about
  the *rule*, never about the *set*: both sets are always consulted, so
  `0 0 */2 * *` fires on odd days only, and `0 0 */2 * 5` fires on the odd
  Fridays (AND), not on every Friday. `parse/1` records the choice as `day_rule`
  (`:any | :dom | :dow | :either`); only `:either` means OR.

  ## Slots are wall-clock, answers are UTC instants

  Cron fields describe wall-clock times in the schedule's zone, so `next_slot/3`
  walks **days** in that zone — matching month/day-of-month/day-of-week at day
  granularity and jumping to the next midnight when a day cannot match — and
  only then walks that day's `hour`×`minute` slots. Each candidate wall time
  converts to an instant, and two conversions are not one-to-one:

    * **Spring-forward gap** — the wall time does not exist. The slot lands on
      the first instant after the gap (`{:gap, _, just_after}`). Every wall
      minute inside the gap maps to that same instant, and the strictly-after
      test is what collapses them into one fire instead of one per skipped
      minute.
    * **Fall-back ambiguity** — the wall time happens twice. Only the first
      (earlier UTC offset) occurrence is a slot (`{:ambiguous, first, _}`), so
      the second pass over that hour never fires. This is also the case that
      exercises the strictly-after test on a *materialized* instant: anchored
      inside the repeated hour, the wall clock has not passed 02:30 yet, but
      02:30's only instant has.

  `next_slot/3` is **strictly after** its anchor: an anchor sitting exactly on a
  slot returns the following one. That is what makes the scheduler's
  "anchor := slot just fired" loop terminate, and what makes both DST rules
  above self-consistent — an instant already consumed can never come back,
  whichever wall time produced it.

  ## Bounded search

  Walking days rather than minutes makes the search cheap enough to be honest
  about long gaps: `0 0 29 2 *` (29 February — legal standard cron) is a couple
  of thousand day-checks away, not two million minute-checks. Two guards keep it
  total:

    * `parse/1` refuses a day-of-month/month pair **no year has** (30 February,
      31 April) under the AND rule — those would never match at all. February is
      checked against 29, so the quadrennial case stays executable.
    * the walk is capped at #{366 * 41} days and raises past it. The cap is a
      backstop, not a limit anyone should meet: the longest real gap belongs to
      29 February pinned to a single weekday (`0 0 29 2 */7`), which the
      Gregorian century rules can stretch to 40 years. An infinite loop inside a
      scheduler tick is a worse failure than a raise, so the guard stays even
      though exhausting it now costs microseconds.
  """

  @enforce_keys [:minute, :hour, :dom, :month, :dow, :day_rule]
  defstruct [:minute, :hour, :dom, :month, :dow, :day_rule]

  @type t :: %__MODULE__{
          minute: MapSet.t(non_neg_integer()),
          hour: MapSet.t(non_neg_integer()),
          dom: MapSet.t(pos_integer()),
          month: MapSet.t(pos_integer()),
          dow: MapSet.t(non_neg_integer()),
          day_rule: :any | :dom | :dow | :either
        }

  @aliases %{
    "hourly" => "0 * * * *",
    "daily" => "0 0 * * *",
    "weekly" => "0 0 * * 0",
    "monthly" => "0 0 1 * *"
  }

  @minute 0..59
  @hour 0..23
  @dom 1..31
  @month 1..12
  # Parsed over 0..7 so `7` is accepted, then folded onto 0.
  @dow 0..7

  @minutes_per_day 24 * 60
  @max_days 366 * 41

  @doc """
  Parses a cron expression (or an alias) into a `t:t/0`.

  Takes any term — a `schedules.json` `cron` field is whatever the file holds —
  and answers `{:error, reason}` for anything that isn't a string in the grammar
  above. `reason` is a sentence for the user, not an atom for a `case`.
  """
  @spec parse(term()) :: {:ok, t()} | {:error, String.t()}
  def parse(expr) when is_binary(expr) do
    with {:ok, expanded} <- expand_alias(String.trim(expr)) do
      parse_fields(expanded)
    end
  end

  def parse(other), do: {:error, "expected a cron string, got #{inspect(other)}"}

  defp expand_alias("@" <> name) do
    case Map.fetch(@aliases, String.downcase(name)) do
      {:ok, expr} -> {:ok, expr}
      :error -> {:error, ~s(unknown alias "@#{name}" — known: @hourly, @daily, @weekly, @monthly)}
    end
  end

  defp expand_alias(expr), do: {:ok, expr}

  defp parse_fields(expr) do
    case String.split(expr, ~r/\s+/, trim: true) do
      [minute, hour, dom, month, dow] -> fields(minute, hour, dom, month, dow)
      fields -> {:error, "expected 5 fields, got #{length(fields)}"}
    end
  end

  defp fields(minute, hour, dom, month, dow) do
    with {:ok, minute} <- field(minute, "minute", @minute),
         {:ok, hour} <- field(hour, "hour", @hour),
         {:ok, days} <- field(dom, "day-of-month", @dom),
         {:ok, month} <- field(month, "month", @month),
         {:ok, weekdays} <- field(dow, "day-of-week", @dow) do
      cron = %__MODULE__{
        minute: minute,
        hour: hour,
        dom: days,
        month: month,
        dow: fold_sunday(weekdays),
        day_rule: day_rule(restricted?(dom), restricted?(dow))
      }

      with :ok <- reachable(cron), do: {:ok, cron}
    end
  end

  # Vixie decides "is this field restricted?" on the first character, so a `*/2`
  # step is still a star and does not switch the day rule to OR. It stays a
  # partial SET either way — see `days_match?/2`.
  defp restricted?(raw), do: not String.starts_with?(String.trim(raw), "*")

  defp day_rule(true, true), do: :either
  defp day_rule(true, false), do: :dom
  defp day_rule(false, true), do: :dow
  defp day_rule(false, false), do: :any

  defp fold_sunday(weekdays), do: MapSet.new(weekdays, &sunday/1)

  defp sunday(7), do: 0
  defp sunday(day), do: day

  # Under OR the weekday side always supplies days, so only the AND rule can name
  # a date that never arrives. February is checked against 29 — 29 February is
  # legal cron and fires in leap years — so what stays refused is a date NO year
  # has (30 February, 31 April). Refusing it here turns "this silently never
  # fires" into a reason the user can read, and keeps the day cap below from ever
  # being the thing that reports it.
  defp reachable(%__MODULE__{day_rule: :either}), do: :ok

  defp reachable(cron) do
    if Enum.any?(cron.month, fn month -> Enum.any?(cron.dom, &(&1 <= days_in(month))) end) do
      :ok
    else
      {:error,
       "day-of-month #{list(cron.dom)} never occurs in month #{list(cron.month)} — " <>
         "no year has that date"}
    end
  end

  # 2000 is a leap year, so February answers 29.
  defp days_in(month), do: Date.days_in_month(Date.new!(2000, month, 1))

  defp list(set), do: set |> Enum.sort() |> Enum.join(",")

  # -- fields -----------------------------------------------------------------

  defp field(raw, name, range) do
    case items(String.trim(raw), range) do
      {:ok, values} -> {:ok, MapSet.new(values)}
      {:error, detail} -> {:error, "#{name}: #{detail}"}
    end
  end

  defp items(raw, range) do
    raw
    |> String.split(",")
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case item(item, range) do
        {:ok, values} -> {:cont, {:ok, acc ++ values}}
        {:error, detail} -> {:halt, {:error, detail}}
      end
    end)
  end

  defp item(item, range) do
    case String.split(item, "/") do
      [base] -> values(base, range)
      [base, step] -> stepped(base, step, range)
      _more_than_one_slash -> {:error, ~s(malformed step "#{item}")}
    end
  end

  defp stepped(base, step, range) do
    with {:ok, size} <- step(step),
         {:ok, values} <- span(base, range) do
      {:ok, values |> Enum.sort() |> Enum.take_every(size)}
    end
  end

  defp step(step) do
    case integer(step) do
      {:ok, size} when size > 0 -> {:ok, size}
      {:ok, size} -> {:error, "step must be 1 or more, got #{size}"}
      {:error, detail} -> {:error, detail}
    end
  end

  # A step needs something to step through: `*` or a range, never a lone number.
  defp span("*", range), do: {:ok, Enum.to_list(range)}

  defp span(base, range) do
    if String.contains?(base, "-"),
      do: values(base, range),
      else: {:error, ~s(step needs `*` or a range before the "/", got "#{base}")}
  end

  defp values("*", range), do: {:ok, Enum.to_list(range)}

  defp values(base, range) do
    case String.split(base, "-") do
      [single] -> with {:ok, value} <- member(single, range), do: {:ok, [value]}
      [from, to] -> bounds(from, to, range)
      _more_than_one_dash -> {:error, ~s(malformed range "#{base}")}
    end
  end

  defp bounds(from, to, range) do
    with {:ok, from} <- member(from, range),
         {:ok, to} <- member(to, range) do
      if from <= to,
        do: {:ok, Enum.to_list(from..to)},
        else: {:error, "range #{from}-#{to} runs backwards"}
    end
  end

  defp member(text, range) do
    with {:ok, value} <- integer(text) do
      if value in range,
        do: {:ok, value},
        else: {:error, "#{value} is out of range #{inspect(range)}"}
    end
  end

  defp integer(text) do
    case Integer.parse(text) do
      {value, ""} -> {:ok, value}
      _not_a_plain_number -> {:error, ~s(expected a number, got "#{text}")}
    end
  end

  # -- slots ------------------------------------------------------------------

  @doc """
  The first slot **strictly after** `after_utc`, as a UTC datetime.

  `zone` is the schedule's wall-clock zone; an unknown one is
  `{:error, :invalid_zone}` (fail closed — a schedule whose zone we cannot
  resolve has no slots at all). See the moduledoc for the two DST rules, the
  day-then-minute walk and its cap.
  """
  @spec next_slot(t(), String.t(), DateTime.t()) :: {:ok, DateTime.t()} | {:error, :invalid_zone}
  def next_slot(%__MODULE__{} = cron, zone, %DateTime{} = after_utc) when is_binary(zone) do
    case DateTime.shift_zone(after_utc, zone) do
      {:ok, local} ->
        {date, from_minute} = start(DateTime.to_naive(local))
        walk(cron, zone, after_utc, minutes_of_day(cron), date, from_minute, 0)

      {:error, _unknown_zone} ->
        {:error, :invalid_zone}
    end
  end

  # Slots are minute-aligned, so the search starts at the minute AFTER the
  # anchor's — which is what makes it strictly-after even when the anchor carries
  # seconds — rolling over to the next day past 23:59.
  defp start(naive) do
    case naive.hour * 60 + naive.minute + 1 do
      minute when minute < @minutes_per_day -> {NaiveDateTime.to_date(naive), minute}
      _rolled_over -> {naive |> NaiveDateTime.to_date() |> Date.add(1), 0}
    end
  end

  # Every minute-of-day this expression fires at, ascending. Day-independent, so
  # it is built once per call rather than once per day walked.
  defp minutes_of_day(cron) do
    for hour <- Enum.sort(cron.hour), minute <- Enum.sort(cron.minute), do: hour * 60 + minute
  end

  defp walk(_cron, zone, _after_utc, _minutes, date, _from_minute, days) when days > @max_days do
    raise "cron slot search passed #{@max_days} days (#{zone}, reached #{date}) — " <>
            "parse/1 is supposed to make that unreachable"
  end

  defp walk(cron, zone, after_utc, minutes, date, from_minute, days) do
    case in_day(cron, zone, after_utc, minutes, date, from_minute) do
      {:ok, at} -> {:ok, at}
      {:error, :invalid_zone} = error -> error
      :none -> walk(cron, zone, after_utc, minutes, Date.add(date, 1), 0, days + 1)
    end
  end

  defp in_day(cron, zone, after_utc, minutes, date, from_minute) do
    if day_matches?(cron, date),
      do: first_slot(zone, after_utc, minutes, date, from_minute),
      else: :none
  end

  # The day matches, so walk its slots in order. `from_minute` only bites on the
  # first day of a search; every later day starts at midnight.
  defp first_slot(zone, after_utc, minutes, date, from_minute) do
    minutes
    |> Enum.drop_while(&(&1 < from_minute))
    |> Enum.reduce_while(:none, fn minute, :none ->
      case materialize(date, minute, zone, after_utc) do
        {:ok, at} -> {:halt, {:ok, at}}
        {:error, :invalid_zone} = error -> {:halt, error}
        :skip -> {:cont, :none}
      end
    end)
  end

  defp day_matches?(cron, date) do
    MapSet.member?(cron.month, date.month) and days_match?(cron, date)
  end

  # `day_rule` chooses OR vs AND. It never SKIPS a set: a star-prefixed field is
  # unrestricted for the *rule* but can still be a partial set (`*/2`), so both
  # sets are always consulted. With a plain `*` the set is the whole range and
  # the AND is trivially satisfied.
  defp days_match?(%__MODULE__{day_rule: :either} = cron, date),
    do: dom?(cron, date) or dow?(cron, date)

  defp days_match?(cron, date), do: dom?(cron, date) and dow?(cron, date)

  defp dom?(cron, date), do: MapSet.member?(cron.dom, date.day)

  # `Date.day_of_week/1` is 1 (Monday) to 7 (Sunday); cron wants 0 for Sunday.
  defp dow?(cron, date), do: MapSet.member?(cron.dow, rem(Date.day_of_week(date), 7))

  defp materialize(date, minute_of_day, zone, after_utc) do
    time = Time.new!(div(minute_of_day, 60), rem(minute_of_day, 60), 0)

    case DateTime.from_naive(NaiveDateTime.new!(date, time), zone) do
      {:ok, at} ->
        strictly_after(at, after_utc)

      # Fall-back: only the first pass over a repeated wall time is a slot.
      {:ambiguous, first, _second} ->
        strictly_after(first, after_utc)

      # Spring-forward: a wall time that does not exist fires just after the gap.
      {:gap, _before, just_after} ->
        strictly_after(just_after, after_utc)

      # Unreachable while `next_slot/3` probes the zone first; still answered
      # rather than raised, because failing closed is the house rule.
      {:error, _no_such_zone} ->
        {:error, :invalid_zone}
    end
  end

  defp strictly_after(at, after_utc) do
    utc = DateTime.shift_zone!(at, "Etc/UTC")

    if DateTime.compare(utc, after_utc) == :gt, do: {:ok, utc}, else: :skip
  end
end
