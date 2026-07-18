defmodule ValeaWeb.CalendarFeedControllerTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Plug.Conn, only: [get_resp_header: 2]

  @endpoint ValeaWeb.Endpoint

  alias Valea.Calendar.Settings
  alias Valea.Workspace.Manager

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-app-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    System.put_env("VALEA_APP_DIR", dir)
    Manager.close()
    {:ok, %{path: ws}} = Manager.create("Primary")

    on_exit(fn ->
      Manager.close()
      File.rm_rf!(dir)
      System.delete_env("VALEA_APP_DIR")
    end)

    %{conn: build_conn(), workspace: ws}
  end

  defp write_event!(ws, filename, bytes) do
    dir = Path.join(ws, "sources/calendar/valea/events")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, filename), bytes)
  end

  defp valid_event_bytes do
    "---\ntitle: \"Coffee\"\nstart: 2026-07-21T09:30:00+02:00\n---\nAgenda.\n"
  end

  defp fetch_feed(token) do
    get(build_conn(), "/calendar/feed.ics", %{"token" => token})
  end

  test "a valid token serves the rendered valea events as text/calendar", %{workspace: ws} do
    write_event!(ws, "coffee.md", valid_event_bytes())
    {:ok, token} = Settings.generate_feed_token(ws)

    conn = fetch_feed(token)
    body = response(conn, 200)

    assert get_resp_header(conn, "content-type") |> hd() =~ "text/calendar"
    assert get_resp_header(conn, "content-type") |> hd() =~ "charset=utf-8"

    assert body =~ "BEGIN:VCALENDAR"
    assert body =~ "SUMMARY:Coffee"
    assert body =~ "DTSTART:20260721T073000Z"
  end

  test "invalid event files are rendered nowhere", %{workspace: ws} do
    write_event!(ws, "good.md", valid_event_bytes())

    write_event!(
      ws,
      "bad.md",
      "---\ntitle: \"Nope\"\nstart: 2026-07-21T09:30:00+02:00\ncolor: red\n---\n"
    )

    {:ok, token} = Settings.generate_feed_token(ws)

    body = response(fetch_feed(token), 200)
    assert body =~ "SUMMARY:Coffee"
    refute body =~ "Nope"
  end

  test "no token configured (fresh workspace) is 404 with an empty body", %{workspace: ws} do
    write_event!(ws, "coffee.md", valid_event_bytes())
    conn = fetch_feed("any-guess")
    assert response(conn, 404) == ""
  end

  test "a missing token parameter is 404 empty", %{workspace: ws} do
    {:ok, _token} = Settings.generate_feed_token(ws)
    conn = get(build_conn(), "/calendar/feed.ics")
    assert response(conn, 404) == ""
  end

  test "a wrong token is 404 empty", %{workspace: ws} do
    {:ok, _token} = Settings.generate_feed_token(ws)
    conn = fetch_feed("wrong-token")
    assert response(conn, 404) == ""
  end

  test "the stored hash itself never authenticates (compare is over sha256(param))", %{
    workspace: ws
  } do
    {:ok, _token} = Settings.generate_feed_token(ws)
    {:ok, %Settings{feed_token_hash: hash}} = Settings.load(ws)

    conn = fetch_feed(hash)
    assert response(conn, 404) == ""
  end

  test "NO other parameters are honored — extra params 404 even with a valid token", %{
    workspace: ws
  } do
    {:ok, token} = Settings.generate_feed_token(ws)

    conn = get(build_conn(), "/calendar/feed.ics", %{"token" => token, "source" => "work"})
    assert response(conn, 404) == ""
  end

  test "a non-binary token parameter is 404, not a crash", %{workspace: ws} do
    {:ok, _token} = Settings.generate_feed_token(ws)

    conn = get(build_conn(), "/calendar/feed.ics", %{"token" => %{"nested" => "x"}})
    assert response(conn, 404) == ""
  end

  test "an invalid calendar.yaml is 404, never detail", %{workspace: ws} do
    File.write!(Path.join(ws, "config/calendar.yaml"), "totally: [broken\n")
    conn = fetch_feed("anything")
    assert response(conn, 404) == ""
  end

  test "rotation invalidates the old token", %{workspace: ws} do
    write_event!(ws, "coffee.md", valid_event_bytes())
    {:ok, old_token} = Settings.generate_feed_token(ws)
    assert response(fetch_feed(old_token), 200) =~ "BEGIN:VCALENDAR"

    {:ok, new_token} = Settings.generate_feed_token(ws)
    assert response(fetch_feed(old_token), 404) == ""
    assert response(fetch_feed(new_token), 200) =~ "BEGIN:VCALENDAR"
  end

  test "the route is token-exempt from the control token (no header sent)", %{workspace: ws} do
    {:ok, token} = Settings.generate_feed_token(ws)

    # No x-valea-token header anywhere in this request.
    conn = get(build_conn(), "/calendar/feed.ics", %{"token" => token})
    assert response(conn, 200) =~ "BEGIN:VCALENDAR"
  end

  test "an empty feed still serves a well-formed empty VCALENDAR", %{workspace: ws} do
    {:ok, token} = Settings.generate_feed_token(ws)

    body = response(fetch_feed(token), 200)
    assert body =~ "BEGIN:VCALENDAR"
    refute body =~ "BEGIN:VEVENT"
  end
end
