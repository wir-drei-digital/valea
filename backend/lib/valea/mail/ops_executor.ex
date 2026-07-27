defmodule Valea.Mail.OpsExecutor do
  @moduledoc """
  The durable declared-ops executor (mail-as-maildir design spec E, §Sync
  engine — Push / §Safety invariants / §Error handling). Given a connected
  transport `ctx`, it validates each op against **current** occurrence
  state, records moves durably (a fsynced `spool/<id>.manifest.yaml` + a
  `mail_pending_ops` ledger row, both written BEFORE any mutating I/O),
  executes them with **execution-time verification**, and confirms every
  destination before the source is ever touched.

  ## Contracts (each backed by a test)

    1. **Execution-time verification.** Immediately before any mutation the
       source folder is `SELECT`ed and its live `UIDVALIDITY` must equal the
       op's recorded value; the source message is fetched and must
       fingerprint-match the occurrence's `msg_id`. Any mismatch → the op is
       rejected `"server_changed"`, no destructive step issued.
    2. **Move ladder (executor-owned).** With native `MOVE`: `uid_move`,
       COPYUID as `dest_uid` when present, else destination confirmation.
       Without it: `uid_copy` → **destination confirmation** → only then
       `uid_mark_deleted` → `uid_expunge` — each step recorded in the
       manifest before it runs, the source NEVER expunged before a confirmed
       destination exists. Confirmation = COPYUID, else a `HEADER
       Message-ID` shortcut, else a watermark candidate scan; a
       fingerprint always decides; exactly one match relocates the local
       file (`U=` renamed), zero/several → `needs_review`, local untouched.
    3. **Write-through destination** (`to` excluded from the mirror): the
       destination is confirmed via a transient read-only `EXAMINE`
       watermark recorded at enqueue; on confirmation the local occurrence
       is REMOVED (it left the mirrored set).
    4. **Gmail profile.** Moves execute only with native `MOVE`; the
       postcondition for EVERY gmail move is source-absence AND
       destination-membership by `X-GM-MSGID` (both via read-only `EXAMINE`,
       pre-existing membership counts). Archive → All Mail removes the local
       occurrence.
    5. **Flags.** No ledger row; the durable record is the claimed ops file
       + its `.state.yaml` sidecar (baseline flags + `MODSEQ` +
       postcondition + source `UIDVALIDITY` + fingerprint, fsynced BEFORE
       the STORE). Execution-time verification applies exactly as to moves;
       the STORE is `UNCHANGEDSINCE`-guarded where advertised; `:modified` →
       `needs_review`.
    6. **Uncertain results** (`{:lost_response, _}`): the op stays
       `executing`; `recover/1` reconciles (confirm-first, never a blind
       retry) before anything else runs.
    7. **Conflict** (server moved/removed the target since the last pull):
       verification fails → rejected `"server_changed"`, server wins.
    8. **RPC** shares the same core via `apply_raw_ops/3` (origin `"rpc"`),
       returning per-op results synchronously.

  `ctx` is `%{root, account, settings, transport, conn}` plus an optional
  `opid` (the claimed ops file's op-id — present on the ops-file push path,
  binding flag-recovery state sidecars; absent for RPC).
  """

  alias Valea.Mail.DraftFile
  alias Valea.Mail.DraftMime
  alias Valea.Mail.Maildir
  alias Valea.Mail.MessageFile
  alias Valea.Mail.Normalizer
  alias Valea.Mail.OpsFile
  alias Valea.Mail.Redact
  alias Valea.Mail.Settings
  alias Valea.Mail.Store
  alias Valea.Mail.Views
  alias Valea.Paths

  @oversize_msg_id "__oversize__"

  # IMAP `\Draft` flag on the appended message (maildir `D`), pull-only —
  # never STOREd by the executor's flag path, only set at APPEND time.
  @draft_flags ["\\Draft"]

  # The Sent copy of a message this user just transmitted is, by
  # construction, one they have read.
  @sent_flags ["\\Seen"]

  # How many COMPLETE-but-empty Sent-Mail searches park a gmail send for good
  # (spec G: "an empty search is a strong signal but not proof … the search
  # re-runs over a short bounded window").
  @reconcile_attempt_limit 3

  # Every non-terminal ledger state — exactly what the claim index treats as
  # active, and what the display projection lets govern a draft's state.
  @active_states ["claimed", "pending", "executing", "needs_review", "transmitted", "send_review"]

  @type ctx :: %{
          required(:root) => String.t(),
          required(:account) => String.t(),
          required(:settings) => Valea.Mail.Settings.t(),
          required(:transport) => module(),
          required(:conn) => term(),
          optional(:opid) => String.t() | nil,
          # The SEND half (spec G). Absent on every pull/move/append path —
          # nothing outside `execute_send/2`'s `pending` branch reads either.
          optional(:smtp_transport) => module(),
          optional(:smtp_credential) => String.t() | nil
        }

  @type result_map :: %{required(String.t()) => term()}

  # ==========================================================================
  # apply_ops / apply_raw_ops — the shared per-op core
  # ==========================================================================

  @doc """
  Runs a list of ALREADY-PARSED ops (atom-keyed, from `OpsFile.parse/1`)
  against `ctx`, returning one `%{"op" => i, "result" => ..., "reason" =>
  ...}` per op. Used by the ops-file push phase.
  """
  @spec apply_ops(ctx(), [OpsFile.op()], String.t()) :: [result_map()]
  def apply_ops(ctx, ops, origin) when is_list(ops) do
    ops
    |> Enum.with_index()
    |> Enum.map(fn {op, index} -> run_indexed(ctx, op, index, origin) end)
  end

  @doc """
  Runs a list of RAW op maps (string-keyed, e.g. from the `mail_apply_ops`
  RPC), parsing each against the closed vocabulary per-op so one malformed
  op rejects only itself. Same per-op result shape as `apply_ops/3`.
  """
  @spec apply_raw_ops(ctx(), [map()], String.t()) :: [result_map()]
  def apply_raw_ops(ctx, raw_ops, origin) when is_list(raw_ops) do
    raw_ops
    |> Enum.with_index()
    |> Enum.map(fn {raw, index} ->
      case OpsFile.parse_one(raw) do
        {:ok, op} -> run_indexed(ctx, op, index, origin)
        {:error, reason} -> result(index, :rejected, reason)
      end
    end)
  end

  defp run_indexed(ctx, op, index, origin) do
    case OpsFile.validate(op, validate_ctx(ctx)) do
      :ok -> result(index, normalize_status(run_op(ctx, op, index, origin)))
      {:rejected, reason} -> result(index, :rejected, reason)
    end
  end

  # `execute/2` returns a bare `:ok`; flags return `{:ok, nil}`. Normalize
  # both to a `{status, reason}` tuple for the result builder.
  defp normalize_status(:ok), do: {:ok, nil}
  defp normalize_status({_status, _reason} = tuple), do: tuple

  # Dispatches a validated op to move/flag execution, returning
  # `{status, reason}`.
  defp run_op(ctx, %{op: :move} = op, _index, origin) do
    case enqueue_move(ctx, op, origin) do
      {:ok, op_row} -> execute(ctx, op_row)
      {:rejected, reason} -> {:rejected, reason}
    end
  end

  defp run_op(ctx, %{op: :flag} = op, index, origin) do
    execute_flag(ctx, op, index, origin)
  end

  defp result(index, {status, reason}), do: result(index, status, reason)

  defp result(index, status, reason) do
    %{"op" => index, "result" => to_string(status), "reason" => reason}
  end

  # ==========================================================================
  # enqueue_move — manifest + ledger BEFORE any mutating I/O
  # ==========================================================================

  @doc """
  Records a move durably before any mutating I/O: a fsynced
  `spool/<id>.manifest.yaml` (source folder/UIDVALIDITY/UID + fingerprint,
  destination + its read-only-examined watermark/UIDVALIDITY, provider,
  gm_msgid, origin) and a `mail_pending_ops` row (`state: "pending"`).
  """
  @spec enqueue_move(ctx(), OpsFile.op(), String.t()) :: {:ok, map()} | {:rejected, String.t()}
  def enqueue_move(ctx, %{op: :move, msg_id: msg_id, from: from, to: to}, origin) do
    with {:ok, occ} <- single_occurrence(ctx, msg_id, from),
         {:ok, fingerprint} <- source_fingerprint(ctx, from, occ),
         {:ok, dest} <- examine_dest(ctx, to) do
      gm_msgid = if gmail?(ctx), do: capture_gm_msgid(ctx, from, occ.uid), else: nil
      id = Ash.UUID.generate()

      manifest = %{
        "kind" => "move",
        "account" => ctx.account,
        "source_folder" => from,
        "source_uidvalidity" => occ.uidvalidity,
        "uid" => occ.uid,
        "msg_id" => msg_id,
        "fingerprint" => fingerprint,
        "target_folder" => to,
        "dest_watermark" => dest.watermark,
        "dest_uidvalidity" => dest.uidvalidity,
        "provider" => provider_string(ctx),
        "gm_msgid" => gm_msgid,
        "write_through" => excluded?(ctx, to),
        "flags" => flags_to_string(occ.flags),
        "message_id" => index_message_id(ctx.account, msg_id),
        "origin" => origin,
        "transitions" => ["enqueued"]
      }

      write_manifest!(ctx, id, manifest)

      {:ok, op_row} =
        Store.create_pending_op(%{
          id: id,
          kind: "move",
          account: ctx.account,
          source_folder: from,
          target_folder: to,
          uid: occ.uid,
          source_uidvalidity: occ.uidvalidity,
          dest_watermark: dest.watermark,
          dest_uidvalidity: dest.uidvalidity,
          msg_id: msg_id,
          message_id: manifest["message_id"],
          origin: origin,
          state: "pending"
        })

      {:ok, op_row}
    else
      :error -> {:rejected, "no single occurrence of #{msg_id} in #{from}"}
      {:error, reason} -> {:rejected, to_string(reason)}
    end
  end

  # ==========================================================================
  # execute — verification + ladder (fresh path)
  # ==========================================================================

  @doc """
  Executes a freshly-enqueued move: execution-time verification, then the
  provider-appropriate ladder. On a lost ladder response it reconciles
  in-session (confirm-first, never a blind retry). `:ok` | `{:needs_review,
  reason}` | `{:rejected, reason}`.
  """
  @spec execute(ctx(), map()) :: :ok | {:needs_review, String.t()} | {:rejected, String.t()}
  def execute(ctx, op_row) do
    manifest = read_manifest(ctx, op_row.id)

    case verify_source(ctx, op_row, manifest) do
      :ok ->
        Store.transition_op(op_row.id, "executing")
        do_move(ctx, op_row, manifest)

      {:rejected, reason} ->
        Store.transition_op(op_row.id, "rejected", %{error: reason})
        cleanup(ctx, op_row.id)
        {:rejected, reason}
    end
  end

  # Contract 1: live UIDVALIDITY == recorded, fingerprint match. Any mismatch
  # rejects for re-validation; no destructive step is issued from cached UID
  # state.
  defp verify_source(ctx, op_row, manifest) do
    case ctx.transport.select(ctx.conn, op_row.source_folder) do
      {:ok, %{uidvalidity: uidvalidity}} when uidvalidity == op_row.source_uidvalidity ->
        case ctx.transport.uid_fetch_full(ctx.conn, op_row.uid) do
          {:ok, raw} ->
            if MessageFile.fingerprint(raw) == manifest["fingerprint"],
              do: :ok,
              else: {:rejected, "server_changed"}

          {:error, _reason} ->
            {:rejected, "server_changed"}
        end

      {:ok, _diverged} ->
        {:rejected, "server_changed"}

      {:error, _reason} ->
        {:rejected, "server_changed"}
    end
  end

  defp do_move(ctx, op_row, manifest) do
    cond do
      manifest["provider"] == "gmail" -> gmail_move(ctx, op_row, manifest)
      ctx.transport.supports?(ctx.conn, :move) -> native_move(ctx, op_row, manifest)
      true -> copy_ladder(ctx, op_row, manifest)
    end
  end

  # -- native MOVE ------------------------------------------------------------

  defp native_move(ctx, op_row, manifest) do
    manifest = transition(ctx, op_row.id, manifest, "move_issued")
    # Source is SELECTed (verify_source). uid_move operates on it as source.
    case ctx.transport.uid_move(ctx.conn, op_row.uid, op_row.target_folder) do
      {:ok, %{dest_uid: dest_uid}} ->
        manifest = transition(ctx, op_row.id, manifest, "moved")
        confirm_and_finalize(ctx, op_row, manifest, dest_uid)

      {:unsupported, _reason} ->
        copy_ladder(ctx, op_row, manifest)

      {:error, _reason} ->
        # Lost response — the move may have applied. Reconcile (confirm-first).
        reconcile_generic(ctx, op_row, manifest)
    end
  end

  # -- COPY → confirm → mark-deleted → expunge --------------------------------

  defp copy_ladder(ctx, op_row, manifest) do
    manifest = transition(ctx, op_row.id, manifest, "copy_issued")

    case ctx.transport.uid_copy(ctx.conn, op_row.uid, op_row.target_folder) do
      {:ok, %{dest_uid: hint}} ->
        manifest = transition(ctx, op_row.id, manifest, "copied")

        case confirm_destination(ctx, op_row, manifest, hint) do
          {:ok, dest_uid, dest_uidvalidity} ->
            manifest = transition(ctx, op_row.id, manifest, "confirmed")
            purge_source(ctx, op_row, manifest)
            finalize(ctx, op_row, manifest, dest_uid, dest_uidvalidity)
            complete(ctx, op_row)

          :none ->
            needs_review(ctx, op_row, "destination_unconfirmed")

          :several ->
            needs_review(ctx, op_row, "ambiguous_destination")
        end

      {:error, _reason} ->
        # Lost COPY response — the copy may have applied. Reconcile.
        reconcile_generic(ctx, op_row, manifest)
    end
  end

  # Marks + targeted-expunges the source occurrence (idempotent; only ever
  # reached after a confirmed destination exists).
  defp purge_source(ctx, op_row, manifest) do
    ctx.transport.select(ctx.conn, op_row.source_folder)
    ctx.transport.uid_mark_deleted(ctx.conn, op_row.uid)
    transition(ctx, op_row.id, manifest, "marked_deleted")
    ctx.transport.uid_expunge(ctx.conn, op_row.uid)
    transition(ctx, op_row.id, manifest, "expunged")
  end

  # -- native-move confirmation ------------------------------------------------

  defp confirm_and_finalize(ctx, op_row, manifest, dest_uid) do
    case confirm_destination(ctx, op_row, manifest, dest_uid) do
      {:ok, uid, uidvalidity} ->
        finalize(ctx, op_row, manifest, uid, uidvalidity)
        complete(ctx, op_row)

      :none ->
        needs_review(ctx, op_row, "destination_unconfirmed")

      :several ->
        needs_review(ctx, op_row, "ambiguous_destination")
    end
  end

  # Destination confirmation (contract 2): COPYUID hint when present, else a
  # read-only EXAMINE of the destination + candidate scan (Message-ID
  # shortcut ∪ watermark scan), each candidate fingerprint-confirmed. A
  # changed destination UIDVALIDITY invalidates the watermark bound → full
  # fingerprint scan. Returns `{:ok, uid, uidvalidity}` | `:none` | `:several`.
  defp confirm_destination(_ctx, _op_row, manifest, hint) when is_integer(hint) do
    # COPYUID/MOVE gave us the destination UID directly.
    {:ok, hint, manifest["dest_uidvalidity"]}
  end

  defp confirm_destination(ctx, op_row, manifest, nil) do
    case ctx.transport.examine(ctx.conn, op_row.target_folder) do
      {:ok, %{uidvalidity: uidvalidity}} ->
        candidates = confirmation_candidates(ctx, manifest, uidvalidity)
        confirmed = fingerprint_confirm(ctx, candidates, manifest["fingerprint"])

        case confirmed do
          [uid] -> {:ok, uid, uidvalidity}
          [] -> :none
          _many -> :several
        end

      {:error, _reason} ->
        :none
    end
  end

  defp confirmation_candidates(ctx, manifest, live_uidvalidity) do
    if live_uidvalidity != manifest["dest_uidvalidity"] do
      # Watermark bound invalid across a destination reset → full-folder scan.
      search(ctx, "ALL")
    else
      watermark = manifest["dest_watermark"] || 0
      mid_hits = message_id_candidates(ctx, manifest["message_id"])
      scan_hits = search(ctx, "UID #{watermark + 1}:*")

      (mid_hits ++ scan_hits)
      |> Enum.uniq()
      |> Enum.filter(&(&1 > watermark))
    end
  end

  defp message_id_candidates(_ctx, mid) when mid in [nil, ""], do: []

  defp message_id_candidates(ctx, mid) do
    if safe_message_id?(mid), do: search(ctx, "HEADER Message-ID #{mid}"), else: []
  end

  defp fingerprint_confirm(ctx, uids, fingerprint) do
    Enum.filter(uids, fn uid ->
      case ctx.transport.uid_fetch_full(ctx.conn, uid) do
        {:ok, raw} -> MessageFile.fingerprint(raw) == fingerprint
        {:error, _reason} -> false
      end
    end)
  end

  # ==========================================================================
  # gmail move (contract 4)
  # ==========================================================================

  defp gmail_move(ctx, op_row, manifest) do
    if ctx.transport.supports?(ctx.conn, :move) do
      manifest = transition(ctx, op_row.id, manifest, "move_issued")
      # Selected on source from verify_source.
      _ = ctx.transport.uid_move(ctx.conn, op_row.uid, op_row.target_folder)
      manifest = transition(ctx, op_row.id, manifest, "moved")
      gmail_prove(ctx, op_row, manifest)
    else
      Store.transition_op(op_row.id, "rejected", %{error: "move_unsupported"})
      cleanup(ctx, op_row.id)
      {:rejected, "move_unsupported"}
    end
  end

  # Postcondition (idempotent, so it doubles as the recovery check): the
  # source no longer lists the message's X-GM-MSGID AND the destination does.
  defp gmail_prove(ctx, op_row, manifest) do
    gm = manifest["gm_msgid"]

    if gmail_absent?(ctx, op_row.source_folder, gm) and
         gmail_present?(ctx, op_row.target_folder, gm) do
      dest_uid = gmail_dest_uid(ctx, op_row.target_folder, gm)
      finalize(ctx, op_row, manifest, dest_uid, manifest["dest_uidvalidity"])
      complete(ctx, op_row)
    else
      needs_review(ctx, op_row, "gmail_postcondition_unproven")
    end
  end

  defp gmail_absent?(ctx, folder, gm) do
    case ctx.transport.examine(ctx.conn, folder) do
      {:ok, _info} -> search(ctx, "X-GM-MSGID #{gm}") == []
      {:error, _reason} -> false
    end
  end

  defp gmail_present?(ctx, folder, gm) do
    case ctx.transport.examine(ctx.conn, folder) do
      {:ok, _info} -> search(ctx, "X-GM-MSGID #{gm}") != []
      {:error, _reason} -> false
    end
  end

  defp gmail_dest_uid(ctx, folder, gm) do
    case ctx.transport.examine(ctx.conn, folder) do
      {:ok, _info} -> search(ctx, "X-GM-MSGID #{gm}") |> Enum.max(fn -> nil end)
      {:error, _reason} -> nil
    end
  end

  # ==========================================================================
  # append (Push-to-Drafts) — prepare (local) + execute (network) + reconcile
  # ==========================================================================
  #
  # Push-to-Drafts APPENDs the rendered MIME to the account's Drafts folder —
  # the low-trust outbound path, and the only one for an account with no
  # `smtp:` block (the transmitting sibling is the `send` section below; both
  # are reachable ONLY from an explicit human click, spec G's invariant).
  # `prepare_push/3` is fully LOCAL (atomic claim + hash-verified snapshot +
  # compose + fsynced spool) and runs synchronously in the Engine loop;
  # `execute_append/2` is the network half and rides the Engine's single
  # serialized work slot exactly like a sync pass. The push is idempotent by a
  # stable Valea-generated Message-ID: every attempt searches the Drafts
  # folder for it first, so a lost response never lands a duplicate.

  @doc """
  LOCAL phase of a push (no connection): validates the draft basename,
  contains + no-follow-reads the reviewed draft into an immutable buffer,
  atomically CLAIMS the append op (the partial unique index serializes
  concurrent pushes — a duplicate returns the existing op's display state),
  verifies `content_hash` against the buffer, validates the frontmatter,
  enforces the status anti-forgery rule, composes the RFC822 **from the same
  buffer's parsed values**, writes the fsynced `spool/<id>.eml` + manifest,
  and transitions the op `claimed → pending`. `ctx` here is the LOCAL ctx
  `%{root, account, settings}` (no transport/conn).

    * `{:ok, op_row}` — claimed, spooled, `pending`; ready for
      `execute_append/2`.
    * `{:duplicate, display}` — a non-terminal push already exists for this
      draft; its display state is returned, no second op created.
    * `{:error, reason}` — a pre-claim failure (bad name, symlink/missing
      file) or a post-claim rejection (`content_changed`, `status_forged`,
      `invalid_draft`); a post-claim rejection also terminates the op
      `rejected`.
  """
  @spec prepare_push(map(), String.t(), String.t()) ::
          {:ok, map()} | {:duplicate, String.t()} | {:error, String.t()}
  def prepare_push(ctx, draft_name, content_hash)
      when is_binary(draft_name) and is_binary(content_hash) do
    origin = draft_origin(draft_name)

    with :ok <- validate_draft_name(draft_name),
         {:ok, path} <- resolve_draft_path(ctx, draft_name),
         {:ok, buffer} <- read_draft_nofollow(path) do
      message_id = DraftMime.push_message_id(ctx.account, draft_name, content_hash)

      case Store.create_pending_op(%{
             kind: "append",
             account: ctx.account,
             origin: origin,
             target_folder: ctx.settings.folders.drafts,
             message_id: message_id,
             msg_id: draft_name,
             state: "claimed"
           }) do
        {:ok, op_row} ->
          snapshot_and_spool_guarded(ctx, op_row, draft_name, content_hash, buffer, path)

        {:error, :duplicate_active} ->
          {:duplicate, existing_display(ctx.account, origin, "pushing")}
      end
    end
  rescue
    # This local phase does bang file I/O (spool/manifest writes) and Ash DB
    # writes that raise on a transient failure (disk full, `database is
    # locked`). It is called from the Engine's own handle_call (serial by
    # design), so a raise here MUST degrade to a clean rejection — a crashed
    # Engine would be supervisor-restarted and lose its RAM-only credential
    # closure, silently stopping the account.
    _error -> {:error, "push_failed"}
  catch
    :exit, _reason -> {:error, "push_failed"}
  end

  # Post-claim guard: any raise past the claim terminates the claimed op
  # `rejected` (best-effort — the claimed-without-spool boot recovery is the
  # backstop when even that write fails) so the partial-unique claim never
  # wedges, then degrades to the same clean error.
  defp snapshot_and_spool_guarded(ctx, op_row, draft_name, content_hash, buffer, path) do
    snapshot_and_spool(ctx, op_row, draft_name, content_hash, buffer, path)
  rescue
    _error ->
      best_effort_reject(op_row.id, "push_failed")
      {:error, "push_failed"}
  catch
    :exit, _reason ->
      best_effort_reject(op_row.id, "push_failed")
      {:error, "push_failed"}
  end

  # The failing subsystem may be the Store itself — never let the cleanup
  # transition raise through the guard. An op left `claimed` (transition also
  # failed) is provably un-transmitted and terminates `rejected` at the next
  # recover pass (`recover_claimed_append/2`).
  defp best_effort_reject(op_id, reason) do
    Store.transition_op(op_id, "rejected", %{error: reason})
  rescue
    _error -> :ok
  catch
    :exit, _reason -> :ok
  end

  # Snapshot-verify → validate → status-corroborate → compose+spool. Every
  # rejection here terminates the already-claimed op `rejected` (so a fixed
  # re-push can re-claim) and NEVER stamps the draft (the on-disk file may be
  # the newer, edited content).
  defp snapshot_and_spool(ctx, op_row, draft_name, content_hash, buffer, path) do
    cond do
      DraftFile.content_hash(buffer) != content_hash ->
        reject_push(op_row, "content_changed")

      true ->
        case DraftFile.parse_and_validate(buffer) do
          {:error, reason} ->
            reject_push(op_row, "invalid_draft: #{reason}")

          {:ok, parsed} ->
            case corroborate_status(ctx, op_row, parsed) do
              :ok ->
                compose_and_spool(ctx, op_row, draft_name, content_hash, parsed, path)

              {:error, reason} ->
                reject_push(op_row, reason)
            end
        end
    end
  end

  # Anti-forgery (spec §Drafting & push): a non-`draft` frontmatter status is
  # accepted ONLY when a PRIOR ledger op for this draft corroborates it (the
  # engine wrote it — a re-push of an edited, previously-pushed draft). With
  # no prior op it is agent-forged → rejected.
  defp corroborate_status(_ctx, _op_row, %{status: "draft"}), do: :ok

  defp corroborate_status(ctx, op_row, _parsed) do
    if prior_op?(ctx, op_row.origin, op_row.id),
      do: :ok,
      else: {:error, "status_forged"}
  end

  # Is there any OTHER ledger op for this draft — i.e. did the engine itself
  # ever stamp this file? `exclude_id` drops the caller's own already-claimed
  # row (the push path claims first, the send path checks before claiming).
  defp prior_op?(ctx, origin, exclude_id) do
    ctx.account
    |> Store.ops_by_origin(origin)
    |> Enum.any?(&(&1.id != exclude_id))
  end

  defp compose_and_spool(ctx, op_row, draft_name, content_hash, parsed, path) do
    {threading, notice} = resolve_threading(ctx, parsed.in_reply_to)
    from = draft_from(ctx)
    {:ok, rfc822} = DraftMime.compose(parsed, threading, op_row.message_id, from)
    payload_sha = sha256_hex(rfc822)

    write_spool_payload!(ctx, op_row.id, rfc822)

    manifest = %{
      "kind" => "append",
      "account" => ctx.account,
      "origin" => op_row.origin,
      "target_folder" => op_row.target_folder,
      "message_id" => op_row.message_id,
      "msg_id" => draft_name,
      "content_hash" => content_hash,
      "payload_sha256" => payload_sha,
      "fingerprint" => MessageFile.fingerprint(rfc822),
      "spool_path" => spool_payload_rel(op_row.id),
      "notice" => notice,
      "transitions" => ["spooled"]
    }

    write_manifest!(ctx, op_row.id, manifest)

    Store.transition_op(op_row.id, "pending", %{
      payload_sha256: payload_sha,
      spool_path: spool_payload_rel(op_row.id)
    })

    # CAS-stamp `status: pushing` (best-effort courtesy — the LEDGER is
    # authoritative for the displayed state). Only rewrites when the on-disk
    # file still hashes to the reviewed snapshot; record the stamped hash so
    # the terminal `pushed`/`draft` stamp can chain off it.
    case cas_stamp_draft(path, content_hash, "pushing") do
      {:ok, pushing_hash} ->
        write_manifest!(ctx, op_row.id, Map.put(manifest, "pushing_hash", pushing_hash))

      :unchanged ->
        :ok
    end

    {:ok, Map.merge(op_row, %{state: "pending", payload_sha256: payload_sha})}
  end

  @doc """
  NETWORK phase of a push (needs `ctx.conn`): re-verifies the spool payload
  hash, issues the idempotent APPEND (search-first by Message-ID), and drives
  the op to a terminal/parked state, CAS-stamping the draft to match.

    * `:ok` — proven appended (op `complete`, draft `pushed`).
    * `{:rejected, reason}` — a definite refusal or an un-transmitted claim
      (op `rejected`, draft reverted to `draft`).
    * `{:needs_review, reason}` — an unprovable outcome or a spool tamper (op
      `needs_review`, spool/manifest kept for the next reconcile).
  """
  @spec execute_append(ctx(), String.t()) ::
          :ok | {:needs_review, String.t()} | {:rejected, String.t()}
  def execute_append(ctx, op_id) when is_binary(op_id) do
    case Store.op_by_id(op_id) do
      {:ok, op_row} ->
        assert_op_account!(op_row, ctx)

        case op_row do
          %{state: "complete"} -> :ok
          %{state: "rejected", error: reason} -> {:rejected, reason || "rejected"}
          _pending -> dispatch_append(ctx, op_row)
        end

      {:error, _} ->
        {:rejected, "op_gone"}
    end
  end

  # The pending-ops ledger is WORKSPACE-wide — every account's rows share one
  # `app.sqlite` — while an op id is all an Engine hands the executor. An id
  # from a different account arriving on this account's connection would
  # append (later: send) one person's message through another person's
  # mailbox, so it is a wiring bug to fail loudly on, never a rejection to
  # record against the innocent op. `Engine.run_push/2` turns the raise into
  # an `:error` log (op id + account) and leaves the op pending — nothing here
  # is recorded against it.
  defp assert_op_account!(%{account: account} = op_row, %{account: account}), do: op_row

  defp assert_op_account!(op_row, ctx) do
    raise ArgumentError,
          "op #{op_row.id} belongs to account #{op_row.account}, engine ctx is #{ctx.account}"
  end

  defp dispatch_append(ctx, op_row) do
    case op_row.state do
      "claimed" -> recover_claimed_append(ctx, op_row)
      "pending" -> fresh_append(ctx, op_row)
      "executing" -> reconcile_append(ctx, op_row)
      "needs_review" -> reconcile_append(ctx, op_row)
      _other -> {:rejected, "unexpected_state"}
    end
  end

  # A `pending` append: verify the spool, search Drafts (idempotent), APPEND.
  # The search-first rule is FAIL-CLOSED (spec: "every append execution —
  # first attempt or retry — searches first"): a search that ERRORS is never
  # "not present" — with the same deterministic Message-ID a re-push after a
  # completed one would otherwise blind-APPEND a duplicate. On an
  # unanswerable search nothing is appended; the op stays `pending` so the
  # next attempt retries the search properly.
  defp fresh_append(ctx, op_row) do
    drafts = drafts_folder(ctx, op_row)

    case load_verified_payload(ctx, op_row) do
      {:ok, payload} ->
        case check_append_present(ctx, drafts, op_row.message_id) do
          {:ok, true} ->
            complete_append(ctx, op_row)

          {:ok, false} ->
            Store.transition_op(op_row.id, "executing")
            issue_append(ctx, op_row, drafts, payload)

          {:error, _reason} ->
            {:needs_review, "search_failed"}
        end

      {:error, :missing_spool} ->
        reject_append(ctx, op_row, "spool_missing")

      {:error, :payload_mismatch} ->
        needs_review_append(op_row, "payload_hash_mismatch")
    end
  end

  defp issue_append(ctx, op_row, drafts, payload) do
    case ctx.transport.append(ctx.conn, drafts, @draft_flags, payload) do
      {:ok, _result} ->
        complete_append(ctx, op_row)

      {:error, reason} when reason in [:closed, :timeout] ->
        # UNKNOWN outcome (lost response): the append MAY have landed and
        # another client may already have filed it — reconcile (widened),
        # never a blind re-APPEND.
        reconcile_append(ctx, op_row)

      {:error, _reason} ->
        # A definite refusal — nothing landed. Double-check Drafts (a racing
        # deliver), else reject and revert the draft to `draft`.
        if append_present?(ctx, drafts, op_row.message_id) do
          complete_append(ctx, op_row)
        else
          reject_append(ctx, op_row, "append_refused")
        end
    end
  end

  # UNKNOWN-outcome reconciliation (also the boot/pass recovery for
  # `executing`/`needs_review` rows): Drafts search-first, then a widened
  # all-folder search — exactly one fingerprint-confirmed match completes;
  # zero/several park in `needs_review`. NEVER a blind re-APPEND.
  defp reconcile_append(ctx, op_row) do
    drafts = drafts_folder(ctx, op_row)

    if append_present?(ctx, drafts, op_row.message_id) do
      complete_append(ctx, op_row)
    else
      case widened_confirm(ctx, op_row) do
        {:ok, _folder, _uid} -> complete_append(ctx, op_row)
        :none -> needs_review_append(op_row, "append_unproven")
        :several -> needs_review_append(op_row, "append_ambiguous")
      end
    end
  end

  # A `claimed` append at recovery is provably un-transmitted (no network I/O
  # happens before `pending` — the spool is written first): terminate
  # `rejected` and revert the draft for re-review (spec §Drafting & push,
  # crash orderings).
  defp recover_claimed_append(ctx, op_row), do: reject_append(ctx, op_row, "spool_missing")

  defp recover_appends(ctx) do
    ctx.account
    |> Store.pending_ops()
    |> Enum.filter(&(&1.kind == "append"))
    |> Enum.each(&dispatch_append(ctx, &1))
  end

  # -- append confirmation / search -------------------------------------------

  # Read-only presence check of the target folder for our Valea-generated
  # Message-ID — the primary idempotency guard (a match, in OUR unique id, is
  # definitively our draft; no re-APPEND). Three-way: a failed EXAMINE or
  # SEARCH is `{:error, reason}`, DISTINCT from a successful empty search —
  # the caller that decides to APPEND must never conflate the two.
  defp check_append_present(ctx, folder, message_id) do
    with {:ok, _info} <- ctx.transport.examine(ctx.conn, folder),
         {:ok, uids} <- checked_search_message_id(ctx, message_id) do
      {:ok, uids != []}
    else
      {:error, _reason} = error -> error
    end
  end

  # Unlike `search/2` (which swallows errors to `[]` for candidate scans),
  # this surfaces the search failure. Our push Message-IDs are always
  # generated-safe; the unsafe branch is unreachable belt-and-braces.
  defp checked_search_message_id(ctx, message_id) do
    if safe_message_id?(message_id) do
      ctx.transport.uid_search(ctx.conn, "HEADER Message-ID #{message_id}")
    else
      {:ok, []}
    end
  end

  # Boolean view for the CONFIRM-ONLY paths (reconciliation, the post-refusal
  # double-check) where an unanswerable search safely degrades to "not
  # proven" — those paths never APPEND on a negative.
  defp append_present?(ctx, folder, message_id),
    do: check_append_present(ctx, folder, message_id) == {:ok, true}

  # Widened all-folder search for an unknown outcome: a client/server rule may
  # have filed the new draft outside Drafts. Each Message-ID candidate is
  # fingerprint-confirmed (so a hostile message reusing the id can't count).
  defp widened_confirm(ctx, op_row) do
    fingerprint = (read_manifest(ctx, op_row.id) || %{})["fingerprint"]

    hits =
      ctx
      |> all_known_folders(op_row)
      |> Enum.flat_map(fn folder ->
        case ctx.transport.examine(ctx.conn, folder) do
          {:ok, _info} ->
            uids = search_message_id(ctx, op_row.message_id)

            confirmed =
              if fingerprint, do: fingerprint_confirm(ctx, uids, fingerprint), else: uids

            Enum.map(confirmed, &{folder, &1})

          {:error, _reason} ->
            []
        end
      end)

    case hits do
      [{folder, uid}] -> {:ok, folder, uid}
      [] -> :none
      _many -> :several
    end
  end

  defp all_known_folders(ctx, op_row),
    do: known_folders_with(ctx, drafts_folder(ctx, op_row))

  # Every mirrored folder plus `folder` (which may not be mirrored at all —
  # an account's Drafts or Sent folder need not be in the sync set).
  defp known_folders_with(ctx, folder) do
    ctx
    |> known_folders()
    |> MapSet.put(folder)
    |> MapSet.to_list()
  end

  defp search_message_id(ctx, message_id) do
    if safe_message_id?(message_id),
      do: search(ctx, "HEADER Message-ID #{message_id}"),
      else: []
  end

  # -- append terminal transitions --------------------------------------------

  defp complete_append(ctx, op_row) do
    Store.transition_op(op_row.id, "complete")
    cas_stamp_op(ctx, op_row, "pushed")
    cleanup_append_spool(ctx, op_row.id)
    :ok
  end

  defp reject_append(ctx, op_row, reason) do
    Store.transition_op(op_row.id, "rejected", %{error: reason})
    cas_stamp_op(ctx, op_row, "draft")
    cleanup_append_spool(ctx, op_row.id)
    {:rejected, reason}
  end

  # Left parked: spool + manifest survive for the next pass to re-prove.
  defp needs_review_append(op_row, reason) do
    Store.transition_op(op_row.id, "needs_review", %{error: reason})
    {:needs_review, reason}
  end

  defp reject_push(op_row, reason) do
    Store.transition_op(op_row.id, "rejected", %{error: reason})
    {:error, reason}
  end

  # -- append spool / payload -------------------------------------------------

  defp load_verified_payload(ctx, op_row) do
    case File.read(spool_payload_path(ctx, op_row.id)) do
      {:ok, payload} ->
        if is_binary(op_row.payload_sha256) and sha256_hex(payload) == op_row.payload_sha256,
          do: {:ok, payload},
          else: {:error, :payload_mismatch}

      {:error, _reason} ->
        {:error, :missing_spool}
    end
  end

  defp write_spool_payload!(ctx, id, bytes),
    do: write_spool_file!(spool_payload_path(ctx, id), bytes)

  # fsynced tmp + rename: the payload the network phase will re-hash must be
  # on disk BEFORE the ledger says it is.
  defp write_spool_file!(path, bytes) do
    File.mkdir_p!(Path.dirname(path))
    tmp = path <> ".tmp-#{System.unique_integer([:positive])}"
    File.write!(tmp, bytes)
    File.open!(tmp, [:read, :binary], fn f -> :file.datasync(f) end)
    File.rename!(tmp, path)
  end

  defp cleanup_append_spool(ctx, id) do
    File.rm(spool_payload_path(ctx, id))
    cleanup(ctx, id)
  end

  defp spool_payload_path(ctx, id),
    do: Path.join([ctx.root, "sources", "mail", ctx.account, "spool", "#{id}.eml"])

  defp spool_payload_rel(id), do: "#{id}.eml"

  # -- draft path / threading / stamp -----------------------------------------

  defp draft_origin(name), do: "drafts/" <> name

  # Validated basename: no separators, no dot-segments, must end `.md` (spec
  # §RPC surface / Push flow step 1).
  defp validate_draft_name(name) do
    cond do
      not is_binary(name) -> {:error, "invalid_draft_name"}
      name != Path.basename(name) -> {:error, "invalid_draft_name"}
      String.contains?(name, ["/", "\\", "\0"]) -> {:error, "invalid_draft_name"}
      name in [".", ".."] -> {:error, "invalid_draft_name"}
      String.contains?(name, "..") -> {:error, "invalid_draft_name"}
      not String.ends_with?(name, ".md") -> {:error, "invalid_draft_name"}
      true -> :ok
    end
  end

  # Containment via `resolve_real` (rejects a symlink escaping the drafts dir),
  # but the returned path is the LITERAL `drafts/<name>` — NOT `resolve_real`'s
  # symlink-followed result — so the caller's no-follow `lstat` sees (and
  # rejects) an IN-TREE symlink too, never the file it points at.
  defp resolve_draft_path(ctx, name) do
    drafts_dir = Path.join([ctx.root, "sources", "mail", ctx.account, "drafts"])

    case Paths.resolve_real(name, drafts_dir) do
      {:ok, _resolved} -> {:ok, Path.join(drafts_dir, name)}
      {:error, _reason} -> {:error, "not_found"}
    end
  end

  # No-follow open (spec §RPC surface): a REGULAR file with a SINGLE link,
  # read ONCE into an immutable buffer. A symlinked or hard-linked draft entry
  # (cross-account or arbitrary target) is refused, never composed.
  defp read_draft_nofollow(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, links: 1, size: size}} -> read_all_bytes(path, size)
      {:ok, _other} -> {:error, "not_found"}
      {:error, _reason} -> {:error, "not_found"}
    end
  end

  defp read_all_bytes(path, size) do
    case :file.open(path, [:read, :binary, :raw]) do
      {:ok, fd} ->
        result = :file.read(fd, size)
        :file.close(fd)

        case result do
          {:ok, bytes} -> {:ok, bytes}
          :eof -> {:ok, ""}
          {:error, _reason} -> {:error, "not_found"}
        end

      {:error, _reason} ->
        {:error, "not_found"}
    end
  end

  # `in_reply_to` msg_id → threading headers from the referenced message's raw
  # canonical file (a direct win of keeping RFC822). Absent/unmirrored/no
  # Message-ID → compose without threading, with a panel notice.
  defp resolve_threading(_ctx, nil), do: {%{in_reply_to: nil, references: []}, nil}

  defp resolve_threading(ctx, msg_id) do
    ctx.account
    |> Store.occurrences_by_msg_id(msg_id)
    |> Enum.reject(&(&1.msg_id == @oversize_msg_id))
    |> case do
      [occ | _] -> threading_from_occurrence(ctx, occ)
      [] -> {%{in_reply_to: nil, references: []}, "referenced message not mirrored"}
    end
  end

  defp threading_from_occurrence(ctx, occ) do
    with {:ok, raw} <- source_raw(ctx, occ.folder, occ),
         {:ok, %{message_id: mid} = msg} when is_binary(mid) and mid != "" <-
           Normalizer.normalize(raw) do
      refs = (msg.references || []) ++ [mid]
      {%{in_reply_to: mid, references: refs}, nil}
    else
      _ -> {%{in_reply_to: nil, references: []}, "referenced message has no usable Message-ID"}
    end
  end

  # Atomic compare-and-swap of the on-disk draft's `status:` frontmatter: only
  # rewrite when the file still hashes to `expected` (unedited since the last
  # snapshot/stamp) — an edited newer revision is left untouched. Returns the
  # stamped file's hash for chaining the next stamp.
  defp cas_stamp_draft(path, expected, status) do
    with {:ok, current} <- read_draft_nofollow(path),
         true <- DraftFile.content_hash(current) == expected,
         {:ok, stamped} <- DraftFile.stamp_status(current, status) do
      atomic_overwrite!(path, stamped)
      {:ok, DraftFile.content_hash(stamped)}
    else
      _ -> :unchanged
    end
  rescue
    # The stamp is a best-effort courtesy (the LEDGER is authoritative for the
    # displayed state) — a failed rewrite must never fail the push around it.
    _error -> :unchanged
  end

  # Stamp using the manifest's recorded snapshot: the in-flight stamp's hash
  # when present (`sending` for a send, `pushing` for a push — so a terminal
  # stamp chains cleanly off it), else the original snapshot hash. An edited
  # draft matches none of them and is left alone, which is the whole point.
  defp cas_stamp_op(ctx, op_row, status) do
    manifest = read_manifest(ctx, op_row.id) || %{}
    name = manifest["msg_id"] || op_row.msg_id
    expected = manifest["sending_hash"] || manifest["pushing_hash"] || manifest["content_hash"]

    if is_binary(name) and is_binary(expected) do
      case resolve_draft_path(ctx, name) do
        {:ok, path} -> cas_stamp_draft(path, expected, status)
        {:error, _reason} -> :unchanged
      end
    end

    :ok
  end

  defp atomic_overwrite!(path, bytes) do
    tmp = path <> ".tmp-#{System.unique_integer([:positive])}"
    File.write!(tmp, bytes)
    File.rename!(tmp, path)
  end

  # -- append helpers ---------------------------------------------------------

  defp drafts_folder(ctx, op_row), do: op_row.target_folder || ctx.settings.folders.drafts

  defp draft_from(ctx), do: ctx.settings.imap.username

  # The display state of whichever op currently holds this draft's claim —
  # the answer a losing claimant gets. `fallback` is what to say when the
  # winning row has already resolved between the failed claim and this read
  # (a push says "pushing", a send says "sending": both are about to be
  # refreshed from the ledger anyway).
  defp existing_display(account, origin, fallback) do
    account
    |> Store.ops_by_origin(origin)
    |> Enum.find(&(&1.state in @active_states))
    |> case do
      %{kind: kind, state: state} -> op_display(kind, state)
      nil -> fallback
    end
  end

  @doc "The non-terminal `mail_pending_ops` states — an op in one of these holds its draft's claim."
  @spec active_states() :: [String.t()]
  def active_states, do: @active_states

  @doc """
  Maps a `mail_pending_ops` state to the user-facing draft display state,
  in PUSH vocabulary (plus the two send-only states, whose names are the
  same either way). Prefer `op_display/2` wherever the op's kind is known:
  one origin can carry ops of both kinds, and `complete` means `pushed` for
  an append but `sent` for a send.
  """
  @spec op_display(String.t()) :: String.t()
  def op_display("complete"), do: "pushed"
  def op_display("needs_review"), do: "needs_review"
  def op_display("rejected"), do: "rejected"
  def op_display("transmitted"), do: "sending"
  def op_display("send_review"), do: "send_review"
  def op_display(_active), do: "pushing"

  @doc """
  Kind-aware display state (spec G, §Display projection): a send in ANY
  pre-terminal state reads `sending`, its parked state `send_review`, and its
  completion `sent` — never the append vocabulary `op_display/1` speaks.
  """
  @spec op_display(String.t(), String.t()) :: String.t()
  def op_display("send", "complete"), do: "sent"

  def op_display("send", state) when state in ["transmitted", "send_review", "rejected"],
    do: op_display(state)

  def op_display("send", _active), do: "sending"
  def op_display(_kind, state), do: op_display(state)

  defp sha256_hex(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  # ==========================================================================
  # send (spec G, §Send pipeline) — prepare (local) + transmit + Sent copy
  # ==========================================================================
  #
  # The transmitting sibling of the push above, sharing its machinery verbatim
  # (claim → snapshot → compose → spool → ledger) and adding exactly one
  # irreversible step. Three properties hold structurally, not by convention:
  #
  #   * **At most one `SmtpTransport.send/5` per op.** Only the `pending`
  #     branch of `execute_send/2` can reach the transport, and reaching it
  #     transitions the op out of `pending` (durably, BEFORE the call) — so no
  #     recovery, reconciliation, retry, or resolution path can transmit. The
  #     tests assert the call COUNT, not just the outcome.
  #   * **Nothing after the DATA dot is ever called provably-unsent.** The
  #     transport's tri-state decides: `{:error, _}` rejects (safe — the
  #     human can click again), `{:unknown, _}` parks in `send_review` for a
  #     human, and only a received `2xx` completes.
  #   * **What the human reviewed is what gets sent.** The review fingerprint
  #     (settings identity + resolved threading) is re-derived from the
  #     Engine's captured settings and compared BEFORE anything durable
  #     exists; the wire bytes' hash is re-verified immediately before the
  #     one transmit.

  @doc """
  The review fingerprint: an opaque hash over everything that decides HOW,
  AS WHOM, and INTO WHICH THREAD this account transmits — the account's SMTP
  send config (`Valea.Mail.Settings.smtp_fingerprint/1`'s frozen input
  string) joined to the review's RESOLVED threading.

  `send_draft` carries the value the human's review modal was rendered from;
  a re-derivation that no longer matches means the sending identity or the
  thread the message would join has drifted since (a settings hot-reload has
  no generation bump, and the referenced message can be deleted server-side),
  so the send is refused rather than transmitted under terms nobody
  reviewed. `nil` for a push-only account, exactly where `smtp_fingerprint/1`
  is `nil`.
  """
  @spec review_fingerprint(Settings.t(), DraftMime.threading() | nil) :: String.t() | nil
  def review_fingerprint(%{smtp: nil}, _threading), do: nil

  def review_fingerprint(%{smtp: smtp}, threading) do
    :sha256
    |> :crypto.hash(
      Settings.fingerprint_input(smtp) <> "\nthreading\n" <> canonical_threading(threading)
    )
    |> Base.encode16(case: :lower)
  end

  # An absent thread is the string "none", never "" — so "no threading" and
  # "threaded onto a message whose id happens to be empty" can't collide.
  defp canonical_threading(nil), do: "none"
  defp canonical_threading(%{in_reply_to: nil}), do: "none"

  defp canonical_threading(%{in_reply_to: in_reply_to, references: references}),
    do: in_reply_to <> "\n" <> Enum.join(references || [], "\n")

  @doc """
  THE review snapshot (spec G §RPC surface, `get_mail_draft_review`): ONE
  no-follow read of the draft, and everything the confirm modal renders comes
  out of that one buffer — the parsed recipient set, the subject, the resolved
  threading (or its absence plus the warning), the config-owned sending
  identity, the review fingerprint, and the `content_hash` OF THAT SAME
  BUFFER.

  Nothing the human sees may come from a different read than the hashes they
  confirm, which is why this is one function and not a composition of the
  listing's parse plus a separate hash.
  """
  @spec review_snapshot(map(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def review_snapshot(ctx, draft_name) when is_binary(draft_name) do
    with :ok <- validate_draft_name(draft_name),
         {:ok, path} <- resolve_draft_path(ctx, draft_name),
         {:ok, buffer} <- read_draft_nofollow(path),
         {:ok, validated} <- validate_send_draft(buffer) do
      {threading, notice} = resolve_threading(ctx, validated.in_reply_to)

      {:ok,
       %{
         "content" => buffer,
         "content_hash" => DraftFile.content_hash(buffer),
         "recipients" => %{
           "to" => Enum.map(validated.to, &addr_map/1),
           "cc" => Enum.map(validated.cc, &addr_map/1),
           "bcc" => Enum.map(validated.bcc, &addr_map/1)
         },
         "subject" => validated.subject,
         "threading" => threading_map(threading),
         "threading_warning" => notice != nil,
         "identity" => identity_map(ctx),
         "review_fingerprint" => review_fingerprint(ctx.settings, threading),
         "smtp_configured" => Settings.smtp_configured?(ctx.settings)
       }}
    end
  rescue
    _error -> {:error, "review_failed"}
  end

  defp addr_map(%{name: name, email: email}), do: %{"name" => name, "email" => email}

  defp threading_map(%{in_reply_to: nil}), do: nil

  defp threading_map(%{in_reply_to: in_reply_to, references: references}),
    do: %{"in_reply_to" => in_reply_to, "references" => references || []}

  defp identity_map(%{settings: %{smtp: nil}} = ctx),
    do: %{"from" => nil, "from_name" => nil, "account" => ctx.account}

  defp identity_map(%{settings: %{smtp: smtp}} = ctx),
    do: %{"from" => smtp.from, "from_name" => smtp.from_name, "account" => ctx.account}

  @doc """
  LOCAL phase of a send (no connection, no transmission): the same
  validate → contain → no-follow-snapshot → hash-verify → parse chain as
  `prepare_push/3`, plus the send-only guards, then the atomic claim, the
  dual composition, and the fsynced spool.

  The order is the contract (spec G §Send pipeline / §RPC surface). Every
  check that can refuse the send runs BEFORE anything durable exists — the
  threading resolution and fingerprint comparison need the parsed snapshot,
  so the side-effect-free read necessarily precedes them, but the claim,
  the spool, and the composition all come after:

    1. basename → containment → no-follow read → `content_hash` verify →
       `parse_and_validate` → status anti-forgery → size guard.
    2. threading resolved from the referenced message's canonical file.
    3. review fingerprint re-derived and compared (`re_review_required`).
    4. atomic claim on the widened `(account, origin)` index — a push or a
       second send holding this draft loses here, with no second op created.
    5. wire + record composed from the ONE buffer, both fsynced into
       `spool/` with a manifest, hashes onto the row, `claimed → pending`,
       draft CAS-stamped `sending`.

  `ctx` is the LOCAL ctx `%{root, account, settings}` — the Engine's
  captured `state.settings`, never a re-read (see the Engine's
  `send_draft/4`).
  """
  @spec prepare_send(map(), String.t(), String.t(), String.t() | nil) ::
          {:ok, map()} | {:duplicate, String.t()} | {:error, String.t()}
  def prepare_send(ctx, draft_name, content_hash, review_fingerprint)
      when is_binary(draft_name) and is_binary(content_hash) do
    with :ok <- validate_draft_name(draft_name),
         {:ok, path} <- resolve_draft_path(ctx, draft_name),
         {:ok, buffer} <- read_draft_nofollow(path),
         :ok <- verify_send_hash(buffer, content_hash),
         {:ok, validated} <- validate_send_draft(buffer),
         :ok <- corroborate_send_status(ctx, draft_name, validated),
         :ok <- check_send_size(ctx, buffer),
         {threading, notice} <- resolve_threading(ctx, validated.in_reply_to),
         :ok <- check_review_fingerprint(ctx, threading, review_fingerprint) do
      claim_send(ctx, %{
        draft_name: draft_name,
        content_hash: content_hash,
        buffer: buffer,
        validated: validated,
        threading: threading,
        notice: notice,
        path: path
      })
    end
  rescue
    # Same posture as `prepare_push/3`: this runs INSIDE the Engine's
    # handle_call, and a raise here would fell the Engine and with it the
    # RAM-only credentials. Nothing has been transmitted at any point this
    # can raise, so degrading to a clean refusal is always safe.
    _error -> {:error, "send_failed"}
  catch
    :exit, _reason -> {:error, "send_failed"}
  end

  defp verify_send_hash(buffer, content_hash) do
    if DraftFile.content_hash(buffer) == content_hash,
      do: :ok,
      else: {:error, "content_changed"}
  end

  defp validate_send_draft(buffer) do
    case DraftFile.parse_and_validate(buffer) do
      {:ok, validated} -> {:ok, validated}
      {:error, reason} -> {:error, "invalid_draft: #{reason}"}
    end
  end

  # The push path corroborates AFTER claiming (and excludes its own row); the
  # send path refuses before claiming, so there is no row to exclude.
  defp corroborate_send_status(_ctx, _draft_name, %{status: "draft"}), do: :ok

  defp corroborate_send_status(ctx, draft_name, _validated) do
    if prior_op?(ctx, draft_origin(draft_name), nil),
      do: :ok,
      else: {:error, "status_forged"}
  end

  # `sync.max_message_bytes` bounds what this account will transmit. Measured
  # on the reviewed SNAPSHOT rather than the composed message, because the
  # bound has to be enforced from the pre-claim position the ordering above
  # demands — and because the snapshot is what the human actually reviewed.
  defp check_send_size(ctx, buffer) do
    if byte_size(buffer) > ctx.settings.sync.max_message_bytes,
      do: {:error, "draft_too_large"},
      else: :ok
  end

  defp check_review_fingerprint(ctx, threading, claimed) do
    if review_fingerprint(ctx.settings, threading) == claimed,
      do: :ok,
      else: {:error, "re_review_required"}
  end

  defp claim_send(ctx, snapshot) do
    origin = draft_origin(snapshot.draft_name)
    canonical_hash = sha256_hex(DraftFile.canonical_send_bytes(snapshot.buffer))

    message_id =
      DraftMime.send_message_id(ctx.account, snapshot.draft_name, canonical_hash)

    case Store.create_pending_op(%{
           kind: "send",
           account: ctx.account,
           origin: origin,
           target_folder: ctx.settings.folders.sent,
           message_id: message_id,
           msg_id: snapshot.draft_name,
           content_hash: snapshot.content_hash,
           state: "claimed"
         }) do
      {:ok, op_row} ->
        spool_send_guarded(ctx, op_row, Map.put(snapshot, :canonical_hash, canonical_hash))

      {:error, :duplicate_active} ->
        # Covers the push-vs-send mutex too: the widened index is one claim
        # per draft across both outbound kinds.
        {:duplicate, existing_display(ctx.account, origin, "sending")}
    end
  end

  # Post-claim guard, exactly as the push has: a raise past the claim
  # terminates the claimed op `rejected` (best effort) so the claim can never
  # wedge the draft. Still strictly pre-transmit — `execute_send/2` owns
  # everything from `pending` on.
  defp spool_send_guarded(ctx, op_row, snapshot) do
    spool_send(ctx, op_row, snapshot)
  rescue
    _error ->
      best_effort_reject(op_row.id, "send_failed")
      {:error, "send_failed"}
  catch
    :exit, _reason ->
      best_effort_reject(op_row.id, "send_failed")
      {:error, "send_failed"}
  end

  defp spool_send(ctx, op_row, snapshot) do
    smtp = ctx.settings.smtp

    {:ok, %{wire: wire, record: record, envelope: envelope}} =
      DraftMime.compose_send(
        snapshot.validated,
        snapshot.threading,
        op_row.message_id,
        smtp.from,
        smtp.from_name
      )

    wire_sha = sha256_hex(wire)
    record_sha = sha256_hex(record)

    write_spool_file!(send_payload_path(ctx, op_row.id, :wire), wire)
    write_spool_file!(send_payload_path(ctx, op_row.id, :record), record)

    manifest = %{
      "kind" => "send",
      "account" => ctx.account,
      "origin" => op_row.origin,
      "target_folder" => op_row.target_folder,
      "message_id" => op_row.message_id,
      "msg_id" => snapshot.draft_name,
      "content_hash" => snapshot.content_hash,
      "canonical_hash" => snapshot.canonical_hash,
      "review_fingerprint" => review_fingerprint(ctx.settings, snapshot.threading),
      "wire_sha256" => wire_sha,
      "record_sha256" => record_sha,
      "envelope" => %{"from" => envelope.from, "rcpt" => envelope.rcpt},
      "threading" => %{
        "in_reply_to" => snapshot.threading[:in_reply_to],
        "references" => snapshot.threading[:references] || []
      },
      "provider" => provider_string(ctx),
      "notice" => snapshot.notice,
      "reconcile_attempts" => 0,
      "transitions" => ["spooled"]
    }

    write_manifest!(ctx, op_row.id, manifest)

    Store.transition_op(op_row.id, "pending", %{
      wire_sha256: wire_sha,
      record_sha256: record_sha,
      envelope_rcpt: Jason.encode!(envelope.rcpt)
    })

    # CAS-stamp `status: sending` (courtesy — the LEDGER is authoritative).
    # The stamped hash chains the terminal `sent`/`draft` stamp, exactly as
    # the push's `pushing_hash` does.
    case cas_stamp_draft(snapshot.path, snapshot.content_hash, "sending") do
      {:ok, sending_hash} ->
        write_manifest!(ctx, op_row.id, Map.put(manifest, "sending_hash", sending_hash))

      :unchanged ->
        :ok
    end

    {:ok,
     Map.merge(op_row, %{state: "pending", wire_sha256: wire_sha, record_sha256: record_sha})}
  end

  @doc """
  NETWORK phase of a send: the one transmit, then the Sent copy. Dispatches
  on the op's durable state, and ONLY the `pending` branch can reach the SMTP
  transport — every other state is a resume, a reconcile, or a refusal.

    * `:ok` — sent and filed (op `complete`, draft `sent`). A `complete` op
      carrying `sent_copy_failed` is also `:ok`: the mail IS sent, only its
      Sent copy is outstanding (`retry_sent_copy/2`).
    * `{:sending, notice}` — transmitted, Sent copy deferred (no IMAP
      connection yet); the next connected recover finishes it.
    * `{:send_review, reason}` — the outcome is not knowable; parked for the
      human, spool kept, NEVER retried.
    * `{:rejected, reason}` — provably unsent (op `rejected`, draft reverted
      to `draft` for a fresh review-and-click).
  """
  @spec execute_send(ctx(), String.t()) ::
          :ok | {:sending, String.t()} | {:send_review, String.t()} | {:rejected, String.t()}
  def execute_send(ctx, op_id) when is_binary(op_id) do
    case Store.op_by_id(op_id) do
      {:ok, op_row} ->
        assert_op_account!(op_row, ctx)
        dispatch_send(ctx, op_row)

      {:error, _} ->
        {:rejected, "op_gone"}
    end
  end

  defp dispatch_send(ctx, op_row) do
    case op_row.state do
      "pending" -> transmit(ctx, op_row)
      # The crash window: the op is at-or-past DATA with no recorded outcome.
      "executing" -> park_send_review(op_row, "crashed_during_transmit")
      "transmitted" -> sent_copy_step(ctx, op_row)
      "send_review" -> reconcile_send(ctx, op_row)
      "complete" -> :ok
      "rejected" -> {:rejected, op_row.error || "rejected"}
      # `claimed` included: it has no spool payload, so it is provably
      # un-transmitted and belongs to `classify_sends_local/1`, not here.
      _other -> {:rejected, "unexpected_state"}
    end
  end

  # THE transmit. Both durable records (ledger `executing`, manifest
  # `transmitting`) are written BEFORE the call, so a crash at any instant
  # around it is recoverable as "at-or-past DATA, outcome unknown" rather
  # than being mistaken for un-transmitted.
  defp transmit(ctx, op_row) do
    case load_verified_send_payload(ctx, op_row, :wire) do
      {:ok, wire} ->
        manifest = read_manifest(ctx, op_row.id) || %{}
        Store.transition_op(op_row.id, "executing")
        manifest = transition(ctx, op_row.id, manifest, "transmitting")

        ctx.smtp_transport.send(
          ctx.settings.smtp,
          ctx.smtp_credential,
          send_envelope(ctx, op_row, manifest),
          wire,
          []
        )
        |> handle_transmit_result(ctx, op_row, manifest)

      {:error, :missing_spool} ->
        reject_send(ctx, op_row, "spool_missing")

      {:error, :payload_mismatch} ->
        reject_send(ctx, op_row, "payload_hash_mismatch")
    end
  end

  defp handle_transmit_result({:ok, :accepted}, ctx, op_row, manifest) do
    Store.transition_op(op_row.id, "transmitted")
    transition(ctx, op_row.id, manifest, "transmitted")
    sent_copy_step(ctx, %{op_row | state: "transmitted"})
  end

  defp handle_transmit_result({:error, {:rejected_recipients, list}}, ctx, op_row, _manifest) do
    reject_send(ctx, op_row, rejected_recipients_reason(list))
  end

  defp handle_transmit_result({:error, reason}, ctx, op_row, _manifest) do
    # Provably unsent (everything before the server's 354, plus a RECEIVED
    # final non-2xx after the dot): reject, revert the draft, let the human
    # click again.
    reject_send(ctx, op_row, scrub(ctx, "send_failed: #{inspect(reason)}"))
  end

  defp handle_transmit_result({:unknown, reason}, ctx, op_row, manifest) do
    # The message may or may not have been delivered and nothing can prove
    # which: park it. The spool survives for the gmail reconciliation and the
    # human resolution — and nothing will ever transmit it again.
    transition(ctx, op_row.id, manifest, "send_review")
    park_send_review(op_row, scrub(ctx, "send_unknown: #{inspect(reason)}"))
  end

  defp rejected_recipients_reason(list) do
    "rejected_recipients: " <>
      Enum.map_join(list, "; ", fn {addr, reason} -> "#{addr}: #{reason}" end)
  end

  # The op's error string is broadcast to the UI and stored in the ledger —
  # defense-in-depth against a transport error term that quoted the secret.
  defp scrub(ctx, string), do: Redact.text(string, Map.get(ctx, :smtp_credential))

  # The envelope the manifest recorded (it survives database loss); the row +
  # settings are the fallback for a manifest that lost the key.
  defp send_envelope(ctx, op_row, manifest) do
    case manifest["envelope"] do
      %{"from" => from, "rcpt" => rcpt} when is_binary(from) and is_list(rcpt) ->
        %{from: from, rcpt: rcpt}

      _missing ->
        %{from: ctx.settings.smtp.from, rcpt: decode_rcpt(op_row.envelope_rcpt)}
    end
  end

  defp decode_rcpt(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end

  defp decode_rcpt(_json), do: []

  # -- Sent copy ---------------------------------------------------------------

  # Gmail files SMTP-sent mail into Sent Mail itself — appending would
  # duplicate it. Every other provider gets the RECORD variant (Bcc kept)
  # through the push's own idempotent, search-first append machinery.
  defp sent_copy_step(ctx, op_row) do
    if gmail?(ctx), do: complete_send(ctx, op_row, nil), else: generic_sent_copy(ctx, op_row)
  end

  # No connection: the mail is out and the op stays `transmitted`, resumed by
  # the next IMAP-connected recover. NEVER a reason to re-transmit.
  defp generic_sent_copy(%{conn: nil}, _op_row), do: {:sending, "sent_copy_pending"}

  defp generic_sent_copy(ctx, op_row) do
    sent = sent_folder(ctx, op_row)

    case check_append_present(ctx, sent, op_row.message_id) do
      {:ok, true} -> complete_send(ctx, op_row, nil)
      {:ok, false} -> file_sent_copy(ctx, op_row, sent)
      # An unanswerable search is never "not present" (it would duplicate the
      # copy). Leave the op `transmitted` for the next pass to re-prove.
      {:error, _reason} -> {:sending, "sent_copy_pending"}
    end
  end

  defp file_sent_copy(ctx, op_row, sent) do
    case load_verified_send_payload(ctx, op_row, :record) do
      {:ok, record} ->
        case ctx.transport.append(ctx.conn, sent, @sent_flags, record) do
          {:ok, _result} ->
            complete_send(ctx, op_row, nil)

          {:error, _reason} ->
            # A failed Sent copy CANNOT un-send the mail: complete either way,
            # with a notice + retry affordance when the copy really is missing.
            if append_present?(ctx, sent, op_row.message_id),
              do: complete_send(ctx, op_row, nil),
              else: complete_send(ctx, op_row, "sent_copy_failed")
        end

      {:error, _reason} ->
        complete_send(ctx, op_row, "sent_copy_failed")
    end
  end

  defp sent_folder(ctx, op_row), do: op_row.target_folder || ctx.settings.folders.sent

  # -- send terminal transitions -----------------------------------------------

  defp complete_send(ctx, op_row, error) do
    Store.transition_op(op_row.id, "complete", %{error: error})
    cas_stamp_op(ctx, op_row, "sent")
    audit_send(ctx, op_row, error)

    # A `sent_copy_failed` completion KEEPS the spool: `retry_sent_copy/2`
    # re-runs the append from that record payload.
    if is_nil(error), do: cleanup_send_spool(ctx, op_row.id)
    :ok
  end

  defp reject_send(ctx, op_row, reason) do
    Store.transition_op(op_row.id, "rejected", %{error: reason})
    cas_stamp_op(ctx, op_row, "draft")
    cleanup_send_spool(ctx, op_row.id)
    {:rejected, reason}
  end

  # Parked for the human. The draft keeps its `sending` stamp on purpose: it
  # is NOT provably unsent, and reverting it would invite a second send.
  defp park_send_review(op_row, reason) do
    Store.transition_op(op_row.id, "send_review", %{error: reason})
    {:send_review, reason}
  end

  defp audit_send(ctx, op_row, error) do
    if Process.whereis(Valea.Audit) do
      Valea.Audit.append("mail_sent", %{
        "account" => ctx.account,
        "op" => op_row.id,
        "message_id" => op_row.message_id,
        "recipients" => length(decode_rcpt(op_row.envelope_rcpt)),
        "sent_copy" => error || "filed"
      })
    end

    :ok
  end

  # -- send reconciliation / human resolution ----------------------------------

  # A parked send. The generic profile has nothing that could prove either
  # way — only the human can resolve it. The gmail profile can search Sent
  # Mail, which is proof when it hits.
  defp reconcile_send(ctx, op_row) do
    if gmail?(ctx),
      do: gmail_reconcile_send(ctx, op_row),
      else: {:send_review, "awaiting_resolution"}
  end

  defp gmail_reconcile_send(%{conn: nil}, op_row),
    do: {:send_review, op_row.error || "awaiting_reconcile"}

  defp gmail_reconcile_send(ctx, op_row) do
    case check_append_present(ctx, sent_folder(ctx, op_row), op_row.message_id) do
      {:ok, true} ->
        resume_transmitted(ctx, op_row)

      {:ok, false} ->
        if send_present_anywhere?(ctx, op_row),
          do: resume_transmitted(ctx, op_row),
          else: count_empty_check(ctx, op_row)

      # A failed search proves nothing and must not count against the bounded
      # window: stay parked, try again next pass.
      {:error, _reason} ->
        {:send_review, op_row.error || "awaiting_reconcile"}
    end
  end

  # Found: transmission is PROVEN, so the op rejoins the accepted path.
  defp resume_transmitted(ctx, op_row) do
    Store.transition_op(op_row.id, "transmitted")
    transition(ctx, op_row.id, read_manifest(ctx, op_row.id) || %{}, "transmitted")
    sent_copy_step(ctx, %{op_row | state: "transmitted"})
  end

  # A complete-but-empty search is a strong signal, not proof (Sent Mail
  # visibility after a 250 is not guaranteed instant). Count it; past the
  # bounded window say so and stay parked — NEVER auto-reject.
  defp count_empty_check(ctx, op_row) do
    manifest = read_manifest(ctx, op_row.id) || %{}
    attempts = (manifest["reconcile_attempts"] || 0) + 1
    write_manifest!(ctx, op_row.id, Map.put(manifest, "reconcile_attempts", attempts))

    if attempts >= @reconcile_attempt_limit do
      Store.transition_op(op_row.id, "send_review", %{error: "gmail_sent_checked_empty"})
      {:send_review, "gmail_sent_checked_empty"}
    else
      {:send_review, op_row.error || "awaiting_reconcile"}
    end
  end

  # Our Message-ID is Valea-generated and unique to this op, so ANY folder
  # holding it proves the transmission — unlike the append path, several hits
  # are not ambiguous here.
  defp send_present_anywhere?(ctx, op_row) do
    ctx
    |> known_folders_with(sent_folder(ctx, op_row))
    |> Enum.any?(fn folder ->
      case ctx.transport.examine(ctx.conn, folder) do
        {:ok, _info} -> search_message_id(ctx, op_row.message_id) != []
        {:error, _reason} -> false
      end
    end)
  end

  @doc """
  The human's verdict on a parked send (spec G §Send pipeline 4):
  `:sent` runs the idempotent Sent copy and completes; `:not_sent` rejects
  the op and reverts the draft for another explicit click (which re-sends
  under the SAME deterministic Message-ID, so a wrong verdict threads/dedupes
  recipient-side rather than reading as an unrelated second mail).

  Only ever valid on a `send_review` op of `ctx.account`. Never transmits.
  """
  @spec resolve_send_review(ctx(), String.t(), :sent | :not_sent) ::
          :ok | {:error, :not_reviewable}
  def resolve_send_review(ctx, op_id, resolution)
      when is_binary(op_id) and resolution in [:sent, :not_sent] do
    case Store.op_by_id(op_id) do
      {:ok, %{state: "send_review", account: account} = op_row} when account == ctx.account ->
        apply_resolution(ctx, op_row, resolution)
        :ok

      _other ->
        {:error, :not_reviewable}
    end
  end

  defp apply_resolution(ctx, op_row, :sent), do: resume_transmitted(ctx, op_row)
  defp apply_resolution(ctx, op_row, :not_sent), do: reject_send(ctx, op_row, "resolved_not_sent")

  @doc """
  Re-runs ONLY the idempotent Sent copy of a send that completed with a
  `sent_copy_failed` notice. The mail was already transmitted — this touches
  IMAP alone and can never reach the SMTP transport.
  """
  @spec retry_sent_copy(ctx(), String.t()) :: :ok | {:error, :not_retryable}
  def retry_sent_copy(ctx, op_id) when is_binary(op_id) do
    case Store.op_by_id(op_id) do
      {:ok, %{state: "complete", error: "sent_copy_failed", account: account} = op_row}
      when account == ctx.account ->
        _ = sent_copy_step(ctx, op_row)
        :ok

      _other ->
        {:error, :not_retryable}
    end
  end

  @doc """
  The Engine-activation classification pass (spec G §Crash recovery): resolves
  every in-flight send from the LEDGER AND MANIFESTS ALONE — no network, so a
  send stranded by a crash is never held hostage to a paused or failing IMAP
  sync.

    * `claimed` — no spool payload can exist yet → provably un-transmitted →
      `rejected`, draft reverted.
    * `pending` — spooled, but the transmit provably never started (it
      transitions `executing` first, durably) → `rejected`, draft reverted.
    * `executing` — at-or-past DATA with no recorded outcome → `send_review`.
    * `transmitted` / `send_review` — left exactly alone: their follow-ups
      (the Sent-copy resume, the gmail reconciliation) need a connection.

  Deliberately NOT called from a sync pass: a `pending` send can legitimately
  be sitting in the Engine's work queue while a pass runs, and rejecting THAT
  would break a send the user is waiting on.
  """
  @spec classify_sends_local(map()) :: :ok
  def classify_sends_local(ctx) do
    ctx.account
    |> Store.pending_ops()
    |> Enum.filter(&(&1.kind == "send"))
    |> Enum.each(&classify_send_local(ctx, &1))

    :ok
  rescue
    # Activation must never fail on this: an Engine that doesn't start is an
    # account that silently stops syncing.
    _error -> :ok
  catch
    :exit, _reason -> :ok
  end

  defp classify_send_local(ctx, %{state: "claimed"} = op_row),
    do: reject_send(ctx, op_row, "crashed_before_spool")

  defp classify_send_local(ctx, %{state: "pending"} = op_row),
    do: reject_send(ctx, op_row, "crashed_before_transmit")

  defp classify_send_local(_ctx, %{state: "executing"} = op_row),
    do: park_send_review(op_row, "crashed_during_transmit")

  defp classify_send_local(_ctx, _op_row), do: :ok

  # The IMAP-connected half of send recovery, run inside `recover/1`. It can
  # only ever RESUME the idempotent Sent copy or RECONCILE (search) — there is
  # no path from here to the SMTP transport, and `claimed`/`pending` sends are
  # deliberately untouched (a queued send is legitimately `pending`).
  defp recover_sends(ctx) do
    ctx.account
    |> Store.pending_ops()
    |> Enum.filter(&(&1.kind == "send"))
    |> Enum.each(&recover_send(ctx, &1))
  end

  defp recover_send(ctx, %{state: "transmitted"} = op_row), do: sent_copy_step(ctx, op_row)
  defp recover_send(ctx, %{state: "send_review"} = op_row), do: reconcile_send(ctx, op_row)

  # The network-path mirror of `classify_sends_local/1`'s `executing` clause,
  # for a row that entered this state without an Engine restart in between (a
  # crashed send task, or an orphan manifest recreated by the sweep above).
  # Safe here where a `pending` classification would not be: an `executing`
  # send holds the Engine's single work slot, so one can never be in flight
  # while a pass runs.
  defp recover_send(_ctx, %{state: "executing"} = op_row),
    do: park_send_review(op_row, "crashed_during_transmit")

  defp recover_send(_ctx, _op_row), do: :ok

  # -- send spool --------------------------------------------------------------

  defp load_verified_send_payload(ctx, op_row, variant) do
    expected = if variant == :wire, do: op_row.wire_sha256, else: op_row.record_sha256

    case File.read(send_payload_path(ctx, op_row.id, variant)) do
      {:ok, payload} ->
        if is_binary(expected) and sha256_hex(payload) == expected,
          do: {:ok, payload},
          else: {:error, :payload_mismatch}

      {:error, _reason} ->
        {:error, :missing_spool}
    end
  end

  defp send_payload_path(ctx, id, variant),
    do: Path.join(spool_dir(ctx), "#{id}.#{variant}.eml")

  defp cleanup_send_spool(ctx, id) do
    File.rm(send_payload_path(ctx, id, :wire))
    File.rm(send_payload_path(ctx, id, :record))
    cleanup(ctx, id)
  end

  # ==========================================================================
  # flag STORE (contract 5)
  # ==========================================================================

  @doc false
  @spec execute_flag(ctx(), OpsFile.op(), non_neg_integer(), String.t()) ::
          {:ok, nil} | {:needs_review, String.t()} | {:rejected, String.t()}
  def execute_flag(ctx, %{op: :flag} = op, index, _origin) do
    case single_occurrence(ctx, op.msg_id, op.folder) do
      {:ok, occ} ->
        case source_fingerprint(ctx, op.folder, occ) do
          {:ok, fingerprint} -> do_flag(ctx, op, index, occ, fingerprint)
          {:error, reason} -> {:rejected, to_string(reason)}
        end

      :error ->
        {:rejected, "no_single_occurrence"}
    end
  end

  defp do_flag(ctx, op, index, occ, fingerprint) do
    condstore? = ctx.transport.supports?(ctx.conn, :condstore)
    baseline_imap = Maildir.flags_to_imap(occ.flags)
    modseq = if condstore?, do: fetch_modseq(ctx, op.folder, occ.uid), else: nil

    # Durable recovery baseline — fsynced BEFORE the STORE, bound to the
    # claimed ops file's op-id (ops-file path only).
    maybe_write_state(ctx, index, %{
      folder: op.folder,
      uid: occ.uid,
      uidvalidity: occ.uidvalidity,
      baseline_flags: baseline_imap,
      modseq: modseq,
      postcondition: %{add: op.add, remove: op.remove},
      source_uidvalidity: occ.uidvalidity,
      fingerprint: fingerprint
    })

    case verify_flag_source(ctx, op.folder, occ, fingerprint) do
      {:ok, base_flags} -> issue_store(ctx, op, occ, base_flags, modseq, condstore?)
      {:rejected, reason} -> {:rejected, reason}
    end
  end

  # Execution-time verification for flags (contract 1, applied exactly as to
  # moves) + a snapshot of the live IMAP flags used as `base_flags` for a
  # combined guarded STORE.
  defp verify_flag_source(ctx, folder, occ, fingerprint) do
    with {:ok, %{uidvalidity: uidvalidity}} when uidvalidity == occ.uidvalidity <-
           ctx.transport.select(ctx.conn, folder),
         {:ok, raw} <- ctx.transport.uid_fetch_full(ctx.conn, occ.uid),
         true <- MessageFile.fingerprint(raw) == fingerprint,
         {:ok, [%{flags: flags}]} <- ctx.transport.uid_fetch_flags(ctx.conn, "#{occ.uid}") do
      {:ok, flags}
    else
      _ -> {:rejected, "server_changed"}
    end
  end

  defp issue_store(ctx, op, occ, base_flags, modseq, condstore?) do
    add_imap = maildir_letters_to_imap(op.add)
    remove_imap = maildir_letters_to_imap(op.remove)
    opts = store_opts(add_imap, remove_imap, base_flags, modseq, condstore?)

    case ctx.transport.uid_store_flags(ctx.conn, occ.uid, add_imap, remove_imap, opts) do
      {:ok, :applied} ->
        apply_flag_locally(ctx, op, occ)
        {:ok, nil}

      {:ok, :modified} ->
        {:needs_review, "baseline_moved"}

      {:error, _reason} ->
        {:needs_review, "flag_store_uncertain"}
    end
  end

  # A combined add+remove under UNCHANGEDSINCE needs base_flags for the
  # single atomic FLAGS replace (see the Transport callback docs); every
  # other shape is a plain +/-FLAGS.
  defp store_opts(add, remove, base_flags, modseq, true) when add != [] and remove != [],
    do: [unchangedsince: modseq, base_flags: base_flags]

  defp store_opts(_add, _remove, _base_flags, modseq, true), do: [unchangedsince: modseq]
  defp store_opts(_add, _remove, _base_flags, _modseq, false), do: []

  defp apply_flag_locally(ctx, op, occ) do
    add = MapSet.new(op.add)
    remove = MapSet.new(op.remove)
    new_flags = occ.flags |> MapSet.union(add) |> MapSet.difference(remove)
    dir_rel = folder_dir_rel(ctx, op.folder)

    if dir_rel do
      dir_abs = folder_dir_abs(ctx, dir_rel)
      old_name = Maildir.encode_filename(occ.msg_id, occ.uid, occ.flags)
      new_name = Maildir.encode_filename(occ.msg_id, occ.uid, new_flags)
      rename_cur(dir_abs, old_name, new_name)

      Store.put_occurrence(ctx.account, op.folder, %{
        uid: occ.uid,
        uidvalidity: occ.uidvalidity,
        msg_id: occ.msg_id,
        flags: new_flags
      })

      write_index_row(ctx, op.folder, dir_rel, occ.uid, occ.msg_id, new_flags, new_name)
      refresh_view(ctx, occ.msg_id)
    end

    :ok
  end

  # ==========================================================================
  # recover (contract 6) — boot / pass-start reconciliation
  # ==========================================================================

  @doc """
  Reconciles every in-flight op before any new op executes. Runs at the top
  of every pass and every RPC ops batch:

    1. **Orphan-manifest sweep** (spec §Store + §Testing "database-loss
       recovery"). SQLite is pure cache for everything except `mail_pending_ops`,
       which is made *recoverable* by a self-contained `spool/*.manifest.yaml`
       fsynced before any remote I/O. After database loss the ledger rows are
       gone but the manifests survive; `sweep_orphan_manifests/1` enumerates
       `spool/` independently of the ledger and, for each manifest whose op-id
       has NO row, recreates a ledger row from the manifest in a NON-TERMINAL
       reconcile state (`executing`) so the confirm-first paths below resolve
       it — a move through `reconcile_move` (never a fresh blind execute, never
       an unverified purge), an append through `reconcile_append` (search-first,
       widened, never a duplicate APPEND). A malformed/unreadable manifest is
       quarantined with a recorded reason rather than crashing the pass; a
       manifest that still has a ledger row is left to the normal paths (cleaned
       at op completion as today).
    2. Move ledger rows in `pending`/`executing`/`needs_review` are reconciled
       (confirm-first, idempotent) from their manifests.
    3. Append ledger rows are driven to a terminal/parked state.
    4. Claimed ops files lacking a result sidecar are replayed (flag ops resolve
       via their recorded baselines) and their results written.
  """
  @spec recover(ctx()) :: :ok
  def recover(ctx) do
    sweep_orphan_manifests(ctx)
    recover_moves(ctx)
    recover_appends(ctx)
    recover_sends(ctx)
    recover_ops_files(ctx)
    :ok
  end

  # -- orphan-manifest sweep (database-loss recovery) -------------------------

  # Enumerate `spool/` for `*.manifest.yaml` whose op-id has no ledger row and
  # recreate a blocked (non-terminal) row so the confirm-first reconcile below
  # resolves each without duplicate delivery. Manifests WITH a row are left to
  # the normal recover paths.
  defp sweep_orphan_manifests(ctx) do
    case File.ls(spool_dir(ctx)) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".manifest.yaml"))
        |> Enum.each(fn name ->
          id = String.replace_suffix(name, ".manifest.yaml", "")
          if orphan_manifest?(id), do: recreate_orphan_row(ctx, id)
        end)

      {:error, _reason} ->
        :ok
    end
  end

  defp orphan_manifest?(id) do
    match?({:error, _}, Store.op_by_id(id))
  end

  # Recreate a ledger row from an orphan manifest. A malformed/unreadable
  # manifest (unparseable, missing `kind`, or an unknown kind) is quarantined
  # with a recorded reason rather than crashing the pass.
  defp recreate_orphan_row(ctx, id) do
    case read_manifest(ctx, id) do
      %{"kind" => "move"} = manifest -> recreate_move_row(ctx, id, manifest)
      %{"kind" => "append"} = manifest -> recreate_append_row(ctx, id, manifest)
      %{"kind" => "send"} = manifest -> recreate_send_row(ctx, id, manifest)
      _malformed -> quarantine_manifest(ctx, id, "malformed_or_unknown_manifest")
    end
  end

  # A move is recreated in `executing` so `recover_moves/1` routes it to
  # `reconcile_move` (confirm-first) — never `execute/2`'s fresh blind ladder.
  defp recreate_move_row(ctx, id, manifest) do
    required = [
      manifest["account"],
      manifest["source_folder"],
      manifest["target_folder"],
      manifest["uid"],
      manifest["source_uidvalidity"],
      manifest["msg_id"],
      manifest["origin"]
    ]

    if Enum.any?(required, &is_nil/1) do
      quarantine_manifest(ctx, id, "incomplete_move_manifest")
    else
      {:ok, _row} =
        Store.create_pending_op(%{
          id: id,
          kind: "move",
          account: manifest["account"],
          source_folder: manifest["source_folder"],
          target_folder: manifest["target_folder"],
          uid: manifest["uid"],
          source_uidvalidity: manifest["source_uidvalidity"],
          dest_watermark: manifest["dest_watermark"],
          dest_uidvalidity: manifest["dest_uidvalidity"],
          msg_id: manifest["msg_id"],
          message_id: manifest["message_id"],
          origin: manifest["origin"],
          state: "executing"
        })

      :ok
    end
  rescue
    _error -> quarantine_manifest(ctx, id, "move_manifest_recreate_failed")
  end

  # An append is recreated in `executing` so `recover_appends/1` routes it to
  # `reconcile_append` (search-first, widened) — never `fresh_append/2`, which
  # could blind-APPEND a duplicate of a message the lost original already landed.
  defp recreate_append_row(ctx, id, manifest) do
    required = [
      manifest["account"],
      manifest["target_folder"],
      manifest["message_id"],
      manifest["origin"]
    ]

    if Enum.any?(required, &is_nil/1) do
      quarantine_manifest(ctx, id, "incomplete_append_manifest")
    else
      case Store.create_pending_op(%{
             id: id,
             kind: "append",
             account: manifest["account"],
             target_folder: manifest["target_folder"],
             message_id: manifest["message_id"],
             msg_id: manifest["msg_id"],
             origin: manifest["origin"],
             spool_path: manifest["spool_path"],
             payload_sha256: manifest["payload_sha256"],
             state: "executing"
           }) do
        {:ok, _row} ->
          :ok

        {:error, :duplicate_active} ->
          quarantine_manifest(ctx, id, "duplicate_active_append_manifest")
      end
    end
  rescue
    _error -> quarantine_manifest(ctx, id, "append_manifest_recreate_failed")
  end

  # A send is recreated at the state its manifest's LAST recorded transition
  # proves: `spooled` never reached the transport (`pending`), `transmitting`
  # is at-or-past DATA with no recorded outcome (`executing`, which the
  # classification pass immediately parks in `send_review`), `transmitted`
  # resumes its Sent copy, `send_review` stays parked. Anything unrecognized
  # fails SAFE to `executing` — never to a state that could transmit.
  defp recreate_send_row(ctx, id, manifest) do
    required = [
      manifest["account"],
      manifest["target_folder"],
      manifest["message_id"],
      manifest["origin"]
    ]

    if Enum.any?(required, &is_nil/1) do
      quarantine_manifest(ctx, id, "incomplete_send_manifest")
    else
      case Store.create_pending_op(%{
             id: id,
             kind: "send",
             account: manifest["account"],
             target_folder: manifest["target_folder"],
             message_id: manifest["message_id"],
             msg_id: manifest["msg_id"],
             origin: manifest["origin"],
             content_hash: manifest["content_hash"],
             wire_sha256: manifest["wire_sha256"],
             record_sha256: manifest["record_sha256"],
             envelope_rcpt: encode_manifest_rcpt(manifest["envelope"]),
             state: send_recreate_state(manifest)
           }) do
        {:ok, _row} ->
          :ok

        {:error, :duplicate_active} ->
          quarantine_manifest(ctx, id, "duplicate_active_send_manifest")
      end
    end
  rescue
    _error -> quarantine_manifest(ctx, id, "send_manifest_recreate_failed")
  end

  defp send_recreate_state(manifest) do
    case List.last(manifest["transitions"] || []) do
      "spooled" -> "pending"
      "transmitted" -> "transmitted"
      "send_review" -> "send_review"
      _at_or_past_data -> "executing"
    end
  end

  defp encode_manifest_rcpt(%{"rcpt" => rcpt}) when is_list(rcpt), do: Jason.encode!(rcpt)
  defp encode_manifest_rcpt(_envelope), do: nil

  # Move the unresolvable manifest to `quarantine/` (with a `.reason` sidecar)
  # so the pass continues and the operator can inspect it — the same posture as
  # OpsFile's link-unsafe quarantine.
  defp quarantine_manifest(ctx, id, reason) do
    dir = Path.join([ctx.root, "sources", "mail", ctx.account, "quarantine"])
    File.mkdir_p!(dir)
    dest = Path.join(dir, "#{id}.manifest.yaml-#{System.unique_integer([:positive])}")
    File.rename(manifest_path(ctx, id), dest)
    File.write(dest <> ".reason", reason)
    :ok
  end

  defp recover_moves(ctx) do
    ctx.account
    |> Store.pending_ops()
    |> Enum.filter(&(&1.kind == "move" and &1.state in ["pending", "executing", "needs_review"]))
    |> Enum.each(fn op_row ->
      case read_manifest(ctx, op_row.id) do
        nil ->
          Store.transition_op(op_row.id, "needs_review", %{error: "manifest_lost"})

        manifest ->
          # A `pending` move never reached the ladder (no mutating I/O), so
          # re-execute it fresh (verification + ladder). An `executing` OR a
          # parked `needs_review` move is re-reconciled (confirm-first, never a
          # blind retry): the same proving logic resolves it whenever the
          # server state has since become provable (source gone + a single
          # confirmed destination ⇒ complete; a proven-duplicate source ⇒
          # purged then complete), cleaning up the manifest; anything still
          # ambiguous stays `needs_review` with its manifest intact so the next
          # pass tries again. No new destructive step runs on an unprovable
          # outcome — `M2`.
          if op_row.state == "pending",
            do: execute(ctx, op_row),
            else: reconcile_move(ctx, op_row, manifest)
      end
    end)
  end

  defp reconcile_move(ctx, op_row, manifest) do
    if manifest["provider"] == "gmail",
      do: gmail_prove(ctx, op_row, manifest),
      else: reconcile_generic(ctx, op_row, manifest)
  end

  # Generic (non-gmail) reconciliation: confirm the destination; if proven,
  # finish purging the source (idempotent, verification-gated — see
  # `ensure_source_gone/3`) and finalize; otherwise needs_review. NEVER a
  # blind re-copy/re-move, and never a purge the source can't re-prove.
  defp reconcile_generic(ctx, op_row, manifest) do
    case confirm_destination(ctx, op_row, manifest, nil) do
      {:ok, dest_uid, dest_uidvalidity} ->
        case ensure_source_gone(ctx, op_row, manifest) do
          :ok ->
            finalize(ctx, op_row, manifest, dest_uid, dest_uidvalidity)
            complete(ctx, op_row)

          {:needs_review, reason} ->
            needs_review(ctx, op_row, reason)
        end

      :none ->
        needs_review(ctx, op_row, "destination_unconfirmed")

      :several ->
        needs_review(ctx, op_row, "ambiguous_destination")
    end
  end

  # Ensures the source occurrence is gone (native MOVE already removed it;
  # a COPY ladder interrupted before EXPUNGE completes it here). Idempotent —
  # and the purge is gated by execution-time verification EXACTLY like a fresh
  # ladder (spec §Safety invariants — verification before every mutation, no
  # skippable branch): the live UIDVALIDITY must equal the op's recorded one
  # AND the live uid must fingerprint-match the manifest. A reset recycles
  # uids, so without this gate a reconcile (this runs on every pass for parked
  # `needs_review` rows) would permanently expunge whatever UNRELATED message
  # now holds the old uid. Any mismatch → `{:needs_review, "source_reset"}`,
  # never a purge; the destination confirmation stays re-provable next pass.
  defp ensure_source_gone(ctx, op_row, manifest) do
    case ctx.transport.select(ctx.conn, op_row.source_folder) do
      {:ok, %{uidvalidity: uidvalidity}} ->
        case search(ctx, "UID #{op_row.uid}") do
          [] ->
            :ok

          _present ->
            if uidvalidity == op_row.source_uidvalidity and
                 fingerprint_confirm(ctx, [op_row.uid], manifest["fingerprint"]) == [op_row.uid] do
              purge_source(ctx, op_row, manifest)
              :ok
            else
              {:needs_review, "source_reset"}
            end
        end

      {:error, _reason} ->
        :ok
    end
  end

  defp recover_ops_files(ctx) do
    Enum.each(OpsFile.unresolved(ctx.root, ctx.account), fn %{opid: opid, path: path} ->
      replay_ops_file(ctx, opid, path)
    end)
  end

  # Replays one claimed-without-result ops file. Move ops are already tracked
  # in the ledger (reconciled by `recover_moves/1`); flag ops resolve via
  # their `.state.yaml` baselines. A tampered (links>1 / swapped) copy is
  # refused, never parsed.
  defp replay_ops_file(ctx, opid, path) do
    states = OpsFile.read_op_states(ctx.root, ctx.account, opid)

    case OpsFile.read_claimed!(path) do
      {:ok, bytes} ->
        case OpsFile.parse(bytes) do
          {:ok, ops} -> write_replay_results(ctx, opid, path, ops, states)
          {:error, reason} -> write_file_result(ctx, opid, path, reason)
        end

      {:error, _reason} ->
        write_file_result(ctx, opid, path, "claimed file failed link-safety re-check on replay")
    end
  end

  defp write_replay_results(ctx, opid, path, ops, states) do
    results =
      ops
      |> Enum.with_index()
      |> Enum.map(fn {op, index} -> resolve_replay(ctx, op, index, states) end)

    OpsFile.write_results!(ctx.root, ctx.account, opid, original_name(path), results)
  end

  # A file-level rejection (malformed on replay, or a link-safety failure):
  # one result entry so the claimed file gets its `.result.yaml` and is no
  # longer unresolved.
  defp write_file_result(ctx, opid, path, reason) do
    OpsFile.write_results!(ctx.root, ctx.account, opid, original_name(path), [
      %{op: 0, result: "rejected", reason: to_string(reason)}
    ])
  end

  defp resolve_replay(ctx, %{op: :flag}, index, states) do
    case Map.get(states, index) do
      nil -> result(index, :needs_review, "no_recovery_baseline")
      state -> recover_flag(ctx, index, state)
    end
  end

  # Move ops resolve through the ledger/manifest (reconcile_move already ran);
  # report their current ledger state so the result file is complete.
  defp resolve_replay(ctx, %{op: :move, msg_id: msg_id, from: from}, index, _states) do
    result(index, move_replay_status(ctx, msg_id, from), nil)
  end

  # Flag recovery (contract 5): refetch flags — postcondition already present
  # → ok; baseline moved → needs_review (never an overwriting STORE); exactly
  # the recorded baseline → one UNCHANGEDSINCE-guarded retry.
  defp recover_flag(ctx, index, state) do
    # Recycled-UID guard: a UIDVALIDITY reset since the sidecar was written
    # renumbers UIDs, so a live UID matching `state.uid` is a DIFFERENT
    # message — never issue a guarded retry against it.
    with {:ok, %{uidvalidity: uidvalidity}} <- ctx.transport.select(ctx.conn, state.folder),
         true <- uidvalidity == state.uidvalidity,
         {:ok, [%{flags: live}]} <- ctx.transport.uid_fetch_flags(ctx.conn, "#{state.uid}") do
      cond do
        postcondition_met?(live, state.postcondition) ->
          result(index, :ok, nil)

        MapSet.equal?(MapSet.new(live), MapSet.new(state.baseline_flags)) ->
          retry_flag_store(ctx, index, state)

        true ->
          result(index, :needs_review, "baseline_moved")
      end
    else
      _ -> result(index, :needs_review, "flag_recovery_unresolved")
    end
  end

  defp retry_flag_store(ctx, index, state) do
    add = maildir_letters_to_imap(state.postcondition.add)
    remove = maildir_letters_to_imap(state.postcondition.remove)
    opts = store_opts(add, remove, state.baseline_flags, state.modseq, state.modseq != nil)

    case ctx.transport.uid_store_flags(ctx.conn, state.uid, add, remove, opts) do
      {:ok, :applied} -> result(index, :ok, nil)
      {:ok, :modified} -> result(index, :needs_review, "baseline_moved")
      {:error, _reason} -> result(index, :needs_review, "flag_store_uncertain")
    end
  end

  defp postcondition_met?(live, %{add: add, remove: remove}) do
    live_set = MapSet.new(live)
    add_set = MapSet.new(maildir_letters_to_imap(add))
    remove_set = MapSet.new(maildir_letters_to_imap(remove))

    MapSet.subset?(add_set, live_set) and MapSet.disjoint?(remove_set, live_set)
  end

  defp move_replay_status(ctx, msg_id, from) do
    # The move's ledger row already carries its resolved state (the orphan
    # sweep + `recover_moves/1` ran first, so a DB-loss move has a row again).
    # Query ANY state — `pending_ops/1` hides terminal rows, so it could not
    # tell a resolved `complete` move from one whose row never existed. A
    # genuinely MISSING row (no manifest, no ledger — nothing to reconcile
    # from) is NOT silently reported `ok`: fail closed to `needs_review`.
    ctx.account
    |> Store.move_ops(msg_id, from)
    |> case do
      [] ->
        :needs_review

      rows ->
        if Enum.any?(rows, &(&1.state in ["pending", "executing", "needs_review"])),
          do: :needs_review,
          else: :ok
    end
  end

  # ==========================================================================
  # finalize — local occurrence relocate / remove (contracts 2/3/4)
  # ==========================================================================

  # Relocate into a mirrored destination (new `U=`), or remove the local
  # occurrence for a write-through (excluded) destination — only ever after a
  # confirmed destination.
  defp finalize(ctx, op_row, manifest, dest_uid, dest_uidvalidity) do
    if manifest["write_through"] do
      remove_local(ctx, op_row, manifest)
    else
      relocate_local(ctx, op_row, manifest, dest_uid, dest_uidvalidity)
    end
  end

  defp relocate_local(ctx, op_row, manifest, dest_uid, dest_uidvalidity) do
    msg_id = op_row.msg_id
    flags = flags_from_string(manifest["flags"])
    src_dir_rel = folder_dir_rel(ctx, op_row.source_folder)
    dest_dir_rel = ensure_folder_dir(ctx, op_row.target_folder)

    raw = read_source_raw(ctx, src_dir_rel, op_row.uid, msg_id, flags)

    if dest_dir_rel && dest_uid && raw do
      dest_abs = folder_dir_abs(ctx, dest_dir_rel)
      Maildir.mailbox_dirs(dest_abs)
      Maildir.write_folder_identity!(dest_abs, op_row.target_folder)
      new_name = Maildir.encode_filename(msg_id, dest_uid, flags)
      Maildir.deliver!(dest_abs, new_name, raw)

      remove_source_file(ctx, src_dir_rel, op_row.uid, msg_id, flags)
      Store.delete_occurrence(ctx.account, op_row.source_folder, op_row.uid)
      Store.delete_index_row(ctx.account, op_row.source_folder, op_row.uid)

      Store.put_occurrence(ctx.account, op_row.target_folder, %{
        uid: dest_uid,
        uidvalidity: dest_uidvalidity,
        msg_id: msg_id,
        flags: flags
      })

      write_index_row(ctx, op_row.target_folder, dest_dir_rel, dest_uid, msg_id, flags, new_name)
      refresh_view(ctx, msg_id)
    else
      # The destination isn't locally mirrorable (or the source file is gone);
      # drop the source occurrence and let the next pull land the destination.
      remove_local(ctx, op_row, manifest)
    end

    :ok
  end

  defp remove_local(ctx, op_row, manifest) do
    msg_id = op_row.msg_id
    flags = flags_from_string(manifest["flags"])
    src_dir_rel = folder_dir_rel(ctx, op_row.source_folder)

    if src_dir_rel, do: remove_source_file(ctx, src_dir_rel, op_row.uid, msg_id, flags)
    Store.delete_occurrence(ctx.account, op_row.source_folder, op_row.uid)
    Store.delete_index_row(ctx.account, op_row.source_folder, op_row.uid)

    if msg_id != @oversize_msg_id do
      remaining = Store.occurrences_by_msg_id(ctx.account, msg_id)
      Views.remove_occurrence(ctx.root, ctx.account, msg_id, length(remaining))
      if remaining != [], do: refresh_view(ctx, msg_id)
    end

    :ok
  end

  # ==========================================================================
  # ledger / manifest transitions
  # ==========================================================================

  defp complete(ctx, op_row) do
    Store.transition_op(op_row.id, "complete")
    cleanup(ctx, op_row.id)
    :ok
  end

  defp needs_review(_ctx, op_row, reason) do
    # Left executing → the local file is untouched, no destructive step
    # taken; the manifest survives for the next reconciliation.
    Store.transition_op(op_row.id, "needs_review", %{error: reason})
    {:needs_review, reason}
  end

  defp transition(ctx, id, manifest, step) do
    updated = Map.update(manifest, "transitions", [step], &(&1 ++ [step]))
    write_manifest!(ctx, id, updated)
    updated
  end

  defp write_manifest!(ctx, id, manifest) do
    path = manifest_path(ctx, id)
    File.mkdir_p!(Path.dirname(path))
    bytes = Jason.encode!(manifest, pretty: true)
    tmp = path <> ".tmp-#{System.unique_integer([:positive])}"
    File.write!(tmp, bytes)
    File.open!(tmp, [:read, :binary], fn f -> :file.datasync(f) end)
    File.rename!(tmp, path)
  end

  defp read_manifest(ctx, id) do
    case YamlElixir.read_from_file(manifest_path(ctx, id)) do
      {:ok, map} when is_map(map) -> map
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp cleanup(ctx, id), do: File.rm(manifest_path(ctx, id))

  defp spool_dir(ctx),
    do: Path.join([ctx.root, "sources", "mail", ctx.account, "spool"])

  defp manifest_path(ctx, id),
    do: Path.join([spool_dir(ctx), "#{id}.manifest.yaml"])

  # ==========================================================================
  # small helpers
  # ==========================================================================

  defp validate_ctx(ctx) do
    %{
      account: ctx.account,
      occurrences_by_msg_id: fn msg_id -> Store.occurrences_by_msg_id(ctx.account, msg_id) end,
      known_folders: known_folders(ctx),
      write_through: MapSet.new([ctx.settings.folders.archive, ctx.settings.folders.trash])
    }
  end

  defp known_folders(ctx) do
    ctx.account
    |> Store.folders()
    |> Enum.reject(& &1.held)
    |> Enum.map(& &1.folder)
    |> MapSet.new()
  end

  defp single_occurrence(ctx, msg_id, folder) do
    ctx.account
    |> Store.occurrences_by_msg_id(msg_id)
    |> Enum.filter(&(&1.folder == folder and &1.msg_id != @oversize_msg_id))
    |> case do
      [occ] -> {:ok, occ}
      _zero_or_many -> :error
    end
  end

  # `single_occurrence/3` for enqueue returns `{:rejected, _}` (a validated op
  # should always resolve; a race that loses it is a rejection, not a crash).
  defp source_fingerprint(ctx, folder, occ) do
    case source_raw(ctx, folder, occ) do
      {:ok, raw} -> {:ok, MessageFile.fingerprint(raw)}
      :error -> stored_fingerprint(ctx, occ)
    end
  end

  defp source_raw(ctx, folder, occ) do
    dir_rel = folder_dir_rel(ctx, folder)

    with true <- is_binary(dir_rel),
         path when is_binary(path) <-
           source_file_path(ctx, dir_rel, occ.uid, occ.msg_id, occ.flags),
         {:ok, raw} <- File.read(path) do
      {:ok, raw}
    else
      _ -> :error
    end
  end

  defp stored_fingerprint(ctx, occ) do
    case Views.stored_fingerprint(ctx.root, ctx.account, occ.msg_id) do
      nil -> {:error, :source_unavailable}
      fingerprint -> {:ok, fingerprint}
    end
  end

  defp examine_dest(ctx, folder) do
    case ctx.transport.examine(ctx.conn, folder) do
      {:ok, %{uidvalidity: uidvalidity} = info} ->
        watermark = if is_integer(info[:uidnext]), do: info.uidnext - 1, else: 0
        {:ok, %{uidvalidity: uidvalidity, watermark: watermark}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp capture_gm_msgid(ctx, folder, uid) do
    with {:ok, _info} <- ctx.transport.select(ctx.conn, folder),
         {:ok, results} <- ctx.transport.uid_fetch_flags(ctx.conn, "#{uid}"),
         %{gm_msgid: gm} <- Enum.find(results, &(&1.uid == uid)) do
      gm
    else
      _ -> nil
    end
  end

  defp fetch_modseq(ctx, folder, uid) do
    with {:ok, _info} <- ctx.transport.select(ctx.conn, folder),
         {:ok, results} <- ctx.transport.uid_fetch_flags(ctx.conn, "#{uid}"),
         %{modseq: modseq} <- Enum.find(results, &(&1.uid == uid)) do
      modseq
    else
      _ -> nil
    end
  end

  defp maybe_write_state(%{opid: opid} = ctx, index, state) when is_binary(opid),
    do: OpsFile.write_op_state!(ctx.root, ctx.account, opid, index, state)

  defp maybe_write_state(_ctx, _index, _state), do: :ok

  defp gmail?(ctx), do: ctx.settings.provider == :gmail
  defp provider_string(ctx), do: to_string(ctx.settings.provider)

  defp excluded?(ctx, folder), do: folder in ctx.settings.sync.exclude_folders

  defp index_message_id(account, msg_id) do
    case Store.message_rows_by_msg_id(account, msg_id) do
      [%{message_id: mid} | _] -> mid
      _ -> nil
    end
  end

  @unsafe_message_id_chars ~r/["()\\{}%*]/
  defp safe_message_id?(mid) do
    String.match?(mid, ~r/^[\x21-\x7E]+$/) and not String.match?(mid, @unsafe_message_id_chars)
  end

  defp search(ctx, criteria) do
    case ctx.transport.uid_search(ctx.conn, criteria) do
      {:ok, uids} -> uids
      {:error, _reason} -> []
    end
  end

  defp maildir_letters_to_imap(letters), do: letters |> MapSet.new() |> Maildir.flags_to_imap()

  defp flags_to_string(flags), do: flags |> Enum.sort() |> Enum.join()
  defp flags_from_string(nil), do: MapSet.new()
  defp flags_from_string(str), do: str |> String.graphemes() |> MapSet.new()

  defp folder_dir_rel(ctx, folder) do
    case Store.get_sync_state(ctx.account, folder) do
      {:ok, %{dir: dir}} when is_binary(dir) -> dir
      _ -> nil
    end
  end

  # For a mirrored destination we may need to allocate a dir the first time an
  # op targets a folder no message has landed in yet.
  defp ensure_folder_dir(ctx, folder) do
    case folder_dir_rel(ctx, folder) do
      nil -> allocate_folder_dir(ctx, folder)
      dir -> dir
    end
  end

  defp allocate_folder_dir(ctx, folder) do
    taken =
      ctx.account
      |> Store.folders()
      |> Enum.map(& &1.dir)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&(&1 |> String.downcase() |> :unicode.characters_to_nfc_binary()))
      |> MapSet.new()

    Maildir.folder_to_dir(folder, taken)
  end

  defp folder_dir_abs(ctx, dir_rel),
    do: Path.join([ctx.root, "sources", "mail", ctx.account, "maildir", dir_rel])

  defp source_file_path(ctx, dir_rel, uid, msg_id, flags) do
    dir_abs = folder_dir_abs(ctx, dir_rel)
    found = dir_abs |> Maildir.list_occurrences() |> Enum.find(&(&1.uid == uid))
    name = if found, do: found.filename, else: Maildir.encode_filename(msg_id, uid, flags)
    Path.join([dir_abs, "cur", name])
  end

  defp read_source_raw(_ctx, nil, _uid, _msg_id, _flags), do: nil

  defp read_source_raw(ctx, dir_rel, uid, msg_id, flags) do
    case File.read(source_file_path(ctx, dir_rel, uid, msg_id, flags)) do
      {:ok, raw} -> raw
      {:error, _reason} -> nil
    end
  end

  defp remove_source_file(ctx, dir_rel, uid, msg_id, flags) do
    File.rm(source_file_path(ctx, dir_rel, uid, msg_id, flags))
  end

  defp rename_cur(dir_abs, old_name, new_name) do
    cur = Path.join(dir_abs, "cur")
    old_path = Path.join(cur, old_name)
    if File.exists?(old_path), do: File.rename(old_path, Path.join(cur, new_name))
  end

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

  defp write_index_row(ctx, folder, dir_rel, uid, msg_id, flags, filename) do
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
      flags: flags |> Enum.sort() |> Enum.join(),
      has_attachments: meta.has_attachments,
      path: path,
      in_reply_to: meta.in_reply_to,
      references: meta.references
    })
  end

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

  defp original_name(path), do: Path.basename(path)

  defp normalize_date(nil), do: nil
  defp normalize_date(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp normalize_date(str) when is_binary(str), do: str

  defp references_string(nil), do: nil
  defp references_string([]), do: nil
  defp references_string(list) when is_list(list), do: Enum.join(list, " ")
end
