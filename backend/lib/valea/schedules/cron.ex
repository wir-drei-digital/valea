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

  Day-of-month and day-of-week are OR'd when **both** are restricted, and
  governed by the restricted one otherwise: `0 0 13 * 5` fires on the 13th
  *and* on every Friday, `0 0 13 * *` only on the 13th, `0 0 * * 5` only on
  Fridays. `parse/1` records which side is restricted as `day_rule`
  (`:any | :dom | :dow | :either`) so matching is a lookup rather than a
  re-derivation. Restriction is read Vixie's way — off the first character — so
  `*/2` counts as a star.

  ## Slots are wall-clock, answers are UTC instants

  Cron fields describe wall-clock times in the schedule's zone, so `next_slot/3`
  walks the wall clock minute by minute from the anchor and converts each match
  to an instant. Two conversions are not one-to-one, and both are pinned:

    * **Spring-forward gap** — the wall time does not exist. The slot lands on
      the first instant after the gap (`{:gap, _, just_after}`). Every wall
      minute inside the gap maps to that same instant, and the strictly-after
      test is what collapses them into one fire instead of one per skipped
      minute.
    * **Fall-back ambiguity** — the wall time happens twice. Only the first
      (earlier UTC offset) occurrence is a slot (`{:ambiguous, first, _}`), so
      the second pass over that hour never fires.

  `next_slot/3` is **strictly after** its anchor: an anchor sitting exactly on a
  slot returns the following one. That is what makes the scheduler's
  "anchor := slot just fired" loop terminate, and it is also what makes both
  DST rules above self-consistent — an instant already consumed can never come
  back, whichever wall time produced it.

  ## Bounded search

  The walk is capped at #{366 * 24 * 60} minute steps (a year and a day) and
  raises past that. The cap is only a backstop, because `parse/1` refuses the
  one family of expressions that could reach it: a day-of-month-governed
  expression naming a date no common year has (30 February, 31 April — and
  29 February, which exists only in leap years and so can sit more than a year
  out). Every expression that parses matches within the cap: `:dow`/`:either`
  hit a weekday inside 7 days, `:any` inside a day, and `:dom` has a
  guaranteed month/day pair.
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

  @max_steps 366 * 24 * 60

  @doc """
  Parses a cron expression (or an alias) into a `t:t/0`.

  Takes any term — a `schedules.json` `cron` field is whatever the file holds —
  and answers `{:error, reason}` for anything that isn't a string in the
  grammar above. `reason` is a sentence for the user, not an atom for a
  `case`.
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

  # Vixie decides "is this field restricted?" on the first character, so a
  # `*/2` step is still a star and does not switch the day rule to OR.
  defp restricted?(raw), do: not String.starts_with?(String.trim(raw), "*")

  defp day_rule(true, true), do: :either
  defp day_rule(true, false), do: :dom
  defp day_rule(false, true), do: :dow
  defp day_rule(false, false), do: :any

  defp fold_sunday(weekdays), do: MapSet.new(weekdays, &sunday/1)

  defp sunday(7), do: 0
  defp sunday(day), do: day

  # Only a dom-governed expression can name a date that never arrives; with dow
  # restricted the weekday side always supplies a day. Refusing it here is what
  # keeps `next_slot/3`'s cap unreachable — and it turns "this never fires" from
  # a silent mystery into a reason the user can read.
  defp reachable(%__MODULE__{day_rule: :dom} = cron) do
    if Enum.any?(cron.month, fn month ->
         Enum.any?(cron.dom, &(&1 <= Date.days_in_month(Date.new!(2001, month, 1))))
       end) do
      :ok
    else
      {:error,
       "day-of-month #{list(cron.dom)} never occurs in month #{list(cron.month)} of a " <>
         "common year (29 February included — it only exists in leap years)"}
    end
  end

  defp reachable(_dow_carries_the_day), do: :ok

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
  resolve has no slots at all). See the moduledoc for the two DST rules and the
  search bound.
  """
  @spec next_slot(t(), String.t(), DateTime.t()) :: {:ok, DateTime.t()} | {:error, :invalid_zone}
  def next_slot(%__MODULE__{} = cron, zone, %DateTime{} = after_utc) when is_binary(zone) do
    case DateTime.shift_zone(after_utc, zone) do
      {:ok, local} -> search(cron, zone, after_utc, first_candidate(local), 0)
      {:error, _unknown_zone} -> {:error, :invalid_zone}
    end
  end

  # Slots are minute-aligned, so the first candidate is the minute after the
  # anchor's — which is exactly what makes the search strictly-after even when
  # the anchor carries seconds.
  defp first_candidate(local) do
    naive = DateTime.to_naive(local)

    %NaiveDateTime{naive | second: 0, microsecond: {0, 0}}
    |> NaiveDateTime.add(60, :second)
  end

  defp search(_cron, zone, _after_utc, naive, steps) when steps > @max_steps do
    raise "cron slot search passed #{@max_steps} minute steps (#{zone}, at #{naive}) — " <>
            "parse/1 is supposed to make that unreachable"
  end

  defp search(cron, zone, after_utc, naive, steps) do
    case candidate(cron, zone, after_utc, naive) do
      {:ok, at} -> {:ok, at}
      {:error, :invalid_zone} = error -> error
      :skip -> search(cron, zone, after_utc, NaiveDateTime.add(naive, 60, :second), steps + 1)
    end
  end

  defp candidate(cron, zone, after_utc, naive) do
    if matches?(cron, naive), do: materialize(naive, zone, after_utc), else: :skip
  end

  defp materialize(naive, zone, after_utc) do
    case DateTime.from_naive(naive, zone) do
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

  defp matches?(cron, naive) do
    MapSet.member?(cron.minute, naive.minute) and
      MapSet.member?(cron.hour, naive.hour) and
      MapSet.member?(cron.month, naive.month) and
      day_matches?(cron, naive)
  end

  defp day_matches?(%__MODULE__{day_rule: :any}, _naive), do: true
  defp day_matches?(%__MODULE__{day_rule: :dom} = cron, naive), do: dom?(cron, naive)
  defp day_matches?(%__MODULE__{day_rule: :dow} = cron, naive), do: dow?(cron, naive)

  defp day_matches?(%__MODULE__{day_rule: :either} = cron, naive),
    do: dom?(cron, naive) or dow?(cron, naive)

  defp dom?(cron, naive), do: MapSet.member?(cron.dom, naive.day)

  # `Date.day_of_week/1` is 1 (Monday) to 7 (Sunday); cron wants 0 for Sunday.
  defp dow?(cron, naive), do: MapSet.member?(cron.dow, rem(Date.day_of_week(naive), 7))
end
