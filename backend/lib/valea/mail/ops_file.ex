defmodule Valea.Mail.OpsFile do
  @moduledoc """
  The declared-ops file grammar + link-safe opaque claiming
  (mail-as-maildir design spec E, §Sync engine — Push (declared ops)).

  An agent (or the Valea UI, via RPC) declares mailbox mutations as a YAML
  list of operations from a **closed vocabulary** under
  `sources/mail/<account>/ops/pending/`. This module is the parse +
  occurrence-validate + claim + result/replay surface the executor
  (`Valea.Mail.OpsExecutor`) drives; it performs no remote I/O and holds no
  ledger state of its own.

  ## Vocabulary

      - op: move
        msg_id: <msg_id>
        from: <exact IMAP mailbox name>
        to:   <exact IMAP mailbox name>

      - op: flag
        msg_id: <msg_id>
        folder: <exact IMAP mailbox name>
        add:    [S, R, F]     # pushable flags only (S/R/F)
        remove: [S, R, F]

  `parse/1` is strict: an unknown `op`, an unknown key on a known op, a
  missing required key, a flag letter outside `S`/`R`/`F` (in either `add`
  or `remove`), a non-list document, or an empty list is an error — never a
  guess. It returns ops as maps with **atom** keys and an atom `op` value.

  ## Opaque-id, link-safe claiming (§Push)

  `claim_next/2` claims the oldest pending file (by mtime) by atomically
  **renaming** it into the engine-owned `ops/done/` under an
  engine-generated opaque op-id (`<opid>.yaml`, no-replace: the destination
  is re-checked and the opid regenerated before the rename, so no
  agent-chosen filename can ever clobber an existing claim, its
  `.result.yaml`, or a crash-recovery record). Claiming is link-safe: a
  pending entry must be a **regular file with a single link**
  (`File.lstat/1`, no-follow) — symlinks and hard-linked files are moved to
  `quarantine/` and never parsed. After the rename the bytes are read
  through the same open-verify-read helper (`read_claimed!/1`) — link count
  and type re-checked on the descriptor's path — so a hardlink minted into
  an agent-writable dir after the check cannot swap what the executor sees;
  boot replay (`unresolved/2` → `read_claimed!/1`) re-runs that check and
  refuses a since-tampered copy.

  Per-op outcomes are written to a separate engine-created result file bound
  to the same op-id (`<opid>.result.yaml`); flag ops additionally record a
  durable recovery baseline in `<opid>.state.yaml` (`write_op_state!/5`)
  **before** their remote I/O. A claimed file lacking its `.result.yaml`
  sibling is unresolved (`unresolved/2`) — the boot replay set.

  ## Encoding

  The engine-owned sidecars (`.result.yaml`, `.state.yaml`) are written as
  pretty-printed JSON, which is a strict subset of YAML (round-trips through
  `YamlElixir` — see `read_op_states/3`): it sidesteps a hand-rolled YAML
  encoder for the nested/heterogeneous shapes these files carry while
  keeping them valid, agent-readable `.yaml`.
  """

  @pushable ~w(S R F)
  @move_keys ~w(op msg_id from to)
  @flag_keys ~w(op msg_id folder add remove)
  @opid_re ~r/^[a-z2-7]{26}\.yaml$/

  @type op ::
          %{op: :move, msg_id: String.t(), from: String.t(), to: String.t()}
          | %{
              op: :flag,
              msg_id: String.t(),
              folder: String.t(),
              add: [String.t()],
              remove: [String.t()]
            }

  @type validate_ctx :: %{
          account: String.t(),
          occurrences_by_msg_id: (String.t() -> [map()]),
          known_folders: MapSet.t(String.t()),
          write_through: MapSet.t(String.t())
        }

  # -- parse ------------------------------------------------------------------

  @doc """
  Parses `yaml` into a list of ops from the closed vocabulary. Strict:
  unknown op/keys/flags → `{:error, reason}`; an empty list → error; a
  non-list document → error; unparseable YAML → error (never a raise).
  """
  @spec parse(binary()) :: {:ok, [op()]} | {:error, String.t()}
  def parse(yaml) when is_binary(yaml) do
    case safe_yaml(yaml) do
      {:ok, list} when is_list(list) and list != [] ->
        parse_ops(list)

      {:ok, []} ->
        {:error, "ops file is an empty list"}

      {:ok, _other} ->
        {:error, "ops file must be a YAML list of operations"}

      {:error, reason} ->
        {:error, "unparseable ops file: #{reason}"}
    end
  end

  defp safe_yaml(yaml) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, doc} -> {:ok, doc}
      {:error, error} -> {:error, describe_yaml_error(error)}
    end
  rescue
    error -> {:error, describe_yaml_error(error)}
  end

  defp describe_yaml_error(%{message: message}) when is_binary(message), do: message
  defp describe_yaml_error(other), do: inspect(other)

  defp parse_ops(list) do
    list
    |> Enum.reduce_while({:ok, []}, fn raw, {:ok, acc} ->
      case parse_op(raw) do
        {:ok, op} -> {:cont, {:ok, [op | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, ops} -> {:ok, Enum.reverse(ops)}
      {:error, _} = error -> error
    end
  end

  @doc """
  Parses a SINGLE already-decoded op map (string keys, e.g. an RPC-supplied
  op) against the closed vocabulary. `{:ok, op}` or `{:error, reason}` — the
  per-op entry point the RPC path uses so one malformed op rejects only
  itself, not the whole batch.
  """
  @spec parse_one(map()) :: {:ok, op()} | {:error, String.t()}
  def parse_one(raw) when is_map(raw), do: parse_op(raw)

  defp parse_op(%{"op" => "move"} = raw) do
    with :ok <- exact_keys(raw, @move_keys, "move"),
         {:ok, msg_id} <- required_string(raw, "msg_id"),
         {:ok, from} <- required_string(raw, "from"),
         {:ok, to} <- required_string(raw, "to") do
      {:ok, %{op: :move, msg_id: msg_id, from: from, to: to}}
    end
  end

  defp parse_op(%{"op" => "flag"} = raw) do
    with :ok <- exact_keys(raw, @flag_keys, "flag"),
         {:ok, msg_id} <- required_string(raw, "msg_id"),
         {:ok, folder} <- required_string(raw, "folder"),
         {:ok, add} <- flag_list(raw, "add"),
         {:ok, remove} <- flag_list(raw, "remove") do
      {:ok, %{op: :flag, msg_id: msg_id, folder: folder, add: add, remove: remove}}
    end
  end

  defp parse_op(%{"op" => other}),
    do: {:error, "unknown op #{inspect(other)} (only move/flag are allowed)"}

  defp parse_op(_raw), do: {:error, "each op must be a mapping with an `op` key"}

  defp exact_keys(raw, allowed, label) do
    keys = Map.keys(raw)
    allowed_set = MapSet.new(allowed)

    extra = Enum.reject(keys, &MapSet.member?(allowed_set, &1))
    missing = Enum.reject(allowed, &Map.has_key?(raw, &1))

    cond do
      extra != [] -> {:error, "#{label} op has unknown key(s): #{Enum.join(extra, ", ")}"}
      missing != [] -> {:error, "#{label} op is missing key(s): #{Enum.join(missing, ", ")}"}
      true -> :ok
    end
  end

  defp required_string(raw, key) do
    case Map.get(raw, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "#{key} must be a non-empty string"}
    end
  end

  defp flag_list(raw, key) do
    case Map.get(raw, key) do
      list when is_list(list) ->
        if Enum.all?(list, &(&1 in @pushable)) do
          {:ok, list}
        else
          {:error, "#{key} may only contain pushable flags S/R/F"}
        end

      _ ->
        {:error, "#{key} must be a list of pushable flags (S/R/F)"}
    end
  end

  # -- validate ---------------------------------------------------------------

  @doc """
  Validates one parsed op against current occurrence state (`ctx`).

    * move: `msg_id` resolves to EXACTLY ONE occurrence in `from`; `to` is a
      known folder or a write-through target; `to != from`.
    * flag: `msg_id` resolves to exactly one occurrence in `folder`;
      `add`/`remove` are already S/R/F by construction (`parse/1`).

  `:ok` or `{:rejected, reason}` — never a guess.
  """
  @spec validate(op(), validate_ctx()) :: :ok | {:rejected, String.t()}
  def validate(%{op: :move, msg_id: msg_id, from: from, to: to}, ctx) do
    cond do
      to == from ->
        {:rejected, "destination equals source folder"}

      not (MapSet.member?(ctx.known_folders, to) or MapSet.member?(ctx.write_through, to)) ->
        {:rejected, "unknown destination folder #{inspect(to)}"}

      true ->
        case occurrences_in(ctx, msg_id, from) do
          [_one] -> :ok
          [] -> {:rejected, "no occurrence of #{msg_id} in #{from}"}
          _many -> {:rejected, "ambiguous: multiple occurrences of #{msg_id} in #{from}"}
        end
    end
  end

  def validate(%{op: :flag, msg_id: msg_id, folder: folder, add: add, remove: remove}, ctx) do
    cond do
      not pushable?(add) or not pushable?(remove) ->
        {:rejected, "only S/R/F flags are pushable"}

      true ->
        case occurrences_in(ctx, msg_id, folder) do
          [_one] -> :ok
          [] -> {:rejected, "no occurrence of #{msg_id} in #{folder}"}
          _many -> {:rejected, "ambiguous: multiple occurrences of #{msg_id} in #{folder}"}
        end
    end
  end

  defp pushable?(flags), do: Enum.all?(flags, &(&1 in @pushable))

  defp occurrences_in(ctx, msg_id, folder) do
    ctx.occurrences_by_msg_id.(msg_id)
    |> Enum.filter(&(&1.folder == folder and &1.msg_id != "__oversize__"))
  end

  # -- claim ------------------------------------------------------------------

  @doc """
  Claims the oldest pending ops file (by mtime) into `ops/done/` under a
  fresh opaque op-id, returning its bytes (read through `read_claimed!/1`),
  the generated opid, and the agent's original filename. `:none` when
  nothing is pending; `{:quarantined, name}` when the oldest entry is a
  symlink or hard-linked file (moved to `quarantine/`, never parsed — the
  caller may call again to reach the next entry).
  """
  @spec claim_next(String.t(), String.t()) ::
          {:ok, %{opid: String.t(), bytes: binary(), original_name: String.t()}}
          | :none
          | {:quarantined, String.t()}
  def claim_next(root, account) when is_binary(root) and is_binary(account) do
    pending = pending_dir(root, account)

    case oldest_pending(pending) do
      nil ->
        :none

      name ->
        path = Path.join(pending, name)

        case File.lstat(path, time: :posix) do
          {:ok, %File.Stat{type: :regular, links: 1}} ->
            claim_regular(root, account, path, name)

          _link_unsafe_or_gone ->
            quarantine!(root, account, path, name)
            {:quarantined, name}
        end
    end
  end

  defp oldest_pending(pending) do
    case File.ls(pending) do
      {:ok, entries} ->
        entries
        |> Enum.map(fn name -> {name, mtime(Path.join(pending, name))} end)
        |> Enum.reject(fn {_name, mtime} -> is_nil(mtime) end)
        |> Enum.sort_by(fn {name, mtime} -> {mtime, name} end)
        |> List.first()
        |> case do
          {name, _mtime} -> name
          nil -> nil
        end

      {:error, _} ->
        nil
    end
  end

  defp mtime(path) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} -> mtime
      {:error, _} -> nil
    end
  end

  defp claim_regular(root, account, path, name) do
    done = done_dir(root, account)
    File.mkdir_p!(done)
    opid = fresh_opid(done)
    done_path = Path.join(done, "#{opid}.yaml")

    case File.rename(path, done_path) do
      :ok ->
        case read_claimed!(done_path) do
          {:ok, bytes} ->
            {:ok, %{opid: opid, bytes: bytes, original_name: name}}

          {:error, _reason} ->
            # A links>1 file that slipped past the pre-rename lstat (raced) —
            # quarantine the claimed copy and report it, never parse it.
            quarantine!(root, account, done_path, name)
            {:quarantined, name}
        end

      {:error, _reason} ->
        # The claim rename itself failed — quarantine the pending entry so a
        # caller looping over `claim_next/2` advances past it rather than
        # re-selecting the same oldest file forever.
        quarantine!(root, account, path, name)
        {:quarantined, name}
    end
  end

  # A random 128-bit opid, re-rolled until it names no existing done entry
  # (no-replace: the rename must never overwrite a claim/result/state file).
  defp fresh_opid(done) do
    opid = Base.encode32(:crypto.strong_rand_bytes(16), case: :lower, padding: false)

    if File.exists?(Path.join(done, "#{opid}.yaml")) do
      fresh_opid(done)
    else
      opid
    end
  end

  @doc """
  Opens `path` no-follow, re-verifies it is a **regular file with a single
  link** (`File.lstat/1` — the same check `claim_next/2` runs pre-rename,
  re-run here on the engine-owned copy), reads ALL bytes from that
  descriptor, and closes it. `{:error, :link_unsafe}` when the type/link
  check fails — a since-minted hardlink or a swapped-in symlink is refused,
  never read as an op.
  """
  @spec read_claimed!(String.t()) :: {:ok, binary()} | {:error, term()}
  def read_claimed!(path) when is_binary(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, links: 1, size: size}} ->
        read_all(path, size)

      {:ok, _other} ->
        {:error, :link_unsafe}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_all(path, size) do
    case :file.open(path, [:read, :binary, :raw]) do
      {:ok, fd} ->
        result = :file.read(fd, size)
        :file.close(fd)

        case result do
          {:ok, bytes} -> {:ok, bytes}
          :eof -> {:ok, ""}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp quarantine!(root, account, path, name) do
    dir = quarantine_dir(root, account)
    File.mkdir_p!(dir)
    dest = Path.join(dir, "#{name}-#{System.unique_integer([:positive])}")
    File.rename(path, dest)
    :ok
  end

  # -- results + state sidecars -----------------------------------------------

  @doc """
  Writes the engine-owned per-op result file `ops/done/<opid>.result.yaml`:
  `%{"file" => original_name, "results" => [%{"op" => i, "result" =>
  "ok"|"rejected"|"needs_review", "reason" => reason}]}`.
  """
  @spec write_results!(String.t(), String.t(), String.t(), String.t(), [map()]) :: :ok
  def write_results!(root, account, opid, original_name, results)
      when is_binary(opid) and is_list(results) do
    doc = %{"file" => original_name, "results" => Enum.map(results, &stringify_result/1)}
    write_yaml!(result_path(root, account, opid), doc)
    :ok
  end

  defp stringify_result(%{} = result) do
    %{
      "op" => fetch_any(result, [:op, "op"]),
      "result" => fetch_any(result, [:result, "result"]),
      "reason" => fetch_any(result, [:reason, "reason"])
    }
  end

  defp fetch_any(map, keys), do: Enum.find_value(keys, fn k -> Map.get(map, k) end)

  @doc """
  Records index `index`'s durable flag-recovery baseline into the fsynced
  sidecar `ops/done/<opid>.state.yaml` (merged over any existing indices),
  written BEFORE that flag op's remote I/O. `state` carries at least
  `folder`, `uid`, `uidvalidity`, `baseline_flags`, `modseq`, and
  `postcondition: %{add:, remove:}` (the executor also records the source
  UIDVALIDITY + msg_id fingerprint reference).
  """
  @spec write_op_state!(String.t(), String.t(), String.t(), non_neg_integer(), map()) :: :ok
  def write_op_state!(root, account, opid, index, state)
      when is_binary(opid) and is_integer(index) and index >= 0 and is_map(state) do
    path = state_path(root, account, opid)

    existing =
      case read_yaml(path) do
        {:ok, map} when is_map(map) -> map
        _ -> %{}
      end

    merged = Map.put(existing, Integer.to_string(index), jsonable(state))
    write_yaml_fsynced!(path, merged)
    :ok
  end

  @doc """
  Reads `ops/done/<opid>.state.yaml` into `%{index => state}` (integer index
  keys, atomized state maps). Empty map when the sidecar is absent.
  """
  @spec read_op_states(String.t(), String.t(), String.t()) :: %{non_neg_integer() => map()}
  def read_op_states(root, account, opid) when is_binary(opid) do
    case read_yaml(state_path(root, account, opid)) do
      {:ok, map} when is_map(map) ->
        Map.new(map, fn {index_str, state} -> {String.to_integer(index_str), atomize(state)} end)

      _ ->
        %{}
    end
  end

  # -- unresolved -------------------------------------------------------------

  @doc """
  Every claimed ops file in `ops/done/` lacking its `.result.yaml` sibling —
  the boot replay set. Each entry is `%{opid:, path:}` (`path` is the
  engine-owned `<opid>.yaml`, replayed via `read_claimed!/1`).
  """
  @spec unresolved(String.t(), String.t()) :: [%{opid: String.t(), path: String.t()}]
  def unresolved(root, account) do
    done = done_dir(root, account)

    case File.ls(done) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&Regex.match?(@opid_re, &1))
        |> Enum.map(&String.replace_suffix(&1, ".yaml", ""))
        |> Enum.reject(&File.exists?(result_path(root, account, &1)))
        |> Enum.map(&%{opid: &1, path: Path.join(done, "#{&1}.yaml")})
        |> Enum.sort_by(& &1.opid)

      {:error, _} ->
        []
    end
  end

  # -- encoding + paths -------------------------------------------------------

  # JSON is a strict subset of YAML that YamlElixir round-trips (see the
  # moduledoc), so these engine-owned `.yaml` sidecars are Jason-encoded.
  defp write_yaml!(path, doc) do
    File.mkdir_p!(Path.dirname(path))
    atomic_write!(path, Jason.encode!(doc, pretty: true))
  end

  defp write_yaml_fsynced!(path, doc) do
    File.mkdir_p!(Path.dirname(path))
    bytes = Jason.encode!(doc, pretty: true)
    tmp = path <> ".tmp-#{System.unique_integer([:positive])}"
    File.write!(tmp, bytes)
    File.open!(tmp, [:read, :binary], fn f -> :file.datasync(f) end)
    File.rename!(tmp, path)
  end

  defp atomic_write!(path, bytes) do
    tmp = path <> ".tmp-#{System.unique_integer([:positive])}"
    File.write!(tmp, bytes)
    File.rename!(tmp, path)
  end

  defp read_yaml(path) do
    YamlElixir.read_from_file(path)
  rescue
    _ -> {:error, :unreadable}
  end

  # Coerce an atom-keyed (possibly nested) state map into a JSON-serializable
  # shape (string keys throughout); values pass through unchanged.
  defp jsonable(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), jsonable(v)} end)

  defp jsonable(list) when is_list(list), do: Enum.map(list, &jsonable/1)
  defp jsonable(value), do: value

  # Reverse of `jsonable/1` for the known state-map keys — every key here is
  # an atom the executor already references, so `to_existing_atom` is safe;
  # anything unexpected keeps its string key rather than growing the atom
  # table.
  defp atomize(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {safe_atom(k), atomize(v)} end)

  defp atomize(list) when is_list(list), do: Enum.map(list, &atomize/1)
  defp atomize(value), do: value

  defp safe_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  defp safe_atom(key), do: key

  defp account_dir(root, account), do: Path.join([root, "sources", "mail", account])
  defp pending_dir(root, account), do: Path.join([account_dir(root, account), "ops", "pending"])
  defp done_dir(root, account), do: Path.join([account_dir(root, account), "ops", "done"])
  defp quarantine_dir(root, account), do: Path.join([account_dir(root, account), "quarantine"])

  defp result_path(root, account, opid),
    do: Path.join(done_dir(root, account), "#{opid}.result.yaml")

  defp state_path(root, account, opid),
    do: Path.join(done_dir(root, account), "#{opid}.state.yaml")
end
