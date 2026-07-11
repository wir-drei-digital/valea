defmodule Valea.Mail.MailboxOps do
  @moduledoc """
  Executes the post-approval mailbox side effects for one decided queue item
  (mail design spec, §Post-approval mailbox ops). This is where an approval
  finally reaches the real mailbox: the composed reply is APPENDed to Drafts,
  and the source message is MOVEd from the Review folder to Processed.

  Two hard requirements shape every line here:

  ## Idempotence

  Both ops are safe to replay. `draft_append` issues `UID SEARCH HEADER
  Message-ID <valea.draft.<run_id>@valea.invalid>` in the Drafts folder
  *before* appending: the draft's Message-ID is a pure function of `run_id`
  (`Valea.Mail.DraftMime.message_id/1`), so a retry after a crash — or after a
  UIDPLUS move that already COPIED the message on a prior half-finished
  attempt — finds the existing draft and records `done` (audited
  `recovered: true`) instead of landing a duplicate. `archive_source` flips
  the local message file's status to `processed` and records the op `done`;
  a re-run finds nothing actionable. (For `archive_source` a re-issued
  UIDPLUS move can leave a duplicate copy in Processed if the first COPY
  succeeded but the STORE/EXPUNGE didn't — an accepted, benign outcome the
  transport documents; the draft's search guard has no such window.)

  ## Never block an approval

  `execute/1` only ever mutates `mailbox_ops` entries via
  `Valea.Queue.update_mailbox_op/3` and flips the local message file — it
  never moves the decided envelope out of `approved/`/`rejected/`. A
  connect failure marks every actionable op `failed` (with the reason) and
  returns; the human's decision is already durable and untouched. Every
  transport error is caught per-op, so one failing op never aborts the batch
  or crashes the caller (the Engine runs this in an unlinked task). `execute/1`
  always returns `:ok`.

  ## Per-op status machine

  For each op whose status is `"pending"` or `"failed"` (uncapped — retries
  are user-driven), the outcome is one of:

    * `"done"` — the append/move succeeded (or the draft was already present);
    * `"unsupported"` — the server has neither MOVE nor UIDPLUS, so the move
      could not run. The op is terminal, but the local status is *still*
      flipped to `processed`: the human reviewed it, and that fact is real
      regardless of the server's capabilities;
    * `"failed"` — a transport/connect error. Retryable via the UI's retry
      button (`Valea.Mail.Engine.retry_ops/1`).

  `"skipped"`, `"unsupported"`, and `"done"` are terminal: `execute/1`
  no-ops them (a seed-source item, whose ops the queue seeded `"skipped"`,
  therefore makes zero transport calls — not even a connect).
  """

  alias Valea.Mail.DraftMime
  alias Valea.Mail.MessageFile
  alias Valea.Mail.Store
  alias Valea.Paths
  alias Valea.Queue

  @op_order ["draft_append", "archive_source"]
  @draft_flags ["\\Draft"]

  @type args :: %{
          root: String.t(),
          run_id: String.t(),
          transport: module(),
          settings: Valea.Mail.Settings.t(),
          credential: (-> String.t()) | String.t()
        }

  @doc """
  Runs the actionable mailbox ops for `run_id`. Reads the decided envelope
  via `Valea.Queue.get_decided/1`; a gone item or an item with no actionable
  op is a no-op. One connect serves the whole batch. Always `:ok`.
  """
  @spec execute(args()) :: :ok
  def execute(%{root: _, run_id: run_id} = args) do
    with {:ok, %{item: item}} <- Queue.get_decided(run_id),
         ops when is_map(ops) <- Map.get(item, "mailbox_ops"),
         [_ | _] = actionable <- actionable_ops(ops) do
      run_batch(Map.merge(args, %{item: item, actionable: actionable}))
    else
      _ -> :ok
    end
  end

  # Preserve @op_order so draft_append always runs before archive_source.
  defp actionable_ops(ops) do
    for name <- @op_order,
        op = Map.get(ops, name),
        is_map(op),
        Map.get(op, "status") in ["pending", "failed"],
        do: name
  end

  # -- batch (one connect) ----------------------------------------------------

  defp run_batch(ctx) do
    case ctx.transport.connect(ctx.settings.imap, resolve_credential(ctx.credential), []) do
      {:ok, conn} ->
        ctx = Map.put(ctx, :conn, conn)
        Enum.each(ctx.actionable, &run_op(ctx, &1))
        safe_logout(ctx)
        :ok

      {:error, reason} ->
        # Connect failed: no per-op work is possible. Mark every actionable
        # op failed with the reason. The approval itself is untouched.
        Enum.each(ctx.actionable, &mark_failed(ctx, &1, reason))
        :ok
    end
  end

  # A per-op crash (an unexpected raise/exit in transport or file IO) becomes
  # a `failed` op, never a batch abort or a caller crash.
  defp run_op(ctx, name) do
    dispatch(ctx, name)
  rescue
    e -> mark_failed(ctx, name, Exception.message(e))
  catch
    kind, reason -> mark_failed(ctx, name, inspect({kind, reason}))
  end

  defp dispatch(ctx, "draft_append"), do: draft_append(ctx)
  defp dispatch(ctx, "archive_source"), do: archive_source(ctx)

  # -- draft_append -----------------------------------------------------------

  defp draft_append(ctx) do
    drafts = ctx.settings.folders.drafts

    with {:ok, draft_md} <- read_draft(ctx.root, ctx.run_id),
         :ok <- select(ctx, drafts),
         {:ok, uids} <- ctx.transport.uid_search(ctx.conn, search_criteria(ctx.run_id)) do
      if uids == [] do
        append_draft(ctx, drafts, draft_md)
      else
        # Already present (crash/retry recovery): record done, don't re-append.
        mark_done(ctx, "draft_append")
        audit("draft_appended", %{"run_id" => ctx.run_id, "recovered" => true})
      end
    else
      {:error, reason} -> mark_failed(ctx, "draft_append", reason)
    end
  end

  defp append_draft(ctx, drafts, draft_md) do
    {:ok, rfc822} =
      DraftMime.compose(draft_md, source_frontmatter(ctx), ctx.run_id, ctx.settings.account)

    case ctx.transport.append(ctx.conn, drafts, @draft_flags, rfc822) do
      :ok ->
        mark_done(ctx, "draft_append")
        audit("draft_appended", %{"run_id" => ctx.run_id})

      {:error, reason} ->
        mark_failed(ctx, "draft_append", reason)
    end
  end

  defp read_draft(root, run_id) do
    case File.read(draft_path(root, run_id)) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, reason} -> {:error, {:draft_unreadable, reason}}
    end
  end

  defp draft_path(root, run_id),
    do: Path.join([root, "sources", "mail", "drafts", "#{run_id}.md"])

  # HEADER Message-ID search — deterministic on run_id, the idempotence guard.
  defp search_criteria(run_id), do: "HEADER Message-ID #{DraftMime.message_id(run_id)}"

  # Source frontmatter drives To/In-Reply-To/References. Unreadable source is
  # tolerated here (draft still appends, just without threading) — the seed
  # rule already skipped genuinely-sourceless items at intent time.
  defp source_frontmatter(ctx) do
    case read_source(ctx) do
      {:ok, fm, _real} -> fm
      {:error, _reason} -> %{}
    end
  end

  # -- archive_source ---------------------------------------------------------

  defp archive_source(ctx) do
    review = ctx.settings.folders.review
    processed = ctx.settings.folders.processed

    with {:ok, fm, real} <- read_source(ctx),
         {:ok, uid} <- fetch_uid(fm),
         :ok <- select(ctx, review) do
      do_move(ctx, uid, processed, fm, real)
    else
      {:error, reason} -> mark_failed(ctx, "archive_source", reason)
    end
  end

  defp do_move(ctx, uid, processed, fm, real) do
    case ctx.transport.uid_move(ctx.conn, uid, processed) do
      :ok ->
        flip_local(real, fm)
        mark_done(ctx, "archive_source")
        audit("message_archived", %{"run_id" => ctx.run_id, "msg_id" => fm["id"]})

      {:unsupported, why} ->
        # Reviewed is reviewed: flip locally even though the server can't move.
        flip_local(real, fm)

        Queue.update_mailbox_op(ctx.run_id, "archive_source", %{
          "status" => "unsupported",
          "error" => why
        })

        audit("message_archived", %{
          "run_id" => ctx.run_id,
          "msg_id" => fm["id"],
          "unsupported" => why
        })

      {:error, reason} ->
        mark_failed(ctx, "archive_source", reason)
    end
  end

  defp fetch_uid(fm) do
    case fm["uid"] do
      uid when is_integer(uid) -> {:ok, uid}
      _ -> {:error, :source_has_no_uid}
    end
  end

  # Byte-preserving status flip of the on-disk message file + the cache row.
  # Best-effort and non-raising: the server move already succeeded and is the
  # authoritative fact, so an unflippable file (already flipped, no
  # frontmatter) or even a failed local write must never turn a done op back
  # into a failed one — which a retry would then try to re-move.
  defp flip_local(real, fm) do
    with {:ok, bytes} <- File.read(real),
         {:ok, flipped} <- MessageFile.flip_status(bytes, "processed") do
      atomic_write!(real, flipped)
    end

    if is_binary(fm["id"]), do: Store.set_message_status(fm["id"], "processed")
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # Containment-gated read of the workspace-relative source path.
  defp read_source(ctx) do
    with source when is_binary(source) <- ctx.item["source_message"],
         {:ok, real} <- Paths.resolve_real(source, ctx.root),
         {:ok, bytes} <- File.read(real),
         {:ok, %{frontmatter: fm}} <- MessageFile.parse(bytes) do
      {:ok, fm, real}
    else
      _ -> {:error, :source_unreadable}
    end
  end

  # -- op status writes -------------------------------------------------------

  defp mark_done(ctx, name) do
    Queue.update_mailbox_op(ctx.run_id, name, %{"status" => "done"})
    :ok
  end

  defp mark_failed(ctx, name, reason) do
    why = describe(reason)
    Queue.update_mailbox_op(ctx.run_id, name, %{"status" => "failed", "error" => why})
    audit("op_failed", %{"run_id" => ctx.run_id, "op" => name, "reason" => why})
    :ok
  end

  # -- transport helpers ------------------------------------------------------

  defp select(ctx, folder) do
    case ctx.transport.select(ctx.conn, folder) do
      {:ok, _mailbox} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp safe_logout(ctx) do
    ctx.transport.logout(ctx.conn)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp resolve_credential(fun) when is_function(fun, 0), do: fun.()
  defp resolve_credential(secret) when is_binary(secret), do: secret

  # -- misc -------------------------------------------------------------------

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)

  defp atomic_write!(abs, bytes) do
    tmp = abs <> ".tmp"
    File.write!(tmp, bytes)
    File.rename!(tmp, abs)
  end

  defp audit(type, fields) do
    if Process.whereis(Valea.Audit), do: Valea.Audit.append(type, fields)
    :ok
  end
end
