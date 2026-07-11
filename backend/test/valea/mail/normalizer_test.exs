defmodule Valea.Mail.NormalizerTest do
  use ExUnit.Case, async: true

  alias Valea.Mail.Normalizer

  @fixtures_dir Path.expand("../../fixtures/mail", __DIR__)

  defp fixture(name), do: File.read!(Path.join(@fixtures_dir, name))

  describe "normalize/1 — plain.eml" do
    test "extracts headers and a verbatim (CRLF-normalized) plain-text body" do
      {:ok, msg} = Normalizer.normalize(fixture("plain.eml"))

      assert msg.message_id == "<CAJx1234@mail.example.com>"
      assert msg.from == %{name: "Priya Nair", email: "priya@example.com"}
      assert msg.to == [%{name: "Mara Lindt", email: "mara@example.com"}]
      assert msg.subject == "Question about leadership coaching"
      assert msg.date == ~U[2026-07-09 06:58:00Z]
      assert msg.in_reply_to == nil
      assert msg.references == []
      assert msg.reply_to == nil
      assert msg.body_text == "Hi Mara, I found your work through a colleague.\n\nBest,\nPriya\n"
      assert msg.attachments == []
      assert msg.notes == %{}
    end
  end

  describe "normalize/1 — html_only.eml" do
    test "falls back to Floki-extracted text when there's no text/plain part" do
      {:ok, msg} = Normalizer.normalize(fixture("html_only.eml"))

      assert msg.subject == "HTML only update"
      # <script>/<style> dropped; p/div/li become newlines; no run of 3+ newlines survives.
      assert msg.body_text == "Hello Mara\nSecond paragraph\nOne\nTwo\n"
      assert msg.attachments == []
    end
  end

  describe "normalize/1 — nested_multipart.eml" do
    test "picks the first text/plain depth-first (ignoring the html alt) and collects the attachment" do
      {:ok, msg} = Normalizer.normalize(fixture("nested_multipart.eml"))

      assert msg.body_text == "Plain-text version of the nested message."
      refute msg.body_text =~ "HTML version"

      assert [%{filename: "agenda.txt", content: content}] = msg.attachments
      assert content == "1. Intro\r\n2. Roadmap\r\n3. Q&A"
    end
  end

  describe "normalize/1 — quoted_printable_latin1.eml" do
    test "decodes an ISO-8859-1 quoted-printable body and an RFC 2047 (ISO-8859-1, Q) subject" do
      {:ok, msg} = Normalizer.normalize(fixture("quoted_printable_latin1.eml"))

      assert msg.subject == "Café meeting notes"
      assert msg.body_text == "Café au lait, naïveté garantie.\n"
      assert String.valid?(msg.body_text)
      assert msg.notes == %{}
    end
  end

  describe "normalize/1 — base64_attachment.eml" do
    test "decodes a base64 attachment to its original bytes" do
      {:ok, msg} = Normalizer.normalize(fixture("base64_attachment.eml"))

      assert msg.body_text == "Please find the attached notes."
      assert [%{filename: "notes.txt", content: content}] = msg.attachments
      assert content == "Meeting notes: discuss Q3 roadmap.\n"
    end
  end

  describe "normalize/1 — evil_filename.eml" do
    test "extracts the raw (unsanitized) attachment filename — sanitizing is MessageFile's job" do
      {:ok, msg} = Normalizer.normalize(fixture("evil_filename.eml"))

      assert [%{filename: "../../../etc/passwd"}] = msg.attachments
    end
  end

  describe "normalize/1 — broken_mime.eml" do
    test "never errors: falls back to headers + raw body with a normalizer_note" do
      {:ok, msg} = Normalizer.normalize(fixture("broken_mime.eml"))

      assert msg.message_id == "<broken-mime-001@mail.example.com>"
      assert msg.from == %{name: "Priya Nair", email: "priya@example.com"}
      assert msg.subject == "Corrupted message"
      assert msg.date == ~U[2026-07-15 14:20:00Z]

      assert msg.body_text ==
               "This mail client forgot to declare a boundary.\n" <>
                 "The raw body is recovered best-effort by the normalizer's fallback path.\n"

      assert msg.attachments == []
      assert %{normalizer_note: note} = msg.notes
      assert note =~ "best-effort"
    end
  end

  describe "normalize/1 — no_message_id.eml" do
    test "message_id is nil when the header is absent; everything else still parses" do
      {:ok, msg} = Normalizer.normalize(fixture("no_message_id.eml"))

      assert msg.message_id == nil
      assert msg.subject == "Quick question, no ID"
      assert msg.from == %{name: "Priya Nair", email: "priya@example.com"}
      assert msg.body_text == "This message was sent without a Message-ID header.\n"
    end
  end

  describe "normalize/1 — threaded_reply.eml" do
    test "unfolds a multi-line References header and splits it, and captures In-Reply-To" do
      {:ok, msg} = Normalizer.normalize(fixture("threaded_reply.eml"))

      assert msg.in_reply_to == "<CAJx1234@mail.example.com>"

      assert msg.references == [
               "<first-in-thread@mail.example.com>",
               "<CAJx1234@mail.example.com>",
               "<threaded-reply-000@mail.example.com>"
             ]
    end
  end

  describe "parse_headers/1" do
    test "extracts from/subject/date/message_id from a headers-only block, decoding RFC 2047" do
      header_block =
        "From: Priya Nair <priya@example.com>\r\n" <>
          "Subject: =?utf-8?Q?Caf=C3=A9?=\r\n" <>
          "Date: Thu, 09 Jul 2026 06:58:00 +0000\r\n" <>
          "Message-ID: <abc@example.com>\r\n"

      result = Normalizer.parse_headers(header_block)

      assert result.from == %{name: "Priya Nair", email: "priya@example.com"}
      assert result.subject == "Café"
      assert result.date == ~U[2026-07-09 06:58:00Z]
      assert result.message_id == "<abc@example.com>"
    end

    test "returns nils/empty defaults for headers that are entirely absent" do
      result = Normalizer.parse_headers("Subject: only a subject\r\n")

      assert result.from == %{name: nil, email: nil}
      assert result.date == nil
      assert result.message_id == nil
      assert result.subject == "only a subject"
    end
  end
end
