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
end
