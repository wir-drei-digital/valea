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

  test "list/0 unions two enabled mounts, each workflow with distinct path + mount provenance",
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

    wf_a_path = Path.join(a.root, "Workflows/Triage.md")
    wf_b_path = Path.join(b.root, "Workflows/Review.md")

    wf_a = Enum.find(workflows, &(&1.path == wf_a_path))
    assert wf_a.mount == "A"
    assert wf_a.name == "New Inquiry Triage"
    assert wf_a.enabled == true

    wf_b = Enum.find(workflows, &(&1.path == wf_b_path))
    assert wf_b.mount == "B"
    assert wf_b.name == "Review"
    assert wf_b.enabled == false

    # sorted by path
    assert Enum.map(workflows, & &1.path) == Enum.sort(Enum.map(workflows, & &1.path))
  end

  test "same workflow filename in two mounts coexists without shadowing", %{workspace: ws} do
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
    paths = Enum.map(workflows, & &1.path)

    wf_a_path = Path.join(a.root, "Workflows/Shared.md")
    wf_b_path = Path.join(b.root, "Workflows/Shared.md")

    assert wf_a_path in paths
    assert wf_b_path in paths
    assert length(workflows) == 2

    a_wf = Enum.find(workflows, &(&1.path == wf_a_path))
    b_wf = Enum.find(workflows, &(&1.path == wf_b_path))
    assert a_wf.name == "A Shared"
    assert b_wf.name == "B Shared"
  end

  test "external mounts' workflows are surfaced in list/1 with absolute paths (A2-T5b), alongside embedded",
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

    assert Enum.map(workflows, & &1.path) |> Enum.sort() ==
             Enum.sort([
               Path.join(a.root, "Workflows/Triage.md"),
               Path.join(ext.root, "Workflows/External.md")
             ])

    ext_wf = Enum.find(workflows, &(&1.mount == "Ext"))
    assert ext_wf.path == Path.join(ext.root, "Workflows/External.md")
    assert ext_wf.name == "Ext WF"
    assert ext_wf.enabled == true
  end

  test "a DISABLED external mount drops out of list/1 AND its absolute path no longer resolves via get/1 (unlike a disabled embedded mount — see Mounts.mount_for/1's enabled-only external attribution)",
       %{workspace: ws} do
    ext = AgentCase.mount_test_icm!(ws, name: "Ext")

    write_workflow!(
      ext.root,
      "External.md",
      "enabled: true\nrisk_level: low\n",
      "# Ext WF\n\nBody.\n"
    )

    ext_wf_path = Path.join(ext.root, "Workflows/External.md")

    assert {:ok, [_one]} = Workflows.list()
    assert {:ok, _wf} = Workflows.get(ext_wf_path)

    :ok = Mounts.set_enabled(ws, ext.mount_key, false)

    assert {:ok, []} = Workflows.list()
    assert {:error, :not_found} = Workflows.get(ext_wf_path)
  end

  # Every mount is external now, so Mounts.mount_for/1's enabled-only
  # attribution applies uniformly: the old embedded-mount "T3 posture"
  # (get/1 kept resolving a disabled mount's explicit path even after
  # list/0 dropped it) no longer holds for ANY mount — mirrors the
  # DISABLED-external-mount test above.
  test "disabling a mount drops its workflows from list/0, and get/1 by explicit path no longer resolves it either (T3 posture superseded)",
       %{workspace: ws} do
    a = AgentCase.mount_test_icm!(ws, name: "A")
    write_workflow!(a.root, "Triage.md", @triage_frontmatter, @triage_body)

    wf_path = Path.join(a.root, "Workflows/Triage.md")

    assert {:ok, wf} = Workflows.get(wf_path)
    assert wf.name == "New Inquiry Triage"
    assert wf.mount == "A"
    assert wf.path == wf_path

    assert {:ok, [_one]} = Workflows.list()

    assert :ok = Mounts.set_enabled(ws, a.mount_key, false)

    assert {:ok, []} = Workflows.list()
    assert {:error, :not_found} = Workflows.get(wf_path)
  end

  test "get/1 parses frontmatter (trigger.source, risk_level, approval.actions) and steps_preview",
       %{workspace: ws} do
    a = AgentCase.mount_test_icm!(ws, name: "A")
    write_workflow!(a.root, "Triage.md", @triage_frontmatter, @triage_body)

    wf_path = Path.join(a.root, "Workflows/Triage.md")
    assert {:ok, wf} = Workflows.get(wf_path)

    assert wf.path == wf_path
    assert wf.mount == "A"
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
    a = AgentCase.mount_test_icm!(ws, name: "A")

    write_workflow!(
      a.root,
      "Weekly.md",
      "enabled: false\nrisk_level: low\n",
      "# Weekly\n\nBody.\n"
    )

    wf_path = Path.join(a.root, "Workflows/Weekly.md")
    assert {:ok, wf} = Workflows.get(wf_path)
    assert wf.enabled == false
    assert wf.risk_level == "low"
  end

  test "get/1 on a missing path returns not_found", %{workspace: ws} do
    a = AgentCase.mount_test_icm!(ws, name: "A")
    assert {:error, :not_found} = Workflows.get(Path.join(a.root, "Workflows/Nonexistent.md"))
  end

  test "get/1 outside mounts/<name>/Workflows/ returns not_found", %{workspace: ws} do
    a = AgentCase.mount_test_icm!(ws, name: "A")
    File.mkdir_p!(Path.join(a.root, "Offers"))
    File.write!(Path.join(a.root, "Offers/X.md"), "---\nenabled: true\n---\n# X\n")

    assert {:error, :not_found} = Workflows.get(Path.join(a.root, "Offers/X.md"))
  end

  test "get/1 with a path that doesn't name a mount at all returns not_found", %{workspace: ws} do
    AgentCase.mount_test_icm!(ws, name: "A")
    assert {:error, :not_found} = Workflows.get("sources/mail/messages/x.md")
  end

  test "get/1 with a path containing .. that escapes the mount returns not_found", %{
    workspace: ws
  } do
    a = AgentCase.mount_test_icm!(ws, name: "A")

    escape_path =
      Path.join([a.root, "Workflows", String.duplicate("../", 15) <> "etc/passwd"])

    assert {:error, :not_found} = Workflows.get(escape_path)
  end

  test "get/1 with a path that lexically starts with mounts/<name>/Workflows/ but traverses out of it (while staying inside the mount) returns not_found",
       %{workspace: ws} do
    a = AgentCase.mount_test_icm!(ws, name: "A")
    File.mkdir_p!(Path.join(a.root, "Offers"))
    File.write!(Path.join(a.root, "Offers/escaped.md"), "# Escaped\n")

    assert {:error, :not_found} =
             Workflows.get(Path.join(a.root, "Workflows/../Offers/escaped.md"))
  end

  test "get/1 with a path that traverses from one mount into another returns not_found", %{
    workspace: ws
  } do
    a = AgentCase.mount_test_icm!(ws, name: "A")
    b = AgentCase.mount_test_icm!(ws, name: "B")
    write_workflow!(b.root, "Secret.md", "enabled: true\n", "# Secret\n\nBody.\n")

    # Lexically starts with `a.root`'s own Workflows/ (so `mount_for/2`'s
    # prefix attribution first ties this to mount "a"), but two ".." hops
    # climb out of "a" entirely and back down into sibling mount "b"'s own
    # Workflows/ — `a` and `b` are both direct children of the same tmp
    # parent (`AgentCase.mount_test_icm!/2` always mints them there), so
    # this reaches `b`'s real file while staying a real, resolvable path.
    escape_path =
      Path.join(a.root, "Workflows") <>
        "/../../" <> Path.basename(b.root) <> "/Workflows/Secret.md"

    assert {:error, :not_found} = Workflows.get(escape_path)
  end

  test "a Workflows/ page without frontmatter is not a contract: list/0 skips it, get/1 -> not_found",
       %{workspace: ws} do
    a = AgentCase.mount_test_icm!(ws, name: "A")
    write_workflow!(a.root, "Triage.md", @triage_frontmatter, @triage_body)

    no_fm_path = Path.join(a.root, "Workflows/No Frontmatter.md")

    File.write!(
      no_fm_path,
      "# No Frontmatter\n\nJust a plain page, no YAML header.\n"
    )

    assert {:error, :not_found} = Workflows.get(no_fm_path)

    assert {:ok, workflows} = Workflows.list()
    assert length(workflows) == 1
    refute Enum.any?(workflows, &(&1.path == no_fm_path))
  end

  test "get/1 on an external mount's absolute path outside its Workflows/ returns not_found",
       %{workspace: ws} do
    ext = AgentCase.mount_test_icm!(ws, name: "Ext")
    File.mkdir_p!(Path.join(ext.root, "Offers"))
    File.write!(Path.join(ext.root, "Offers/X.md"), "---\nenabled: true\n---\n# X\n")

    assert {:error, :not_found} = Workflows.get(Path.join(ext.root, "Offers/X.md"))
  end

  test "get/1 on an external mount's absolute path that traverses out of its Workflows/ (while staying inside the mount) returns not_found",
       %{workspace: ws} do
    ext = AgentCase.mount_test_icm!(ws, name: "Ext")
    File.mkdir_p!(Path.join(ext.root, "Offers"))
    File.write!(Path.join(ext.root, "Offers/escaped.md"), "# Escaped\n")

    escape_path = Path.join(ext.root, "Workflows/../Offers/escaped.md")
    assert {:error, :not_found} = Workflows.get(escape_path)
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
    assert hd(workflows).path == Path.join(valid.root, "Workflows/Good.md")
    assert hd(workflows).mount == "Valid Mount"
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
    test "finds the triage workflow's path in the first (alphabetically) enabled mount that has one",
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

    test "finds the triage workflow seeded in an enabled EXTERNAL mount (A2-T5b acceptance: registry discovery keeps working)",
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
    test "finds the distill workflow's path in the first (alphabetically) enabled mount that has one",
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
