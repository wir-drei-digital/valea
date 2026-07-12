defmodule Valea.Workflows.MemoryProposalTest do
  use ExUnit.Case, async: false

  alias Valea.Workflows.MemoryProposal
  alias Valea.Workspace.Manager

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-app-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    System.put_env("VALEA_APP_DIR", dir)
    Manager.close()
    {:ok, ws} = Manager.create(Path.join(dir, "workspaces"), "Primary")

    staging = Path.join(ws.path, "queue/staging/r1")
    File.mkdir_p!(Path.join(staging, "proposals"))

    on_exit(fn ->
      Manager.close()
      File.rm_rf!(dir)
      System.delete_env("VALEA_APP_DIR")
    end)

    %{workspace: ws.path, staging: staging}
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

  test "check_target accepts an enabled embedded mount page", %{workspace: ws} do
    assert {:ok, %{abs: abs}} =
             MemoryProposal.check_target(ws, "mounts/primary/Pricing/Current Pricing.md")

    assert String.ends_with?(abs, "/mounts/primary/Pricing/Current Pricing.md")
  end

  test "check_target rejects shell, traversal, and unknown-mount targets", %{workspace: ws} do
    assert {:error, :not_in_mount} = MemoryProposal.check_target(ws, "AGENTS.md")
    assert {:error, :not_in_mount} = MemoryProposal.check_target(ws, "sources/mail/inbox.md")

    assert {:error, :outside_mount} =
             MemoryProposal.check_target(ws, "mounts/primary/../../etc/passwd")

    assert {:error, :not_in_mount} = MemoryProposal.check_target(ws, "/tmp/nope.md")
  end

  test "check_target rejects a disabled mount", %{workspace: ws} do
    :ok = Valea.Mounts.set_enabled("primary", false)

    assert {:error, :mount_not_enabled} =
             MemoryProposal.check_target(ws, "mounts/primary/Pricing/Current Pricing.md")
  end
end
