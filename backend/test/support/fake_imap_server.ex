defmodule FakeImapServer do
  @moduledoc """
  Scripted fake IMAP server for testing the real socket client (Task 3),
  over real TLS sockets against the committed test fixtures
  (`test/fixtures/tls/{ca.pem,server.pem,server.key}`).

  Deliberately independent of `Valea.Mail.Imap.Wire` — the codec under
  test — so a bug shared between the harness and the client under test
  can't make a broken exchange look green. Client lines are read to CRLF
  with a small manual buffer loop; `:expect_literal` reads exactly N raw
  bytes without ever scanning them for structure.

  ## Unsolicited pushes and IDLE (task 14)

  A script is a sequence, not a request/response table, so a server that
  SPEAKS FIRST needs nothing new: `{:send, line}` pushes bytes whenever the
  script reaches it, which is how an IDLE conversation is written —
  `{:expect, ~r/IDLE$/, then: ["+ idling"]}`, then any number of `{:send,
  "* 3 EXISTS"}`, then `{:expect, "DONE", then: [...]}`.

  Two steps exist for the timing that IDLE testing needs:

    * `{:sleep, ms}` spaces pushes out in TIME, so a burst arrives as
      separate reads rather than one coalesced TLS record — the only way to
      test that a client DEBOUNCES rather than merely batches;
    * `:close` drops the connection mid-script, and `start_sequence/2`
      accepts the client's RECONNECT with a second script.
  """

  @fixtures_dir Path.expand("../fixtures/tls", __DIR__)
  @certfile Path.join(@fixtures_dir, "server.pem")
  @keyfile Path.join(@fixtures_dir, "server.key")

  # Bounds every blocking socket op (accept + recv) so a script bug or a
  # test that forgets to drive the client can't hang a test run forever.
  @default_timeout 5_000

  @typedoc "One step of a server script, executed in order against one accepted connection."
  @type step ::
          {:send, binary()}
          | {:send_raw, binary()}
          | {:expect, Regex.t() | binary(), then: [binary()]}
          | {:expect_command, Regex.t() | binary(), then: [binary()]}
          | {:expect_literal, non_neg_integer(), then: [binary()]}
          | {:sleep, non_neg_integer()}
          | :starttls
          | :close

  @type server :: %{port: :inet.port_number(), task: pid()}

  @doc """
  Starts a scripted server listening on an ephemeral loopback port and
  returns immediately with `%{port: port, task: pid}`. The server accepts
  exactly one connection (in a background process) and runs `script`
  against it.

  `tls: true` (default) presents the fixture CA-signed `localhost`
  certificate over `:ssl`; `tls: false` speaks plain TCP. Both read/write
  the same way — only the transport differs.
  """
  @spec start([step()], keyword()) :: server()
  def start(script, opts \\ []) when is_list(script), do: start_sequence([script], opts)

  @doc """
  Like `start/2`, but accepts N connections IN SEQUENCE — the i-th connection
  runs `Enum.at(scripts, i)`. Same ephemeral port for all of them, so a client
  that reconnects to `server.port` lands on the next script.

  This is how a RECONNECT is tested: script one ends in `:close`, script two
  is the exchange the client must perform on its second connection.
  `await/2` succeeds only once every script has run to completion, so a client
  that never comes back is a failure, not a pass.
  """
  @spec start_sequence([[step()]], keyword()) :: server()
  def start_sequence([_ | _] = scripts, opts \\ []) do
    tls? = Keyword.get(opts, :tls, true)
    # `certfile:`/`keyfile:` override the fixture CA-signed identity — the
    # self-signed `selfsigned.pem` pair plays a ProtonMail-Bridge-shaped
    # server for the cert-pinning tests.
    certfile = Keyword.get(opts, :certfile, @certfile)
    keyfile = Keyword.get(opts, :keyfile, @keyfile)
    parent = self()
    {listen_socket, port} = listen(tls?, certfile, keyfile)

    pid =
      spawn(fn ->
        result = accept_and_run_all(listen_socket, tls?, scripts, certfile, keyfile)
        close(listen_socket, tls?)
        send(parent, {__MODULE__, self(), result})
      end)

    %{port: port, task: pid}
  end

  @doc """
  Blocks until the server's script has run to completion, raising if any
  step failed (accept error, non-matching `:expect`, socket closed early,
  ...). This is the harness's assertion surface — call it after driving
  the client side of the exchange.
  """
  @spec await(server(), timeout()) :: :ok
  def await(server, timeout \\ @default_timeout)

  def await(%{task: pid}, timeout) do
    receive do
      {__MODULE__, ^pid, :ok} ->
        :ok

      {__MODULE__, ^pid, {:error, reason}} ->
        raise "fake IMAP server script failed: #{reason}"
    after
      timeout ->
        raise "fake IMAP server did not finish its script within #{timeout}ms"
    end
  end

  # -- listen --------------------------------------------------------------

  defp listen(true, certfile, keyfile) do
    opts = [
      :binary,
      packet: :raw,
      active: false,
      reuseaddr: true,
      certfile: certfile,
      keyfile: keyfile
    ]

    {:ok, socket} = :ssl.listen(0, opts)
    {:ok, {_addr, port}} = :ssl.sockname(socket)
    {socket, port}
  end

  defp listen(false, _certfile, _keyfile) do
    opts = [:binary, packet: :raw, active: false, reuseaddr: true]
    {:ok, socket} = :gen_tcp.listen(0, opts)
    {:ok, port} = :inet.port(socket)
    {socket, port}
  end

  # -- connection lifecycle -------------------------------------------------

  # Stops at the FIRST failing connection: a later script's accept would
  # otherwise block for the full timeout against a client that already gave up,
  # burying the real error behind a timeout message.
  defp accept_and_run_all(listen_socket, tls?, scripts, certfile, keyfile) do
    Enum.reduce_while(scripts, :ok, fn script, :ok ->
      case accept_and_run(listen_socket, tls?, script, certfile, keyfile) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp accept_and_run(listen_socket, tls?, script, certfile, keyfile) do
    case accept(listen_socket, tls?) do
      {:ok, socket} ->
        ctx = %{socket: socket, tls?: tls?, buffer: "", certfile: certfile, keyfile: keyfile}

        try do
          run_script(script, ctx)
          :ok
        rescue
          e -> {:error, Exception.message(e)}
        after
          close(socket, tls?)
        end

      {:error, reason} ->
        {:error, "accept failed: #{inspect(reason)}"}
    end
  end

  defp accept(listen_socket, true) do
    with {:ok, transport_socket} <- :ssl.transport_accept(listen_socket, @default_timeout) do
      :ssl.handshake(transport_socket, @default_timeout)
    end
  end

  defp accept(listen_socket, false), do: :gen_tcp.accept(listen_socket, @default_timeout)

  # -- script execution ------------------------------------------------------

  defp run_script([], _ctx), do: :ok

  defp run_script([{:send, line} | rest], ctx) do
    send_line(ctx, line)
    run_script(rest, ctx)
  end

  # Bytes verbatim — no CRLF appended. The step that can send HALF a response,
  # which is how a client's "response split across two reads" path is tested.
  defp run_script([{:send_raw, bytes} | rest], ctx) do
    send_bytes(ctx, bytes)
    run_script(rest, ctx)
  end

  defp run_script([{:expect, matcher, then: reply_lines} | rest], ctx) do
    {line, ctx} = read_line(ctx)
    assert_match!(matcher, line)
    Enum.each(reply_lines, &send_line(ctx, &1))
    run_script(rest, ctx)
  end

  defp run_script([{:expect_command, matcher, then: reply_lines} | rest], ctx) do
    {command, ctx} = read_command(ctx, "")
    assert_match!(matcher, command)
    Enum.each(reply_lines, &send_line(ctx, &1))
    run_script(rest, ctx)
  end

  defp run_script([{:expect_literal, n, then: reply_lines} | rest], ctx) do
    {_bytes, ctx} = read_exact(ctx, n)
    Enum.each(reply_lines, &send_line(ctx, &1))
    run_script(rest, ctx)
  end

  # Spaces the NEXT step out in time — so a burst of pushes arrives as
  # separate reads on the client rather than one coalesced record.
  defp run_script([{:sleep, ms} | rest], ctx) do
    Process.sleep(ms)
    run_script(rest, ctx)
  end

  # Expects the client's `<tag> STARTTLS`, answers `<tag> OK`, and upgrades
  # the plain socket to TLS with the fixture certificate — start the server
  # with `tls: false` to use it (same shape as `FakeSmtpServer`'s step).
  # Any bytes the client wrote after STARTTLS but before the handshake are
  # an injection, not protocol — the raise mirrors what the client under
  # test must ALSO refuse in the other direction.
  defp run_script([:starttls | rest], ctx) do
    {line, ctx} = read_line(ctx)

    tag =
      case String.split(line, " ", parts: 2) do
        [tag, "STARTTLS"] -> tag
        _other -> raise "expected client line <tag> STARTTLS, got: #{inspect(line)}"
      end

    send_line(ctx, tag <> " OK begin TLS")
    run_script(rest, upgrade(ctx))
  end

  defp run_script([:close | rest], ctx) do
    close(ctx.socket, ctx.tls?)
    run_script(rest, ctx)
  end

  defp upgrade(%{tls?: true}) do
    raise "STARTTLS issued on a connection that is already TLS"
  end

  defp upgrade(%{buffer: buffer}) when buffer != "" do
    raise "client bytes buffered across the STARTTLS upgrade: #{inspect(buffer)}"
  end

  defp upgrade(ctx) do
    opts = [:binary, packet: :raw, active: false, certfile: ctx.certfile, keyfile: ctx.keyfile]

    case :ssl.handshake(ctx.socket, opts, @default_timeout) do
      {:ok, tls_socket} -> %{ctx | socket: tls_socket, tls?: true}
      {:error, reason} -> raise "TLS upgrade failed: #{inspect(reason)}"
    end
  end

  defp assert_match!(%Regex{} = re, line) do
    unless Regex.match?(re, line) do
      raise "expected client line to match #{inspect(re)}, got: #{inspect(line)}"
    end
  end

  defp assert_match!(bin, line) when is_binary(bin) do
    unless bin == line do
      raise "expected client line #{inspect(bin)}, got: #{inspect(line)}"
    end
  end

  # Reads one logical command that MAY carry synchronizing literals,
  # reassembling the argument bytes inline. Whenever a physical line fragment
  # ends in a `{N}` marker it sends a `+` continuation, reads exactly N raw
  # bytes (never scanned for structure), then reads the next fragment — so a
  # LOGIN sent as `A1 LOGIN {4}\r\nuser {4}\r\npass` reassembles to
  # `A1 LOGIN user pass`. A literal-free command is a single read_line.
  defp read_command(ctx, acc) do
    {fragment, ctx} = read_line(ctx)

    case trailing_literal(fragment) do
      {n, head} ->
        send_line(ctx, "+ ready for literal")
        {bytes, ctx} = read_exact(ctx, n)
        read_command(ctx, acc <> head <> bytes)

      :none ->
        {acc <> fragment, ctx}
    end
  end

  defp trailing_literal(fragment) do
    case Regex.run(~r/^(.*)\{(\d+)\}$/s, fragment) do
      [_, head, digits] -> {String.to_integer(digits), head}
      nil -> :none
    end
  end

  # -- byte-exact read buffer (independent of Wire) ---------------------------

  defp read_line(ctx) do
    case :binary.match(ctx.buffer, "\r\n") do
      {idx, _len} ->
        line = binary_part(ctx.buffer, 0, idx)
        rest_offset = idx + 2
        rest = binary_part(ctx.buffer, rest_offset, byte_size(ctx.buffer) - rest_offset)
        {line, %{ctx | buffer: rest}}

      :nomatch ->
        ctx |> recv_more!() |> read_line()
    end
  end

  defp read_exact(ctx, n) do
    if byte_size(ctx.buffer) >= n do
      bytes = binary_part(ctx.buffer, 0, n)
      rest = binary_part(ctx.buffer, n, byte_size(ctx.buffer) - n)
      {bytes, %{ctx | buffer: rest}}
    else
      ctx |> recv_more!() |> read_exact(n)
    end
  end

  defp recv_more!(ctx) do
    case recv(ctx.socket, ctx.tls?) do
      {:ok, data} -> %{ctx | buffer: ctx.buffer <> data}
      {:error, reason} -> raise "failed to read from client: #{inspect(reason)}"
    end
  end

  defp recv(socket, true), do: :ssl.recv(socket, 0, @default_timeout)
  defp recv(socket, false), do: :gen_tcp.recv(socket, 0, @default_timeout)

  # -- write ------------------------------------------------------------------

  defp send_line(ctx, line), do: send_bytes(ctx, line <> "\r\n")

  defp send_bytes(ctx, bytes) do
    case send_data(ctx.socket, ctx.tls?, bytes) do
      :ok -> :ok
      {:error, reason} -> raise "send to client failed: #{inspect(reason)}"
    end
  end

  defp send_data(socket, true, data), do: :ssl.send(socket, data)
  defp send_data(socket, false, data), do: :gen_tcp.send(socket, data)

  defp close(socket, true), do: :ssl.close(socket)
  defp close(socket, false), do: :gen_tcp.close(socket)
end
