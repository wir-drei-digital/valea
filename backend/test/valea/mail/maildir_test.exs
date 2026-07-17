defmodule Valea.Mail.MaildirTest do
  use ExUnit.Case, async: true
  alias Valea.Mail.Maildir

  describe "filename codec" do
    test "round-trips msg_id, uid and sorted flags" do
      name = Maildir.encode_filename("2026-07-15-alex-4f2a91c3", 42, MapSet.new(["S", "F"]))
      assert name == "2026-07-15-alex-4f2a91c3,U=42:2,FS"

      assert {:ok, %{msg_id: "2026-07-15-alex-4f2a91c3", uid: 42, flags: flags}} =
               Maildir.parse_filename(name)

      assert MapSet.equal?(flags, MapSet.new(["S", "F"]))
    end

    test "uid-less filename (pre-confirmation) round-trips" do
      name = Maildir.encode_filename("2026-07-15-alex-4f2a91c3", nil, MapSet.new())
      assert name == "2026-07-15-alex-4f2a91c3:2,"
      assert {:ok, %{uid: nil, flags: flags}} = Maildir.parse_filename(name)
      assert MapSet.size(flags) == 0
    end

    test "rejects garbage" do
      assert :error = Maildir.parse_filename("no-flags-part")
      assert :error = Maildir.parse_filename("id,U=notanum:2,S")
    end

    test "rejects uid 0 (IMAP UIDs must be >= 1)" do
      assert :error = Maildir.parse_filename("id,U=0:2,S")
    end
  end

  describe "flag mapping" do
    test "letters <-> IMAP system flags, unknown IMAP flags dropped" do
      assert Maildir.flags_to_imap(MapSet.new(["S", "T"])) |> Enum.sort() ==
               ["\\Deleted", "\\Seen"]

      assert MapSet.equal?(
               Maildir.flags_from_imap(["\\Seen", "\\Answered", "$Forwarded"]),
               MapSet.new(["S", "R"])
             )
    end

    test "pushable set is exactly S/R/F" do
      assert MapSet.equal?(Maildir.pushable_flags(), MapSet.new(["S", "R", "F"]))
    end
  end

  describe "folder mapping" do
    test "escapes reserved segments, %, and leading dots reversibly" do
      for raw <- ["cur", "new", "tmp", ".hidden", "50%off", "Work/Clients"] do
        encoded = raw |> String.split("/") |> Enum.map(&Maildir.encode_segment/1)
        assert raw == encoded |> Enum.map(&Maildir.decode_segment/1) |> Enum.join("/")
        refute Enum.any?(encoded, &(&1 in ["cur", "new", "tmp"]))
      end
    end

    test "case-colliding IMAP names get distinct dirs (APFS injectivity)" do
      a = Maildir.folder_to_dir("Clients", MapSet.new())
      taken = MapSet.new([a |> String.downcase() |> :unicode.characters_to_nfc_binary()])
      b = Maildir.folder_to_dir("clients", taken)
      refute String.downcase(a) == String.downcase(b)
      assert b =~ ~r/-[0-9a-f]{6}$/
    end

    test "suffixed candidate colliding with a pre-existing literal dir extends the digest" do
      norm = fn s -> s |> String.downcase() |> :unicode.characters_to_nfc_binary() end
      first_suffix = Maildir.folder_to_dir("clients", MapSet.new([norm.("clients")]))
      taken = MapSet.new([norm.("clients"), norm.(first_suffix)])
      c = Maildir.folder_to_dir("clients", taken)
      refute norm.(c) in taken
      assert c =~ ~r/-[0-9a-f]{12}$/
    end

    test "folder_to_dir raises RuntimeError when all 64-hex suffixes are exhausted" do
      norm = fn s -> s |> String.downcase() |> :unicode.characters_to_nfc_binary() end
      base_path = "conflict"
      base_norm = norm.(base_path)

      # Build a taken set with all possible suffix lengths exhausted
      # We need to simulate all 11 suffix lengths: 6, 12, 18, 24, 30, 36, 42, 48, 54, 60, 64
      sha_hex = :crypto.hash(:sha256, "conflict") |> Base.encode16(case: :lower)

      taken_set =
        [6, 12, 18, 24, 30, 36, 42, 48, 54, 60, 64]
        |> Enum.map(fn hex_len ->
          suffix = "-" <> String.slice(sha_hex, 0, hex_len)
          norm.("#{base_path}#{suffix}")
        end)
        |> MapSet.new()
        |> MapSet.put(base_norm)

      assert_raise RuntimeError, fn -> Maildir.folder_to_dir("conflict", taken_set) end
    end

    test ".folder identity file is authoritative and atomic" do
      dir = Path.join(System.tmp_dir!(), "maildir-#{System.unique_integer([:positive])}")
      :ok = Maildir.mailbox_dirs(dir)
      :ok = Maildir.write_folder_identity!(dir, "Work/Clients")
      assert {:ok, "Work/Clients"} = Maildir.read_folder_identity(dir)
      assert File.dir?(Path.join(dir, "cur")) and File.dir?(Path.join(dir, "tmp"))
    end

    test "read_folder_identity returns :error when .folder file doesn't exist" do
      dir = Path.join(System.tmp_dir!(), "maildir-#{System.unique_integer([:positive])}")
      :ok = Maildir.mailbox_dirs(dir)
      assert :error = Maildir.read_folder_identity(dir)
    end
  end

  describe "delivery" do
    test "deliver! lands via tmp/ then cur/, listable" do
      dir = Path.join(System.tmp_dir!(), "maildir-#{System.unique_integer([:positive])}")
      :ok = Maildir.mailbox_dirs(dir)
      name = Maildir.encode_filename("2026-01-01-a-deadbeef", 7, MapSet.new(["S"]))
      :ok = Maildir.deliver!(dir, name, "raw bytes")
      assert File.read!(Path.join([dir, "cur", name])) == "raw bytes"
      assert [] = Path.wildcard(Path.join([dir, "tmp", "*"]))
      assert [%{msg_id: "2026-01-01-a-deadbeef", uid: 7}] = Maildir.list_occurrences(dir)
    end
  end
end
