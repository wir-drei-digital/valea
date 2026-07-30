defmodule Valea.ICM.Briefing do
  @moduledoc """
  Materializes the Valea-owned tasks+schedules contract at an ICM root —
  `.valea/briefing.md`, copied from `priv/icm_briefing_template/briefing.md`
  (tasks+schedules spec §"Materialized briefing").

  `Valea.Mail.AgentsFile` is the pattern, one simplification apart: there is
  nothing to interpolate. The briefing describes the grammar Valea enforces,
  not this particular ICM, so the template ships as the literal file contents
  and every ICM gets byte-identical bytes.

  Runs on every workspace activation and mount-enable (the scheduler's
  per-mount first pass), so the contract an agent reads always matches the app
  version that is enforcing it. Idempotent: unchanged content is a no-op — no
  write, no mtime churn, nothing for the ICM watcher to broadcast. Anything
  else — an older app's render, a hand edit, even a symlink planted where the
  briefing should be — is replaced via tmp + `File.rename!/2`, which swaps the
  directory entry itself and so can never write *through* a planted link.

  The file is engine-owned in the strong sense: `PermissionPolicy` and the
  managed-settings mirror both **deny** agent writes anywhere under `.valea/`
  (reads stay ordinary — the briefing exists to be read), which is what makes
  regenerating it safe. Users can of course edit it by hand; the next
  activation puts it back.
  """

  @template "icm_briefing_template/briefing.md"

  @doc "The briefing's path for an ICM root."
  @spec path(String.t()) :: String.t()
  def path(icm_root) when is_binary(icm_root),
    do: Path.join([icm_root, ".valea", "briefing.md"])

  @doc "The shipped template's path — the source of truth for the bytes on disk."
  @spec template_path() :: String.t()
  def template_path, do: Path.join(:code.priv_dir(:valea), @template)

  @doc """
  Writes the briefing at `icm_root` unless it is already byte-identical.

  Raises on I/O failure (a `.valea` that is a regular file, an unwritable
  root): a caller that must not be interrupted by this — the scheduler's tick —
  handles that itself rather than having the failure swallowed here.
  """
  @spec materialize!(String.t()) :: :ok
  def materialize!(icm_root) when is_binary(icm_root) do
    target = path(icm_root)
    rendered = File.read!(template_path())

    unless File.read(target) == {:ok, rendered} do
      write_via_rename!(target, rendered)
    end

    :ok
  end

  # tmp + rename: atomic under concurrent readers, and it replaces the
  # directory entry rather than writing through an existing symlink.
  defp write_via_rename!(path, data) do
    File.mkdir_p!(Path.dirname(path))
    tmp = path <> ".tmp"
    File.write!(tmp, data)
    File.rename!(tmp, path)
  end
end
