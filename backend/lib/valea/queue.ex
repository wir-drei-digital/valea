defmodule Valea.Queue do
  @moduledoc """
  The proposal queue: `queue/pending/<run_id>.json` items written by
  `Valea.Workflows.Runner`, and the HARDENED approval path that turns one
  into an executed side effect (today: an email draft file).

  Movement between states is a `File.rename/2` between sibling directories on
  the same workspace filesystem — atomic, so a claim can never be lost or
  duplicated by two callers racing the same item. The queue directory a file
  currently lives in IS the state machine:

      pending -> processing -> approved
      pending -> processing -> rejected

  The DECIDED envelope carries more than the pending one did: on the way into
  `approved/`/`rejected/` its bytes are upgraded from `queue_item/v1` to
  `queue_item/v2`, stamping the durable `mailbox_ops` intents a later mailbox
  pass consumes (see `approve/2` step 6 and `reject/2`). Both decisions do
  this as an in-place atomic rewrite of the ALREADY-CLAIMED `processing/`
  file (single writer) before the final rename into the terminal directory,
  so the rename-is-the-claim guarantee holds for BOTH verbs: a concurrent
  approve and reject of the same item mutually exclude at the claim, the
  loser seeing `:queue_item_gone`.

  `revision` (sha256 hex of the exact file bytes) is the optimistic-lock
  token: `get/1` hands it out, `approve/2` and `reject/2` re-read the file
  and re-hash it immediately before deciding, so a caller acting on a stale
  view of the item (edited or already claimed since they fetched it) gets
  `{:error, :queue_item_changed}` instead of silently clobbering a concurrent
  decision.

  Execution itself (the draft write) happens strictly BETWEEN two audited
  steps — `approval_intent` before, `action_executed` after — and is
  idempotent (skips the write if the draft file already exists), so a crash
  between claim and completion is always safe to replay: `recover/1` finds
  the item still sitting in `processing/` and decides from the draft. Draft
  exists — a crashed APPROVE whose execute finished; finish it, INCLUDING the
  step-6 v2 upgrade the crash may have skipped, so a recovered approval never
  lands without its `mailbox_ops`. Draft absent — a crashed approve
  pre-execute OR a crashed reject pre-terminal-rename; both are unobservable
  outside the queue, so the item is handed back to `pending/` for the human
  to re-decide (a re-pended reject simply gets decided again — acceptable, as
  no side effect ever happened). `recover/1` also still sweeps the LEGACY
  reject crash window (rejected/ and pending/ both present, from the old
  write-then-remove reject flow): rejected wins, the pending duplicate is
  dropped.

  On approve completion and reject completion (even when the seeded ops are
  all `"skipped"`), a `{:mailbox_ops_pending, run_id}` message is broadcast on
  the `"mail_ops"` PubSub topic; `update_mailbox_op/3` broadcasts
  `{:mailbox_ops_updated, run_id}` on the same topic after recording an op's
  outcome.

  `approval_intent` is written with `Valea.Audit.append_sync/2` (a
  synchronous call) rather than the fire-and-forget `append/2` cast used
  elsewhere: the intent must be durably on disk BEFORE the draft write, so a
  crash in the window between claim and execute always leaves a readable
  trail explaining the orphaned `processing/` item. `action_executed` and
  `item_approved` stay on the async cast — their relative order is already
  guaranteed by same-sender-to-same-process FIFO.
  """

  alias Valea.Workspace.Manager

  @type revision :: String.t()

  @doc """
  Pending items, newest first (run ids are lexically sortable timestamps).
  Invalid files (bad JSON or a JSON value that fails the `queue_item/v1`
  shape check) are listed with `valid: false` and an `error` reason instead
  of being skipped or crashing the call.
  """
  @spec list() :: {:ok, [map()]} | {:error, :no_workspace}
  def list do
    with {:ok, workspace} <- workspace_root() do
      entries =
        workspace
        |> pending_dir()
        |> Path.join("*.json")
        |> Path.wildcard()
        |> Enum.map(&list_entry/1)
        |> Enum.sort_by(& &1.run_id, :desc)

      {:ok, entries}
    end
  end

  @doc """
  Fetches the pending item's full envelope plus its current revision (sha256
  hex of the raw file bytes). `revision` is only ever meaningful for the
  exact bytes it was computed from — pass it straight to `approve/2` or
  `reject/2`.
  """
  @spec get(String.t()) ::
          {:ok, %{item: map(), revision: revision()}}
          | {:error, :queue_item_gone | :queue_item_invalid}
  def get(run_id) do
    with {:ok, workspace} <- resolve(run_id),
         {:ok, bytes} <- read_pending(workspace, run_id) do
      case decode_envelope(bytes) do
        {:ok, item} -> {:ok, %{item: item, revision: sha256(bytes)}}
        {:error, _reason} -> {:error, :queue_item_invalid}
      end
    end
  end

  @doc """
  Approves `run_id`, EXACTLY in this order:

    1. re-read the pending file's bytes and re-hash — mismatch against
       `revision` returns `{:error, :queue_item_changed}` and touches
       nothing;
    2. atomic claim: `File.rename/2` `pending/<run_id>.json` ->
       `processing/<run_id>.json` (already moved/gone -> `:queue_item_gone`);
    3. audit `approval_intent`, SYNCHRONOUSLY (flushed to disk before step 4
       runs — see moduledoc);
    4. idempotent execute: write `sources/mail/drafts/<run_id>.md` UNLESS it
       already exists (a replay after a crash between steps 3 and 5 must not
       re-send/re-write);
    5. audit `action_executed`;
    6. upgrade-then-rename: atomically rewrite the CLAIMED `processing/` file
       to the `queue_item/v2` envelope (schema bumped, plus a `mailbox_ops`
       map seeding the post-approval mailbox intents — `draft_append` +
       `archive_source`, each `"pending"` or, for a seed-source item, a
       missing/unreadable source message, `"skipped"`), then `File.rename/2`
       `processing/` -> `approved/`. The rewrite is a single-writer
       tmp+rename over the processing path — safe because the item is already
       claimed;
    7. audit `item_approved`, then broadcast `{:mailbox_ops_pending, run_id}`
       on the `"mail_ops"` PubSub topic (fired even when both ops are
       `"skipped"` — the mailbox consumer no-ops).
  """
  @spec approve(String.t(), revision()) ::
          {:ok, %{draft_path: String.t()}}
          | {:error, :queue_item_gone | :queue_item_changed | :queue_item_invalid}
  def approve(run_id, revision) do
    with {:ok, workspace} <- resolve(run_id),
         {:ok, bytes} <- read_pending(workspace, run_id),
         :ok <- check_revision(bytes, revision),
         {:ok, item} <- decode_for_execute(bytes),
         :ok <- claim(workspace, run_id) do
      audit_sync("approval_intent", %{"run_id" => run_id})
      ensure_draft(workspace, run_id, item)
      audit("action_executed", %{"run_id" => run_id})
      complete_approval(workspace, run_id, item)
      audit("item_approved", %{"run_id" => run_id})
      broadcast_ops(run_id)
      {:ok, %{draft_path: draft_rel_path(run_id)}}
    end
  end

  @doc """
  Rejects `run_id` with the same claim discipline as `approve/2`:

    1. re-read the pending file's bytes and re-hash — mismatch against
       `revision` returns `{:error, :queue_item_changed}` and touches
       nothing;
    2. atomic claim: `File.rename/2` `pending/<run_id>.json` ->
       `processing/<run_id>.json` (already moved/gone ->
       `:queue_item_gone`) — this is what makes a concurrent `approve/2`
       and `reject/2` of the same item mutually exclusive;
    3. atomically rewrite the claimed file to the `queue_item/v2` envelope
       carrying ONLY an `archive_source` mailbox-op intent (same seed rule
       as approve — `"skipped"` for a seed-source or missing/unreadable
       source message, else `"pending"`);
    4. `File.rename!` `processing/` -> `rejected/`;
    5. audit `item_rejected`, broadcast `{:mailbox_ops_pending, run_id}` on
       `"mail_ops"` (the consumer no-ops when the sole op is skipped).

  A crash before step 4 leaves the item in `processing/` with no draft;
  `recover/1` hands it back to `pending/` for the human to re-decide.
  """
  @spec reject(String.t(), revision()) ::
          {:ok, %{}}
          | {:error, :queue_item_gone | :queue_item_changed | :queue_item_invalid}
  def reject(run_id, revision) do
    with {:ok, workspace} <- resolve(run_id),
         {:ok, bytes} <- read_pending(workspace, run_id),
         :ok <- check_revision(bytes, revision),
         {:ok, item} <- decode_for_execute(bytes),
         :ok <- claim(workspace, run_id) do
      complete_rejection(workspace, run_id, item)
      audit("item_rejected", %{"run_id" => run_id})
      broadcast_ops(run_id)
      {:ok, %{}}
    end
  end

  @doc """
  Crash recovery: for every file still sitting in `queue/processing/`
  (meaning the process died between the claiming rename and the terminal
  rename — approve OR reject), decide its fate from whether the draft was
  already written:

    * draft exists -> a crashed approve whose execute step finished, only
      completion didn't — finish it (stamp the step-6 `queue_item/v2` +
      `mailbox_ops` upgrade if the crash skipped it, rename to `approved/`,
      audit `item_approved` with `recovered: true`, broadcast
      `{:mailbox_ops_pending, run_id}`);
    * draft absent -> a crashed approve pre-execute or a crashed reject
      pre-terminal-rename — nothing observable happened, so hand it back to
      `pending/` (audit `approval_recovered`) for a human to approve/reject
      again.

  Additionally sweeps the LEGACY reject crash window — a `rejected/` file
  whose run_id still has a `pending/` sibling, left by the old
  write-rejected-then-remove-pending flow — by dropping the pending duplicate
  (audit `reject_recovered`). The claim-based reject cannot produce that
  window anymore.

  `workspace` is the plain root path (NOT a `%{path: ...}` map): this runs
  from `Valea.Workspace.Runtime` startup, before `Valea.Workspace.Manager`
  has committed the new workspace as current.
  """
  @spec recover(String.t()) :: :ok
  def recover(workspace) do
    workspace
    |> processing_dir()
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.each(&recover_one(workspace, &1))

    workspace
    |> rejected_dir()
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.each(&recover_rejected(workspace, &1))

    :ok
  end

  @doc """
  Decided items — everything in `approved/` and `rejected/` — newest first
  (run ids are lexically sortable timestamps). Each entry carries `run_id`,
  `decided` (`"approved"` | `"rejected"`), `title`, `kind`, the raw
  `mailbox_ops` map (or `nil`), and `created_at`. Files that are unreadable or
  no longer valid JSON are skipped (decided envelopes are written by this
  module's own atomic writes, so this is defensive only).
  """
  @spec list_decided() :: {:ok, [map()]} | {:error, :no_workspace}
  def list_decided do
    with {:ok, workspace} <- workspace_root() do
      entries =
        (decided_entries(approved_dir(workspace), "approved") ++
           decided_entries(rejected_dir(workspace), "rejected"))
        |> Enum.sort_by(& &1.run_id, :desc)

      {:ok, entries}
    end
  end

  @doc """
  Fetches a decided item's raw envelope plus which terminal directory it lives
  in (`"approved"` | `"rejected"`). `{:error, :queue_item_gone}` when `run_id`
  is in neither.
  """
  @spec get_decided(String.t()) ::
          {:ok, %{item: map(), decided: String.t()}} | {:error, :queue_item_gone}
  def get_decided(run_id) do
    with {:ok, workspace} <- resolve(run_id),
         {:ok, path, decided} <- decided_file(workspace, run_id),
         {:ok, bytes} <- File.read(path),
         {:ok, %{} = item} <- Jason.decode(bytes) do
      {:ok, %{item: item, decided: decided}}
    else
      _ -> {:error, :queue_item_gone}
    end
  end

  @doc """
  Records the outcome of a single mailbox op on an already-decided envelope:
  finds `run_id` in `approved/` or `rejected/`, sets
  `mailbox_ops[op_name] = status_map` (`status_map` is a map like
  `%{"status" => "done"}`, optionally with extra keys such as `"error"`),
  atomically rewrites the file in place, and broadcasts
  `{:mailbox_ops_updated, run_id}` on `"mail_ops"`. The mailbox consumer (T11)
  is the sole caller.
  """
  @spec update_mailbox_op(String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, :queue_item_gone}
  def update_mailbox_op(run_id, op_name, status_map) do
    with {:ok, workspace} <- resolve(run_id),
         {:ok, path, _decided} <- decided_file(workspace, run_id),
         {:ok, bytes} <- File.read(path),
         {:ok, %{} = item} <- Jason.decode(bytes) do
      ops = Map.get(item, "mailbox_ops") || %{}
      updated = Map.put(item, "mailbox_ops", Map.put(ops, op_name, status_map))
      atomic_write!(path, Jason.encode!(updated))
      broadcast({:mailbox_ops_updated, run_id})
      {:ok, updated}
    else
      _ -> {:error, :queue_item_gone}
    end
  end

  ## resolution + validation

  defp resolve(run_id) do
    with true <- valid_run_id?(run_id),
         {:ok, workspace} <- workspace_root() do
      {:ok, workspace}
    else
      false -> {:error, :queue_item_gone}
      {:error, _} = err -> err
    end
  end

  defp workspace_root do
    case Manager.current() do
      {:ok, %{path: root}} -> {:ok, root}
      {:error, :no_workspace} -> {:error, :no_workspace}
    end
  end

  # A safe basename: run ids come straight from filenames, so before any
  # path is built from one it must contain no separator or traversal
  # sequence.
  defp valid_run_id?(run_id) when is_binary(run_id) do
    run_id != "" and not String.contains?(run_id, "/") and not String.contains?(run_id, "..")
  end

  defp valid_run_id?(_run_id), do: false

  ## list/1 helpers

  defp list_entry(path) do
    run_id = Path.basename(path, ".json")

    case File.read(path) do
      {:error, reason} ->
        invalid_entry(run_id, reason)

      {:ok, bytes} ->
        case decode_envelope(bytes) do
          {:ok, item} -> summary(run_id, item)
          {:error, reason} -> invalid_entry(run_id, reason)
        end
    end
  end

  defp summary(run_id, item) do
    %{
      run_id: run_id,
      title: item["payload"]["title"],
      summary: item["payload"]["summary"],
      kind: item["payload"]["kind"],
      risk_level: item["risk_level"],
      created_at: item["created_at"],
      workflow: item["workflow"],
      valid: true
    }
  end

  defp invalid_entry(run_id, reason) do
    %{
      run_id: run_id,
      title: nil,
      summary: nil,
      kind: nil,
      risk_level: nil,
      created_at: nil,
      workflow: nil,
      valid: false,
      error: to_string(reason)
    }
  end

  ## get/1 + envelope validation (mirrors Runner's proposal/v1 checks, one
  ## level up: the whole queue_item/v1 envelope)

  defp read_pending(workspace, run_id) do
    case File.read(pending_path(workspace, run_id)) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, _reason} -> {:error, :queue_item_gone}
    end
  end

  defp decode_for_execute(bytes) do
    case decode_envelope(bytes) do
      {:ok, item} -> {:ok, item}
      {:error, _reason} -> {:error, :queue_item_invalid}
    end
  end

  defp decode_envelope(bytes) do
    case Jason.decode(bytes) do
      {:ok, %{} = item} ->
        if valid_envelope?(item), do: {:ok, item}, else: {:error, :invalid_schema}

      {:ok, _not_a_map} ->
        {:error, :invalid_schema}

      {:error, _reason} ->
        {:error, :invalid_json}
    end
  end

  defp valid_envelope?(item) do
    item["schema"] in ["queue_item/v1", "queue_item/v2"] and
      nonempty_string?(item["run_id"]) and
      nonempty_string?(item["workflow"]) and
      nonempty_string?(item["risk_level"]) and
      nonempty_string?(item["created_at"]) and
      valid_payload?(item["payload"]) and
      valid_mailbox_ops?(item["mailbox_ops"])
  end

  # `source_message` is intentionally NOT required: a v2 envelope from an old
  # run may lack it (approve/reject then treat it as unreadable -> skipped).
  # `mailbox_ops`, if present at all, must be a map.
  defp valid_mailbox_ops?(nil), do: true
  defp valid_mailbox_ops?(ops) when is_map(ops), do: true
  defp valid_mailbox_ops?(_ops), do: false

  defp valid_payload?(%{} = payload) do
    nonempty_string?(payload["title"]) and
      nonempty_string?(payload["summary"]) and
      nonempty_string?(payload["kind"]) and
      list_of_strings?(payload["sources"]) and
      valid_action?(payload["proposed_action"])
  end

  defp valid_payload?(_payload), do: false

  defp valid_action?(%{
         "type" => "create_email_draft",
         "to" => to,
         "subject" => subject,
         "body_markdown" => body
       })
       when is_binary(to) and is_binary(subject) and is_binary(body),
       do: no_control_chars?(to) and no_control_chars?(subject)

  defp valid_action?(_action), do: false

  # `to`/`subject` are interpolated straight into the draft's YAML frontmatter
  # (`draft_markdown/2`). A control char — newline, CR, or any other C0/DEL —
  # would let a hand-written or agent-authored queue item inject arbitrary
  # frontmatter keys (e.g. a second `to:`), diverging the executed draft from
  # what the human approved. Reject at the envelope boundary so `get/approve`
  # surface `:queue_item_invalid` rather than executing a malformed draft.
  defp no_control_chars?(s) do
    not Enum.any?(String.to_charlist(s), &(&1 < 0x20 or &1 == 0x7F))
  end

  defp nonempty_string?(s), do: is_binary(s) and String.trim(s) != ""

  defp list_of_strings?(list) when is_list(list), do: Enum.all?(list, &is_binary/1)
  defp list_of_strings?(_list), do: false

  ## approve/2 + reject/2 helpers

  defp check_revision(bytes, revision) do
    if sha256(bytes) == revision, do: :ok, else: {:error, :queue_item_changed}
  end

  defp claim(workspace, run_id) do
    File.mkdir_p!(processing_dir(workspace))

    case File.rename(pending_path(workspace, run_id), processing_path(workspace, run_id)) do
      :ok -> :ok
      {:error, _reason} -> {:error, :queue_item_gone}
    end
  end

  defp ensure_draft(workspace, run_id, item) do
    path = draft_path(workspace, run_id)

    unless File.exists?(path) do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, draft_markdown(run_id, item))
    end

    :ok
  end

  defp draft_markdown(run_id, item) do
    action = item["payload"]["proposed_action"]
    sources = item["payload"]["sources"] || []

    lines =
      [
        "---",
        "to: #{action["to"]}",
        "subject: #{action["subject"]}",
        "run_id: #{run_id}",
        "workflow: #{item["workflow"]}",
        "sources:"
      ] ++
        Enum.map(sources, &"  - #{&1}") ++
        ["---", "", action["body_markdown"]]

    Enum.join(lines, "\n")
  end

  # Step 6 of approve/2: upgrade the CLAIMED processing file to queue_item/v2
  # (schema + mailbox_ops), atomically rewriting it in place before the final
  # rename to approved/. The item is already claimed, so this is the sole
  # writer of the processing path — the tmp+rename just makes the content swap
  # crash-atomic.
  defp complete_approval(workspace, run_id, item) do
    item2 = upgrade_envelope(workspace, item, ["draft_append", "archive_source"])
    atomic_write!(processing_path(workspace, run_id), Jason.encode!(item2))

    File.mkdir_p!(approved_dir(workspace))
    File.rename!(processing_path(workspace, run_id), approved_path(workspace, run_id))
  end

  # reject/2 steps 3-4: same upgrade-then-rename shape as complete_approval,
  # but with only the archive_source intent and rejected/ as the terminal
  # directory. Operates on the ALREADY-CLAIMED processing file (single
  # writer). A crash before the final rename leaves the item in processing/
  # with no draft — recover_one/2 hands it back to pending/.
  defp complete_rejection(workspace, run_id, item) do
    item2 = upgrade_envelope(workspace, item, ["archive_source"])
    atomic_write!(processing_path(workspace, run_id), Jason.encode!(item2))

    File.mkdir_p!(rejected_dir(workspace))
    File.rename!(processing_path(workspace, run_id), rejected_path(workspace, run_id))
  end

  # v1/v2 -> v2: bump schema and, for an email_draft, stamp the seeded
  # mailbox-op intents. Non-email_draft kinds carry no ops map.
  defp upgrade_envelope(workspace, item, op_names) do
    item
    |> Map.put("schema", "queue_item/v2")
    |> maybe_put_mailbox_ops(workspace, item, op_names)
  end

  defp maybe_put_mailbox_ops(item2, workspace, item, op_names) do
    if item["payload"]["kind"] == "email_draft" do
      Map.put(item2, "mailbox_ops", mailbox_ops_for(workspace, item, op_names))
    else
      item2
    end
  end

  # Mailbox-op seeding rule (per-op, allowlist not denylist): an op is
  # "pending" ONLY for a genuine inbound mail message — `source: imap` in the
  # source file's frontmatter — and `archive_source` additionally requires a
  # `uid` to move by. Everything else is "skipped": seed data, an ICM/other
  # non-mail workflow that merely emitted a kind:"email_draft", and any
  # absent/unreadable source. This keeps a non-mail draft from being APPENDed
  # to the real Drafts folder, and keeps a uid-less source from parking
  # archive_source in a permanent :source_has_no_uid failure.
  defp mailbox_ops_for(workspace, item, op_names) do
    info = source_op_info(workspace, item["source_message"])
    Map.new(op_names, fn name -> {name, %{"status" => op_status(name, info)}} end)
  end

  defp op_status("archive_source", %{imap?: true, uid?: true}), do: "pending"
  defp op_status("archive_source", _info), do: "skipped"
  defp op_status(_name, %{imap?: true}), do: "pending"
  defp op_status(_name, _info), do: "skipped"

  defp source_op_info(workspace, source_message) do
    case read_source_message(workspace, source_message) do
      {:ok, content} ->
        fm = frontmatter_map(content)
        %{imap?: Map.get(fm, "source") == "imap", uid?: present_value?(fm["uid"])}

      :error ->
        %{imap?: false, uid?: false}
    end
  end

  # Shallow parse of the leading `---`-delimited frontmatter block into a
  # key => unquoted-scalar map (first occurrence wins) — enough to read
  # `source:` and `uid:`. Containment/traversal is already enforced by
  # `read_source_message/2` before we get here.
  defp frontmatter_map(content) do
    content
    |> frontmatter_lines()
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, ":", parts: 2) do
        [key, value] -> Map.put_new(acc, String.trim(key), unquote_value(value))
        _ -> acc
      end
    end)
  end

  defp present_value?(value), do: is_binary(value) and String.trim(value) != ""

  # Containment-gated like Runner's input read: `resolve_real/2` rejects any
  # `..`/symlink traversal escaping the workspace, so an agent-authored
  # source_message can never point the seed decision at a file the workspace
  # does not own. Unresolvable, outside, and unreadable all collapse to
  # :error — i.e. "skipped".
  defp read_source_message(workspace, source_message) when is_binary(source_message) do
    with {:ok, real} <- Valea.Paths.resolve_real(source_message, workspace),
         {:ok, content} <- File.read(real) do
      {:ok, content}
    else
      _ -> :error
    end
  end

  defp read_source_message(_workspace, _source_message), do: :error

  defp frontmatter_lines(content) do
    case String.split(content, "\n") do
      [first | rest] ->
        if String.trim(first) == "---" do
          Enum.take_while(rest, fn line -> String.trim(line) != "---" end)
        else
          []
        end

      [] ->
        []
    end
  end

  defp unquote_value(value) do
    value |> String.trim() |> String.trim("\"") |> String.trim("'")
  end

  ## recover/1 helpers

  defp recover_one(workspace, path) do
    run_id = Path.basename(path, ".json")

    if File.exists?(draft_path(workspace, run_id)) do
      finish_recovered_approval(workspace, path, run_id)
    else
      # Draft absent: a crashed approve that executed nothing observable, or
      # a crashed reject that never reached its terminal rename. Either way
      # the human re-decides.
      File.mkdir_p!(pending_dir(workspace))
      File.rename!(path, pending_path(workspace, run_id))
      audit("approval_recovered", %{"run_id" => run_id})
    end
  end

  # The draft exists, so approve's execute step finished — but the crash may
  # have hit BEFORE step 6's v2 upgrade, and a bare rename would land an
  # approved/ envelope with NO mailbox_ops (the mailbox pass and the UI retry
  # both key off that map, so the ops would be silently dropped forever).
  # Stamp the upgrade exactly as complete_approval does; re-stamping an
  # already-upgraded file is idempotent (same seed rule, same source, and no
  # op outcome can exist yet — update_mailbox_op only touches terminal dirs).
  # An unreadable/corrupt processing file falls back to the bare rename: the
  # item reaching its terminal state still beats a perfect envelope.
  defp finish_recovered_approval(workspace, path, run_id) do
    with {:ok, bytes} <- File.read(path),
         {:ok, %{} = item} <- Jason.decode(bytes) do
      item2 = upgrade_envelope(workspace, item, ["draft_append", "archive_source"])
      atomic_write!(path, Jason.encode!(item2))
    end

    File.mkdir_p!(approved_dir(workspace))
    File.rename!(path, approved_path(workspace, run_id))
    audit("item_approved", %{"run_id" => run_id, "recovered" => true})
    broadcast_ops(run_id)
  end

  # LEGACY defensive sweep: the original reject flow wrote rejected/ first
  # and removed pending/ second, so a crash in between left both. The
  # claim-based reject/2 above can no longer produce this window (pending is
  # renamed away before rejected/ is ever written), but a workspace last
  # touched by the old flow may still carry the pair — rejected is the
  # durable decision, so it wins and the pending duplicate is dropped.
  defp recover_rejected(workspace, path) do
    run_id = Path.basename(path, ".json")
    pending = pending_path(workspace, run_id)

    if File.exists?(pending) do
      File.rm!(pending)
      audit("reject_recovered", %{"run_id" => run_id})
    end
  end

  ## list_decided/0 + get_decided/1 + update_mailbox_op/3 helpers

  defp decided_entries(dir, decided) do
    dir
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.flat_map(&decided_entry(&1, decided))
  end

  defp decided_entry(path, decided) do
    run_id = Path.basename(path, ".json")

    with {:ok, bytes} <- File.read(path),
         {:ok, %{} = item} <- Jason.decode(bytes) do
      [
        %{
          run_id: run_id,
          decided: decided,
          title: item["payload"]["title"],
          kind: item["payload"]["kind"],
          mailbox_ops: item["mailbox_ops"],
          created_at: item["created_at"]
        }
      ]
    else
      _ -> []
    end
  end

  defp decided_file(workspace, run_id) do
    approved = approved_path(workspace, run_id)
    rejected = rejected_path(workspace, run_id)

    cond do
      File.exists?(approved) -> {:ok, approved, "approved"}
      File.exists?(rejected) -> {:ok, rejected, "rejected"}
      true -> {:error, :queue_item_gone}
    end
  end

  ## paths

  defp pending_dir(ws), do: Path.join([ws, "queue", "pending"])
  defp processing_dir(ws), do: Path.join([ws, "queue", "processing"])
  defp approved_dir(ws), do: Path.join([ws, "queue", "approved"])
  defp rejected_dir(ws), do: Path.join([ws, "queue", "rejected"])
  defp drafts_dir(ws), do: Path.join([ws, "sources", "mail", "drafts"])

  defp pending_path(ws, run_id), do: Path.join(pending_dir(ws), run_id <> ".json")
  defp processing_path(ws, run_id), do: Path.join(processing_dir(ws), run_id <> ".json")
  defp approved_path(ws, run_id), do: Path.join(approved_dir(ws), run_id <> ".json")
  defp rejected_path(ws, run_id), do: Path.join(rejected_dir(ws), run_id <> ".json")
  defp draft_path(ws, run_id), do: Path.join(drafts_dir(ws), run_id <> ".md")
  defp draft_rel_path(run_id), do: Path.join(["sources", "mail", "drafts", run_id <> ".md"])

  ## misc

  defp atomic_write!(abs, bytes) do
    tmp = abs <> ".tmp"
    File.write!(tmp, bytes)
    File.rename!(tmp, abs)
  end

  defp broadcast_ops(run_id), do: broadcast({:mailbox_ops_pending, run_id})

  defp broadcast(message) do
    Phoenix.PubSub.broadcast(Valea.PubSub, "mail_ops", message)
    :ok
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp audit(type, fields) do
    if Process.whereis(Valea.Audit), do: Valea.Audit.append(type, fields)
    :ok
  end

  # Synchronous variant for entries that must be durably on disk before the
  # caller proceeds (approval_intent, ahead of the draft write — see
  # moduledoc). Same "never crash callers" contract as audit/2: if the Audit
  # process isn't up, this is a no-op.
  defp audit_sync(type, fields) do
    if Process.whereis(Valea.Audit), do: Valea.Audit.append_sync(type, fields)
    :ok
  end
end
