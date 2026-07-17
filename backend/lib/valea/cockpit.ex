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
  """

  @doc """
  Returns the Today cockpit payload as a map with string keys, ready for JSON.

  Returns `{:ok, map}` with keys:
    - "sections": one per enabled ICM that has a readable `today.json`, in
      `Valea.Mounts.enabled/0` order — `%{"mount_key", "icm_name", "ok",
      "updated_at", "notes", "prepared", "open_loops"}` (see moduledoc for
      the leniency contract)
    - "mail": a LIST, one entry per running `Valea.Mail.Engine` (i.e. one
      per valid account) — `%{"account", "configured" => true, "state",
      "pending_ops", "notices"}`, live off `Valea.Mail.Engine.statuses/0`
      (Registry enumeration; empty list when no workspace is open or no
      account is configured yet)
    - "recent_sessions": up to 5 most recent sessions, newest first —
      `%{"id", "title", "started_at", "status", "live"}`
  """
  def today do
    {:ok,
     %{
       "sections" => icm_sections(),
       "mail" => mail_summary(),
       "recent_sessions" => recent_sessions()
     }}
  end

  defp icm_sections do
    case Valea.Mounts.enabled() do
      {:ok, mounts} -> mounts |> Enum.map(&icm_section/1) |> Enum.reject(&is_nil/1)
      {:error, :no_workspace} -> []
    end
  end

  defp icm_section(mount) do
    base = %{"mount_key" => mount.name, "icm_name" => mount.manifest.name}

    case File.read(Path.join(mount.root, "today.json")) do
      {:error, :enoent} ->
        nil

      {:error, _reason} ->
        unreadable_section(base)

      {:ok, raw} ->
        case parse_today(raw) do
          {:ok, fields} -> base |> Map.put("ok", true) |> Map.merge(fields)
          :error -> unreadable_section(base)
        end
    end
  end

  defp unreadable_section(base) do
    base |> Map.put("ok", false) |> Map.merge(empty_fields())
  end

  defp empty_fields do
    %{"updated_at" => nil, "notes" => nil, "prepared" => [], "open_loops" => []}
  end

  defp parse_today(raw) do
    case Jason.decode(raw) do
      {:ok, %{} = doc} ->
        {:ok,
         %{
           "updated_at" => str_or_nil(doc["updated_at"]),
           "notes" => str_or_nil(doc["notes"]),
           "prepared" => items(doc["prepared"], ["title", "summary", "page"]),
           "open_loops" => items(doc["open_loops"], ["title", "source"])
         }}

      _ ->
        :error
    end
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
    %{
      "account" => slug,
      "configured" => true,
      "state" => status.state,
      # The `mail_pending_ops` ledger genuinely exists (`Valea.Mail.Store`),
      # but nothing writes real rows to it yet — the ops executor that would
      # is Task 13. Hardcoded 0 rather than reading a ledger that's
      # perpetually empty today.
      "pending_ops" => 0,
      "notices" => status.notices
    }
  end
end
