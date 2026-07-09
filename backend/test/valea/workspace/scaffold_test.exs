defmodule Valea.Workspace.ScaffoldTest do
  use ExUnit.Case, async: true

  alias Valea.Workspace.Scaffold

  defp tmp_target do
    Path.join(System.tmp_dir!(), "valea-ws-#{System.unique_integer([:positive])}")
  end

  test "create scaffolds the full template tree" do
    target = tmp_target()
    assert :ok = Scaffold.create(target)

    for dir <-
          ~w(icm workflows prompts queue/pending queue/approved queue/rejected queue/applied logs sources/mail/normalized config secrets) do
      assert File.dir?(Path.join(target, dir)), "missing #{dir}"
    end

    assert File.exists?(Path.join(target, "icm/Offers/Founder Coaching Package.md"))
    assert File.exists?(Path.join(target, "workflows/new_inquiry_triage.yaml"))
    assert File.exists?(Path.join(target, "sources/mail/normalized/priya-nair-inquiry.json"))
    assert File.exists?(Path.join(target, "logs/audit.jsonl"))
    assert File.exists?(Path.join(target, ".gitignore"))
    refute File.exists?(Path.join(target, "gitignore"))
  end

  test "create refuses a non-empty target" do
    target = tmp_target()
    File.mkdir_p!(target)
    File.write!(Path.join(target, "existing.txt"), "x")
    assert {:error, :target_not_empty} = Scaffold.create(target)
  end

  test "valid? recognizes a scaffolded workspace and rejects others" do
    target = tmp_target()
    :ok = Scaffold.create(target)
    assert Scaffold.valid?(target)
    refute Scaffold.valid?(System.tmp_dir!())
  end

  test "inspect_summary counts content" do
    target = tmp_target()
    :ok = Scaffold.create(target)
    summary = Scaffold.inspect_summary(target)
    assert summary.valid
    assert summary.icm_pages >= 12
    assert summary.workflows == 4
    assert summary.queue_pending == 0
    assert summary.has_audit_log
  end
end
