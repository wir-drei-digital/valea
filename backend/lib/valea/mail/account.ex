defmodule Valea.Mail.Account do
  @moduledoc """
  Per-account identity binding (mail-as-maildir design spec E, §Identity
  binding) — a small `sources/mail/<slug>/.account` file recording the
  `host`/`username` a slug's local subtree was first provisioned against,
  plus the one-shot `.readopt` authorization marker `Valea.Mail.Engine`
  consults when unblocking a `mailbox_replaced` sticky state.

  ## `.account`

  A slug's subtree (maildir, views, sync cache) is only ever meaningful for
  ONE server identity. Without a persisted binding, re-pointing a slug's
  `config/mail.yaml` entry at a DIFFERENT mailbox (a typo'd host, or a
  destructive copy-paste) would silently start syncing an unrelated
  account's mail into the old one's local history. `verify/3` catches that
  at activation, before any sync/index work runs; `write_if_absent!/3`
  claims the binding the first time a slug activates with no prior
  `.account` file (a brand-new account, or a purged one).

  `host`/`username` only — not port, not folder names — mirrors the design
  spec's identity scope: those two together are ONE IMAP mailbox, and
  everything else about `Settings.t()` is free to change without implying a
  different account.

  ## `.readopt`

  A fsynced, engine-owned marker file (`sources/mail/<slug>/.readopt`) —
  survives a lost `app.sqlite` the same way the maildir tree itself does,
  so the one-shot authorization a user grants via the `readopt_mail_account`
  RPC can't be silently forgotten by a database wipe between the grant and
  the next sync pass. `Valea.Mail.Engine.readopt/1` writes it; a running
  `Valea.Mail.SyncPass` reads its presence via `readopt_authorized?/2` and
  threads that into `run/1`'s `readopt_authorized:` arg; the engine clears
  it (`clear_readopt!/2`) only once that pass reports success — a failed or
  still-blocked pass leaves the authorization standing for the next attempt.
  """

  @doc "`sources/mail/<slug>/.account`, absolute under `root`."
  @spec account_path(String.t(), String.t()) :: String.t()
  def account_path(root, slug), do: Path.join([root, "sources", "mail", slug, ".account"])

  @doc "`sources/mail/<slug>/.readopt`, absolute under `root`."
  @spec readopt_path(String.t(), String.t()) :: String.t()
  def readopt_path(root, slug), do: Path.join([root, "sources", "mail", slug, ".readopt"])

  @doc """
  Writes `sources/mail/<slug>/.account` (atomic: temp file + rename) with
  `identity`'s `host`/`username` — but ONLY when the file doesn't already
  exist. A no-op `:ok` when it's already present, whatever it currently
  holds: the caller's own `verify/3` call is what decides whether an
  existing file is a match or a mismatch; this function only ever claims an
  unclaimed slug.
  """
  @spec write_if_absent!(String.t(), String.t(), %{host: String.t(), username: String.t()}) ::
          :ok
  def write_if_absent!(root, slug, %{host: host, username: username})
      when is_binary(root) and is_binary(slug) and is_binary(host) and is_binary(username) do
    path = account_path(root, slug)

    if File.exists?(path) do
      :ok
    else
      File.mkdir_p!(Path.dirname(path))
      atomic_write!(path, render(host, username))
      :ok
    end
  end

  @doc """
  Verifies `identity` (`host`/`username`) against the persisted
  `.account` file for `slug`:

    * `:absent` — no `.account` file exists yet (a brand-new, or fully
      purged, slug) — the caller should `write_if_absent!/3` to claim it.
    * `:ok` — the file exists and matches `identity` exactly.
    * `{:error, :identity_mismatch}` — the file exists and records a
      DIFFERENT `host` or `username` than `identity`.

  A file that exists but can't be parsed is treated as a mismatch (never as
  `:absent` — a corrupt file must not silently re-claim the slug for a
  possibly-different identity) and never raises.
  """
  @spec verify(String.t(), String.t(), %{host: String.t(), username: String.t()}) ::
          :ok | {:error, :identity_mismatch} | :absent
  def verify(root, slug, %{host: host, username: username})
      when is_binary(root) and is_binary(slug) and is_binary(host) and is_binary(username) do
    path = account_path(root, slug)

    case File.read(path) do
      {:error, :enoent} ->
        :absent

      {:error, _reason} ->
        {:error, :identity_mismatch}

      {:ok, bytes} ->
        case parse(bytes) do
          {:ok, %{host: ^host, username: ^username}} -> :ok
          _mismatch_or_unparseable -> {:error, :identity_mismatch}
        end
    end
  end

  # -- .readopt one-shot marker -----------------------------------------------

  @doc """
  Writes the `.readopt` marker for `slug`, fsynced (temp file + `datasync` +
  rename — same discipline as `Valea.Mail.Maildir.deliver!/3`) so the
  authorization survives a crash between this call and the next sync pass
  reading it.
  """
  @spec authorize_readopt!(String.t(), String.t()) :: :ok
  def authorize_readopt!(root, slug) when is_binary(root) and is_binary(slug) do
    path = readopt_path(root, slug)
    File.mkdir_p!(Path.dirname(path))
    tmp = path <> ".tmp-#{System.unique_integer([:positive])}"

    File.write!(tmp, "1")
    File.open!(tmp, [:binary], fn file -> :file.datasync(file) end)
    File.rename!(tmp, path)

    :ok
  end

  @doc "Whether `slug`'s one-shot `.readopt` authorization is currently standing."
  @spec readopt_authorized?(String.t(), String.t()) :: boolean()
  def readopt_authorized?(root, slug) when is_binary(root) and is_binary(slug),
    do: File.exists?(readopt_path(root, slug))

  @doc "Clears `slug`'s `.readopt` marker. A no-op (not an error) when it's already absent."
  @spec clear_readopt!(String.t(), String.t()) :: :ok
  def clear_readopt!(root, slug) when is_binary(root) and is_binary(slug) do
    File.rm(readopt_path(root, slug))
    :ok
  end

  # -- .account render/parse ---------------------------------------------------

  defp render(host, username) do
    "host: #{yaml_string(host)}\nusername: #{yaml_string(username)}\n"
  end

  defp parse(bytes) do
    with {:ok, %{"host" => host, "username" => username}} <- YamlElixir.read_from_string(bytes),
         true <- is_binary(host) and is_binary(username) do
      {:ok, %{host: host, username: username}}
    else
      _ -> :error
    end
  end

  # Same injection hardening as `Valea.Mail.Settings.yaml_string/1` — `host`/
  # `username` reach here from the account-setup RPC (user input).
  defp yaml_string(value) when is_binary(value) do
    escaped =
      value
      |> ensure_valid_utf8()
      |> String.to_charlist()
      |> Enum.map(fn c -> if c < 0x20 or c == 0x7F, do: ?\s, else: c end)
      |> List.to_string()
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    "\"#{escaped}\""
  end

  defp ensure_valid_utf8(value) do
    if String.valid?(value), do: value, else: Valea.Mail.Normalizer.scrub_utf8(value)
  end

  defp atomic_write!(path, bytes) do
    tmp = path <> ".tmp-#{System.unique_integer([:positive])}"
    File.write!(tmp, bytes)
    File.rename!(tmp, path)
  end
end
