defmodule Valea.Workflows.MemoryProposalTest do
  use ExUnit.Case, async: false

  alias Valea.AgentCase
  alias Valea.Workflows.MemoryProposal
  alias Valea.Workspace.Manager

  # Post-task-3.2, `Valea.Mounts.list/1` is config truth over `icms:` ONLY —
  # no more filesystem-glob discovery of an embedded `mounts/<name>` — so
  # `check_target/2`'s tests below need a REAL mounted EXTERNAL ICM (via
  # `AgentCase.mount_test_icm!/2`) rather than a bare "mounts/primary/..."
  # literal that names nothing. Every target path in those tests is the
  # mounted ICM's ABSOLUTE resolved path (`icm.root`-relative), never the
  # old workspace-relative literal.
  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-app-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    System.put_env("VALEA_APP_DIR", dir)
    Manager.close()
    {:ok, ws} = Manager.create("Primary")

    staging = Path.join(ws.path, "queue/staging/r1")
    File.mkdir_p!(Path.join(staging, "proposals"))

    icm =
      AgentCase.mount_test_icm!(ws.path,
        name: "Primary",
        pages: %{"Pricing/Current Pricing.md" => "# Current Pricing\n"}
      )

    on_exit(fn ->
      Manager.close()
      File.rm_rf!(dir)
      System.delete_env("VALEA_APP_DIR")
    end)

    %{workspace: ws.path, staging: staging, icm: icm}
  end

  defp put_pair(staging, name, manifest, content) do
    File.write!(Path.join([staging, "proposals", name <> ".json"]), Jason.encode!(manifest))
    File.write!(Path.join([staging, "proposals", name <> ".md"]), content)
  end

  defp manifest(target, base \\ nil) do
    %{
      "schema" => "memory_update/v1",
      "target_path" => target,
      "base_sha256" => base,
      "reason" => "rate changed",
      "sources" => ["mounts/primary/Pricing/Current Pricing.md"]
    }
  end

  test "valid pair loads with content", %{staging: staging} do
    put_pair(staging, "pricing", manifest("mounts/primary/Pricing/Current Pricing.md"), "# New\n")

    assert [{"pricing.json", {:ok, %{manifest: m, content: "# New\n"}}}] =
             MemoryProposal.load_pairs(staging)

    assert m["reason"] == "rate changed"
  end

  test "orphaned json and orphaned md are errors", %{staging: staging} do
    File.write!(
      Path.join([staging, "proposals", "a.json"]),
      Jason.encode!(manifest("mounts/primary/x.md"))
    )

    File.write!(Path.join([staging, "proposals", "b.md"]), "hi")

    assert [{"a.json", {:error, :missing_content}}, {"b.md", {:error, :orphaned_content}}] =
             MemoryProposal.load_pairs(staging)
  end

  test "bad schema, empty reason, bad hash are errors", %{staging: staging} do
    put_pair(staging, "s", %{manifest("mounts/primary/x.md") | "schema" => "nope/v1"}, "x")
    put_pair(staging, "r", %{manifest("mounts/primary/x.md") | "reason" => " "}, "x")
    put_pair(staging, "h", %{manifest("mounts/primary/x.md") | "base_sha256" => "zz"}, "x")
    results = Map.new(MemoryProposal.load_pairs(staging))
    assert results["s.json"] == {:error, :invalid_manifest}
    assert results["r.json"] == {:error, :invalid_manifest}
    assert results["h.json"] == {:error, :invalid_manifest}
  end

  test "check_target accepts an enabled external mount page", %{workspace: ws, icm: icm} do
    target = Path.join(icm.root, "Pricing/Current Pricing.md")
    assert {:ok, %{abs: abs}} = MemoryProposal.check_target(ws, target)

    assert abs == target
  end

  test "check_target rejects shell, traversal, and unknown-mount targets", %{
    workspace: ws,
    icm: icm
  } do
    assert {:error, :not_in_mount} = MemoryProposal.check_target(ws, "AGENTS.md")
    assert {:error, :not_in_mount} = MemoryProposal.check_target(ws, "sources/mail/inbox.md")

    assert {:error, :outside_mount} =
             MemoryProposal.check_target(ws, Path.join(icm.root, "../../etc/passwd"))

    assert {:error, :not_in_mount} = MemoryProposal.check_target(ws, "/tmp/nope.md")
  end

  test "check_target rejects a disabled mount", %{workspace: ws, icm: icm} do
    :ok = Valea.Mounts.set_enabled(ws, icm.mount_key, false)

    target = Path.join(icm.root, "Pricing/Current Pricing.md")
    assert {:error, :mount_not_enabled} = MemoryProposal.check_target(ws, target)
  end

  ## check_icm_target/2 (Task 7.3) — scoped to ONE already-known ICM via a
  ## run sidecar's icm_id/icm_root, never re-attributed across every mount.

  defp run_sidecar(icm), do: %{"icm_id" => icm.id, "icm_root" => icm.root}

  test "check_icm_target accepts an ICM-relative path inside the sidecar's icm_root", %{icm: icm} do
    assert {:ok, %{locator: locator, abs: abs}} =
             MemoryProposal.check_icm_target(run_sidecar(icm), "Pricing/Current Pricing.md")

    assert locator == %{
             "kind" => "icm",
             "icm_id" => icm.id,
             "path" => "Pricing/Current Pricing.md"
           }

    assert abs == Path.join(icm.root, "Pricing/Current Pricing.md")
  end

  test "check_icm_target's locator carries the path UNCHANGED — no absolute intermediate", %{
    icm: icm
  } do
    # A create target (does not exist on disk yet) still resolves and still
    # produces a locator whose `path` is exactly the agent's own string —
    # `resolve_real/2`'s missing-remainder-appended-literally behavior, not
    # a round trip through `for_path/2` re-attribution.
    assert {:ok, %{locator: %{"path" => "Decisions/2026-07.md"}}} =
             MemoryProposal.check_icm_target(run_sidecar(icm), "Decisions/2026-07.md")
  end

  test "check_icm_target rejects a target_path that escapes icm_root via ..", %{icm: icm} do
    assert {:error, :outside_mount} =
             MemoryProposal.check_icm_target(run_sidecar(icm), "../../etc/passwd")
  end

  test "check_icm_target is :icm_unavailable when the sidecar's icm_root is missing", %{icm: icm} do
    sidecar = %{"icm_id" => icm.id, "icm_root" => nil}
    assert {:error, :icm_unavailable} = MemoryProposal.check_icm_target(sidecar, "x.md")
  end

  test "check_icm_target never scans other mounts — a DIFFERENT mounted ICM's page is still :outside_mount unless it happens to nest under THIS icm_root",
       %{workspace: ws, icm: icm} do
    other = AgentCase.mount_test_icm!(ws, name: "Other", pages: %{"Notes/Doc.md" => "# Doc\n"})

    # Even though `other` is validly mounted, check_icm_target only ever
    # resolves against the ONE icm_root it was given — it never falls back
    # to scanning `Mounts.list/1` for a different owner the way
    # `check_target/2` would.
    assert {:error, :outside_mount} =
             MemoryProposal.check_icm_target(run_sidecar(icm), other.root <> "/Notes/Doc.md")
  end

  test "content exceeding 1_000_000 bytes is rejected", %{staging: staging} do
    put_pair(
      staging,
      "large",
      manifest("mounts/primary/Pricing/Current Pricing.md"),
      String.duplicate("a", 1_000_001)
    )

    assert [{"large.json", {:error, :content_too_large}}] =
             MemoryProposal.load_pairs(staging)
  end

  test "target_path ending with / is rejected as invalid", %{staging: staging} do
    put_pair(
      staging,
      "dir_target",
      %{manifest("mounts/primary/Pricing/") | "target_path" => "mounts/primary/Pricing/"},
      "# Content\n"
    )

    assert [{"dir_target.json", {:error, :invalid_manifest}}] =
             MemoryProposal.load_pairs(staging)
  end
end
