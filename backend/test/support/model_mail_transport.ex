# Stateful `Valea.Mail.Transport` double for the scenario suite (Tasks 7, 8,
# 13, 15) that needs multi-pass, real behavior `FakeMailTransport` scripting
# can't express: uids that actually auto-assign and advance, a mailbox that
# actually loses a message on move, a UIDVALIDITY that actually bumps and
# re-uids. Backed by a single `Agent` per model instance (named per test, via
# `start_link(name: ...)`), holding a small in-memory account model.
defmodule ModelMailTransport do
  @moduledoc """
  A real (if tiny) IMAP-shaped server model in an `Agent`, implementing
  `Valea.Mail.Transport` against it. Tests drive two separate surfaces:

    * **Model manipulation** (`put_folder/3`, `put_message/4`,
      `delete_message/3`, `set_flags/4`, `rename_folder/3`,
      `reset_uidvalidity/2`, `messages/2`, `inject/2`) — direct calls keyed by
      the Agent's registered `name`, no `Transport` indirection.
    * **`Transport` callbacks** — called by the code under test (an
      `Engine`/`SyncPass`/executor) exactly as it would call `ImapClient`.
      `connect/3` has no `conn` yet, so (mirroring
      `test/support/fake_mail_transport.ex`'s convention) it resolves the
      target Agent from `opts[:name]` and hands that name straight back as
      `conn` — every other callback trusts it as the Agent target as-is.

  ## Connection state: the selected mailbox

  Real IMAP is stateful per-connection: `SELECT`/`EXAMINE` set the
  connection's "current mailbox", and every subsequent `UID` command that
  doesn't take an explicit folder argument (`uid_search/2`,
  `uid_fetch_meta/2`, `uid_fetch_headers/2`, `uid_fetch_full/2`,
  `uid_fetch_flags/2`, `uid_store_flags/5`, `uid_move/3` (source side),
  `uid_copy/3` (source side), `uid_mark_deleted/2`, `uid_expunge/2`) operates
  against it. This model tracks that as `state.selected`, set by
  `select/2`/`examine/2` and consulted by everything else — call one of
  those without a prior successful `select`/`examine` and it errors with
  `{:error, :no_mailbox_selected}`, exactly like a real server would refuse
  an unselected-state command.

  A FAILING `select/2`/`examine/2` always deselects — `state.selected`
  becomes `nil` — whether the failure is a nonexistent mailbox OR an
  injected `:drop_connection`/`{:fail, ...}` fault, mirroring RFC 3501
  §6.3.1/§6.3.2: a failed SELECT/EXAMINE deselects any previously-selected
  mailbox rather than leaving the old selection in place. The one exception
  is `{:lost_response, :select}`/`{:lost_response, :examine}`: that fault
  models a command that genuinely completed server-side before its response
  was lost, so the selection really did change — `state.selected` is left
  exactly as that successful run computed it, and only the client-visible
  result is overridden to an error.

  ## Fault injection

  `inject(name, fault)` queues a one-shot fault (FIFO among faults with the
  same target). On each `Transport` call whose return type actually admits
  an error (i.e. NOT `capabilities/1`, `supports?/2`, or `logout/1` — their
  callback types are unconditionally successful, so no fault ever applies to
  them), the queue is scanned front-to-back for the first entry that targets
  this call:

    * `:drop_connection` — targets ANY call; consumed, returns
      `{:error, :closed}`, no mutation (EXCEPT for `select/2`/`examine/2`,
      which also deselect — see "Connection state" above).
    * `{:fail, fun_name, reason}` — targets `fun_name` only; consumed,
      returns `{:error, reason}`, no mutation (same `select/2`/`examine/2`
      exception).
    * `{:lost_response, fun_name}` — targets `fun_name` only; the underlying
      operation runs to completion (its state mutation fully applies), then
      the result actually returned to the caller is overridden to
      `{:error, :closed}` — modeling a server that finished executing a
      command but whose response the client never saw.

  A fault targeting a different `fun_name` is left in the queue and does not
  block an unrelated call from proceeding normally.

  ## Gmail label mode

  `initial_model(gmail: true)` pre-creates `"[Gmail]/All Mail"` and flips
  every folder into "label" semantics:

    * `put_message/4` and `append/4` on any OTHER folder also insert a
      mirror occurrence into All Mail (own uid, same `gm_msgid`) — this is
      what keeps "every message is visible in All Mail" true without a test
      having to do it by hand.
    * `uid_move/3` INTO All Mail removes the occurrence from the source
      folder only: the destination occurrence already exists (it was
      auto-mirrored in), so `dest_uid` is that EXISTING All Mail uid, not a
      freshly minted one.
    * `uid_move/3` between two ordinary (non-All-Mail) folders never touches
      All Mail's independent copy of the message at all — membership survives.
    * `gm_msgid` is a decimal-string id (matching the real
      `Valea.Mail.Transport.fetch_flags_result` shape) assigned from a
      content hash the FIRST time a given raw byte sequence is seen by
      `put_message/4`/`append/4`, and reused for every later occurrence of
      that exact content — this is what makes "the same raw message copied
      across folders keeps ONE gm_msgid" true, whether the copy happened via
      the auto-mirror above or via a test directly calling `put_message/4`
      with the same bytes in two different folders.

  `gm_msgid`/`modseq` are still computed even outside gmail mode, but
  `uid_fetch_flags/2` only reports them (else `nil`) when the model is
  gmail-capable / CONDSTORE-capable respectively — matching `ImapClient`'s
  own "don't ask a server for an attribute it doesn't support" behavior.

  ## `SINCE` date parsing

  `uid_search(conn, "SINCE <date>")` compares against each message's
  `internal_date` (a `Date`, date-only granularity — no time-of-day
  comparison, matching real IMAP SEARCH SINCE). `<date>` accepts BOTH the
  RFC 3501 wire format real callers send (`17-Jul-2026`) and plain ISO 8601
  (`2026-07-17`), tried in that order, to be liberal about what a test (or a
  future caller) hands in.
  """

  @behaviour Valea.Mail.Transport

  use Agent

  @all_mail "[Gmail]/All Mail"
  @rfc3501_months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  # -- start_link / model construction --------------------------------------

  @doc "Starts the model's Agent. `opts[:name]` is required; `opts[:model]` defaults to `initial_model/1`."
  def start_link(opts \\ []) do
    name = Keyword.fetch!(opts, :name)
    model = Keyword.get(opts, :model, initial_model())
    Agent.start_link(fn -> model end, name: name)
  end

  @doc """
  Builds a fresh account model. `opts[:gmail]` (default `false`) turns on
  label mode (see moduledoc). `opts[:capabilities]` overrides the default
  `supports?/2`/`capabilities/1` set (default: `condstore`, `move`,
  `uidplus`, plus `gmail` iff `opts[:gmail]`; `qresync` is off by default).
  """
  def initial_model(opts \\ []) do
    gmail? = Keyword.get(opts, :gmail, false)
    default_caps = [:condstore, :move, :uidplus] ++ if(gmail?, do: [:gmail], else: [])
    capability_set = opts |> Keyword.get(:capabilities, default_caps) |> MapSet.new()
    folders = if gmail?, do: %{@all_mail => new_folder()}, else: %{}

    %{
      folders: folders,
      selected: nil,
      faults: [],
      gmail: gmail?,
      capability_set: capability_set,
      gm_msgid_seq: 0,
      content_hashes: %{}
    }
  end

  # -- model manipulation (test-side) ---------------------------------------

  @doc "Creates (or replaces) an empty folder. `opts[:uidvalidity]` defaults to `1`."
  def put_folder(name, folder, opts \\ []) do
    uidvalidity = Keyword.get(opts, :uidvalidity, 1)
    Agent.update(name, fn state -> put_folder_state(state, folder, new_folder(uidvalidity)) end)
  end

  @doc """
  Inserts `raw` into `folder`, auto-assigning `uid = uidnext` (then
  advancing it). `opts[:flags]` defaults to `[]`; `opts[:internal_date]`
  defaults to today (accepts a `Date`, an RFC 3501 string, or an ISO 8601
  string — see moduledoc). Returns the assigned uid. In gmail mode, also
  mirrors into `"[Gmail]/All Mail"` (own uid, same `gm_msgid`) unless
  `folder` already IS All Mail.
  """
  def put_message(name, folder, raw, opts \\ []) do
    flags = Keyword.get(opts, :flags, [])
    internal_date = opts |> Keyword.get(:internal_date) |> normalize_internal_date()

    Agent.get_and_update(name, fn state ->
      {gm_msgid, state} = gm_msgid_for(state, raw)
      insert_with_mirror(state, folder, raw, flags, internal_date, gm_msgid)
    end)
  end

  @doc "Server-side expunge of a single folder+uid occurrence. No-op if either is absent."
  def delete_message(name, folder, uid) do
    Agent.update(name, fn state ->
      update_folder(state, folder, fn folder_state ->
        if Map.has_key?(folder_state.messages, uid) do
          bump_folder(%{folder_state | messages: Map.delete(folder_state.messages, uid)})
        else
          folder_state
        end
      end)
    end)
  end

  @doc "Replaces (not add/remove — a direct replace) the flags list for a folder+uid occurrence."
  def set_flags(name, folder, uid, flags) do
    Agent.update(name, fn state ->
      update_folder(state, folder, fn folder_state ->
        case Map.fetch(folder_state.messages, uid) do
          :error -> folder_state
          {:ok, msg} -> put_updated_message(folder_state, uid, %{msg | flags: flags})
        end
      end)
    end)
  end

  @doc """
  Delete+create semantics at the LIST level: `from` stops existing (and is
  deselected if it was the current mailbox) and `to` appears as a brand new,
  empty folder — this is NOT a content-preserving rename.
  """
  def rename_folder(name, from, to) do
    Agent.update(name, fn state ->
      folders = state.folders |> Map.delete(from) |> Map.put(to, new_folder())
      selected = if state.selected == from, do: nil, else: state.selected
      %{state | folders: folders, selected: selected}
    end)
  end

  @doc "Bumps uidvalidity and reassigns uids 1..N to every message, preserving relative order."
  def reset_uidvalidity(name, folder) do
    Agent.update(name, fn state ->
      update_folder(state, folder, fn folder_state ->
        ordered = folder_state.messages |> Map.values() |> Enum.sort_by(& &1.uid)

        {reuided, next_uid} =
          Enum.map_reduce(ordered, 1, fn msg, uid -> {%{msg | uid: uid, modseq: 1}, uid + 1} end)

        %{
          folder_state
          | uidvalidity: folder_state.uidvalidity + 1,
            uidnext: next_uid,
            modseq: 1,
            messages: Map.new(reuided, &{&1.uid, &1})
        }
      end)
    end)
  end

  @doc "Every message currently in `folder`, ascending by uid (`[]` if the folder doesn't exist)."
  def messages(name, folder) do
    Agent.get(name, fn state ->
      case Map.fetch(state.folders, folder) do
        {:ok, folder_state} -> folder_state.messages |> Map.values() |> Enum.sort_by(& &1.uid)
        :error -> []
      end
    end)
  end

  @doc "Queues a one-shot fault (see moduledoc \"Fault injection\")."
  def inject(name, fault) do
    Agent.update(name, fn state -> %{state | faults: state.faults ++ [fault]} end)
  end

  # -- Transport callbacks: unconditionally-successful (no fault injection) --
  # capabilities/1, supports?/2, logout/1 have callback types with no error
  # variant at all (bare `{:ok, _}`/`boolean()`/`:ok`), so no fault ever
  # applies to them — see moduledoc.

  @impl true
  def connect(_config, _credential, opts \\ []) do
    name = Keyword.fetch!(opts, :name)
    perform(name, :connect, fn state -> {{:ok, name}, state} end)
  end

  @impl true
  def capabilities(conn) do
    Agent.get(conn, fn state ->
      wire = state.capability_set |> MapSet.to_list() |> Enum.map(&capability_wire_name/1)
      {:ok, ["IMAP4rev1" | wire]}
    end)
  end

  @impl true
  def supports?(conn, capability) do
    Agent.get(conn, fn state -> MapSet.member?(state.capability_set, capability) end)
  end

  @impl true
  def logout(_conn), do: :ok

  # -- Transport callbacks: fault-eligible ------------------------------------

  @impl true
  def list_folders(conn) do
    perform(conn, :list_folders, fn state ->
      {{:ok, state.folders |> Map.keys() |> Enum.sort()}, state}
    end)
  end

  @impl true
  def create_folder(conn, name) do
    perform(conn, :create_folder, fn state ->
      if Map.has_key?(state.folders, name) do
        {{:error, :already_exists}, state}
      else
        {:ok, put_folder_state(state, name, new_folder())}
      end
    end)
  end

  @impl true
  def select(conn, folder), do: do_select(conn, :select, folder)

  @impl true
  def examine(conn, folder), do: do_select(conn, :examine, folder)

  # Uses `perform_select/3`, NOT the plain `perform/3` every other callback
  # uses — see moduledoc "Connection state: the selected mailbox" for why a
  # failing select/examine needs its own fault-handling wrapper (deselecting
  # on a fault that skipped mutation, not just on a genuine no-such-mailbox).
  defp do_select(conn, fun_name, folder) do
    perform_select(conn, fun_name, fn state ->
      case Map.fetch(state.folders, folder) do
        {:ok, f} ->
          info = %{uidvalidity: f.uidvalidity, uidnext: f.uidnext, highestmodseq: f.modseq}
          {{:ok, info}, %{state | selected: folder}}

        :error ->
          {{:error, {:no_such_mailbox, folder}}, %{state | selected: nil}}
      end
    end)
  end

  @impl true
  def uid_search(conn, criteria) do
    perform(conn, :uid_search, fn state ->
      with_selected(state, fn folder_state -> {:ok, run_search(criteria, folder_state)} end)
    end)
  end

  @impl true
  def uid_fetch_meta(conn, uids) do
    perform(conn, :uid_fetch_meta, fn state ->
      with_selected(state, fn folder_state ->
        fetch_each(folder_state, uids, fn msg -> %{uid: msg.uid, size: byte_size(msg.raw)} end)
      end)
    end)
  end

  @impl true
  def uid_fetch_headers(conn, uids) do
    perform(conn, :uid_fetch_headers, fn state ->
      with_selected(state, fn folder_state ->
        fetch_each(folder_state, uids, fn msg ->
          %{uid: msg.uid, header: header_bytes(msg.raw)}
        end)
      end)
    end)
  end

  @impl true
  def uid_fetch_full(conn, uid) do
    perform(conn, :uid_fetch_full, fn state ->
      with_selected(state, fn folder_state ->
        case Map.fetch(folder_state.messages, uid) do
          {:ok, msg} -> {:ok, msg.raw}
          :error -> {:error, {:no_fetch_data, uid}}
        end
      end)
    end)
  end

  @impl true
  def uid_fetch_flags(conn, uid_set) do
    perform(conn, :uid_fetch_flags, fn state ->
      with_selected(state, fn folder_state ->
        uids = resolve_uid_set(uid_set, folder_state.messages)

        results =
          Enum.map(uids, fn uid ->
            msg = Map.fetch!(folder_state.messages, uid)

            %{
              uid: msg.uid,
              flags: msg.flags,
              modseq: if(MapSet.member?(state.capability_set, :condstore), do: msg.modseq),
              gm_msgid: if(state.gmail, do: msg.gm_msgid)
            }
          end)

        {:ok, results}
      end)
    end)
  end

  @impl true
  def uid_store_flags(conn, uid, add, remove, opts \\ []) do
    unchangedsince = Keyword.get(opts, :unchangedsince)

    if add != [] and remove != [] and unchangedsince != nil do
      case Keyword.get(opts, :base_flags) do
        nil ->
          raise ArgumentError, """
          uid_store_flags/5: combining a non-empty add list AND a non-empty \
          remove list under opts[:unchangedsince] requires opts[:base_flags] \
          (the message's current IMAP flags, from execution-time verification) \
          so a single atomic FLAGS replace can be computed. Without it, issuing \
          two sequential guarded STOREs would have the first one's own \
          successful apply bump the message's modseq, making the second \
          deterministically fail its own UNCHANGEDSINCE precondition.\
          """

        base_flags ->
          perform(conn, :uid_store_flags, fn state ->
            with_selected_mutable(state, fn folder_state ->
              atomic_replace_flags(folder_state, uid, base_flags, add, remove, unchangedsince)
            end)
          end)
      end
    else
      perform(conn, :uid_store_flags, fn state ->
        with_selected_mutable(state, fn folder_state ->
          plain_store_flags(folder_state, uid, add, remove, unchangedsince)
        end)
      end)
    end
  end

  @impl true
  def uid_move(conn, uid, dest_folder) do
    perform(conn, :uid_move, fn state ->
      with_selected_source(state, uid, fn source, msg ->
        move(state, source, dest_folder, uid, msg)
      end)
    end)
  end

  @impl true
  def uid_copy(conn, uid, dest_folder) do
    perform(conn, :uid_copy, fn state ->
      with_selected_source(state, uid, fn _source, msg ->
        copy_into(state, dest_folder, msg)
      end)
    end)
  end

  @impl true
  def uid_mark_deleted(conn, uid) do
    perform(conn, :uid_mark_deleted, fn state ->
      with_selected_mutable(state, fn folder_state ->
        case Map.fetch(folder_state.messages, uid) do
          :error ->
            {{:error, {:no_such_message, uid}}, folder_state}

          {:ok, msg} ->
            new_flags = Enum.uniq(msg.flags ++ ["\\Deleted"])
            {:ok, put_updated_message(folder_state, uid, %{msg | flags: new_flags})}
        end
      end)
    end)
  end

  @impl true
  def uid_expunge(conn, uid) do
    perform(conn, :uid_expunge, fn state ->
      with_selected_mutable(state, fn folder_state ->
        case Map.fetch(folder_state.messages, uid) do
          {:ok, %{flags: flags}} ->
            if "\\Deleted" in flags do
              {:ok,
               bump_folder(%{folder_state | messages: Map.delete(folder_state.messages, uid)})}
            else
              {:ok, folder_state}
            end

          :error ->
            {:ok, folder_state}
        end
      end)
    end)
  end

  @impl true
  def append(conn, folder, flags, rfc822) do
    perform(conn, :append, fn state ->
      {gm_msgid, state} = gm_msgid_for(state, rfc822)
      {uid, state} = insert_with_mirror(state, folder, rfc822, flags, Date.utc_today(), gm_msgid)
      {{:ok, %{dest_uid: uid}}, state}
    end)
  end

  # -- fault-injection plumbing ----------------------------------------------

  # `target` is the Agent name/pid (i.e. `conn`, or the resolved `name` for
  # `connect/3`). `fun` receives the full state and must return
  # `{result, new_state}` — the same shape `Agent.get_and_update/2` expects.
  defp perform(target, fun_name, fun) do
    Agent.get_and_update(target, fn state ->
      case pop_fault(state.faults, fun_name) do
        {:drop, rest} ->
          {{:error, :closed}, %{state | faults: rest}}

        {{:fail, reason}, rest} ->
          {{:error, reason}, %{state | faults: rest}}

        {:lost_response, rest} ->
          {_discarded_result, new_state} = fun.(%{state | faults: rest})
          {{:error, :closed}, new_state}

        :none ->
          fun.(state)
      end
    end)
  end

  # Like `perform/3`, but ONLY for `select/2`/`examine/2`: a fault path that
  # skips running `fun` entirely (`:drop_connection`, `{:fail, ...}`) also
  # deselects the connection's mailbox, mirroring real IMAP — a failed
  # SELECT/EXAMINE deselects any previously-selected mailbox (RFC 3501
  # §6.3.1/§6.3.2), rather than leaving a stale prior selection in place for
  # every later unselected-state check to wrongly treat as still current.
  # `{:lost_response, ...}` still runs `fun` to completion first (the
  # command genuinely succeeded server-side), so its resulting `selected` is
  # left exactly as `fun` computed it — only the client-visible result is
  # overridden to an error, same as `perform/3`.
  defp perform_select(target, fun_name, fun) do
    Agent.get_and_update(target, fn state ->
      case pop_fault(state.faults, fun_name) do
        {:drop, rest} ->
          {{:error, :closed}, %{state | faults: rest, selected: nil}}

        {{:fail, reason}, rest} ->
          {{:error, reason}, %{state | faults: rest, selected: nil}}

        {:lost_response, rest} ->
          {_discarded_result, new_state} = fun.(%{state | faults: rest})
          {{:error, :closed}, new_state}

        :none ->
          fun.(state)
      end
    end)
  end

  defp pop_fault(faults, fun_name), do: pop_fault(faults, fun_name, [])
  defp pop_fault([], _fun_name, _acc), do: :none

  defp pop_fault([:drop_connection | rest], _fun_name, acc),
    do: {:drop, Enum.reverse(acc) ++ rest}

  defp pop_fault([{:fail, target, reason} | rest], fun_name, acc) when target == fun_name,
    do: {{:fail, reason}, Enum.reverse(acc) ++ rest}

  defp pop_fault([{:lost_response, target} | rest], fun_name, acc) when target == fun_name,
    do: {:lost_response, Enum.reverse(acc) ++ rest}

  defp pop_fault([other | rest], fun_name, acc), do: pop_fault(rest, fun_name, [other | acc])

  # -- selected-mailbox plumbing ----------------------------------------------

  defp current_folder(state) do
    with folder when not is_nil(folder) <- state.selected,
         {:ok, folder_state} <- Map.fetch(state.folders, folder) do
      {:ok, folder_state}
    else
      _ -> {:error, :no_mailbox_selected}
    end
  end

  # Read-only: `fun` maps the selected folder_state straight to the result.
  defp with_selected(state, fun) do
    case current_folder(state) do
      {:ok, folder_state} -> {fun.(folder_state), state}
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  # Mutating: `fun` maps the selected folder_state to `{result, new_folder_state}`;
  # the new folder_state is folded back into `state.folders`.
  defp with_selected_mutable(state, fun) do
    case current_folder(state) do
      {:error, reason} ->
        {{:error, reason}, state}

      {:ok, folder_state} ->
        {result, new_folder_state} = fun.(folder_state)
        {result, put_folder_state(state, state.selected, new_folder_state)}
    end
  end

  # For uid_move/uid_copy: resolves the selected folder AND the message
  # within it in one step, since both need the source folder name too.
  defp with_selected_source(state, uid, fun) do
    case current_folder(state) do
      {:error, reason} ->
        {{:error, reason}, state}

      {:ok, folder_state} ->
        case Map.fetch(folder_state.messages, uid) do
          :error -> {{:error, {:no_such_message, uid}}, state}
          {:ok, msg} -> fun.(state.selected, msg)
        end
    end
  end

  # -- move / copy ------------------------------------------------------------

  defp move(state, source, @all_mail, uid, msg) when source != @all_mail do
    if state.gmail do
      case find_by_gm_msgid(state, @all_mail, msg.gm_msgid) do
        {existing_uid, _existing_msg} ->
          {{:ok, %{dest_uid: existing_uid}}, remove_from_folder(state, source, uid)}

        nil ->
          move_ordinary(state, source, @all_mail, uid, msg)
      end
    else
      move_ordinary(state, source, @all_mail, uid, msg)
    end
  end

  defp move(state, source, dest, uid, msg), do: move_ordinary(state, source, dest, uid, msg)

  defp move_ordinary(state, source, dest, uid, msg) do
    state = remove_from_folder(state, source, uid)

    {new_uid, state} =
      insert_message(state, dest, msg.raw, msg.flags, msg.internal_date, msg.gm_msgid)

    {{:ok, %{dest_uid: new_uid}}, state}
  end

  defp copy_into(state, @all_mail, msg) do
    if state.gmail do
      case find_by_gm_msgid(state, @all_mail, msg.gm_msgid) do
        {existing_uid, _existing_msg} ->
          {{:ok, %{dest_uid: existing_uid}}, state}

        nil ->
          copy_ordinary(state, @all_mail, msg)
      end
    else
      copy_ordinary(state, @all_mail, msg)
    end
  end

  defp copy_into(state, dest, msg), do: copy_ordinary(state, dest, msg)

  defp copy_ordinary(state, dest, msg) do
    {new_uid, state} =
      insert_message(state, dest, msg.raw, msg.flags, msg.internal_date, msg.gm_msgid)

    {{:ok, %{dest_uid: new_uid}}, state}
  end

  defp find_by_gm_msgid(state, folder, gm_msgid) do
    state.folders
    |> Map.get(folder, new_folder())
    |> Map.get(:messages)
    |> Enum.find(fn {_uid, m} -> m.gm_msgid == gm_msgid end)
  end

  defp remove_from_folder(state, folder, uid) do
    update_folder(state, folder, fn folder_state ->
      bump_folder(%{folder_state | messages: Map.delete(folder_state.messages, uid)})
    end)
  end

  # -- uid_store_flags helpers -------------------------------------------------

  defp plain_store_flags(folder_state, uid, add, remove, unchangedsince) do
    case Map.fetch(folder_state.messages, uid) do
      :error ->
        {{:error, {:no_such_message, uid}}, folder_state}

      {:ok, _msg} when add == [] and remove == [] ->
        {{:ok, :applied}, folder_state}

      {:ok, msg} ->
        if unchangedsince != nil and msg.modseq > unchangedsince do
          {{:ok, :modified}, folder_state}
        else
          new_flags = (msg.flags ++ add) -- remove

          new_folder_state =
            put_updated_message(folder_state, uid, %{msg | flags: Enum.uniq(new_flags)})

          {{:ok, :applied}, new_folder_state}
        end
    end
  end

  defp atomic_replace_flags(folder_state, uid, base_flags, add, remove, unchangedsince) do
    case Map.fetch(folder_state.messages, uid) do
      :error ->
        {{:error, {:no_such_message, uid}}, folder_state}

      {:ok, msg} ->
        if msg.modseq > unchangedsince do
          {{:ok, :modified}, folder_state}
        else
          final = replace_flags(base_flags, add, remove)
          new_folder_state = put_updated_message(folder_state, uid, %{msg | flags: final})
          {{:ok, :applied}, new_folder_state}
        end
    end
  end

  # `final = (base_flags ++ add) -- remove`, deduped and sorted — mirrors
  # `ImapClient.replace_flags/3` exactly, INCLUDING its choice of
  # `Enum.reject/2` over Kernel `--`: `--` only deletes the FIRST occurrence
  # of each removed element, so a flag duplicated across `base_flags`/`add`
  # (e.g. a caller re-asserting a flag it's also asking to have removed)
  # would leave one stray occurrence behind. Rejecting every occurrence of
  # anything in `remove` is the correct set-based semantics: `remove` always
  # wins, regardless of how many times a flag is duplicated on the way in.
  defp replace_flags(base_flags, add, remove) do
    remove_set = MapSet.new(remove)

    (base_flags ++ add)
    |> Enum.reject(&MapSet.member?(remove_set, &1))
    |> Enum.uniq()
    |> Enum.sort()
  end

  # -- uid_search -------------------------------------------------------------

  defp run_search("ALL", folder_state), do: folder_state.messages |> Map.keys() |> Enum.sort()

  defp run_search("UID " <> rest, folder_state) do
    case String.split(rest, ":") do
      [n, "*"] ->
        n = String.to_integer(n)
        uids = folder_state.messages |> Map.keys() |> Enum.sort()

        case Enum.filter(uids, &(&1 >= n)) do
          # RFC 3501: `*` in a sequence-set always resolves to the largest
          # uid in the mailbox. When `n` exceeds every existing uid, the
          # range is reversed (`n:*` becomes e.g. `5:1`) and a real server
          # normalizes a reversed range by swapping the endpoints — so it
          # still matches that one largest uid, never `[]`. An empty
          # mailbox has no largest uid to resolve `*` to, so it's the one
          # case that's genuinely `[]`.
          [] -> uids |> List.last() |> List.wrap()
          matched -> matched
        end

      [n] ->
        n = String.to_integer(n)
        if Map.has_key?(folder_state.messages, n), do: [n], else: []
    end
  end

  defp run_search("SINCE " <> date_str, folder_state) do
    date = parse_date(date_str)

    folder_state.messages
    |> Map.values()
    |> Enum.filter(&(Date.compare(&1.internal_date, date) != :lt))
    |> Enum.map(& &1.uid)
    |> Enum.sort()
  end

  defp run_search("HEADER Message-ID " <> id, folder_state) do
    folder_state.messages
    |> Map.values()
    |> Enum.filter(&header_contains?(&1.raw, "Message-ID", id))
    |> Enum.map(& &1.uid)
    |> Enum.sort()
  end

  defp run_search("X-GM-MSGID " <> id, folder_state) do
    folder_state.messages
    |> Map.values()
    |> Enum.filter(&(&1.gm_msgid == id))
    |> Enum.map(& &1.uid)
    |> Enum.sort()
  end

  defp run_search(criteria, _folder_state) do
    raise ArgumentError,
          "ModelMailTransport.uid_search: unsupported criteria #{inspect(criteria)}"
  end

  defp header_contains?(raw, field_name, needle) do
    case extract_header(raw, field_name) do
      nil -> false
      value -> String.contains?(String.downcase(value), String.downcase(needle))
    end
  end

  defp extract_header(raw, field_name) do
    header_part =
      case :binary.split(raw, ["\r\n\r\n", "\n\n"]) do
        [h, _] -> h
        [h] -> h
      end

    header_part
    |> String.split(~r/\r\n|\n/)
    |> Enum.find_value(fn line ->
      case String.split(line, ":", parts: 2) do
        [name, value] ->
          if String.downcase(String.trim(name)) == String.downcase(field_name),
            do: String.trim(value)

        _ ->
          nil
      end
    end)
  end

  defp parse_date(str) do
    str = String.trim(str)

    case Date.from_iso8601(str) do
      {:ok, date} -> date
      {:error, _} -> parse_rfc3501_date(str)
    end
  end

  defp parse_rfc3501_date(str) do
    case String.split(str, "-") do
      [day, mon, year] ->
        month = (Enum.find_index(@rfc3501_months, &(&1 == mon)) || raise_bad_date(str)) + 1
        Date.new!(String.to_integer(year), month, String.to_integer(day))

      _ ->
        raise_bad_date(str)
    end
  end

  defp raise_bad_date(str) do
    raise ArgumentError,
          "ModelMailTransport: cannot parse SINCE date #{inspect(str)} (expected RFC 3501 " <>
            "e.g. \"17-Jul-2026\" or ISO 8601 e.g. \"2026-07-17\")"
  end

  # -- uid_set (sequence-set string) resolution --------------------------------

  defp resolve_uid_set(str, messages) do
    present = Map.keys(messages)

    str
    |> String.split(",", trim: true)
    |> Enum.flat_map(&resolve_uid_token(&1, present))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.filter(&Map.has_key?(messages, &1))
  end

  defp resolve_uid_token(token, present) do
    case String.split(token, ":") do
      ["*"] ->
        case Enum.max(present, fn -> nil end) do
          nil -> []
          max -> [max]
        end

      [n] ->
        [String.to_integer(n)]

      [n, "*"] ->
        n = String.to_integer(n)
        Enum.filter(present, &(&1 >= n))

      [n, m] ->
        n = String.to_integer(n)
        m = String.to_integer(m)
        Enum.filter(present, &(&1 >= n and &1 <= m))
    end
  end

  # -- fetch helpers ------------------------------------------------------------

  defp fetch_each(folder_state, uids, mapper) do
    uids
    |> Enum.reduce_while({:ok, []}, fn uid, {:ok, acc} ->
      case Map.fetch(folder_state.messages, uid) do
        {:ok, msg} -> {:cont, {:ok, [mapper.(msg) | acc]}}
        :error -> {:halt, {:error, {:no_fetch_data, uid}}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp header_bytes(raw) do
    case :binary.split(raw, ["\r\n\r\n", "\n\n"]) do
      [h, _] -> h
      [h] -> h
    end
  end

  # -- message / folder construction & mutation --------------------------------

  defp new_folder(uidvalidity \\ 1) do
    %{uidvalidity: uidvalidity, uidnext: 1, modseq: 0, messages: %{}}
  end

  defp put_folder_state(state, folder, folder_state) do
    %{state | folders: Map.put(state.folders, folder, folder_state)}
  end

  defp update_folder(state, folder, fun) do
    case Map.fetch(state.folders, folder) do
      :error -> state
      {:ok, folder_state} -> put_folder_state(state, folder, fun.(folder_state))
    end
  end

  defp bump_folder(folder_state), do: %{folder_state | modseq: folder_state.modseq + 1}

  defp put_updated_message(folder_state, uid, updated_msg) do
    new_modseq = folder_state.modseq + 1
    updated_msg = %{updated_msg | modseq: new_modseq}

    %{
      folder_state
      | modseq: new_modseq,
        messages: Map.put(folder_state.messages, uid, updated_msg)
    }
  end

  # Inserts a brand-new message, auto-assigning `uid = folder's uidnext`.
  # Returns `{uid, new_state}`.
  defp insert_message(state, folder, raw, flags, internal_date, gm_msgid) do
    folder_state = Map.get(state.folders, folder, new_folder())
    uid = folder_state.uidnext
    new_modseq = folder_state.modseq + 1

    msg = %{
      uid: uid,
      flags: flags,
      raw: raw,
      internal_date: internal_date,
      gm_msgid: gm_msgid,
      modseq: new_modseq
    }

    new_folder_state = %{
      folder_state
      | uidnext: uid + 1,
        modseq: new_modseq,
        messages: Map.put(folder_state.messages, uid, msg)
    }

    {uid, put_folder_state(state, folder, new_folder_state)}
  end

  # Like insert_message/6, but in gmail mode also mirrors into All Mail
  # (unless `folder` already IS All Mail). Returns `{uid, new_state}` for
  # the PRIMARY folder's occurrence.
  defp insert_with_mirror(state, folder, raw, flags, internal_date, gm_msgid) do
    {uid, state} = insert_message(state, folder, raw, flags, internal_date, gm_msgid)

    state =
      if state.gmail and folder != @all_mail do
        {_all_mail_uid, state} =
          insert_message(state, @all_mail, raw, flags, internal_date, gm_msgid)

        state
      else
        state
      end

    {uid, state}
  end

  defp normalize_internal_date(nil), do: Date.utc_today()
  defp normalize_internal_date(%Date{} = date), do: date
  defp normalize_internal_date(str) when is_binary(str), do: parse_date(str)

  # Assigns a stable decimal-string gm_msgid keyed by a content hash of
  # `raw` — the SAME raw bytes always resolve to the SAME gm_msgid, however
  # many folders/occurrences they end up copied into. Returns `{gm_msgid, new_state}`.
  #
  # Keyed by a SHA-256 digest of `raw`, not `:erlang.phash2/2` — phash2 is a
  # 32-bit (or narrower, per the range arg) hash explicitly NOT designed for
  # content-identity use and collides far too easily for that; SHA-256 gives
  # genuine content identity with a collision window this model need not
  # worry about.
  defp gm_msgid_for(state, raw) do
    hash = :crypto.hash(:sha256, raw)

    case Map.fetch(state.content_hashes, hash) do
      {:ok, gm_msgid} ->
        {gm_msgid, state}

      :error ->
        seq = state.gm_msgid_seq + 1
        gm_msgid = Integer.to_string(seq)

        state = %{
          state
          | gm_msgid_seq: seq,
            content_hashes: Map.put(state.content_hashes, hash, gm_msgid)
        }

        {gm_msgid, state}
    end
  end

  # -- capability wire names ----------------------------------------------------

  defp capability_wire_name(:condstore), do: "CONDSTORE"
  defp capability_wire_name(:qresync), do: "QRESYNC"
  defp capability_wire_name(:move), do: "MOVE"
  defp capability_wire_name(:uidplus), do: "UIDPLUS"
  defp capability_wire_name(:gmail), do: "X-GM-EXT-1"
end
