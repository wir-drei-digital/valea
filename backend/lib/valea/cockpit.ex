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
    - "mail": `%{"review_count", "inbox_count", "configured"}` — live, read
      from `Valea.Mail.Store`/`Valea.Mail.Engine`
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

  # See the moduledoc: `Process.whereis/1` is the SAME guard
  # `Valea.Audit.entries/1` uses, for the same reason — no workspace open (or
  # one mid-switch) means `Valea.Mail.Engine` isn't registered, and calling
  # its `GenServer.call/2` anyway would exit `:noproc` and take this whole
  # RPC/channel call down instead of degrading gracefully.
  #
  # The whereis check does NOT cover `Valea.Mail.Store` (i.e. `Valea.Repo`),
  # though: the Repo is NOT a `Valea.Workspace.Runtime` child — the Manager
  # starts it directly under `Valea.Workspace.DynamicSupervisor` BEFORE the
  # Runtime (`manager.ex`: `start_repo` → `migrate` → `start_runtime`), and
  # `do_close/1` terminates `state.children` in that same list order, so on
  # every close/switch the Repo goes down FIRST while the Engine's name is
  # still registered. A `today/0` call landing in that window (or racing an
  # Engine crash) passes the whereis guard and then hits a dead Repo — which
  # is what `live_mail_summary/0`'s rescue/catch is for.
  defp mail_summary do
    if Process.whereis(Valea.Mail.Engine) do
      live_mail_summary()
    else
      zero_mail_summary()
    end
  end

  # `state: "inactive"` — the Engine is registered but hasn't processed its
  # `:workspace_opened` activation yet (activation is async in the Engine's
  # own mailbox; `Index.rebuild/1` only runs there). Counts read this early
  # would be whatever the previous session left in the cache, so report the
  # deterministic zero/unconfigured shape instead; activation ends with a
  # `mail_status` broadcast, and the Today page refetches this payload on
  # that push (see `+page.svelte`), so the real counts follow immediately.
  #
  # rescue/catch: degrade to the zero summary the whereis guard already
  # promises — deliberately broad, because the failure modes here are "some
  # dependency of the read is down", not a specific exception type:
  # `Store.*` raises assorted DB errors (`DBConnection.ConnectionError`,
  # `Exqlite.Error`, Ash wrappers) when the Repo is down (see the close
  # ordering note above), and `Engine.status/0` exits `:noproc` if the
  # Engine dies between the whereis check and the call.
  defp live_mail_summary do
    case Valea.Mail.Engine.status() do
      %{state: "inactive"} ->
        zero_mail_summary()

      status ->
        review_count =
          Valea.Mail.Store.list_messages() |> Enum.count(&(&1.status == "review"))

        %{
          "review_count" => review_count,
          "inbox_count" => length(Valea.Mail.Store.inbox_headers()),
          "configured" => status.configured
        }
    end
  rescue
    _ -> zero_mail_summary()
  catch
    :exit, _ -> zero_mail_summary()
  end

  defp zero_mail_summary do
    %{"review_count" => 0, "inbox_count" => 0, "configured" => false}
  end
end
