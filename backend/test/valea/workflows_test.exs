defmodule Valea.WorkflowsTest do
  use ExUnit.Case, async: false

  alias Valea.AgentCase
  alias Valea.Workflows

  setup do
    ws = AgentCase.open_workspace!()
    %{workspace: ws.path}
  end

  test "list/0 returns the four template workflows, exactly one enabled" do
    assert {:ok, workflows} = Workflows.list()
    assert length(workflows) == 4
    assert Enum.count(workflows, & &1.enabled) == 1

    enabled = Enum.find(workflows, & &1.enabled)
    assert enabled.name == "New Inquiry Triage"
    assert enabled.path == "icm/Workflows/New Inquiry Triage.md"
  end

  test "get/1 parses frontmatter (trigger.source, risk_level, approval.actions) and steps_preview" do
    assert {:ok, wf} = Workflows.get("icm/Workflows/New Inquiry Triage.md")

    assert wf.path == "icm/Workflows/New Inquiry Triage.md"
    assert wf.name == "New Inquiry Triage"
    assert wf.enabled == true
    assert wf.trigger["source"] == "email.selected"
    assert wf.risk_level == "medium"
    assert wf.approval["actions"] == ["create_email_draft"]
    assert is_list(wf.sources) and length(wf.sources) > 0
    assert wf.description =~ "Classifies a new email inquiry"

    assert wf.steps_preview == [
             "Summarize the incoming inquiry in two sentences.",
             "Classify it: good-fit, unclear, not fit, or spam.",
             "Draft a warm reply using the tone guide and the relevant offer. Respect the no-medical-advice policy."
           ]
  end

  test "get/1 on a disabled workflow still returns it (enabled: false)" do
    assert {:ok, wf} = Workflows.get("icm/Workflows/Weekly Admin Review.md")
    assert wf.enabled == false
    assert wf.risk_level == "low"
  end

  test "get/1 on a missing path returns not_found" do
    assert {:error, :not_found} = Workflows.get("icm/Workflows/Nonexistent.md")
  end

  test "get/1 outside icm/Workflows/ returns not_found" do
    assert {:error, :not_found} = Workflows.get("icm/Offers/Founder Coaching Package.md")
  end

  test "a Workflows/ page without frontmatter is not a contract: list/0 skips it, get/1 -> not_found",
       %{workspace: workspace} do
    path = Path.join(workspace, "icm/Workflows/No Frontmatter.md")
    File.write!(path, "# No Frontmatter\n\nJust a plain page, no YAML header.\n")

    assert {:error, :not_found} = Workflows.get("icm/Workflows/No Frontmatter.md")

    assert {:ok, workflows} = Workflows.list()
    assert length(workflows) == 4
    refute Enum.any?(workflows, &(&1.path == "icm/Workflows/No Frontmatter.md"))
  end

  test "no workspace open returns an empty list" do
    Valea.Workspace.Manager.close()
    assert {:ok, []} = Workflows.list()
  end
end
