defmodule Valea.WorkflowsTest do
  use ExUnit.Case, async: false

  alias Valea.AgentCase
  alias Valea.Mounts
  alias Valea.Workflows

  setup do
    # A fresh v5 workspace carries no seeded mount at all any more (config
    # truth over `icms:` only — see `Valea.Mounts`'s moduledoc) — every mount
    # this suite's tests need is a REAL EXTERNAL ICM this suite mounts for
    # itself via `AgentCase.mount_test_icm!/2`, so there is nothing to
    # disable up front any more.
    ws = AgentCase.open_workspace!()
    %{workspace: ws.path}
  end

  defp write_workflow!(mount_dir, filename, frontmatter, body) do
    File.mkdir_p!(Path.join(mount_dir, "Workflows"))
    content = "---\n" <> frontmatter <> "---\n" <> body
    File.write!(Path.join([mount_dir, "Workflows", filename]), content)
  end

  # Declares an external `icms:` entry directly in the workspace's existing
  # config/workspace.yaml, preserving version/id and every existing entry —
  # mirrors `Valea.Agents.SessionReadRootsTest`/`ValeaWeb.MountsRpcTest`'s
  # helper of the same name/shape. Used only for the degraded-manifest test
  # below, where `Mounts.mount/2` itself would reject the folder outright.
  defp declare_external!(ws_path, name, ref) do
    config_path = Path.join(ws_path, "config/workspace.yaml")
    {:ok, doc} = YamlElixir.read_from_file(config_path)

    icms =
      (Map.get(doc, "icms") || %{})
      |> Map.put(name, %{"path" => ref})

    header = for key <- ["version", "id"], Map.has_key?(doc, key), do: "#{key}: #{doc[key]}"

    entries =
      Enum.flat_map(Enum.sort_by(icms, &elem(&1, 0)), fn {n, entry} ->
        [
          "  #{n}:"
          | Enum.map(Enum.sort_by(entry, &elem(&1, 0)), fn {k, v} ->
              "    #{k}: #{render_scalar(v)}"
            end)
        ]
      end)

    File.write!(config_path, Enum.join(header ++ ["icms:"] ++ entries, "\n") <> "\n")
  end

  defp render_scalar(v) when is_binary(v), do: inspect(v)
  defp render_scalar(v), do: to_string(v)

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

  test "list/0 unions two enabled mounts, each workflow keyed by {icm_id, relative_path} with mount_key/resolved_path provenance",
       %{workspace: ws} do
    a = AgentCase.mount_test_icm!(ws, name: "A")
    write_workflow!(a.root, "Triage.md", @triage_frontmatter, @triage_body)

    b = AgentCase.mount_test_icm!(ws, name: "B")

    write_workflow!(
      b.root,
      "Review.md",
      "enabled: false\nrisk_level: low\n",
      "# Review\n\nBody.\n"
    )

    assert {:ok, workflows} = Workflows.list()
    assert length(workflows) == 2

    wf_a = Enum.find(workflows, &(&1.mount_key == a.mount_key))
    assert wf_a.icm_id == a.id
    assert wf_a.relative_path == "Workflows/Triage.md"
    assert wf_a.resolved_path == Path.join(a.root, "Workflows/Triage.md")
    assert wf_a.name == "New Inquiry Triage"
    assert wf_a.enabled == true

    wf_b = Enum.find(workflows, &(&1.mount_key == b.mount_key))
    assert wf_b.icm_id == b.id
    assert wf_b.relative_path == "Workflows/Review.md"
    assert wf_b.resolved_path == Path.join(b.root, "Workflows/Review.md")
    assert wf_b.name == "Review"
    assert wf_b.enabled == false

    # sorted by resolved_path
    assert Enum.map(workflows, & &1.resolved_path) ==
             Enum.sort(Enum.map(workflows, & &1.resolved_path))
  end

  test "same workflow filename in two mounts coexists without shadowing (same relative_path, distinct icm_id/mount_key/resolved_path)",
       %{workspace: ws} do
    a = AgentCase.mount_test_icm!(ws, name: "A")

    write_workflow!(
      a.root,
      "Shared.md",
      "enabled: true\nrisk_level: low\n",
      "# A Shared\n\nBody.\n"
    )

    b = AgentCase.mount_test_icm!(ws, name: "B")

    write_workflow!(
      b.root,
      "Shared.md",
      "enabled: true\nrisk_level: low\n",
      "# B Shared\n\nBody.\n"
    )

    assert {:ok, workflows} = Workflows.list()
    assert length(workflows) == 2
    assert Enum.all?(workflows, &(&1.relative_path == "Workflows/Shared.md"))

    a_wf = Enum.find(workflows, &(&1.mount_key == a.mount_key))
    b_wf = Enum.find(workflows, &(&1.mount_key == b.mount_key))
    assert a_wf.icm_id == a.id
    assert b_wf.icm_id == b.id
    assert a_wf.resolved_path == Path.join(a.root, "Workflows/Shared.md")
    assert b_wf.resolved_path == Path.join(b.root, "Workflows/Shared.md")
    assert a_wf.name == "A Shared"
    assert b_wf.name == "B Shared"
  end

  test "list/1 surfaces every enabled mount's workflows with absolute resolved_path",
       %{workspace: ws} do
    a = AgentCase.mount_test_icm!(ws, name: "A")

    write_workflow!(
      a.root,
      "Triage.md",
      "enabled: true\nrisk_level: low\n",
      "# Triage\n\nBody.\n"
    )

    ext = AgentCase.mount_test_icm!(ws, name: "Ext")

    write_workflow!(
      ext.root,
      "External.md",
      "enabled: true\nrisk_level: low\n",
      "# Ext WF\n\nBody.\n"
    )

    workflows = Workflows.list(ws)

    assert Enum.map(workflows, & &1.resolved_path) |> Enum.sort() ==
             Enum.sort([
               Path.join(a.root, "Workflows/Triage.md"),
               Path.join(ext.root, "Workflows/External.md")
             ])

    ext_wf = Enum.find(workflows, &(&1.mount_key == ext.mount_key))
    assert ext_wf.icm_id == ext.id
    assert ext_wf.resolved_path == Path.join(ext.root, "Workflows/External.md")
    assert ext_wf.relative_path == "Workflows/External.md"
    assert ext_wf.name == "Ext WF"
    assert ext_wf.enabled == true
  end

  test "a DISABLED mount drops out of list/1, but get/2 by {mount_key, relative_path} still resolves it (keyed lookup, not path-attribution — see Workflows moduledoc DECISION)",
       %{workspace: ws} do
    ext = AgentCase.mount_test_icm!(ws, name: "Ext")

    write_workflow!(
      ext.root,
      "External.md",
      "enabled: true\nrisk_level: low\n",
      "# Ext WF\n\nBody.\n"
    )

    assert {:ok, [_one]} = Workflows.list()
    assert {:ok, _wf} = Workflows.get(ext.mount_key, "Workflows/External.md")

    :ok = Mounts.set_enabled(ws, ext.mount_key, false)

    assert {:ok, []} = Workflows.list()
    assert {:ok, wf} = Workflows.get(ext.mount_key, "Workflows/External.md")
    assert wf.mount_key == ext.mount_key
  end

  test "get/2 parses frontmatter (trigger.source, risk_level, approval.actions) and steps_preview",
       %{workspace: ws} do
    a = AgentCase.mount_test_icm!(ws, name: "A")
    write_workflow!(a.root, "Triage.md", @triage_frontmatter, @triage_body)

    assert {:ok, wf} = Workflows.get(a.mount_key, "Workflows/Triage.md")

    assert wf.icm_id == a.id
    assert wf.mount_key == a.mount_key
    assert wf.relative_path == "Workflows/Triage.md"
    assert wf.resolved_path == Path.join(a.root, "Workflows/Triage.md")
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

  test "get/2 on a disabled workflow (frontmatter enabled: false) still returns it", %{
    workspace: ws
  } do
    a = AgentCase.mount_test_icm!(ws, name: "A")

    write_workflow!(
      a.root,
      "Weekly.md",
      "enabled: false\nrisk_level: low\n",
      "# Weekly\n\nBody.\n"
    )

    assert {:ok, wf} = Workflows.get(a.mount_key, "Workflows/Weekly.md")
    assert wf.enabled == false
    assert wf.risk_level == "low"
  end

  test "get/2 on a missing relative_path returns not_found", %{workspace: ws} do
    a = AgentCase.mount_test_icm!(ws, name: "A")
    assert {:error, :not_found} = Workflows.get(a.mount_key, "Workflows/Nonexistent.md")
  end

  test "get/2 with a mount_key that names no mount returns not_found", %{workspace: ws} do
    AgentCase.mount_test_icm!(ws, name: "A")
    assert {:error, :not_found} = Workflows.get("no-such-mount", "Workflows/Triage.md")
  end

  test "get/2 outside the mount's own Workflows/ returns not_in_icm", %{workspace: ws} do
    a = AgentCase.mount_test_icm!(ws, name: "A")
    File.mkdir_p!(Path.join(a.root, "Offers"))
    File.write!(Path.join(a.root, "Offers/X.md"), "---\nenabled: true\n---\n# X\n")

    assert {:error, :not_in_icm} = Workflows.get(a.mount_key, "Offers/X.md")
  end

  test "get/2 with a relative_path that traverses out of Workflows/ but stays inside the mount returns not_in_icm (acceptance case)",
       %{workspace: ws} do
    a = AgentCase.mount_test_icm!(ws, name: "A")
    File.mkdir_p!(Path.join(a.root, "Offers"))
    File.write!(Path.join(a.root, "Offers/escaped.md"), "# Escaped\n")

    assert {:error, :not_in_icm} = Workflows.get(a.mount_key, "Workflows/../Offers/escaped.md")

    # The exact acceptance-test path from the task brief: escaping into the
    # mount's own icm.yaml.
    assert {:error, :not_in_icm} = Workflows.get(a.mount_key, "Workflows/../icm.yaml")
  end

  test "get/2 with a relative_path that escapes the mount's root entirely returns not_found", %{
    workspace: ws
  } do
    a = AgentCase.mount_test_icm!(ws, name: "A")

    escape_path = Path.join(["Workflows", String.duplicate("../", 15) <> "etc/passwd"])

    assert {:error, :not_found} = Workflows.get(a.mount_key, escape_path)
  end

  test "get/2 with a relative_path that traverses from one mount into a sibling mount returns not_found",
       %{workspace: ws} do
    a = AgentCase.mount_test_icm!(ws, name: "A")
    b = AgentCase.mount_test_icm!(ws, name: "B")
    write_workflow!(b.root, "Secret.md", "enabled: true\n", "# Secret\n\nBody.\n")

    # Lexically starts inside `a`'s own Workflows/, but two ".." hops climb
    # out of `a` entirely and back down into sibling mount `b`'s own
    # Workflows/ — `a` and `b` are both direct children of the same tmp
    # parent (`AgentCase.mount_test_icm!/2` always mints them there), so
    # this reaches `b`'s real file while staying a real, resolvable path —
    # but it escapes `a`'s OWN root, which `get/2` resolves `relative_path`
    # against, so it is rejected as `:not_found`, not attributed to `b`.
    escape_path = "Workflows/../../" <> Path.basename(b.root) <> "/Workflows/Secret.md"

    assert {:error, :not_found} = Workflows.get(a.mount_key, escape_path)
  end

  test "a Workflows/ page without frontmatter is not a contract: list/0 skips it, get/2 -> not_found",
       %{workspace: ws} do
    a = AgentCase.mount_test_icm!(ws, name: "A")
    write_workflow!(a.root, "Triage.md", @triage_frontmatter, @triage_body)

    File.write!(
      Path.join(a.root, "Workflows/No Frontmatter.md"),
      "# No Frontmatter\n\nJust a plain page, no YAML header.\n"
    )

    assert {:error, :not_found} = Workflows.get(a.mount_key, "Workflows/No Frontmatter.md")

    assert {:ok, workflows} = Workflows.list()
    assert length(workflows) == 1
    refute Enum.any?(workflows, &(&1.relative_path == "Workflows/No Frontmatter.md"))
  end

  test "no workspace open returns an empty list" do
    Valea.Workspace.Manager.close()
    assert {:ok, []} = Workflows.list()
  end

  test "no workspace open: get/2 returns not_found" do
    Valea.Workspace.Manager.close()
    assert {:error, :not_found} = Workflows.get("a", "Workflows/Triage.md")
  end

  test "list/0 gracefully skips mounts with degraded (invalid) manifests, and get/2 on the degraded mount_key returns not_found",
       %{workspace: ws} do
    # A valid, healthy external mount with a workflow.
    valid = AgentCase.mount_test_icm!(ws, name: "Valid Mount")
    write_workflow!(valid.root, "Good.md", @triage_frontmatter, @triage_body)

    # A degraded mount: a real external directory with a Workflows/ file,
    # but an icm.yaml that fails to parse (unterminated YAML key).
    # `Mounts.mount/2` itself would reject a folder like this outright, so
    # it's declared directly into `icms:` config instead (mirrors
    # `ValeaWeb.MountsRpcTest`'s degraded-manifest fixture).
    degraded_dir =
      Path.join(
        System.tmp_dir!(),
        "valea-wf-degraded-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(degraded_dir)
    on_exit(fn -> File.rm_rf!(degraded_dir) end)
    File.write!(Path.join(degraded_dir, "icm.yaml"), "name: [unterminated")

    File.mkdir_p!(Path.join(degraded_dir, "Workflows"))

    File.write!(
      Path.join([degraded_dir, "Workflows", "BadMount.md"]),
      "---\nenabled: true\nrisk_level: low\n---\n# BadMount\n\nBody.\n"
    )

    declare_external!(ws, "degraded", degraded_dir)

    # list/0 should return only the valid mount's workflow, not raise
    assert {:ok, workflows} = Workflows.list()
    assert length(workflows) == 1
    assert hd(workflows).resolved_path == Path.join(valid.root, "Workflows/Good.md")
    assert hd(workflows).mount_key == valid.mount_key

    # get/2 keyed on the degraded mount's key has no trustworthy manifest to
    # resolve `icm_id` from, so it fails closed rather than returning a
    # contract with no identity.
    assert {:error, :not_found} = Workflows.get("degraded", "Workflows/BadMount.md")
  end

  # -- list/1 (pure form) and triage_path/0,1 (Task A-T13) --------------------

  describe "list/1 (pure form)" do
    test "matches list/0's result for the currently open workspace", %{workspace: ws} do
      a = AgentCase.mount_test_icm!(ws, name: "A")
      write_workflow!(a.root, "Triage.md", @triage_frontmatter, @triage_body)

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
    test "finds the triage workflow's resolved_path in the first (alphabetically) enabled mount that has one",
         %{workspace: ws} do
      a = AgentCase.mount_test_icm!(ws, name: "A")
      write_workflow!(a.root, "New Inquiry Triage.md", @triage_frontmatter, @triage_body)

      b = AgentCase.mount_test_icm!(ws, name: "B")
      write_workflow!(b.root, "New Inquiry Triage.md", @triage_frontmatter, @triage_body)

      expected = Path.join(a.root, "Workflows/New Inquiry Triage.md")
      assert Workflows.triage_path() == expected
      assert Workflows.triage_path(ws) == expected
    end

    test "skips a mount lacking the triage workflow and finds it in a later one",
         %{workspace: ws} do
      AgentCase.mount_test_icm!(ws, name: "A")
      # "A" has no Workflows/ at all.

      b = AgentCase.mount_test_icm!(ws, name: "B")
      write_workflow!(b.root, "New Inquiry Triage.md", @triage_frontmatter, @triage_body)

      expected = Path.join(b.root, "Workflows/New Inquiry Triage.md")
      assert Workflows.triage_path() == expected
      assert Workflows.triage_path(ws) == expected
    end

    test "returns nil when no enabled mount has a triage workflow", %{workspace: ws} do
      a = AgentCase.mount_test_icm!(ws, name: "A")

      write_workflow!(
        a.root,
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

    test "finds the triage workflow seeded in an enabled mount (A2-T5b acceptance: registry discovery keeps working)",
         %{workspace: ws} do
      ext = AgentCase.mount_test_icm!(ws, name: "Ext")
      write_workflow!(ext.root, "New Inquiry Triage.md", @triage_frontmatter, @triage_body)

      expected = Path.join(ext.root, "Workflows/New Inquiry Triage.md")

      assert Workflows.triage_path() == expected
      assert Workflows.triage_path(ws) == expected
    end

    test "a disabled mount's triage workflow is not found (mirrors list/0's enabled-only gating)",
         %{workspace: ws} do
      a = AgentCase.mount_test_icm!(ws, name: "A")
      write_workflow!(a.root, "New Inquiry Triage.md", @triage_frontmatter, @triage_body)

      assert :ok = Mounts.set_enabled(ws, a.mount_key, false)

      assert Workflows.triage_path() == nil
      assert Workflows.triage_path(ws) == nil
    end
  end

  # distill_path/0,1 (Task B8) mirrors triage_path/0,1's shape exactly (same
  # basename-match-over-list/0 implementation), so this exercises only the
  # cases that matter for that mirroring — not the full triage_path suite
  # above. The starter-mount seed for "Distill Decisions.md" itself is B9's
  # task, so a fresh scaffold's own mount never carries one yet; every test
  # below hand-writes the file the way `triage_path/0,1`'s tests do.
  describe "distill_path/0,1 (Task B8, mirrors triage_path/0,1)" do
    test "finds the distill workflow's resolved_path in the first (alphabetically) enabled mount that has one",
         %{workspace: ws} do
      a = AgentCase.mount_test_icm!(ws, name: "A")
      write_workflow!(a.root, "Distill Decisions.md", @triage_frontmatter, @triage_body)

      b = AgentCase.mount_test_icm!(ws, name: "B")
      write_workflow!(b.root, "Distill Decisions.md", @triage_frontmatter, @triage_body)

      expected = Path.join(a.root, "Workflows/Distill Decisions.md")
      assert Workflows.distill_path() == expected
      assert Workflows.distill_path(ws) == expected
    end

    test "skips a mount lacking the distill workflow and finds it in a later one",
         %{workspace: ws} do
      AgentCase.mount_test_icm!(ws, name: "A")
      # "A" has no Workflows/ at all.

      b = AgentCase.mount_test_icm!(ws, name: "B")
      write_workflow!(b.root, "Distill Decisions.md", @triage_frontmatter, @triage_body)

      expected = Path.join(b.root, "Workflows/Distill Decisions.md")
      assert Workflows.distill_path() == expected
      assert Workflows.distill_path(ws) == expected
    end

    test "returns nil when no enabled mount has a distill workflow (expected until B9 seeds one)",
         %{workspace: ws} do
      a = AgentCase.mount_test_icm!(ws, name: "A")
      write_workflow!(a.root, "New Inquiry Triage.md", @triage_frontmatter, @triage_body)

      assert Workflows.distill_path() == nil
      assert Workflows.distill_path(ws) == nil
    end

    test "returns nil when no workspace is open (list/0's own no-workspace case)" do
      Valea.Workspace.Manager.close()
      assert Workflows.distill_path() == nil
    end
  end
end
