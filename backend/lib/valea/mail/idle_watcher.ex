defmodule Valea.Mail.IdleWatcher do
  @moduledoc """
  One IMAP IDLE watcher per account (mail full-client plan, M5 task 14): it
  holds a connection of its OWN open on `INBOX`, waits for the server to
  announce a change, and pokes its `Valea.Mail.Engine` into running a sync
  pass. It never reads, writes or reconciles anything itself — the pass does
  all of that, exactly as it does when the poll timer fires.

  ## What it is FOR (and the invariant that follows)

  IDLE is an ACCELERATOR on top of the poll loop, never a replacement for it.
  The Engine's timer keeps ticking at the account's configured interval
  whether or not a watcher exists, which is what makes every failure mode
  here cheap: a dropped connection, a server that refuses IDLE, a swallowed
  notification during a re-issue — each costs *latency* (up to one poll
  interval), never a lost message. That invariant is why every failure below
  is logged at `:debug` and answered with a backoff rather than escalated:
  nothing a user can see is broken when IDLE stops working.

  ## Lifecycle: engine-supervised, credential-coupled

  The Engine starts one of these under a `DynamicSupervisor` it owns (see
  `Valea.Mail.Engine`, §IMAP IDLE) whenever the account passes the same gate a
  sync pass does — active, configured, credentialed, not sticky-blocked — and
  terminates it when that stops being true (`auth_failed`, `mailbox_replaced`)
  or when a new credential arrives (the watcher is REBUILT, since the
  connection it is holding authenticated with the old secret). The Engine
  dying takes the whole thing down through the supervisor's link.

  The intervening supervisor is the point: a watcher that crashes must not
  reach the Engine, whose in-RAM credential nothing else holds a copy of. Its
  child spec is `restart: :transient` — an abnormal exit is restarted
  (`:one_for_one`, since there is nothing else in that supervisor to restart
  alongside it), while a `:normal` stop is FINAL. Both halves matter: the
  no-IDLE exit below must not be retried, and a genuine bug must not take the
  account's sync down with it.

  This process deliberately does NOT trap exits. It spends most of its life
  blocked in a socket read, and the Engine terminates it from inside its own
  loop (a supervisor call that waits for the child to die) — a trapping
  watcher would only handle that shutdown after its read returned, deadlocking
  the Engine for up to 25 minutes. Untrapped, `Process.exit(:shutdown)` ends
  it instantly, mid-read; the cost is skipping the `LOGOUT` on that one path,
  and the server reaps the connection when the socket closes.

  ## The conversation

  `connect/3` (its own connection, verified TLS, same `connect_opts` the
  Engine hands every worker) → `capabilities`-gated `supports?(conn, :idle)`
  → `examine/2` on `INBOX` → `idle_start/1`. Then, in a loop:

    * `idle_await/3` until the server reports untagged activity;
    * `EXISTS`/`EXPUNGE`/`FETCH` (not a `* OK` keepalive) → ONE debounced
      sync-pass trigger;
    * at the re-issue deadline, `idle_done/2` → `idle_start/1` again.

  `examine/2`, not `select/2`: the watcher needs the selected state IDLE
  requires and nothing more, and a read-only EXAMINE cannot disturb `\\Recent`
  or any other server state. Nothing on this connection can mutate the
  mailbox — by construction, not by discipline.

  INBOX only. A per-folder IDLE needs one connection per folder (IMAP has no
  multi-folder IDLE without the NOTIFY extension), and INBOX is where mail
  arrives; every other folder keeps the poll interval it always had.

  ## Debounce

  A single arriving message can produce several untagged lines, and a server
  delivering a batch produces one per message. So the first change event does
  not trigger anything on its own: the watcher keeps reading in
  500ms slices until a slice comes back quiet (or 5s of
  burst has elapsed), and only then fires ONE trigger. A burst of ten EXISTS
  lines therefore yields one pass, not ten.

  The Engine's own single-flighting is the second line of defence, not the
  first: it would collapse concurrent triggers, but a trigger arriving just
  after a pass finished would start another one, so the coalescing has to
  happen here.

  ## Re-issue

  RFC 2177 tells a client to re-issue IDLE periodically and servers to allow
  at least 29 minutes; the deadline here is 25, leaving room for a slow
  handshake. The deadline is enforced as the `idle_await/3` timeout rather
  than a `Process.send_after/3` timer on purpose: this process is blocked in
  a socket read for the whole window, so a timer message could not be handled
  until the read returned anyway — the read's own deadline IS the timer.

  Events that arrive inside the `DONE`→completion window are reported by
  `idle_done/2` and trigger a pass just like any other; they are not lost to
  the re-issue.

  ## Reconnect

  Any transport failure — a dead socket, a refused IDLE, a server that ended
  the IDLE itself — disconnects and schedules a reconnect, doubling from
  1s to a 5-minute ceiling and resetting on every
  successful connect. A missing IDLE capability is the one failure that is
  not retried at all: it cannot change while this connection's server does,
  so the watcher stops `:normal` and the account simply stays on its poll
  interval.

  ## Credential

  Handed in at start as the Engine's own zero-arity closure (`fn -> secret
  end`) — never asked for later. Two reasons: a watcher that called back into
  the Engine could deadlock against the Engine terminating it, and a rotated
  credential has to invalidate the connection this process is *holding*, which
  a restart does and a re-read would not. The secret is materialized only at
  the `connect/3` boundary and, redacted, inside a `:debug` log's own closure
  — never stored as a string, never written anywhere.
  """

  use GenServer, restart: :transient

  require Logger

  alias Valea.Mail.Engine
  alias Valea.Mail.Redact

  @inbox "INBOX"

  # RFC 2177: re-issue before the server's cutoff (>= 29 minutes).
  @reissue_ms 25 * 60 * 1_000

  # Quiet slice that ends a burst, and the cap on how long one burst may hold
  # the trigger back.
  @debounce_ms 500
  @debounce_max_ms 5_000

  @backoff_initial_ms 1_000
  @backoff_max_ms 300_000

  @typedoc """
  Start args. `engine` is the owning Engine's pid (never a slug: this process
  is a child of that Engine's own supervisor, so the pid cannot dangle, and
  routing by name could reach a DIFFERENT generation's Engine for the same
  account). `reissue_ms`/`debounce_ms`/`backoff_ms` are overridable so a test
  can drive the whole conversation in milliseconds; production passes none of
  them.
  """
  @type args :: %{
          required(:account) => String.t(),
          required(:engine) => pid(),
          required(:settings) => Valea.Mail.Settings.t(),
          required(:transport) => module(),
          required(:credential) => (-> String.t()) | nil,
          optional(:connect_opts) => keyword(),
          optional(:reissue_ms) => pos_integer(),
          optional(:debounce_ms) => non_neg_integer(),
          optional(:backoff_ms) => pos_integer()
        }

  @spec start_link(args()) :: GenServer.on_start()
  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  # -- GenServer -------------------------------------------------------------

  @impl true
  def init(args) do
    backoff_initial = Map.get(args, :backoff_ms, @backoff_initial_ms)

    state = %{
      account: args.account,
      engine: args.engine,
      settings: args.settings,
      transport: args.transport,
      credential: args.credential,
      connect_opts: Map.get(args, :connect_opts, []),
      reissue_ms: Map.get(args, :reissue_ms, @reissue_ms),
      debounce_ms: Map.get(args, :debounce_ms, @debounce_ms),
      backoff_initial_ms: backoff_initial,
      backoff_ms: backoff_initial,
      conn: nil,
      idle: nil,
      deadline: nil
    }

    # Connecting is deferred out of `init/1`: the Engine starts this child from
    # inside its own loop, so init must return immediately.
    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state), do: open(state)

  def handle_continue(:await, state) do
    remaining = max(state.deadline - now_ms(), 0)

    case call(state, :idle_await, [state.conn, state.idle, remaining]) do
      # Deadline with nothing pending — re-issue (RFC 2177).
      {:ok, [], idle} ->
        reissue(%{state | idle: idle})

      {:ok, events, idle} ->
        state = %{state | idle: idle}

        if changed?(events) do
          debounce_and_trigger(state)
        else
          # A keepalive (`* OK Still here`) or another uninteresting untagged
          # line: keep waiting on the SAME deadline, never sync.
          {:noreply, state, {:continue, :await}}
        end

      {:error, reason} ->
        {:noreply, disconnect_and_retry(state, "await failed", reason)}
    end
  end

  @impl true
  def handle_info(:reconnect, state), do: open(state)

  @impl true
  def terminate(_reason, state), do: logout(state)

  # -- connect / capability gate ---------------------------------------------

  defp open(state) do
    case connect_and_examine(state) do
      {:ok, conn} ->
        start_idle(%{state | conn: conn, backoff_ms: state.backoff_initial_ms})

      {:no_idle, conn} ->
        # The one permanent failure: a server without the IDLE capability
        # cannot grow one under this connection, so retrying would be a
        # pointless reconnect loop. `restart: :transient` makes this stop
        # final; the account keeps its poll interval. `terminate/2` logs out.
        log(state, "server does not advertise IDLE — watcher stopping")
        {:stop, :normal, %{state | conn: conn}}

      {:error, reason} ->
        {:noreply, retry(%{state | conn: nil, idle: nil}, "connect failed", reason)}
    end
  end

  defp connect_and_examine(state) do
    case call(state, :connect, [state.settings.imap, secret(state), state.connect_opts]) do
      {:ok, conn} -> examine_inbox(state, conn)
      {:error, reason} -> {:error, reason}
    end
  end

  defp examine_inbox(state, conn) do
    state = %{state | conn: conn}

    if call(state, :supports?, [conn, :idle]) == true do
      case call(state, :examine, [conn, @inbox]) do
        {:ok, _info} ->
          {:ok, conn}

        # Transient as far as this process can tell (a busy server, a mailbox
        # momentarily unavailable) — hand it back for the backoff path. The
        # connection is closed first: the next attempt opens a fresh one.
        other ->
          logout(state)
          {:error, {:examine_failed, other}}
      end
    else
      {:no_idle, conn}
    end
  end

  defp start_idle(state) do
    case call(state, :idle_start, [state.conn]) do
      {:ok, idle} ->
        {:noreply, %{state | idle: idle, deadline: now_ms() + state.reissue_ms},
         {:continue, :await}}

      {:error, reason} ->
        {:noreply, disconnect_and_retry(state, "IDLE refused", reason)}
    end
  end

  # -- trigger ---------------------------------------------------------------

  # Holds the trigger back until the burst goes quiet, then fires exactly one
  # (see the moduledoc, §Debounce).
  defp debounce_and_trigger(state) do
    case drain_burst(state, now_ms() + @debounce_max_ms) do
      {:ok, state} ->
        trigger(state)
        {:noreply, state, {:continue, :await}}

      # The connection died mid-burst. The change already observed is real, and
      # the pass runs on a connection of its OWN — so trigger it anyway, then
      # reconnect. Dropping it here would delay known-new mail by a whole poll
      # interval for no reason.
      {:error, state, reason} ->
        trigger(state)
        {:noreply, disconnect_and_retry(state, "burst drain failed", reason)}
    end
  end

  defp drain_burst(state, cap) do
    window = min(state.debounce_ms, max(cap - now_ms(), 0))

    case call(state, :idle_await, [state.conn, state.idle, window]) do
      # A quiet window ends the burst.
      {:ok, [], idle} ->
        {:ok, %{state | idle: idle}}

      {:ok, _events, idle} ->
        state = %{state | idle: idle}
        if now_ms() >= cap, do: {:ok, state}, else: drain_burst(state, cap)

      {:error, reason} ->
        {:error, state, reason}
    end
  end

  # The Engine's own internal sync entry point — the same gated path its poll
  # tick takes, cast (never called) so this process can never block on the
  # Engine loop and the Engine can never block on it.
  defp trigger(state), do: Engine.idle_activity(state.engine)

  # -- re-issue --------------------------------------------------------------

  defp reissue(state) do
    case call(state, :idle_done, [state.conn, state.idle]) do
      {:ok, events} ->
        state = %{state | idle: nil}
        # Activity inside the DONE handshake window is still activity.
        if changed?(events), do: trigger(state)
        start_idle(state)

      {:error, reason} ->
        {:noreply, disconnect_and_retry(state, "DONE failed", reason)}
    end
  end

  # -- reconnect / backoff ---------------------------------------------------

  defp disconnect_and_retry(state, what, reason) do
    logout(state)
    retry(%{state | conn: nil, idle: nil}, what, reason)
  end

  defp retry(state, what, reason) do
    log(state, what, reason)
    Process.send_after(self(), :reconnect, state.backoff_ms)
    %{state | backoff_ms: min(state.backoff_ms * 2, @backoff_max_ms)}
  end

  defp logout(%{conn: nil}), do: :ok

  defp logout(state) do
    call(state, :logout, [state.conn])
    :ok
  end

  # -- helpers ---------------------------------------------------------------

  defp changed?(events), do: Enum.any?(events, &change?/1)

  defp change?({:exists, _seq}), do: true
  defp change?({:expunge, _seq}), do: true
  defp change?({:fetch, _seq}), do: true
  defp change?({:other, _line}), do: false

  # Every transport call goes through here. A transport is allowed to answer
  # its failures as `{:error, _}`; a RAISE from one is a bug, and letting it
  # through would spend this watcher's restart budget (and, once spent, its
  # supervisor's) over something the backoff path already handles correctly.
  # Narrow by construction: the only code inside the rescue is the one
  # transport call named by `fun`.
  defp call(state, fun, args) do
    apply(state.transport, fun, args)
  rescue
    e -> {:error, {:raised, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  # Debug, not warn: see the moduledoc's §What it is FOR — a failure here
  # costs latency, not correctness, and a flapping connection must not fill an
  # operator's log with noise about an optimization. The message is built
  # inside the closure so the secret is materialized ONLY when a debug log is
  # actually emitted, and scrubbed even then (a connect error can quote what
  # it was handed).
  defp log(state, what, reason), do: log(state, "#{what}: #{inspect(reason)}")

  defp log(state, what) do
    Logger.debug(fn ->
      Redact.text("mail IDLE (account #{state.account}): #{what}", secret(state))
    end)
  end

  defp secret(%{credential: fun}) when is_function(fun, 0), do: fun.()
  defp secret(_state), do: nil

  defp now_ms, do: System.monotonic_time(:millisecond)
end
