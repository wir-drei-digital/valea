defmodule Valea.Mail.AgentsFile do
  @moduledoc """
  Materializes the engine-owned agent briefing at a mail account root —
  `sources/mail/<slug>/AGENTS.md` (rendered from `priv/mail_template/`,
  `{{account}}` → slug) plus `CLAUDE.md` as a relative symlink to it
  (fallback: the template's one-line `@AGENTS.md` import file, mirroring
  `Valea.Mounts`' `link_claude_md!/1` for platforms without symlinks).

  Runs on every successful Engine activation, so the briefing always
  matches the app version that is enforcing the grammar it describes.
  Idempotent: an unchanged render is a no-op (no mtime churn); anything
  else — stale content from an older app, a hand edit, even a symlinked
  `AGENTS.md` — is replaced via tmp + `File.rename!/2`, which swaps the
  directory entry itself and can never write through a planted link.
  Like `.account`, these files are engine-owned: the settings mirror and
  `PermissionPolicy` keep them readable but never agent-writable.
  """

  def template_dir, do: Path.join(:code.priv_dir(:valea), "mail_template")

  @spec agents_path(String.t(), String.t()) :: String.t()
  def agents_path(root, slug), do: Path.join([root, "sources", "mail", slug, "AGENTS.md"])

  @spec materialize!(String.t(), String.t()) :: :ok
  def materialize!(root, slug) when is_binary(root) and is_binary(slug) do
    agents = agents_path(root, slug)

    rendered =
      template_dir()
      |> Path.join("AGENTS.md")
      |> File.read!()
      |> String.replace("{{account}}", slug)

    unless File.read(agents) == {:ok, rendered} do
      write_via_rename!(agents, rendered)
    end

    link_claude_md!(Path.dirname(agents))
    :ok
  end

  # tmp + rename: atomic under concurrent readers, and replaces the
  # directory entry rather than writing through an existing symlink.
  defp write_via_rename!(path, data) do
    File.mkdir_p!(Path.dirname(path))
    tmp = path <> ".tmp"
    File.write!(tmp, data)
    File.rename!(tmp, path)
  end

  defp link_claude_md!(dir) do
    path = Path.join(dir, "CLAUDE.md")

    case File.read_link(path) do
      {:ok, "AGENTS.md"} ->
        :ok

      _missing_or_regular_or_foreign ->
        File.rm(path)

        case File.ln_s("AGENTS.md", path) do
          :ok -> :ok
          {:error, _reason} -> write_via_rename!(path, "@AGENTS.md\n")
        end
    end
  end
end
