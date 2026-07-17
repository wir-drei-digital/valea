defmodule Valea.Mail.SyncPass do
  @moduledoc """
  GUTTED in Task 6 (mail-as-maildir rebuild) — rewritten wholesale in Task 7
  around the new `Valea.Mail.Views`/`Valea.Mail.Index` cache-only APIs and
  the maildir tree (mail-as-maildir design spec, §Sync engine —
  declared-ops two-way). This module's previous body (Review-folder
  landing via the now-deleted single-flat-file
  `MessageFile.render(message, %{uid:, status:, source:, ...})` meta
  shape, INBOX awareness-index generation, per-UID `Store.record_outcome/
  outcomes`) does not survive `Task 6`'s `MessageFile`/`Store` changes —
  `flip_status/2` is gone, `render/2`'s meta no longer carries `uid`/
  `status`/`source`, and `mail_uid_outcomes`/`mail_inbox_headers` are
  slated for deletion once this module stops using them (Task 7's own
  moduledoc / the `UidOutcome`/`InboxHeader` resources' moduledocs).
  Rewriting all of that around the new maildir/views/occurrence model is
  squarely Task 7's job, not an "adapt the meta shape" patch — so, per the
  Task 6 brief, this module is a temporary no-op stub instead of faking
  the old semantics against the new file format.

  `run/1` keeps only the piece every current caller (`Valea.Mail.Engine`'s
  `start_pass/1`, and the Engine's own test suite) still depends on
  structurally: it actually calls `transport.connect/3` and passes through
  `{:error, :auth_failed}` / any other connect error verbatim (the
  Engine's `auth_failed`-pauses-polling and credential-redaction behavior
  is exercised against exactly this contract). On a successful connect it
  logs out and reports a no-op pass — no folder is walked, nothing lands,
  nothing is deduped. `Engine.sync_now/0` therefore still works
  end-to-end (connect, auth-failure handling, single-flight, status
  transitions) with zero real mail sync until Task 7 lands.
  """

  @type args :: %{
          root: String.t(),
          settings: Valea.Mail.Settings.t(),
          credential: (-> String.t()) | String.t(),
          transport: module()
        }

  @doc """
  Connects, immediately logs back out, and returns a no-op pass result —
  see the moduledoc for why this is gutted rather than adapted. Preserves
  the real `{:error, :auth_failed}` / `{:error, term()}` connect-failure
  contract verbatim.
  """
  @spec run(args()) ::
          {:ok, %{new_messages: non_neg_integer(), errors: [String.t()]}}
          | {:error, :auth_failed}
          | {:error, term()}
  def run(%{settings: settings, credential: credential, transport: transport}) do
    case transport.connect(settings.imap, resolve_credential(credential), []) do
      {:ok, conn} ->
        safe_logout(transport, conn)
        {:ok, %{new_messages: 0, errors: []}}

      {:error, :auth_failed} ->
        {:error, :auth_failed}

      {:error, reason} ->
        {:error, reason}
    end
  end

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
