# Agent-scripted `Valea.Mail.Transport` double for Engine tests (this task
# and every later mail task — T8's sync pass, T11's mailbox ops). Modeled on
# `test/support/fake_imap_server.ex`'s scripted-steps shape, but at the
# `Transport` callback level rather than the wire-protocol level: a test
# scripts what each callback should return, and can assert on what was
# actually called and with what arguments.
defmodule FakeMailTransport do
  @moduledoc """
  Backed by a single `Agent` (default name `#{inspect(__MODULE__)}`, the same
  name every `Transport` callback targets) holding `%{script:, calls:}`.

  `connect/3` has no `conn` to route through yet, so it always targets the
  default name — meaning a scripted `connect` result must hand back that same
  name (or an explicitly `start_link/1`-named alternative) as its `conn` for
  every later callback to resolve correctly:

      {:ok, _} = FakeMailTransport.start_link()
      FakeMailTransport.script([
        {:connect, :_, {:ok, FakeMailTransport}},
        {:capabilities, :_, {:ok, ["IMAP4rev1", "MOVE"]}}
      ])

  Every callback logs `{fun_name, args}` before returning, readable via
  `calls/1` (oldest first) — the assertion surface for "did the Engine call
  what I expected, with what arguments".
  """

  @behaviour Valea.Mail.Transport

  use Agent

  @typedoc """
  One scripted step: `fun_name` is the callback name (e.g. `:uid_search`);
  `args_matcher` is `:_` (match any call), a list the same length as the
  call's args where each element is either a literal (`==`-compared) or `:_`,
  or a 1-arity function `(args -> boolean)`; `result` is either the literal
  return value or a 1-arity function `(args -> return_value)` for
  call-dependent results (e.g. echoing back a UID from `args`).
  """
  @type step :: {atom(), :_ | list() | (list() -> boolean()), term() | (list() -> term())}

  @doc "Starts the fake's script/call-log state. `name:` defaults to `#{inspect(__MODULE__)}`."
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Agent.start_link(fn -> %{script: [], calls: []} end, name: name)
  end

  @doc "Replaces `pid_or_name`'s script (see the moduledoc for step shape)."
  @spec script(Agent.agent(), [step()]) :: :ok
  def script(pid_or_name \\ __MODULE__, steps) when is_list(steps) do
    Agent.update(pid_or_name, fn state -> %{state | script: steps} end)
  end

  @doc "Every call made so far against `pid_or_name`, oldest first: `{fun_name, args}`."
  @spec calls(Agent.agent()) :: [{atom(), list()}]
  def calls(pid_or_name \\ __MODULE__) do
    Agent.get(pid_or_name, fn state -> Enum.reverse(state.calls) end)
  end

  # -- Transport behaviour ----------------------------------------------------
  # `conn` is always exactly what a scripted `:connect` step returned — see
  # the moduledoc. Every other callback trusts it as the Agent target as-is;
  # a script that hands back a name nothing is running under fails loudly
  # (`no such process`) rather than silently routing to the wrong instance.

  @impl true
  def connect(config, credential, opts),
    do: invoke(__MODULE__, :connect, [config, credential, opts])

  @impl true
  def capabilities(conn), do: invoke(conn, :capabilities, [conn])

  @impl true
  def list_folders(conn), do: invoke(conn, :list_folders, [conn])

  @impl true
  def create_folder(conn, folder), do: invoke(conn, :create_folder, [conn, folder])

  @impl true
  def select(conn, folder), do: invoke(conn, :select, [conn, folder])

  @impl true
  def examine(conn, folder), do: invoke(conn, :examine, [conn, folder])

  @impl true
  def uid_search(conn, criteria), do: invoke(conn, :uid_search, [conn, criteria])

  @impl true
  def uid_fetch_meta(conn, uids), do: invoke(conn, :uid_fetch_meta, [conn, uids])

  @impl true
  def uid_fetch_headers(conn, uids), do: invoke(conn, :uid_fetch_headers, [conn, uids])

  @impl true
  def uid_fetch_full(conn, uid), do: invoke(conn, :uid_fetch_full, [conn, uid])

  @impl true
  def uid_fetch_flags(conn, uid_set), do: invoke(conn, :uid_fetch_flags, [conn, uid_set])

  @impl true
  def uid_store_flags(conn, uid, add, remove, opts \\ []),
    do: invoke(conn, :uid_store_flags, [conn, uid, add, remove, opts])

  @impl true
  def uid_move(conn, uid, folder), do: invoke(conn, :uid_move, [conn, uid, folder])

  @impl true
  def uid_copy(conn, uid, folder), do: invoke(conn, :uid_copy, [conn, uid, folder])

  @impl true
  def uid_mark_deleted(conn, uid), do: invoke(conn, :uid_mark_deleted, [conn, uid])

  @impl true
  def uid_expunge(conn, uid), do: invoke(conn, :uid_expunge, [conn, uid])

  @impl true
  def append(conn, folder, flags, rfc822),
    do: invoke(conn, :append, [conn, folder, flags, rfc822])

  @impl true
  def supports?(conn, capability), do: invoke(conn, :supports?, [conn, capability])

  @impl true
  def logout(conn), do: invoke(conn, :logout, [conn])

  # -- internal -----------------------------------------------------------

  # The "no match" raise must happen in the CALLING (test) process, not
  # inside the Agent callback below — raising there would crash the shared
  # Agent itself, poisoning every later scripted call in the same test with
  # a dead process instead of a clean, catchable error at the call site
  # that actually went off-script.
  defp invoke(target, fun_name, args) do
    case Agent.get_and_update(target, &lookup_and_log(&1, fun_name, args)) do
      {:ok, result} ->
        result

      :no_match ->
        raise "FakeMailTransport: no script step matches #{fun_name}(#{inspect(args)})"
    end
  end

  defp lookup_and_log(state, fun_name, args) do
    case find_result(state.script, fun_name, args) do
      {:ok, result} -> {{:ok, result}, %{state | calls: [{fun_name, args} | state.calls]}}
      :no_match -> {:no_match, state}
    end
  end

  defp find_result(script, fun_name, args) do
    case Enum.find(script, fn {name, matcher, _result} ->
           name == fun_name and matches?(matcher, args)
         end) do
      {_name, _matcher, result} -> {:ok, resolve(result, args)}
      nil -> :no_match
    end
  end

  defp matches?(:_, _args), do: true
  defp matches?(matcher, args) when is_function(matcher, 1), do: matcher.(args)

  defp matches?(matcher, args) when is_list(matcher) and length(matcher) == length(args) do
    matcher |> Enum.zip(args) |> Enum.all?(fn {m, a} -> m == :_ or m == a end)
  end

  defp matches?(_matcher, _args), do: false

  defp resolve(result, args) when is_function(result, 1), do: result.(args)
  defp resolve(result, _args), do: result
end
