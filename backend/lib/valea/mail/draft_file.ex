defmodule Valea.Mail.DraftFile do
  @moduledoc """
  Parse + fail-closed validation of an outbound draft file
  (mail-as-maildir design spec E, §Drafting & push). A draft lives at
  `sources/mail/<account>/drafts/<name>.md` and is **untrusted input** —
  agents (and the user) write drafts through the ask-gate, so composition
  must validate every frontmatter field before a single header byte is
  serialized.

  ## Frontmatter grammar

      ---
      to: [alex@example.com]
      cc: []
      bcc: []
      subject: "Re: Kickoff"
      in_reply_to: 2026-07-15-alex-4f2a91c3   # msg_id, optional
      status: draft                            # draft | pushing | pushed
      ---
      Body in markdown; composed as text/plain.

  `parse_and_validate/1` is strict:

    * unknown frontmatter fields reject (allowed:
      `to`/`cc`/`bcc`/`subject`/`in_reply_to`/`status`);
    * `status` is `draft` | `pushing` | `pushed` | absent (defaults
      `draft`) — any OTHER value rejects. All three parse without
      rejection: the **anti-forgery rule lives in the push flow**, not
      here — the push rejects a non-`draft` stamp unless a ledger op
      corroborates it (the engine wrote it), and listing derives the
      displayed state from the ledger, never the frontmatter. Keeping
      engine-stamped values parseable is what makes an edited,
      previously-pushed draft re-pushable;
    * any CR, LF, or NUL inside ANY field value rejects (header-injection
      defense);
    * `to`/`cc`/`bcc` are parsed with an RFC 5322 mailbox parser
      (`parse_mailbox/1`: name-addr + addr-spec, quoted display names; no
      groups, no route addrs) — at least one `to`;
    * `in_reply_to`, when present, must match the msg_id shape.

  The outbound headers are always serialized from the PARSED values
  (`Valea.Mail.DraftMime.compose/4`), never the raw frontmatter strings.
  """

  @allowed_keys ~w(to cc bcc subject in_reply_to status)
  @statuses ~w(draft pushing pushed)
  @msg_id_re ~r/^[0-9]{4}-[0-9]{2}-[0-9]{2}-[a-z0-9-]+-[0-9a-f]{8,64}$/

  # RFC 5322 addr-spec: dot-atom local part (atext, no leading/trailing dot),
  # `@`, a dotted domain of alnum/hyphen labels. Deliberately conservative —
  # it structurally rejects whitespace, angle brackets, and the group/route
  # punctuation (`:`/`;`/`,`) that the mailbox forms below must never admit.
  @addr_re ~r/^[A-Za-z0-9!#$%&'*+\/=?^_`{|}~-]+(\.[A-Za-z0-9!#$%&'*+\/=?^_`{|}~-]+)*@[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$/

  # Specials that force a display name to be quoted (RFC 5322 §3.2.3). An
  # UNquoted phrase carrying any of these is invalid — `.`/`-`/`'` are
  # deliberately tolerated bare so ordinary names ("John Q. Public",
  # "O'Brien") don't need quoting.
  @display_specials ["(", ")", "<", ">", "[", "]", ":", ";", "@", "\\", ",", "\""]

  @type addr :: %{name: String.t() | nil, email: String.t()}
  @type validated :: %{
          to: [addr()],
          cc: [addr()],
          bcc: [addr()],
          subject: String.t(),
          in_reply_to: String.t() | nil,
          status: String.t(),
          body: String.t()
        }

  @doc "The SHA-256 of the exact draft bytes, lowercase hex — the hash bound end-to-end through the push (spec §Safety invariants)."
  @spec content_hash(binary()) :: String.t()
  def content_hash(bytes) when is_binary(bytes),
    do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  @doc """
  Rewrites the draft's engine-owned `status:` frontmatter field to `status`
  (one of `draft`/`pushing`/`pushed`), inserting the line if absent, and
  leaves everything else byte-for-byte. Used by the push flow's atomic
  compare-and-swap stamp (`Valea.Mail.OpsExecutor`). `:error` when the input
  has no frontmatter block.
  """
  @spec stamp_status(binary(), String.t()) :: {:ok, binary()} | :error
  def stamp_status(bytes, status) when is_binary(bytes) and status in @statuses do
    case split_frontmatter(bytes) do
      {:ok, block, body} ->
        new_block =
          if Regex.match?(~r/^status:.*$/m, block) do
            Regex.replace(~r/^status:.*$/m, block, fn _ -> "status: #{status}" end, global: false)
          else
            String.trim_trailing(block, "\n") <> "\nstatus: #{status}"
          end

        {:ok, "---\n" <> new_block <> "\n---\n" <> body}

      {:error, _reason} ->
        :error
    end
  end

  @doc """
  Parses and validates the whole draft (frontmatter + body). Returns the
  parsed recipient sets, subject, threading hint, engine-owned status stamp,
  and raw body; `{:error, reason}` on ANY rule violation — never a partial
  or best-effort result.
  """
  @spec parse_and_validate(binary()) :: {:ok, validated()} | {:error, String.t()}
  def parse_and_validate(bytes) when is_binary(bytes) do
    with {:ok, block, body} <- split_frontmatter(bytes),
         {:ok, map} <- parse_yaml_map(block),
         :ok <- check_known_keys(map),
         {:ok, status} <- validate_status(map),
         {:ok, to} <- validate_addr_list(map, "to", true),
         {:ok, cc} <- validate_addr_list(map, "cc", false),
         {:ok, bcc} <- validate_addr_list(map, "bcc", false),
         {:ok, subject} <- validate_subject(map),
         {:ok, in_reply_to} <- validate_in_reply_to(map) do
      {:ok,
       %{
         to: to,
         cc: cc,
         bcc: bcc,
         subject: subject,
         in_reply_to: in_reply_to,
         status: status,
         body: body
       }}
    end
  end

  # -- frontmatter --------------------------------------------------------------

  defp split_frontmatter("---\n" <> rest) do
    case String.split(rest, "\n---\n", parts: 2) do
      [block, body] -> {:ok, block, body}
      _ -> {:error, "missing frontmatter terminator"}
    end
  end

  defp split_frontmatter(_other), do: {:error, "draft has no leading frontmatter block"}

  defp parse_yaml_map(block) do
    case YamlElixir.read_from_string(block) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _other} -> {:error, "frontmatter is not a mapping"}
      {:error, error} -> {:error, "invalid frontmatter yaml: #{describe(error)}"}
    end
  rescue
    error -> {:error, "invalid frontmatter yaml: #{Exception.message(error)}"}
  end

  defp describe(%{message: message}) when is_binary(message), do: message
  defp describe(other), do: inspect(other)

  defp check_known_keys(map) do
    case Enum.reject(Map.keys(map), &(&1 in @allowed_keys)) do
      [] -> :ok
      extra -> {:error, "unknown frontmatter field(s): #{Enum.join(Enum.sort(extra), ", ")}"}
    end
  end

  # -- status -------------------------------------------------------------------

  defp validate_status(map) do
    case Map.get(map, "status") do
      nil ->
        {:ok, "draft"}

      value when is_binary(value) ->
        cond do
          has_control?(value) -> {:error, "control character in status"}
          value in @statuses -> {:ok, value}
          true -> {:error, "invalid status #{inspect(value)}"}
        end

      _other ->
        {:error, "status must be a string"}
    end
  end

  # -- recipients ---------------------------------------------------------------

  defp validate_addr_list(map, key, required?) do
    with {:ok, values} <- coerce_list(map, key) do
      cond do
        required? and values == [] -> {:error, "#{key} requires at least one recipient"}
        true -> parse_all_mailboxes(values, key, [])
      end
    end
  end

  defp coerce_list(map, key) do
    case Map.get(map, key) do
      nil -> {:ok, []}
      value when is_binary(value) -> {:ok, [value]}
      value when is_list(value) -> {:ok, value}
      _other -> {:error, "#{key} must be a string or a list of strings"}
    end
  end

  defp parse_all_mailboxes([], _key, acc), do: {:ok, Enum.reverse(acc)}

  defp parse_all_mailboxes([value | rest], key, acc) do
    cond do
      not is_binary(value) ->
        {:error, "#{key} entries must be strings"}

      has_control?(value) ->
        {:error, "control character in #{key} recipient"}

      true ->
        case parse_mailbox(value) do
          {:ok, addr} -> parse_all_mailboxes(rest, key, [addr | acc])
          {:error, reason} -> {:error, "#{key}: #{reason}"}
        end
    end
  end

  # -- subject / in_reply_to ----------------------------------------------------

  defp validate_subject(map) do
    case Map.get(map, "subject") do
      nil ->
        {:ok, ""}

      value when is_binary(value) ->
        if has_control?(value), do: {:error, "control character in subject"}, else: {:ok, value}

      _other ->
        {:error, "subject must be a string"}
    end
  end

  defp validate_in_reply_to(map) do
    case Map.get(map, "in_reply_to") do
      nil ->
        {:ok, nil}

      "" ->
        {:ok, nil}

      value when is_binary(value) ->
        cond do
          has_control?(value) -> {:error, "control character in in_reply_to"}
          Regex.match?(@msg_id_re, value) -> {:ok, value}
          true -> {:error, "in_reply_to must be a valid msg_id"}
        end

      _other ->
        {:error, "in_reply_to must be a string"}
    end
  end

  # -- mailbox parser -----------------------------------------------------------

  @doc """
  Parses ONE RFC 5322 mailbox — either an addr-spec (`local@domain`) or a
  name-addr (`[display-name] <addr-spec>`), with quoted or bare display
  names. Rejects everything else: groups, route addrs, address LISTS
  (a comma-bearing string), and any control character. Returns
  `%{name: String.t() | nil, email: String.t()}`.
  """
  @spec parse_mailbox(String.t()) :: {:ok, addr()} | {:error, String.t()}
  def parse_mailbox(str) when is_binary(str) do
    trimmed = String.trim(str)

    cond do
      has_control?(str) -> {:error, "control character in mailbox"}
      trimmed == "" -> {:error, "empty mailbox"}
      String.contains?(trimmed, "<") or String.contains?(trimmed, ">") -> parse_name_addr(trimmed)
      valid_addr_spec?(trimmed) -> {:ok, %{name: nil, email: trimmed}}
      true -> {:error, "invalid address #{inspect(trimmed)}"}
    end
  end

  defp parse_name_addr(str) do
    with [display, rest] <- split_once(str, "<"),
         true <- String.ends_with?(rest, ">"),
         addr <- rest |> String.slice(0..-2//1) |> String.trim(),
         false <- String.contains?(addr, "<") or String.contains?(addr, ">"),
         true <- valid_addr_spec?(addr),
         {:ok, name} <- validate_display_name(String.trim(display)) do
      {:ok, %{name: name, email: addr}}
    else
      _ -> {:error, "invalid mailbox #{inspect(str)}"}
    end
  end

  defp split_once(str, sep) do
    case String.split(str, sep, parts: 2) do
      [a, b] -> [a, b]
      _ -> :error
    end
  end

  defp validate_display_name(""), do: {:ok, nil}

  defp validate_display_name(name) do
    cond do
      quoted?(name) ->
        unquote_phrase(name)

      Enum.any?(@display_specials, &String.contains?(name, &1)) ->
        {:error, "unquoted display name has specials"}

      true ->
        {:ok, name}
    end
  end

  defp quoted?(name),
    do:
      String.length(name) >= 2 and String.starts_with?(name, "\"") and
        String.ends_with?(name, "\"")

  defp unquote_phrase(name) do
    inner = String.slice(name, 1..-2//1)
    # Unescape \" and \\; reject an odd trailing backslash or an unescaped
    # inner quote (a malformed quoted-string).
    case unescape(inner, []) do
      {:ok, unescaped} -> {:ok, unescaped}
      :error -> {:error, "malformed quoted display name"}
    end
  end

  defp unescape("", acc), do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}
  defp unescape("\\" <> <<c::utf8, rest::binary>>, acc), do: unescape(rest, [<<c::utf8>> | acc])
  defp unescape("\\", _acc), do: :error
  defp unescape("\"" <> _rest, _acc), do: :error
  defp unescape(<<c::utf8, rest::binary>>, acc), do: unescape(rest, [<<c::utf8>> | acc])

  defp valid_addr_spec?(addr), do: Regex.match?(@addr_re, addr)

  # -- shared -------------------------------------------------------------------

  defp has_control?(value), do: String.contains?(value, ["\r", "\n", "\0"])
end
