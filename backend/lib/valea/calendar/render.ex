defmodule Valea.Calendar.Render do
  @moduledoc """
  Composes the served ICS feed for the Valea calendar (calendar spec F,
  §The served feed): one VCALENDAR carrying one engine-composed VEVENT
  per VALID `Valea.Calendar.Local.Event`. This is the `Valea.Mail.
  DraftMime` posture inverted for ICS — composition happens ONLY from
  validated struct fields, every TEXT value is RFC 5545-escaped
  (`\\\\`, `\\;`, `\\,`, `\\n`) and every content line is folded at 75
  octets (CRLF + single space) on UTF-8 codepoint boundaries, so agent
  text can never smuggle a raw property or an extra component into a
  subscriber's calendar.

  Per event: UID (`Local.uid/1` — name-derived, stable across edits),
  DTSTAMP and LAST-MODIFIED (BOTH the event's `mtime`, rendered as UTC
  `YYYYMMDDTHHMMSSZ`), SUMMARY, DTSTART/DTEND (timed: the UTC `Z` form;
  all-day: `;VALUE=DATE` with the exclusive end), LOCATION when present,
  STATUS upcased, DESCRIPTION when the body is non-empty.
  """

  alias Valea.Calendar.Local
  alias Valea.Calendar.Local.Event

  @crlf "\r\n"
  # RFC 5545 §3.1: content lines SHOULD NOT exceed 75 octets excluding
  # CRLF; folded continuations carry one leading space, so their payload
  # budget is 74.
  @first_line_octets 75
  @cont_line_octets 74

  @utc_db Calendar.UTCOnlyTimeZoneDatabase

  @doc "The whole feed for `events` as CRLF-terminated ICS bytes."
  @spec feed([Event.t()]) :: binary()
  def feed(events) when is_list(events) do
    lines =
      ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Valea//Calendar//EN", "CALSCALE:GREGORIAN"] ++
        Enum.flat_map(events, &vevent/1) ++
        ["END:VCALENDAR"]

    lines
    |> Enum.map(&fold/1)
    |> Enum.map_join(&(&1 <> @crlf))
  end

  # -- one VEVENT ---------------------------------------------------------------

  defp vevent(%Event{} = event) do
    stamp = utc_basic(event.mtime)

    [
      "BEGIN:VEVENT",
      "UID:" <> Local.uid(event.name),
      "DTSTAMP:" <> stamp,
      "LAST-MODIFIED:" <> stamp,
      "SUMMARY:" <> escape(event.title)
    ] ++
      times(event) ++
      optional("LOCATION:", event.location) ++
      ["STATUS:" <> String.upcase(event.status)] ++
      optional("DESCRIPTION:", event.description) ++
      ["END:VEVENT"]
  end

  defp times(%Event{all_day: true} = event) do
    [
      "DTSTART;VALUE=DATE:" <> basic_date(event.start),
      "DTEND;VALUE=DATE:" <> basic_date(Map.fetch!(event, :end))
    ]
  end

  defp times(%Event{} = event) do
    [
      "DTSTART:" <> utc_basic(event.start),
      "DTEND:" <> utc_basic(Map.fetch!(event, :end))
    ]
  end

  defp optional(_prefix, nil), do: []
  defp optional(_prefix, ""), do: []
  defp optional(prefix, value), do: [prefix <> escape(value)]

  # -- time rendering -----------------------------------------------------------

  # Fixed-offset values (Local preserves the file's offset) normalize to
  # UTC arithmetically — shifting TO Etc/UTC needs no zone lookup of the
  # source, so the UTC-only database suffices for any offset.
  defp utc_basic(%DateTime{} = dt) do
    {:ok, utc} = DateTime.shift_zone(dt, "Etc/UTC", @utc_db)
    Calendar.strftime(utc, "%Y%m%dT%H%M%S") <> "Z"
  end

  defp basic_date(%Date{} = date), do: Calendar.strftime(date, "%Y%m%d")

  # -- TEXT escaping ------------------------------------------------------------

  # RFC 5545 §3.3.11 TEXT: backslash FIRST (never double-escape), then
  # semicolon, comma, and newline (the two-character `\n`). CR is dropped
  # outright — validated fields never carry one, and even a hand-built
  # struct must not be able to emit a raw line break.
  defp escape(value) when is_binary(value) do
    value
    |> String.replace("\r", "")
    |> String.replace("\\", "\\\\")
    |> String.replace(";", "\\;")
    |> String.replace(",", "\\,")
    |> String.replace("\n", "\\n")
  end

  # -- folding ------------------------------------------------------------------

  # 75-octet folding with CRLF + one space, splitting ONLY between UTF-8
  # codepoints — a multi-byte character is never cut mid-sequence.
  defp fold(line) when byte_size(line) <= @first_line_octets, do: line

  defp fold(line) do
    {first, rest} = take_codepoints(line, @first_line_octets)
    first <> fold_rest(rest)
  end

  defp fold_rest(""), do: ""

  defp fold_rest(rest) do
    {chunk, more} = take_codepoints(rest, @cont_line_octets)
    @crlf <> " " <> chunk <> fold_rest(more)
  end

  # The longest prefix of `bin` that is <= `limit` octets and ends on a
  # codepoint boundary (always at least one codepoint — every UTF-8
  # codepoint is <= 4 octets, far under either budget).
  defp take_codepoints(bin, limit), do: take_codepoints(bin, limit, 0)

  defp take_codepoints(bin, limit, taken) do
    case bin do
      <<_::binary-size(^taken)>> ->
        {bin, ""}

      <<_::binary-size(^taken), cp::utf8, _::binary>> ->
        size = byte_size(<<cp::utf8>>)

        if taken + size > limit do
          <<chunk::binary-size(^taken), rest::binary>> = bin
          {chunk, rest}
        else
          take_codepoints(bin, limit, taken + size)
        end
    end
  end
end
