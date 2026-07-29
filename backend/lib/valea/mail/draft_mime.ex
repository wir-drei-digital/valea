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

  Spec G adds the SEND side on the same foundation: `compose_send/6` builds
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

  ## Attachments

  With no attachments a message is exactly what it always was — a single
  `text/plain` entity, byte for byte. With attachments it becomes
  `multipart/mixed`: the same `text/plain` body as the first part, then one
  `base64`, `Content-Disposition: attachment` part per file.

  Two rules live here rather than at any call site:

    * **Content-Type by extension, from a CLOSED map** (`content_type/1`).
      Nothing is sniffed from the bytes and nothing is taken from the file's
      own claims — an unknown extension is `application/octet-stream`, which
      is the honest answer and the one that cannot be talked into
      `text/html`.
    * **Caps** (`check_caps/1`): 10 MB per file, 25 MB in total. Enforced at
      REVIEW and at PUSH — i.e. before anything is claimed, spooled or
      transmitted — and refused with the single code `attachments_too_large`.

  The multipart boundary is DERIVED from the `Message-ID`
  (`boundary_for/1`), never generated randomly. `compose_send/6`'s promise
  that wire and record are byte-identical when there is no `Bcc` rests on
  the two encodings being the same function of the same inputs, and
  `mimemail`'s own boundary generator is random per call — two encodings of
  one message would disagree on every part separator.

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

  @max_attachment_bytes 10 * 1024 * 1024
  @max_total_attachment_bytes 25 * 1024 * 1024

  # The CLOSED extension → Content-Type map (see the moduledoc). Everything
  # not listed is `application/octet-stream`: a mail client that guesses a
  # type for an unrecognized file is a mail client that can be talked into
  # announcing `text/html` for something the sender never looked at.
  # `.svg` is deliberately ABSENT — SVG is a script-bearing document, and an
  # `image/svg+xml` label invites a receiving client to render it as one.
  @content_types %{
    ".pdf" => {"application", "pdf"},
    ".png" => {"image", "png"},
    ".jpg" => {"image", "jpeg"},
    ".jpeg" => {"image", "jpeg"},
    ".gif" => {"image", "gif"},
    ".webp" => {"image", "webp"},
    ".heic" => {"image", "heic"},
    ".txt" => {"text", "plain"},
    ".md" => {"text", "markdown"},
    ".csv" => {"text", "csv"},
    ".ics" => {"text", "calendar"},
    ".json" => {"application", "json"},
    ".yaml" => {"application", "yaml"},
    ".yml" => {"application", "yaml"},
    ".zip" => {"application", "zip"},
    ".doc" => {"application", "msword"},
    ".docx" => {"application", "vnd.openxmlformats-officedocument.wordprocessingml.document"},
    ".xls" => {"application", "vnd.ms-excel"},
    ".xlsx" => {"application", "vnd.openxmlformats-officedocument.spreadsheetml.sheet"},
    ".ppt" => {"application", "vnd.ms-powerpoint"},
    ".pptx" => {"application", "vnd.openxmlformats-officedocument.presentationml.presentation"},
    ".odt" => {"application", "vnd.oasis.opendocument.text"},
    ".ods" => {"application", "vnd.oasis.opendocument.spreadsheet"},
    ".odp" => {"application", "vnd.oasis.opendocument.presentation"},
    ".rtf" => {"application", "rtf"},
    ".mp3" => {"audio", "mpeg"},
    ".wav" => {"audio", "wav"},
    ".m4a" => {"audio", "mp4"},
    ".mp4" => {"video", "mp4"},
    ".mov" => {"video", "quicktime"}
  }

  @octet_stream {"application", "octet-stream"}

  @type threading :: %{in_reply_to: String.t() | nil, references: [String.t()]}

  @typedoc "One attachment, as composition needs it: the name the recipient sees and the bytes."
  @type attachment :: %{filename: String.t(), content: binary()}

  @doc """
  Composes the RFC822 draft from `validated` (the map
  `Valea.Mail.DraftFile.parse_and_validate/1` returns), `threading` (the
  resolved `In-Reply-To`/`References`), the deterministic `message_id`, the
  account `from` address, and the already-read `attachments` (the CALLER
  resolves and contains those paths — see `Valea.Mail.OpsExecutor`). Always
  `{:ok, binary}` — every input is already vetted, so composition is total.
  """
  @spec compose(
          DraftFile.validated(),
          threading(),
          String.t(),
          String.t() | nil,
          [attachment()]
        ) ::
          {:ok, binary()}
  def compose(validated, threading, message_id, from, attachments \\ [])
      when is_map(validated) and is_map(threading) and is_binary(message_id) and
             is_list(attachments) do
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

    {:ok, encode(headers, validated.body, attachments, message_id)}
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
          String.t() | nil,
          [attachment()]
        ) ::
          {:ok,
           %{wire: binary(), record: binary(), envelope: Valea.Mail.SmtpTransport.envelope()}}
  def compose_send(validated, threading, message_id, from, from_name \\ nil, attachments \\ [])
      when is_map(validated) and is_map(threading) and is_binary(message_id) and
             is_list(attachments) do
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
       wire: encode(wire_headers, validated.body, attachments, message_id),
       record: encode(headers, validated.body, attachments, message_id),
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

  # The ONE serialization both `compose/5` and `compose_send/6` go through.
  # Deterministic for a given header list, body and attachment list — which
  # is what lets `compose_send/6`'s two variants be byte-identical when there
  # is no Bcc to drop, attachments or not.
  #
  # No attachments: `text/plain; charset=utf-8`, quoted-printable, inline —
  # the exact single-entity message this composed before attachments existed,
  # unchanged byte for byte.
  defp encode(headers, body, [], _message_id) do
    :mimemail.encode({"text", "plain", headers, text_params(), body})
  end

  # Attachments: `multipart/mixed`, body first, then one part per file. The
  # boundary is derived from the Message-ID rather than generated, so this
  # stays a pure function of its inputs (see the moduledoc).
  defp encode(headers, body, attachments, message_id) do
    parts =
      [{"text", "plain", [], text_params(), body} | Enum.map(attachments, &attachment_part/1)]

    params = %{content_type_params: [{"boundary", boundary_for(message_id)}]}

    :mimemail.encode({"multipart", "mixed", headers, params, parts})
  end

  defp text_params do
    %{
      content_type_params: [{"charset", "utf-8"}],
      disposition: "inline",
      transfer_encoding: "quoted-printable"
    }
  end

  # `name` (Content-Type) and `filename` (Content-Disposition) both carry the
  # filename because receiving clients disagree about which one they honour;
  # `mimemail` RFC 2231-encodes either when it is not plain ASCII. base64 is
  # unconditional — an attachment is opaque bytes here, and quoted-printable
  # would corrupt anything that is not text.
  defp attachment_part(%{filename: filename, content: content}) do
    {type, subtype} = content_type(filename)

    params = %{
      content_type_params: [{"name", filename}],
      disposition: "attachment",
      disposition_params: [{"filename", filename}],
      transfer_encoding: "base64"
    }

    {type, subtype, [], params, content}
  end

  # A boundary can never appear inside the parts it separates, so it is built
  # from a digest rather than from anything the message carries: 16 hex
  # characters behind a fixed label, in the `----=_` shape conventional
  # enough that a broken client's boundary heuristics see what they expect.
  defp boundary_for(message_id), do: "----=_valea_" <> message_digest(message_id)

  @doc """
  The `{type, subtype}` for `filename`'s extension, from the closed map in
  this module (see the moduledoc) — `{"application", "octet-stream"}` for
  everything not listed, including a file with no extension at all. Case is
  folded, so `DECK.PDF` types the same as `deck.pdf`.
  """
  @spec content_type(String.t()) :: {String.t(), String.t()}
  def content_type(filename) when is_binary(filename) do
    ext = filename |> Path.extname() |> String.downcase()
    Map.get(@content_types, ext, @octet_stream)
  end

  @doc "The per-file attachment cap in bytes (10 MB)."
  @spec max_attachment_bytes() :: pos_integer()
  def max_attachment_bytes, do: @max_attachment_bytes

  @doc "The whole-draft attachment cap in bytes (25 MB)."
  @spec max_total_attachment_bytes() :: pos_integer()
  def max_total_attachment_bytes, do: @max_total_attachment_bytes

  @doc """
  Enforces both caps over a list of attachment SIZES in bytes:
  #{@max_attachment_bytes} per file and #{@max_total_attachment_bytes} in
  total. `{:error, "attachments_too_large"}` names neither which cap nor
  which file — the composer already shows every attachment's size next to
  the limits, and one code is one thing for a caller to map.

  Sizes, not contents, so the callers can refuse an oversized draft from a
  `stat` without ever reading the bytes into memory.
  """
  @spec check_caps([non_neg_integer()]) :: :ok | {:error, String.t()}
  def check_caps(sizes) when is_list(sizes) do
    if Enum.any?(sizes, &(&1 > @max_attachment_bytes)) or
         Enum.sum(sizes) > @max_total_attachment_bytes,
       do: {:error, "attachments_too_large"},
       else: :ok
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
