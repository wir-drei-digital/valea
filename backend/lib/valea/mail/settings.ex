defmodule Valea.Mail.Settings do
  @moduledoc """
  `config/mail.yaml` v4 (mail design spec E, §config/mail.yaml (v4)) ⇄
  `%{slug => %Settings{}}`. Non-secret only — this file never holds a
  password; the credential lives in the OS keychain, handed to the Engine
  over the control plane (see the spec's §Credentials).

  v4 replaces the v3 single-account top-level `account:`/`imap:`/`folders:`/
  `sync:` shape with a multi-account `accounts:` map keyed by a URL-safe
  slug. There is no v3 compatibility: a v3-shaped file (no `accounts:` key)
  loads as `{:error, {:invalid, _}}`.

  ## Per-account validity

  `load/1` validates every account entry **independently** — one
  hand-edited or otherwise broken entry must never brick the others. A
  structurally-invalid entry (bad slug grammar, missing/malformed
  `imap.host`/`imap.username`/`imap.port`) is dropped from the ok-map's
  `accounts:` and instead collected under `invalid: %{slug => reason}`, so
  the caller can still surface every other, valid account.

  ## Provider detection

  `upsert_account!/3` detects Gmail by host (`detect_provider/1`) and — when
  no caller-supplied override says otherwise — seeds the Gmail-specific
  folder names (`gmail_folders/0`) and excludes Gmail's virtual "All
  Mail"/"Important"/"Starred" folders from sync (`gmail_excludes/0`).
  Without this, a plain `imap.gmail.com` setup would sync Gmail's `[Gmail]/*`
  duplicates and never resolve `folders.archive` to `"[Gmail]/All Mail"` —
  the executor's Gmail archive contract never composes.

  ## Safety block

  `render/1` always emits the fixed v4 safety invariant
  (`never_expunge: true`, `outbound: push_drafts_only`) — this Engine never
  expunges a message and never sends anything directly; it only ever
  creates drafts.
  """

  alias __MODULE__
  alias Valea.Mail.Normalizer

  @default_port 993
  @default_folders %{drafts: "Drafts", sent: "Sent", archive: "Archive", trash: "Trash"}
  @default_sync %{
    window_days: 90,
    interval_minutes: 15,
    max_message_bytes: 26_214_400,
    exclude_folders: []
  }

  @gmail_hosts ~w(imap.gmail.com imap.googlemail.com)
  @gmail_excludes ["[Gmail]/All Mail", "[Gmail]/Important", "[Gmail]/Starred"]
  @gmail_folders %{
    drafts: "[Gmail]/Drafts",
    sent: "[Gmail]/Sent Mail",
    archive: "[Gmail]/All Mail",
    trash: "[Gmail]/Trash"
  }

  # `^[a-z0-9][a-z0-9-]{0,31}$` — lowercase, digits, and internal dashes
  # only; 1-32 chars total. Used both as a directory-safe identifier (the
  # OS keychain entry keys on it, per the spec's §Credentials) and as a
  # YAML mapping key that can be interpolated unquoted with no injection
  # risk (the character class structurally cannot break a YAML block).
  @slug_re ~r/^[a-z0-9][a-z0-9-]{0,31}$/

  defstruct slug: nil,
            provider: :generic,
            imap: %{host: nil, port: @default_port, username: nil},
            folders: @default_folders,
            sync: @default_sync

  @type t :: %__MODULE__{
          slug: String.t() | nil,
          provider: :generic | :gmail,
          imap: %{host: String.t() | nil, port: pos_integer(), username: String.t() | nil},
          folders: %{drafts: String.t(), sent: String.t(), archive: String.t(), trash: String.t()},
          sync: %{
            window_days: pos_integer(),
            interval_minutes: pos_integer(),
            max_message_bytes: pos_integer(),
            exclude_folders: [String.t()]
          }
        }

  @doc """
  Loads and validates every account in `<root>/config/mail.yaml`.

  Returns `{:ok, %{accounts: %{slug => t()}, invalid: %{slug => reason}}}`
  on any file that at least has a top-level `accounts:` mapping (possibly
  empty — a freshly scaffolded workspace's `accounts: {}` is a normal,
  valid state, not an error). `{:error, :not_configured}` when the file is
  missing entirely. `{:error, {:invalid, reason}}` when the file exists but
  isn't a YAML mapping, or has no `accounts:` mapping at all (including
  every v3-shaped file — there is no compatibility path).
  """
  @spec load(String.t()) ::
          {:ok, %{accounts: %{String.t() => t()}, invalid: %{String.t() => String.t()}}}
          | {:error, :not_configured}
          | {:error, {:invalid, String.t()}}
  def load(root) when is_binary(root) do
    case read_doc(root) do
      {:ok, doc} -> build_accounts(doc)
      {:error, _reason} = error -> error
    end
  end

  @doc "Slug grammar: `^[a-z0-9][a-z0-9-]{0,31}$` — lowercase, 1-32 chars."
  @spec valid_slug?(String.t()) :: boolean()
  def valid_slug?(slug) when is_binary(slug), do: Regex.match?(@slug_re, slug)
  def valid_slug?(_slug), do: false

  @doc """
  Detects the mailbox provider from its IMAP host. Only Gmail is special-
  cased today (`imap.gmail.com` / `imap.googlemail.com`, case-insensitive);
  every other host is `:generic`.
  """
  @spec detect_provider(String.t()) :: :gmail | :generic
  def detect_provider(host) when is_binary(host) do
    if String.downcase(host) in @gmail_hosts, do: :gmail, else: :generic
  end

  def detect_provider(_host), do: :generic

  @doc "The Gmail virtual folders excluded from sync (they mirror every other folder)."
  @spec gmail_excludes() :: [String.t()]
  def gmail_excludes, do: @gmail_excludes

  @doc "The Gmail-specific folder names — `archive` is `\"[Gmail]/All Mail\"`, never `\"Archive\"`."
  @spec gmail_folders() :: %{
          drafts: String.t(),
          sent: String.t(),
          archive: String.t(),
          trash: String.t()
        }
  def gmail_folders, do: @gmail_folders

  @doc """
  Adds or replaces the account at `slug`, then atomically rewrites the full
  `config/mail.yaml`. Validates `slug` against `valid_slug?/1` and against
  casefold-collision with any OTHER existing key already in the file (a
  grammar-valid slug can never collide with another grammar-valid one —
  grammar is lowercase-only — but a hand-edited file can still carry a
  mixed-case leftover; either failure mode reports the same
  `{:error, :invalid_slug}`, since a caller cannot act on the two any
  differently).

  Detects the provider from `host` (`detect_provider/1`) and layers the
  provider-appropriate folder/sync defaults (`gmail_folders/0` and
  `gmail_excludes/0` for Gmail) under any caller-supplied `folders:`/
  `sync:` overrides in `attrs`. Every other account in the file is
  preserved untouched (an already-invalid hand-edited entry is dropped on
  rewrite — this call fully re-renders the file, the same posture v3's
  `write!/2` took).
  """
  @spec upsert_account!(String.t(), String.t(), %{
          required(:host) => String.t(),
          required(:port) => pos_integer(),
          required(:username) => String.t(),
          optional(:folders) => map() | nil,
          optional(:sync) => map() | nil
        }) :: :ok | {:error, :invalid_slug}
  def upsert_account!(root, slug, %{host: host, port: port, username: username} = attrs)
      when is_binary(root) and is_binary(slug) and is_binary(host) and is_integer(port) and
             port > 0 and is_binary(username) do
    with :ok <- validate_new_slug(root, slug) do
      provider = detect_provider(host)

      account = %Settings{
        slug: slug,
        provider: provider,
        imap: %{host: host, port: port, username: username},
        folders:
          merge_override(default_folders_for(provider), Map.get(attrs, :folders), &is_binary/1),
        sync: merge_sync_override(default_sync_for(provider), Map.get(attrs, :sync))
      }

      accounts = root |> current_accounts() |> Map.put(slug, account)
      atomic_write!(mail_yaml_path(root), render(accounts))
      :ok
    end
  end

  @doc "Removes the account at `slug` (a no-op `:ok` if it was already absent) and rewrites the file."
  @spec remove_account!(String.t(), String.t()) :: :ok
  def remove_account!(root, slug) when is_binary(root) and is_binary(slug) do
    accounts = root |> current_accounts() |> Map.delete(slug)
    atomic_write!(mail_yaml_path(root), render(accounts))
    :ok
  end

  @doc """
  Renders the full v4 `config/mail.yaml` bytes for `accounts` (a
  `%{slug => t()}` map, as `load/1`'s ok-map's `accounts:` field) — the
  fixed `safety:` block (`never_expunge: true`, `outbound:
  push_drafts_only`) is always emitted. String fields go through the
  injection-hardened `yaml_string/1` (same shape as `Valea.Mail.MessageFile`'s
  helper of the same name); slugs are grammar-validated elsewhere and never
  reach here unvalidated, so they're safe to interpolate unquoted as YAML
  mapping keys.
  """
  @spec render(%{String.t() => t()}) :: binary()
  def render(accounts) when is_map(accounts) do
    accounts_block =
      case Enum.sort_by(accounts, fn {slug, _account} -> slug end) do
        [] -> "accounts: {}\n"
        list -> "accounts:\n" <> Enum.map_join(list, fn {slug, a} -> render_account(slug, a) end)
      end

    """
    version: 4
    #{accounts_block}safety:
      never_expunge: true
      outbound: push_drafts_only
    """
  end

  @doc """
  Reads `VALEA_MAIL_PASSWORD_<SLUG>`, where `<SLUG>` is `slug` upcased with
  every `-` turned into `_` (env var names can't contain `-`). Returns
  `nil` when unset — never raises on a missing credential; callers treat
  that exactly like "no credential yet".
  """
  @spec env_credential(String.t()) :: String.t() | nil
  def env_credential(slug) when is_binary(slug) do
    var_name =
      slug
      |> String.upcase()
      |> String.replace("-", "_")

    System.get_env("VALEA_MAIL_PASSWORD_#{var_name}")
  end

  # -- file I/O -----------------------------------------------------------------

  defp mail_yaml_path(root), do: Path.join(root, "config/mail.yaml")

  defp read_doc(root) do
    path = mail_yaml_path(root)

    with true <- File.exists?(path),
         {:ok, doc} when is_map(doc) <- YamlElixir.read_from_file(path) do
      {:ok, doc}
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

  defp atomic_write!(path, bytes) do
    File.mkdir_p!(Path.dirname(path))
    tmp = path <> ".tmp"
    File.write!(tmp, bytes)
    File.rename!(tmp, path)
  end

  # Reads back only the currently VALID accounts (the same set `load/1`
  # would put in its ok-map's `accounts:`) — a missing file or an
  # otherwise-broken one (e.g. a leftover v3 file) both fall back to `%{}`,
  # since `upsert_account!/3` is allowed to create/repair the file fresh,
  # same posture v3's `write!/2` took.
  defp current_accounts(root) do
    case load(root) do
      {:ok, %{accounts: accounts}} -> accounts
      {:error, _reason} -> %{}
    end
  end

  # -- slug validation ------------------------------------------------------

  defp validate_new_slug(root, slug) do
    cond do
      not valid_slug?(slug) -> {:error, :invalid_slug}
      casefold_collision?(root, slug) -> {:error, :invalid_slug}
      true -> :ok
    end
  end

  # Checks the RAW file (not just the already-validated accounts) so a
  # hand-edited mixed-case leftover still blocks a new, grammar-valid slug
  # that would collide with it case-insensitively.
  defp casefold_collision?(root, slug) do
    case read_doc(root) do
      {:ok, %{"accounts" => accounts}} when is_map(accounts) ->
        Enum.any?(accounts, fn {existing, _attrs} ->
          existing != slug and is_binary(existing) and
            String.downcase(existing) == String.downcase(slug)
        end)

      _ ->
        false
    end
  end

  # -- parsing --------------------------------------------------------------

  defp build_accounts(doc) do
    case Map.fetch(doc, "accounts") do
      {:ok, accounts} when is_map(accounts) ->
        {valid, invalid} =
          Enum.reduce(accounts, {%{}, %{}}, fn {slug, attrs}, {valid_acc, invalid_acc} ->
            case build_account(slug, attrs) do
              {:ok, account} -> {Map.put(valid_acc, slug, account), invalid_acc}
              {:error, reason} -> {valid_acc, Map.put(invalid_acc, to_string(slug), reason)}
            end
          end)

        {:ok, %{accounts: valid, invalid: invalid}}

      _ ->
        {:error, {:invalid, "config/mail.yaml must define an accounts: mapping"}}
    end
  end

  defp build_account(slug, attrs) when is_map(attrs) do
    if valid_slug?(slug) do
      imap = fetch_map(attrs, "imap")

      with {:ok, host} <- fetch_required_string(imap, "host"),
           {:ok, username} <- fetch_required_string(imap, "username"),
           {:ok, port} <- fetch_port(imap) do
        # Resolve provider: explicit YAML value takes precedence, fallback to host detection
        provider =
          case provider_from_string(Map.get(attrs, "provider")) do
            :generic -> detect_provider(host)
            explicit -> explicit
          end

        {:ok,
         %Settings{
           slug: slug,
           provider: provider,
           imap: %{host: host, port: port, username: username},
           folders:
             merge_yaml(default_folders_for(provider), Map.get(attrs, "folders"), &is_binary/1),
           sync: merge_yaml_sync(default_sync_for(provider), Map.get(attrs, "sync"))
         }}
      end
    else
      {:error, "invalid slug #{inspect(slug)}"}
    end
  end

  defp build_account(slug, _attrs), do: {:error, "account #{inspect(slug)} must be a mapping"}

  defp provider_from_string("gmail"), do: :gmail
  defp provider_from_string(_other), do: :generic

  defp fetch_map(attrs, key) do
    case Map.get(attrs, key) do
      m when is_map(m) -> m
      _ -> %{}
    end
  end

  defp fetch_required_string(map, key) do
    case Map.fetch(map, key) do
      {:ok, v} when is_binary(v) and v != "" -> {:ok, v}
      {:ok, _other} -> {:error, "imap.#{key} must be a non-empty string"}
      :error -> {:error, "imap.#{key} is required"}
    end
  end

  defp fetch_port(imap) do
    case Map.fetch(imap, "port") do
      {:ok, v} when is_integer(v) and v > 0 -> {:ok, v}
      {:ok, _other} -> {:error, "imap.port must be a positive integer"}
      :error -> {:ok, @default_port}
    end
  end

  # -- defaults by provider -------------------------------------------------

  defp default_folders_for(:gmail), do: @gmail_folders
  defp default_folders_for(:generic), do: @default_folders

  defp default_sync_for(:gmail), do: %{@default_sync | exclude_folders: @gmail_excludes}
  defp default_sync_for(:generic), do: @default_sync

  # -- typed merges (v3's merge_typed/merge_key style, kept for both the
  # string-keyed YAML-doc path and the atom-keyed Elixir-call path) --------

  # YAML doc override: string keys (as YamlElixir parses them).
  defp merge_yaml(defaults, override, valid?) when is_map(override) do
    Enum.reduce(defaults, defaults, fn {key, _default}, acc ->
      merge_yaml_key(acc, override, key, valid?)
    end)
  end

  defp merge_yaml(defaults, _override, _valid?), do: defaults

  defp merge_yaml_key(acc, override, key, valid?) do
    case Map.fetch(override, Atom.to_string(key)) do
      {:ok, v} -> if valid?.(v), do: Map.put(acc, key, v), else: acc
      :error -> acc
    end
  end

  defp merge_yaml_sync(defaults, override) when is_map(override) do
    defaults
    |> merge_yaml_key(override, :window_days, &pos_integer?/1)
    |> merge_yaml_key(override, :interval_minutes, &pos_integer?/1)
    |> merge_yaml_key(override, :max_message_bytes, &pos_integer?/1)
    |> merge_yaml_key(override, :exclude_folders, &string_list?/1)
  end

  defp merge_yaml_sync(defaults, _override), do: defaults

  # Elixir-call override (`upsert_account!/3`'s `attrs.folders`/`attrs.sync`):
  # atom keys already, straight from the caller.
  defp merge_override(defaults, nil, _valid?), do: defaults

  defp merge_override(defaults, override, valid?) when is_map(override) do
    Enum.reduce(defaults, defaults, fn {key, _default}, acc ->
      merge_override_key(acc, override, key, valid?)
    end)
  end

  defp merge_override_key(acc, override, key, valid?) do
    case Map.fetch(override, key) do
      {:ok, v} -> if valid?.(v), do: Map.put(acc, key, v), else: acc
      :error -> acc
    end
  end

  defp merge_sync_override(defaults, nil), do: defaults

  defp merge_sync_override(defaults, override) when is_map(override) do
    defaults
    |> merge_override_key(override, :window_days, &pos_integer?/1)
    |> merge_override_key(override, :interval_minutes, &pos_integer?/1)
    |> merge_override_key(override, :max_message_bytes, &pos_integer?/1)
    |> merge_override_key(override, :exclude_folders, &string_list?/1)
  end

  defp pos_integer?(v), do: is_integer(v) and v > 0
  defp string_list?(v), do: is_list(v) and Enum.all?(v, &is_binary/1)

  # -- rendering --------------------------------------------------------------

  defp render_account(slug, %Settings{} = a) do
    """
      #{slug}:
        provider: #{a.provider}
        imap:
          host: #{yaml_string(a.imap.host)}
          port: #{a.imap.port}
          username: #{yaml_string(a.imap.username)}
        folders:
          drafts: #{yaml_string(a.folders.drafts)}
          sent: #{yaml_string(a.folders.sent)}
          archive: #{yaml_string(a.folders.archive)}
          trash: #{yaml_string(a.folders.trash)}
        sync:
          window_days: #{a.sync.window_days}
          interval_minutes: #{a.sync.interval_minutes}
          max_message_bytes: #{a.sync.max_message_bytes}
          exclude_folders: #{render_string_list(a.sync.exclude_folders)}
    """
  end

  defp render_string_list([]), do: "[]"
  defp render_string_list(list), do: "[" <> Enum.map_join(list, ", ", &yaml_string/1) <> "]"

  # Injection hardening, same shape as `Valea.Mail.MessageFile`'s
  # `yaml_string/1`: `host`/`username`/folder names reach here from the
  # account-setup RPC, i.e. arbitrary user input. Invalid UTF-8 is scrubbed
  # first (each bad sequence → U+FFFD, via `Normalizer.scrub_utf8/1`) so
  # `String.to_charlist/1` structurally cannot raise on raw bytes; then
  # every C0 control character and DEL is neutralized to a plain space
  # (never dropped, so a value doesn't silently truncate) and `\` / `"`
  # are escaped before double-quoting — none of these values can ever
  # inject a sibling YAML key, break the block, or crash the write.
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
    if String.valid?(value), do: value, else: Normalizer.scrub_utf8(value)
  end
end
