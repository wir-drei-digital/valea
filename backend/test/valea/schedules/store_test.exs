defmodule Valea.Schedules.StoreTest do
  use ExUnit.Case, async: false

  alias Valea.Schedules.Store

  @icm "icm-work"
  @other_icm "icm-life"

  # Focused unit tests, mirroring `Valea.Mail.StoreTest`: start `Valea.Repo`
  # directly against a tmp `app.sqlite` + run the real migrations, rather than
  # going through the full `Valea.Workspace.Manager` open lifecycle (ICM
  # watcher, runtime, scaffold — none of which `Store` needs).
  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-schedules-store-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)

    # pool_size: 1 — see the identical comment in `Valea.Mail.StoreTest`.
    start_supervised!({Valea.Repo, database: Path.join(dir, "app.sqlite"), pool_size: 1})

    migrations_path =
      Application.get_env(:valea, :migrations_path) || Ecto.Migrator.migrations_path(Valea.Repo)

    previous_compiler_options = Code.compiler_options(ignore_module_conflict: true)
    Ecto.Migrator.run(Valea.Repo, migrations_path, :up, all: true)
    Code.compiler_options(previous_compiler_options)

    on_exit(fn -> File.rm_rf!(dir) end)

    :ok
  end

  # -- helpers -----------------------------------------------------------------

  defp at(iso) do
    {:ok, dt, 0} = DateTime.from_iso8601(iso)
    dt
  end

  defp run_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        icm_id: @icm,
        schedule_id: "s-morning",
        fingerprint: "fp1",
        slot: at("2026-07-30T07:30:00Z"),
        fired_at: at("2026-07-30T07:30:02Z"),
        trigger: "scheduled",
        kind: "prompt",
        outcome: "running",
        duration_ms: nil,
        session_id: nil,
        output: nil,
        coalesced_count: 1,
        mount_key: "work"
      },
      overrides
    )
  end

  # Every SQL statement Ecto emits while `fun` runs. Used to assert the shape
  # of the upsert itself, which no read-back can distinguish (see the
  # `SET`-list test).
  defp capture_sql(fun) do
    test = self()
    handler = "schedules-store-test-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:valea, :repo, :query],
      fn _event, _measurements, %{query: query}, _config -> send(test, {:sql, query}) end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler)
    end

    drain_sql([])
  end

  defp drain_sql(acc) do
    receive do
      {:sql, query} -> drain_sql([query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp state_row_count do
    Ecto.Adapters.SQL.query!(Valea.Repo, "SELECT count(*) FROM schedule_state", []).rows
    |> hd()
    |> hd()
  end

  # -- schedule_state ----------------------------------------------------------

  describe "get_state/2 + put_state/3" do
    test "get_state/2 is nil before anything is written" do
      assert Store.get_state(@icm, "s-morning") == nil
    end

    test "put_state/3 writes every column and get_state/2 reads it back" do
      assert :ok =
               Store.put_state(@icm, "s-morning", %{
                 fingerprint: "fp1",
                 first_seen_at: at("2026-07-30T06:00:00Z"),
                 last_attempted_slot: at("2026-07-30T07:30:00Z"),
                 deleted_at: nil
               })

      assert %{
               icm_id: @icm,
               schedule_id: "s-morning",
               fingerprint: "fp1",
               first_seen_at: ~U[2026-07-30 06:00:00Z],
               last_attempted_slot: ~U[2026-07-30 07:30:00Z],
               deleted_at: nil
             } = Store.get_state(@icm, "s-morning")
    end

    test "a second put_state/3 overwrites fingerprint + anchor in place (one row, not two)" do
      :ok =
        Store.put_state(@icm, "s-morning", %{
          fingerprint: "fp1",
          first_seen_at: at("2026-07-30T06:00:00Z"),
          last_attempted_slot: at("2026-07-30T07:30:00Z")
        })

      assert state_row_count() == 1

      :ok =
        Store.put_state(@icm, "s-morning", %{
          fingerprint: "fp2",
          first_seen_at: at("2026-07-30T09:00:00Z"),
          last_attempted_slot: at("2026-07-30T09:00:00Z")
        })

      assert state_row_count() == 1

      assert %{
               fingerprint: "fp2",
               first_seen_at: ~U[2026-07-30 09:00:00Z],
               last_attempted_slot: ~U[2026-07-30 09:00:00Z]
             } = Store.get_state(@icm, "s-morning")
    end

    test "keys omitted from attrs keep their stored value (anchor advance never loses the fingerprint)" do
      :ok =
        Store.put_state(@icm, "s-morning", %{
          fingerprint: "fp1",
          first_seen_at: at("2026-07-30T06:00:00Z"),
          last_attempted_slot: at("2026-07-30T07:30:00Z")
        })

      assert :ok =
               Store.put_state(@icm, "s-morning", %{
                 last_attempted_slot: at("2026-07-30T08:30:00Z")
               })

      assert %{
               fingerprint: "fp1",
               first_seen_at: ~U[2026-07-30 06:00:00Z],
               last_attempted_slot: ~U[2026-07-30 08:30:00Z],
               deleted_at: nil
             } = Store.get_state(@icm, "s-morning")
    end

    test "deleted_at is a tombstone an explicit nil clears" do
      :ok = Store.put_state(@icm, "s-morning", %{fingerprint: "fp1"})
      :ok = Store.put_state(@icm, "s-morning", %{deleted_at: at("2026-07-30T10:00:00Z")})

      assert %{deleted_at: ~U[2026-07-30 10:00:00Z], fingerprint: "fp1"} =
               Store.get_state(@icm, "s-morning")

      # Reappearance: the reconciler resets the anchors AND clears the
      # tombstone in one write, so `nil` has to mean "clear it", not "leave it".
      assert :ok =
               Store.put_state(@icm, "s-morning", %{
                 fingerprint: "fp1",
                 first_seen_at: at("2026-07-30T11:00:00Z"),
                 last_attempted_slot: at("2026-07-30T11:00:00Z"),
                 deleted_at: nil
               })

      assert %{deleted_at: nil, first_seen_at: ~U[2026-07-30 11:00:00Z]} =
               Store.get_state(@icm, "s-morning")
    end

    test "the key is (icm_id, schedule_id) — the same schedule id in two ICMs is two states" do
      :ok = Store.put_state(@icm, "s-morning", %{fingerprint: "fp-work"})
      :ok = Store.put_state(@other_icm, "s-morning", %{fingerprint: "fp-life"})

      assert %{fingerprint: "fp-work"} = Store.get_state(@icm, "s-morning")
      assert %{fingerprint: "fp-life"} = Store.get_state(@other_icm, "s-morning")
      assert state_row_count() == 2
    end

    # Pins `put_state/3`'s read-modify-write, which is forward-insurance and so
    # cannot be caught by any read-back: `State` declares no attribute
    # defaults, so a bare upsert preserves omitted columns just as well TODAY.
    # What the merge changes is the emitted statement — every mutable column
    # enters the `SET` list, carrying its stored value, instead of only the
    # keys this call passed. Give any of those columns a `default:` later and
    # the bare form would start writing that default over stored data (the live
    # `Valea.Mail.Store.put_sync_state/3` bug); this assertion is what makes
    # deleting the merge fail loudly instead of quietly re-arming it.
    test "a partial put_state/3 still names every mutable column in the upsert's SET list" do
      :ok = Store.put_state(@icm, "s-morning", %{fingerprint: "fp1"})

      sql =
        capture_sql(fn ->
          Store.put_state(@icm, "s-morning", %{last_attempted_slot: at("2026-07-30T08:30:00Z")})
        end)

      upsert = Enum.find(sql, &String.contains?(&1, ~s(INSERT INTO "schedule_state")))
      assert upsert, "no INSERT INTO schedule_state was emitted"

      for column <- ["fingerprint", "first_seen_at", "last_attempted_slot", "deleted_at"] do
        assert String.contains?(upsert, ~s("#{column}" = EXCLUDED."#{column}")),
               "#{column} missing from the upsert SET list — put_state/3 stopped " <>
                 "merging over the stored row:\n#{upsert}"
      end
    end

    test "sub-second precision is truncated (anchors are second-granular)" do
      :ok =
        Store.put_state(@icm, "s-morning", %{
          first_seen_at: ~U[2026-07-30 06:00:00.987654Z]
        })

      assert %{first_seen_at: ~U[2026-07-30 06:00:00Z]} = Store.get_state(@icm, "s-morning")
    end
  end

  describe "states_for/1" do
    test "is empty for an ICM with nothing stored" do
      assert Store.states_for(@icm) == []
    end

    test "returns every state for the ICM — tombstoned rows included — and no other ICM's" do
      :ok = Store.put_state(@icm, "s-a", %{fingerprint: "fp-a"})

      :ok =
        Store.put_state(@icm, "s-b", %{
          fingerprint: "fp-b",
          deleted_at: at("2026-07-30T10:00:00Z")
        })

      :ok = Store.put_state(@other_icm, "s-c", %{fingerprint: "fp-c"})

      states = Store.states_for(@icm)

      assert Enum.map(states, & &1.schedule_id) |> Enum.sort() == ["s-a", "s-b"]

      assert %{deleted_at: ~U[2026-07-30 10:00:00Z]} =
               Enum.find(states, &(&1.schedule_id == "s-b"))
    end
  end

  # -- schedule_runs -----------------------------------------------------------

  describe "record_run/1" do
    test "returns a run id and the row reads back through runs/3" do
      assert {:ok, run_id} = Store.record_run(run_attrs())
      assert is_binary(run_id)

      assert [
               %{
                 id: ^run_id,
                 icm_id: @icm,
                 schedule_id: "s-morning",
                 fingerprint: "fp1",
                 slot: ~U[2026-07-30 07:30:00Z],
                 fired_at: ~U[2026-07-30 07:30:02Z],
                 trigger: "scheduled",
                 kind: "prompt",
                 outcome: "running",
                 duration_ms: nil,
                 session_id: nil,
                 output: nil,
                 coalesced_count: 1,
                 mount_key: "work"
               }
             ] = Store.runs(@icm, "s-morning", 10)
    end

    test "fired_at defaults to now and coalesced_count to 1" do
      before = DateTime.utc_now() |> DateTime.add(-1, :second)

      assert {:ok, _id} =
               Store.record_run(%{
                 icm_id: @icm,
                 schedule_id: "s-morning",
                 trigger: "manual",
                 kind: "command",
                 outcome: "running"
               })

      assert [%{fired_at: fired_at, coalesced_count: 1}] = Store.runs(@icm, "s-morning", 10)
      assert DateTime.compare(fired_at, before) in [:gt, :eq]
    end

    test "outcomes are free-form strings — every token the spec names round-trips" do
      outcomes = [
        "running",
        "completed",
        "failed",
        "skipped: still running",
        "interrupted",
        "timed out",
        "waiting"
      ]

      for {outcome, index} <- Enum.with_index(outcomes) do
        {:ok, _id} =
          Store.record_run(
            run_attrs(%{
              outcome: outcome,
              fired_at: DateTime.add(at("2026-07-30T07:00:00Z"), index, :second)
            })
          )
      end

      assert Store.runs(@icm, "s-morning", 10) |> Enum.map(& &1.outcome) ==
               Enum.reverse(outcomes)
    end

    test "a missing key column or an unrecognised field raises — a history row must not lie" do
      assert_raise Ash.Error.Invalid, ~r/attribute icm_id is required/, fn ->
        Store.record_run(%{schedule_id: "s-morning", outcome: "completed"})
      end

      assert_raise Ash.Error.Invalid, ~r/No such input `bogus`/, fn ->
        Store.record_run(run_attrs() |> Map.put(:bogus, 1))
      end
    end

    # `default:` fills an ABSENT key only. Without `allow_nil? false` this
    # stored a NULL, and a NULL fails `fired_at >= ?` — the failed run would
    # show in runs/3 while never reaching the cockpit notices.
    test "an explicit fired_at: nil raises — a NULL would hide the run from notices_since/1" do
      assert_raise Ash.Error.Invalid, ~r/fired_at/, fn ->
        Store.record_run(run_attrs(%{outcome: "failed", fired_at: nil}))
      end

      assert Store.runs(@icm, "s-morning", 10) == []
      assert Store.notices_since(at("2000-01-01T00:00:00Z")).failed == []
    end

    test "output is stored verbatim — the store never re-caps what the caller capped" do
      output = String.duplicate("x", 50_000)

      {:ok, _id} = Store.record_run(run_attrs(%{output: output}))

      assert [%{output: ^output}] = Store.runs(@icm, "s-morning", 10)
    end
  end

  describe "runs/3" do
    test "is newest-first and honours the limit" do
      for hour <- 5..8 do
        {:ok, _id} =
          Store.record_run(
            run_attrs(%{
              fired_at: at("2026-07-30T0#{hour}:00:00Z"),
              output: "run-#{hour}"
            })
          )
      end

      assert Store.runs(@icm, "s-morning", 2) |> Enum.map(& &1.output) == ["run-8", "run-7"]

      assert Store.runs(@icm, "s-morning", 10) |> Enum.map(& &1.output) ==
               ["run-8", "run-7", "run-6", "run-5"]
    end

    test "is scoped to (icm_id, schedule_id) — never another schedule's or another ICM's runs" do
      {:ok, _} = Store.record_run(run_attrs(%{output: "mine"}))
      {:ok, _} = Store.record_run(run_attrs(%{schedule_id: "s-other", output: "sibling"}))
      {:ok, _} = Store.record_run(run_attrs(%{icm_id: @other_icm, output: "other-icm"}))

      assert Store.runs(@icm, "s-morning", 10) |> Enum.map(& &1.output) == ["mine"]
      assert Store.runs(@other_icm, "s-morning", 10) |> Enum.map(& &1.output) == ["other-icm"]
    end

    test "run records need no state row and survive the schedule's tombstone (no FK)" do
      # Recorded with no `schedule_state` row in existence at all.
      {:ok, _} = Store.record_run(run_attrs(%{outcome: "completed"}))
      assert Store.get_state(@icm, "s-morning") == nil
      assert [%{outcome: "completed"}] = Store.runs(@icm, "s-morning", 10)

      # ... and after the schedule is registered and then deleted.
      :ok = Store.put_state(@icm, "s-morning", %{fingerprint: "fp1"})
      :ok = Store.put_state(@icm, "s-morning", %{deleted_at: at("2026-07-30T10:00:00Z")})

      assert [%{outcome: "completed"}] = Store.runs(@icm, "s-morning", 10)
    end

    test "mount_key is display metadata, not part of the key — a rename keeps both runs" do
      {:ok, _} =
        Store.record_run(run_attrs(%{mount_key: "work", fired_at: at("2026-07-30T07:00:00Z")}))

      {:ok, _} =
        Store.record_run(
          run_attrs(%{mount_key: "work-renamed", fired_at: at("2026-07-30T08:00:00Z")})
        )

      assert Store.runs(@icm, "s-morning", 10) |> Enum.map(& &1.mount_key) ==
               ["work-renamed", "work"]
    end
  end

  describe "update_run/2" do
    test "sets outcome, duration_ms and output, leaving the launch columns alone" do
      {:ok, run_id} = Store.record_run(run_attrs())

      assert :ok =
               Store.update_run(run_id, %{
                 outcome: "completed",
                 duration_ms: 4_200,
                 output: "done"
               })

      assert [
               %{
                 id: ^run_id,
                 outcome: "completed",
                 duration_ms: 4_200,
                 output: "done",
                 fingerprint: "fp1",
                 slot: ~U[2026-07-30 07:30:00Z],
                 trigger: "scheduled",
                 coalesced_count: 1
               }
             ] = Store.runs(@icm, "s-morning", 10)
    end

    test "omitted keys are left untouched" do
      {:ok, run_id} = Store.record_run(run_attrs(%{output: "partial output"}))

      assert :ok = Store.update_run(run_id, %{outcome: "timed out"})

      assert [%{outcome: "timed out", output: "partial output", duration_ms: nil}] =
               Store.runs(@icm, "s-morning", 10)
    end

    test "an unknown run id is a silent no-op, not an error" do
      assert :ok = Store.update_run(Ash.UUID.generate(), %{outcome: "completed"})
    end

    # The lifecycle Task 4 gets: record BEFORE the spawn (so a crash in the
    # window still leaves evidence the fire happened), attach the session the
    # moment the spawn returns, settle the outcome at completion.
    test "session_id is a post-create write — record, attach the session, then settle" do
      {:ok, run_id} = Store.record_run(run_attrs(%{outcome: "running", session_id: nil}))

      assert [%{session_id: nil, outcome: "running"}] = Store.runs(@icm, "s-morning", 10)

      assert :ok = Store.update_run(run_id, %{session_id: "sess-42"})
      assert [%{session_id: "sess-42", outcome: "running"}] = Store.runs(@icm, "s-morning", 10)

      assert :ok = Store.update_run(run_id, %{outcome: "completed", duration_ms: 10})

      assert [%{session_id: "sess-42", outcome: "completed", duration_ms: 10}] =
               Store.runs(@icm, "s-morning", 10)
    end

    test "an unrecognised or immutable key raises rather than being silently dropped" do
      {:ok, run_id} = Store.record_run(run_attrs())

      assert_raise Ash.Error.Invalid, ~r/No such input `outcom`/, fn ->
        Store.update_run(run_id, %{outcom: "completed"})
      end

      # The launch columns are history: `:progress` does not accept them.
      assert_raise Ash.Error.Invalid, ~r/No such input `slot`/, fn ->
        Store.update_run(run_id, %{slot: at("2026-07-30T09:30:00Z")})
      end

      assert [%{outcome: "running", slot: ~U[2026-07-30 07:30:00Z]}] =
               Store.runs(@icm, "s-morning", 10)
    end
  end

  # -- notices -----------------------------------------------------------------

  describe "running_runs/1" do
    test "finds the newest RUNNING row even when a newer record hides it" do
      {:ok, running} = Store.record_run(run_attrs(%{outcome: "running", session_id: "sess-1"}))

      {:ok, _skip} =
        Store.record_run(
          run_attrs(%{
            outcome: "skipped: still running",
            fired_at: at("2026-07-30T08:30:00Z")
          })
        )

      # `runs/3` answers "the newest EVENT", which is the skip — the distinction
      # liveness and interrupted-convergence both depend on.
      assert [%{outcome: "skipped: still running"} | _] = Store.runs(@icm, "s-morning", 5)
      assert [%{id: ^running, session_id: "sess-1"}] = Store.running_runs()
    end

    test "narrows by icm and schedule, newest first, and ignores finished runs" do
      {:ok, older} = Store.record_run(run_attrs(%{outcome: "running"}))

      {:ok, newer} =
        Store.record_run(run_attrs(%{outcome: "running", fired_at: at("2026-07-30T09:00:00Z")}))

      {:ok, other_schedule} =
        Store.record_run(run_attrs(%{schedule_id: "s-nightly", outcome: "running"}))

      {:ok, other_icm} = Store.record_run(run_attrs(%{icm_id: @other_icm, outcome: "running"}))
      {:ok, _done} = Store.record_run(run_attrs(%{outcome: "completed"}))

      assert Store.running_runs(icm_id: @icm, schedule_id: "s-morning")
             |> Enum.map(& &1.id) == [newer, older]

      assert Store.running_runs(icm_id: @icm) |> Enum.map(& &1.id) |> Enum.sort() ==
               Enum.sort([newer, older, other_schedule])

      assert other_icm in (Store.running_runs() |> Enum.map(& &1.id))
    end

    test "answers with an empty list when nothing is in flight" do
      {:ok, _done} = Store.record_run(run_attrs(%{outcome: "completed"}))
      assert Store.running_runs() == []
    end
  end

  describe "notices_since/1" do
    test "is empty on an empty store" do
      assert Store.notices_since(at("2026-07-30T00:00:00Z")) == %{
               waiting: [],
               failed: [],
               registered: []
             }
    end

    test "picks up waiting + failed runs since the cutoff and nothing else" do
      cutoff = at("2026-07-30T08:00:00Z")

      for {outcome, fired_at} <- [
            {"waiting", "2026-07-30T08:00:00Z"},
            {"failed", "2026-07-30T09:00:00Z"},
            {"completed", "2026-07-30T09:00:00Z"},
            {"skipped: still running", "2026-07-30T09:00:00Z"},
            {"interrupted", "2026-07-30T09:00:00Z"},
            {"timed out", "2026-07-30T09:00:00Z"},
            {"running", "2026-07-30T09:00:00Z"},
            # Before the cutoff — already seen, must not resurface.
            {"failed", "2026-07-30T07:59:59Z"},
            {"waiting", "2026-07-30T07:00:00Z"}
          ] do
        {:ok, _} = Store.record_run(run_attrs(%{outcome: outcome, fired_at: at(fired_at)}))
      end

      assert %{waiting: waiting, failed: failed} = Store.notices_since(cutoff)

      # `fired_at >= cutoff` is inclusive: the run at exactly the cutoff counts.
      assert Enum.map(waiting, & &1.fired_at) == [~U[2026-07-30 08:00:00Z]]
      assert Enum.map(failed, & &1.fired_at) == [~U[2026-07-30 09:00:00Z]]
    end

    test "a fractional-second cutoff is truncated down, so it includes its own second" do
      # Stored `fired_at` is second-truncated, so an 08:00:00.9 event lands on
      # 08:00:00. A cutoff of 08:00:00.4 must still see it: comparing against
      # the untruncated cutoff would half-exclude events that were themselves
      # truncated down into that second.
      {:ok, _} =
        Store.record_run(run_attrs(%{outcome: "failed", fired_at: ~U[2026-07-30 08:00:00.900Z]}))

      assert %{failed: [%{fired_at: ~U[2026-07-30 08:00:00Z]}]} =
               Store.notices_since(~U[2026-07-30 08:00:00.400Z])

      # ... and the second AFTER is genuinely outside the window.
      assert %{failed: []} = Store.notices_since(~U[2026-07-30 08:00:01.400Z])
    end

    test "notice runs are newest-first and span every ICM and schedule" do
      {:ok, _} =
        Store.record_run(
          run_attrs(%{outcome: "failed", fired_at: at("2026-07-30T08:00:00Z"), output: "a"})
        )

      {:ok, _} =
        Store.record_run(
          run_attrs(%{
            icm_id: @other_icm,
            schedule_id: "s-other",
            outcome: "failed",
            fired_at: at("2026-07-30T09:00:00Z"),
            output: "b"
          })
        )

      assert %{failed: failed} = Store.notices_since(at("2026-07-30T00:00:00Z"))
      assert Enum.map(failed, & &1.output) == ["b", "a"]
      assert Enum.map(failed, & &1.icm_id) == [@other_icm, @icm]
    end

    test "registered is the states first seen since the cutoff, newest-first" do
      :ok = Store.put_state(@icm, "s-old", %{first_seen_at: at("2026-07-30T06:00:00Z")})
      :ok = Store.put_state(@icm, "s-new", %{first_seen_at: at("2026-07-30T08:30:00Z")})
      :ok = Store.put_state(@other_icm, "s-newer", %{first_seen_at: at("2026-07-30T09:00:00Z")})
      # No `first_seen_at` at all — never a registration notice.
      :ok = Store.put_state(@icm, "s-anchorless", %{fingerprint: "fp"})

      assert %{registered: registered} = Store.notices_since(at("2026-07-30T08:00:00Z"))

      assert Enum.map(registered, & &1.schedule_id) == ["s-newer", "s-new"]
    end
  end
end
