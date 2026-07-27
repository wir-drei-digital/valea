defmodule Valea.Mail.DraftMime do
  @moduledoc """
  Composes the RFC822 bytes appended to the user's Drafts folder when the
  USER pushes a reviewed draft (mail-as-maildir design spec E, §Drafting &
  push). Resurrected from the pre-Spec-D queue composer (git `f668811^`) and
  reworked for the maildir push flow: it no longer parses a draft file
  line-wise, it composes from the **already-parsed and validated** fields
  (`Valea.Mail.DraftFile.parse_and_validate/1`) — so header injection is
  structurally impossible, the outbound headers are a pure function of
  vetted values, never of raw frontmatter text.

  Spec G adds the SEND side on the same foundation: `compose_send/5` builds
  ONE header list and serializes it twice — the *wire* message the SMTP
  server receives (no `Bcc` header) and the *record* message filed in the
  user's Sent folder (with it) — plus the SMTP envelope that actually
  carries the blind recipients. Same principle as above, one level further:
  the two variants and the envelope are all pure functions of vetted values,
  and the `From` identity comes from settings, never from the draft.

  ## Deterministic Message-IDs

  `push_message_id/3` is a pure function of `(account, draft_name,
  content_hash)`: `<valea.push.<16 hex>@valea.invalid>`. That stability is
  what makes the whole push idempotent — the ops executor issues
  `UID SEARCH HEADER Message-ID <valea.push.…>` before appending, so a
  retried append (after a lost response) finds the existing draft instead of
  landing a duplicate. `@valea.invalid` uses the reserved `.invalid` TLD
  (RFC 6761) so the synthetic id can never collide with a real host's.

  `send_message_id/3` is its domain-separated sibling, over the draft's
  CANONICAL bytes rather than its raw ones — see it and
  `Valea.Mail.DraftFile.canonical_send_bytes/1` for why the send identity
  must survive the engine's own status stamps.

  ## Body & headers

  Body is the validated draft body, encoded as `text/plain; charset=utf-8`
  with quoted-printable transfer-encoding via `:mimemail.encode/1`
  (gen_smtp). `To`/`Cc`/`Bcc` are serialized from the parsed addr structs;
  `mimemail` re-parses those address headers and RFC 2047-encodes any
  non-ASCII display name, and `:mimemail.encode/1` likewise RFC 2047-encodes
  a non-ASCII `Subject` — so the bytes on the wire stay 7-bit clean.
  `In-Reply-To`/`References` come from the `threading` map the push flow
  resolved off the referenced message's raw canonical file. `mimemail`
  hard-requires a `From`; a draft in the user's own Drafts folder is
  authored *by* that account, so `from` is the account address, with a
  never-block synthetic fallback.
  """

  alias Valea.Mail.DraftFile

  # Never-block fallback: an unconfigured/blank `from` must not make a
  # reviewed draft un-composable. `.invalid` (RFC 6761) can never be a real
  # host, so it is a safe, obviously-synthetic sender of last resort.
  @from_fallback "valea@valea.invalid"

  @type threading :: %{in_reply_to: String.t() | nil, references: [String.t()]}

  @doc """
  Composes the RFC822 draft from `validated` (the map
  `Valea.Mail.DraftFile.parse_and_validate/1` returns), `threading` (the
  resolved `In-Reply-To`/`References`), the deterministic `message_id`, and
  the account `from` address. Always `{:ok, binary}` — every input is
  already vetted, so composition is total.
  """
  @spec compose(DraftFile.validated(), threading(), String.t(), String.t() | nil) ::
          {:ok, binary()}
  def compose(validated, threading, message_id, from)
      when is_map(validated) and is_map(threading) and is_binary(message_id) do
    headers =
      [
        {"From", from_address(from)},
        {"To", address_list(validated.to)},
        header("Cc", address_list(validated.cc)),
        header("Bcc", address_list(validated.bcc)),
        {"Subject", validated.subject},
        header("In-Reply-To", threading[:in_reply_to]),
        header("References", references(threading[:references])),
        {"Message-ID", message_id},
        {"Date", rfc2822_now()},
        {"MIME-Version", "1.0"}
      ]
      |> Enum.reject(&is_nil/1)

    {:ok, encode(headers, validated.body)}
  end

  @doc """
  Composes the send's TWO byte-variants plus the SMTP envelope, from ONE
  header list built once (spec G, §Send pipeline).

    * `record` — the user's own Sent copy, WITH the `Bcc` header when the
      draft has bcc recipients.
    * `wire` — what actually goes to the server: the same message with the
      `Bcc` header removed, so a blind recipient stays blind. With no bcc
      recipients the two are byte-identical.
    * `envelope` — `from` (the config-owned identity, bare addr-spec) and
      `rcpt`, the deduped `to ++ cc ++ bcc` addresses. Bcc recipients are
      delivered here and ONLY here; that is the whole reason the two
      variants exist.

  Built as one list — one `Date`, one `Message-ID` — because a Sent copy
  that disagreed with the transmitted message about either would no longer
  be a record of the same mail. `from_name`, when given, becomes the `From`
  display name through the same path a `To` display name takes, so
  `mimemail` RFC 2047-encodes it. Always `{:ok, _}`: every input is already
  vetted, so composition is total.
  """
  @spec compose_send(
          DraftFile.validated(),
          threading(),
          String.t(),
          String.t(),
          String.t() | nil
        ) ::
          {:ok,
           %{wire: binary(), record: binary(), envelope: Valea.Mail.SmtpTransport.envelope()}}
  def compose_send(validated, threading, message_id, from, from_name \\ nil)
      when is_map(validated) and is_map(threading) and is_binary(message_id) do
    from_addr = from_address(from)

    headers =
      [
        {"From", from_mailbox(from_addr, from_name)},
        {"To", address_list(validated.to)},
        header("Cc", address_list(validated.cc)),
        header("Bcc", address_list(validated.bcc)),
        {"Subject", validated.subject},
        header("In-Reply-To", threading[:in_reply_to]),
        header("References", references(threading[:references])),
        {"Message-ID", message_id},
        {"Date", rfc2822_now()},
        {"MIME-Version", "1.0"}
      ]
      |> Enum.reject(&is_nil/1)

    wire_headers = Enum.reject(headers, fn {name, _value} -> name == "Bcc" end)

    {:ok,
     %{
       wire: encode(wire_headers, validated.body),
       record: encode(headers, validated.body),
       envelope: %{from: from_addr, rcpt: rcpt(validated)}
     }}
  end

  @doc "The deterministic push Message-ID for `(account, draft_name, content_hash)` (see moduledoc)."
  @spec push_message_id(String.t(), String.t(), String.t()) :: String.t()
  def push_message_id(account, draft_name, content_hash)
      when is_binary(account) and is_binary(draft_name) and is_binary(content_hash) do
    "<valea.push.#{message_digest("#{account}/#{draft_name}/#{content_hash}")}@valea.invalid>"
  end

  @doc """
  The deterministic send Message-ID for `(account, draft_name,
  canonical_hash)` — `canonical_hash` being the SHA-256 of
  `Valea.Mail.DraftFile.canonical_send_bytes/1`, NOT the raw content hash
  (see that function: an engine status stamp must not move a send's
  identity).

  Domain-separated from `push_message_id/3` by a `send/` prefix inside the
  digest AND a distinct `valea.send.` label, so a pushed draft and a sent
  message of byte-identical content can never share a Message-ID — the
  send's idempotent Sent-copy search would otherwise find the pushed draft
  and conclude the mail was already filed.
  """
  @spec send_message_id(String.t(), String.t(), String.t()) :: String.t()
  def send_message_id(account, draft_name, canonical_hash)
      when is_binary(account) and is_binary(draft_name) and is_binary(canonical_hash) do
    "<valea.send.#{message_digest("send/#{account}/#{draft_name}/#{canonical_hash}")}@valea.invalid>"
  end

  defp message_digest(input) do
    :crypto.hash(:sha256, input)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  # -- encoding ----------------------------------------------------------------

  # The ONE serialization both `compose/4` and `compose_send/5` go through:
  # `text/plain; charset=utf-8`, quoted-printable, inline. Deterministic for
  # a given header list and body — which is what lets `compose_send/5`'s two
  # variants be byte-identical when there is no Bcc to drop.
  defp encode(headers, body) do
    params = %{
      content_type_params: [{"charset", "utf-8"}],
      disposition: "inline",
      transfer_encoding: "quoted-printable"
    }

    :mimemail.encode({"text", "plain", headers, params, body})
  end

  # -- envelope ------------------------------------------------------------------

  # `to ++ cc ++ bcc` as bare addresses, deduped, order-preserving: one RCPT
  # TO per distinct recipient, in the order the human wrote them. A duplicate
  # would draw a second (possibly refused) RCPT for an address already
  # accepted, and under the all-or-nothing rule that could sink a valid send.
  defp rcpt(validated) do
    (validated.to ++ validated.cc ++ validated.bcc)
    |> Enum.map(& &1.email)
    |> Enum.uniq()
  end

  # -- headers ----------------------------------------------------------------

  # The From mailbox: bare addr-spec, or `Display Name <addr>` built by the
  # SAME formatter the To/Cc lists use, so `mimemail` quotes specials and RFC
  # 2047-encodes a non-ASCII name identically wherever a name appears.
  defp from_mailbox(from_addr, nil), do: from_addr
  defp from_mailbox(from_addr, ""), do: from_addr

  defp from_mailbox(from_addr, from_name) when is_binary(from_name),
    do: format_address(%{name: from_name, email: from_addr})

  defp from_address(from) when is_binary(from) do
    case String.trim(from) do
      "" -> @from_fallback
      trimmed -> trimmed
    end
  end

  defp from_address(_from), do: @from_fallback

  # `[]` → nil (the header is dropped by `header/2`); otherwise the parsed
  # addrs formatted and comma-joined. `mimemail` re-parses and RFC 2047-
  # encodes the display names from here.
  defp address_list([]), do: nil
  defp address_list(addrs) when is_list(addrs), do: Enum.map_join(addrs, ", ", &format_address/1)

  defp format_address(%{name: name, email: email}) do
    case name do
      nil -> email
      "" -> email
      trimmed -> "#{quote_phrase(trimmed)} <#{email}>"
    end
  end

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

  # References is the threading chain (already `<...>`-formatted Message-IDs),
  # blanks dropped, space-joined; `nil`/`[]` drops the header.
  defp references(nil), do: nil

  defp references(refs) when is_list(refs) do
    case Enum.reject(refs, &blank?/1) do
      [] -> nil
      list -> Enum.join(list, " ")
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
