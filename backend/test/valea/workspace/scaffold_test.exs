defmodule Valea.Workspace.ScaffoldTest do
  use ExUnit.Case, async: true

  alias Valea.Workspace.Scaffold

  defp tmp_target do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-ws-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  test "create scaffolds the full template tree" do
    target = tmp_target()
    assert :ok = Scaffold.create(target)

    for dir <-
          ~w(icm icm/Workflows prompts queue/pending queue/approved queue/rejected queue/applied queue/staging queue/processing logs sources/mail/messages sources/mail/attachments config secrets) do
      assert File.dir?(Path.join(target, dir)), "missing #{dir}"
    end

    assert File.exists?(Path.join(target, "icm/Offers/Founder Coaching Package.md"))
    assert File.exists?(Path.join(target, "icm/Workflows/New Inquiry Triage.md"))
    # v3: the legacy normalized JSON is gone, replaced by a seed markdown message
    assert File.exists?(
             Path.join(target, "sources/mail/messages/2026-07-09-priya-nair-seed0001.md")
           )

    refute File.exists?(Path.join(target, "sources/mail/normalized/priya-nair-inquiry.json"))
    assert File.exists?(Path.join(target, "logs/audit.jsonl"))
    assert File.exists?(Path.join(target, ".gitignore"))
    refute File.exists?(Path.join(target, "gitignore"))
  end

  test "create writes version 3 + a fresh workspace uuid (not the template placeholder)" do
    target = tmp_target()
    assert :ok = Scaffold.create(target)

    yaml = File.read!(Path.join(target, "config/workspace.yaml"))
    assert yaml =~ "version: 3"
    assert [uuid] = Regex.run(~r/^id: ([0-9a-f-]{36})$/m, yaml, capture: :all_but_first)
    refute uuid == "TEMPLATE"

    # a second scaffold gets a different id
    other = tmp_target()
    :ok = Scaffold.create(other)
    other_yaml = File.read!(Path.join(other, "config/workspace.yaml"))

    assert [other_uuid] =
             Regex.run(~r/^id: ([0-9a-f-]{36})$/m, other_yaml, capture: :all_but_first)

    refute other_uuid == uuid
  end

  test "the seed message is byte-identical to MessageFile.render output (parses cleanly)" do
    target = tmp_target()
    :ok = Scaffold.create(target)

    bytes =
      File.read!(Path.join(target, "sources/mail/messages/2026-07-09-priya-nair-seed0001.md"))

    assert {:ok, %{frontmatter: fm, body: body}} = Valea.Mail.MessageFile.parse(bytes)
    assert fm["id"] == "2026-07-09-priya-nair-seed0001"
    assert fm["message_id"] == "<seed-priya-nair-inquiry@valea.seed>"
    assert fm["source"] == "seed"
    assert fm["source_ref"] == "email://seed/priya-nair-inquiry"
    assert fm["status"] == "review"
    assert String.starts_with?(body, "Hi Mara,")

    # the file is exactly what the renderer produces — no drift between the
    # committed seed and Valea.Mail.MessageFile
    message = %Valea.Mail.Message{
      message_id: "<seed-priya-nair-inquiry@valea.seed>",
      from: %{name: "Priya Nair", email: "priya@example.com"},
      to: [%{name: "Mara Lindt", email: "mara@example.com"}],
      subject: "Question about leadership coaching",
      date: ~U[2026-07-09 06:58:00Z],
      body_text: body
    }

    rendered =
      Valea.Mail.MessageFile.render(message, %{
        msg_id: "2026-07-09-priya-nair-seed0001",
        uid: nil,
        status: "review",
        source: "seed",
        source_ref: "email://seed/priya-nair-inquiry",
        attachments: []
      })

    assert rendered == bytes
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
