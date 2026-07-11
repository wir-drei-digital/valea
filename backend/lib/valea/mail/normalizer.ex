defmodule Valea.Mail.Message do
  @moduledoc """
  The normalized shape `Valea.Mail.Normalizer.normalize/1` produces from raw
  RFC822 bytes. Every field here is derived data — the raw bytes are
  discarded after normalization (see the mail design spec, §Normalized
  message file), so `message_id`/`in_reply_to`/`references`/`reply_to` exist
  precisely because a later task needs them to thread a reply without the
  original headers.
  """

  defstruct message_id: nil,
            from: %{name: nil, email: nil},
            to: [],
            subject: "",
            date: nil,
            in_reply_to: nil,
            references: [],
            reply_to: nil,
            body_text: "",
            attachments: [],
            notes: %{}

  @type address :: %{name: String.t() | nil, email: String.t() | nil}
  @type attachment :: %{filename: String.t(), content: binary()}
  @type t :: %__MODULE__{
          message_id: String.t() | nil,
          from: address(),
          to: [address()],
          subject: String.t(),
          date: DateTime.t() | nil,
          in_reply_to: String.t() | nil,
          references: [String.t()],
          reply_to: address() | nil,
          body_text: String.t(),
          attachments: [attachment()],
          notes: %{optional(atom()) => String.t()}
        }
end

defmodule Valea.Mail.Normalizer do
  @moduledoc """
  RFC822 bytes → `Valea.Mail.Message`. `:mimemail.decode/2` (gen_smtp) does
  the MIME structure parsing (multipart traversal, transfer-encoding
  decode); this module owns everything gen_smtp can't do without the
  `iconv` NIF — charset-to-UTF-8 conversion and RFC 2047 encoded-word
  decoding — plus body selection (text/plain over Floki-extracted
  text/html) and the best-effort fallback for malformed MIME.

  ## Why `encoding: :none`

  `iconv` is not (and is deliberately not) a project dependency — see the
  mail design spec, §Normalizer: "Charset handling without the iconv NIF".
  gen_smtp's `mimemail.erl` calls `iconv:convert/3` for *any* charset
  conversion — headers or body — whenever its `encoding` option resolves to
  anything other than the literal atom `:none` (its own default, from
  `:mimemail.decode/1`, is `"utf-8//IGNORE"`, not `:none`, despite the
  module's stale doc comment suggesting iconv is optional). Verified
  empirically: even a trivial single-part `text/plain; charset=utf-8`
  message raises `UndefinedFunctionError` (module `:iconv` not available)
  through `:mimemail.decode/1`. Passing `encoding: :none` short-circuits
  every `decode_body/4` and `decode_header/2` call before it reaches
  `iconv:convert/3` — CTE decode (base64/quoted-printable) still happens,
  headers are returned raw (RFC 2047 encoded-words undecoded). This module
  therefore always calls the 2-arity `decode/2` with `encoding: :none` and
  implements charset mapping (`Codepagex` for ISO-8859-1 / Windows-1252,
  `String.valid?/1` + scrub for UTF-8/US-ASCII) and RFC 2047 decoding
  itself, uniformly, for both the structured-decode path and the
  headers-only fallback path.

  ## The `encoding: :none` 7-bit filter, and the seven-bit-safe pre-pass

  `encoding: :none` has a second, nastier consequence: mimemail's
  `decode_body(Type, Body, _InEncoding, none)` clause strips every byte
  ≥ 0x80 from each leaf part's **wire** bytes *before* the
  transfer-encoding decode. Quoted-printable and base64 survive only
  because their wire form happens to be pure ASCII — a body or attachment
  sent with `Content-Transfer-Encoding: 8bit`/`binary` (or none at all)
  would silently lose every high byte, with no error and no note.

  The fix is `seven_bit_safe/1`: before handing bytes to
  `:mimemail.decode/2`, any leaf part whose wire bytes contain a byte
  ≥ 0x80 is transfer-decoded here (qp via mimemail's own exported
  decoder, raw CTEs verbatim) and re-encoded as base64, with the part's
  `Content-Transfer-Encoding` header rewritten to match. The message
  mimemail then sees is 7-bit clean end to end, so the filter has nothing
  to drop, and the decoded part bodies come back byte-identical to the
  original content — which the normal charset pipeline
  (`decode_charset_bytes/2`) then converts exactly like the QP path. The
  pre-pass is conservative: messages with no high bytes anywhere are
  returned untouched (byte-identical), any per-entity ambiguity (no
  parseable headers, multipart without boundary, dirty base64 wire) leaves
  that entity untouched, and any raise falls back to the original bytes —
  worst case is mimemail's old behavior, never something worse.
  """

  alias Valea.Mail.Message

  @mime_options [
    encoding: :none,
    decode_attachments: true,
    allow_missing_version: true,
    default_mime_version: "1.0"
  ]

  @block_tags ~w(p div br li tr h1 h2 h3 h4 h5 h6)
  @encoded_word ~r/=\?([^?]+)\?([bBqQ])\?([^?]*)\?=/

  @months %{
    "jan" => 1,
    "feb" => 2,
    "mar" => 3,
    "apr" => 4,
    "may" => 5,
    "jun" => 6,
    "jul" => 7,
    "aug" => 8,
    "sep" => 9,
    "oct" => 10,
    "nov" => 11,
    "dec" => 12
  }

  @date_re ~r/(\d{1,2})\s+([A-Za-z]{3})[A-Za-z]*\s+(\d{2,4})\s+(\d{1,2}):(\d{2})(?::(\d{2}))?\s+(?:\([^)]*\)\s*)?([+-]\d{4}|UTC?|GMT|Z)/i

  @doc """
  Normalizes raw RFC822 bytes into a `%Valea.Mail.Message{}`. Never returns
  an error: a `:mimemail.decode/2` raise (malformed MIME) falls back to
  headers extracted via `parse_headers/1` plus the raw text after the
  first blank line, with `notes.normalizer_note` set. The guarantee is
  structural, not incidental — `do_normalize/1` wraps the whole pipeline
  (including the fallback itself) in a rescue whose last resort is a
  minimal message built only from raise-proof operations.
  """
  @spec normalize(binary()) :: {:ok, Message.t()}
  def normalize(rfc822) when is_binary(rfc822) do
    {:ok, do_normalize(rfc822)}
  end

  defp do_normalize(rfc822) do
    case try_decode(rfc822) do
      {:ok, mime} -> build_from_mime(mime)
      {:error, reason} -> build_fallback(rfc822, reason)
    end
  rescue
    e -> minimal_fallback(rfc822, e)
  catch
    kind, reason -> minimal_fallback(rfc822, {kind, reason})
  end

  # Raise-proof by construction: scrub_utf8/1 and :binary.replace/4 accept
  # any binary, and describe_reason/1 bottoms out in inspect/1.
  defp minimal_fallback(rfc822, reason) do
    %Message{
      body_text: rfc822 |> normalize_newlines() |> scrub_utf8(),
      notes: %{
        normalizer_note:
          "normalization crashed (#{describe_reason(reason)}); raw bytes preserved as body"
      }
    }
  end

  @doc """
  Extracts `from`/`subject`/`date`/`message_id` from a headers-only block
  (no body). Used directly by callers that only have headers (e.g. a later
  IMAP header-fetch path) and internally by `normalize/1`'s fallback path.
  """
  @spec parse_headers(binary()) :: %{
          from: Message.address(),
          subject: String.t(),
          date: DateTime.t() | nil,
          message_id: String.t() | nil
        }
  def parse_headers(header_block) when is_binary(header_block) do
    {headers, _rest} = :mimemail.parse_headers(header_block)
    envelope = extract_envelope(headers)

    %{
      from: envelope.from,
      subject: envelope.subject,
      date: envelope.date,
      message_id: envelope.message_id
    }
  end

  # -- mimemail decode (never lets an mimemail raise escape) -----------------

  defp try_decode(rfc822) do
    {:ok, :mimemail.decode(seven_bit_safe(rfc822), @mime_options)}
  rescue
    e -> {:error, e}
  catch
    # mimemail uses erlang:error/1 for structural failures (e.g. no_boundary),
    # which `rescue` already catches as ErlangError — this `catch` is for the
    # rarer :throw/:exit paths in third-party MIME parsing code.
    kind, reason -> {:error, {kind, reason}}
  end

  # -- seven-bit-safe pre-pass (see moduledoc) --------------------------------
  #
  # Re-encodes every leaf part whose wire bytes contain a byte >= 0x80 as
  # base64 (rewriting its Content-Transfer-Encoding header), so mimemail's
  # encoding:none 7-bit filter never has anything to drop. Byte-identical
  # passthrough when the message is already 7-bit clean.

  # Elixir regexes without the `u` modifier run PCRE in 8-bit mode — these
  # match raw bytes, safe on arbitrary (non-UTF-8) binaries.
  @high_byte_re ~r/[\x80-\xFF]/
  @cte_header_re ~r/^content-transfer-encoding:[^\r\n]*(?:\r\n[ \t][^\r\n]*)*\r\n/im

  defp seven_bit_safe(raw) do
    if has_high_byte?(raw) do
      {bytes, _changed} = rewrite_entity(raw)
      bytes
    else
      raw
    end
  rescue
    _ -> raw
  catch
    _, _ -> raw
  end

  defp has_high_byte?(bin), do: Regex.match?(@high_byte_re, bin)

  # One MIME entity = header block + body. Returns {bytes, changed?};
  # changed? == false always returns the input bytes untouched.
  defp rewrite_entity(raw) do
    {parsed_headers, body} = :mimemail.parse_headers(raw)
    header_size = byte_size(raw) - byte_size(body)

    with true <- parsed_headers != [],
         # parse_headers may reconstruct `body` on odd inputs; only proceed
         # when it is literally the byte suffix of `raw`, so header bytes can
         # be carried over verbatim.
         true <- binary_part(raw, header_size, byte_size(body)) == body do
      header_bytes = binary_part(raw, 0, header_size)

      parsed_headers
      |> header_value("Content-Type")
      |> classify_content_type()
      |> rewrite_by_type(raw, header_bytes, parsed_headers, body)
    else
      _ -> {raw, false}
    end
  end

  defp classify_content_type(nil), do: :leaf

  defp classify_content_type(content_type) do
    [type | _] = String.split(content_type, ";", parts: 2)
    type = type |> String.trim() |> String.downcase()

    cond do
      String.starts_with?(type, "multipart/") -> classify_multipart(content_type)
      type == "message/rfc822" -> :rfc822
      true -> :leaf
    end
  end

  defp classify_multipart(content_type) do
    case Regex.run(~r/boundary\s*=\s*(?:"([^"]*)"|([^;\s]+))/i, content_type) do
      [_, boundary] when boundary != "" -> {:multipart, boundary}
      [_, "", boundary] when boundary != "" -> {:multipart, boundary}
      # No usable boundary: leave the entity alone; mimemail will raise
      # no_boundary and normalize/1's fallback path takes over, as before.
      _ -> :opaque
    end
  end

  defp rewrite_by_type({:multipart, boundary}, raw, header_bytes, _headers, body) do
    case rewrite_multipart_body(body, boundary) do
      {new_body, true} -> {header_bytes <> new_body, true}
      {_body, false} -> {raw, false}
    end
  end

  defp rewrite_by_type(:rfc822, raw, header_bytes, _headers, body) do
    case rewrite_entity(body) do
      {new_body, true} -> {header_bytes <> new_body, true}
      {_body, false} -> {raw, false}
    end
  end

  defp rewrite_by_type(:opaque, raw, _header_bytes, _headers, _body), do: {raw, false}

  defp rewrite_by_type(:leaf, raw, header_bytes, headers, body) do
    with true <- has_high_byte?(body),
         {:ok, decoded} <- transfer_decode_for_rewrite(leaf_cte(headers), body) do
      {rewrite_cte_to_base64(header_bytes) <> Base.encode64(decoded), true}
    else
      _ -> {raw, false}
    end
  end

  defp leaf_cte(headers) do
    case header_value(headers, "Content-Transfer-Encoding") do
      nil -> ""
      value -> value |> String.trim() |> String.downcase()
    end
  end

  defp transfer_decode_for_rewrite("quoted-printable", body),
    do: {:ok, :mimemail.decode_quoted_printable(body)}

  # base64 wire bytes should never contain a high byte; if they do, the wire
  # is malformed — leave it for mimemail rather than guess.
  defp transfer_decode_for_rewrite("base64", _body), do: :skip

  # 7bit / 8bit / binary / absent: the wire bytes ARE the content.
  defp transfer_decode_for_rewrite(_other, body), do: {:ok, body}

  # Replace (or add) the Content-Transfer-Encoding header inside a verbatim
  # header block (which normally ends with the blank separator line, i.e.
  # a "\r\n\r\n" suffix).
  defp rewrite_cte_to_base64(header_bytes) do
    stripped = Regex.replace(@cte_header_re, header_bytes, "")
    new_line = "Content-Transfer-Encoding: base64\r\n"

    cond do
      # Normal case: insert just before the blank separator line.
      String.ends_with?(stripped, "\r\n\r\n") ->
        String.replace_suffix(stripped, "\r\n", "") <> new_line <> "\r\n"

      # Every header line was a CTE header; only the blank separator remains.
      stripped == "\r\n" ->
        new_line <> "\r\n"

      # No blank separator line survived (degenerate block): append one.
      true ->
        stripped <> new_line <> "\r\n"
    end
  end

  # Splits a multipart body on its boundary delimiters, recursing into each
  # part entity. "\r\n" is prepended before splitting because the delimiter
  # is defined as CRLF + "--boundary" (RFC 2046) but the very first one may
  # sit at offset 0; the injected CRLF is trimmed back off the preamble on
  # reassembly. Only reassembles when a part actually changed.
  defp rewrite_multipart_body(body, boundary) do
    delimiter = "\r\n--" <> boundary
    [preamble | segments] = :binary.split("\r\n" <> body, delimiter, [:global])
    {rebuilt, changed} = rewrite_segments(segments, delimiter, [], false)

    if changed do
      {trim_injected_crlf(preamble) <> rebuilt, true}
    else
      {body, false}
    end
  end

  defp trim_injected_crlf("\r\n" <> rest), do: rest
  defp trim_injected_crlf(other), do: other

  defp rewrite_segments([], _delimiter, acc, changed) do
    {acc |> Enum.reverse() |> Enum.join(), changed}
  end

  defp rewrite_segments([segment | rest], delimiter, acc, changed) do
    if String.starts_with?(segment, "--") do
      # Terminator ("--boundary--"): everything from here on — including any
      # epilogue and stray delimiter-lookalikes inside it — stays verbatim.
      tail = Enum.join([segment | rest], delimiter)
      rewrite_segments([], delimiter, [delimiter <> tail | acc], changed)
    else
      {chunk, chunk_changed} = rewrite_segment(segment)
      rewrite_segments(rest, delimiter, [delimiter <> chunk | acc], changed or chunk_changed)
    end
  end

  # A part segment = the rest of the boundary line (usually empty, possibly
  # transport padding), then CRLF, then the part entity.
  defp rewrite_segment(segment) do
    case :binary.split(segment, "\r\n") do
      [boundary_line_rest, entity] ->
        {new_entity, changed} = rewrite_entity(entity)
        {boundary_line_rest <> "\r\n" <> new_entity, changed}

      [_no_crlf] ->
        {segment, false}
    end
  end

  defp build_from_mime({_type, _subtype, headers, _params, _body} = mime) do
    envelope = extract_envelope(headers)
    walked = walk_body(mime, %{plain: nil, html: nil, attachments: [], note: nil})

    %Message{
      message_id: envelope.message_id,
      from: envelope.from,
      to: envelope.to,
      subject: envelope.subject,
      date: envelope.date,
      in_reply_to: envelope.in_reply_to,
      references: envelope.references,
      reply_to: envelope.reply_to,
      body_text: body_text_from(walked),
      attachments: walked.attachments,
      notes: notes_map(charset_note: walked.note)
    }
  end

  defp build_fallback(rfc822, reason) do
    {header_block, body_raw} = split_message(rfc822)
    headers = parse_headers(header_block)
    {body_text, charset_note} = validate_or_scrub(normalize_newlines(body_raw))

    %Message{
      message_id: headers.message_id,
      from: headers.from,
      to: [],
      subject: headers.subject,
      date: headers.date,
      in_reply_to: nil,
      references: [],
      reply_to: nil,
      body_text: body_text,
      attachments: [],
      notes:
        notes_map(
          normalizer_note:
            "message failed structured MIME parsing (#{describe_reason(reason)}); headers and body recovered best-effort",
          charset_note: charset_note
        )
    }
  end

  defp describe_reason(%{__exception__: true} = exception), do: Exception.message(exception)
  defp describe_reason(reason), do: inspect(reason)

  defp split_message(raw) do
    case :binary.split(raw, "\r\n\r\n") do
      [headers, body] ->
        {headers <> "\r\n", body}

      [_only] ->
        case :binary.split(raw, "\n\n") do
          [headers, body] -> {headers <> "\n", body}
          [_only2] -> {raw, ""}
        end
    end
  end

  defp validate_or_scrub(bytes) do
    if String.valid?(bytes) do
      {bytes, nil}
    else
      {scrub_utf8(bytes),
       "body bytes were not valid UTF-8; invalid sequences replaced with U+FFFD"}
    end
  end

  defp notes_map(pairs), do: pairs |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()

  # -- envelope headers --------------------------------------------------

  defp extract_envelope(headers) do
    %{
      from: first_address(header_value(headers, "From")),
      to: parse_address_list(header_value(headers, "To")),
      subject: header_value(headers, "Subject") |> decode_encoded_words() |> presence() || "",
      date: header_value(headers, "Date") |> parse_date(),
      message_id: header_value(headers, "Message-ID") |> normalize_id(),
      in_reply_to: header_value(headers, "In-Reply-To") |> normalize_id(),
      references: header_value(headers, "References") |> parse_references(),
      reply_to: header_value(headers, "Reply-To") |> parse_address_list() |> List.first()
    }
  end

  defp header_value(headers, name) do
    case :mimemail.get_header_value(name, headers) do
      :undefined -> nil
      value -> value
    end
  end

  defp normalize_id(nil), do: nil
  defp normalize_id(s), do: s |> String.trim() |> presence()

  defp presence(nil), do: nil
  defp presence(s) when is_binary(s), do: if(String.trim(s) == "", do: nil, else: s)

  defp parse_references(nil), do: []
  defp parse_references(value), do: value |> String.split(~r/\s+/, trim: true)

  defp first_address(nil), do: %{name: nil, email: nil}

  defp first_address(value) do
    case parse_address_list(value) do
      [first | _] -> first
      [] -> %{name: nil, email: nil}
    end
  end

  defp parse_address_list(nil), do: []

  defp parse_address_list(value) do
    case :smtp_util.parse_rfc5322_addresses(value) do
      {:ok, list} -> Enum.map(list, &to_address/1)
      {:error, _reason} -> []
    end
  end

  defp to_address({:undefined, email}), do: %{name: nil, email: to_str(email)}

  defp to_address({name, email}) do
    %{name: name |> to_str() |> decode_encoded_words() |> presence(), email: to_str(email)}
  end

  defp to_str(charlist), do: List.to_string(charlist)

  # -- body selection (depth-first: first text/plain, else first text/html) --

  defp walk_body({"multipart", _sub, _headers, _params, parts}, acc) when is_list(parts) do
    Enum.reduce(parts, acc, &walk_body/2)
  end

  defp walk_body({"message", "rfc822", _headers, _params, inner}, acc) when is_tuple(inner) do
    walk_body(inner, acc)
  end

  defp walk_body({type, subtype, _headers, params, body}, acc) when is_binary(body) do
    case classify_part(type, subtype, params, acc) do
      :attachment -> %{acc | attachments: acc.attachments ++ [build_attachment(params, body)]}
      :plain -> capture_text(acc, :plain, body, params)
      :html -> capture_text(acc, :html, body, params)
      :skip -> acc
    end
  end

  defp walk_body(_other, acc), do: acc

  defp classify_part(type, subtype, params, acc) do
    cond do
      attachment?(params) -> :attachment
      type == "text" and subtype == "plain" and is_nil(acc.plain) -> :plain
      type == "text" and subtype == "html" and is_nil(acc.html) -> :html
      true -> :skip
    end
  end

  defp capture_text(acc, key, body, params) do
    {text, note} = decode_part(body, params)
    acc |> Map.put(key, text) |> Map.update!(:note, &(&1 || note))
  end

  defp body_text_from(%{plain: plain, html: html}) do
    cond do
      plain -> plain
      html -> html_to_text(html)
      true -> ""
    end
  end

  defp decode_part(body, params) do
    {text, note} = decode_charset_bytes(body, charset_of(params))
    {normalize_newlines(text), note}
  end

  defp html_to_text(html) do
    html
    |> Floki.parse_document!()
    |> Floki.filter_out("script")
    |> Floki.filter_out("style")
    |> Floki.traverse_and_update(&break_block/1)
    |> Floki.text()
    |> normalize_newlines()
    |> collapse_blank_lines()
  rescue
    _ -> ""
  end

  defp break_block({tag, attrs, children}) when tag in @block_tags,
    do: {tag, attrs, children ++ ["\n"]}

  defp break_block(other), do: other

  defp collapse_blank_lines(text), do: Regex.replace(~r/\n{3,}/, text, "\n\n")

  defp normalize_newlines(bin), do: :binary.replace(bin, "\r\n", "\n", [:global])

  # -- attachments ---------------------------------------------------------

  defp attachment?(params) do
    Map.get(params, :disposition) == "attachment" or
      has_param?(Map.get(params, :disposition_params), "filename") or
      has_param?(Map.get(params, :content_type_params), "name")
  end

  defp has_param?(nil, _key), do: false

  defp has_param?(list, key) when is_list(list) do
    Enum.any?(list, fn {k, _v} -> String.downcase(to_string(k)) == key end)
  end

  defp build_attachment(params, body) do
    filename =
      get_param(Map.get(params, :disposition_params), "filename") ||
        get_param(Map.get(params, :content_type_params), "name") ||
        "attachment"

    %{filename: decode_encoded_words(filename), content: body}
  end

  defp charset_of(params), do: get_param(Map.get(params, :content_type_params), "charset")

  defp get_param(nil, _key), do: nil

  defp get_param(list, key) do
    Enum.find_value(list, fn {k, v} -> if String.downcase(to_string(k)) == key, do: v end)
  end

  # -- charsets --------------------------------------------------------------

  defp decode_charset_bytes(bytes, charset) do
    case normalize_charset_label(charset) do
      c when c in ["", "utf-8", "utf8", "us-ascii", "ascii"] ->
        utf8_or_scrub(bytes, charset)

      c when c in ["iso-8859-1", "iso8859-1", "latin1", "latin-1"] ->
        try_codepagex(bytes, :iso_8859_1, charset)

      c when c in ["windows-1252", "cp1252", "x-cp1252"] ->
        try_codepagex(bytes, "VENDORS/MICSFT/WINDOWS/CP1252", charset)

      _other ->
        {scrub_utf8(bytes),
         "unrecognized charset #{inspect(charset)}; bytes replaced with UTF-8 fallback"}
    end
  end

  defp normalize_charset_label(nil), do: ""

  defp normalize_charset_label(charset),
    do: charset |> to_string() |> String.trim() |> String.downcase()

  defp utf8_or_scrub(bytes, charset) do
    if String.valid?(bytes) do
      {bytes, nil}
    else
      {scrub_utf8(bytes),
       "#{describe_charset(charset)} but bytes were not valid UTF-8; invalid sequences replaced"}
    end
  end

  defp describe_charset(nil), do: "no declared charset"
  defp describe_charset(charset), do: "declared charset #{inspect(charset)}"

  defp try_codepagex(bytes, encoding, charset) do
    {Codepagex.to_string!(bytes, encoding), nil}
  rescue
    _ -> {scrub_utf8(bytes), "failed to decode #{inspect(charset)} bytes; replaced with U+FFFD"}
  end

  @doc """
  Replaces every invalid UTF-8 sequence in `bin` with U+FFFD, returning a
  binary for which `String.valid?/1` holds. Raise-proof for any input.
  Public because `Valea.Mail.MessageFile` uses the same scrub to keep
  invalid bytes in header-derived struct fields from ever crashing a
  frontmatter render — one scrub semantic across the mail modules.
  """
  @spec scrub_utf8(binary()) :: String.t()
  def scrub_utf8(bin) do
    case :unicode.characters_to_binary(bin) do
      b when is_binary(b) ->
        b

      {:error, good, <<_bad, rest::binary>>} ->
        good <> <<0xFFFD::utf8>> <> scrub_utf8(rest)

      {:error, good, <<>>} ->
        good <> <<0xFFFD::utf8>>

      {:incomplete, good, _rest} ->
        good <> <<0xFFFD::utf8>>
    end
  end

  # -- RFC 2047 encoded-words --------------------------------------------

  defp decode_encoded_words(nil), do: nil

  defp decode_encoded_words(str) when is_binary(str) do
    str
    |> collapse_adjacent_encoded_words()
    |> then(
      &Regex.replace(@encoded_word, &1, fn _whole, charset, enc, data ->
        decode_one_word(charset, enc, data)
      end)
    )
  rescue
    _ -> str
  end

  # RFC 2047 §6.2: whitespace *between* two adjacent encoded-words is part of
  # the encoding, not the content, and must be discarded on decode.
  defp collapse_adjacent_encoded_words(str), do: Regex.replace(~r/\?=[ \t]+=\?/, str, "?==?")

  defp decode_one_word(charset, enc, data) do
    raw =
      case String.upcase(enc) do
        "B" -> safe_base64_decode(data)
        "Q" -> data |> String.replace("_", " ") |> :mimemail.decode_quoted_printable()
      end

    {text, _note} = decode_charset_bytes(raw, charset)
    text
  rescue
    _ -> "=?#{charset}?#{enc}?#{data}?="
  end

  defp safe_base64_decode(data) do
    case Base.decode64(data) do
      {:ok, bin} ->
        bin

      :error ->
        case Base.decode64(data, padding: false) do
          {:ok, bin} -> bin
          :error -> data
        end
    end
  end

  # -- dates (RFC 2822 §3.3, numeric-offset zones + UT/GMT/Z) ---------------

  defp parse_date(nil), do: nil

  defp parse_date(str) do
    case Regex.run(@date_re, String.trim(str)) do
      [_, day, mon, year, hour, minute, sec, tz] ->
        build_datetime(day, mon, year, hour, minute, sec, tz)

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp build_datetime(day, mon, year, hour, minute, sec, tz) do
    with {:ok, month} <- Map.fetch(@months, String.downcase(mon)),
         {d, ""} <- Integer.parse(day),
         {y, ""} <- Integer.parse(year),
         {h, ""} <- Integer.parse(hour),
         {mi, ""} <- Integer.parse(minute),
         {:ok, s} <- parse_seconds(sec),
         {:ok, offset} <- parse_offset(tz),
         {:ok, naive} <- NaiveDateTime.new(normalize_year(y), month, d, h, mi, s) do
      naive
      |> DateTime.from_naive!("Etc/UTC")
      |> DateTime.add(-offset, :second)
    else
      _ -> nil
    end
  end

  defp parse_seconds(""), do: {:ok, 0}

  defp parse_seconds(s) do
    case Integer.parse(s) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp normalize_year(y) when y < 50, do: 2000 + y
  defp normalize_year(y) when y < 100, do: 1900 + y
  defp normalize_year(y), do: y

  defp parse_offset(tz) do
    case String.upcase(tz) do
      t when t in ["UT", "UTC", "GMT", "Z"] ->
        {:ok, 0}

      <<sign, h1, h2, m1, m2>> when sign in [?+, ?-] ->
        total = ((h1 - ?0) * 10 + (h2 - ?0)) * 3600 + ((m1 - ?0) * 10 + (m2 - ?0)) * 60
        {:ok, if(sign == ?-, do: -total, else: total)}

      _ ->
        :error
    end
  end
end
