defmodule Valea.Mail.IndexTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Valea.Mail.Index
  alias Valea.Mail.MessageFile
  alias Valea.Mail.Normalizer
  alias Valea.Mail.Store

  @fixtures_dir Path.expand("../../fixtures/mail", __DIR__)

  defp fixture(name), do: File.read!(Path.join(@fixtures_dir, name))
  defp normalize!(name), do: fixture(name) |> Normalizer.normalize() |> elem(1)

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-index-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    root = Path.join(dir, "workspace")
    File.mkdir_p!(Path.join(root, "sources/mail/messages"))

    # pool_size: 1 — see store_test.exs for why (avoids a transient
    # "database is locked" at pool startup against a brand-new sqlite file).
    start_supervised!({Valea.Repo, database: Path.join(dir, "app.sqlite"), pool_size: 1})

    migrations_path =
      Application.get_env(:valea, :migrations_path) || Ecto.Migrator.migrations_path(Valea.Repo)

    # `ignore_module_conflict` avoids a "redefining module" warning: every
    # test recompiles the same migration file against a brand-new sqlite db.
    previous_compiler_options = Code.compiler_options(ignore_module_conflict: true)
    Ecto.Migrator.run(Valea.Repo, migrations_path, :up, all: true)
    Code.compiler_options(previous_compiler_options)

    on_exit(fn -> File.rm_rf!(dir) end)

    %{root: root}
  end

  defp write_message_file!(root, fixture_name, uid, status) do
    msg = normalize!(fixture_name)
    id = MessageFile.msg_id(msg, fixture(fixture_name))

    bytes =
      MessageFile.render(msg, %{
        msg_id: id,
        uid: uid,
        status: status,
        source: "imap",
        attachments: []
      })

    File.write!(Path.join(root, "sources/mail/messages/#{id}.md"), bytes)

    {id, msg}
  end

  test "indexes valid message files, skips a garbage file, and lands correct statuses", %{
    root: root
  } do
    {id1, msg1} = write_message_file!(root, "plain.eml", 1, "review")
    {id2, _msg2} = write_message_file!(root, "no_message_id.eml", 2, "processed")

    File.write!(
      Path.join(root, "sources/mail/messages/garbage.md"),
      "not a message file, no frontmatter block here\n"
    )

    log =
      capture_log(fn ->
        assert {:ok, 2} = Index.rebuild(root)
      end)

    assert log =~ "skipping unparseable message file"
    assert log =~ "garbage.md"

    assert {:ok, indexed1} = Store.get_message(id1)
    assert indexed1.status == "review"
    assert indexed1.uid == 1
    assert indexed1.path == "sources/mail/messages/#{id1}.md"
    assert indexed1.from_name == msg1.from.name
    assert indexed1.from_email == msg1.from.email
    assert indexed1.subject == msg1.subject

    assert {:ok, %{status: "processed", uid: 2}} = Store.get_message(id2)

    assert {:error, :not_found} = Store.get_message("garbage")
    assert length(Store.list_messages()) == 2
  end

  test "an unparseable file does not abort indexing the rest", %{root: root} do
    {id, _msg} = write_message_file!(root, "plain.eml", 1, "review")

    File.write!(Path.join(root, "sources/mail/messages/broken.md"), "garbage, no frontmatter\n")
    File.write!(Path.join(root, "sources/mail/messages/empty.md"), "")

    capture_log(fn ->
      assert {:ok, 1} = Index.rebuild(root)
    end)

    assert {:ok, _} = Store.get_message(id)
  end

  test "rebuild is safe to rerun — re-indexing upserts rather than duplicating", %{root: root} do
    {id, _msg} = write_message_file!(root, "plain.eml", 1, "review")

    assert {:ok, 1} = Index.rebuild(root)
    assert {:ok, 1} = Index.rebuild(root)
    assert length(Store.list_messages()) == 1
    assert {:ok, %{msg_id: ^id}} = Store.get_message(id)
  end

  test "returns {:ok, 0} when there is nothing to index (directory absent)" do
    empty_root =
      Path.join(System.tmp_dir!(), "valea-index-empty-#{System.unique_integer([:positive])}")

    assert {:ok, 0} = Index.rebuild(empty_root)
  end
end
