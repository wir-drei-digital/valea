defmodule Valea.Mail.DraftMime do
  @moduledoc """
  Composes the RFC822 bytes appended to the user's Drafts folder when an
  approved `email_draft` proposal closes its loop into the mailbox
  (`Valea.Mail.MailboxOps`, mail design spec §Post-approval mailbox ops).

  The reply is threaded onto the message it answers: `To`, `In-Reply-To`, and
  `References` all come from the SOURCE message's frontmatter (as parsed by
  `Valea.Mail.MessageFile.parse/1`), not the draft — a reply goes back to the
  sender and joins their thread. `Subject` and the body come from the draft
  file the human approved.

  ## Deterministic Message-ID

  The draft carries `Message-ID: <valea.draft.<run_id>@valea.invalid>`. It is
  a pure function of `run_id`, which is what makes the whole mailbox pass
  idempotent: `MailboxOps` issues `UID SEARCH HEADER Message-ID
  <valea.draft.…>` before appending, so a retried append (after a crash, or a
  UIDPLUS move that already copied) finds the existing draft instead of
  landing a duplicate. `@valea.invalid` uses the reserved `.invalid` TLD
  (RFC 6761) so the synthetic id can never collide with a real host's.

  ## Body & headers

  Body is the draft markdown below its frontmatter, encoded as
  `text/plain; charset=utf-8` with quoted-printable transfer-encoding via
  `:mimemail.encode/1` (gen_smtp). The `From` header is the mailbox account
  the draft is appended into (`settings.account`, threaded in by
  `Valea.Mail.MailboxOps` as the 4th argument): `:mimemail.encode/1`
  hard-requires a `From`, and a draft in the user's own Drafts folder is
  authored *by* that account. The draft frontmatter is parsed line-wise (not
  as YAML) because its `subject:` value is written unquoted by the queue and
  legitimately contains colons (`Re: …`), which a YAML mapping-parse rejects.
  """

  # Never-block fallback: an unconfigured/blank account must not make an
  # approved draft un-appendable. `.invalid` (RFC 6761) can never be a real
  # host, so it is a safe, obviously-synthetic sender of last resort.
  @from_fallback "valea@valea.invalid"

  @doc """
  Composes the RFC822 draft. `source_frontmatter` is the string-keyed map
  `Valea.Mail.MessageFile.parse/1` returns for the source message (keys
  `"message_id"`, `"references"`, `"reply_to"`, `"from"`); `draft_md` is the
  full draft file bytes (frontmatter + body); `from` is the account address
  written as the `From` header. Always `{:ok, binary}` — every input is
  rendered defensively.
  """
  @spec compose(binary(), map(), String.t(), String.t() | nil) :: {:ok, binary()}
  def compose(draft_md, source_frontmatter, run_id, from \\ nil)
      when is_binary(draft_md) and is_map(source_frontmatter) and is_binary(run_id) do
    {subject, body} = parse_draft(draft_md)

    headers =
      [
        {"From", from_address(from)},
        header("To", to_address(source_frontmatter)),
        {"Subject", subject},
        header("In-Reply-To", source_frontmatter["message_id"]),
        header("References", references(source_frontmatter)),
        {"Message-ID", message_id(run_id)},
        {"Date", rfc2822_now()},
        {"MIME-Version", "1.0"}
      ]
      |> Enum.reject(&is_nil/1)

    params = %{
      content_type_params: [{"charset", "utf-8"}],
      disposition: "inline",
      transfer_encoding: "quoted-printable"
    }

    {:ok, :mimemail.encode({"text", "plain", headers, params, body})}
  end

  @doc "The deterministic draft Message-ID for `run_id` (see moduledoc)."
  @spec message_id(String.t()) :: String.t()
  def message_id(run_id), do: "<valea.draft.#{run_id}@valea.invalid>"

  # -- draft parsing ----------------------------------------------------------

  # Line-wise, not YAML: `subject:` is written unquoted and carries colons.
  defp parse_draft(draft_md) do
    case split_frontmatter(draft_md) do
      {:ok, block, body} -> {subject_from(block), strip_leading_blank(body)}
      :error -> {"", strip_leading_blank(draft_md)}
    end
  end

  defp split_frontmatter("---\n" <> rest) do
    case String.split(rest, "\n---\n", parts: 2) do
      [block, body] -> {:ok, block, body}
      _ -> :error
    end
  end

  defp split_frontmatter(_other), do: :error

  defp subject_from(block) do
    block
    |> String.split("\n")
    |> Enum.find_value("", fn line ->
      case String.split(line, ":", parts: 2) do
        [key, value] -> if String.trim(key) == "subject", do: String.trim(value)
        _ -> nil
      end
    end)
  end

  # The queue writes `---\n\n<body>`, so the split leaves exactly one leading
  # newline (the separator blank line) — drop it so the email body starts on
  # the author's first line.
  defp strip_leading_blank(body), do: String.replace_prefix(body, "\n", "")

  # -- headers ----------------------------------------------------------------

  defp from_address(from) when is_binary(from) do
    case String.trim(from) do
      "" -> @from_fallback
      trimmed -> trimmed
    end
  end

  defp from_address(_from), do: @from_fallback

  defp to_address(fm) do
    case fm["reply_to"] || fm["from"] do
      %{"email" => email} = addr when is_binary(email) ->
        format_address(String.trim(email), addr["name"])

      _ ->
        nil
    end
  end

  defp format_address("", _name), do: nil

  defp format_address(email, name) when is_binary(name) do
    case String.trim(name) do
      "" -> email
      trimmed -> "#{quote_phrase(trimmed)} <#{email}>"
    end
  end

  defp format_address(email, _name), do: email

  # RFC 5322 display-name: quote (and backslash-escape) when it contains any
  # "specials", otherwise emit it bare.
  @specials ~r/[()<>\[\]:;@\\,."]/

  defp quote_phrase(name) do
    if Regex.match?(@specials, name) do
      escaped = name |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
      "\"#{escaped}\""
    else
      name
    end
  end

  # source references ++ [source message_id], nils/blanks dropped, space-joined
  defp references(fm) do
    (List.wrap(fm["references"]) ++ [fm["message_id"]])
    |> Enum.reject(&blank?/1)
    |> case do
      [] -> nil
      refs -> Enum.join(refs, " ")
    end
  end

  defp header(_name, nil), do: nil
  defp header(_name, ""), do: nil
  defp header(name, value), do: {name, value}

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp rfc2822_now do
    Calendar.strftime(DateTime.utc_now(), "%a, %d %b %Y %H:%M:%S +0000")
  end
end
