defmodule Valea.Mail.MessageFile do
  @moduledoc """
  `Valea.Mail.Message` ⇄ the on-disk `sources/mail/messages/<msg_id>.md`
  format (mail design spec, §Normalized message file). This module owns:

    * `msg_id/2` — the deterministic `<date>-<from-slug>-<hash8>` filename
      stem.
    * `render/2` — struct + landing metadata → file bytes (frontmatter +
      body).
    * `parse/1` — file bytes → `%{frontmatter:, body:}` (the read side a
      later task's message index / status-flip uses).
    * `flip_status/2` — byte-preserving `status:` line replacement (never
      re-serializes the rest of the file — a later task's file writes must
      never perturb bytes a diff or a hash comparison depends on).
    * `sanitize_filename/1` — the basename-only, control-char-free,
      no-traversal filename a later (attachment-landing) task uses before
      ever touching the filesystem.

  ## Frontmatter injection hardening

  Every value that ultimately comes from a mail header (subject, from/to
  names and emails, message_id, in_reply_to, references, reply_to,
  attachment filenames) is rendered through `yaml_string/1`, which:

    1. scrubs invalid UTF-8 (each bad sequence → U+FFFD, via
       `Valea.Mail.Normalizer.scrub_utf8/1`) so `render/2` structurally
       cannot raise on a struct field carrying raw header bytes —
       regardless of whether the normalizer produced it,
    2. replaces every C0 control character (`< 0x20`) and DEL (`0x7F`) —
       notably `\\n` and `\\r` — with a plain space, so a header can never
       inject a new YAML line (e.g. a second `status:` key), and
    3. double-quotes the result, escaping `\\` and `"`.

  A mail header must never be able to break the frontmatter block.
  """

  alias Valea.Mail.Message
  alias Valea.Mail.Normalizer

  @status_re ~r/^status:.*$/m

  # -- msg_id ----------------------------------------------------------------

  @doc """
  `<yyyy-mm-dd>-<from-slug>-<hash8>`. Deterministic: the same `message` +
  `raw_headers` always produce the same id. `hash8` is the first 8 hex
  characters of SHA-256 over `message.message_id` when present, else over
  the entire raw header block (a far stronger disambiguator than
  date/from/subject, which can legitimately collide, per the mail design
  spec) — this is why `raw_headers` is always required, even though it's
  only actually hashed when `message_id` is missing. `message.date` is
  virtually always present (`Normalizer` only leaves it `nil` when the
  `Date` header is missing or unparseable); on that rare path the epoch
  `1970-01-01` is used as the date component so the id keeps its fixed
  three-segment shape rather than needing a fourth, sometimes-absent field.
  """
  @spec msg_id(Message.t(), binary()) :: String.t()
  def msg_id(%Message{} = message, raw_headers) when is_binary(raw_headers) do
    "#{date_slug(message.date)}-#{from_slug(message.from)}-#{hash8(message.message_id, raw_headers)}"
  end

  defp date_slug(nil), do: "1970-01-01"
  defp date_slug(%DateTime{} = dt), do: dt |> DateTime.to_date() |> Date.to_iso8601()

  defp from_slug(%{name: name, email: email}) do
    base = if blank?(name), do: local_part(email), else: name

    slug =
      base
      |> to_string()
      |> String.normalize(:nfd)
      |> String.replace(~r/\p{Mn}/u, "")
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 40)
      |> String.trim_trailing("-")

    if slug == "", do: "unknown", else: slug
  end

  defp local_part(nil), do: ""

  defp local_part(email) do
    case String.split(email, "@", parts: 2) do
      [local, _domain] -> local
      _ -> email
    end
  end

  defp blank?(nil), do: true
  defp blank?(s), do: String.trim(s) == ""

  defp hash8(message_id, raw_headers) do
    source = if blank?(message_id), do: raw_headers, else: message_id

    :sha256
    |> :crypto.hash(source)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 8)
  end

  # -- render ------------------------------------------------------------

  @doc """
  Renders `message` + landing `meta` to the exact frontmatter format from
  the mail design spec (§Normalized message file): field order `id,
  message_id, from, to, subject, date, uid, in_reply_to, references,
  reply_to, status, source, source_ref, attachments`, then any present
  `notes` (`charset_note, normalizer_note, truncation_note`, in that
  order), then `---`, then `message.body_text` verbatim.

  `meta` is `%{msg_id:, uid: int | nil, status: "review" | "processed",
  source: "imap" | "seed", attachments: [%{filename:, path:, bytes:}]}`.
  `source_ref` defaults to `"email://" <> source <> "/" <> msg_id`; pass
  `meta[:source_ref]` to override it (seed data keeps its legacy ref).
  """
  @spec render(Message.t(), map()) :: binary()
  def render(%Message{} = message, meta) do
    source_ref = Map.get(meta, :source_ref) || "email://#{meta.source}/#{meta.msg_id}"

    lines =
      [
        "---",
        "id: #{meta.msg_id}",
        "message_id: #{yaml_string(message.message_id)}",
        "from: #{render_address(message.from)}",
        "to: #{render_address_list(message.to)}",
        "subject: #{yaml_string(message.subject)}",
        "date: #{render_date(message.date)}",
        "uid: #{render_int(Map.get(meta, :uid))}",
        "in_reply_to: #{yaml_string(message.in_reply_to)}",
        "references: #{render_string_list(message.references)}",
        "reply_to: #{render_address(message.reply_to)}",
        "status: #{meta.status}",
        "source: #{meta.source}",
        "source_ref: #{yaml_string(source_ref)}",
        "attachments: #{render_attachment_list(Map.get(meta, :attachments, []))}"
      ] ++ render_notes(message.notes) ++ ["---"]

    Enum.join(lines, "\n") <> "\n" <> message.body_text
  end

  defp render_address(nil), do: "null"

  defp render_address(%{name: name, email: email}) do
    "{ name: #{yaml_string(name)}, email: #{yaml_string(email)} }"
  end

  defp render_address_list([]), do: "[]"
  defp render_address_list(list), do: "[" <> Enum.map_join(list, ", ", &render_address/1) <> "]"

  defp render_string_list([]), do: "[]"
  defp render_string_list(list), do: "[" <> Enum.map_join(list, ", ", &yaml_string/1) <> "]"

  defp render_attachment_list([]), do: "[]"

  defp render_attachment_list(list),
    do: "[" <> Enum.map_join(list, ", ", &render_attachment/1) <> "]"

  defp render_attachment(%{filename: filename, path: path, bytes: bytes}) do
    "{ filename: #{yaml_string(filename)}, path: #{yaml_string(path)}, bytes: #{render_int(bytes)} }"
  end

  defp render_date(nil), do: "null"
  defp render_date(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp render_int(nil), do: "null"
  defp render_int(n) when is_integer(n), do: Integer.to_string(n)

  @note_keys [:charset_note, :normalizer_note, :truncation_note]

  defp render_notes(notes) do
    for key <- @note_keys, Map.has_key?(notes, key), do: "#{key}: #{yaml_string(notes[key])}"
  end

  # Injection hardening: invalid UTF-8 scrubbed first (String.to_charlist/1
  # in neutralize_control_chars/1 would raise UnicodeConversionError on raw
  # header bytes otherwise — the guarantee must not depend on the caller
  # having normalized the field), then C0/DEL neutralized to a space (never
  # dropped, so offsets in error messages/tests stay stable), then `\` and
  # `"` escaped, then double-quoted. A mail header can therefore never crash
  # a render, terminate the string early, or inject a sibling YAML key.
  defp yaml_string(nil), do: "null"

  defp yaml_string(value) when is_binary(value) do
    escaped =
      value
      |> ensure_valid_utf8()
      |> neutralize_control_chars()
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    "\"#{escaped}\""
  end

  defp ensure_valid_utf8(value) do
    if String.valid?(value), do: value, else: Normalizer.scrub_utf8(value)
  end

  defp neutralize_control_chars(s) do
    s
    |> String.to_charlist()
    |> Enum.map(fn c -> if c < 0x20 or c == 0x7F, do: ?\s, else: c end)
    |> List.to_string()
  end

  # -- flip_status ---------------------------------------------------------

  @doc """
  Replaces only the `status:` line inside the leading `---\\n...\\n---\\n`
  frontmatter block, byte-for-byte preserving everything else (other
  frontmatter fields, their exact formatting, and the whole body).
  """
  @spec flip_status(binary(), String.t()) :: {:ok, binary()} | {:error, :no_frontmatter}
  def flip_status(file_bytes, new_status) when is_binary(file_bytes) and is_binary(new_status) do
    with {:ok, block, body} <- split_frontmatter(file_bytes),
         true <- Regex.match?(@status_re, block) do
      new_block = Regex.replace(@status_re, block, "status: #{new_status}", global: false)
      {:ok, new_block <> body}
    else
      _ -> {:error, :no_frontmatter}
    end
  end

  # -- parse -------------------------------------------------------------

  @doc """
  Splits `file_bytes` into its frontmatter (parsed as YAML into a map) and
  body. `{:error, :no_frontmatter}` when there's no leading `---\\n...\\n
  ---\\n` block; `{:error, reason}` when the block isn't valid YAML.
  """
  @spec parse(binary()) :: {:ok, %{frontmatter: map(), body: String.t()}} | {:error, term()}
  def parse(file_bytes) when is_binary(file_bytes) do
    with {:ok, block, body} <- split_frontmatter(file_bytes),
         yaml <- block |> String.trim_leading("---\n") |> String.trim_trailing("---\n"),
         {:ok, frontmatter} when is_map(frontmatter) <- YamlElixir.read_from_string(yaml) do
      {:ok, %{frontmatter: frontmatter, body: body}}
    else
      {:ok, _not_a_map} -> {:error, :invalid_frontmatter}
      {:error, reason} -> {:error, reason}
    end
  end

  defp split_frontmatter("---\n" <> rest) do
    case String.split(rest, "\n---\n", parts: 2) do
      [yaml, body] -> {:ok, "---\n" <> yaml <> "\n---\n", body}
      _ -> {:error, :no_frontmatter}
    end
  end

  defp split_frontmatter(_input), do: {:error, :no_frontmatter}

  # -- sanitize_filename -----------------------------------------------------

  @doc """
  Basename-only, C0/DEL- and `/ \\\\ :`-free filename, safe to join under an
  attachment landing directory: `Path.basename/1` first (strips `/`-based
  traversal), then strips C0/DEL control characters and the `/`, `\\`, `:`
  characters (a later task's landing path is `<dir>/<msg_id>/<filename>` —
  none of these may reintroduce a path separator), collapsing to
  `"attachment"` if nothing safe is left (including the bare `.`/`..`
  tokens, which strip to themselves and would otherwise still resolve to a
  directory, not a file).
  """
  @spec sanitize_filename(String.t()) :: String.t()
  def sanitize_filename(name) when is_binary(name) do
    cleaned =
      name
      |> String.trim()
      |> Path.basename()
      |> String.to_charlist()
      |> Enum.reject(fn c -> c < 0x20 or c == 0x7F or c in [?/, ?\\, ?:] end)
      |> List.to_string()
      |> String.trim()

    if cleaned in ["", ".", ".."], do: "attachment", else: cleaned
  end
end
