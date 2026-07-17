defmodule Valea.Mail.MessageFile do
  @moduledoc """
  `Valea.Mail.Message` ⇄ the on-disk `sources/mail/<account>/views/messages/
  <msg_id>.md` format (mail-as-maildir design spec, §Derived views &
  indexing). This module owns:

    * `fingerprint/1` — the sha256 hex digest of the raw RFC822 bytes, the
      message identity's foundation (mail-as-maildir design spec,
      §Two-level identity: "the hash is a fingerprint of the raw RFC822
      bytes").
    * `msg_id/2` — the deterministic `<date>-<from-slug>-<hash8>` filename
      stem, `hash8` being `fingerprint/1`'s first 8 hex characters. The
      hash-extension collision rule (8 → 16 → 64 hex) lives in
      `Valea.Mail.Views.land/4`, the only caller that has the stored
      fingerprints to detect a collision against.
    * `render/2` — struct + landing metadata → file bytes (frontmatter +
      body).
    * `parse/1` — file bytes → `%{frontmatter:, body:}` (the read side
      `Valea.Mail.Index`'s cache-only rebuild uses to recover a message's
      metadata without re-normalizing raw mail bytes).
    * `patch_frontmatter/2` — byte-preserving multi-key `<key>: ...` line
      replacement inside the leading frontmatter block, never touching
      anything else (other frontmatter fields, their exact formatting, or
      the body) — `Valea.Mail.Views.refresh_folders/5` uses it to patch
      `folders:`/`flags:` in place whenever occurrence membership changes,
      without a full re-render. Supersedes the old `flip_status/2` (deleted
      — there is no more `status:` field to flip; see the moduledoc below).
    * `sanitize_filename/1` — the basename-only, control-char-free,
      no-traversal filename attachment landing uses before ever touching
      the filesystem.

  ## Fingerprint identity (mail-as-maildir design spec, §Two-level identity)

  A message's identity is its raw bytes, not its `Message-ID` header:
  `Message-ID` is sender-controlled and not guaranteed unique, so two
  distinct messages that happen to reuse one get different msg_ids (and
  separate views), while true multi-folder occurrences of the same bytes
  (a Gmail label + INBOX, an ordinary `COPY`) share one msg_id and one
  view. `Message-ID` is therefore never hashed here — only a lookup hint
  elsewhere in the pipeline (`Valea.Mail.Views.land/4`'s caller can use it
  to short-circuit which existing msg_id to re-land under).

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
       inject a new YAML line (e.g. a second `id:` key), and
    3. double-quotes the result, escaping `\\` and `"`.

  A mail header must never be able to break the frontmatter block.
  """

  alias Valea.Mail.Message
  alias Valea.Mail.Normalizer

  # -- fingerprint / msg_id ----------------------------------------------------

  @doc """
  Sha256 hex digest (lowercase, full 64 characters) of `raw` — the raw
  RFC822 bytes of one occurrence. The message identity's foundation: two
  occurrences with byte-identical `raw` always fingerprint identically
  (same msg_id, one shared view); anything else, including a single
  differing byte, fingerprints differently.
  """
  @spec fingerprint(binary()) :: String.t()
  def fingerprint(raw) when is_binary(raw) do
    :sha256 |> :crypto.hash(raw) |> Base.encode16(case: :lower)
  end

  @doc """
  `<yyyy-mm-dd>-<from-slug>-<hash8>`. Deterministic: the same `message` +
  `raw` always produce the same id. `hash8` is `fingerprint/1`'s first 8
  hex characters — a fingerprint of the raw RFC822 bytes, never of the
  `Message-ID` header (see the moduledoc, §Fingerprint identity). Only this
  8-hex stem is this function's job; extending it to 16 or 64 hex on a
  collision against a DIFFERENT fingerprint is `Valea.Mail.Views.land/4`'s
  job (it alone has the stored fingerprints to detect one).
  `message.date` is virtually always present (`Normalizer` only leaves it
  `nil` when the `Date` header is missing or unparseable); on that rare
  path the epoch `1970-01-01` is used as the date component so the id keeps
  its fixed three-segment shape rather than needing a fourth,
  sometimes-absent field.
  """
  @spec msg_id(Message.t(), binary()) :: String.t()
  def msg_id(%Message{} = message, raw) when is_binary(raw) do
    "#{date_slug(message.date)}-#{from_slug(message.from)}-#{hash8(raw)}"
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

  defp hash8(raw), do: raw |> fingerprint() |> String.slice(0, 8)

  # -- render ------------------------------------------------------------

  @doc """
  Renders `message` + landing `meta` to the exact frontmatter format from
  the mail-as-maildir design spec (§Derived views & indexing): field order
  `id, message_id, account, folders, flags, from, to, subject, date,
  in_reply_to, references, reply_to, attachments`, then any present
  `notes` (`charset_note, normalizer_note, truncation_note`, in that
  order), then `---`, then `message.body_text` verbatim.

  `meta` is `%{msg_id:, account:, folders: [String.t()], flags: String.t(),
  attachments: [%{filename:, path:, bytes:}]}`. `folders`/`flags`/
  `attachments` default to `[]`/`""`/`[]` when absent (a fresh landing has
  no folder membership yet — `Valea.Mail.Views.refresh_folders/5` fills
  them in once occurrences are known). There is deliberately no
  `status`/`uid`/`source`/`source_ref` field — those belonged to the
  retired single-flat-file design; occurrence identity now lives on the
  maildir filename (`Valea.Mail.Maildir.encode_filename/3`) and in
  `mail_messages`/`mail_uid_map`, not in the shared view.
  """
  @spec render(Message.t(), map()) :: binary()
  def render(%Message{} = message, meta) do
    lines =
      [
        "---",
        "id: #{meta.msg_id}",
        "message_id: #{yaml_string(message.message_id)}",
        "account: #{yaml_string(meta.account)}",
        "folders: #{render_string_list(Map.get(meta, :folders, []))}",
        "flags: #{yaml_string(Map.get(meta, :flags, ""))}",
        "from: #{render_address(message.from)}",
        "to: #{render_address_list(message.to)}",
        "subject: #{yaml_string(message.subject)}",
        "date: #{render_date(message.date)}",
        "in_reply_to: #{yaml_string(message.in_reply_to)}",
        "references: #{render_string_list(message.references)}",
        "reply_to: #{render_address(message.reply_to)}",
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

  @doc """
  Renders a YAML flow-sequence of double-quoted, injection-hardened
  strings (`[]` when empty) — the exact encoding `render/2` uses for
  `references:` and `folders:`. Public because
  `Valea.Mail.Views.refresh_folders/5` reuses it verbatim to patch the
  `folders:` line without pulling in the rest of `render/2`.
  """
  @spec render_string_list([String.t()]) :: String.t()
  def render_string_list([]), do: "[]"
  def render_string_list(list), do: "[" <> Enum.map_join(list, ", ", &yaml_string/1) <> "]"

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
  @doc """
  Double-quotes and injection-hardens `value` (`"null"` for `nil`): scrubs
  invalid UTF-8, neutralizes C0/DEL control characters to a plain space,
  escapes `\\` and `"`. Public because `Valea.Mail.Views.refresh_folders/5`
  reuses it verbatim to patch the `flags:` line.
  """
  @spec yaml_string(String.t() | nil) :: String.t()
  def yaml_string(nil), do: "null"

  def yaml_string(value) when is_binary(value) do
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

  # -- patch_frontmatter ---------------------------------------------------

  @doc """
  Replaces one or more `<key>: ...` lines inside the leading `---\\n...\\n
  ---\\n` frontmatter block, byte-for-byte preserving everything else
  (other frontmatter fields, their exact formatting, and the whole body) —
  the same discipline the deleted `flip_status/2` used for the retired
  `status:` field, generalized to any set of keys. `replacements` is a
  `%{String.t() => String.t()}` of bare key name → the FULL replacement
  line value (already rendered, e.g. via `render_string_list/1`/
  `yaml_string/1`) — only the first match per key is replaced
  (`global: false`), and only within the extracted frontmatter block, so a
  body line that happens to start with `"folders:"` can never be
  clobbered. A key absent from the block is silently left untouched (not
  an error — `refresh_folders/5` always targets keys `render/2` always
  emits, but this function itself doesn't assume it).
  """
  @spec patch_frontmatter(binary(), %{String.t() => String.t()}) ::
          {:ok, binary()} | {:error, :no_frontmatter}
  def patch_frontmatter(file_bytes, replacements)
      when is_binary(file_bytes) and is_map(replacements) do
    with {:ok, block, body} <- split_frontmatter(file_bytes) do
      new_block =
        Enum.reduce(replacements, block, fn {key, value}, acc ->
          # FUNCTION replacement, never a string one: `Regex.replace/4` with a
          # STRING replacement reinterprets `\N` as a capture-group
          # backreference and collapses `\\` pairs to a single `\`
          # (Perl-style replacement escaping) — silently corrupting any
          # `yaml_string/1`-escaped value that contains a backslash (e.g. an
          # IMAP folder name ending in `\` renders its closing `\\"` as a
          # collapsed `\"`, un-terminating the YAML string). The function
          # form returns its result verbatim, byte-for-byte, with no
          # reinterpretation.
          Regex.replace(~r/^#{Regex.escape(key)}:.*$/m, acc, fn _ -> "#{key}: #{value}" end,
            global: false
          )
        end)

      {:ok, new_block <> body}
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
  characters (a landing path is `<dir>/<msg_id>/<filename>` — none of
  these may reintroduce a path separator), collapsing to `"attachment"` if
  nothing safe is left (including the bare `.`/`..` tokens, which strip to
  themselves and would otherwise still resolve to a directory, not a
  file).
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
