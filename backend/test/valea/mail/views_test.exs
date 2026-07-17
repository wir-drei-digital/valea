defmodule Valea.Mail.ViewsTest do
  use ExUnit.Case, async: true

  alias Valea.Mail.MessageFile
  alias Valea.Mail.Normalizer
  alias Valea.Mail.Views

  @fixtures_dir Path.expand("../../fixtures/mail", __DIR__)

  defp fixture(name), do: File.read!(Path.join(@fixtures_dir, name))

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-views-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    root = Path.join(dir, "workspace")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{root: root}
  end

  defp view_path(root, account, msg_id), do: Path.join(root, Views.view_rel_path(account, msg_id))

  defp attachments_dir(root, account, msg_id),
    do: Path.join([root, "sources", "mail", account, "views", "attachments", msg_id])

  defp fingerprint_sidecar(root, account, msg_id),
    do: Path.join([root, "sources", "mail", account, "views", ".fingerprints", msg_id])

  describe "land/4" do
    test "writes the view file + attachments; folders/flags empty until refreshed", %{root: root} do
      raw = fixture("base64_attachment.eml")

      assert {:ok, %{msg_id: msg_id, fingerprint: fingerprint, has_attachments: true}} =
               Views.land(root, "mara", raw)

      assert fingerprint == MessageFile.fingerprint(raw)

      path = view_path(root, "mara", msg_id)
      assert File.exists?(path)

      {:ok, %{frontmatter: fm}} = MessageFile.parse(File.read!(path))
      assert fm["id"] == msg_id
      assert fm["account"] == "mara"
      assert fm["folders"] == []
      assert fm["flags"] == ""

      attachments = File.ls!(attachments_dir(root, "mara", msg_id))
      assert attachments == ["notes.txt"]

      assert File.read!(Path.join(attachments_dir(root, "mara", msg_id), "notes.txt")) ==
               "Meeting notes: discuss Q3 roadmap.\n"

      assert File.exists?(fingerprint_sidecar(root, "mara", msg_id))
    end

    test "a message with no attachments lands has_attachments: false and no attachments dir", %{
      root: root
    } do
      raw = fixture("plain.eml")

      assert {:ok, %{msg_id: msg_id, has_attachments: false}} = Views.land(root, "mara", raw)
      refute File.dir?(attachments_dir(root, "mara", msg_id))
    end

    test "landing the exact same bytes twice is a no-op: same msg_id, no duplicate, no clobber",
         %{
           root: root
         } do
      raw = fixture("plain.eml")

      assert {:ok, %{msg_id: id1}} = Views.land(root, "mara", raw)

      # Give the view real folder membership, then re-land the same bytes —
      # the idempotent no-op must NOT wipe that back to folders: [].
      :ok = Views.refresh_folders(root, "mara", id1, ["INBOX"], "S")

      assert {:ok, %{msg_id: id2}} = Views.land(root, "mara", raw)
      assert id1 == id2

      {:ok, %{frontmatter: fm}} = MessageFile.parse(File.read!(view_path(root, "mara", id1)))
      assert fm["folders"] == ["INBOX"]
      assert fm["flags"] == "S"
    end

    test "two accounts landing the same raw bytes are fully isolated", %{root: root} do
      raw = fixture("plain.eml")

      assert {:ok, %{msg_id: id_a}} = Views.land(root, "account-a", raw)
      assert {:ok, %{msg_id: id_b}} = Views.land(root, "account-b", raw)

      assert File.exists?(view_path(root, "account-a", id_a))
      assert File.exists?(view_path(root, "account-b", id_b))

      # removing account-a's view must not touch account-b's.
      :ok = Views.remove_occurrence(root, "account-a", id_a, 0)
      refute File.exists?(view_path(root, "account-a", id_a))
      assert File.exists?(view_path(root, "account-b", id_b))
    end

    test "hash8 collision against a DIFFERENT fingerprint extends the id to 16 hex", %{root: root} do
      raw = fixture("plain.eml")
      {:ok, message} = Normalizer.normalize(raw)
      base_id = MessageFile.msg_id(message, raw)

      # Simulate a pre-existing, unrelated message already occupying the
      # 8-hex candidate under a totally different fingerprint.
      sidecar = fingerprint_sidecar(root, "mara", base_id)
      File.mkdir_p!(Path.dirname(sidecar))
      File.write!(sidecar, String.duplicate("a", 64))

      assert {:ok, %{msg_id: msg_id}} = Views.land(root, "mara", raw)
      refute msg_id == base_id
      assert String.ends_with?(msg_id, String.slice(MessageFile.fingerprint(raw), 0, 16))
    end
  end

  describe "refresh_folders/5" do
    test "rewrites folders (sorted, deduped) and flags in place", %{root: root} do
      raw = fixture("plain.eml")
      {:ok, %{msg_id: msg_id}} = Views.land(root, "mara", raw)

      :ok = Views.refresh_folders(root, "mara", msg_id, ["INBOX", "Archive", "Archive"], "FS")

      {:ok, %{frontmatter: fm}} = MessageFile.parse(File.read!(view_path(root, "mara", msg_id)))
      assert fm["folders"] == ["Archive", "INBOX"]
      assert fm["flags"] == "FS"
    end

    test "a missing view file is a silent no-op", %{root: root} do
      assert :ok = Views.refresh_folders(root, "mara", "does-not-exist", ["INBOX"], "S")
    end
  end

  describe "remove_occurrence/4" do
    test "remaining: 0 deletes the view, attachments dir, and fingerprint sidecar", %{root: root} do
      raw = fixture("base64_attachment.eml")
      {:ok, %{msg_id: msg_id}} = Views.land(root, "mara", raw)

      assert :ok = Views.remove_occurrence(root, "mara", msg_id, 0)

      refute File.exists?(view_path(root, "mara", msg_id))
      refute File.dir?(attachments_dir(root, "mara", msg_id))
      refute File.exists?(fingerprint_sidecar(root, "mara", msg_id))

      # msg_id is free again — landing the same bytes now looks brand new,
      # not an idempotent no-op against stale bookkeeping.
      assert {:ok, %{msg_id: ^msg_id}} = Views.land(root, "mara", raw)
      assert File.exists?(view_path(root, "mara", msg_id))
    end

    test "remaining: 1 (or more) keeps the view and attachments untouched", %{root: root} do
      raw = fixture("base64_attachment.eml")
      {:ok, %{msg_id: msg_id}} = Views.land(root, "mara", raw)
      :ok = Views.refresh_folders(root, "mara", msg_id, ["INBOX"], "S")

      before = File.read!(view_path(root, "mara", msg_id))

      assert :ok = Views.remove_occurrence(root, "mara", msg_id, 1)

      assert File.read!(view_path(root, "mara", msg_id)) == before
      assert File.dir?(attachments_dir(root, "mara", msg_id))
    end

    test "removing an already-absent view is not an error", %{root: root} do
      assert :ok = Views.remove_occurrence(root, "mara", "never-landed", 0)
    end
  end

  describe "view_rel_path/2" do
    test "the exact spec layout" do
      assert Views.view_rel_path("mara", "2026-07-09-priya-nair-abcd1234") ==
               "sources/mail/mara/views/messages/2026-07-09-priya-nair-abcd1234.md"
    end
  end
end
