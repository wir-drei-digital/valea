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

  # No single file may abort the rebuild. Three defenses, all counting the
  # file as skipped (`false`):
  #
  #   * an unparseable file (bad/absent frontmatter) — logged, as before;
  #   * a parseable file with a nil/blank `id` — `msg_id` is required by the
  #     Store's Ash create, so without this guard the create RAISES and the
  #     old `with/else` (which only matched error tuples) let it escape,
  #     crashing Engine activation for the whole session;
  #   * any other raise (a Store/validation failure on some other field) —
  #     caught by the surrounding `rescue`/`catch` so a lone bad row can never
  #     take down the rest of the mailbox.
  defp index_file(root, path) do
    with {:ok, bytes} <- File.read(path),
         {:ok, %{frontmatter: frontmatter}} <- MessageFile.parse(bytes),
         msg_id when is_binary(msg_id) <- present_id(frontmatter["id"]) do
      Store.upsert_message(%{
        msg_id: msg_id,
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

      nil ->
        Logger.warning("Valea.Mail.Index: skipping message file #{path}: missing frontmatter id")
        false
    end
  rescue
    e ->
      Logger.warning("Valea.Mail.Index: skipping message file #{path}: #{Exception.message(e)}")

      false
  catch
    kind, reason ->
      Logger.warning(
        "Valea.Mail.Index: skipping message file #{path}: #{inspect({kind, reason})}"
      )

      false
  end

  defp present_id(id) when is_binary(id) do
    if String.trim(id) == "", do: nil, else: id
  end

  defp present_id(_id), do: nil
end
