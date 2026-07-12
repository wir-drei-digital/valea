defmodule Valea.WorkflowsTest do
  use ExUnit.Case, async: false

  alias Valea.AgentCase
  alias Valea.Mounts
  alias Valea.Mounts.Manifest
  alias Valea.Workflows

  setup do
    ws = AgentCase.open_workspace!()
    # A fresh scaffold (T8) mints its own real, enabled mount from the
    # template's seed content — disable it so this suite's `Workflows.list/0`
    # assertions see only the mounts each test builds for itself.
    Enum.each(Mounts.list(ws.path), &Mounts.set_enabled(&1.name, false))
    %{workspace: ws.path}
  end

  defp write_mount!(ws_path, name, title) do
    dir = Path.join([ws_path, "mounts", name])
    File.mkdir_p!(dir)
    Manifest.write!(dir, %{id: "id-" <> name, name: title, description: ""})
    dir
  end

  defp write_workflow!(mount_dir, filename, frontmatter, body) do
    File.mkdir_p!(Path.join(mount_dir, "Workflows"))
    content = "---\n" <> frontmatter <> "---\n" <> body
    File.write!(Path.join([mount_dir, "Workflows", filename]), content)
  end

  # Declares an external (kind: "path") mount in the workspace's existing
  # config/workspace.yaml, preserving version/id and every existing mount
  # entry (e.g. this suite's setup-time set_enabled overlays).
  defp declare_external!(ws_path, name, ref) do
    config_path = Path.join(ws_path, "config/workspace.yaml")
    {:ok, doc} = YamlElixir.read_from_file(config_path)

    mounts = Map.put(Map.get(doc, "mounts") || %{}, name, %{"kind" => "path", "ref" => ref})

    header = for key <- ["version", "id"], Map.has_key?(doc, key), do: "#{key}: #{doc[key]}"

    entries =
      Enum.flat_map(Enum.sort_by(mounts, &elem(&1, 0)), fn {n, entry} ->
        [
          "  #{n}:"
          | Enum.map(Enum.sort_by(entry, &elem(&1, 0)), fn {k, v} ->
              "    #{k}: #{render_scalar(v)}"
            end)
        ]
      end)

    File.write!(config_path, Enum.join(header ++ ["mounts:"] ++ entries, "\n") <> "\n")
  end

  defp render_scalar(v) when is_binary(v), do: inspect(v)
  defp render_scalar(v), do: to_string(v)

  defp external_icm!(name) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-ext-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    Manifest.write!(dir, %{id: "ext-id", name: name, description: ""})
    dir
  end

  @triage_frontmatter """
  enabled: true
  trigger: { type: manual, source: email.selected }
  sources:
    - { id: current_email, type: email, required: true }
    - { id: founder_coaching_offer, type: icm, path: "Offers/Founder Coaching Package.md" }
    - { id: tone_guide, type: icm, path: "Tone & Voice/Email Tone Guide.md" }
  risk_level: medium
  approval:
    required: true
    reason: Email replies must be reviewed before sending.
    actions: [create_email_draft]
  """

  @triage_body """
  # New Inquiry Triage

  Classifies a new email inquiry and drafts a reply for review.

  ## Process

  1. Summarize the incoming inquiry in two sentences.
  2. Classify it: good-fit, unclear, not fit, or spam.
  3. Draft a warm reply using the tone guide and the relevant offer. Respect the no-medical-advice policy.
  """

  test "list/0 unions two enabled mounts, each workflow with distinct path + mount provenance",
       %{workspace: ws} do
    a = write_mount!(ws, "a", "Mount A")
    write_workflow!(a, "Triage.md", @triage_frontmatter, @triage_body)

    b = write_mount!(ws, "b", "Mount B")
    write_workflow!(b, "Review.md", "enabled: false\nrisk_level: low\n", "# Review\n\nBody.\n")

    assert {:ok, workflows} = Workflows.list()
    assert length(workflows) == 2

    wf_a = Enum.find(workflows, &(&1.path == "mounts/a/Workflows/Triage.md"))
    assert wf_a.mount == "Mount A"
    assert wf_a.name == "New Inquiry Triage"
    assert wf_a.enabled == true

    wf_b = Enum.find(workflows, &(&1.path == "mounts/b/Workflows/Review.md"))
    assert wf_b.mount == "Mount B"
    assert wf_b.name == "Review"
    assert wf_b.enabled == false

    # sorted by path
    assert Enum.map(workflows, & &1.path) == Enum.sort(Enum.map(workflows, & &1.path))
  end

  test "same workflow filename in two mounts coexists without shadowing", %{workspace: ws} do
    a = write_mount!(ws, "a", "Mount A")
    write_workflow!(a, "Shared.md", "enabled: true\nrisk_level: low\n", "# A Shared\n\nBody.\n")

    b = write_mount!(ws, "b", "Mount B")
    write_workflow!(b, "Shared.md", "enabled: true\nrisk_level: low\n", "# B Shared\n\nBody.\n")

    assert {:ok, workflows} = Workflows.list()
    paths = Enum.map(workflows, & &1.path)
    assert "mounts/a/Workflows/Shared.md" in paths
    assert "mounts/b/Workflows/Shared.md" in paths
    assert length(workflows) == 2

    a_wf = Enum.find(workflows, &(&1.path == "mounts/a/Workflows/Shared.md"))
    b_wf = Enum.find(workflows, &(&1.path == "mounts/b/Workflows/Shared.md"))
    assert a_wf.name == "A Shared"
    assert b_wf.name == "B Shared"
  end

  test "external mounts' workflows are not yet surfaced in list/1 (A2-T5b) — embedded only, no crash",
       %{workspace: ws} do
    a = write_mount!(ws, "a", "Mount A")
    write_workflow!(a, "Triage.md", "enabled: true\nrisk_level: low\n", "# Triage\n\nBody.\n")

    ext = external_icm!("Ext")
    write_workflow!(ext, "External.md", "enabled: true\nrisk_level: low\n", "# Ext WF\n\nBody.\n")
    declare_external!(ws, "ext", ext)

    # Sanity: the external mount IS effective — its workflows are excluded
    # deliberately (rel_root: nil has no workspace-relative form for a
    # workflow's `mounts/<name>/…` path), not because it failed to resolve.
    assert "ext" in Enum.map(Mounts.enabled(ws), & &1.name)

    workflows = Workflows.list(ws)
    assert Enum.map(workflows, & &1.path) == ["mounts/a/Workflows/Triage.md"]
  end

  test "disabling a mount drops its workflows from list/0, but get/1 by explicit path still resolves it (T3 posture)",
       %{workspace: ws} do
    a = write_mount!(ws, "a", "Mount A")
    write_workflow!(a, "Triage.md", @triage_frontmatter, @triage_body)

    assert {:ok, [_one]} = Workflows.list()

    assert :ok = Mounts.set_enabled("a", false)

    assert {:ok, []} = Workflows.list()

    assert {:ok, wf} = Workflows.get("mounts/a/Workflows/Triage.md")
    assert wf.name == "New Inquiry Triage"
    assert wf.mount == "Mount A"
    assert wf.path == "mounts/a/Workflows/Triage.md"
  end

  test "get/1 parses frontmatter (trigger.source, risk_level, approval.actions) and steps_preview",
       %{workspace: ws} do
    a = write_mount!(ws, "a", "Mount A")
    write_workflow!(a, "Triage.md", @triage_frontmatter, @triage_body)

    assert {:ok, wf} = Workflows.get("mounts/a/Workflows/Triage.md")

    assert wf.path == "mounts/a/Workflows/Triage.md"
    assert wf.mount == "Mount A"
    assert wf.name == "New Inquiry Triage"
    assert wf.enabled == true
    assert wf.trigger["source"] == "email.selected"
    assert wf.risk_level == "medium"
    assert wf.approval["actions"] == ["create_email_draft"]
    assert is_list(wf.sources) and length(wf.sources) == 3
    assert wf.description =~ "Classifies a new email inquiry"

    assert wf.steps_preview == [
             "Summarize the incoming inquiry in two sentences.",
             "Classify it: good-fit, unclear, not fit, or spam.",
             "Draft a warm reply using the tone guide and the relevant offer. Respect the no-medical-advice policy."
           ]
  end

  test "get/1 on a disabled workflow still returns it (enabled: false)", %{workspace: ws} do
    a = write_mount!(ws, "a", "Mount A")
    write_workflow!(a, "Weekly.md", "enabled: false\nrisk_level: low\n", "# Weekly\n\nBody.\n")

    assert {:ok, wf} = Workflows.get("mounts/a/Workflows/Weekly.md")
    assert wf.enabled == false
    assert wf.risk_level == "low"
  end

  test "get/1 on a missing path returns not_found", %{workspace: ws} do
    write_mount!(ws, "a", "Mount A")
    assert {:error, :not_found} = Workflows.get("mounts/a/Workflows/Nonexistent.md")
  end

  test "get/1 outside mounts/<name>/Workflows/ returns not_found", %{workspace: ws} do
    a = write_mount!(ws, "a", "Mount A")
    File.mkdir_p!(Path.join(a, "Offers"))
    File.write!(Path.join([a, "Offers", "X.md"]), "---\nenabled: true\n---\n# X\n")

    assert {:error, :not_found} = Workflows.get("mounts/a/Offers/X.md")
  end

  test "get/1 with a path that doesn't name a mount at all returns not_found", %{workspace: ws} do
    write_mount!(ws, "a", "Mount A")
    assert {:error, :not_found} = Workflows.get("sources/mail/messages/x.md")
  end

  test "get/1 with a path containing .. that escapes the workspace returns not_found", %{
    workspace: ws
  } do
    write_mount!(ws, "a", "Mount A")

    assert {:error, :not_found} =
             Workflows.get("mounts/a/Workflows/../../../../../../../../etc/passwd")
  end

  test "get/1 with a path that lexically starts with mounts/<name>/Workflows/ but traverses out of it (while staying inside the mount) returns not_found",
       %{workspace: ws} do
    a = write_mount!(ws, "a", "Mount A")
    File.mkdir_p!(Path.join(a, "Offers"))
    File.write!(Path.join([a, "Offers", "escaped.md"]), "# Escaped\n")

    assert {:error, :not_found} = Workflows.get("mounts/a/Workflows/../Offers/escaped.md")
  end

  test "get/1 with a path that traverses from one mount into another returns not_found", %{
    workspace: ws
  } do
    _a = write_mount!(ws, "a", "Mount A")
    b = write_mount!(ws, "b", "Mount B")
    write_workflow!(b, "Secret.md", "enabled: true\n", "# Secret\n\nBody.\n")

    assert {:error, :not_found} =
             Workflows.get("mounts/a/Workflows/../../b/Workflows/Secret.md")
  end

  test "a Workflows/ page without frontmatter is not a contract: list/0 skips it, get/1 -> not_found",
       %{workspace: ws} do
    a = write_mount!(ws, "a", "Mount A")
    write_workflow!(a, "Triage.md", @triage_frontmatter, @triage_body)

    File.write!(
      Path.join([a, "Workflows", "No Frontmatter.md"]),
      "# No Frontmatter\n\nJust a plain page, no YAML header.\n"
    )

    assert {:error, :not_found} = Workflows.get("mounts/a/Workflows/No Frontmatter.md")

    assert {:ok, workflows} = Workflows.list()
    assert length(workflows) == 1
    refute Enum.any?(workflows, &(&1.path == "mounts/a/Workflows/No Frontmatter.md"))
  end

  test "no workspace open returns an empty list" do
    Valea.Workspace.Manager.close()
    assert {:ok, []} = Workflows.list()
  end

  test "no workspace open: get/1 returns not_found" do
    Valea.Workspace.Manager.close()
    assert {:error, :not_found} = Workflows.get("mounts/a/Workflows/Triage.md")
  end

  test "list/0 gracefully skips mounts with degraded (invalid) manifests",
       %{workspace: ws} do
    # Create one valid mount with a workflow
    valid = write_mount!(ws, "valid", "Valid Mount")
    write_workflow!(valid, "Good.md", @triage_frontmatter, @triage_body)

    # Create a degraded mount: Workflows dir exists with a workflow file,
    # but icm.yaml is invalid (unterminated YAML key)
    degraded_dir = Path.join([ws, "mounts", "degraded"])
    File.mkdir_p!(degraded_dir)
    File.write!(Path.join(degraded_dir, "icm.yaml"), "name: [unterminated")

    File.mkdir_p!(Path.join(degraded_dir, "Workflows"))

    File.write!(
      Path.join([degraded_dir, "Workflows", "BadMount.md"]),
      "---\nenabled: true\nrisk_level: low\n---\n# BadMount\n\nBody.\n"
    )

    # list/0 should return only the valid mount's workflow, not raise
    assert {:ok, workflows} = Workflows.list()
    assert length(workflows) == 1
    assert hd(workflows).path == "mounts/valid/Workflows/Good.md"
    assert hd(workflows).mount == "Valid Mount"
  end

  # -- list/1 (pure form) and triage_path/0,1 (Task A-T13) --------------------

  describe "list/1 (pure form)" do
    test "matches list/0's result for the currently open workspace", %{workspace: ws} do
      a = write_mount!(ws, "a", "Mount A")
      write_workflow!(a, "Triage.md", @triage_frontmatter, @triage_body)

      assert {:ok, via_list_0} = Workflows.list()
      assert Workflows.list(ws) == via_list_0
    end

    test "a workspace with no mounts returns an empty list, without needing an open workspace" do
      other =
        System.tmp_dir!() |> Path.join("valea-wf-list1-#{System.unique_integer([:positive])}")

      File.mkdir_p!(other)
      on_exit(fn -> File.rm_rf!(other) end)

      assert Workflows.list(other) == []
    end
  end

  describe "triage_path/0,1 (seeded-workflow discovery, Task A-T13)" do
    test "finds the triage workflow's path in the first (alphabetically) enabled mount that has one",
         %{workspace: ws} do
      a = write_mount!(ws, "a", "Mount A")
      write_workflow!(a, "New Inquiry Triage.md", @triage_frontmatter, @triage_body)

      b = write_mount!(ws, "b", "Mount B")
      write_workflow!(b, "New Inquiry Triage.md", @triage_frontmatter, @triage_body)

      assert Workflows.triage_path() == "mounts/a/Workflows/New Inquiry Triage.md"
      assert Workflows.triage_path(ws) == "mounts/a/Workflows/New Inquiry Triage.md"
    end

    test "skips a mount lacking the triage workflow and finds it in a later one",
         %{workspace: ws} do
      write_mount!(ws, "a", "Mount A")
      # "a" has no Workflows/ at all.

      b = write_mount!(ws, "b", "Mount B")
      write_workflow!(b, "New Inquiry Triage.md", @triage_frontmatter, @triage_body)

      assert Workflows.triage_path() == "mounts/b/Workflows/New Inquiry Triage.md"
      assert Workflows.triage_path(ws) == "mounts/b/Workflows/New Inquiry Triage.md"
    end

    test "returns nil when no enabled mount has a triage workflow", %{workspace: ws} do
      a = write_mount!(ws, "a", "Mount A")

      write_workflow!(
        a,
        "Unrelated.md",
        "enabled: true\nrisk_level: low\n",
        "# Unrelated\n\nBody.\n"
      )

      assert Workflows.triage_path() == nil
      assert Workflows.triage_path(ws) == nil
    end

    test "returns nil when no workspace is open (list/0's own no-workspace case)" do
      Valea.Workspace.Manager.close()
      assert Workflows.triage_path() == nil
    end

    test "a disabled mount's triage workflow is not found (mirrors list/0's enabled-only gating)",
         %{workspace: ws} do
      a = write_mount!(ws, "a", "Mount A")
      write_workflow!(a, "New Inquiry Triage.md", @triage_frontmatter, @triage_body)

      assert :ok = Mounts.set_enabled("a", false)

      assert Workflows.triage_path() == nil
      assert Workflows.triage_path(ws) == nil
    end
  end
end
