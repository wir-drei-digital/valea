defmodule Valea.AuditTest do
  use ExUnit.Case, async: false

  setup do
    root = Path.join(System.tmp_dir!(), "vaud-#{System.os_time(:nanosecond)}")
    File.mkdir_p!(Path.join(root, "logs"))
    on_exit(fn -> File.rm_rf!(root) end)
    start_supervised!({Valea.Audit, %{root: root, generation: 7}})
    %{root: root}
  end

  test "appends jsonl with ts, type, generation; entries newest-first", %{root: root} do
    :ok = Valea.Audit.append("workflow_run_started", %{"run_id" => "r1"})
    :ok = Valea.Audit.append("queue_item_created", %{"run_id" => "r1"})

    # append/2 is a cast (fire-and-forget); round-trip a call through the same
    # Audit process before reading the file. Same-sender-to-same-receiver FIFO
    # guarantees both casts above were processed before this call is.
    {:ok, _} = Valea.Audit.entries(1)

    lines =
      root |> Path.join("logs/audit.jsonl") |> File.read!() |> String.split("\n", trim: true)

    assert length(lines) == 2
    first = Jason.decode!(hd(lines))
    assert first["type"] == "workflow_run_started"
    assert first["generation"] == 7
    assert first["ts"] =~ "T"

    {:ok, entries} = Valea.Audit.entries(10)

    assert [%{"type" => "queue_item_created"}, %{"type" => "workflow_run_started"}] =
             Enum.map(entries, &Map.take(&1, ["type"]))
  end

  test "entries/1 with no Audit process running -> {:ok, []}, no crash" do
    # No workspace open (or mid-switch): the named process is gone. entries/1
    # must degrade calmly instead of exiting :noproc and taking the caller down.
    :ok = stop_supervised(Valea.Audit)
    refute Process.whereis(Valea.Audit)

    assert {:ok, []} = Valea.Audit.entries(10)
  end

  test "append with a non-JSON-encodable field never crashes the caller, and the Audit process stays alive",
       %{root: root} do
    audit_pid = Process.whereis(Valea.Audit)
    assert is_pid(audit_pid)

    # A PID is not encodable by Jason. This must not crash the caller (this
    # test process) nor the Audit GenServer.
    :ok = Valea.Audit.append("bad_entry", %{"pid" => self()})

    # Round-trip a call through the same process to force ordering before we
    # inspect state.
    {:ok, _} = Valea.Audit.entries(1)

    assert Process.whereis(Valea.Audit) == audit_pid
    assert Process.alive?(audit_pid)

    # Subsequent appends/entries still work.
    :ok = Valea.Audit.append("good_entry", %{"run_id" => "r2"})
    {:ok, _} = Valea.Audit.entries(1)

    lines =
      root |> Path.join("logs/audit.jsonl") |> File.read!() |> String.split("\n", trim: true)

    # Only the encodable entry made it to the file; the bad one was logged and skipped.
    assert length(lines) == 1
    assert Jason.decode!(hd(lines))["type"] == "good_entry"
  end

  test "append_sync/2 has already flushed the entry to disk when it returns — no entries/1 round-trip needed",
       %{root: root} do
    :ok = Valea.Audit.append_sync("approval_intent", %{"run_id" => "r-sync"})

    # No call to entries/1 here on purpose: append_sync/2 is a GenServer.call,
    # so by the time it returns the write has already happened. Read the file
    # straight off disk.
    lines =
      root |> Path.join("logs/audit.jsonl") |> File.read!() |> String.split("\n", trim: true)

    assert length(lines) == 1
    entry = Jason.decode!(hd(lines))
    assert entry["type"] == "approval_intent"
    assert entry["run_id"] == "r-sync"
  end

  test "append_sync/2 with a non-encodable field never crashes the caller, and the Audit process stays alive",
       %{root: root} do
    audit_pid = Process.whereis(Valea.Audit)
    assert is_pid(audit_pid)

    # A PID is not encodable by Jason.
    :ok = Valea.Audit.append_sync("bad_entry", %{"pid" => self()})

    assert Process.whereis(Valea.Audit) == audit_pid
    assert Process.alive?(audit_pid)

    # The bad entry was logged and skipped, not written.
    lines =
      case File.read(Path.join(root, "logs/audit.jsonl")) do
        {:ok, data} -> String.split(data, "\n", trim: true)
        {:error, :enoent} -> []
      end

    refute Enum.any?(lines, &(Jason.decode!(&1)["type"] == "bad_entry"))

    # Subsequent sync appends still work.
    :ok = Valea.Audit.append_sync("good_entry", %{"run_id" => "r-after-bad"})

    lines =
      root |> Path.join("logs/audit.jsonl") |> File.read!() |> String.split("\n", trim: true)

    assert Enum.any?(lines, &(Jason.decode!(&1)["type"] == "good_entry"))
  end
end
