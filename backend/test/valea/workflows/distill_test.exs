defmodule Valea.Workflows.DistillTest do
  use ExUnit.Case, async: false

  alias Valea.AgentCase
  alias Valea.Workflows.Distill

  # Same tmp-workspace setup as `Valea.Agents.RiskTierTest` (B1) /
  # `Valea.Workflows.RunnerTest` (B3+) — `AgentCase.open_workspace!/1` is
  # that exact pattern (isolated `VALEA_APP_DIR`, real `Manager.create/2`,
  # `on_exit` cleanup), just factored into the shared helper those other
  # suites already use.
  setup do
    ws = AgentCase.open_workspace!("Primary")
    %{workspace: ws.path}
  end

  defp decided!(ws, dir, run_id, decided_at, extra \\ %{}) do
    item =
      Map.merge(
        %{
          "schema" => "queue_item/v2",
          "run_id" => run_id,
          "workflow" => "mounts/primary/Workflows/New Inquiry Triage.md",
          "risk_level" => "medium",
          "created_at" => "2026-07-01T00:00:00Z",
          "decided_at" => decided_at,
          "payload" => %{
            "title" => "T-" <> run_id,
            "summary" => "s",
            "kind" => "email_draft",
            "sources" => [],
            "proposed_action" => %{
              "type" => "create_email_draft",
              "to" => "a@b.c",
              "subject" => "s",
              "body_markdown" => "b"
            }
          }
        },
        extra
      )

    d = Path.join(ws, "queue/" <> dir)
    File.mkdir_p!(d)
    File.write!(Path.join(d, run_id <> ".json"), Jason.encode!(item))
  end

  test "window, reasons, ordering, exclusions", %{workspace: ws} do
    now = DateTime.utc_now()
    recent = now |> DateTime.add(-2, :day) |> DateTime.to_iso8601()
    old = now |> DateTime.add(-40, :day) |> DateTime.to_iso8601()

    decided!(ws, "approved", "d1", recent)
    decided!(ws, "rejected", "d2", recent, %{"decision" => %{"reason" => "too pushy"}})
    decided!(ws, "approved", "d3", old)
    decided!(ws, "approved", "d4-nostamp", nil)

    {count, md} = Distill.digest(ws)
    assert count == 2
    assert md =~ "# Recent decisions (last 30 days)"
    assert md =~ "T-d1"
    assert md =~ "reason: too pushy"
    refute md =~ "T-d3"
    refute md =~ "d4-nostamp"
  end

  test "empty window", %{workspace: ws} do
    assert {0, md} = Distill.digest(ws)
    assert md =~ "# Recent decisions"
  end
end
