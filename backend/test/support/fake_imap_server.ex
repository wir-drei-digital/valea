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
          | {:expect, Regex.t() | binary(), then: [binary()]}
          | {:expect_literal, non_neg_integer(), then: [binary()]}
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
  def start(script, opts \\ []) when is_list(script) do
    tls? = Keyword.get(opts, :tls, true)
    parent = self()
    {listen_socket, port} = listen(tls?)

    pid =
      spawn(fn ->
        result = accept_and_run(listen_socket, tls?, script)
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

  defp listen(true) do
    opts = [
      :binary,
      packet: :raw,
      active: false,
      reuseaddr: true,
      certfile: @certfile,
      keyfile: @keyfile
    ]

    {:ok, socket} = :ssl.listen(0, opts)
    {:ok, {_addr, port}} = :ssl.sockname(socket)
    {socket, port}
  end

  defp listen(false) do
    opts = [:binary, packet: :raw, active: false, reuseaddr: true]
    {:ok, socket} = :gen_tcp.listen(0, opts)
    {:ok, port} = :inet.port(socket)
    {socket, port}
  end

  # -- connection lifecycle -------------------------------------------------

  defp accept_and_run(listen_socket, tls?, script) do
    case accept(listen_socket, tls?) do
      {:ok, socket} ->
        try do
          run_script(script, %{socket: socket, tls?: tls?, buffer: ""})
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

  defp run_script([{:expect, matcher, then: reply_lines} | rest], ctx) do
    {line, ctx} = read_line(ctx)
    assert_match!(matcher, line)
    Enum.each(reply_lines, &send_line(ctx, &1))
    run_script(rest, ctx)
  end

  defp run_script([{:expect_literal, n, then: reply_lines} | rest], ctx) do
    {_bytes, ctx} = read_exact(ctx, n)
    Enum.each(reply_lines, &send_line(ctx, &1))
    run_script(rest, ctx)
  end

  defp run_script([:close | rest], ctx) do
    close(ctx.socket, ctx.tls?)
    run_script(rest, ctx)
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

  defp send_line(ctx, line) do
    case send_data(ctx.socket, ctx.tls?, line <> "\r\n") do
      :ok -> :ok
      {:error, reason} -> raise "send to client failed: #{inspect(reason)}"
    end
  end

  defp send_data(socket, true, data), do: :ssl.send(socket, data)
  defp send_data(socket, false, data), do: :gen_tcp.send(socket, data)

  defp close(socket, true), do: :ssl.close(socket)
  defp close(socket, false), do: :gen_tcp.close(socket)
end
