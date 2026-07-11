defmodule Valea.Mail.Index do
  @moduledoc """
  Rebuilds `Valea.Mail.Store`'s `mail_messages` cache from the canonical
  on-disk files under `sources/mail/messages/` — the reconstruction path
  every `Valea.Mail.Store` table must have (pure cache, files are
  canonical). An unparseable file is skipped (logged), not fatal: a single
  corrupt message must never abort indexing the rest of the mailbox.
  """
  require Logger

  alias Valea.Mail.MessageFile
  alias Valea.Mail.Store

  @doc "Globs `<root>/sources/mail/messages/*.md`, parses + upserts each. Returns the count indexed."
  @spec rebuild(String.t()) :: {:ok, non_neg_integer()}
  def rebuild(root) do
    count =
      root
      |> Path.join("sources/mail/messages/*.md")
      |> Path.wildcard()
      |> Enum.count(&index_file(root, &1))

    {:ok, count}
  end

  defp index_file(root, path) do
    with {:ok, bytes} <- File.read(path),
         {:ok, %{frontmatter: frontmatter}} <- MessageFile.parse(bytes) do
      Store.upsert_message(%{
        msg_id: frontmatter["id"],
        message_id: frontmatter["message_id"],
        path: Path.relative_to(path, root),
        from: frontmatter["from"] || %{},
        subject: frontmatter["subject"],
        date: frontmatter["date"],
        status: frontmatter["status"],
        has_attachments: (frontmatter["attachments"] || []) != [],
        uid: frontmatter["uid"]
      })

      true
    else
      {:error, reason} ->
        Logger.warning(
          "Valea.Mail.Index: skipping unparseable message file #{path}: #{inspect(reason)}"
        )

        false
    end
  end
end
