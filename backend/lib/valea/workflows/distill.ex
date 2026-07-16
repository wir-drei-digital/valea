defmodule Valea.Workflows.Distill do
  @moduledoc """
  Compiles the reflection workflow's input: a self-contained markdown
  digest of recently decided queue items, so the agent reads one
  server-owned document and the read boundary never widens to queue/.

  Reads `queue/approved/*.json` + `queue/rejected/*.json` directly — the
  decided source of truth — rather than round-tripping through a
  `Valea.Workspace.Manager`-dependent read (this module is a pure function
  of `workspace`, callable outside that context, mirroring every other
  `Runner`-adjacent module).

  Window: fixed 30 days by `decided_at` (both decision verbs stamp this
  ISO-8601 field since the v2 upgrade). An envelope
  without the stamp is EXCLUDED, not treated as always-in-window — an old
  pre-stamp envelope carries no reliable decision time to sort or window by.
  """

  @window_days 30

  @doc """
  `{count, markdown}` — every decided item (`queue/approved` +
  `queue/rejected`) with a `decided_at` inside the last #{@window_days}
  days, newest first.
  """
  @spec digest(String.t()) :: {non_neg_integer(), String.t()}
  def digest(workspace) do
    now = DateTime.utc_now()
    cutoff = DateTime.add(now, -@window_days, :day)

    items =
      for dir <- ["approved", "rejected"],
          path <- Path.wildcard(Path.join([workspace, "queue", dir, "*.json"])),
          {:ok, bytes} <- [File.read(path)],
          {:ok, %{} = item} <- [Jason.decode(bytes)],
          decided_at = parse_ts(item["decided_at"]),
          decided_at != nil,
          DateTime.compare(decided_at, cutoff) == :gt,
          DateTime.compare(decided_at, now) != :gt do
        {decided_at, dir, item}
      end
      |> Enum.sort_by(fn {ts, _, _} -> ts end, {:desc, DateTime})

    md =
      ([
         "# Recent decisions (last #{@window_days} days)",
         "",
         "Each entry is one item the user decided. Rejections with a reason",
         "are the strongest teaching signal.",
         ""
       ] ++ Enum.flat_map(items, &entry/1))
      |> Enum.join("\n")

    {length(items), md}
  end

  defp entry({ts, dir, item}) do
    decided = if dir == "approved", do: "approved", else: "rejected"

    payload =
      if is_map(item["payload"]) do
        item["payload"]
      else
        %{}
      end

    reason =
      case item["decision"] do
        %{"reason" => r} -> r
        _ -> nil
      end

    [
      "### #{sanitize(payload["title"] || item["run_id"])}",
      "- kind: #{sanitize(payload["kind"])}",
      "- workflow: #{sanitize(item["workflow"])}",
      "- decided: #{decided} on #{ts |> DateTime.to_date() |> Date.to_iso8601()}"
    ] ++
      if(reason, do: ["- reason: #{sanitize(reason)}"], else: []) ++ [""]
  end

  # Collapse control chars so no value can span lines — every value here
  # renders mid-line after a literal prefix, so line-start escaping is unnecessary.
  defp sanitize(nil), do: ""

  defp sanitize(s) when is_binary(s) do
    s
    |> String.replace(~r/[\x00-\x1F\x7F]+/u, " ")
    |> String.trim()
  end

  defp sanitize(other), do: inspect(other)

  defp parse_ts(nil), do: nil

  defp parse_ts(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_ts(_), do: nil
end
