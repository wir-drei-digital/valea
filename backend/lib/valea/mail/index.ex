defmodule Valea.Mail.Index do
  @moduledoc """
  Cache-only reconstruction of `Valea.Mail.Store`'s per-account tables from
  `<root>/sources/mail/<account>/maildir/` — the maildir tree is canonical
  (mail-as-maildir design spec, §Storage layout), `mail_sync_state`/
  `mail_uid_map`/`mail_messages` are pure cache, so this is the path every
  one of those tables must have after a wiped `app.sqlite`. Never touches
  the server: watermarks/`UIDVALIDITY`/`HIGHESTMODSEQ` are deliberately left
  unset (`nil`) for every folder this rebuilds — the next real sync pass
  re-establishes them.

  ## `.folder`-first binding reconstruction

  Every mailbox directory under `maildir/` carries an engine-owned
  `.folder` file recording the exact IMAP mailbox name
  (`Valea.Mail.Maildir.write_folder_identity!/2`) — authoritative for
  folder → dir after database loss, never inferred back from the directory
  spelling (spec, §Storage layout). `rebuild/2` walks the tree, and for
  EVERY directory carrying a `.folder` file, binds
  `Store.put_sync_state(account, imap_name, %{dir: ..., backfill_complete:
  false})` FIRST — before parsing a single occurrence in that directory.
  This binding pass is the reason a wiped SQLite database with
  case-colliding folder names (`Work` and `work`, mapped by
  `Maildir.folder_to_dir/2` to two DISTINCT directories, e.g. `Work` and
  `work-<hash>`) and a reversed `LIST` order still reuses the existing
  dirs instead of a live sync minting duplicates: each directory declares
  its OWN identity independently of traversal order, so there is nothing
  to get backwards — `SyncPass` (Task 7) consults these freshly-rebuilt
  bindings before ever calling `Maildir.folder_to_dir/2` to allocate a new
  one.

  ## Per-occurrence resilience

  A single bad occurrence (an unparseable/missing view, a malformed
  maildir filename, any other raise) is skipped and logged, never fatal —
  the same "one bad message never aborts the mailbox" posture the old
  flat-file `Index` held. An occurrence's message metadata (message_id,
  from, subject, date, in_reply_to, references, has_attachments) comes
  from its shared view (`sources/mail/<account>/views/messages/<msg_id>.md`
  — already landed by `Valea.Mail.Views.land/4`, never re-derived by
  re-normalizing raw mail bytes here); a missing/corrupt view still
  indexes the occurrence (it undeniably exists on disk — dropping it from
  the index because cosmetic metadata is unavailable would be worse than
  a row with a few blank fields), just with that metadata blank.
  """
  require Logger

  alias Valea.Mail.Maildir
  alias Valea.Mail.MessageFile
  alias Valea.Mail.Store
  alias Valea.Mail.Views

  @doc """
  Rebuilds every sync-state/uid_map/message-index row derivable from
  `<root>/sources/mail/<account>/maildir/`. Returns the number of
  occurrences successfully indexed (`{:ok, 0}` when the account has no
  maildir tree yet — a freshly configured, never-synced account).
  """
  @spec rebuild(String.t(), String.t()) :: {:ok, non_neg_integer()}
  def rebuild(root, account) when is_binary(root) and is_binary(account) do
    maildir_root = Path.join([root, "sources", "mail", account, "maildir"])

    count =
      maildir_root
      |> folder_dirs()
      |> Enum.reduce(0, fn {imap_name, dir_abs, dir_rel}, acc ->
        bind_sync_state!(account, imap_name, dir_rel)
        acc + index_folder(root, account, imap_name, dir_abs, dir_rel)
      end)

    {:ok, count}
  end

  # TEMP v3-bridge: removed in Task 9. `engine.ex`'s `activate/1` still calls
  # the old single-argument `rebuild/1` from its pre-multi-account (v3) days.
  # A pure no-op is the SMALLER of the two bridges the task brief allows
  # (the alternative — iterating every account in `Settings.load/1` and
  # calling `rebuild/2` per account — would tie this module to `Settings`
  # for no real benefit this early: `engine.ex` itself is still single-
  # account-shaped and doesn't yet call the real per-account rebuild at
  # activation). Callers needing an actual rebuild call `rebuild/2` directly
  # (as this module's own tests, and `Task 7`'s `SyncPass`, do).
  @spec rebuild(String.t()) :: {:ok, non_neg_integer()}
  def rebuild(root) when is_binary(root), do: {:ok, 0}

  # -- .folder-first directory discovery --------------------------------------

  # Every directory under maildir_root carrying a `.folder` identity file,
  # as `{imap_name, absolute_dir, dir_relative_to_maildir_root}`. Recurses
  # the whole tree (not just one level) since IMAP hierarchy segments
  # (`Work/Clients`) are ordinary nested plain directories (Maildir
  # moduledoc) — `cur`/`new`/`tmp` themselves are never descended into,
  # they're leaves holding message files, not further folder nesting.
  defp folder_dirs(maildir_root) do
    if File.dir?(maildir_root) do
      maildir_root
      |> walk_dirs()
      |> Enum.flat_map(fn dir_abs ->
        case Maildir.read_folder_identity(dir_abs) do
          {:ok, imap_name} -> [{imap_name, dir_abs, Path.relative_to(dir_abs, maildir_root)}]
          :error -> []
        end
      end)
    else
      []
    end
  end

  defp walk_dirs(dir) do
    [dir | dir |> subdirs() |> Enum.flat_map(&walk_dirs/1)]
  end

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

  defp bind_sync_state!(account, imap_name, dir_rel) do
    Store.put_sync_state(account, imap_name, %{dir: dir_rel, backfill_complete: false})
  end

  # -- per-folder occurrence indexing ------------------------------------------

  defp index_folder(root, account, imap_name, dir_abs, dir_rel) do
    dir_abs
    |> Maildir.list_occurrences()
    |> Enum.count(&index_occurrence(root, account, imap_name, dir_rel, &1))
  end

  # An occurrence without a confirmed UID (pre-confirmation, shouldn't
  # normally be sitting in `cur/`) carries no usable primary key for
  # `mail_uid_map`/`mail_messages` (both keyed on `(account, folder, uid)`,
  # `uid` non-nullable) — skip it rather than invent one.
  defp index_occurrence(_root, account, imap_name, _dir_rel, %{uid: nil, filename: filename}) do
    Logger.warning(
      "Valea.Mail.Index: skipping #{account}/#{imap_name}/#{filename}: no confirmed UID"
    )

    false
  end

  defp index_occurrence(root, account, imap_name, dir_rel, %{
         filename: filename,
         msg_id: msg_id,
         uid: uid,
         flags: flags
       }) do
    flags_str = flags |> Enum.sort() |> Enum.join()
    path = Path.join(["sources", "mail", account, "maildir", dir_rel, "cur", filename])
    meta = view_meta(root, account, msg_id)

    Store.put_occurrence(account, imap_name, %{
      uid: uid,
      uidvalidity: nil,
      msg_id: msg_id,
      flags: flags
    })

    Store.upsert_index_row(%{
      account: account,
      folder: imap_name,
      uid: uid,
      msg_id: msg_id,
      message_id: meta.message_id,
      from_name: meta.from_name,
      from_email: meta.from_email,
      subject: meta.subject,
      date: meta.date,
      flags: flags_str,
      has_attachments: meta.has_attachments,
      path: path,
      in_reply_to: meta.in_reply_to,
      references: meta.references
    })

    true
  rescue
    e ->
      Logger.warning(
        "Valea.Mail.Index: skipping #{account}/#{imap_name}/#{filename}: #{Exception.message(e)}"
      )

      false
  catch
    kind, reason ->
      Logger.warning(
        "Valea.Mail.Index: skipping #{account}/#{imap_name}/#{filename}: #{inspect({kind, reason})}"
      )

      false
  end

  # -- view metadata (never re-normalizes raw mail bytes) ----------------------

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

  # YamlElixir parses an unquoted ISO8601-looking scalar (render_date/1's
  # `date:` line) as a `DateTime` implicitly; `mail_messages.date` is a
  # plain `:string` column, so a struct must be re-stringified rather than
  # handed to Ash as-is.
  defp normalize_date(nil), do: nil
  defp normalize_date(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp normalize_date(str) when is_binary(str), do: str

  defp references_string(nil), do: nil
  defp references_string([]), do: nil
  defp references_string(list) when is_list(list), do: Enum.join(list, " ")
end
