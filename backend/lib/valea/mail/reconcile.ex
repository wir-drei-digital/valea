defmodule Valea.Mail.Reconcile do
  @moduledoc """
  UIDVALIDITY-reset and folder-lifecycle reconciliation for the pull engine
  (mail-as-maildir design spec, §Pull — `UIDVALIDITY` reset / §Folder
  lifecycle — hold, don't guess).

  ## Task-7 status: mostly a SAFE STUB

  `Valea.Mail.SyncPass` (Task 7) detects a per-folder `UIDVALIDITY` change and
  an account-wide replacement itself, but the *recovery* — the complete,
  horizon-independent re-pull that re-binds already-landed occurrences to
  their new `(uidvalidity, uid)` before removing anything — is Task 8's job.
  Until then:

    * `folder_reset/2` returns `{:error, :not_implemented}`. `SyncPass` treats
      that as **"remove nothing, emit a notice, retry next pass"** — the folder
      keeps every local occurrence and its old watermark, and the reset is
      re-detected (and re-deferred) every pass until Task 8 lands the real
      reconciliation. This is the fail-safe posture the spec demands: server-
      authoritative deletion never fires off a *guess*.
    * `folder_lifecycle/2` returns `{:ok, []}` — no folder is ever held yet
      (Task 8 wires the held-folder protocol).
    * `discard_held!/3` returns `{:error, :not_held}` — there are no held
      folders to discard yet.

  `detect_replacement/2` is implemented **for real** here (it's a pure
  decision `SyncPass` needs this task, before any mutation): a whole-mailbox
  replacement — INBOX itself re-provisioned, or a majority of the mirrored
  set re-`UIDVALIDITY`'d in a single pass — is not an ordinary per-folder
  reset to reconcile occurrence-by-occurrence but a different account behind
  the same settings, which `SyncPass` must refuse (`{:error,
  :mailbox_replaced}`) rather than silently re-pull over the top of the old
  one's local data.
  """

  @typedoc "The per-pass reconciliation context `SyncPass` threads in (root, account, transport, conn, select_info)."
  @type ctx :: map()

  @doc """
  TASK-8 STUB. The real single-folder `UIDVALIDITY`-reset reconciliation
  (snapshot pre-reset occurrences → full enumeration → Message-ID/fingerprint
  re-bind → remove only the genuinely-vanished → re-init watermark). Returns
  `{:error, :not_implemented}` for now; `SyncPass` maps that to a deferral
  notice and leaves the folder's local data and watermark untouched.
  """
  @spec folder_reset(ctx(), String.t()) :: {:ok, map()} | {:error, term()}
  def folder_reset(_ctx, _folder), do: {:error, :not_implemented}

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

  @doc """
  TASK-8 STUB. Given the successfully-`LIST`ed mirrored folder set, returns
  the folders that should become **held** (previously mirrored, now absent —
  deleted, renamed, or newly excluded). `{:ok, []}` for now: no folder is
  ever held until Task 8 wires the hold protocol.
  """
  @spec folder_lifecycle(ctx(), [String.t()]) :: {:ok, [String.t()]}
  def folder_lifecycle(_ctx, _listed), do: {:ok, []}

  @doc """
  TASK-8 STUB. Discards a held folder's local data on the user's typed
  confirmation. `{:error, :not_held}` for now — there are no held folders yet.
  """
  @spec discard_held!(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def discard_held!(_root, _account, _folder), do: {:error, :not_held}
end
