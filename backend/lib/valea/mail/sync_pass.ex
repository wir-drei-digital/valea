defmodule Valea.Mail.SyncPass do
  @moduledoc """
  The pull engine (mail-as-maildir design spec, §Pull (server → local)). One
  `run/1` mirrors the server's mirrored folder set — its new occurrences,
  flag changes, and server-side deletions — into the account's local maildir
  tree + derived views + `Valea.Mail.Store` cache. Pull only: `ops_enabled:
  false` for now (Task 13 wires push).

  ## Per-folder pipeline

  For every folder in `LIST` minus `settings.sync.exclude_folders`:

    1. **Bind + select.** Resolve the folder's local maildir directory: an
       on-disk `.folder` identity wins (authoritative after a SQLite loss),
       then a `mail_sync_state` binding, then a fresh allocation via
       `Valea.Mail.Maildir.folder_to_dir/2` (taken-set = every known
       `mail_sync_state` dir plus every existing maildir directory name).
       `SELECT` the folder to read its `UIDVALIDITY`/`UIDNEXT`/`HIGHESTMODSEQ`.
    2. **Reset guard.** A `UIDVALIDITY` that differs from the stored one is a
       reset. Across the whole pass, if the reset set is a whole-mailbox
       *replacement* (`Valea.Mail.Reconcile.detect_replacement/2`), abort with
       `{:error, :mailbox_replaced}` BEFORE mutating anything. An ordinary
       single-folder reset defers to `Reconcile.folder_reset/2` — a Task-8
       stub today, so the folder is left untouched with a notice.
    3. **Discovery.** First sync: watermark := `UIDNEXT − 1` (or `max(UID)`
       from `UID SEARCH ALL` when `UIDNEXT` is unknown). Every pass:
       `UID SEARCH UID <hw+1>:*` (client-side `above?/2` guards the `n:*`
       reversed-range quirk) lands every UID above the watermark regardless of
       date, advancing the watermark. Until `backfill_complete`, the windowed
       `UID SEARCH SINCE <horizon>` re-runs each pass, landing any still-
       missing in-window UID (idempotent by UID).
    4. **Landing.** `UID FETCH` size-checked against `max_message_bytes`
       (oversized → skipped, counted, recorded as `__oversize__` so it is
       never re-fetched), else `BODY.PEEK` → `Valea.Mail.Views.land/4`
       (fingerprint dedupe) → `Maildir.deliver!/3` → `Store.put_occurrence` +
       `upsert_index_row` + a `Views.refresh_folders/5` recomputed from the
       message's FULL occurrence set.
    5. **Flags.** CONDSTORE-gated where advertised, else a plain
       `UID FETCH FLAGS` of the mirrored set; a changed flag set rewrites the
       maildir filename suffix + the UID map + the index row + the view.
    6. **Deletions.** Authoritative `UID SEARCH ALL`; a known UID absent from
       a *successful* result is removed (file, UID map, index row, and — when
       it was the last occurrence — the shared view). A failed/short search
       removes nothing. `HIGHESTMODSEQ` is persisted only after this.
    7. **Damage repair.** A UID-map row whose local file vanished is re-
       fetched (fingerprint-verified) and restored; an unknown/unparseable
       file in `maildir/` is moved to `quarantine/` with a notice.

  ## Result

  `{:ok, %{new_messages:, errors:, notices:}}` on a completed pass;
  `{:error, :auth_failed}` / `{:error, :mailbox_replaced}` / `{:error, term}`
  otherwise. `errors` collects per-message/per-folder failures that did not
  abort the pass (oversized, a fetch that failed); `notices` carries reset-
  deferral, restore, and quarantine strings for status.

  ## Engine bridge (TEMP, removed in Task 13)

  `Valea.Mail.Engine` still calls `run/1` with the v3-bridge arg shape (no
  `account`, a v3-shaped settings map) and only ever exercises the connect /
  `auth_failed` / logout contract in its tests (its transports hang or fail at
  connect). So `run/1` still connects and passes those outcomes through
  verbatim, and when `args` carries no `:account` it logs out and reports an
  empty pass rather than attempting a pull it has no v4 settings for.
  """

  alias Valea.Mail.Maildir
  alias Valea.Mail.MessageFile
  alias Valea.Mail.Reconcile
  alias Valea.Mail.Store
  alias Valea.Mail.Views

  @oversize_msg_id "__oversize__"

  @type result :: %{
          new_messages: non_neg_integer(),
          errors: [String.t()],
          notices: [String.t()]
        }

  @type args :: %{
          root: String.t(),
          account: String.t(),
          settings: Valea.Mail.Settings.t(),
          credential: (-> String.t()) | String.t(),
          transport: module(),
          ops_enabled: boolean()
        }

  @doc """
  Runs one pull pass. See the moduledoc for the full pipeline + result
  contract.
  """
  @spec run(args()) ::
          {:ok, result()}
          | {:error, :auth_failed}
          | {:error, :mailbox_replaced}
          | {:error, term()}
  def run(%{settings: settings, credential: credential, transport: transport} = args) do
    connect_opts = Map.get(args, :connect_opts, [])

    case transport.connect(settings.imap, resolve_credential(credential), connect_opts) do
      {:ok, conn} ->
        try do
          do_run(args, conn)
        after
          safe_logout(transport, conn)
        end

      {:error, :auth_failed} ->
        {:error, :auth_failed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The engine's TEMP v3-bridge path: no `:account` -> nothing to pull, keep
  # the connect/logout/no-op contract the engine's tests depend on.
  defp do_run(%{account: account} = args, conn) when is_binary(account) do
    ctx = %{
      root: args.root,
      account: account,
      settings: args.settings,
      transport: args.transport,
      conn: conn,
      ops_enabled: Map.get(args, :ops_enabled, false)
    }

    pull(ctx)
  end

  defp do_run(_args, _conn), do: {:ok, empty_result()}

  # -- pull orchestration -----------------------------------------------------

  defp pull(ctx) do
    case ctx.transport.list_folders(ctx.conn) do
      {:ok, listed} ->
        mirrored = mirrored_folders(listed, ctx.settings)
        scans = scan_folders(ctx, mirrored)
        reset_folders = for s <- scans, s.reset?, do: s.folder

        case Reconcile.detect_replacement(reset_folders, mirrored) do
          :mailbox_replaced ->
            {:error, :mailbox_replaced}

          :ok ->
            {:ok, Enum.reduce(scans, empty_result(), &process_folder(ctx, &1, &2))}
        end

      {:error, reason} ->
        # A failed/partial LIST changes nothing (spec §Folder lifecycle).
        {:error, {:list_failed, reason}}
    end
  end

  # LIST minus exclude_folders. The transport model returns plain selectable
  # names; a real client's `\Noselect` mailboxes would be filtered here too
  # (noted as a gap — the transport surface carries no selectability flag yet).
  defp mirrored_folders(listed, settings) do
    excluded = MapSet.new(settings.sync.exclude_folders)
    Enum.reject(listed, &MapSet.member?(excluded, &1))
  end

  # -- Phase A: bind + select + detect resets (read-only, no persistence) -----

  defp scan_folders(ctx, mirrored) do
    identity_map = existing_identity_map(ctx.root, ctx.account)
    taken0 = taken_dirs(ctx.account, identity_map)

    {scans, _taken} =
      Enum.map_reduce(mirrored, taken0, fn folder, taken ->
        {dir_rel, taken} = resolve_dir(folder, ctx.account, identity_map, taken)
        stored = stored_sync_state(ctx.account, folder)
        select = ctx.transport.select(ctx.conn, folder)

        scan = %{
          folder: folder,
          dir_rel: dir_rel,
          stored: stored,
          select: select,
          reset?: reset?(stored, select)
        }

        {scan, taken}
      end)

    scans
  end

  defp reset?(stored, {:ok, %{uidvalidity: uidvalidity}}) do
    is_map(stored) and is_integer(stored.uidvalidity) and stored.uidvalidity != uidvalidity
  end

  defp reset?(_stored, _select), do: false

  # -- Phase B: per-folder processing -----------------------------------------

  defp process_folder(_ctx, %{select: {:error, reason}, folder: folder}, acc) do
    add_error(acc, "select failed for #{folder}: #{inspect(reason)}")
  end

  defp process_folder(ctx, %{reset?: true, folder: folder} = scan, acc) do
    # Single-folder reset (a whole-mailbox replacement already aborted in
    # `pull/1`). `Reconcile.folder_reset/2` is a Task-8 stub that always
    # returns `{:error, :not_implemented}` today — SyncPass treats a deferred
    # reset as: call the reconciler, then remove nothing, emit a notice, and
    # retry next pass. Task 8 both fills the stub AND takes over this branch's
    # real recovery wiring (re-bind matched occurrences, remove the vanished,
    # re-init the watermark).
    _ = Reconcile.folder_reset(reconcile_ctx(ctx, scan), folder)
    add_notice(acc, "folder #{folder}: UIDVALIDITY reset detected; reconciliation deferred")
  end

  defp process_folder(ctx, scan, acc) do
    {:ok, select} = scan.select
    folder = scan.folder
    dir_rel = scan.dir_rel
    dir_abs = folder_dir_abs(ctx.root, ctx.account, dir_rel)

    # Ensure the maildir subdirs + `.folder` identity BEFORE any delivery
    # (spec §Folder set). Idempotent.
    Maildir.mailbox_dirs(dir_abs)
    Maildir.write_folder_identity!(dir_abs, folder)

    # `scan.stored` is the pre-pass snapshot (Phase A is read-only). All of
    # this pass's sync_state fields are computed in memory and persisted in
    # ONE final write — a partial `put_sync_state` re-applies the Ash
    # `default:` of every default-bearing column it omits (`backfill_complete`,
    # `held`), so a single full write is the only clobber-safe shape.
    stored = scan.stored
    first_sync? = stored == nil or not is_integer(stored.high_water_uid)

    watermark0 =
      if first_sync?, do: first_sync_watermark(ctx, select), else: stored.high_water_uid

    backfill_complete0 = not first_sync? and stored != nil and stored.backfill_complete
    held0 = (stored && stored.held) || false

    {acc, watermark} =
      discover_incremental(acc, ctx, folder, dir_abs, dir_rel, select, watermark0)

    {acc, backfill_complete} =
      backfill(acc, ctx, folder, dir_abs, dir_rel, select, backfill_complete0)

    acc = pull_flags(acc, ctx, folder, dir_abs, dir_rel, select, stored)
    {acc, deletions_ok?} = reconcile_deletions(acc, ctx, folder, dir_abs)
    acc = repair_damage(acc, ctx, folder, dir_abs, dir_rel)

    # HIGHESTMODSEQ advances only after a successful deletion reconciliation;
    # a failed enumeration keeps the stored token so nothing is treated as
    # already-reconciled next pass.
    highestmodseq =
      if deletions_ok?, do: select.highestmodseq, else: stored && stored.highestmodseq

    Store.put_sync_state(ctx.account, folder, %{
      dir: dir_rel,
      uidvalidity: select.uidvalidity,
      high_water_uid: watermark,
      highestmodseq: highestmodseq,
      backfill_complete: backfill_complete,
      held: held0,
      last_pass_at: now_iso8601(),
      last_error: nil
    })

    acc
  end

  # -- binding + folder identity ----------------------------------------------

  # Resolve the folder's local dir. Identity wins (post-SQLite-loss), then a
  # sync_state binding, then a fresh allocation. Returns the (possibly grown)
  # taken-set so a later new folder in the same pass can't collide with it.
  defp resolve_dir(folder, account, identity_map, taken) do
    cond do
      Map.has_key?(identity_map, folder) ->
        {identity_map[folder], taken}

      true ->
        case stored_sync_state(account, folder) do
          %{dir: dir} when is_binary(dir) ->
            {dir, taken}

          _ ->
            dir = Maildir.folder_to_dir(folder, taken)
            {dir, MapSet.put(taken, normalize_dir(dir))}
        end
    end
  end

  # imap_name => dir_rel for every on-disk maildir directory carrying a
  # `.folder` identity (recurses nested IMAP hierarchy segments).
  defp existing_identity_map(root, account) do
    maildir_root = maildir_root(root, account)

    if File.dir?(maildir_root) do
      maildir_root
      |> walk_dirs()
      |> Enum.reduce(%{}, fn dir_abs, acc ->
        case Maildir.read_folder_identity(dir_abs) do
          {:ok, imap_name} -> Map.put(acc, imap_name, Path.relative_to(dir_abs, maildir_root))
          :error -> acc
        end
      end)
    else
      %{}
    end
  end

  # Normalized taken-set for `folder_to_dir/2`: every known sync_state dir plus
  # every existing on-disk maildir directory name (both normalized the exact
  # way `Maildir.folder_to_dir/2` compares candidates).
  defp taken_dirs(account, identity_map) do
    from_state = account |> Store.folders() |> Enum.map(& &1.dir) |> Enum.reject(&is_nil/1)
    from_disk = Map.values(identity_map)

    (from_state ++ from_disk)
    |> Enum.map(&normalize_dir/1)
    |> MapSet.new()
  end

  defp normalize_dir(dir), do: dir |> String.downcase() |> :unicode.characters_to_nfc_binary()

  defp walk_dirs(dir), do: [dir | dir |> subdirs() |> Enum.flat_map(&walk_dirs/1)]

  defp subdirs(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.reject(&(&1 in ["cur", "new", "tmp"]))
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.filter(&File.dir?/1)

      {:error, _reason} ->
        []
    end
  end

  # -- watermark init ---------------------------------------------------------

  # First sync => watermark := UIDNEXT-1 (or max(UID) from a full search when
  # UIDNEXT is unknown).
  defp first_sync_watermark(_ctx, %{uidnext: uidnext}) when is_integer(uidnext), do: uidnext - 1

  defp first_sync_watermark(ctx, _select) do
    case ctx.transport.uid_search(ctx.conn, "ALL") do
      {:ok, []} -> 0
      {:ok, uids} -> Enum.max(uids)
      {:error, _reason} -> 0
    end
  end

  # -- discovery (incremental, above the watermark) ---------------------------

  defp discover_incremental(acc, ctx, folder, dir_abs, dir_rel, select, watermark) do
    case ctx.transport.uid_search(ctx.conn, "UID #{watermark + 1}:*") do
      {:ok, uids} ->
        # Client-side `above?/2` guard: the `n:*` reversed-range quirk can
        # return the mailbox's single largest UID even when it is <= watermark.
        above = Enum.filter(uids, &(&1 > watermark))
        {acc, _landed} = land_uids(acc, ctx, folder, dir_abs, dir_rel, select, above)

        new_watermark = if above == [], do: watermark, else: Enum.max([watermark | above])
        {acc, new_watermark}

      {:error, reason} ->
        {add_error(acc, "discovery search failed for #{folder}: #{inspect(reason)}"), watermark}
    end
  end

  # -- backfill (windowed, until complete) ------------------------------------

  defp backfill(acc, _ctx, _folder, _dir_abs, _dir_rel, _select, true), do: {acc, true}

  defp backfill(acc, ctx, folder, dir_abs, dir_rel, select, false) do
    horizon = Date.add(Date.utc_today(), -ctx.settings.sync.window_days)
    since = Calendar.strftime(horizon, "%d-%b-%Y")

    case ctx.transport.uid_search(ctx.conn, "SINCE #{since}") do
      {:ok, uids} ->
        {acc, _landed} = land_uids(acc, ctx, folder, dir_abs, dir_rel, select, uids)

        # Complete only when every windowed UID is now known (landed or
        # recorded as oversized) — a fetch error leaves it incomplete so the
        # next pass re-runs the windowed search.
        {acc, backfill_settled?(ctx.account, folder, uids)}

      {:error, reason} ->
        {add_error(acc, "backfill search failed for #{folder}: #{inspect(reason)}"), false}
    end
  end

  defp backfill_settled?(account, folder, uids) do
    known = known_uids(account, folder)
    Enum.all?(uids, &MapSet.member?(known, &1))
  end

  # -- landing ----------------------------------------------------------------

  defp land_uids(acc, ctx, folder, dir_abs, dir_rel, select, uids) do
    known = known_uids(ctx.account, folder)
    to_land = uids |> Enum.reject(&MapSet.member?(known, &1)) |> Enum.sort()
    flags_map = fetch_flags_map(ctx, to_land)

    Enum.reduce(to_land, {acc, 0}, fn uid, {acc, count} ->
      case land_uid(acc, ctx, folder, dir_abs, dir_rel, select, uid, Map.get(flags_map, uid, [])) do
        {acc, true} -> {bump_new_messages(acc), count + 1}
        {acc, false} -> {acc, count}
      end
    end)
  end

  defp bump_new_messages(acc), do: %{acc | new_messages: acc.new_messages + 1}

  defp land_uid(acc, ctx, folder, dir_abs, dir_rel, select, uid, imap_flags) do
    max_bytes = ctx.settings.sync.max_message_bytes

    case ctx.transport.uid_fetch_meta(ctx.conn, [uid]) do
      {:ok, [%{size: size}]} when size > max_bytes ->
        record_oversize(ctx, folder, uid, select)

        {add_error(acc, "oversized message uid=#{uid} in #{folder} (#{size} bytes) skipped"),
         false}

      {:ok, [%{size: _size}]} ->
        land_body(acc, ctx, folder, dir_abs, dir_rel, select, uid, imap_flags)

      {:ok, []} ->
        {add_error(acc, "no metadata for uid=#{uid} in #{folder}"), false}

      {:error, reason} ->
        {add_error(acc, "meta fetch failed uid=#{uid} in #{folder}: #{inspect(reason)}"), false}
    end
  end

  defp land_body(acc, ctx, folder, dir_abs, dir_rel, select, uid, imap_flags) do
    case ctx.transport.uid_fetch_full(ctx.conn, uid) do
      {:ok, raw} ->
        maildir_flags = Maildir.flags_from_imap(imap_flags)
        {:ok, %{msg_id: msg_id}} = Views.land(ctx.root, ctx.account, raw, %{})
        filename = Maildir.encode_filename(msg_id, uid, maildir_flags)
        Maildir.deliver!(dir_abs, filename, raw)

        Store.put_occurrence(ctx.account, folder, %{
          uid: uid,
          uidvalidity: select.uidvalidity,
          msg_id: msg_id,
          flags: maildir_flags
        })

        write_index_row!(ctx, folder, dir_rel, uid, msg_id, maildir_flags, filename)
        refresh_view(ctx, msg_id)
        {acc, true}

      {:error, reason} ->
        {add_error(acc, "body fetch failed uid=#{uid} in #{folder}: #{inspect(reason)}"), false}
    end
  end

  # Oversized: recorded in the UID map under a sentinel msg_id so it is never
  # re-fetched, and deliberately excluded from the index + maildir (spec §Pull).
  defp record_oversize(ctx, folder, uid, select) do
    Store.put_occurrence(ctx.account, folder, %{
      uid: uid,
      uidvalidity: select.uidvalidity,
      msg_id: @oversize_msg_id,
      flags: MapSet.new()
    })
  end

  # -- flag pull --------------------------------------------------------------

  defp pull_flags(acc, ctx, folder, dir_abs, dir_rel, select, stored) do
    known = real_occurrences(ctx.account, folder)

    if known == [] do
      acc
    else
      case fetch_flag_results(ctx, folder, known, stored) do
        {:ok, results} ->
          by_uid = Map.new(known, &{&1.uid, &1})

          Enum.reduce(results, acc, fn result, acc ->
            case Map.fetch(by_uid, result.uid) do
              {:ok, occ} ->
                apply_flag_change(acc, ctx, folder, dir_abs, dir_rel, select, occ, result.flags)

              :error ->
                acc
            end
          end)

        {:error, reason} ->
          add_error(acc, "flag fetch failed for #{folder}: #{inspect(reason)}")
      end
    end
  end

  # CONDSTORE-gated where advertised + a stored HIGHESTMODSEQ exists (client-
  # side modseq filter is acceptable), else a plain fetch of the known set.
  defp fetch_flag_results(ctx, _folder, known, stored) do
    condstore? = ctx.transport.supports?(ctx.conn, :condstore)
    stored_modseq = stored && stored.highestmodseq

    if condstore? and is_integer(stored_modseq) do
      case ctx.transport.uid_fetch_flags(ctx.conn, "1:*") do
        {:ok, results} ->
          {:ok, Enum.filter(results, &(is_integer(&1.modseq) and &1.modseq > stored_modseq))}

        error ->
          error
      end
    else
      uid_set = known |> Enum.map(& &1.uid) |> Enum.sort() |> Enum.join(",")
      ctx.transport.uid_fetch_flags(ctx.conn, uid_set)
    end
  end

  defp apply_flag_change(acc, ctx, folder, dir_abs, dir_rel, select, occ, imap_flags) do
    new_flags = Maildir.flags_from_imap(imap_flags)

    if MapSet.equal?(new_flags, occ.flags) do
      acc
    else
      old_name = Maildir.encode_filename(occ.msg_id, occ.uid, occ.flags)
      new_name = Maildir.encode_filename(occ.msg_id, occ.uid, new_flags)
      rename_cur(dir_abs, old_name, new_name)

      Store.put_occurrence(ctx.account, folder, %{
        uid: occ.uid,
        uidvalidity: occ.uidvalidity || select.uidvalidity,
        msg_id: occ.msg_id,
        flags: new_flags
      })

      write_index_row!(ctx, folder, dir_rel, occ.uid, occ.msg_id, new_flags, new_name)
      refresh_view(ctx, occ.msg_id)
      acc
    end
  end

  # -- deletions --------------------------------------------------------------

  # Returns `{acc, deletions_ok?}` — `true` only on a successful, complete
  # enumeration, which is the sole condition under which the caller advances
  # HIGHESTMODSEQ (spec §Pull — deletions).
  defp reconcile_deletions(acc, ctx, folder, dir_abs) do
    case ctx.transport.uid_search(ctx.conn, "ALL") do
      {:ok, present} ->
        present_set = MapSet.new(present)

        stale =
          Enum.reject(all_occurrences(ctx.account, folder), &MapSet.member?(present_set, &1.uid))

        {Enum.reduce(stale, acc, &remove_occurrence(ctx, folder, dir_abs, &1, &2)), true}

      {:error, reason} ->
        # A failed/short enumeration removes nothing AND does not advance the
        # HIGHESTMODSEQ token.
        {add_error(acc, "deletion enumeration failed for #{folder}: #{inspect(reason)}"), false}
    end
  end

  defp remove_occurrence(ctx, folder, dir_abs, occ, acc) do
    rm_cur_by_uid(dir_abs, occ.uid, occ.msg_id, occ.flags)
    Store.delete_occurrence(ctx.account, folder, occ.uid)
    Store.delete_index_row(ctx.account, folder, occ.uid)

    if occ.msg_id != @oversize_msg_id do
      remaining = Store.occurrences_by_msg_id(ctx.account, occ.msg_id)
      Views.remove_occurrence(ctx.root, ctx.account, occ.msg_id, length(remaining))
      if remaining != [], do: refresh_view(ctx, occ.msg_id)
    end

    acc
  end

  # -- damage repair ----------------------------------------------------------

  defp repair_damage(acc, ctx, folder, dir_abs, dir_rel) do
    acc
    |> restore_missing(ctx, folder, dir_abs, dir_rel)
    |> quarantine_unknown(ctx, folder, dir_abs)
  end

  # A UID-map row whose local maildir file vanished (hand-deleted, interrupted
  # write) — re-fetch by UID, fingerprint-verify (the re-landed msg_id must
  # match), and restore the file.
  defp restore_missing(acc, ctx, folder, dir_abs, dir_rel) do
    on_disk = dir_abs |> Maildir.list_occurrences() |> MapSet.new(& &1.uid)
    missing = Enum.reject(real_occurrences(ctx.account, folder), &MapSet.member?(on_disk, &1.uid))

    Enum.reduce(missing, acc, fn occ, acc ->
      case ctx.transport.uid_fetch_full(ctx.conn, occ.uid) do
        {:ok, raw} ->
          {:ok, %{msg_id: landed}} =
            Views.land(ctx.root, ctx.account, raw, %{msg_id_hint: occ.msg_id})

          if landed == occ.msg_id do
            filename = Maildir.encode_filename(occ.msg_id, occ.uid, occ.flags)
            Maildir.deliver!(dir_abs, filename, raw)
            write_index_row!(ctx, folder, dir_rel, occ.uid, occ.msg_id, occ.flags, filename)
            refresh_view(ctx, occ.msg_id)

            add_notice(
              acc,
              "folder #{folder}: restored out-of-band-deleted occurrence uid=#{occ.uid}"
            )
          else
            add_error(
              acc,
              "folder #{folder}: uid=#{occ.uid} content changed under a stable UID; skipped"
            )
          end

        {:error, reason} ->
          add_error(acc, "folder #{folder}: could not restore uid=#{occ.uid}: #{inspect(reason)}")
      end
    end)
  end

  # Any file in `cur/` that doesn't parse, or parses to a UID with no UID-map
  # row, is out-of-band damage — moved to `quarantine/` (never interpreted).
  defp quarantine_unknown(acc, ctx, folder, dir_abs) do
    known = MapSet.new(all_occurrences(ctx.account, folder), & &1.uid)
    cur = Path.join(dir_abs, "cur")

    case File.ls(cur) do
      {:ok, files} ->
        Enum.reduce(files, acc, fn filename, acc ->
          if known_file?(filename, known) do
            acc
          else
            quarantine_file!(ctx, folder, cur, filename)
            add_notice(acc, "folder #{folder}: quarantined unknown file #{filename}")
          end
        end)

      {:error, _reason} ->
        acc
    end
  end

  defp known_file?(filename, known) do
    case Maildir.parse_filename(filename) do
      {:ok, %{uid: uid}} when is_integer(uid) -> MapSet.member?(known, uid)
      _ -> false
    end
  end

  defp quarantine_file!(ctx, _folder, cur, filename) do
    dir = Path.join([ctx.root, "sources", "mail", ctx.account, "quarantine"])
    File.mkdir_p!(dir)
    dest = Path.join(dir, "#{filename}-#{System.unique_integer([:positive])}")
    File.rename(Path.join(cur, filename), dest)
  end

  # -- index row construction -------------------------------------------------

  @blank_meta %{
    message_id: nil,
    from_name: nil,
    from_email: nil,
    subject: nil,
    date: nil,
    has_attachments: false,
    in_reply_to: nil,
    references: nil
  }

  defp write_index_row!(ctx, folder, dir_rel, uid, msg_id, maildir_flags, filename) do
    meta = view_meta(ctx.root, ctx.account, msg_id)
    path = Path.join(["sources", "mail", ctx.account, "maildir", dir_rel, "cur", filename])

    Store.upsert_index_row(%{
      account: ctx.account,
      folder: folder,
      uid: uid,
      msg_id: msg_id,
      message_id: meta.message_id,
      from_name: meta.from_name,
      from_email: meta.from_email,
      subject: meta.subject,
      date: meta.date,
      flags: maildir_flags |> Enum.sort() |> Enum.join(),
      has_attachments: meta.has_attachments,
      path: path,
      in_reply_to: meta.in_reply_to,
      references: meta.references
    })
  end

  # Metadata straight from the just-landed shared view (already parsed once by
  # `Views.land/4`) — the same fast path `Valea.Mail.Index` uses.
  defp view_meta(root, account, msg_id) do
    path = Path.join(root, Views.view_rel_path(account, msg_id))

    with {:ok, bytes} <- File.read(path),
         {:ok, %{frontmatter: fm}} <- MessageFile.parse(bytes) do
      %{
        message_id: fm["message_id"],
        from_name: get_in(fm, ["from", "name"]),
        from_email: get_in(fm, ["from", "email"]),
        subject: fm["subject"],
        date: normalize_date(fm["date"]),
        has_attachments: (fm["attachments"] || []) != [],
        in_reply_to: fm["in_reply_to"],
        references: references_string(fm["references"])
      }
    else
      _ -> @blank_meta
    end
  end

  # Recompute the view's `folders:`/`flags:` from the message's FULL occurrence
  # set (the reconciliation point that heals a partial folders list).
  defp refresh_view(ctx, msg_id) do
    occs = Store.occurrences_by_msg_id(ctx.account, msg_id)
    folders = occs |> Enum.map(& &1.folder) |> Enum.uniq()

    flags_union =
      occs
      |> Enum.flat_map(&MapSet.to_list(&1.flags))
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.join()

    Views.refresh_folders(ctx.root, ctx.account, msg_id, folders, flags_union)
  end

  # -- Store read helpers -----------------------------------------------------

  defp stored_sync_state(account, folder) do
    case Store.get_sync_state(account, folder) do
      {:ok, state} -> state
      {:error, :not_found} -> nil
    end
  end

  defp all_occurrences(account, folder), do: Store.occurrences(account, folder)

  defp real_occurrences(account, folder) do
    account |> Store.occurrences(folder) |> Enum.reject(&(&1.msg_id == @oversize_msg_id))
  end

  defp known_uids(account, folder) do
    account |> Store.occurrences(folder) |> MapSet.new(& &1.uid)
  end

  # -- filesystem helpers -----------------------------------------------------

  defp rename_cur(dir_abs, old_name, new_name) do
    cur = Path.join(dir_abs, "cur")
    old_path = Path.join(cur, old_name)
    if File.exists?(old_path), do: File.rename(old_path, Path.join(cur, new_name))
  end

  # Remove the occurrence's file by finding the on-disk file whose parsed UID
  # matches (robust to an out-of-band flag rename), falling back to the name
  # computed from the cached flags.
  defp rm_cur_by_uid(dir_abs, uid, msg_id, flags) do
    cur = Path.join(dir_abs, "cur")

    found =
      dir_abs
      |> Maildir.list_occurrences()
      |> Enum.find(&(&1.uid == uid))

    name = if found, do: found.filename, else: Maildir.encode_filename(msg_id, uid, flags)
    File.rm(Path.join(cur, name))
  end

  # -- flag fetch for a UID set (landing) -------------------------------------

  defp fetch_flags_map(_ctx, []), do: %{}

  defp fetch_flags_map(ctx, uids) do
    uid_set = uids |> Enum.sort() |> Enum.join(",")

    case ctx.transport.uid_fetch_flags(ctx.conn, uid_set) do
      {:ok, results} -> Map.new(results, &{&1.uid, &1.flags})
      {:error, _reason} -> %{}
    end
  end

  # -- misc -------------------------------------------------------------------

  defp reconcile_ctx(ctx, scan) do
    %{
      root: ctx.root,
      account: ctx.account,
      transport: ctx.transport,
      conn: ctx.conn,
      dir_rel: scan.dir_rel,
      select: scan.select
    }
  end

  defp folder_dir_abs(root, account, dir_rel), do: Path.join(maildir_root(root, account), dir_rel)

  defp maildir_root(root, account), do: Path.join([root, "sources", "mail", account, "maildir"])

  defp empty_result, do: %{new_messages: 0, errors: [], notices: []}

  defp add_error(acc, message), do: %{acc | errors: acc.errors ++ [message]}
  defp add_notice(acc, message), do: %{acc | notices: acc.notices ++ [message]}

  defp normalize_date(nil), do: nil
  defp normalize_date(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp normalize_date(str) when is_binary(str), do: str

  defp references_string(nil), do: nil
  defp references_string([]), do: nil
  defp references_string(list) when is_list(list), do: Enum.join(list, " ")

  defp now_iso8601, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp resolve_credential(fun) when is_function(fun, 0), do: fun.()
  defp resolve_credential(secret) when is_binary(secret), do: secret

  defp safe_logout(transport, conn) do
    transport.logout(conn)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
