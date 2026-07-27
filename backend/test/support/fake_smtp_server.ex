defmodule FakeSmtpServer do
  @moduledoc """
  Scripted fake SMTP submission server for testing the real socket client
  (`Valea.Mail.SmtpClient`), over real TLS sockets against the same committed
  fixtures `FakeImapServer` uses (`test/fixtures/tls/{ca.pem,server.pem,server.key}`).

  Same role and shape as `FakeImapServer`, one protocol down the hall:
  a `:gen_tcp`/`:ssl` listener on an ephemeral loopback port driven by an
  ordered script, with a byte-exact manual read buffer (no `:packet, :line`,
  no shared codec with the client under test — a bug shared between the
  harness and the code under test can't make a broken exchange look green).

  ## Two security modes, two scripts

  Implicit TLS (465) starts with `:implicit_tls` and speaks TLS from the
  first byte — exactly ONE `EHLO`, `STARTTLS` never appears:

      [:implicit_tls,
       {:greet, "220 ok"},
       {:expect, "EHLO", "250 AUTH PLAIN"},
       {:expect, "AUTH PLAIN", "235 ok"},
       ...]

  STARTTLS (587) starts in plaintext and upgrades mid-session. AUTH is
  advertised ONLY in the post-upgrade `EHLO` reply, and `assert_auth_allowed!/1`
  fails the script on ANY `AUTH` command that arrives without TLS or without a
  second `EHLO` observed after the upgrade (RFC 3207: pre-TLS EHLO extensions
  MUST be discarded):

      [{:greet, "220 ok"},
       {:expect, "EHLO", "250-x\\r\\n250 STARTTLS"},
       :starttls,
       {:expect, "EHLO", "250 AUTH PLAIN"},
       {:expect, "AUTH PLAIN", "235 ok"},
       ...]

  ## The observation log

  `await/2` returns the ordered log of everything the server observed:
  client command lines as binaries, `{:tls, :implicit | :starttls}` when a TLS
  layer came up, and `{:data, payload}` for a DATA payload read through to its
  terminating dot (raw, still dot-stuffed — that is what makes the stuffing
  golden a real wire assertion). That log is the ordering assertion surface:
  "TLS first", "exactly one EHLO", "no STARTTLS on the wire", "never saw DATA".
  """

  @fixtures_dir Path.expand("../fixtures/tls", __DIR__)
  @certfile Path.join(@fixtures_dir, "server.pem")
  @keyfile Path.join(@fixtures_dir, "server.key")

  # Bounds every blocking socket op (accept + recv) so a script bug or a test
  # that forgets to drive the client can't hang a test run forever.
  @default_timeout 5_000

  @typedoc "One step of a server script, executed in order against one accepted connection."
  @type step ::
          :implicit_tls
          | {:greet, binary()}
          | {:expect, binary() | Regex.t(), binary()}
          | :starttls
          | {:expect_rcpt, %{binary() => binary()}}
          | :expect_quit
          | {:data_reply, binary()}
          | :drop_after_data
          | {:drop_after_bytes, non_neg_integer()}
          | :close

  @typedoc "One observation: a client command line, a TLS layer coming up, or a DATA payload."
  @type log_entry ::
          binary()
          | {:tls, :implicit | :starttls}
          | {:data, binary()}
          | {:data_partial, non_neg_integer()}

  @type server :: %{port: :inet.port_number(), task: pid()}

  @doc """
  Starts a scripted server on an ephemeral loopback port and returns
  immediately with `%{port: port, task: pid}`. The server accepts exactly one
  connection (in a background process) and runs `script` against it.

  A leading `:implicit_tls` step makes the listener a TLS listener (465-style);
  without it the listener is plain TCP and TLS only arrives via `:starttls`.
  """
  @spec start([step()]) :: server()
  def start(script) when is_list(script) do
    implicit_tls? = match?([:implicit_tls | _], script)
    parent = self()
    {listen_socket, port} = listen(implicit_tls?)

    pid =
      spawn(fn ->
        result = accept_and_run(listen_socket, implicit_tls?, script)
        send(parent, {__MODULE__, self(), result})
      end)

    %{port: port, task: pid}
  end

  @doc """
  Blocks until the server's script has run to completion and returns its
  observation log (see the moduledoc), raising if any step failed (accept
  error, non-matching `:expect`, an `AUTH` outside TLS, socket closed early,
  ...). This is the harness's assertion surface — call it after driving the
  client side of the exchange.
  """
  @spec await(server(), timeout()) :: [log_entry()]
  def await(server, timeout \\ @default_timeout)

  def await(%{task: pid}, timeout) do
    receive do
      {__MODULE__, ^pid, {:ok, log}} ->
        log

      {__MODULE__, ^pid, {:error, reason, log}} ->
        raise "fake SMTP server script failed: #{reason}\nobserved: #{inspect(log)}"
    after
      timeout ->
        raise "fake SMTP server did not finish its script within #{timeout}ms"
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

  defp accept_and_run(listen_socket, implicit_tls?, script) do
    case accept(listen_socket, implicit_tls?) do
      {:ok, socket} ->
        ctx = %{
          socket: socket,
          tls?: implicit_tls?,
          buffer: "",
          closed?: false,
          ehlo_after_tls?: false,
          log: if(implicit_tls?, do: [{:tls, :implicit}], else: [])
        }

        run_guarded(script, ctx)

      {:error, reason} ->
        {:error, "accept failed: #{inspect(reason)}", []}
    end
  end

  # The log has to survive a mid-script failure — it is the most useful thing
  # a failing test can be shown — so it rides in the process dictionary of
  # this short-lived, single-connection server process rather than being
  # threaded back out of a raise.
  defp run_guarded(script, ctx) do
    Process.put(__MODULE__, ctx.log)

    try do
      final = run_script(script, ctx)
      {:ok, final.log}
    rescue
      e -> {:error, Exception.message(e), Process.get(__MODULE__, [])}
    after
      close(ctx)
    end
  end

  defp accept(listen_socket, true) do
    with {:ok, transport_socket} <- :ssl.transport_accept(listen_socket, @default_timeout) do
      :ssl.handshake(transport_socket, @default_timeout)
    end
  end

  defp accept(listen_socket, false), do: :gen_tcp.accept(listen_socket, @default_timeout)

  # -- script execution ------------------------------------------------------

  defp run_script([], ctx), do: ctx

  defp run_script([:implicit_tls | rest], ctx), do: run_script(rest, ctx)

  defp run_script([{:greet, line} | rest], ctx) do
    send_line(ctx, line)
    run_script(rest, ctx)
  end

  defp run_script([{:expect, matcher, reply} | rest], ctx) do
    {line, ctx} = read_line(ctx)
    ctx = observe(ctx, line)
    assert_match!(matcher, line)
    assert_auth_allowed!(ctx, line)
    send_line(ctx, reply)
    run_script(rest, note_ehlo(ctx, line))
  end

  defp run_script([:starttls | rest], ctx) do
    {line, ctx} = read_line(ctx)
    ctx = observe(ctx, line)
    assert_match!("STARTTLS", line)
    send_line(ctx, "220 ready to start TLS")
    run_script(rest, upgrade(ctx))
  end

  # Reads exactly `map_size(replies)` RCPT commands — one per address the
  # client is expected to offer — replying per address. A client that offers
  # fewer blocks here (and fails on the read timeout); one that offers more
  # trips the NEXT step's matcher on the leftover RCPT line.
  defp run_script([{:expect_rcpt, replies} | rest], ctx) do
    ctx =
      Enum.reduce(1..map_size(replies)//1, ctx, fn _i, ctx ->
        {line, ctx} = read_line(ctx)
        ctx = observe(ctx, line)
        send_line(ctx, rcpt_reply!(replies, line))
        ctx
      end)

    run_script(rest, ctx)
  end

  # `QUIT` is expected but deliberately NOT answered: the client sends it and
  # closes without waiting for the 221 (by then the outcome is already
  # decided — see `SmtpClient.quit/1`), so a scripted reply would race the
  # close and fail the script for no reason.
  defp run_script([:expect_quit | rest], ctx) do
    {line, ctx} = read_line(ctx)
    ctx = observe(ctx, line)
    assert_match!("QUIT", line)
    run_script(rest, close(ctx))
  end

  defp run_script([{:data_reply, reply} | rest], ctx) do
    {payload, ctx} = read_data(ctx)
    ctx = observe(ctx, {:data, payload})
    send_line(ctx, reply)
    run_script(rest, ctx)
  end

  defp run_script([:drop_after_data | rest], ctx) do
    {payload, ctx} = read_data(ctx)
    ctx = ctx |> observe({:data, payload}) |> close()
    run_script(rest, ctx)
  end

  # Reads at least `n` payload bytes, then drops the connection without ever
  # replying — the client is mid-write (or has just finished the body and is
  # writing the terminating dot). Both are post-354 failures.
  defp run_script([{:drop_after_bytes, n} | rest], ctx) do
    ctx = read_at_least(ctx, n)
    ctx = ctx |> observe({:data_partial, byte_size(ctx.buffer)}) |> close()
    run_script(rest, ctx)
  end

  defp run_script([:close | rest], ctx), do: run_script(rest, close(ctx))

  defp observe(ctx, entry) do
    log = ctx.log ++ [entry]
    Process.put(__MODULE__, log)
    %{ctx | log: log}
  end

  defp note_ehlo(ctx, line) do
    if ctx.tls? and String.starts_with?(line, "EHLO") do
      %{ctx | ehlo_after_tls?: true}
    else
      ctx
    end
  end

  defp upgrade(%{tls?: true}) do
    raise "STARTTLS issued on a connection that is already TLS"
  end

  defp upgrade(ctx) do
    opts = [:binary, packet: :raw, active: false, certfile: @certfile, keyfile: @keyfile]

    case :ssl.handshake(ctx.socket, opts, @default_timeout) do
      {:ok, tls_socket} ->
        %{ctx | socket: tls_socket, tls?: true} |> observe({:tls, :starttls})

      {:error, reason} ->
        raise "TLS upgrade failed: #{inspect(reason)}"
    end
  end

  # The whole point of the STARTTLS ordering: a credential must never be
  # offered in the clear, and the mechanism it is offered with must have been
  # advertised by the POST-upgrade EHLO (RFC 3207 — pre-TLS extensions are
  # discarded). Enforced on every AUTH line regardless of what the script's
  # matcher says, so a script can't accidentally bless a plaintext AUTH.
  defp assert_auth_allowed!(ctx, "AUTH" <> _rest) do
    cond do
      not ctx.tls? -> raise "client issued AUTH before the TLS layer was up"
      not ctx.ehlo_after_tls? -> raise "client issued AUTH without an EHLO after the TLS upgrade"
      true -> :ok
    end
  end

  defp assert_auth_allowed!(_ctx, _line), do: :ok

  defp assert_match!(%Regex{} = re, line) do
    unless Regex.match?(re, line) do
      raise "expected client line to match #{inspect(re)}, got: #{inspect(line)}"
    end
  end

  defp assert_match!(prefix, line) when is_binary(prefix) do
    unless String.starts_with?(line, prefix) do
      raise "expected client line starting with #{inspect(prefix)}, got: #{inspect(line)}"
    end
  end

  # `RCPT TO:<addr>` → the scripted reply for `addr`; an address the script
  # never mentioned is a script failure, not a silent 250.
  defp rcpt_reply!(replies, line) do
    case Regex.run(~r/^RCPT TO:<([^>]*)>/i, line) do
      [_, addr] ->
        case Map.fetch(replies, addr) do
          {:ok, reply} ->
            reply

          :error ->
            raise "unexpected RCPT recipient #{inspect(addr)} (scripted: #{inspect(Map.keys(replies))})"
        end

      nil ->
        raise "expected a RCPT TO line, got: #{inspect(line)}"
    end
  end

  # -- byte-exact read buffer -------------------------------------------------

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

  # Reads through the RFC 5321 terminator (`CRLF "." CRLF`), returning the raw
  # payload up to and including the final body CRLF — still dot-stuffed,
  # exactly as it arrived on the wire.
  defp read_data(ctx) do
    case :binary.match(ctx.buffer, "\r\n.\r\n") do
      {idx, _len} ->
        payload = binary_part(ctx.buffer, 0, idx + 2)
        rest_offset = idx + 5
        rest = binary_part(ctx.buffer, rest_offset, byte_size(ctx.buffer) - rest_offset)
        {payload, %{ctx | buffer: rest}}

      :nomatch ->
        ctx |> recv_more!() |> read_data()
    end
  end

  defp read_at_least(ctx, n) do
    if byte_size(ctx.buffer) >= n, do: ctx, else: ctx |> recv_more!() |> read_at_least(n)
  end

  defp recv_more!(ctx) do
    case recv(ctx) do
      {:ok, data} -> %{ctx | buffer: ctx.buffer <> data}
      {:error, reason} -> raise "failed to read from client: #{inspect(reason)}"
    end
  end

  defp recv(%{tls?: true, socket: socket}), do: :ssl.recv(socket, 0, @default_timeout)
  defp recv(%{socket: socket}), do: :gen_tcp.recv(socket, 0, @default_timeout)

  # -- write / close ------------------------------------------------------------

  defp send_line(ctx, line) do
    case send_data(ctx, line <> "\r\n") do
      :ok -> :ok
      {:error, reason} -> raise "send to client failed: #{inspect(reason)}"
    end
  end

  defp send_data(%{tls?: true, socket: socket}, data), do: :ssl.send(socket, data)
  defp send_data(%{socket: socket}, data), do: :gen_tcp.send(socket, data)

  defp close(%{closed?: true} = ctx), do: ctx

  defp close(ctx) do
    if ctx.tls?, do: :ssl.close(ctx.socket), else: :gen_tcp.close(ctx.socket)
    %{ctx | closed?: true}
  end
end
