defmodule FakeFeedServer do
  @moduledoc """
  Scripted fake HTTP(S) feed server for testing `Valea.Calendar.Fetch` —
  the `FakeImapServer` pattern (calendar spec §Testing "Fetch"), over plain
  TCP for most scenarios plus real TLS against the committed fixtures
  (`test/fixtures/tls/{ca.pem,server.pem,server.key}`).

  A script is a list of EXCHANGES, one per accepted connection, served in
  order: every scripted response should carry `connection: close` (the
  `response/3`/`chunked_response/2` helpers always do), so the client under
  test opens a fresh connection per redirect hop and scripts stay linear.

  Deliberately independent of `:httpc` (the stack under test): request
  heads are read to the bare `\\r\\n\\r\\n` boundary with a manual buffer
  loop and matched by regex; responses are raw scripted bytes, never built
  from any shared HTTP encoder.
  """

  @fixtures_dir Path.expand("../fixtures/tls", __DIR__)
  @certfile Path.join(@fixtures_dir, "server.pem")
  @keyfile Path.join(@fixtures_dir, "server.key")

  # Bounds every blocking socket op (accept + recv) so a script bug or a
  # test that forgets to drive the client can't hang a test run forever.
  @default_timeout 5_000

  @typedoc """
  One exchange, executed against one accepted connection:

    * `:expect` (optional) — regex the raw request head (request line +
      headers) must match, asserted before responding.
    * `:respond` — raw response bytes (iodata), or
      `{:tolerate_abort, iodata}` (send errors after the head are fine —
      the client aborting mid-body is exactly what an oversize test
      expects), or `:stall` (read the request, answer nothing, wait for
      the client to give up), or `:close` (read the request, close), or
      `:handshake_failure` (TLS only: the client is EXPECTED to abort the
      handshake — e.g. it doesn't trust the fixture CA — so a failed
      accept IS this exchange succeeding).
  """
  @type exchange :: %{
          optional(:expect) => Regex.t(),
          :respond =>
            iodata() | {:tolerate_abort, iodata()} | :stall | :close | :handshake_failure
        }

  @type server :: %{port: :inet.port_number(), task: pid()}

  @doc """
  Starts a scripted server on an ephemeral loopback port and returns
  immediately with `%{port: port, task: pid}`. Connections are accepted
  sequentially, one per exchange. `tls: true` presents the fixture
  CA-signed `localhost` certificate over `:ssl`; default is plain TCP.
  """
  @spec start([exchange()], keyword()) :: server()
  def start(exchanges, opts \\ []) when is_list(exchanges) do
    tls? = Keyword.get(opts, :tls, false)
    parent = self()
    {listen_socket, port} = listen(tls?)

    pid =
      spawn(fn ->
        result = run_exchanges(listen_socket, tls?, exchanges)
        send(parent, {__MODULE__, self(), result})
      end)

    %{port: port, task: pid}
  end

  @doc """
  Blocks until the whole script has run, raising if any step failed
  (accept error, non-matching `:expect`, send failure outside
  `:tolerate_abort`, ...). Call after driving the client side.
  """
  @spec await(server(), timeout()) :: :ok
  def await(server, timeout \\ @default_timeout)

  def await(%{task: pid}, timeout) do
    receive do
      {__MODULE__, ^pid, :ok} ->
        :ok

      {__MODULE__, ^pid, {:error, reason}} ->
        raise "fake feed server script failed: #{reason}"
    after
      timeout ->
        raise "fake feed server did not finish its script within #{timeout}ms"
    end
  end

  @doc """
  Raw HTTP/1.1 response bytes for `status` with the given extra header
  lines (`"etag: \\"v1\\""`-style strings), a correct `content-length`,
  and `connection: close`.
  """
  @spec response(pos_integer(), [String.t()], binary()) :: binary()
  def response(status, headers, body \\ "") when is_list(headers) and is_binary(body) do
    head_lines =
      ["HTTP/1.1 #{status} #{reason_phrase(status)}"] ++
        headers ++
        ["content-length: #{byte_size(body)}", "connection: close"]

    Enum.join(head_lines, "\r\n") <> "\r\n\r\n" <> body
  end

  @doc """
  Raw HTTP/1.1 `200` response bytes using chunked transfer-encoding, one
  chunk per element of `chunks` — the shape a streamed-body-cap test needs
  (no `content-length` for the client to reject early on).
  """
  @spec chunked_response([String.t()], [binary()]) :: binary()
  def chunked_response(headers, chunks) when is_list(headers) and is_list(chunks) do
    head_lines =
      ["HTTP/1.1 200 OK"] ++
        headers ++
        ["transfer-encoding: chunked", "connection: close"]

    body =
      Enum.map_join(chunks, fn chunk ->
        Integer.to_string(byte_size(chunk), 16) <> "\r\n" <> chunk <> "\r\n"
      end) <> "0\r\n\r\n"

    Enum.join(head_lines, "\r\n") <> "\r\n\r\n" <> body
  end

  defp reason_phrase(200), do: "OK"
  defp reason_phrase(302), do: "Found"
  defp reason_phrase(304), do: "Not Modified"
  defp reason_phrase(404), do: "Not Found"
  defp reason_phrase(500), do: "Internal Server Error"
  defp reason_phrase(_status), do: "Status"

  # -- listen ----------------------------------------------------------------

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

  # -- exchange loop ---------------------------------------------------------

  defp run_exchanges(_listen_socket, _tls?, []), do: :ok

  defp run_exchanges(listen_socket, tls?, [%{respond: :handshake_failure} | rest]) do
    case accept(listen_socket, tls?) do
      {:ok, socket} ->
        close(socket, tls?)
        {:error, "expected the client to abort the TLS handshake, but it completed"}

      {:error, _reason} ->
        # The client refused our certificate — exactly what this exchange
        # scripted.
        run_exchanges(listen_socket, tls?, rest)
    end
  end

  defp run_exchanges(listen_socket, tls?, [exchange | rest]) do
    case accept(listen_socket, tls?) do
      {:ok, socket} ->
        result =
          try do
            run_exchange(exchange, %{socket: socket, tls?: tls?, buffer: ""})
            :ok
          rescue
            e -> {:error, Exception.message(e)}
          after
            close(socket, tls?)
          end

        case result do
          :ok -> run_exchanges(listen_socket, tls?, rest)
          {:error, _} = error -> error
        end

      {:error, reason} ->
        {:error, "accept failed: #{inspect(reason)}"}
    end
  end

  defp run_exchange(exchange, ctx) do
    {head, ctx} = read_head(ctx)

    if re = exchange[:expect] do
      unless Regex.match?(re, head) do
        raise "expected request head to match #{inspect(re)}, got: #{inspect(head)}"
      end
    end

    case Map.fetch!(exchange, :respond) do
      :close ->
        :ok

      :stall ->
        # Answer nothing; hold the connection until the client gives up
        # (its timeout cancels the request and closes the socket).
        await_client_close(ctx)

      {:tolerate_abort, bytes} ->
        _ = send_data(ctx.socket, ctx.tls?, bytes)
        :ok

      bytes ->
        case send_data(ctx.socket, ctx.tls?, bytes) do
          :ok -> :ok
          {:error, reason} -> raise "send to client failed: #{inspect(reason)}"
        end
    end
  end

  defp await_client_close(ctx) do
    case recv(ctx.socket, ctx.tls?, @default_timeout * 2) do
      {:ok, _more} -> await_client_close(ctx)
      {:error, _closed_or_timeout} -> :ok
    end
  end

  # -- request-head reader (independent of any HTTP codec) -------------------

  defp read_head(ctx) do
    case :binary.match(ctx.buffer, "\r\n\r\n") do
      {idx, _len} ->
        head = binary_part(ctx.buffer, 0, idx)
        rest_offset = idx + 4
        rest = binary_part(ctx.buffer, rest_offset, byte_size(ctx.buffer) - rest_offset)
        {head, %{ctx | buffer: rest}}

      :nomatch ->
        ctx |> recv_more!() |> read_head()
    end
  end

  defp recv_more!(ctx) do
    case recv(ctx.socket, ctx.tls?, @default_timeout) do
      {:ok, data} -> %{ctx | buffer: ctx.buffer <> data}
      {:error, reason} -> raise "failed to read from client: #{inspect(reason)}"
    end
  end

  defp accept(listen_socket, true) do
    with {:ok, transport_socket} <- :ssl.transport_accept(listen_socket, @default_timeout) do
      :ssl.handshake(transport_socket, @default_timeout)
    end
  end

  defp accept(listen_socket, false), do: :gen_tcp.accept(listen_socket, @default_timeout)

  defp recv(socket, true, timeout), do: :ssl.recv(socket, 0, timeout)
  defp recv(socket, false, timeout), do: :gen_tcp.recv(socket, 0, timeout)

  defp send_data(socket, true, data), do: :ssl.send(socket, data)
  defp send_data(socket, false, data), do: :gen_tcp.send(socket, data)

  defp close(socket, true), do: :ssl.close(socket)
  defp close(socket, false), do: :gen_tcp.close(socket)
end
