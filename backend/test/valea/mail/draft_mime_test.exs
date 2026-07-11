defmodule Valea.Mail.DraftMimeTest do
  use ExUnit.Case, async: true

  alias Valea.Mail.DraftMime

  @run_id "20260710T120000Z-priya01"

  # A `threaded_reply`-style source: the inbound message this draft answers.
  # `reply_to` is present *and different from* `from`, so the golden To must
  # prove reply_to wins the precedence.
  defp source_frontmatter do
    %{
      "id" => "2026-07-09-priya-nair-abcd1234",
      "message_id" => "<CADorig@mail.example.com>",
      "references" => ["<thread-root@example.com>", "<prev@example.com>"],
      "reply_to" => %{"name" => "Priya Nair", "email" => "priya@example.com"},
      "from" => %{"name" => "No Reply", "email" => "noreply@example.com"},
      "uid" => 42,
      "source" => "imap"
    }
  end

  defp draft_md do
    Enum.join(
      [
        "---",
        "to: priya@example.com",
        "subject: Re: Inquiry",
        "run_id: #{@run_id}",
        "workflow: icm/Workflows/New Inquiry Triage.md",
        "sources:",
        "  - icm/Clients/Priya Nair.md",
        "---",
        "",
        "Hello Priya,\n\nThanks for reaching out — happy to help! Grüße.\n"
      ],
      "\n"
    )
  end

  # mimemail folds header lines > 78 chars onto `\r\n\t` continuations; unfold
  # so a single-string assertion sees the logical header value.
  defp unfold(rfc822), do: String.replace(rfc822, ~r/\r\n[ \t]+/, " ")

  test "compose/4 builds the reply headers, deterministic Message-ID, and a QP text/plain body" do
    assert {:ok, rfc822} =
             DraftMime.compose(draft_md(), source_frontmatter(), @run_id, "mara@example.com")

    unfolded = unfold(rfc822)

    # From = the account the draft is authored by
    assert unfolded =~ "From: mara@example.com"
    # To = source reply_to (wins over from), name-addr form
    assert unfolded =~ "To: Priya Nair <priya@example.com>"
    # Subject from the draft frontmatter (colon-bearing, preserved verbatim)
    assert unfolded =~ "Subject: Re: Inquiry"
    # In-Reply-To = source message_id
    assert unfolded =~ "In-Reply-To: <CADorig@mail.example.com>"
    # References = source references ++ [source message_id]
    assert unfolded =~
             "References: <thread-root@example.com> <prev@example.com> <CADorig@mail.example.com>"

    # Deterministic Message-ID keyed on run_id
    assert rfc822 =~ "Message-ID: <valea.draft.#{@run_id}@valea.invalid>"

    # A Date header is present
    assert unfolded =~ ~r/\r\nDate: \w{3}, \d{2} \w{3} \d{4} \d{2}:\d{2}:\d{2} \+0000/

    # text/plain, utf-8, quoted-printable
    assert rfc822 =~ "Content-Type: text/plain"
    assert unfolded =~ "charset=utf-8"
    assert rfc822 =~ "Content-Transfer-Encoding: quoted-printable"

    # mimemail round-trips: the body decodes back to the draft body verbatim.
    {"text", "plain", _headers, _params, body} =
      :mimemail.decode(rfc822, encoding: :none, allow_missing_version: true)

    assert body == "Hello Priya,\n\nThanks for reaching out — happy to help! Grüße.\n"
  end

  test "compose/4 falls back to the source `from` address when there is no reply_to" do
    fm = source_frontmatter() |> Map.delete("reply_to")

    assert {:ok, rfc822} = DraftMime.compose(draft_md(), fm, @run_id, "mara@example.com")
    assert unfold(rfc822) =~ "To: No Reply <noreply@example.com>"
  end

  test "compose/4 uses a bare address when the source address carries no display name" do
    fm = %{"from" => %{"name" => nil, "email" => "plain@example.com"}}

    assert {:ok, rfc822} = DraftMime.compose(draft_md(), fm, @run_id, "mara@example.com")
    assert unfold(rfc822) =~ "To: plain@example.com"
    refute unfold(rfc822) =~ "<plain@example.com>"
  end

  test "compose/4 omits In-Reply-To/References when the source has no message_id" do
    fm = %{"from" => %{"name" => "Sam", "email" => "sam@example.com"}}

    assert {:ok, rfc822} = DraftMime.compose(draft_md(), fm, @run_id, "mara@example.com")
    refute rfc822 =~ "In-Reply-To:"
    refute rfc822 =~ "References:"
  end

  test "compose/4 falls back to a synthetic From when no account is given (never-block)" do
    fm = %{"from" => %{"name" => "Sam", "email" => "sam@example.com"}}

    assert {:ok, rfc822} = DraftMime.compose(draft_md(), fm, @run_id, nil)
    assert unfold(rfc822) =~ "From: valea@valea.invalid"
  end

  test "compose/4 quotes a display name with RFC 5322 specials in the To header" do
    fm = %{"from" => %{"name" => "Nair, Priya (Sales)", "email" => "priya@example.com"}}

    assert {:ok, rfc822} = DraftMime.compose(draft_md(), fm, @run_id, "mara@example.com")
    assert unfold(rfc822) =~ ~s(To: "Nair, Priya \(Sales\)" <priya@example.com>)
  end

  test "compose/4 RFC-2047-encodes a non-ASCII display name in the To header" do
    fm = %{"from" => %{"name" => "Grüße Nair", "email" => "g@example.com"}}

    assert {:ok, rfc822} = DraftMime.compose(draft_md(), fm, @run_id, "mara@example.com")
    # mimemail re-parses address headers and emits non-ASCII names as
    # encoded-words — the raw bytes on the wire stay 7-bit clean.
    assert unfold(rfc822) =~ "To: =?UTF-8?Q?Gr=C3=BC=C3=9Fe_Nair?= <g@example.com>"
    refute unfold(rfc822) =~ "To: Grüße"
  end
end
