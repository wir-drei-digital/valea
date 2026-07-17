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
  alias Valea.Mail.Store
  alias Valea.Mail.Views
  alias Valea.Paths

  @oversize_msg_id "__oversize__"

  # IMAP `\Draft` flag on the appended message (maildir `D`), pull-only —
  # never STOREd by the executor's flag path, only set at APPEND time.
  @draft_flags ["\\Draft"]

  @type ctx :: %{
          required(:root) => String.t(),
          required(:account) => String.t(),
          required(:settings) => Valea.Mail.Settings.t(),
          required(:transport) => module(),
          required(:conn) => term(),
          optional(:opid) => String.t() | nil
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
  # THERE IS NO SMTP. The only outbound path is the USER clicking
  # Push-to-Drafts, which APPENDs the rendered MIME to the account's Drafts
  # folder. `prepare_push/3` is fully LOCAL (atomic claim + hash-verified
  # snapshot + compose + fsynced spool) and runs synchronously in the Engine
  # loop; `execute_append/2` is the network half and rides the Engine's
  # single serialized work slot exactly like a sync pass. The push is
  # idempotent by a stable Valea-generated Message-ID: every attempt searches
  # the Drafts folder for it first, so a lost response never lands a duplicate.

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
          snapshot_and_spool(ctx, op_row, draft_name, content_hash, buffer, path)

        {:error, :duplicate_active} ->
          {:duplicate, existing_display(ctx.account, origin)}
      end
    end
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
    others =
      ctx.account
      |> Store.ops_by_origin(op_row.origin)
      |> Enum.reject(&(&1.id == op_row.id))

    if others == [], do: {:error, "status_forged"}, else: :ok
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
      {:ok, %{state: "complete"}} -> :ok
      {:ok, %{state: "rejected", error: reason}} -> {:rejected, reason || "rejected"}
      {:ok, op_row} -> dispatch_append(ctx, op_row)
      {:error, _} -> {:rejected, "op_gone"}
    end
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
  defp fresh_append(ctx, op_row) do
    drafts = drafts_folder(ctx, op_row)

    case load_verified_payload(ctx, op_row) do
      {:ok, payload} ->
        if append_present?(ctx, drafts, op_row.message_id) do
          complete_append(ctx, op_row)
        else
          Store.transition_op(op_row.id, "executing")
          issue_append(ctx, op_row, drafts, payload)
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
  # definitively our draft; no re-APPEND).
  defp append_present?(ctx, folder, message_id) do
    case ctx.transport.examine(ctx.conn, folder) do
      {:ok, _info} -> search_message_id(ctx, message_id) != []
      {:error, _reason} -> false
    end
  end

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

  defp all_known_folders(ctx, op_row) do
    ctx
    |> known_folders()
    |> MapSet.put(drafts_folder(ctx, op_row))
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

  defp write_spool_payload!(ctx, id, bytes) do
    path = spool_payload_path(ctx, id)
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
  end

  # Stamp using the manifest's recorded snapshot: the `pushing`-stamped hash
  # when present (so a happy-path terminal stamp chains cleanly), else the
  # original snapshot hash.
  defp cas_stamp_op(ctx, op_row, status) do
    manifest = read_manifest(ctx, op_row.id) || %{}
    name = manifest["msg_id"] || op_row.msg_id
    expected = manifest["pushing_hash"] || manifest["content_hash"]

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

  defp existing_display(account, origin) do
    account
    |> Store.ops_by_origin(origin)
    |> Enum.find(&(&1.state in ["claimed", "pending", "executing", "needs_review"]))
    |> case do
      %{state: state} -> op_display(state)
      nil -> "pushing"
    end
  end

  @doc "Maps a `mail_pending_ops` state to the user-facing draft display state."
  @spec op_display(String.t()) :: String.t()
  def op_display("complete"), do: "pushed"
  def op_display("needs_review"), do: "needs_review"
  def op_display("rejected"), do: "rejected"
  def op_display(_active), do: "pushing"

  defp sha256_hex(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

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
  Reconciles every in-flight op before any new op executes: move ledger rows
  in `pending`/`executing`/`needs_review` are reconciled (confirm-first,
  idempotent) from their manifests, and claimed ops files lacking a result
  sidecar are replayed (flag ops resolve via their recorded baselines) and
  their results written.
  """
  @spec recover(ctx()) :: :ok
  def recover(ctx) do
    recover_moves(ctx)
    recover_appends(ctx)
    recover_ops_files(ctx)
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
    # The move's ledger row already carries its resolved state.
    ctx.account
    |> Store.pending_ops()
    |> Enum.find(&(&1.kind == "move" and &1.msg_id == msg_id and &1.source_folder == from))
    |> case do
      %{state: "needs_review"} -> :needs_review
      %{state: state} when state in ["pending", "executing"] -> :needs_review
      _resolved_or_absent -> :ok
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

  defp manifest_path(ctx, id),
    do: Path.join([ctx.root, "sources", "mail", ctx.account, "spool", "#{id}.manifest.yaml"])

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
