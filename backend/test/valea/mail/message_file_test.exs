defmodule Valea.Mail.MessageFileTest do
  use ExUnit.Case, async: true

  alias Valea.Mail.{Message, MessageFile, Normalizer}

  @fixtures_dir Path.expand("../../fixtures/mail", __DIR__)

  defp fixture(name), do: File.read!(Path.join(@fixtures_dir, name))
  defp normalize!(name), do: fixture(name) |> Normalizer.normalize() |> elem(1)

  describe "fingerprint/1" do
    test "sha256 hex digest, lowercase, deterministic" do
      raw = fixture("plain.eml")

      assert MessageFile.fingerprint(raw) == MessageFile.fingerprint(raw)
      assert MessageFile.fingerprint(raw) =~ ~r/^[0-9a-f]{64}$/
    end

    test "any byte difference changes the fingerprint" do
      refute MessageFile.fingerprint("hello\n") == MessageFile.fingerprint("hellp\n")
    end
  end

  describe "msg_id/2" do
    test "is deterministic for the same raw bytes" do
      msg = normalize!("plain.eml")
      raw = fixture("plain.eml")

      id1 = MessageFile.msg_id(msg, raw)
      id2 = MessageFile.msg_id(msg, raw)

      assert id1 == id2
      assert id1 =~ ~r/^2026-07-09-priya-nair-[0-9a-f]{8}$/
    end

    test "fingerprint identity: two DIFFERENT raw messages sharing the same Message-ID differ" do
      # Message-ID is sender-controlled and not unique (mail-as-maildir
      # design spec, §Two-level identity) — the id must track the raw
      # bytes' fingerprint, never the Message-ID header.
      msg = %Message{
        message_id: "<dup@example.com>",
        from: %{name: "Priya Nair", email: nil},
        date: ~U[2026-07-09 00:00:00Z]
      }

      raw1 = "Message-ID: <dup@example.com>\r\n\r\nBody one\r\n"
      raw2 = "Message-ID: <dup@example.com>\r\n\r\nBody two\r\n"

      refute MessageFile.msg_id(msg, raw1) == MessageFile.msg_id(msg, raw2)
    end

    test "hash8 is the first 8 hex characters of fingerprint/1" do
      msg = normalize!("plain.eml")
      raw = fixture("plain.eml")

      [_date, _slug, hash8] =
        Regex.run(~r/^(\d{4}-\d{2}-\d{2})-(.+)-([0-9a-f]{8})$/, MessageFile.msg_id(msg, raw),
          capture: :all_but_first
        )

      assert hash8 == String.slice(MessageFile.fingerprint(raw), 0, 8)
    end

    test "from-slug falls back to the email local part when there is no display name" do
      msg = %Message{from: %{name: nil, email: "jdoe@example.com"}, message_id: "<x@example.com>"}

      assert MessageFile.msg_id(msg, "From: jdoe@example.com\r\n") =~
               ~r/^1970-01-01-jdoe-[0-9a-f]{8}$/
    end

    test "from-slug is lowercased, ASCII-slugged, and capped at 40 characters" do
      msg = %Message{
        from: %{name: "Ândré Ünïcode Very Long Display Name For Slug Truncation", email: nil},
        message_id: "<x@example.com>"
      }

      id = MessageFile.msg_id(msg, "irrelevant")

      [_date, slug, _hash] =
        Regex.run(~r/^(\d{4}-\d{2}-\d{2})-(.+)-([0-9a-f]{8})$/, id, capture: :all_but_first)

      assert slug =~ ~r/^[a-z0-9-]+$/
      assert String.length(slug) <= 40
      assert String.starts_with?(slug, "andre-unicode")
    end
  end

  describe "render/2 — golden test (plain.eml)" do
    test "renders the exact frontmatter + body byte layout from the spec" do
      msg = normalize!("plain.eml")
      raw = fixture("plain.eml")
      id = MessageFile.msg_id(msg, raw)

      rendered =
        MessageFile.render(msg, %{
          msg_id: id,
          account: "mara@example.com",
          folders: [],
          flags: "",
          attachments: []
        })

      expected =
        "---\n" <>
          "id: #{id}\n" <>
          "message_id: \"<CAJx1234@mail.example.com>\"\n" <>
          "account: \"mara@example.com\"\n" <>
          "folders: []\n" <>
          "flags: \"\"\n" <>
          "from: { name: \"Priya Nair\", email: \"priya@example.com\" }\n" <>
          "to: [{ name: \"Mara Lindt\", email: \"mara@example.com\" }]\n" <>
          "subject: \"Question about leadership coaching\"\n" <>
          "date: 2026-07-09T06:58:00Z\n" <>
          "in_reply_to: null\n" <>
          "references: []\n" <>
          "reply_to: null\n" <>
          "attachments: []\n" <>
          "---\n" <>
          "Hi Mara, I found your work through a colleague.\n\nBest,\nPriya\n"

      assert rendered == expected
    end

    test "folders/flags carry real occurrence membership when supplied" do
      msg = normalize!("plain.eml")
      raw = fixture("plain.eml")
      id = MessageFile.msg_id(msg, raw)

      rendered =
        MessageFile.render(msg, %{
          msg_id: id,
          account: "mara@example.com",
          folders: ["Archive", "INBOX"],
          flags: "FS",
          attachments: []
        })

      assert rendered =~ "folders: [\"Archive\", \"INBOX\"]\n"
      assert rendered =~ "flags: \"FS\"\n"
    end

    test "renders addresses, references, reply_to, attachments, and notes in field order" do
      msg = %Message{
        message_id: "<a@example.com>",
        from: %{name: "A", email: "a@example.com"},
        to: [%{name: "B", email: "b@example.com"}, %{name: nil, email: "c@example.com"}],
        subject: "Hi",
        date: nil,
        in_reply_to: "<orig@example.com>",
        references: ["<orig@example.com>", "<mid@example.com>"],
        reply_to: %{name: "D", email: "d@example.com"},
        body_text: "body\n",
        attachments: [],
        notes: %{charset_note: "note1", normalizer_note: "note2"}
      }

      rendered =
        MessageFile.render(msg, %{
          msg_id: "2026-01-01-a-deadbeef",
          account: "mara@example.com",
          folders: [],
          flags: "",
          attachments: [
            %{filename: "f.txt", path: "sources/mail/mara/views/attachments/x/f.txt", bytes: 12}
          ]
        })

      assert rendered =~
               "to: [{ name: \"B\", email: \"b@example.com\" }, { name: null, email: \"c@example.com\" }]\n"

      assert rendered =~ "references: [\"<orig@example.com>\", \"<mid@example.com>\"]\n"
      assert rendered =~ "reply_to: { name: \"D\", email: \"d@example.com\" }\n"
      assert rendered =~ "date: null\n"

      assert rendered =~
               "attachments: [{ filename: \"f.txt\", path: \"sources/mail/mara/views/attachments/x/f.txt\", bytes: 12 }]\n"

      # notes appear, in order, after attachments and before the closing ---
      assert rendered =~
               ~r/attachments:.*\ncharset_note: "note1"\nnormalizer_note: "note2"\n---\n/s
    end

    test "omits notes lines entirely when there are none" do
      msg = %Message{from: %{name: nil, email: "x@example.com"}, notes: %{}}

      rendered =
        MessageFile.render(msg, %{
          msg_id: "2026-01-01-x-deadbeef",
          account: "mara@example.com",
          folders: [],
          flags: "",
          attachments: []
        })

      refute rendered =~ "_note"
      assert rendered =~ "attachments: []\n---\n"
    end

    test "has no status, uid, source, or source_ref field" do
      msg = %Message{from: %{name: nil, email: "x@example.com"}}

      rendered =
        MessageFile.render(msg, %{
          msg_id: "2026-01-01-x-deadbeef",
          account: "mara@example.com",
          folders: [],
          flags: "",
          attachments: []
        })

      lines = String.split(rendered, "\n")
      refute Enum.any?(lines, &String.starts_with?(&1, "status:"))
      refute Enum.any?(lines, &String.starts_with?(&1, "uid:"))
      refute Enum.any?(lines, &String.starts_with?(&1, "source:"))
      refute Enum.any?(lines, &String.starts_with?(&1, "source_ref:"))
    end
  end

  describe "render/2 — frontmatter injection hardening" do
    test "a Subject with an embedded newline renders as one quoted line, not a new YAML key" do
      msg = %Message{subject: "Evil\naccount: hacked", from: %{name: nil, email: "x@example.com"}}

      rendered =
        MessageFile.render(msg, %{
          msg_id: "2026-01-01-x-deadbeef",
          account: "mara@example.com",
          folders: [],
          flags: "",
          attachments: []
        })

      lines = String.split(rendered, "\n")

      assert Enum.count(lines, &String.starts_with?(&1, "subject:")) == 1
      assert "subject: \"Evil account: hacked\"" in lines
      refute "account: hacked" in lines
      assert "account: \"mara@example.com\"" in lines
    end

    test "double quotes and backslashes in header-derived values are escaped and round-trip" do
      msg = %Message{
        subject: ~s(She said "hi" and used a \\ backslash),
        from: %{name: nil, email: "x@example.com"}
      }

      rendered =
        MessageFile.render(msg, %{
          msg_id: "2026-01-01-x-deadbeef",
          account: "mara@example.com",
          folders: [],
          flags: "",
          attachments: []
        })

      assert rendered =~ ~s(subject: "She said \\"hi\\" and used a \\\\ backslash"\n)

      {:ok, parsed} = MessageFile.parse(rendered)
      assert parsed.frontmatter["subject"] == ~s(She said "hi" and used a \\ backslash)
    end

    test "invalid UTF-8 in header-derived values is scrubbed, never raises" do
      msg = %Message{
        message_id: <<0x3C, 0xFF, 0xFE, 0x40, 0x3E>>,
        from: %{name: <<"Bad", 0xC3>>, email: "x@example.com"},
        subject: "ok"
      }

      rendered =
        MessageFile.render(msg, %{
          msg_id: "2026-01-01-x-deadbeef",
          account: "mara@example.com",
          folders: [],
          flags: "",
          attachments: []
        })

      assert String.valid?(rendered)
      # <0xFF 0xFE @> — each invalid byte becomes U+FFFD; the frontmatter
      # stays parseable and the value round-trips as the scrubbed string.
      {:ok, %{frontmatter: frontmatter}} = MessageFile.parse(rendered)
      assert frontmatter["message_id"] == "<��@>"
      assert frontmatter["from"]["name"] == "Bad�"
    end

    test "a null byte / DEL in a from name is neutralized, not dropped or left raw" do
      msg = %Message{from: %{name: "Evil\x00\x7Fname", email: "x@example.com"}}

      rendered =
        MessageFile.render(msg, %{
          msg_id: "2026-01-01-x-deadbeef",
          account: "mara@example.com",
          folders: [],
          flags: "",
          attachments: []
        })

      assert rendered =~ "from: { name: \"Evil  name\", email: \"x@example.com\" }\n"
    end
  end

  describe "patch_frontmatter/2" do
    test "replaces only the named lines, byte-preserving everything else (including the body)" do
      msg = normalize!("plain.eml")
      raw = fixture("plain.eml")
      id = MessageFile.msg_id(msg, raw)

      file_bytes =
        MessageFile.render(msg, %{
          msg_id: id,
          account: "mara@example.com",
          folders: [],
          flags: "",
          attachments: []
        })

      {:ok, patched} =
        MessageFile.patch_frontmatter(file_bytes, %{
          "folders" => MessageFile.render_string_list(["Archive", "INBOX"]),
          "flags" => MessageFile.yaml_string("FS")
        })

      assert patched != file_bytes
      assert patched =~ "folders: [\"Archive\", \"INBOX\"]\n"
      assert patched =~ "flags: \"FS\"\n"
      refute patched =~ "folders: []\n"
      refute patched =~ "flags: \"\"\n"

      before_lines = String.split(file_bytes, "\n")
      after_lines = String.split(patched, "\n")
      assert length(before_lines) == length(after_lines)

      Enum.zip(before_lines, after_lines)
      |> Enum.each(fn {before_line, after_line} ->
        cond do
          String.starts_with?(before_line, "folders:") ->
            assert after_line == "folders: [\"Archive\", \"INBOX\"]"

          String.starts_with?(before_line, "flags:") ->
            assert after_line == "flags: \"FS\""

          true ->
            assert after_line == before_line
        end
      end)
    end

    test "a body line that looks like a frontmatter key is never touched" do
      msg = %Message{
        from: %{name: nil, email: "x@example.com"},
        body_text: "folders: not a real frontmatter line\n"
      }

      file_bytes =
        MessageFile.render(msg, %{
          msg_id: "2026-01-01-x-deadbeef",
          account: "mara@example.com",
          folders: [],
          flags: "",
          attachments: []
        })

      {:ok, patched} =
        MessageFile.patch_frontmatter(file_bytes, %{
          "folders" => MessageFile.render_string_list(["INBOX"])
        })

      assert patched =~ "folders: not a real frontmatter line\n"
      assert patched =~ "folders: [\"INBOX\"]\n"
      assert Enum.count(String.split(patched, "\n"), &(&1 == "folders: [\"INBOX\"]")) == 1
    end

    test "returns {:error, :no_frontmatter} when there is no leading frontmatter block" do
      assert MessageFile.patch_frontmatter("just a plain markdown file, no frontmatter\n", %{
               "folders" => "[]"
             }) == {:error, :no_frontmatter}
    end
  end

  describe "parse/1" do
    test "round-trips render/2 output into a frontmatter map + body" do
      msg = normalize!("plain.eml")
      raw = fixture("plain.eml")
      id = MessageFile.msg_id(msg, raw)

      file_bytes =
        MessageFile.render(msg, %{
          msg_id: id,
          account: "mara@example.com",
          folders: ["INBOX"],
          flags: "S",
          attachments: []
        })

      {:ok, %{frontmatter: frontmatter, body: body}} = MessageFile.parse(file_bytes)

      assert frontmatter["id"] == id
      assert frontmatter["message_id"] == "<CAJx1234@mail.example.com>"
      assert frontmatter["from"] == %{"name" => "Priya Nair", "email" => "priya@example.com"}
      assert frontmatter["account"] == "mara@example.com"
      assert frontmatter["folders"] == ["INBOX"]
      assert frontmatter["flags"] == "S"
      assert body == msg.body_text
    end

    test "returns {:error, :no_frontmatter} for a file with no frontmatter block" do
      assert MessageFile.parse("no frontmatter here\n") == {:error, :no_frontmatter}
    end
  end

  describe "sanitize_filename/1" do
    test "strips path traversal down to the basename" do
      assert MessageFile.sanitize_filename("../../../etc/passwd") == "passwd"
    end

    test "strips control characters and path/drive separator characters" do
      assert MessageFile.sanitize_filename("weird\x00name\x7F.txt") == "weirdname.txt"
      assert MessageFile.sanitize_filename("a/b\\c:d") == "bcd"
    end

    test "collapses to \"attachment\" when nothing safe is left" do
      assert MessageFile.sanitize_filename("") == "attachment"
      assert MessageFile.sanitize_filename("   ") == "attachment"
      assert MessageFile.sanitize_filename("/") == "attachment"
      assert MessageFile.sanitize_filename("..") == "attachment"
    end

    test "leaves an ordinary filename untouched" do
      assert MessageFile.sanitize_filename("report.pdf") == "report.pdf"
    end

    test "the evil_filename.eml fixture's raw attachment name sanitizes cleanly" do
      msg = normalize!("evil_filename.eml")
      assert [%{filename: raw_filename}] = msg.attachments
      assert MessageFile.sanitize_filename(raw_filename) == "passwd"
    end
  end
end
