defmodule Valea.Calendar.SettingsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Valea.Calendar.Settings
  alias Valea.Calendar.Supervisor, as: CalSupervisor

  @v1_empty "version: 1\nsources: {}\n"

  # The exact placeholder the workspace template shipped before this spec —
  # byte-for-byte what pre-existing workspaces carry.
  @legacy_placeholder """
  account: mara@example.com
  caldav:
    url: https://caldav.example.com/
    username_env: CALDAV_USERNAME
    password_env: CALDAV_PASSWORD
  ics_fallback:
    path: sources/calendar/import.ics
  event_types:
    session: ["coaching", "session", "client"]
    admin: ["admin", "review", "bookkeeping"]
    deep_work: ["deep work", "focus", "writing"]
  """

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "valea-cal-settings-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(root, "config"))
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  defp write!(root, bytes), do: File.write!(Path.join(root, "config/calendar.yaml"), bytes)
  defp read!(root), do: File.read!(Path.join(root, "config/calendar.yaml"))

  describe "load/1" do
    test "absent file is {:error, :absent}", %{root: root} do
      assert {:error, :absent} = Settings.load(root)
    end

    test "the template's v1-empty shape loads as zero sources", %{root: root} do
      write!(root, @v1_empty)

      assert {:ok, %Settings{sources: sources, invalid: invalid, feed_token_hash: nil}} =
               Settings.load(root)

      assert sources == %{}
      assert invalid == %{}
    end

    test "a full v1 document round-trips with explicit window/interval", %{root: root} do
      write!(root, """
      version: 1
      sources:
        work:
          name: "Work (Google)"
          window:
            past_days: 7
            future_days: 60
          interval_minutes: 15
      feed:
        token_hash: "abc123"
      """)

      assert {:ok, settings} = Settings.load(root)

      assert settings.sources == %{
               "work" => %{
                 name: "Work (Google)",
                 past_days: 7,
                 future_days: 60,
                 interval_minutes: 15
               }
             }

      assert settings.feed_token_hash == "abc123"
    end

    test "defaults are past 30 / future 365 / interval 30", %{root: root} do
      write!(root, """
      version: 1
      sources:
        home:
          name: "Home"
      """)

      assert {:ok, settings} = Settings.load(root)

      assert settings.sources["home"] == %{
               name: "Home",
               past_days: 30,
               future_days: 365,
               interval_minutes: 30
             }
    end

    test "interval_minutes below 5 is floored to 5", %{root: root} do
      write!(root, """
      version: 1
      sources:
        a:
          name: "A"
          interval_minutes: 1
        b:
          name: "B"
          interval_minutes: 4
        c:
          name: "C"
          interval_minutes: 5
      """)

      assert {:ok, settings} = Settings.load(root)
      assert settings.sources["a"].interval_minutes == 5
      assert settings.sources["b"].interval_minutes == 5
      assert settings.sources["c"].interval_minutes == 5
    end

    test "a structurally-broken entry lands in invalid while valid entries load", %{root: root} do
      write!(root, """
      version: 1
      sources:
        good:
          name: "Good"
        Bad_Slug:
          name: "Bad"
        no-name:
          window:
            past_days: 5
        bad-window:
          name: "BW"
          window: "tomorrow"
        bad-days:
          name: "BD"
          window:
            past_days: -3
        bad-interval:
          name: "BI"
          interval_minutes: soon
        zero-interval:
          name: "ZI"
          interval_minutes: 0
      """)

      assert {:ok, settings} = Settings.load(root)
      assert Map.keys(settings.sources) == ["good"]

      assert Map.keys(settings.invalid) |> Enum.sort() ==
               ["Bad_Slug", "bad-days", "bad-interval", "bad-window", "no-name", "zero-interval"]
    end

    test "a valea source key is WHOLE-FILE invalid", %{root: root} do
      write!(root, """
      version: 1
      sources:
        fine:
          name: "Fine"
        valea:
          name: "Reserved"
      """)

      assert {:error, {:invalid, reason}} = Settings.load(root)
      assert reason =~ "valea"
    end

    test "junk documents are invalid", %{root: root} do
      write!(root, "just a string\n")
      assert {:error, {:invalid, _}} = Settings.load(root)

      write!(root, "version: 2\nsources: {}\n")
      assert {:error, {:invalid, _}} = Settings.load(root)

      write!(root, "version: 1\nsources: [not, a, map]\n")
      assert {:error, {:invalid, _}} = Settings.load(root)

      write!(root, "version: 1\n")
      assert {:error, {:invalid, _}} = Settings.load(root)

      write!(root, ": [broken yaml\n")
      assert {:error, {:invalid, _}} = Settings.load(root)
    end
  end

  describe "load/1 — legacy placeholder convergence" do
    test "the EXACT legacy placeholder is rewritten to v1-empty once, with a notice", %{
      root: root
    } do
      # The test env's primary Logger level is :warning (config/test.exs);
      # the convergence notice is :info, so raise it for this test only.
      previous_level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: previous_level) end)

      write!(root, @legacy_placeholder)

      log =
        capture_log([level: :info], fn ->
          assert {:ok, %Settings{sources: %{}, invalid: %{}, feed_token_hash: nil}} =
                   Settings.load(root)
        end)

      assert log =~ "legacy placeholder"
      assert read!(root) == @v1_empty

      # Converged: the second load sees a normal v1 file and logs nothing.
      log2 = capture_log([level: :info], fn -> assert {:ok, _} = Settings.load(root) end)
      refute log2 =~ "legacy placeholder"
      assert read!(root) == @v1_empty
    end

    test "an empty document is {:invalid, _} and untouched — never converged", %{root: root} do
      write!(root, "")
      assert {:error, {:invalid, _}} = Settings.load(root)
      assert read!(root) == ""
    end

    test "a subset of legacy keys is {:invalid, _} and untouched", %{root: root} do
      bytes = "account: mara@example.com\ncaldav:\n  url: https://caldav.example.com/\n"
      write!(root, bytes)
      assert {:error, {:invalid, _}} = Settings.load(root)
      assert read!(root) == bytes
    end

    test "legacy keys with an altered value are {:invalid, _} and untouched", %{root: root} do
      bytes = String.replace(@legacy_placeholder, "mara@example.com", "someone@real.example")
      write!(root, bytes)
      assert {:error, {:invalid, _}} = Settings.load(root)
      assert read!(root) == bytes
    end

    test "the placeholder plus an extra key is {:invalid, _} and untouched", %{root: root} do
      bytes = @legacy_placeholder <> "extra: true\n"
      write!(root, bytes)
      assert {:error, {:invalid, _}} = Settings.load(root)
      assert read!(root) == bytes
    end
  end

  describe "load/1 — convergence vs concurrent lifecycle mutations" do
    # The Codex-review race: a reader (calendar_status) sees the exact
    # legacy placeholder, then a SERIALIZED mutation (setup_calendar_source
    # / generate_feed_token, both inside CalSupervisor.lifecycle/1) writes
    # a real v1 config — the stale reader must NOT rename v1-empty over
    # it. Deterministic, no sleeps: the serializer is held open by the
    # test, the loader provably parks behind it (its call is visible in
    # the serializer's mailbox, which implies its stale read completed),
    # the mutation lands, then the serializer is released.
    test "a stale legacy read cannot overwrite a setup serialized in between", %{root: root} do
      # Start the real serializer BEFORE planting the placeholder — its
      # init must not converge the file ahead of the test.
      start_supervised!({CalSupervisor, %{root: root, generation: 1}})
      sup = Process.whereis(CalSupervisor)
      write!(root, @legacy_placeholder)

      test_pid = self()

      holder =
        Task.async(fn ->
          CalSupervisor.lifecycle(fn ->
            send(test_pid, :held)

            receive do
              :release -> :ok
            end
          end)
        end)

      assert_receive :held

      # The stale reader: the file is untouched until put_source below,
      # so this load reads the EXACT placeholder, then blocks on the
      # held serializer before it can write.
      loader = Task.async(fn -> Settings.load(root) end)
      await_lifecycle_queued(sup)

      # The serialized mutation lands while the stale reader is parked.
      assert :ok = Settings.put_source(root, "work", "Work")

      send(sup, :release)
      assert :ok = Task.await(holder)

      # The stale convergence no-oped and loaded what actually won.
      assert {:ok, %Settings{sources: %{"work" => %{name: "Work"}}}} = Task.await(loader)
      assert {:ok, %Settings{sources: sources}} = Settings.load(root)
      assert Map.keys(sources) == ["work"]
      refute read!(root) == @v1_empty
    end

    test "without a supervisor, racing loads both converge with no torn writes", %{root: root} do
      # Fallback path: no serializer process — each load re-reads before
      # its rename and writes through a UNIQUE temp name.
      assert Process.whereis(CalSupervisor) == nil
      write!(root, @legacy_placeholder)

      [a, b] = for _i <- 1..2, do: Task.async(fn -> Settings.load(root) end)

      assert {:ok, %Settings{sources: sources_a, feed_token_hash: nil}} = Task.await(a)
      assert {:ok, %Settings{sources: sources_b, feed_token_hash: nil}} = Task.await(b)
      assert sources_a == %{}
      assert sources_b == %{}

      # Exactly the converged v1-empty document, byte-for-byte — and no
      # temp-file debris (every unique tmp was renamed into place).
      assert read!(root) == @v1_empty
      assert Path.wildcard(Path.join(root, "config/calendar.yaml.tmp*")) == []
    end
  end

  # Spin (a pure state check — never proceeds early, no sleeps) until a
  # lifecycle call is parked in the serializer's mailbox. GenServer.call
  # enqueues its request message before blocking, so once the call is
  # visible the loader has necessarily finished its stale read.
  defp await_lifecycle_queued(sup, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 5_000

    {:messages, messages} = Process.info(sup, :messages)

    queued? =
      Enum.any?(messages, fn
        {:"$gen_call", _from, {:lifecycle, _fun}} -> true
        _other -> false
      end)

    cond do
      queued? ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("Settings.load never queued behind the held lifecycle serializer")

      true ->
        :erlang.yield()
        await_lifecycle_queued(sup, deadline)
    end
  end

  describe "valid_slug?/1" do
    test "grammar" do
      assert Settings.valid_slug?("work")
      assert Settings.valid_slug?("a")
      assert Settings.valid_slug?("work-cal-2")
      assert Settings.valid_slug?("0numeric")
      assert Settings.valid_slug?(String.duplicate("a", 32))
      refute Settings.valid_slug?("")
      refute Settings.valid_slug?("-lead")
      refute Settings.valid_slug?("UPPER")
      refute Settings.valid_slug?("with_underscore")
      refute Settings.valid_slug?("with space")
      refute Settings.valid_slug?(String.duplicate("a", 33))
      refute Settings.valid_slug?(nil)
    end

    test "valea is reserved even though it matches the grammar" do
      refute Settings.valid_slug?("valea")
    end
  end

  describe "put_source/3" do
    test "creates a fresh v1 file when absent", %{root: root} do
      assert :ok = Settings.put_source(root, "work", "Work")
      assert {:ok, settings} = Settings.load(root)

      assert settings.sources == %{
               "work" => %{name: "Work", past_days: 30, future_days: 365, interval_minutes: 30}
             }
    end

    test "rejects a bad slug and the reserved valea slug", %{root: root} do
      assert {:error, :invalid_slug} = Settings.put_source(root, "Bad_Slug", "X")
      assert {:error, :invalid_slug} = Settings.put_source(root, "valea", "X")
      refute File.exists?(Path.join(root, "config/calendar.yaml"))
    end

    test "rejects a blank name", %{root: root} do
      assert {:error, :invalid_name} = Settings.put_source(root, "work", "")
      refute File.exists?(Path.join(root, "config/calendar.yaml"))
    end

    test "preserves other sources and their window config on a valid file", %{root: root} do
      write!(root, """
      version: 1
      sources:
        work:
          name: "Work"
          window:
            past_days: 7
            future_days: 60
          interval_minutes: 15
      """)

      assert :ok = Settings.put_source(root, "home", "Home")
      assert {:ok, settings} = Settings.load(root)

      assert settings.sources["work"] == %{
               name: "Work",
               past_days: 7,
               future_days: 60,
               interval_minutes: 15
             }

      assert settings.sources["home"].name == "Home"
    end

    test "re-putting an existing slug updates the name but keeps its window config", %{root: root} do
      write!(root, """
      version: 1
      sources:
        work:
          name: "Old"
          window:
            past_days: 7
            future_days: 60
          interval_minutes: 15
      """)

      assert :ok = Settings.put_source(root, "work", "New name")
      assert {:ok, settings} = Settings.load(root)

      assert settings.sources["work"] == %{
               name: "New name",
               past_days: 7,
               future_days: 60,
               interval_minutes: 15
             }
    end

    test "a name with YAML metacharacters cannot break the file", %{root: root} do
      name = "x: y\n  evil: \"quote\" \\ trail"
      assert :ok = Settings.put_source(root, "work", name)
      assert {:ok, settings} = Settings.load(root)
      # Control characters are neutralized to spaces; everything else survives.
      assert settings.sources["work"].name == "x: y   evil: \"quote\" \\ trail"
      assert map_size(settings.sources) == 1
    end
  end

  describe "generate_feed_token/1" do
    test "returns a 32-byte base64url token and persists only its sha256 hex", %{root: root} do
      write!(root, @v1_empty)

      assert {:ok, token} = Settings.generate_feed_token(root)
      assert {:ok, raw} = Base.url_decode64(token, padding: false)
      assert byte_size(raw) == 32

      expected_hash = :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
      file = read!(root)
      refute file =~ token
      assert file =~ expected_hash

      assert {:ok, %Settings{feed_token_hash: ^expected_hash}} = Settings.load(root)
    end

    test "a second call rotates the hash", %{root: root} do
      write!(root, @v1_empty)

      assert {:ok, token1} = Settings.generate_feed_token(root)
      assert {:ok, %Settings{feed_token_hash: hash1}} = Settings.load(root)

      assert {:ok, token2} = Settings.generate_feed_token(root)
      assert {:ok, %Settings{feed_token_hash: hash2}} = Settings.load(root)

      assert token1 != token2
      assert hash1 != hash2
      assert hash2 == :crypto.hash(:sha256, token2) |> Base.encode16(case: :lower)
    end
  end

  describe "mutation interactions" do
    test "put_source and remove_source preserve an existing token_hash", %{root: root} do
      write!(root, @v1_empty)
      {:ok, token} = Settings.generate_feed_token(root)
      hash = :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

      assert :ok = Settings.put_source(root, "work", "Work")
      assert {:ok, %Settings{feed_token_hash: ^hash}} = Settings.load(root)

      assert :ok = Settings.remove_source(root, "work")
      assert {:ok, %Settings{feed_token_hash: ^hash, sources: sources}} = Settings.load(root)
      assert sources == %{}
    end

    test "generate_feed_token preserves configured sources", %{root: root} do
      assert :ok = Settings.put_source(root, "work", "Work")
      assert {:ok, _token} = Settings.generate_feed_token(root)

      assert {:ok, settings} = Settings.load(root)
      assert Map.keys(settings.sources) == ["work"]
      assert settings.feed_token_hash != nil
    end

    test "put_source on an invalid file replaces it wholesale with only its own change", %{
      root: root
    } do
      write!(root, "version: 99\nsources: {}\nfeed:\n  token_hash: \"stale\"\n")

      assert :ok = Settings.put_source(root, "work", "Work")
      assert {:ok, settings} = Settings.load(root)
      assert Map.keys(settings.sources) == ["work"]
      # Nothing from the invalid file survives — no inherited token hash.
      assert settings.feed_token_hash == nil
    end

    test "put_source on a legacy-shaped (but not exact) file replaces it wholesale", %{root: root} do
      write!(root, String.replace(@legacy_placeholder, "mara@example.com", "real@example.org"))

      assert :ok = Settings.put_source(root, "work", "Work")
      assert {:ok, settings} = Settings.load(root)
      assert Map.keys(settings.sources) == ["work"]
      assert settings.feed_token_hash == nil
    end

    test "put_source on the EXACT legacy placeholder yields a fresh v1 with only its change", %{
      root: root
    } do
      write!(root, @legacy_placeholder)

      assert :ok = Settings.put_source(root, "work", "Work")
      assert {:ok, settings} = Settings.load(root)
      assert Map.keys(settings.sources) == ["work"]
      assert settings.feed_token_hash == nil
    end

    test "generate_feed_token on an invalid file replaces it wholesale with only the token", %{
      root: root
    } do
      write!(root, "version: 99\nsources:\n  stale:\n    name: \"Stale\"\n")

      assert {:ok, _token} = Settings.generate_feed_token(root)
      assert {:ok, settings} = Settings.load(root)
      # No inherited sources from the invalid file.
      assert settings.sources == %{}
      assert settings.feed_token_hash != nil
    end

    test "generate_feed_token on a legacy-shaped file replaces it wholesale", %{root: root} do
      write!(root, @legacy_placeholder <> "extra: true\n")

      assert {:ok, _token} = Settings.generate_feed_token(root)
      assert {:ok, settings} = Settings.load(root)
      assert settings.sources == %{}
      assert settings.feed_token_hash != nil
    end

    test "remove_source on an invalid file is non-destructive: error + byte-identical", %{
      root: root
    } do
      bytes = "version: 99\nsources:\n  work:\n    name: \"Work\"\n"
      write!(root, bytes)

      assert {:error, {:invalid, _}} = Settings.remove_source(root, "work")
      assert read!(root) == bytes
    end

    test "remove_source on a legacy-shaped file is non-destructive: error + byte-identical", %{
      root: root
    } do
      bytes = String.replace(@legacy_placeholder, "mara@example.com", "real@example.org")
      write!(root, bytes)

      assert {:error, {:invalid, _}} = Settings.remove_source(root, "work")
      assert read!(root) == bytes
    end

    test "remove_source on the EXACT legacy placeholder is non-destructive too", %{root: root} do
      write!(root, @legacy_placeholder)

      assert {:error, {:invalid, _}} = Settings.remove_source(root, "work")
      assert read!(root) == @legacy_placeholder
    end

    test "remove_source on an absent file is a no-op that creates nothing", %{root: root} do
      assert :ok = Settings.remove_source(root, "work")
      refute File.exists?(Path.join(root, "config/calendar.yaml"))
    end

    test "remove_source rejects an invalid slug without touching the file", %{root: root} do
      write!(root, @v1_empty)
      assert {:error, :invalid_slug} = Settings.remove_source(root, "Bad_Slug")
      assert read!(root) == @v1_empty
    end
  end

  describe "env_var/1" do
    test "upcases and maps dashes to underscores" do
      assert Settings.env_var("work") == "VALEA_CAL_URL_WORK"
      assert Settings.env_var("work-cal-2") == "VALEA_CAL_URL_WORK_CAL_2"
    end
  end
end
