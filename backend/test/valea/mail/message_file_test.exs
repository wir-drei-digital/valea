defmodule Valea.Mail.MessageFileTest do
  use ExUnit.Case, async: true

  alias Valea.Mail.{Message, MessageFile, Normalizer}

  @fixtures_dir Path.expand("../../fixtures/mail", __DIR__)

  defp fixture(name), do: File.read!(Path.join(@fixtures_dir, name))
  defp normalize!(name), do: fixture(name) |> Normalizer.normalize() |> elem(1)

  describe "msg_id/2" do
    test "is deterministic for a message with a Message-ID (hashes the Message-ID)" do
      msg = normalize!("plain.eml")
      raw = fixture("plain.eml")

      id1 = MessageFile.msg_id(msg, raw)
      id2 = MessageFile.msg_id(msg, raw)

      assert id1 == id2
      assert id1 =~ ~r/^2026-07-09-priya-nair-[0-9a-f]{8}$/
    end

    test "is deterministic for a message with no Message-ID (hashes raw_headers instead)" do
      msg = normalize!("no_message_id.eml")
      raw = fixture("no_message_id.eml")

      id1 = MessageFile.msg_id(msg, raw)
      id2 = MessageFile.msg_id(msg, raw)

      assert id1 == id2
      assert id1 =~ ~r/^2026-07-16-priya-nair-[0-9a-f]{8}$/
    end

    test "without a Message-ID, the hash tracks raw_headers (not just the struct)" do
      msg = normalize!("no_message_id.eml")

      id_from_own_headers = MessageFile.msg_id(msg, fixture("no_message_id.eml"))
      id_from_other_headers = MessageFile.msg_id(msg, fixture("plain.eml"))

      refute id_from_own_headers == id_from_other_headers
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
          uid: 4711,
          status: "review",
          source: "imap",
          attachments: []
        })

      expected =
        "---\n" <>
          "id: #{id}\n" <>
          "message_id: \"<CAJx1234@mail.example.com>\"\n" <>
          "from: { name: \"Priya Nair\", email: \"priya@example.com\" }\n" <>
          "to: [{ name: \"Mara Lindt\", email: \"mara@example.com\" }]\n" <>
          "subject: \"Question about leadership coaching\"\n" <>
          "date: 2026-07-09T06:58:00Z\n" <>
          "uid: 4711\n" <>
          "in_reply_to: null\n" <>
          "references: []\n" <>
          "reply_to: null\n" <>
          "status: review\n" <>
          "source: imap\n" <>
          "source_ref: \"email://imap/#{id}\"\n" <>
          "attachments: []\n" <>
          "---\n" <>
          "Hi Mara, I found your work through a colleague.\n\nBest,\nPriya\n"

      assert rendered == expected
    end

    test "meta[:source_ref] overrides the derived ref (seed keeps its legacy ref)" do
      msg = normalize!("plain.eml")
      raw = fixture("plain.eml")
      id = MessageFile.msg_id(msg, raw)

      rendered =
        MessageFile.render(msg, %{
          msg_id: id,
          uid: nil,
          status: "review",
          source: "seed",
          source_ref: "email://seed/priya-nair-inquiry",
          attachments: []
        })

      assert rendered =~ "source: seed\n"
      assert rendered =~ "source_ref: \"email://seed/priya-nair-inquiry\"\n"
      refute rendered =~ "email://seed/#{id}"
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
          uid: 7,
          status: "processed",
          source: "imap",
          attachments: [%{filename: "f.txt", path: "sources/mail/attachments/x/f.txt", bytes: 12}]
        })

      assert rendered =~
               "to: [{ name: \"B\", email: \"b@example.com\" }, { name: null, email: \"c@example.com\" }]\n"

      assert rendered =~ "references: [\"<orig@example.com>\", \"<mid@example.com>\"]\n"
      assert rendered =~ "reply_to: { name: \"D\", email: \"d@example.com\" }\n"
      assert rendered =~ "date: null\n"
      assert rendered =~ "uid: 7\n"

      assert rendered =~
               "attachments: [{ filename: \"f.txt\", path: \"sources/mail/attachments/x/f.txt\", bytes: 12 }]\n"

      # notes appear, in order, after attachments and before the closing ---
      assert rendered =~
               ~r/attachments:.*\ncharset_note: "note1"\nnormalizer_note: "note2"\n---\n/s
    end

    test "omits notes lines entirely when there are none" do
      msg = %Message{from: %{name: nil, email: "x@example.com"}, notes: %{}}

      rendered =
        MessageFile.render(msg, %{
          msg_id: "2026-01-01-x-deadbeef",
          uid: nil,
          status: "review",
          source: "imap",
          attachments: []
        })

      refute rendered =~ "_note"
      assert rendered =~ "attachments: []\n---\n"
    end
  end

  describe "render/2 — frontmatter injection hardening" do
    test "a Subject with an embedded newline renders as one quoted line, not a new YAML key" do
      msg = %Message{subject: "Evil\nstatus: hacked", from: %{name: nil, email: "x@example.com"}}

      rendered =
        MessageFile.render(msg, %{
          msg_id: "2026-01-01-x-deadbeef",
          uid: nil,
          status: "review",
          source: "imap",
          attachments: []
        })

      lines = String.split(rendered, "\n")

      assert Enum.count(lines, &String.starts_with?(&1, "subject:")) == 1
      assert "subject: \"Evil status: hacked\"" in lines
      refute "status: hacked" in lines
      assert "status: review" in lines
    end

    test "double quotes and backslashes in header-derived values are escaped and round-trip" do
      msg = %Message{
        subject: ~s(She said "hi" and used a \\ backslash),
        from: %{name: nil, email: "x@example.com"}
      }

      rendered =
        MessageFile.render(msg, %{
          msg_id: "2026-01-01-x-deadbeef",
          uid: nil,
          status: "review",
          source: "imap",
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
          uid: nil,
          status: "review",
          source: "imap",
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
          uid: nil,
          status: "review",
          source: "imap",
          attachments: []
        })

      assert rendered =~ "from: { name: \"Evil  name\", email: \"x@example.com\" }\n"
    end
  end

  describe "flip_status/2" do
    test "replaces only the status line, byte-preserving everything else" do
      msg = normalize!("plain.eml")
      raw = fixture("plain.eml")
      id = MessageFile.msg_id(msg, raw)

      file_bytes =
        MessageFile.render(msg, %{
          msg_id: id,
          uid: 4711,
          status: "review",
          source: "imap",
          attachments: []
        })

      {:ok, flipped} = MessageFile.flip_status(file_bytes, "processed")

      assert flipped != file_bytes
      assert flipped =~ "status: processed\n"
      refute flipped =~ "status: review\n"

      before_lines = String.split(file_bytes, "\n")
      after_lines = String.split(flipped, "\n")
      assert length(before_lines) == length(after_lines)

      Enum.zip(before_lines, after_lines)
      |> Enum.each(fn {before_line, after_line} ->
        if String.starts_with?(before_line, "status:") do
          assert after_line == "status: processed"
        else
          assert after_line == before_line
        end
      end)
    end

    test "returns {:error, :no_frontmatter} when there is no leading frontmatter block" do
      assert MessageFile.flip_status("just a plain markdown file, no frontmatter\n", "processed") ==
               {:error, :no_frontmatter}
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
          uid: 4711,
          status: "review",
          source: "imap",
          attachments: []
        })

      {:ok, %{frontmatter: frontmatter, body: body}} = MessageFile.parse(file_bytes)

      assert frontmatter["id"] == id
      assert frontmatter["message_id"] == "<CAJx1234@mail.example.com>"
      assert frontmatter["from"] == %{"name" => "Priya Nair", "email" => "priya@example.com"}
      assert frontmatter["status"] == "review"
      assert frontmatter["uid"] == 4711
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
