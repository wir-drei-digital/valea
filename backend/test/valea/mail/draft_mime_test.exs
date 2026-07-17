defmodule Valea.Mail.DraftMimeTest do
  use ExUnit.Case, async: true

  alias Valea.Mail.DraftMime

  @message_id "<valea.push.0123456789abcdef@valea.invalid>"

  defp validated(overrides \\ %{}) do
    base = %{
      to: [%{name: "Priya Nair", email: "priya@example.com"}],
      cc: [],
      bcc: [],
      subject: "Re: Inquiry",
      in_reply_to: nil,
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
end
