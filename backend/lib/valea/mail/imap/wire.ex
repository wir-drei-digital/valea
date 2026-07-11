defmodule Valea.Mail.Imap.Wire do
  @moduledoc """
  Pure IMAP wire codec: parses server responses off a byte buffer and
  encodes client commands. No sockets, no processes — `pull/1` and
  `encode/2` are ordinary functions over binaries.

  Parsing is byte-exact, not text/regex based: IMAP literals (`{N}\r\n`
  followed by exactly N raw bytes) can contain arbitrary bytes, including
  `)`, `\r`, `\n`, so anything that scans literal content for structural
  characters (like a naive regex over the whole line) can misparse. This
  module always skips literal content by exact byte count and never
  inspects it while looking for message framing.
  """

  @type fetch_attrs :: %{
          uid: integer() | nil,
          size: integer() | nil,
          flags: [binary()],
          body: binary() | nil,
          header: binary() | nil,
          internaldate: binary() | nil
        }

  @type response ::
          {:tagged, tag :: binary(), :ok | :no | :bad, text :: binary()}
          | {:untagged, line :: binary()}
          | {:fetch, seq :: integer(), attrs :: fetch_attrs()}
          | {:continuation, text :: binary()}

  @doc """
  Pull exactly one complete server response off the front of `buffer`.

  Returns `:incomplete` whenever the buffer holds less than a full
  response — including a partially received literal. Never guesses.
  """
  @spec pull(binary()) :: {:ok, response(), rest :: binary()} | :incomplete
  def pull(buffer) when is_binary(buffer) do
    case response_end(buffer, 0) do
      :incomplete ->
        :incomplete

      {:ok, end_pos} ->
        <<raw::binary-size(^end_pos), rest::binary>> = buffer
        {:ok, classify(raw), rest}
    end
  end

  @doc """
  Encode one IMAP command line.

  `parts` is a flat list of arguments: plain binaries are quoted or left
  bare per IMAP astring/atom rules, and `{:literal, bin}` entries become
  `{N}` placeholders whose bytes are returned separately in
  `pending_literals` (in order) for the caller to send after receiving a
  `{:continuation, _}` from the server, followed by `"\r\n"`.

  Non-standard LITERAL+ synchronizing literals (`{N+}`) are not used.

  Raises `ArgumentError` if a plain binary argument contains CR, LF, or
  any 8-bit byte — such content cannot be safely quoted onto a single
  command line and must be sent as `{:literal, _}` instead. This is the
  command-injection guard: without it, a value like
  `"x\r\nA4 DELETE INBOX"` could smuggle a second command into the stream.
  """
  @spec encode(tag :: binary(), parts :: [binary() | {:literal, binary()}]) ::
          {iodata(), pending_literals :: [binary()]}
  def encode(tag, parts) when is_binary(tag) and is_list(parts) do
    {tokens, literals_rev} =
      Enum.map_reduce(parts, [], fn
        {:literal, bin}, acc when is_binary(bin) ->
          {["{", Integer.to_string(byte_size(bin)), "}"], [bin | acc]}

        bin, acc when is_binary(bin) ->
          {encode_arg(bin), acc}
      end)

    iodata = [tag, " ", Enum.intersperse(tokens, " "), "\r\n"]
    {iodata, Enum.reverse(literals_rev)}
  end

  @doc """
  Encode one IMAP command as the ordered list of wire *segments* the
  synchronizing-literal dance requires — the general form `encode/2` cannot
  express when a `{:literal, _}` sits anywhere but the tail.

  `parts` is the same flat argument list `encode/2` accepts. The result is a
  list of iodata segments: send the first, then before each remaining segment
  read exactly one `{:continuation, _}` from the server. There are precisely
  `num_literals + 1` segments — a command with no literals is a single
  segment. Every non-final segment ends in a `{N}` literal marker + CRLF; the
  final segment ends in CRLF. Each literal's raw bytes lead the segment that
  follows its continuation, so ANY byte value (non-ASCII, spaces, quotes,
  control bytes) is transmitted verbatim rather than quoted — the reason
  `LOGIN` sends its username and password this way.

  Plain-binary arguments obey the same astring/atom quoting rules and the
  same CR/LF/8-bit guard as `encode/2`.
  """
  @spec encode_command(tag :: binary(), parts :: [binary() | {:literal, binary()}]) :: [iodata()]
  def encode_command(tag, parts) when is_binary(tag) and is_list(parts) do
    {[first_run | rest_runs], literals} = split_runs(parts)
    build_segments([tag, " ", space_join(first_run)], rest_runs, literals, [])
  end

  # Splits `parts` at each literal into the runs of plain (already-encoded)
  # tokens between the literals. Returns `{runs, literals}` with
  # `length(runs) == length(literals) + 1`.
  defp split_runs(parts) do
    {runs_rev, current_rev, literals_rev} =
      Enum.reduce(parts, {[], [], []}, fn
        {:literal, bin}, {runs, current, literals} when is_binary(bin) ->
          {[Enum.reverse(current) | runs], [], [bin | literals]}

        bin, {runs, current, literals} when is_binary(bin) ->
          {runs, [encode_arg(bin) | current], literals}
      end)

    runs = Enum.reverse([Enum.reverse(current_rev) | runs_rev])
    {runs, Enum.reverse(literals_rev)}
  end

  # `lead` is the current segment's bytes before its terminating marker. Each
  # step closes the current segment with `{N}` for the next literal, then
  # starts the following segment with that literal's raw bytes.
  defp build_segments(lead, [next_run | rest_runs], [lit | rest_lits], acc) do
    segment = [lead, " {", Integer.to_string(byte_size(lit)), "}\r\n"]
    build_segments([lit, run_prefix(next_run)], rest_runs, rest_lits, [segment | acc])
  end

  defp build_segments(lead, [], [], acc) do
    Enum.reverse([[lead, "\r\n"] | acc])
  end

  defp space_join(tokens), do: Enum.intersperse(tokens, " ")

  defp run_prefix([]), do: []
  defp run_prefix(tokens), do: [" ", space_join(tokens)]

  # -- response boundary scanning (byte-exact, literal-aware) --------------

  # Finds the absolute end offset (exclusive) of the first complete
  # response in `buffer` starting at `pos`. A response ends at the first
  # CRLF, unless the text immediately preceding that CRLF ends in a
  # literal marker `{N}`, in which case N raw bytes follow and the line
  # continues (repeat, to allow multiple literals per response).
  @spec response_end(binary(), non_neg_integer()) :: {:ok, non_neg_integer()} | :incomplete
  defp response_end(buffer, pos) do
    case find_crlf(buffer, pos) do
      :not_found ->
        :incomplete

      crlf_pos ->
        pre = binary_part(buffer, pos, crlf_pos - pos)

        case trailing_literal_len(pre) do
          nil ->
            {:ok, crlf_pos + 2}

          n ->
            literal_start = crlf_pos + 2
            literal_end = literal_start + n

            if byte_size(buffer) < literal_end do
              :incomplete
            else
              response_end(buffer, literal_end)
            end
        end
    end
  end

  defp find_crlf(buffer, pos) when pos > byte_size(buffer), do: :not_found

  defp find_crlf(buffer, pos) do
    case :binary.match(buffer, "\r\n", scope: {pos, byte_size(buffer) - pos}) do
      {idx, _len} -> idx
      :nomatch -> :not_found
    end
  end

  # Checks whether `pre` ends with a literal marker `{N}` (N all digits,
  # brace immediately at the end) and returns N, or nil if not.
  defp trailing_literal_len(pre) do
    size = byte_size(pre)

    if size > 0 and :binary.at(pre, size - 1) == ?} do
      case find_matching_open_brace(pre, size - 2) do
        nil ->
          nil

        idx ->
          digits = binary_part(pre, idx + 1, size - idx - 2)
          if digits != "" and all_digits?(digits), do: String.to_integer(digits), else: nil
      end
    else
      nil
    end
  end

  defp find_matching_open_brace(_pre, idx) when idx < 0, do: nil

  defp find_matching_open_brace(pre, idx) do
    case :binary.at(pre, idx) do
      ?{ -> idx
      c when c in ?0..?9 -> find_matching_open_brace(pre, idx - 1)
      _ -> nil
    end
  end

  defp all_digits?(<<>>), do: true
  defp all_digits?(<<c, rest::binary>>) when c in ?0..?9, do: all_digits?(rest)
  defp all_digits?(_), do: false

  # -- classification --------------------------------------------------

  # `raw` is exactly one complete response, including its terminating
  # CRLF and any embedded literal bytes.
  defp classify(<<"+ ", rest::binary>>), do: {:continuation, strip_crlf(rest)}
  defp classify(<<"* ", rest::binary>>), do: classify_untagged(rest)
  defp classify(raw), do: classify_tagged(raw)

  defp classify_untagged(rest) do
    case parse_fetch_prefix(rest) do
      {:fetch, seq, after_open_paren} ->
        {tokens, _remaining} = tokenize_list(after_open_paren)
        {:fetch, seq, build_attrs(tokens)}

      :not_fetch ->
        {:untagged, strip_crlf(rest)}
    end
  end

  defp parse_fetch_prefix(rest) do
    {digits, after_digits} = read_digits(rest, "")

    case {digits, after_digits} do
      {"", _} -> :not_fetch
      {_, <<" FETCH (", remainder::binary>>} -> {:fetch, String.to_integer(digits), remainder}
      _ -> :not_fetch
    end
  end

  defp classify_tagged(raw) do
    {tag, after_tag} = read_token(raw, "")
    {status_word, after_status} = read_token(strip_leading_space(after_tag), "")
    status = parse_status(status_word)
    text = strip_crlf(strip_leading_space(after_status))
    {:tagged, tag, status, text}
  end

  defp parse_status("OK"), do: :ok
  defp parse_status("NO"), do: :no
  defp parse_status("BAD"), do: :bad

  defp parse_status(other),
    do: raise(ArgumentError, "unknown tagged response status: #{inspect(other)}")

  defp read_digits(<<c, rest::binary>>, acc) when c in ?0..?9, do: read_digits(rest, acc <> <<c>>)
  defp read_digits(bin, acc), do: {acc, bin}

  defp read_token(<<c, rest::binary>>, acc) when c not in [?\s, ?\r, ?\n],
    do: read_token(rest, acc <> <<c>>)

  defp read_token(bin, acc), do: {acc, bin}

  defp strip_leading_space(<<" ", rest::binary>>), do: rest
  defp strip_leading_space(bin), do: bin

  defp strip_crlf(bin) when byte_size(bin) >= 2 do
    n = byte_size(bin) - 2
    binary_part(bin, 0, n)
  end

  defp strip_crlf(bin), do: bin

  # -- FETCH attr-list tokenizer -----------------------------------------
  #
  # Small recursive-descent tokenizer over: atoms (including BODY[...]
  # section specs, whose bracket contents are passed through verbatim so
  # nested parens like "BODY[HEADER.FIELDS (FROM SUBJECT)]" don't confuse
  # list nesting), quoted strings (\ and " escaped), parenthesized lists,
  # and literals (exact byte count, never scanned for structure).

  defp tokenize_list(bin), do: tokenize_list(bin, [])

  defp tokenize_list(bin, acc) do
    case skip_spaces(bin) do
      <<")", rest::binary>> ->
        {Enum.reverse(acc), rest}

      <<>> ->
        {Enum.reverse(acc), <<>>}

      rest ->
        {token, rest2} = read_token_value(rest)
        tokenize_list(rest2, [token | acc])
    end
  end

  defp skip_spaces(<<" ", rest::binary>>), do: skip_spaces(rest)
  defp skip_spaces(bin), do: bin

  defp read_token_value(<<"(", rest::binary>>) do
    {items, rest2} = tokenize_list(rest, [])
    {{:list, items}, rest2}
  end

  defp read_token_value(<<"\"", rest::binary>>), do: read_quoted(rest, "")
  defp read_token_value(<<"{", rest::binary>>), do: read_literal(rest)
  defp read_token_value(bin), do: read_atom(bin, "")

  defp read_literal(bin) do
    {digits, after_digits} = read_digits(bin, "")

    case after_digits do
      <<"}\r\n", rest::binary>> ->
        n = String.to_integer(digits)
        <<content::binary-size(^n), rest2::binary>> = rest
        {{:literal, content}, rest2}

      _ ->
        raise ArgumentError, "malformed IMAP literal marker"
    end
  end

  defp read_quoted(<<"\\", c, rest::binary>>, acc), do: read_quoted(rest, acc <> <<c>>)
  defp read_quoted(<<"\"", rest::binary>>, acc), do: {{:string, acc}, rest}
  defp read_quoted(<<c, rest::binary>>, acc), do: read_quoted(rest, acc <> <<c>>)
  defp read_quoted(<<>>, _acc), do: raise(ArgumentError, "unterminated quoted string")

  defp read_atom(<<"[", _::binary>> = bin, acc) do
    {bracket, rest} = read_bracket(bin)
    read_atom(rest, acc <> bracket)
  end

  defp read_atom(<<c, rest::binary>>, acc) when c not in [?\s, ?(, ?), ?{, ?\r, ?\n],
    do: read_atom(rest, acc <> <<c>>)

  defp read_atom(bin, acc), do: {{:atom, acc}, bin}

  defp read_bracket(<<"[", rest::binary>>), do: read_bracket_inner(rest, "[")
  defp read_bracket_inner(<<"]", rest::binary>>, acc), do: {acc <> "]", rest}

  defp read_bracket_inner(<<c, rest::binary>>, acc),
    do: read_bracket_inner(rest, acc <> <<c>>)

  defp read_bracket_inner(<<>>, _acc), do: raise(ArgumentError, "unterminated section spec")

  # -- token list -> fetch attrs map --------------------------------------

  @empty_attrs %{uid: nil, size: nil, flags: [], body: nil, header: nil, internaldate: nil}

  defp build_attrs(tokens) do
    tokens
    |> pair_up()
    |> Enum.reduce(@empty_attrs, &apply_attr/2)
  end

  defp pair_up([k, v | rest]), do: [{k, v} | pair_up(rest)]
  defp pair_up(_), do: []

  defp apply_attr({{:atom, "UID"}, v}, acc), do: %{acc | uid: token_int(v)}
  defp apply_attr({{:atom, "RFC822.SIZE"}, v}, acc), do: %{acc | size: token_int(v)}
  defp apply_attr({{:atom, "INTERNALDATE"}, v}, acc), do: %{acc | internaldate: token_text(v)}

  defp apply_attr({{:atom, "FLAGS"}, {:list, items}}, acc),
    do: %{acc | flags: Enum.map(items, &token_text/1)}

  defp apply_attr({{:atom, "BODY[]"}, v}, acc), do: %{acc | body: token_text(v)}

  defp apply_attr({{:atom, key}, v}, acc) do
    if String.starts_with?(key, "BODY[") do
      %{acc | header: token_text(v)}
    else
      acc
    end
  end

  defp apply_attr(_, acc), do: acc

  defp token_int({:atom, s}), do: String.to_integer(s)
  defp token_text({:atom, s}), do: s
  defp token_text({:string, s}), do: s
  defp token_text({:literal, s}), do: s
  defp token_text(_), do: nil

  # -- encode: argument quoting -------------------------------------------

  # Characters safe to leave bare (protocol syntax: commands, keywords,
  # sequence sets, section/flag punctuation) — uppercase only, so
  # arbitrary mailbox-name-shaped strings (e.g. "Drafts") are quoted by
  # default rather than accidentally passed through unescaped.
  @unquoted_chars MapSet.new(~c"ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789\\().+*:[]-")

  defp encode_arg(bin) do
    if contains_unsafe_byte?(bin) do
      # Deliberately does NOT inspect `bin`: this guard fires on exactly the
      # kind of value (arbitrary bytes) a credential can be, and the message
      # ends up in crash reports. Send such values as `{:literal, _}` instead.
      raise ArgumentError,
            "argument contains bytes that require a literal; send it as {:literal, _} instead"
    end

    if String.starts_with?(bin, "(") or unquoted_safe?(bin) do
      bin
    else
      ["\"", escape_quoted(bin), "\""]
    end
  end

  defp contains_unsafe_byte?(bin) do
    :binary.bin_to_list(bin) |> Enum.any?(&(&1 == ?\r or &1 == ?\n or &1 >= 0x80))
  end

  defp unquoted_safe?(<<>>), do: false

  defp unquoted_safe?(bin) do
    :binary.bin_to_list(bin) |> Enum.all?(&MapSet.member?(@unquoted_chars, &1))
  end

  defp escape_quoted(bin) do
    bin
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end
end
