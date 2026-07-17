defmodule Valea.Mail.Reconcile do
  @moduledoc """
  UIDVALIDITY-reset and folder-lifecycle reconciliation for the pull engine
  (mail-as-maildir design spec, §Pull — `UIDVALIDITY` reset / §Folder
  lifecycle — hold, don't guess).

  Three server-authoritative recovery paths `Valea.Mail.SyncPass` delegates
  to, plus the pure replacement decision it consults before mutating anything:

    * `folder_reset/2` — a single folder's `UIDVALIDITY` changed, so its UID
      map is meaningless. This runs the **complete, horizon-independent**
      reconciliation the spec mandates: snapshot the pre-reset local
      occurrences, fully enumerate the folder (`UID SEARCH ALL`), re-bind each
      still-present occurrence to its new `(uidvalidity, uid)` (Message-ID
      shortcut where present, fingerprint always deciding), and only after that
      whole reconciliation SUCCEEDS remove the genuinely-vanished ones. ANY
      step failing aborts with **nothing removed** — `SyncPass` maps the
      `{:error, _}` to a deferral notice and retries next pass.

    * `detect_replacement/2` — pure decision (no I/O): a whole-mailbox
      replacement (INBOX itself re-provisioned, or a majority of the mirrored
      set re-`UIDVALIDITY`'d in one pass) is a different account behind the
      same settings, not a set of per-folder resets. `SyncPass` consults it
      BEFORE any mutation and fails closed (`{:error, :mailbox_replaced}`).

    * `folder_lifecycle/2` — after a *successful, complete* `LIST`, a
      previously-mirrored folder now absent from the mirrored set (deleted,
      renamed, or newly excluded) becomes **held**: its local data stays
      intact and readable, nothing is inferred about where it went. A held
      folder reappearing in the mirrored set is unheld. NEVER deletes local
      data — discard is a user RPC (`discard_held!/3`).

    * `discard_held!/3` — the user's typed-confirmation removal of a held
      folder's local data (maildir directory, UID map + index rows, and each
      message's shared view garbage-collected when its last occurrence goes).
  """

  alias Valea.Mail.Maildir
  alias Valea.Mail.MessageFile
  alias Valea.Mail.Store
  alias Valea.Mail.Views

  # The sentinel `msg_id` `SyncPass` records for an oversized message: a UID-map
  # row with no maildir file, view, or index row. Never re-bindable across a
  # reset (there is no local content to fingerprint), so its stale row is just
  # cleared — the next windowed backfill re-records it if it is still in-window.
  @oversize_msg_id "__oversize__"

  @typedoc "The per-folder reconciliation context `SyncPass` threads in (root, account, transport, conn, dir_rel, select, settings)."
  @type ctx :: map()

  # -- folder_reset -----------------------------------------------------------

  @doc """
  Reconciles one folder across a `UIDVALIDITY` reset. Returns
  `{:ok, %{rebound: n, removed: n}}` once the complete reconciliation has
  succeeded and been applied, or `{:error, reason}` (nothing mutated) if any
  enumeration/fetch step failed.

  The reconciliation is **complete and horizon-independent** (explicitly NOT
  the windowed first-sync algorithm): the pre-reset local occurrence set is
  snapshotted, the folder is fully enumerated (`UID SEARCH ALL`), and every
  still-present occurrence is fingerprint-confirmed against its new UID —
  so a `>window`-old, Message-ID-less, still-present message re-binds rather
  than being mistaken for a deletion. Bodies are fetched only for candidates
  a Message-ID search cannot resolve (and are memoized), but correctness beats
  efficiency: the fingerprint always decides. Nothing is removed until the
  whole reconciliation succeeds; the watermark then re-initializes as at first
  sync so new content beyond the re-bound set backfills next pass.
  """
  @spec folder_reset(ctx(), String.t()) ::
          {:ok, %{rebound: non_neg_integer(), removed: non_neg_integer()}} | {:error, term()}
  def folder_reset(ctx, folder) do
    {:ok, select} = ctx.select
    dir_abs = folder_dir_abs(ctx.root, ctx.account, ctx.dir_rel)

    with {:ok, _info} <- ctx.transport.select(ctx.conn, folder),
         {:ok, enumerated} <- ctx.transport.uid_search(ctx.conn, "ALL"),
         snapshot = snapshot_occurrences(ctx, folder, dir_abs),
         {:ok, plan} <- build_reset_plan(ctx, snapshot, enumerated) do
      # Only here — after the ENTIRE reconciliation is proven — are any local
      # mutations applied. Removals before rebinds so a removed occurrence's
      # file/rows can't be confused with a re-bound one reusing its old UID.
      apply_reset_plan(ctx, folder, dir_abs, select.uidvalidity, plan)
      persist_reset_state(ctx, folder, select, enumerated)
      {:ok, %{rebound: length(plan.rebinds), removed: length(plan.removals)}}
    end
  end

  # Pre-reset local occurrences, split into re-bind CANDIDATES (real messages,
  # each carrying the fingerprint + Message-ID + on-disk filename needed to
  # match and relocate it) and OVERSIZE sentinel rows (cleared, never matched).
  defp snapshot_occurrences(ctx, folder, dir_abs) do
    by_uid = dir_abs |> Maildir.list_occurrences() |> Map.new(&{&1.uid, &1})

    {reals, oversize} =
      ctx.account
      |> Store.occurrences(folder)
      |> Enum.split_with(&(&1.msg_id != @oversize_msg_id))

    candidates =
      Enum.map(reals, fn occ ->
        {fingerprint, message_id, filename, flags} =
          local_identity(ctx, dir_abs, occ, Map.get(by_uid, occ.uid))

        %{
          uid: occ.uid,
          msg_id: occ.msg_id,
          flags: flags,
          filename: filename,
          fingerprint: fingerprint,
          message_id: message_id
        }
      end)

    %{candidates: candidates, oversize: Enum.map(oversize, & &1.uid)}
  end

  # The on-disk maildir file is the source of truth for both fingerprint and
  # Message-ID. When it's missing (out-of-band damage), fall back to the stored
  # fingerprint sidecar + the index row's Message-ID — a `nil` fingerprint then
  # means "cannot confirm", so the occurrence can only fall through to removal.
  defp local_identity(ctx, dir_abs, occ, %{filename: filename, flags: flags}) do
    case File.read(Path.join([dir_abs, "cur", filename])) do
      {:ok, raw} -> {MessageFile.fingerprint(raw), extract_message_id(raw), filename, flags}
      {:error, _} -> stored_identity(ctx, occ)
    end
  end

  defp local_identity(ctx, _dir_abs, occ, nil), do: stored_identity(ctx, occ)

  defp stored_identity(ctx, occ) do
    fingerprint = Views.stored_fingerprint(ctx.root, ctx.account, occ.msg_id)
    filename = Maildir.encode_filename(occ.msg_id, occ.uid, occ.flags)
    {fingerprint, index_message_id(ctx.account, occ.msg_id), filename, occ.flags}
  end

  defp index_message_id(account, msg_id) do
    case Store.message_rows_by_msg_id(account, msg_id) do
      [row | _] -> row.message_id
      [] -> nil
    end
  end

  # Read-only planning: decide re-bind vs removal for every candidate. Threads
  # the still-available new UIDs, a memoized uid→fingerprint cache, and the two
  # result lists; short-circuits to `{:error, _}` on the first transport
  # failure so `apply_reset_plan/5` is never reached with a partial picture.
  defp build_reset_plan(ctx, snapshot, enumerated) do
    initial = %{available: MapSet.new(enumerated), fp_cache: %{}, rebinds: [], removals: []}

    snapshot.candidates
    |> Enum.reduce_while({:ok, initial}, fn cand, {:ok, state} ->
      case match_candidate(ctx, cand, state) do
        {:ok, {:rebind, new_uid, state}} ->
          {:cont, {:ok, %{state | rebinds: [{cand, new_uid} | state.rebinds]}}}

        {:ok, {:removal, state}} ->
          {:cont, {:ok, %{state | removals: [cand | state.removals]}}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, state} ->
        {:ok,
         %{
           rebinds: Enum.reverse(state.rebinds),
           removals: Enum.reverse(state.removals),
           oversize: snapshot.oversize
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # No local fingerprint to confirm against -> can only be a removal.
  defp match_candidate(_ctx, %{fingerprint: nil}, state), do: {:ok, {:removal, state}}

  defp match_candidate(ctx, cand, state) do
    case message_id_candidates(ctx, cand, state) do
      {:ok, mid_uids} ->
        # Message-ID candidates first (the shortcut), then every other
        # still-available UID as the fingerprint fallback — so a Message-ID-less
        # occurrence, or one whose Message-ID collides/moved, still matches by
        # content. `fingerprint always decides`.
        ordered = mid_uids ++ (MapSet.to_list(state.available) -- mid_uids)
        find_fingerprint_match(ctx, cand, ordered, state)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp message_id_candidates(_ctx, %{message_id: nil}, _state), do: {:ok, []}
  defp message_id_candidates(_ctx, %{message_id: ""}, _state), do: {:ok, []}

  defp message_id_candidates(ctx, %{message_id: mid}, state) do
    if safe_message_id_for_search?(mid) do
      case ctx.transport.uid_search(ctx.conn, "HEADER Message-ID #{mid}") do
        {:ok, uids} -> {:ok, Enum.filter(uids, &MapSet.member?(state.available, &1))}
        {:error, reason} -> {:error, reason}
      end
    else
      # `mid` is interpolated VERBATIM into the search criteria string above.
      # A malformed/adversarial Message-ID carrying an IMAP-significant
      # character would corrupt that string on a real server (space breaks
      # the atom into two search terms; quote/backslash escape out of a
      # quoted string; parens/braces are list/literal syntax; `%`/`*` are
      # LIST wildcards) and come back BAD — aborting `build_reset_plan/3`'s
      # `reduce_while` short-circuit and wedging reset reconciliation forever
      # (the whole point of this shortcut is to be an optimization, never a
      # correctness dependency). Skip it: an empty candidate list here just
      # means `find_fingerprint_match/4` falls through to the full available
      # set — `fingerprint always decides`, so this occurrence still
      # resolves correctly, just without the fast path.
      {:ok, []}
    end
  end

  # Conservative allowlist for the Message-ID shortcut: printable,
  # non-whitespace US-ASCII (`0x21`–`0x7E`) MINUS the characters IMAP search
  # syntax gives special meaning to: `"` `(` `)` `\` `{` `}` `%` `*`. Anything
  # outside this — including a bare space, which `0x21..0x7E` already
  # excludes — skips the shortcut rather than risking a malformed search
  # string reaching the transport.
  @unsafe_message_id_chars ~r/["()\\{}%*]/

  defp safe_message_id_for_search?(mid) do
    String.match?(mid, ~r/^[\x21-\x7E]+$/) and not String.match?(mid, @unsafe_message_id_chars)
  end

  defp find_fingerprint_match(_ctx, _cand, [], state), do: {:ok, {:removal, state}}

  defp find_fingerprint_match(ctx, cand, [uid | rest], state) do
    case uid_fingerprint(ctx, uid, state) do
      {:ok, fp, state} ->
        if fp == cand.fingerprint do
          {:ok, {:rebind, uid, %{state | available: MapSet.delete(state.available, uid)}}}
        else
          find_fingerprint_match(ctx, cand, rest, state)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp uid_fingerprint(ctx, uid, state) do
    case Map.fetch(state.fp_cache, uid) do
      {:ok, fp} ->
        {:ok, fp, state}

      :error ->
        case ctx.transport.uid_fetch_full(ctx.conn, uid) do
          {:ok, raw} ->
            fp = MessageFile.fingerprint(raw)
            {:ok, fp, %{state | fp_cache: Map.put(state.fp_cache, uid, fp)}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # -- apply (local-only, no transport calls) ---------------------------------

  defp apply_reset_plan(ctx, folder, dir_abs, new_uidvalidity, plan) do
    Enum.each(plan.removals, &apply_removal(ctx, folder, dir_abs, &1))

    Enum.each(plan.rebinds, fn {cand, new_uid} ->
      apply_rebind(ctx, folder, dir_abs, new_uidvalidity, cand, new_uid)
    end)

    Enum.each(plan.oversize, &Store.delete_occurrence(ctx.account, folder, &1))
  end

  defp apply_removal(ctx, folder, dir_abs, cand) do
    File.rm(Path.join([dir_abs, "cur", cand.filename]))
    Store.delete_occurrence(ctx.account, folder, cand.uid)
    Store.delete_index_row(ctx.account, folder, cand.uid)

    remaining = Store.occurrences_by_msg_id(ctx.account, cand.msg_id)
    Views.remove_occurrence(ctx.root, ctx.account, cand.msg_id, length(remaining))
    if remaining != [], do: refresh_view(ctx.root, ctx.account, cand.msg_id)
  end

  defp apply_rebind(ctx, folder, dir_abs, new_uidvalidity, cand, new_uid) do
    new_filename = Maildir.encode_filename(cand.msg_id, new_uid, cand.flags)

    if new_filename != cand.filename do
      cur = Path.join(dir_abs, "cur")
      File.rename(Path.join(cur, cand.filename), Path.join(cur, new_filename))
    end

    Store.delete_occurrence(ctx.account, folder, cand.uid)

    Store.put_occurrence(ctx.account, folder, %{
      uid: new_uid,
      uidvalidity: new_uidvalidity,
      msg_id: cand.msg_id,
      flags: cand.flags
    })

    rebind_index_row(ctx, folder, cand, new_uid, new_filename)
  end

  @blank_index_meta %{
    message_id: nil,
    from_name: nil,
    from_email: nil,
    subject: nil,
    date: nil,
    has_attachments: false,
    in_reply_to: nil,
    references: nil
  }

  # The occurrence's message metadata is unchanged by a re-bind — only its uid
  # and maildir path move — so carry the OLD index row's fields forward under
  # the new `(account, folder, uid)` key rather than re-parsing the view.
  defp rebind_index_row(ctx, folder, cand, new_uid, new_filename) do
    old =
      ctx.account
      |> Store.message_rows_by_msg_id(cand.msg_id)
      |> Enum.find(&(&1.folder == folder and &1.uid == cand.uid))

    Store.delete_index_row(ctx.account, folder, cand.uid)

    meta = old || @blank_index_meta

    path =
      Path.join(["sources", "mail", ctx.account, "maildir", ctx.dir_rel, "cur", new_filename])

    Store.upsert_index_row(%{
      account: ctx.account,
      folder: folder,
      uid: new_uid,
      msg_id: cand.msg_id,
      message_id: meta.message_id,
      from_name: meta.from_name,
      from_email: meta.from_email,
      subject: meta.subject,
      date: meta.date,
      flags: cand.flags |> Enum.sort() |> Enum.join(),
      has_attachments: meta.has_attachments,
      path: path,
      in_reply_to: meta.in_reply_to,
      references: meta.references
    })
  end

  # Re-init the watermark as at first sync (`UIDNEXT − 1`, else `max(UID)`),
  # clear the CONDSTORE token, and reopen backfill so new content beyond the
  # re-bound set pulls next pass. `dir`/`held` are preserved (read-modify-write).
  defp persist_reset_state(ctx, folder, select, enumerated) do
    watermark =
      cond do
        is_integer(select[:uidnext]) -> select.uidnext - 1
        enumerated == [] -> 0
        true -> Enum.max(enumerated)
      end

    Store.put_sync_state(ctx.account, folder, %{
      uidvalidity: select.uidvalidity,
      high_water_uid: watermark,
      highestmodseq: nil,
      backfill_complete: false,
      last_pass_at: now_iso8601(),
      last_error: nil
    })
  end

  defp refresh_view(root, account, msg_id) do
    occs = Store.occurrences_by_msg_id(account, msg_id)
    folders = occs |> Enum.map(& &1.folder) |> Enum.uniq()

    flags_union =
      occs
      |> Enum.flat_map(&MapSet.to_list(&1.flags))
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.join()

    Views.refresh_folders(root, account, msg_id, folders, flags_union)
  end

  # -- detect_replacement -----------------------------------------------------

  @doc """
  Decides whether the set of folders that reset their `UIDVALIDITY` this pass
  amounts to a whole-mailbox **replacement** (a different account behind the
  same settings) rather than a set of ordinary per-folder resets.

  `:mailbox_replaced` when INBOX itself reset, or when strictly more than half
  the mirrored folders reset in one pass; `:ok` otherwise. Pure — no I/O — so
  `SyncPass` can consult it BEFORE mutating anything and bail out cleanly.
  """
  @spec detect_replacement([String.t()], [String.t()]) :: :mailbox_replaced | :ok
  def detect_replacement(reset_folders, mirrored)
      when is_list(reset_folders) and is_list(mirrored) do
    if "INBOX" in reset_folders or length(reset_folders) * 2 > length(mirrored) do
      :mailbox_replaced
    else
      :ok
    end
  end

  # -- reselect_diverged? ------------------------------------------------------

  @doc """
  Pure decision: has this folder's `UIDVALIDITY` diverged between `SyncPass`
  Phase A's scan-time `SELECT` (`scan_select`, the value `reset?/2` already
  used to decide this folder is NOT resetting) and the Phase-B re-`SELECT`
  (`reselect`) taken immediately before discovery/flags/deletions run?

  A reset landing in that narrow window makes Phase A's `reset?: false`
  decision stale: proceeding with the OLD `select`/watermark would run
  ordinary reconciliation against renumbered UIDs, and the deletion pass's
  "known UID absent from a successful ALL enumeration" comparison would
  mass-remove every renumbered-but-still-present occurrence. `SyncPass` must
  defer the folder instead (no `put_sync_state`) so next pass's `reset?/2`
  sees the still-stored (pre-reset) `uidvalidity`, correctly detects the
  reset, and runs the proper `folder_reset/2` reconciliation.
  """
  @spec reselect_diverged?(%{uidvalidity: integer()}, %{uidvalidity: integer()}) :: boolean()
  def reselect_diverged?(%{uidvalidity: scan_uidvalidity}, %{uidvalidity: reselect_uidvalidity})
      when is_integer(scan_uidvalidity) and is_integer(reselect_uidvalidity) do
    scan_uidvalidity != reselect_uidvalidity
  end

  # -- folder_lifecycle -------------------------------------------------------

  @doc """
  Reconciles the persisted known-folder set against `listed` (the mirrored set
  from a *successful, complete* `LIST`). A previously-mirrored, non-held folder
  now absent from `listed` — deleted, renamed, or newly excluded — becomes
  **held** (local data kept, its pending ops rejected once Task 13 wires that);
  a held folder reappearing in `listed` is unheld. Never deletes local data;
  never infers a rename. Returns `{:ok, notices}`.
  """
  @spec folder_lifecycle(ctx(), [String.t()]) :: {:ok, [String.t()]}
  def folder_lifecycle(ctx, listed) when is_list(listed) do
    listed_set = MapSet.new(listed)

    notices =
      ctx.account
      |> Store.folders()
      |> Enum.reduce([], fn state, acc ->
        cond do
          not state.held and not MapSet.member?(listed_set, state.folder) ->
            Store.mark_held(ctx.account, state.folder, true)

            [
              "folder #{state.folder}: disappeared from the mirrored LIST; held — resolve from the Mail page"
              | acc
            ]

          state.held and MapSet.member?(listed_set, state.folder) ->
            Store.mark_held(ctx.account, state.folder, false)

            [
              "folder #{state.folder}: reappeared in the mirrored LIST; unheld, will reconcile next pass"
              | acc
            ]

          true ->
            acc
        end
      end)

    {:ok, Enum.reverse(notices)}
  end

  # -- discard_held! ----------------------------------------------------------

  @doc """
  Removes a held folder's local data on the user's typed confirmation: its
  maildir directory, its UID-map + index rows, and — per message — its shared
  view/attachments garbage-collected only when this was the message's last
  occurrence (a copy still in another folder keeps the view). `{:error,
  :not_held}` when the folder isn't currently held (or doesn't exist).
  """
  @spec discard_held!(String.t(), String.t(), String.t()) :: :ok | {:error, :not_held}
  def discard_held!(root, account, folder)
      when is_binary(root) and is_binary(account) and is_binary(folder) do
    case Store.get_sync_state(account, folder) do
      {:ok, %{held: true} = state} ->
        surviving_msg_ids =
          account
          |> Store.occurrences(folder)
          |> Enum.reduce(MapSet.new(), fn occ, acc ->
            Store.delete_occurrence(account, folder, occ.uid)
            Store.delete_index_row(account, folder, occ.uid)

            if occ.msg_id != @oversize_msg_id do
              remaining = Store.occurrences_by_msg_id(account, occ.msg_id)
              Views.remove_occurrence(root, account, occ.msg_id, length(remaining))
              if remaining != [], do: MapSet.put(acc, occ.msg_id), else: acc
            else
              acc
            end
          end)

        # Drops the sync_state row (and any residual uid_map/index rows).
        Store.clear_folder(account, folder)
        if is_binary(state.dir), do: File.rm_rf(folder_dir_abs(root, account, state.dir))

        # Every surviving shared view must drop the just-discarded folder from
        # its `folders:`/`flags:` frontmatter — recomputed from each msg_id's
        # FULL remaining occurrence set now that this folder's rows are truly
        # gone (after `clear_folder/2`, in case it cleaned up anything the
        # loop above missed), the same refresh shape `apply_removal/4` uses.
        Enum.each(surviving_msg_ids, &refresh_view(root, account, &1))

        :ok

      _ ->
        {:error, :not_held}
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp extract_message_id(raw) do
    header =
      case :binary.split(raw, ["\r\n\r\n", "\n\n"]) do
        [h, _body] -> h
        [h] -> h
      end

    header
    |> String.split(~r/\r\n|\n/)
    |> Enum.find_value(fn line ->
      case String.split(line, ":", parts: 2) do
        [name, value] ->
          if String.downcase(String.trim(name)) == "message-id", do: String.trim(value)

        _ ->
          nil
      end
    end)
  end

  defp folder_dir_abs(root, account, dir_rel),
    do: Path.join([root, "sources", "mail", account, "maildir", dir_rel])

  defp now_iso8601, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
