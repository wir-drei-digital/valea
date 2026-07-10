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
end
