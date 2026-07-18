defmodule Valea.Calendar.Views do
  @moduledoc """
  The derived markdown views for one external calendar source (calendar
  spec F, §Views / §Storage layout): one file per VEVENT — masters AND
  override VEVENTs — under `sources/calendar/<slug>/views/events/
  <view_id>.md`, plus the `.rev` derive marker riding INSIDE the swapped
  views directory.

  `rebuild!/6` is one half of the engine's guarded derive: it renders the
  whole views tree for a parsed feed into a temp directory (containing
  `.rev`) and swaps it in by double rename — `views` → `views.old-<rand>`,
  `views.tmp-<rand>` → `views`, then removes the old tree. The double
  rename is not atomic as a pair, but the marker checks make that safe:
  `.rev` rides inside the NEW directory, so any interruption leaves a
  marker mismatch that the next pass repairs. It returns the OCCURRENCE
  ROWS for `Valea.Calendar.Store.replace_source!/5` — expansion runs here
  (via `Valea.Calendar.Ics.expand/5` per master) exactly once for both
  derived stores, so views and index can never disagree about a series.

  View frontmatter is the injection-hardened `Valea.Yaml.escape/1` shape
  (the mail-views posture): a fixed key set `uid, source, summary, start,
  end, all_day, location, status, recurring, rrule, recurrence_id`, with
  `recurrence_unsupported: true` ADDED — and only then — for a series the
  expander refuses (unsupported RRULE part, THISANDFUTURE, unknown TZID):
  its views keep the raw rule, but NO occurrence rows are emitted.
  External UIDs are arbitrary, possibly hostile bytes — filenames come
  from `Ics.view_id/3` (a hash), never from the UID.
  """

  alias Valea.Calendar.Ics
  alias Valea.Calendar.Ics.Event

  @typedoc "One `calendar_occurrences` row, ready for `Store.replace_source!/5`."
  @type row :: %{
          uid: String.t(),
          all_day: boolean(),
          occ_start: String.t(),
          occ_end: String.t(),
          summary: String.t() | nil,
          location: String.t() | nil,
          status: String.t(),
          view_path: String.t()
        }

  @doc """
  Rebuilds `source_dir/views` from `feed` and swaps it in (see the
  moduledoc). `window` is the inclusive expansion date window, `host_zone`
  the zone floating times resolve against. Returns the occurrence rows,
  the per-source notices collected during expansion (unmatched overrides,
  unsupported series, structural oddities), and the unsupported-series
  count.
  """
  @spec rebuild!(
          String.t(),
          String.t(),
          %Ics.Feed{},
          String.t(),
          {Date.t(), Date.t()},
          String.t()
        ) ::
          %{rows: [row()], notices: [String.t()], unsupported_series: non_neg_integer()}
  def rebuild!(
        source_dir,
        slug,
        %Ics.Feed{} = feed,
        rev,
        {%Date{} = from, %Date{} = to},
        host_zone
      )
      when is_binary(source_dir) and is_binary(slug) and is_binary(rev) and is_binary(host_zone) do
    {views, rows, notices, unsupported} = build(slug, feed, from, to, host_zone)
    swap!(source_dir, views, rev)

    %{
      rows: Enum.sort_by(rows, &{&1.occ_start, &1.uid}),
      notices: notices,
      unsupported_series: unsupported
    }
  end

  @doc "The rev recorded in `source_dir/views/.rev`, or `nil` before any completed swap."
  @spec current_rev(String.t()) :: String.t() | nil
  def current_rev(source_dir) when is_binary(source_dir) do
    case File.read(Path.join([source_dir, "views", ".rev"])) do
      {:ok, bytes} -> String.trim(bytes)
      {:error, _reason} -> nil
    end
  end

  # -- building ---------------------------------------------------------------

  defp build(slug, feed, from, to, host_zone) do
    feed.events
    |> Enum.group_by(& &1.uid)
    |> Enum.sort_by(fn {uid, _events} -> uid end)
    |> Enum.reduce({[], [], [], 0}, fn {uid, events}, acc ->
      {masters, overrides} = Enum.split_with(events, &(&1.recurrence_id == nil))

      case masters do
        [master | dupes] ->
          series(acc, slug, uid, master, dupes, overrides, from, to, host_zone)

        [] ->
          masterless(acc, slug, uid, overrides, from, to, host_zone)
      end
    end)
  end

  # A normal series: one master (duplicates noticed and skipped — their
  # view id would collide with the master's) plus its overrides.
  defp series(
         {views, rows, notices, unsupported},
         slug,
         uid,
         master,
         dupes,
         overrides,
         from,
         to,
         host_zone
       ) do
    dupe_notices =
      if dupes == [] do
        []
      else
        ["duplicate master VEVENT for UID " <> sanitize(uid) <> " — first one wins"]
      end

    recurring? = master.rrule != nil

    case Ics.expand(master, overrides, from, to, host_zone) do
      {:ok, occurrences, expand_notices} ->
        new_views =
          for event <- [master | overrides],
              do: view_entry(slug, event, recurring?, false, host_zone)

        new_rows = Enum.map(occurrences, &row(slug, &1, host_zone))

        {views ++ new_views, rows ++ new_rows, notices ++ dupe_notices ++ expand_notices,
         unsupported}

      {:unsupported, reason} ->
        new_views =
          for event <- [master | overrides],
              do: view_entry(slug, event, recurring?, true, host_zone)

        notice =
          "series " <> sanitize(uid) <> " unsupported: " <> reason <> " — occurrences unavailable"

        {views ++ new_views, rows, notices ++ dupe_notices ++ [notice], unsupported + 1}
    end
  end

  # Override VEVENTs whose UID has no master in the feed: each renders
  # standalone (the spec's unmatched-override posture — visible, noticed,
  # never fabricated into a series).
  defp masterless(acc, slug, uid, overrides, from, to, host_zone) do
    Enum.reduce(overrides, acc, fn override, {views, rows, notices, unsupported} ->
      notice = "override " <> sanitize(uid) <> " has no master VEVENT — rendered standalone"

      case Ics.expand(override, [], from, to, host_zone) do
        {:ok, occurrences, expand_notices} ->
          new_rows = Enum.map(occurrences, &row(slug, &1, host_zone))

          {views ++ [view_entry(slug, override, false, false, host_zone)], rows ++ new_rows,
           notices ++ [notice] ++ expand_notices, unsupported}

        {:unsupported, reason} ->
          series_notice =
            "series " <>
              sanitize(uid) <> " unsupported: " <> reason <> " — occurrences unavailable"

          {views ++ [view_entry(slug, override, false, true, host_zone)], rows,
           notices ++ [notice, series_notice], unsupported + 1}
      end
    end)
  end

  # -- occurrence rows --------------------------------------------------------

  defp row(slug, %{all_day: false} = occurrence, host_zone) do
    event = occurrence.event

    %{
      uid: event.uid,
      all_day: false,
      occ_start: DateTime.to_iso8601(occurrence.start),
      occ_end: DateTime.to_iso8601(Map.fetch!(occurrence, :end)),
      summary: event.summary,
      location: event.location,
      status: status_string(event),
      view_path: rel_view_path(slug, event, host_zone)
    }
  end

  defp row(slug, %{all_day: true} = occurrence, host_zone) do
    event = occurrence.event

    %{
      uid: event.uid,
      all_day: true,
      occ_start: Date.to_iso8601(occurrence.start_date),
      occ_end: Date.to_iso8601(occurrence.end_date),
      summary: event.summary,
      location: event.location,
      status: status_string(event),
      view_path: rel_view_path(slug, event, host_zone)
    }
  end

  defp rel_view_path(slug, %Event{} = event, host_zone) do
    Path.join(["sources", "calendar", slug, "views", "events", view_file(slug, event, host_zone)])
  end

  defp view_file(slug, %Event{} = event, host_zone) do
    Ics.view_id(slug, event.uid, Ics.canonical_recurrence_id(event, host_zone)) <> ".md"
  end

  # -- view rendering ---------------------------------------------------------

  defp view_entry(slug, %Event{} = event, recurring?, unsupported?, host_zone) do
    {view_file(slug, event, host_zone), render(slug, event, recurring?, unsupported?, host_zone)}
  end

  defp render(slug, %Event{} = event, recurring?, unsupported?, host_zone) do
    frontmatter =
      [
        {"uid", escape(event.uid)},
        {"source", escape(slug)},
        {"summary", escape(event.summary || "")},
        {"start", escape(render_time(event.dtstart, host_zone))},
        {"end", escape(render_end(event, host_zone))},
        {"all_day", bool(event.all_day)},
        {"location", escape(event.location || "")},
        {"status", escape(status_string(event))},
        {"recurring", bool(recurring?)},
        {"rrule", escape(raw_rrule(event))},
        {"recurrence_id", escape(raw_recurrence_id(event.recurrence_id))}
      ] ++ if(unsupported?, do: [{"recurrence_unsupported", "true"}], else: [])

    lines = Enum.map_join(frontmatter, fn {key, value} -> key <> ": " <> value <> "\n" end)
    "---\n" <> lines <> "---\n" <> body(event.description)
  end

  defp body(nil), do: ""
  defp body(""), do: ""

  defp body(description) do
    if String.ends_with?(description, "\n"), do: description, else: description <> "\n"
  end

  defp escape(value), do: Valea.Yaml.escape(value)

  defp bool(true), do: "true"
  defp bool(_false_or_nil), do: "false"

  defp status_string(%Event{status: nil}), do: "confirmed"
  defp status_string(%Event{status: status}), do: String.downcase(status)

  defp raw_rrule(%Event{rrule: nil}), do: ""
  defp raw_rrule(%Event{rrule: %{raw: raw}}), do: raw

  # -- time rendering ---------------------------------------------------------

  # Frontmatter start/end: all-day → ISO dates; timed → UTC ISO instants,
  # resolved through the same chain as expansion. A TZID the chain cannot
  # resolve (an unsupported series — its view still exists) falls back to
  # the naive ISO plus "@tzid", informational and deterministic.
  defp render_time({:date, %Date{} = date}, _host_zone), do: Date.to_iso8601(date)

  defp render_time(tagged, host_zone) do
    case Ics.resolve(tagged, host_zone) do
      {:ok, dt} -> DateTime.to_iso8601(dt)
      {:error, :unknown_tzid} -> unresolved(tagged)
    end
  end

  defp unresolved({:zoned, ndt, tzid}), do: NaiveDateTime.to_iso8601(ndt) <> "@" <> tzid
  defp unresolved({:floating, ndt}), do: NaiveDateTime.to_iso8601(ndt)

  # DTEND when present; else DURATION applied to the start; else the RFC's
  # defaults, mirroring expansion (timed → zero duration, all-day → one day).
  defp render_end(%Event{dtend: dtend}, host_zone) when dtend != nil,
    do: render_time(dtend, host_zone)

  defp render_end(%Event{dtstart: {:date, start_date}, duration: duration}, _host_zone) do
    span = if is_integer(duration), do: max(div(duration, 86_400), 1), else: 1
    Date.to_iso8601(Date.add(start_date, span))
  end

  defp render_end(%Event{dtstart: dtstart, duration: duration}, host_zone) do
    case Ics.resolve(dtstart, host_zone) do
      {:ok, dt} ->
        DateTime.to_iso8601(
          DateTime.add(dt, duration || 0, :second, Calendar.UTCOnlyTimeZoneDatabase)
        )

      _unresolved_or_date ->
        render_time(dtstart, host_zone)
    end
  end

  # The raw RECURRENCE-ID value for the view frontmatter — reconstructed
  # losslessly from the parsed tagged time in RFC 5545 basic format
  # (the parser keeps every component; only the string shape is rebuilt).
  defp raw_recurrence_id(nil), do: ""
  defp raw_recurrence_id({:date, %Date{} = date}), do: basic_date(date)
  defp raw_recurrence_id({:utc, %DateTime{} = dt}), do: basic_datetime(dt) <> "Z"
  defp raw_recurrence_id({:floating, %NaiveDateTime{} = ndt}), do: basic_datetime(ndt)

  defp raw_recurrence_id({:zoned, %NaiveDateTime{} = ndt, tzid}),
    do: "TZID=" <> tzid <> ":" <> basic_datetime(ndt)

  defp basic_date(date), do: Calendar.strftime(date, "%Y%m%d")
  defp basic_datetime(dt), do: Calendar.strftime(dt, "%Y%m%dT%H%M%S")

  # Notices reach status surfaces; external UIDs are arbitrary bytes, so
  # keep printable ASCII only and truncate (the Ics notice posture).
  defp sanitize(nil), do: "?"

  defp sanitize(binary) do
    binary
    |> :binary.bin_to_list()
    |> Enum.filter(&(&1 in 32..126))
    |> Enum.take(60)
    |> List.to_string()
  end

  # -- the swap ---------------------------------------------------------------

  # Renders into `views.tmp-<rand>` (with `.rev` inside), then double-renames
  # it into place. Stale `views.tmp-*`/`views.old-*` debris from an earlier
  # crashed swap is garbage-collected first — a rebuild fully re-renders, so
  # nothing in the debris is ever worth keeping.
  defp swap!(source_dir, views, rev) do
    File.mkdir_p!(source_dir)

    for entry <- File.ls!(source_dir),
        String.starts_with?(entry, "views.tmp-") or String.starts_with?(entry, "views.old-") do
      File.rm_rf!(Path.join(source_dir, entry))
    end

    rand = System.unique_integer([:positive])
    tmp = Path.join(source_dir, "views.tmp-#{rand}")
    events_dir = Path.join(tmp, "events")
    File.mkdir_p!(events_dir)

    Enum.each(views, fn {file, bytes} -> File.write!(Path.join(events_dir, file), bytes) end)
    File.write!(Path.join(tmp, ".rev"), rev)

    views_dir = Path.join(source_dir, "views")
    old = Path.join(source_dir, "views.old-#{rand}")
    if File.exists?(views_dir), do: File.rename!(views_dir, old)
    File.rename!(tmp, views_dir)
    File.rm_rf!(old)

    :ok
  end
end
