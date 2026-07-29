defmodule Valea.Schedules.CronTest do
  use ExUnit.Case, async: true

  alias Valea.Schedules.Cron

  # -- helpers ----------------------------------------------------------------

  defp parse!(expr) do
    {:ok, cron} = Cron.parse(expr)
    cron
  end

  defp utc!(iso) do
    {:ok, at, 0} = DateTime.from_iso8601(iso)
    at
  end

  # The whole contract in one call: parse, ask for the slot strictly after
  # `after_iso`, render the answer as a UTC instant.
  defp slot(expr, zone, after_iso) do
    {:ok, at} = Cron.next_slot(parse!(expr), zone, utc!(after_iso))
    DateTime.to_iso8601(at)
  end

  describe "parse/1 grammar" do
    test "a full 5-field expression yields the sets and the day rule" do
      cron = parse!("30 7 * * 1-5")

      assert cron.minute == MapSet.new([30])
      assert cron.hour == MapSet.new([7])
      assert cron.dom == MapSet.new(1..31)
      assert cron.month == MapSet.new(1..12)
      assert cron.dow == MapSet.new(1..5)
      assert cron.day_rule == :dow
    end

    test "surrounding and repeated whitespace is tolerated" do
      assert parse!("  30   7 * * 1-5  ") == parse!("30 7 * * 1-5")
    end

    test "lists, ranges and steps" do
      assert parse!("*/15 * * * *").minute == MapSet.new([0, 15, 30, 45])
      assert parse!("0 9-17 * * *").hour == MapSet.new(9..17)
      assert parse!("0 0 1,15 * *").dom == MapSet.new([1, 15])
      assert parse!("0 0 * * 1-5,0").dow == MapSet.new([0, 1, 2, 3, 4, 5])
      assert parse!("0 10-20/5 * * *").hour == MapSet.new([10, 15, 20])
    end

    test "day-of-week 7 folds onto 0 (Sunday)" do
      assert parse!("0 0 * * 7").dow == MapSet.new([0])
      assert parse!("0 0 * * 0,7").dow == MapSet.new([0])
      assert parse!("0 0 * * *").dow == MapSet.new(0..6)
    end

    test "the day rule records which of dom/dow is restricted (Vixie)" do
      assert parse!("0 0 13 * 5").day_rule == :either
      assert parse!("0 0 13 * *").day_rule == :dom
      assert parse!("0 0 * * 5").day_rule == :dow
      assert parse!("0 0 * * *").day_rule == :any
      # Vixie reads the restriction off the first character: `*/2` is a star.
      assert parse!("0 0 */2 * 5").day_rule == :dow
      assert parse!("0 0 */2 * *").day_rule == :any
    end

    test "a star-prefixed field is unrestricted for the RULE but still a partial set" do
      assert parse!("0 0 */2 * *").dom ==
               MapSet.new([1, 3, 5, 7, 9, 11, 13, 15, 17, 19] ++ [21, 23, 25, 27, 29, 31])

      assert parse!("0 0 * * */2").dow == MapSet.new([0, 2, 4, 6])
      # `*` and `*/1` are the whole range, which is what makes the AND trivial.
      assert parse!("0 0 */1 * *").dom == parse!("0 0 * * *").dom
      assert parse!("0 0 * * */1").dow == parse!("0 0 * * *").dow
    end
  end

  describe "parse/1 aliases" do
    test "the four aliases expand to their 5-field equivalents" do
      assert parse!("@hourly") == parse!("0 * * * *")
      assert parse!("@daily") == parse!("0 0 * * *")
      assert parse!("@weekly") == parse!("0 0 * * 0")
      assert parse!("@monthly") == parse!("0 0 1 * *")
    end

    test "unknown aliases are refused by name" do
      assert {:error, reason} = Cron.parse("@yearly")
      assert reason =~ "unknown alias"
      assert {:error, _} = Cron.parse("@reboot")
    end

    test "aliases fire where they should" do
      assert slot("@hourly", "Etc/UTC", "2026-07-29T10:30:00Z") == "2026-07-29T11:00:00Z"
      assert slot("@daily", "Etc/UTC", "2026-07-29T10:30:00Z") == "2026-07-30T00:00:00Z"
      # 2026-07-29 is a Wednesday; @weekly is Sunday 00:00.
      assert slot("@weekly", "Etc/UTC", "2026-07-29T10:30:00Z") == "2026-08-02T00:00:00Z"
      assert slot("@monthly", "Etc/UTC", "2026-07-29T10:30:00Z") == "2026-08-01T00:00:00Z"
    end
  end

  describe "parse/1 rejections" do
    test "out-of-range values" do
      assert {:error, reason} = Cron.parse("61 * * * *")
      assert reason =~ "minute"
      assert reason =~ "0..59"

      assert {:error, _} = Cron.parse("* 24 * * *")
      assert {:error, _} = Cron.parse("* * 0 * *")
      assert {:error, _} = Cron.parse("* * 32 * *")
      assert {:error, _} = Cron.parse("* * * 13 *")
      assert {:error, _} = Cron.parse("* * * * 8")
    end

    test "wrong field count" do
      assert {:error, reason} = Cron.parse("* * *")
      assert reason =~ "5 fields"
      assert {:error, _} = Cron.parse("* * * * * *")
      assert {:error, _} = Cron.parse("")
    end

    test "non-numeric fields" do
      assert {:error, _} = Cron.parse("a b c d e")
      # Three-letter names are deliberately outside the grammar.
      assert {:error, _} = Cron.parse("0 0 * * MON")
    end

    test "malformed ranges and steps" do
      assert {:error, _} = Cron.parse("1-2-3 * * * *")
      assert {:error, reason} = Cron.parse("30-10 * * * *")
      assert reason =~ "backwards"
      assert {:error, _} = Cron.parse("*/0 * * * *")
      assert {:error, reason} = Cron.parse("5/10 * * * *")
      assert reason =~ "step"
      assert {:error, _} = Cron.parse("*/ * * * *")
      assert {:error, _} = Cron.parse("0,,1 * * * *")
    end

    test "dates that NO year has" do
      assert {:error, reason} = Cron.parse("0 0 30 2 *")
      assert reason =~ "never occurs"

      for expr <- ["0 0 31 2 *", "0 0 31 4 *", "0 0 31 6 *", "0 0 31 9 *", "0 0 31 11 *"] do
        assert {:error, _} = Cron.parse(expr), "#{expr} should be unreachable"
      end

      # Reachable again as soon as some pair works, or dow can carry the day
      # under the OR rule.
      assert {:ok, _} = Cron.parse("0 0 31 * *")
      assert {:ok, _} = Cron.parse("0 0 15,30 2 *")
      assert {:ok, _} = Cron.parse("0 0 30 2 5")
      assert {:ok, _} = Cron.parse("0 0 */31 2 *")
    end

    test "29 February is legal cron, not an unreachable date" do
      assert {:ok, _} = Cron.parse("0 0 29 2 *")
      assert {:ok, _} = Cron.parse("0 0 29 2 */7")
    end

    test "a non-string expression" do
      assert {:error, _} = Cron.parse(42)
      assert {:error, _} = Cron.parse(nil)
    end
  end

  describe "next_slot/3" do
    test "weekday morning in a zone with an offset" do
      # Tue 2026-07-28 12:00 CEST -> Wed 2026-07-29 07:30 CEST.
      assert slot("30 7 * * 1-5", "Europe/Zurich", "2026-07-28T10:00:00Z") ==
               "2026-07-29T05:30:00Z"

      # Fri -> Mon: the weekend is skipped.
      assert slot("30 7 * * 1-5", "Europe/Zurich", "2026-07-31T10:00:00Z") ==
               "2026-08-03T05:30:00Z"
    end

    test "is strictly after the given instant" do
      assert slot("*/15 * * * *", "Etc/UTC", "2026-07-29T10:15:00Z") == "2026-07-29T10:30:00Z"

      assert slot("30 7 * * 1-5", "Europe/Zurich", "2026-07-29T05:30:00Z") ==
               "2026-07-30T05:30:00Z"
    end

    test "sub-minute precision in the anchor is floored, not rounded" do
      assert slot("*/15 * * * *", "Etc/UTC", "2026-07-29T10:14:59Z") == "2026-07-29T10:15:00Z"
      assert slot("*/15 * * * *", "Etc/UTC", "2026-07-29T10:15:01Z") == "2026-07-29T10:30:00Z"
    end

    test "lists, ranges and steps materialize" do
      assert slot("*/15 * * * *", "Etc/UTC", "2026-07-29T10:07:00Z") == "2026-07-29T10:15:00Z"
      assert slot("*/15 * * * *", "Etc/UTC", "2026-07-29T10:46:00Z") == "2026-07-29T11:00:00Z"
      assert slot("0 9-17 * * *", "Etc/UTC", "2026-07-29T09:30:00Z") == "2026-07-29T10:00:00Z"
      assert slot("0 9-17 * * *", "Etc/UTC", "2026-07-29T17:30:00Z") == "2026-07-30T09:00:00Z"
      assert slot("0 0 1,15 * *", "Etc/UTC", "2026-08-02T00:00:00Z") == "2026-08-15T00:00:00Z"
      assert slot("0 0 1,15 * *", "Etc/UTC", "2026-08-15T00:00:00Z") == "2026-09-01T00:00:00Z"
    end

    test "Vixie OR rule: both restricted fires on either" do
      # August 2026: Fridays are the 7th, 14th, 21st, 28th; the 13th is a
      # Thursday. `0 0 13 * 5` fires on both kinds of day.
      assert slot("0 0 13 * 5", "Etc/UTC", "2026-08-01T12:00:00Z") == "2026-08-07T00:00:00Z"
      assert slot("0 0 13 * 5", "Etc/UTC", "2026-08-08T00:00:00Z") == "2026-08-13T00:00:00Z"
      assert slot("0 0 13 * 5", "Etc/UTC", "2026-08-13T00:00:00Z") == "2026-08-14T00:00:00Z"
    end

    test "a star-prefixed partial set still constrains the day (AND, not skipped)" do
      # `0 0 */2 * *` is `:any` for the rule and {1,3,5,…} for the set: odd days
      # only. Anchored on the 1st it must skip the 2nd.
      assert slot("0 0 */2 * *", "Etc/UTC", "2026-08-01T12:00:00Z") == "2026-08-03T00:00:00Z"
      # The dom set restarts each month, so the 31st and the 1st are adjacent.
      assert slot("0 0 */2 * *", "Etc/UTC", "2026-08-31T00:00:00Z") == "2026-09-01T00:00:00Z"

      # dow */2 is {Sun, Tue, Thu, Sat}: Mon -> Tue, Tue -> Thu.
      assert slot("0 0 * * */2", "Etc/UTC", "2026-08-03T00:00:00Z") == "2026-08-04T00:00:00Z"
      assert slot("0 0 * * */2", "Etc/UTC", "2026-08-04T00:00:00Z") == "2026-08-06T00:00:00Z"
    end

    test "odd Fridays: both sets consulted under the AND rule" do
      # August 2026 Fridays are the 7th, 14th, 21st, 28th. `0 0 */2 * 5` is
      # `:dow` for the rule, so dom AND dow: only the odd Fridays fire, and the
      # 14th is skipped.
      assert slot("0 0 */2 * 5", "Etc/UTC", "2026-08-01T00:00:00Z") == "2026-08-07T00:00:00Z"
      assert slot("0 0 */2 * 5", "Etc/UTC", "2026-08-07T00:00:00Z") == "2026-08-21T00:00:00Z"
    end

    test "the 13th on a star-prefixed weekday set (AND across months)" do
      # dow */2 is {Sun, Tue, Thu, Sat}; 2026-08-13 is a Thursday.
      assert slot("0 0 13 * */2", "Etc/UTC", "2026-08-01T00:00:00Z") == "2026-08-13T00:00:00Z"
      # 2026-11-13 is a Friday, so November is skipped for 2026-12-13 (Sunday).
      assert slot("0 0 13 * */2", "Etc/UTC", "2026-10-13T00:00:00Z") == "2026-12-13T00:00:00Z"
    end

    test "the AND-degenerate stars fire every day" do
      assert slot("0 0 */1 * *", "Etc/UTC", "2026-08-01T12:00:00Z") == "2026-08-02T00:00:00Z"
      assert slot("0 0 * * */1", "Etc/UTC", "2026-08-01T12:00:00Z") == "2026-08-02T00:00:00Z"
      assert slot("0 0 * * *", "Etc/UTC", "2026-08-01T12:00:00Z") == "2026-08-02T00:00:00Z"
    end

    test "29 February fires in the next leap year" do
      assert slot("0 0 29 2 *", "Etc/UTC", "2026-03-01T00:00:00Z") == "2028-02-29T00:00:00Z"
      assert slot("0 0 29 2 *", "Etc/UTC", "2028-02-29T00:00:00Z") == "2032-02-29T00:00:00Z"
    end

    test "29 February pinned to one weekday — the longest search there is" do
      # dow */7 is {Sunday}. The day walk crosses six years for this one; the
      # bound exists for the century-boundary version of it.
      assert slot("0 0 29 2 */7", "Etc/UTC", "2026-01-01T00:00:00Z") == "2032-02-29T00:00:00Z"
    end

    test "Vixie AND rule: only the restricted field governs" do
      # dom only: the 13th, never the Friday.
      assert slot("0 0 13 * *", "Etc/UTC", "2026-08-01T12:00:00Z") == "2026-08-13T00:00:00Z"
      assert slot("0 0 13 * *", "Etc/UTC", "2026-08-13T00:00:00Z") == "2026-09-13T00:00:00Z"

      # dow only: the Friday, never the 13th.
      assert slot("0 0 * * 5", "Etc/UTC", "2026-08-08T00:00:00Z") == "2026-08-14T00:00:00Z"
    end

    test "day-of-week 7 means Sunday" do
      assert slot("0 0 * * 7", "Etc/UTC", "2026-07-29T10:00:00Z") == "2026-08-02T00:00:00Z"
    end

    test "DST spring-forward: a wall time inside the gap fires just after it" do
      # Europe/Zurich jumps 02:00 CET -> 03:00 CEST on 2026-03-29, so 02:30
      # does not exist that day: the slot lands on 03:00 CEST = 01:00Z.
      assert slot("30 2 * * *", "Europe/Zurich", "2026-03-28T02:00:00Z") ==
               "2026-03-29T01:00:00Z"

      # And the day after is the ordinary 02:30 CEST — the gap fires once.
      assert slot("30 2 * * *", "Europe/Zurich", "2026-03-29T01:00:00Z") ==
               "2026-03-30T00:30:00Z"
    end

    test "DST spring-forward: every wall minute in the gap collapses to one slot" do
      # 02:00, 02:15, 02:30 and 02:45 are all missing on 2026-03-29; the
      # search must not emit 01:00Z four times.
      assert slot("*/15 * * * *", "Europe/Zurich", "2026-03-29T00:59:00Z") ==
               "2026-03-29T01:00:00Z"

      assert slot("*/15 * * * *", "Europe/Zurich", "2026-03-29T01:00:00Z") ==
               "2026-03-29T01:15:00Z"
    end

    test "DST fall-back: the repeated wall time fires only on its first pass" do
      # Europe/Zurich repeats 02:00-02:59 on 2026-10-25 (CEST then CET), so
      # 02:30 exists twice: 00:30Z and 01:30Z. Only the first is a slot.
      assert slot("30 2 * * *", "Europe/Zurich", "2026-10-24T12:00:00Z") ==
               "2026-10-25T00:30:00Z"

      # From the first occurrence the search skips the second pass entirely
      # and lands on the next day (02:30 CET = 01:30Z).
      assert slot("30 2 * * *", "Europe/Zurich", "2026-10-25T00:30:00Z") ==
               "2026-10-26T01:30:00Z"

      # Anchored inside the second pass, it still refuses to fire there.
      assert slot("30 2 * * *", "Europe/Zurich", "2026-10-25T01:00:00Z") ==
               "2026-10-26T01:30:00Z"
    end

    test "an unknown zone fails closed" do
      cron = parse!("@daily")
      at = utc!("2026-07-29T10:00:00Z")

      assert Cron.next_slot(cron, "Mars/Phobos", at) == {:error, :invalid_zone}
      assert Cron.next_slot(cron, "", at) == {:error, :invalid_zone}
    end

    test "the answer is always a UTC datetime" do
      {:ok, at} = Cron.next_slot(parse!("@daily"), "Europe/Zurich", utc!("2026-07-29T10:00:00Z"))
      assert at.time_zone == "Etc/UTC"
      assert at.microsecond == {0, 0}
      assert at.second == 0
    end

    test "an anchor in another zone is honoured as an instant" do
      cron = parse!("30 7 * * 1-5")
      {:ok, zurich} = DateTime.shift_zone(utc!("2026-07-28T10:00:00Z"), "Europe/Zurich")
      {:ok, at} = Cron.next_slot(cron, "Europe/Zurich", zurich)

      assert DateTime.to_iso8601(at) == "2026-07-29T05:30:00Z"
    end
  end
end
