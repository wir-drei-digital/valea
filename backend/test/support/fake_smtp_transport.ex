# Agent-scripted `Valea.Mail.SmtpTransport` double for the send pipeline's
# executor/engine/doctor tests. Modeled on `test/support/fake_mail_transport.ex`
# (the IMAP-side double) — same script/calls shape, one behaviour down.
defmodule FakeSmtpTransport do
  @moduledoc """
  Backed by a single `Agent` registered under `#{inspect(__MODULE__)}`.

  `Valea.Mail.SmtpTransport` has no `conn` — every call is a whole session —
  so unlike `FakeMailTransport` there is nothing to route through and both
  callbacks always target that one name:

      {:ok, _} = FakeSmtpTransport.start_link()
      FakeSmtpTransport.script([
        {:check_auth, :_, :ok},
        {:send, :_, {:ok, :accepted}}
      ])

  Every call logs `{fun_name, args}` before returning, readable via `calls/1`
  (oldest first). That log is the assertion surface for the property this
  whole spec is built around: `send/5` is called **at most once** per op, and
  never at all from a recovery, reconciliation, or retry path.
  """

  @behaviour Valea.Mail.SmtpTransport

  use Agent

  @typedoc """
  One scripted step: `fun_name` is the callback name (`:send` | `:check_auth`);
  `args_matcher` is `:_` (match any call), a list the same length as the call's
  args where each element is either a literal (`==`-compared) or `:_`, or a
  1-arity function `(args -> boolean)`; `result` is either the literal return
  value or a 1-arity function `(args -> return_value)` for call-dependent
  results (e.g. deriving rejected recipients from the envelope in `args`).
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

  # -- SmtpTransport behaviour --------------------------------------------------

  @impl true
  def send(config, credential, envelope, data, opts),
    do: invoke(:send, [config, credential, envelope, data, opts])

  @impl true
  def check_auth(config, credential, opts),
    do: invoke(:check_auth, [config, credential, opts])

  # -- internal ------------------------------------------------------------------

  # Both the "no match" raise AND the scripted result function run in the
  # CALLING process, never inside the Agent callback: raising in there would
  # crash the shared Agent and poison every later call in the same test with a
  # dead process instead of a clean error at the call site. That matters here
  # in particular because a legitimate script step may RAISE on purpose — it
  # is how a test drives the doctor's "a transport that blows up becomes a
  # failed check, never an exception" path.
  defp invoke(fun_name, args) do
    case Agent.get_and_update(__MODULE__, &lookup_and_log(&1, fun_name, args)) do
      {:ok, result} ->
        resolve(result, args)

      :no_match ->
        raise "FakeSmtpTransport: no script step matches #{fun_name}(#{inspect(args)})"
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
      {_name, _matcher, result} -> {:ok, result}
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
