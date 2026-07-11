defmodule Valea.Mail.Settings do
  @moduledoc """
  `config/mail.yaml` v3 (mail design spec, §config/mail.yaml (v3)) ⇄
  `%Settings{}`. Non-secret only — this file never holds a password; the
  credential lives in the OS keychain, handed to the Engine over the
  control plane (see the spec's §Credentials).

  v3 dropped the v2 `smtp:` block, `ssl:` toggle, and `*_env` keys (TLS is
  mandatory and not configurable). `load/1` tolerates those leftovers in a
  hand-edited or not-yet-migrated file — a stray key must never brick
  Engine activation — by only ever reading the known v3 keys and ignoring
  everything else.

  ## Not configured vs. invalid

  `load/1` draws a line between two different failure shapes:

    * **`{:error, :not_configured}`** — the file is missing, or `imap.host`
      / `imap.username` are present but empty or still the seed's
      `imap.example.com` placeholder. This is the expected state before
      account setup has run; callers show onboarding, not an error.
    * **`{:error, {:invalid, reason}}`** — `imap.host` / `imap.username`
      are missing entirely or the wrong type, or `imap.port` isn't an
      integer. This means the file is structurally broken (hand-edited
      into a bad shape), which is worth surfacing loudly rather than
      silently treated as "not set up yet".

  `imap.port` defaults to `993` when absent (matching the struct default)
  — only a *present but non-integer* port is `:invalid`.
  """

  alias __MODULE__

  @placeholder_host "imap.example.com"
  @default_port 993
  @default_folders %{review: "AI/Review", processed: "AI/Processed", drafts: "Drafts"}
  @default_sync %{interval_minutes: 5, max_message_bytes: 10_485_760, inbox_index_limit: 200}

  defstruct account: nil,
            imap: %{host: nil, port: @default_port, username: nil},
            folders: @default_folders,
            sync: @default_sync

  @type t :: %__MODULE__{
          account: String.t() | nil,
          imap: %{host: String.t() | nil, port: pos_integer(), username: String.t() | nil},
          folders: %{review: String.t(), processed: String.t(), drafts: String.t()},
          sync: %{
            interval_minutes: pos_integer(),
            max_message_bytes: pos_integer(),
            inbox_index_limit: pos_integer()
          }
        }

  @doc """
  Loads and validates `<root>/config/mail.yaml`.

  Returns `{:ok, %Settings{}}`, `{:error, :not_configured}`, or
  `{:error, {:invalid, reason}}` — see the moduledoc for the line between
  the latter two.
  """
  @spec load(String.t()) ::
          {:ok, t()} | {:error, :not_configured} | {:error, {:invalid, String.t()}}
  def load(root) when is_binary(root) do
    path = Path.join(root, "config/mail.yaml")

    with true <- File.exists?(path),
         {:ok, doc} when is_map(doc) <- YamlElixir.read_from_file(path) do
      build(doc)
    else
      false ->
        {:error, :not_configured}

      {:ok, _not_a_map} ->
        {:error, {:invalid, "config/mail.yaml must be a YAML mapping"}}

      {:error, %YamlElixir.FileNotFoundError{}} ->
        {:error, :not_configured}

      {:error, %{message: message}} ->
        {:error, {:invalid, message}}
    end
  end

  @doc """
  Renders and atomically writes the full v3 `config/mail.yaml` —
  `folders:`, `sync:`, and `safety:` always take their defaults (`safety:`
  is a fixed invariant; the Engine has no send path). Never writes a
  credential; `attrs` carries none. The tmp-then-rename write means
  readers never observe a partial file.
  """
  @spec write!(String.t(), %{
          account: String.t(),
          host: String.t(),
          port: pos_integer(),
          username: String.t()
        }) :: :ok
  def write!(root, %{account: account, host: host, port: port, username: username})
      when is_binary(root) and is_binary(account) and is_binary(host) and is_integer(port) and
             is_binary(username) do
    dir = Path.join(root, "config")
    File.mkdir_p!(dir)
    path = Path.join(dir, "mail.yaml")
    atomic_write!(path, render(account, host, port, username))
    :ok
  end

  defp atomic_write!(path, bytes) do
    tmp = path <> ".tmp"
    File.write!(tmp, bytes)
    File.rename!(tmp, path)
  end

  defp render(account, host, port, username) do
    """
    account: #{yaml_string(account)}
    imap:
      host: #{yaml_string(host)}
      port: #{port}
      username: #{yaml_string(username)}
    folders:
      review: #{yaml_string(@default_folders.review)}
      processed: #{yaml_string(@default_folders.processed)}
      drafts: #{yaml_string(@default_folders.drafts)}
    sync:
      interval_minutes: #{@default_sync.interval_minutes}
      max_message_bytes: #{@default_sync.max_message_bytes}
      inbox_index_limit: #{@default_sync.inbox_index_limit}
    safety:
      send_directly: false
      create_drafts_only: true
    """
  end

  # Injection hardening, same shape as `Valea.Mail.MessageFile`'s
  # `yaml_string/1`: `account`/`host`/`username` reach here from the
  # account-setup RPC, i.e. arbitrary user input. Neutralizing control
  # characters (never dropping them, so a value doesn't silently truncate)
  # and escaping `\` / `"` before double-quoting means none of them can
  # ever inject a sibling YAML key or break the block.
  defp yaml_string(value) when is_binary(value) do
    escaped =
      value
      |> String.to_charlist()
      |> Enum.map(fn c -> if c < 0x20 or c == 0x7F, do: ?\s, else: c end)
      |> List.to_string()
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    "\"#{escaped}\""
  end

  defp build(doc) do
    imap =
      case Map.get(doc, "imap") do
        m when is_map(m) -> m
        _ -> %{}
      end

    with {:ok, host} <- fetch_required_string(imap, "host"),
         {:ok, username} <- fetch_required_string(imap, "username"),
         {:ok, port} <- fetch_port(imap) do
      cond do
        host == @placeholder_host -> {:error, :not_configured}
        blank?(host) -> {:error, :not_configured}
        blank?(username) -> {:error, :not_configured}
        true -> {:ok, to_struct(doc, host, port, username)}
      end
    end
  end

  defp to_struct(doc, host, port, username) do
    %Settings{
      account: Map.get(doc, "account"),
      imap: %{host: host, port: port, username: username},
      folders: merge_typed(@default_folders, Map.get(doc, "folders"), &is_binary/1),
      sync: merge_typed(@default_sync, Map.get(doc, "sync"), &is_integer/1)
    }
  end

  defp fetch_required_string(map, key) do
    case Map.fetch(map, key) do
      {:ok, v} when is_binary(v) -> {:ok, v}
      {:ok, _other} -> {:error, {:invalid, "imap.#{key} must be a string"}}
      :error -> {:error, {:invalid, "imap.#{key} is required"}}
    end
  end

  defp fetch_port(imap) do
    case Map.fetch(imap, "port") do
      {:ok, v} when is_integer(v) -> {:ok, v}
      {:ok, _other} -> {:error, {:invalid, "imap.port must be an integer"}}
      :error -> {:ok, @default_port}
    end
  end

  defp blank?(s), do: String.trim(s) == ""

  # Applies `defaults` (an atom-keyed map) with any matching, correctly
  # typed keys from `override` (a string-keyed map, as parsed from YAML)
  # layered on top. A present-but-wrong-type or unknown key is silently
  # skipped rather than erroring — folders/sync are cosmetic, so a
  # hand-edited leftover here must not brick loading the way a bad
  # host/username/port does.
  defp merge_typed(defaults, override, valid?) when is_map(override) do
    Enum.reduce(defaults, defaults, fn {key, _default}, acc ->
      merge_key(acc, key, Map.fetch(override, Atom.to_string(key)), valid?)
    end)
  end

  defp merge_typed(defaults, _override, _valid?), do: defaults

  defp merge_key(acc, key, {:ok, v}, valid?),
    do: if(valid?.(v), do: Map.put(acc, key, v), else: acc)

  defp merge_key(acc, _key, :error, _valid?), do: acc
end
