defmodule Valea.Mail.DraftMimeTest do
  use ExUnit.Case, async: true

  alias Valea.Mail.DraftFile
  alias Valea.Mail.DraftMime

  @message_id "<valea.push.0123456789abcdef@valea.invalid>"

  defp validated(overrides \\ %{}) do
    base = %{
      to: [%{name: "Priya Nair", email: "priya@example.com"}],
      cc: [],
      bcc: [],
      subject: "Re: Inquiry",
      in_reply_to: nil,
      attachments: [],
      status: "draft",
      body: "Hello Priya,\n\nThanks for reaching out — happy to help! Grüße.\n"
    }

    Map.merge(base, overrides)
  end

  defp threading(overrides \\ %{}) do
    Map.merge(%{in_reply_to: nil, references: []}, overrides)
  end

  # mimemail folds header lines > 78 chars onto `\r\n\t` continuations; unfold
  # so a single-string assertion sees the logical header value.
  defp unfold(rfc822), do: String.replace(rfc822, ~r/\r\n[ \t]+/, " ")

  describe "compose/4" do
    test "builds headers from the parsed values, threading, Message-ID, and a QP text/plain body" do
      thread =
        threading(%{
          in_reply_to: "<CADorig@mail.example.com>",
          references: ["<thread-root@example.com>", "<CADorig@mail.example.com>"]
        })

      assert {:ok, rfc822} =
               DraftMime.compose(validated(), thread, @message_id, "mara@example.com")

      unfolded = unfold(rfc822)

      assert unfolded =~ "From: mara@example.com"
      assert unfolded =~ "To: Priya Nair <priya@example.com>"
      assert unfolded =~ "Subject: Re: Inquiry"
      assert unfolded =~ "In-Reply-To: <CADorig@mail.example.com>"

      assert unfolded =~
               "References: <thread-root@example.com> <CADorig@mail.example.com>"

      assert rfc822 =~ "Message-ID: #{@message_id}"
      assert unfolded =~ ~r/\r\nDate: \w{3}, \d{2} \w{3} \d{4} \d{2}:\d{2}:\d{2} \+0000/

      assert rfc822 =~ "Content-Type: text/plain"
      assert unfolded =~ "charset=utf-8"
      assert rfc822 =~ "Content-Transfer-Encoding: quoted-printable"

      {"text", "plain", _headers, _params, body} =
        :mimemail.decode(rfc822, encoding: :none, allow_missing_version: true)

      assert body == "Hello Priya,\n\nThanks for reaching out — happy to help! Grüße.\n"
    end

    test "serializes multiple To recipients and a Cc from the parsed values" do
      v =
        validated(%{
          to: [
            %{name: "Priya Nair", email: "priya@example.com"},
            %{name: nil, email: "sam@example.com"}
          ],
          cc: [%{name: nil, email: "cc@example.com"}]
        })

      assert {:ok, rfc822} = DraftMime.compose(v, threading(), @message_id, "mara@example.com")
      unfolded = unfold(rfc822)
      assert unfolded =~ "To: Priya Nair <priya@example.com>, sam@example.com"
      assert unfolded =~ "Cc: cc@example.com"
    end

    test "includes a Bcc header when the parsed bcc set is non-empty" do
      v = validated(%{bcc: [%{name: nil, email: "hidden@example.com"}]})
      assert {:ok, rfc822} = DraftMime.compose(v, threading(), @message_id, "mara@example.com")
      assert unfold(rfc822) =~ "Bcc: hidden@example.com"
    end

    test "omits Cc/Bcc/In-Reply-To/References when empty" do
      assert {:ok, rfc822} = DraftMime.compose(validated(), threading(), @message_id, "m@x.com")
      refute rfc822 =~ "\r\nCc:"
      refute rfc822 =~ "\r\nBcc:"
      refute rfc822 =~ "In-Reply-To:"
      refute rfc822 =~ "References:"
    end

    test "falls back to a synthetic From when none is given (never-block)" do
      assert {:ok, rfc822} = DraftMime.compose(validated(), threading(), @message_id, nil)
      assert unfold(rfc822) =~ "From: valea@valea.invalid"
    end

    test "quotes a display name with RFC 5322 specials in the To header" do
      v = validated(%{to: [%{name: "Nair, Priya (Sales)", email: "priya@example.com"}]})
      assert {:ok, rfc822} = DraftMime.compose(v, threading(), @message_id, "m@x.com")
      assert unfold(rfc822) =~ "To: \"Nair, Priya (Sales)\" <priya@example.com>"
    end

    test "RFC-2047-encodes a non-ASCII display name in the To header" do
      v = validated(%{to: [%{name: "Grüße Nair", email: "g@example.com"}]})
      assert {:ok, rfc822} = DraftMime.compose(v, threading(), @message_id, "m@x.com")
      assert unfold(rfc822) =~ "To: =?UTF-8?Q?Gr=C3=BC=C3=9Fe_Nair?= <g@example.com>"
      refute unfold(rfc822) =~ "To: Grüße"
    end

    test "RFC-2047-encodes a non-ASCII subject" do
      v = validated(%{subject: "Grüße"})
      assert {:ok, rfc822} = DraftMime.compose(v, threading(), @message_id, "m@x.com")
      assert unfold(rfc822) =~ "Subject: =?UTF-8?"
      refute rfc822 =~ "Subject: Grüße"
    end
  end

  describe "push_message_id/3" do
    test "is stable per (account, draft_name, content_hash) and uses the .invalid TLD" do
      id = DraftMime.push_message_id("mara", "reply.md", "deadbeef")
      assert id == DraftMime.push_message_id("mara", "reply.md", "deadbeef")
      assert id =~ ~r/^<valea\.push\.[0-9a-f]{16}@valea\.invalid>$/
    end

    test "changes when any component changes" do
      base = DraftMime.push_message_id("mara", "reply.md", "deadbeef")
      refute base == DraftMime.push_message_id("other", "reply.md", "deadbeef")
      refute base == DraftMime.push_message_id("mara", "other.md", "deadbeef")
      refute base == DraftMime.push_message_id("mara", "reply.md", "cafef00d")
    end
  end

  describe "send_message_id/3" do
    test "is stable per (account, draft_name, canonical_hash) and uses the .invalid TLD" do
      id = DraftMime.send_message_id("mara", "reply.md", "deadbeef")
      assert id == DraftMime.send_message_id("mara", "reply.md", "deadbeef")
      assert id =~ ~r/^<valea\.send\.[0-9a-f]{16}@valea\.invalid>$/
    end

    # Domain separation, not decoration: a pushed COPY of a draft and the SENT
    # message of that same draft are two different objects on the server. If
    # they shared a Message-ID, the send's idempotent Sent-copy search would
    # find the pushed draft and conclude the mail was already filed.
    test "never collides with push_message_id/3 on identical inputs" do
      refute DraftMime.send_message_id("mara", "reply.md", "deadbeef") ==
               DraftMime.push_message_id("mara", "reply.md", "deadbeef")
    end

    test "changes when any component changes" do
      base = DraftMime.send_message_id("mara", "reply.md", "deadbeef")
      refute base == DraftMime.send_message_id("other", "reply.md", "deadbeef")
      refute base == DraftMime.send_message_id("mara", "other.md", "deadbeef")
      refute base == DraftMime.send_message_id("mara", "reply.md", "cafef00d")
    end

    # The end-to-end retry property: a failed attempt stamps the draft
    # (`sending`, then back to `draft`), and the human clicks Send again. The
    # canonical hash — and so the Message-ID — must not have moved, or the
    # recipient gets a duplicate instead of a dedupe.
    test "is stable across the engine's status stamps, via the canonical bytes" do
      bytes = "---\nto: [a@b.co]\nsubject: \"Hi\"\n---\nBody.\n"
      id = send_id_for(bytes)

      for status <- ["sending", "send_review", "sent", "draft"] do
        assert {:ok, stamped} = DraftFile.stamp_status(bytes, status)
        assert send_id_for(stamped) == id
      end
    end
  end

  defp send_id_for(bytes) do
    canonical_hash = bytes |> DraftFile.canonical_send_bytes() |> DraftFile.content_hash()
    DraftMime.send_message_id("mara", "reply.md", canonical_hash)
  end

  describe "compose_send/5" do
    @send_id "<valea.send.0123456789abcdef@valea.invalid>"

    test "wire drops the Bcc header, record keeps it, and both are otherwise the same message" do
      v =
        validated(%{
          cc: [%{name: nil, email: "cc@example.com"}],
          bcc: [%{name: nil, email: "hidden@example.com"}]
        })

      assert {:ok, %{wire: wire, record: record, envelope: envelope}} =
               DraftMime.compose_send(v, threading(), @send_id, "mara@example.com", nil)

      refute unfold(wire) =~ "Bcc:"
      assert unfold(record) =~ "Bcc: hidden@example.com"

      # One header list, built once: the two variants cannot disagree on
      # identity or timestamp, which is what makes the Sent copy the same
      # message the recipient received.
      assert header_line(wire, "Message-ID") == header_line(record, "Message-ID")
      assert header_line(wire, "Date") == header_line(record, "Date")
      assert header_line(wire, "Cc") == header_line(record, "Cc")

      # ...but the BCC recipient still gets the mail: it rides the envelope,
      # which is the whole reason wire and record differ at all.
      assert envelope == %{
               from: "mara@example.com",
               rcpt: ["priya@example.com", "cc@example.com", "hidden@example.com"]
             }
    end

    test "empty bcc: neither variant carries a Bcc header and wire == record" do
      assert {:ok, %{wire: wire, record: record, envelope: envelope}} =
               DraftMime.compose_send(validated(), threading(), @send_id, "mara@example.com", nil)

      refute unfold(wire) =~ "Bcc:"
      refute unfold(record) =~ "Bcc:"
      assert wire == record
      assert envelope.rcpt == ["priya@example.com"]
    end

    test "envelope.rcpt dedupes across to/cc/bcc, order-preserving" do
      v =
        validated(%{
          to: [%{name: nil, email: "a@x.co"}, %{name: nil, email: "b@x.co"}],
          cc: [%{name: nil, email: "a@x.co"}],
          bcc: [%{name: nil, email: "c@x.co"}, %{name: nil, email: "b@x.co"}]
        })

      assert {:ok, %{envelope: envelope}} =
               DraftMime.compose_send(v, threading(), @send_id, "mara@example.com", nil)

      assert envelope.rcpt == ["a@x.co", "b@x.co", "c@x.co"]
    end

    test "from_name becomes an RFC 2047-encoded display name in BOTH variants" do
      v = validated(%{bcc: [%{name: nil, email: "hidden@example.com"}]})

      assert {:ok, %{wire: wire, record: record, envelope: envelope}} =
               DraftMime.compose_send(v, threading(), @send_id, "mara@example.com", "Mara Grüß")

      for variant <- [wire, record] do
        assert unfold(variant) =~ "From: =?UTF-8?Q?Mara_Gr=C3=BC=C3=9F?= <mara@example.com>"
      end

      # The ENVELOPE sender stays the bare addr-spec — a display name has no
      # business in a MAIL FROM.
      assert envelope.from == "mara@example.com"
    end

    test "an ASCII from_name is quoted only when it carries RFC 5322 specials" do
      assert {:ok, %{wire: plain}} =
               DraftMime.compose_send(validated(), threading(), @send_id, "m@x.co", "Mara Kim")

      assert unfold(plain) =~ "From: Mara Kim <m@x.co>"

      assert {:ok, %{wire: quoted}} =
               DraftMime.compose_send(validated(), threading(), @send_id, "m@x.co", "Kim, Mara")

      assert unfold(quoted) =~ ~s(From: "Kim, Mara" <m@x.co>)
    end

    test "threading, subject and body come through exactly as compose/4 builds them" do
      thread =
        threading(%{
          in_reply_to: "<CADorig@mail.example.com>",
          references: ["<thread-root@example.com>", "<CADorig@mail.example.com>"]
        })

      assert {:ok, %{wire: wire}} =
               DraftMime.compose_send(validated(), thread, @send_id, "mara@example.com", nil)

      unfolded = unfold(wire)
      assert unfolded =~ "To: Priya Nair <priya@example.com>"
      assert unfolded =~ "Subject: Re: Inquiry"
      assert unfolded =~ "In-Reply-To: <CADorig@mail.example.com>"
      assert unfolded =~ "References: <thread-root@example.com> <CADorig@mail.example.com>"
      assert wire =~ "Message-ID: #{@send_id}"
      assert wire =~ "Content-Transfer-Encoding: quoted-printable"

      {"text", "plain", _headers, _params, body} =
        :mimemail.decode(wire, encoding: :none, allow_missing_version: true)

      assert body == "Hello Priya,\n\nThanks for reaching out — happy to help! Grüße.\n"
    end
  end

  describe "attachments" do
    defp attachment(filename, content), do: %{filename: filename, content: content}

    # `:mimemail.decode/2` is the round-trip authority here: an assertion on
    # the bytes we happen to emit would pass for a message no client can read.
    defp decode(rfc822),
      do: :mimemail.decode(rfc822, encoding: :none, allow_missing_version: true)

    test "no attachments composes the same single text/plain entity as before" do
      assert {:ok, rfc822} =
               DraftMime.compose(validated(), threading(), @message_id, "m@x.co", [])

      assert {:ok, same} = DraftMime.compose(validated(), threading(), @message_id, "m@x.co")
      refute rfc822 =~ "multipart/mixed"
      assert {"text", "plain", _headers, _params, _body} = decode(rfc822)
      # ...and the 4-arity call is the same message, so an attachment-less
      # draft is untouched end to end.
      assert header_line(rfc822, "Content-Type") == header_line(same, "Content-Type")
    end

    test "attachments make it multipart/mixed: body part first, one part per file" do
      attachments = [
        attachment("deck.pdf", "%PDF-1.7 fake"),
        attachment("notes.txt", "plain notes\n")
      ]

      assert {:ok, rfc822} =
               DraftMime.compose(validated(), threading(), @message_id, "m@x.co", attachments)

      assert unfold(rfc822) =~ "Content-Type: multipart/mixed"
      assert unfold(rfc822) =~ "To: Priya Nair <priya@example.com>"

      assert {"multipart", "mixed", _headers, _params, parts} = decode(rfc822)
      assert [body_part, pdf_part, txt_part] = parts

      assert {"text", "plain", _, _, body} = body_part
      assert body == "Hello Priya,\n\nThanks for reaching out — happy to help! Grüße.\n"

      assert {"application", "pdf", _, pdf_params, "%PDF-1.7 fake"} = pdf_part
      assert pdf_params[:disposition] == "attachment"
      assert pdf_params[:disposition_params] == [{"filename", "deck.pdf"}]

      assert {"text", "plain", _, txt_params, "plain notes\n"} = txt_part
      assert txt_params[:disposition] == "attachment"
      assert txt_params[:disposition_params] == [{"filename", "notes.txt"}]
    end

    test "binary content survives the base64 round trip byte for byte" do
      bytes = :crypto.strong_rand_bytes(2048)

      assert {:ok, rfc822} =
               DraftMime.compose(validated(), threading(), @message_id, "m@x.co", [
                 attachment("blob.bin", bytes)
               ])

      assert rfc822 =~ "Content-Transfer-Encoding: base64"
      assert {"multipart", "mixed", _, _, [_body, part]} = decode(rfc822)
      assert {"application", "octet-stream", _, _, ^bytes} = part
    end

    # `mimemail` emits a non-ASCII filename as RFC 2231 `filename*`
    # (`UTF-8''`-prefixed, percent-encoded) rather than as raw bytes — which
    # is the interoperable form, and the reason nothing here has to sanitize
    # the name itself. Asserted through the decode so the claim is about what
    # a receiving client parses, then percent-decoded back to prove the name
    # survived.
    test "a non-ASCII filename rides RFC 2231 and decodes back to itself" do
      assert {:ok, rfc822} =
               DraftMime.compose(validated(), threading(), @message_id, "m@x.co", [
                 attachment("Grüße.txt", "hi")
               ])

      assert {"multipart", "mixed", _, _, [_body, part]} = decode(rfc822)
      assert {"text", "plain", _, params, "hi"} = part
      assert [{"filename*", "UTF-8''" <> encoded}] = params[:disposition_params]
      assert URI.decode(encoded) == "Grüße.txt"
    end

    # The boundary is derived from the Message-ID, so two encodings of one
    # message agree — which is what keeps `compose_send/6`'s wire and record
    # byte-identical when there is no Bcc to drop.
    test "compose_send: wire == record with attachments and no bcc" do
      attachments = [attachment("deck.pdf", "%PDF-1.7 fake")]

      assert {:ok, %{wire: wire, record: record}} =
               DraftMime.compose_send(
                 validated(),
                 threading(),
                 @send_id,
                 "mara@example.com",
                 nil,
                 attachments
               )

      assert wire == record
      assert unfold(wire) =~ "Content-Type: multipart/mixed"
    end

    test "compose_send: the bcc variants differ only by the Bcc header, attachments and all" do
      v = validated(%{bcc: [%{name: nil, email: "hidden@example.com"}]})
      attachments = [attachment("deck.pdf", "%PDF-1.7 fake")]

      assert {:ok, %{wire: wire, record: record}} =
               DraftMime.compose_send(
                 v,
                 threading(),
                 @send_id,
                 "mara@example.com",
                 nil,
                 attachments
               )

      refute unfold(wire) =~ "Bcc:"
      assert unfold(record) =~ "Bcc: hidden@example.com"
      assert header_line(wire, "Content-Type") == header_line(record, "Content-Type")

      assert {"multipart", "mixed", _, _, [_body, {_, _, _, _, content}]} = decode(wire)
      assert content == "%PDF-1.7 fake"
    end

    test "composition is deterministic for the same inputs" do
      attachments = [attachment("deck.pdf", "%PDF-1.7 fake")]

      assert {:ok, first} =
               DraftMime.compose(validated(), threading(), @message_id, "m@x.co", attachments)

      assert {:ok, second} =
               DraftMime.compose(validated(), threading(), @message_id, "m@x.co", attachments)

      # Only the Date header is clock-derived; strip it and the rest — the
      # boundary included — must match exactly.
      assert without_date(first) == without_date(second)
    end

    test "different messages get different boundaries" do
      attachments = [attachment("deck.pdf", "x")]

      assert {:ok, a} =
               DraftMime.compose(validated(), threading(), @message_id, "m@x.co", attachments)

      assert {:ok, b} =
               DraftMime.compose(validated(), threading(), @send_id, "m@x.co", attachments)

      refute header_line(a, "Content-Type") == header_line(b, "Content-Type")
    end
  end

  describe "content_type/1" do
    test "maps known extensions, case-insensitively" do
      assert DraftMime.content_type("deck.pdf") == {"application", "pdf"}
      assert DraftMime.content_type("DECK.PDF") == {"application", "pdf"}
      assert DraftMime.content_type("shot.JPEG") == {"image", "jpeg"}
      assert DraftMime.content_type("notes.md") == {"text", "markdown"}
    end

    test "falls back to application/octet-stream for anything else" do
      for name <- ["thing.xyz", "Makefile", "archive.tar.zst", ".gitignore", "trailing."] do
        assert DraftMime.content_type(name) == {"application", "octet-stream"}
      end
    end

    # SVG is a script-bearing document; typing it as an image invites a
    # receiving client to render it as one.
    test "svg is deliberately not in the map" do
      assert DraftMime.content_type("logo.svg") == {"application", "octet-stream"}
    end
  end

  describe "check_caps/1" do
    test "accepts an empty list and anything under both caps" do
      assert DraftMime.check_caps([]) == :ok
      assert DraftMime.check_caps([1, 2, 3]) == :ok
      assert DraftMime.check_caps([DraftMime.max_attachment_bytes()]) == :ok
    end

    test "refuses one file over the per-file cap" do
      assert DraftMime.check_caps([DraftMime.max_attachment_bytes() + 1]) ==
               {:error, "attachments_too_large"}
    end

    test "refuses a set over the total cap even when every file fits" do
      per_file = DraftMime.max_attachment_bytes()
      count = div(DraftMime.max_total_attachment_bytes(), per_file) + 1

      assert DraftMime.check_caps(List.duplicate(per_file, count)) ==
               {:error, "attachments_too_large"}
    end

    test "accepts a set exactly on the total cap" do
      total = DraftMime.max_total_attachment_bytes()
      half_a_file = div(DraftMime.max_attachment_bytes(), 2)
      sizes = List.duplicate(half_a_file, div(total, half_a_file))

      assert Enum.sum(sizes) == total
      assert DraftMime.check_caps(sizes) == :ok
    end
  end

  defp without_date(rfc822),
    do: rfc822 |> String.split("\r\n") |> Enum.reject(&String.starts_with?(&1, "Date:"))

  defp header_line(rfc822, name) do
    rfc822
    |> unfold()
    |> String.split("\r\n")
    |> Enum.find(&String.starts_with?(&1, name <> ":"))
  end
end
