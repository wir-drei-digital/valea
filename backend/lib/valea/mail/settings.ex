defmodule Valea.Mail.Settings do
  @moduledoc """
  `config/mail.yaml` v5 (mail SMTP-send design spec G, §Configuration &
  credentials) ⇄ `%{slug => %Settings{}}`. Non-secret only — this file
  never holds a password; the credentials (IMAP and SMTP, separately) live
  in the OS keychain, handed to the Engine over the control plane (see the
  spec's §Credentials).

  v4 replaced the v3 single-account top-level `account:`/`imap:`/`folders:`/
  `sync:` shape with a multi-account `accounts:` map keyed by a URL-safe
  slug. There is no v3 compatibility: a v3-shaped file (no `accounts:` key)
  loads as `{:error, {:invalid, _}}`.

  ## v5: the optional `smtp:` block

  v5 adds one optional per-account `smtp:` block and flips the `safety:`
  block's `outbound:` value to `human_send_and_push`. A v4 file loads
  unchanged — every account simply gets `smtp: nil` — and is normalized to
  v5 on the next write (`render/1` only ever emits v5). The `version:` key
  itself is documentation, not a gate: `load/1` has never read it, and a
  file's SHAPE (an `accounts:` mapping, per-account validity) is what
  decides.

  `smtp: nil` means a PUSH-ONLY account: no Send action, everything else
  unchanged. When present, the block is validated at load —
  `security` defaults from the port (587 → `:starttls`, 465 → `:tls`; any
  other port must state `security:` explicitly, and an explicit value
  contradicting the 587/465 convention is rejected), `from` defaults to
  `username` and must be a single addr-spec (it becomes the `From` header —
  a draft can never override it), and a `from_name` carrying CR/LF/NUL is
  rejected outright (header injection). A broken `smtp:` block invalidates
  only ITS account, exactly like a broken `imap:` one.

  ## The `imap.security` mode and per-account `tls_cacert_file`

  ProtonMail Bridge support, in two additive keys. `imap.security` (`tls` |
  `starttls`) picks WHICH TLS the IMAP connection uses — implicit on connect
  (IMAPS/993, the default) or a STARTTLS upgrade (143, Bridge's 1143). An
  absent key means the port's convention: 143 → `starttls`, every other port
  → `tls` — deliberately unlike `smtp.security`'s "nonstandard ports must
  state a mode", because every file written before this key existed ran
  implicit TLS on whatever port it had, and invalidating those accounts is
  exactly what an additive key must not do. An explicit value contradicting
  the 993/143 convention, or an unusable one, INVALIDATES the account like
  `auth:` — there is no plaintext to fall back to, only the wrong TLS.

  `tls_cacert_file` is an optional per-account absolute path to a PEM
  certificate that REPLACES the system CA store for BOTH protocols
  (`verify_peer` stays on; the clients additionally accept a byte-identical
  self-signed peer — see `Valea.Mail.ImapClient`'s pinning comment). It
  exists for a local bridge's self-signed certificate and rides `imap_config/1`
  and `smtp_config/1` as `cacertfile`. An unusable value DEGRADES to "no
  pin" (the `oauth_client_id` posture, not `auth:`'s): either way the
  handshake against the bridge fails closed and visibly in the doctor.

  ## The per-account `auth:` mode

  One optional per-account key (mail full-client plan, M6 task 15),
  `password` (the default) or `oauth2` — which SASL verb the two clients
  authenticate with, NOT where the secret comes from. Additive on top of
  v5: a file written before it existed loads every account as `password`,
  and is normalized on the next write (`render/1` always emits the key).

  Unlike `folders:`/`sync:`/`notifications:`, an unusable value here does
  NOT fall back to the default — it INVALIDATES the account, exactly like a
  broken `imap:` block. The fallback the others take would be a silent
  auth-mode DOWNGRADE, and for an OAuth2 account that means the engine
  offering its access token as a LOGIN password: a secret sent in the wrong
  field, to a server that never asked for one, over a typo.

  ## The per-account `oauth_client_id` override

  One optional per-account string (mail full-client plan, M6 task 16): the
  PUBLIC OAuth2 client id this account authorizes with, overriding whatever
  `config :valea, :mail_oauth` ships for its provider. It exists because a
  public client id is per-INSTALLATION — the person running a packaged build
  registers their own with Google/Microsoft — and editing one line of
  `config/mail.yaml` must not require a rebuild.

  Not a secret (PKCE public clients have no secret at all — see
  `Valea.Mail.OAuth`), so it lives in this non-secret file like every other
  connection detail. Rendered only when set, so a file for an account that
  doesn't override keeps its exact previous bytes.

  An unusable value (present but not a non-empty string) DEGRADES to "no
  override" rather than invalidating the account — the `folders:`/`sync:`
  posture, not `auth:`'s. The distinction is real: a wrong client id cannot
  put a secret anywhere it doesn't belong, it just makes the sign-in flow
  refuse or the provider reject it, both of which are visible and harmless.

  ## The per-account `notifications:` flag

  One optional boolean per account (mail full-client plan, M5 task 13),
  DEFAULT OFF. Additive on top of v5 — a file written before it existed loads
  every account with `notifications: false`, and is normalized on the next
  write (`render/1` always emits the key). Anything that isn't literally
  `true` is `false`: a hand-edited `notifications: "yes"` turns notifications
  OFF rather than invalidating the account, on the same "an unusable override
  falls back to the default" posture `folders:`/`sync:` already take.

  ## Per-account validity

  `load/1` validates every account entry **independently** — one
  hand-edited or otherwise broken entry must never brick the others. A
  structurally-invalid entry (bad slug grammar, missing/malformed
  `imap.host`/`imap.username`/`imap.port`) is dropped from the ok-map's
  `accounts:` and instead collected under `invalid: %{slug => reason}`, so
  the caller can still surface every other, valid account.

  ## Provider detection

  `upsert_account!/3` detects the provider by host (`detect_provider/1`) and
  — when no caller-supplied override says otherwise — seeds that provider's
  folder names and sync exclusions.

  **Gmail** (`imap.gmail.com`/`imap.googlemail.com`) gets `gmail_folders/0`
  and excludes Gmail's virtual "All Mail"/"Important"/"Starred" folders from
  sync (`gmail_excludes/0`). Without this, a plain `imap.gmail.com` setup
  would sync Gmail's `[Gmail]/*` duplicates and never resolve
  `folders.archive` to `"[Gmail]/All Mail"` — the executor's Gmail archive
  contract never composes.

  **Microsoft 365 / Outlook.com** (`outlook.office365.com` and friends, M6
  task 16) gets `microsoft_folders/0`: Exchange names its special folders
  `"Sent Items"` and `"Deleted Items"`, so the generic `"Sent"`/`"Trash"`
  defaults would have the doctor offer to CREATE two folders that already
  exist under other names, and every archive/trash op would file into the
  duplicates. Nothing is excluded from sync — Exchange has no virtual
  mirror folders.

  Detection is also what routes the setup UI to "Sign in with
  Google/Microsoft" (`Valea.Mail.OAuth.provider_for/1` maps these same
  atoms onto its presets), so the host table has one home.

  ## Safety block

  `render/1` always emits the fixed v5 safety invariant
  (`never_expunge: true`, `outbound: human_send_and_push`) — this Engine
  never expunges a message, and the only transmission path is a HUMAN
  clicking Send or Push in the app (no agent-facing tool or file convention
  can reach either).
  """

  alias __MODULE__
  alias Valea.Mail.DraftFile
  alias Valea.Mail.Normalizer

  @default_port 993
  @default_smtp_port 587
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

  # Microsoft 365 / Outlook.com over IMAP (M6 task 16). `outlook.office365.com`
  # is the current endpoint for both business and consumer mailboxes;
  # `imap-mail.outlook.com` is the older consumer name, and `outlook.office.com`
  # appears in some tenant documentation. All three are the same service and
  # the same OAuth2 endpoints.
  @microsoft_hosts ~w(outlook.office365.com outlook.office.com imap-mail.outlook.com)
  @microsoft_folders %{
    drafts: "Drafts",
    sent: "Sent Items",
    archive: "Archive",
    trash: "Deleted Items"
  }

  # `^[a-z0-9][a-z0-9-]{0,31}$` — lowercase, digits, and internal dashes
  # only; 1-32 chars total. Used both as a directory-safe identifier (the
  # OS keychain entry keys on it, per the spec's §Credentials) and as a
  # YAML mapping key that can be interpolated unquoted with no injection
  # risk (the character class structurally cannot break a YAML block).
  @slug_re ~r/^[a-z0-9][a-z0-9-]{0,31}$/

  defstruct slug: nil,
            provider: :generic,
            auth: :password,
            oauth_client_id: nil,
            tls_cacert_file: nil,
            imap: %{host: nil, port: @default_port, security: :tls, username: nil},
            smtp: nil,
            notifications: false,
            folders: @default_folders,
            sync: @default_sync

  @typedoc """
  One account's non-secret settings. `smtp: nil` is a push-only account
  (v4 files, and any v5 account that simply has no `smtp:` block); when
  present, `from` is ALWAYS populated (defaulted to `username` at load).

  `auth` is the account's SASL mode (M6 task 15) — `:password` (the default,
  and every account written before the key existed) or `:oauth2`. It is
  per-ACCOUNT, not per-protocol: one mode governs both the IMAP and the SMTP
  session, which is why it sits here rather than inside `imap`/`smtp`.
  `imap_config/1` and `smtp_config/1` are what stamp it onto the maps the
  transports actually receive.

  `oauth_client_id` is the per-account PUBLIC client id override (M6 task 16),
  `nil` for every account that takes whatever `config :valea, :mail_oauth`
  ships — see the moduledoc's §The per-account `oauth_client_id` override. It
  is deliberately NOT in `imap`/`smtp`: one authorization covers both
  protocols, exactly like `auth`.

  `notifications` is the per-account OS-notification opt-in (mail full-client
  plan, M5 task 13) — DEFAULT OFF, and off for every file written before it
  existed (a missing or non-boolean `notifications:` key loads as `false`).
  It gates nothing backend-side: the counter it feeds (`new_unread` on the
  `mail_sync` push) is computed for every account regardless, and this flag
  is the frontend's permission to raise a notification for it.
  """
  @type t :: %__MODULE__{
          slug: String.t() | nil,
          provider: provider(),
          auth: auth(),
          oauth_client_id: String.t() | nil,
          tls_cacert_file: String.t() | nil,
          imap: %{
            host: String.t() | nil,
            port: pos_integer(),
            security: security(),
            username: String.t() | nil
          },
          smtp: smtp() | nil,
          notifications: boolean(),
          folders: %{drafts: String.t(), sent: String.t(), archive: String.t(), trash: String.t()},
          sync: %{
            window_days: pos_integer(),
            interval_minutes: pos_integer(),
            max_message_bytes: pos_integer(),
            exclude_folders: [String.t()]
          }
        }

  @typedoc """
  Which SASL mechanism this account authenticates with — `:password`
  (`LOGIN` / `AUTH PLAIN`|`LOGIN`) or `:oauth2` (`XOAUTH2`, both protocols).
  """
  @type auth :: :password | :oauth2

  @typedoc """
  Which TLS a connection uses — implicit on connect (`:tls`) or a STARTTLS
  upgrade. There is no plaintext mode; TLS is mandatory and verified either
  way. Shared by the `imap:` and `smtp:` blocks.
  """
  @type security :: :tls | :starttls

  @typedoc """
  The recognized mailbox providers (`detect_provider/1`). Each one picks its
  own folder/sync defaults, and the two non-generic ones are also the keys
  `Valea.Mail.OAuth`'s presets are stored under.
  """
  @type provider :: :generic | :gmail | :microsoft

  @type smtp :: %{
          host: String.t(),
          port: pos_integer(),
          security: :starttls | :tls,
          username: String.t(),
          from: String.t(),
          from_name: String.t() | nil
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
  Detects the mailbox provider from its IMAP host, case-insensitively: Gmail
  (`imap.gmail.com` / `imap.googlemail.com`), Microsoft 365 / Outlook.com
  (`outlook.office365.com` and its two aliases — M6 task 16), `:generic` for
  everything else.

  THE host table for the whole codebase: it decides both the folder/sync
  defaults (see the moduledoc's §Provider detection) and which OAuth2 preset
  an account can sign in with (`Valea.Mail.OAuth.provider_for/1`).
  """
  @spec detect_provider(String.t()) :: provider()
  def detect_provider(host) when is_binary(host) do
    host = String.downcase(host)

    cond do
      host in @gmail_hosts -> :gmail
      host in @microsoft_hosts -> :microsoft
      true -> :generic
    end
  end

  def detect_provider(_host), do: :generic

  @doc """
  The config map handed to `Valea.Mail.Transport.connect/3` — this account's
  `imap:` block plus its `auth:` mode.

  THE seam that carries the auth mode to the IMAP client (M6 task 15). Every
  production `connect/3` call site goes through here rather than passing
  `settings.imap` directly, so the mode cannot be dropped on one path and
  honored on another: a caller that forgot it would have the client fall back
  to `LOGIN` and send an access token as a password.
  """
  @spec imap_config(t()) :: %{
          host: String.t() | nil,
          port: pos_integer(),
          security: security(),
          username: String.t() | nil,
          auth: auth(),
          cacertfile: String.t() | nil
        }
  def imap_config(%Settings{imap: imap, auth: auth, tls_cacert_file: cacert}) do
    imap |> Map.put(:auth, auth) |> Map.put(:cacertfile, cacert)
  end

  @doc """
  The config map handed to `Valea.Mail.SmtpTransport`'s callbacks — this
  account's `smtp:` block plus its `auth:` mode, or `nil` for a push-only
  account. The send-side counterpart of `imap_config/1`, for the same reason.
  """
  @spec smtp_config(t()) ::
          %{
            host: String.t(),
            port: pos_integer(),
            security: security(),
            username: String.t(),
            from: String.t(),
            from_name: String.t() | nil,
            auth: auth(),
            cacertfile: String.t() | nil
          }
          | nil
  def smtp_config(%Settings{smtp: nil}), do: nil

  def smtp_config(%Settings{smtp: smtp, auth: auth, tls_cacert_file: cacert}) do
    smtp |> Map.put(:auth, auth) |> Map.put(:cacertfile, cacert)
  end

  @doc "True when this account carries an `smtp:` block — i.e. it can send, not only push."
  @spec smtp_configured?(t()) :: boolean()
  def smtp_configured?(%Settings{smtp: nil}), do: false
  def smtp_configured?(%Settings{}), do: true

  @doc """
  An opaque hash over everything that decides HOW and AS WHOM this account
  transmits — `nil` for a push-only account.

  This is the settings component of the send flow's **review fingerprint**
  (spec G, §Send pipeline): the value the user reviewed is pinned into the
  send op, and a send whose fingerprint no longer matches is refused rather
  than transmitted under changed identity or against a different server.
  Task 4's `review_fingerprint/2` joins the resolved threading to this
  hash — nothing else may fold into it, and the input string below is
  frozen: changing it invalidates in-flight reviews.

  Deliberately EXCLUDES everything that doesn't change what lands in the
  recipient's mailbox (`sync:`, `folders:`, the IMAP block): a poll-interval
  edit must not force the user to re-review a composed message.
  """
  @spec smtp_fingerprint(t()) :: String.t() | nil
  def smtp_fingerprint(%Settings{smtp: nil}), do: nil

  def smtp_fingerprint(%Settings{smtp: smtp}) do
    :sha256
    |> :crypto.hash(fingerprint_input(smtp))
    |> Base.encode16(case: :lower)
  end

  @doc """
  The canonical, FROZEN input string `smtp_fingerprint/1` hashes — public so
  the send flow's `Valea.Mail.OpsExecutor.review_fingerprint/2` can extend it
  with the review's resolved threading without re-spelling it (two spellings
  of a frozen string is exactly the bug that would silently stop rejecting
  identity drift).

  Changing this string invalidates every in-flight review.
  """
  @spec fingerprint_input(smtp()) :: String.t()
  def fingerprint_input(smtp) do
    "smtp\n#{smtp.from}\n#{smtp.from_name || ""}\n#{smtp.host}\n#{smtp.port}\n#{smtp.security}\n#{smtp.username}\n"
  end

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

  @doc "The Microsoft 365 / Outlook.com folder names — Exchange spells them `\"Sent Items\"` and `\"Deleted Items\"`."
  @spec microsoft_folders() :: %{
          drafts: String.t(),
          sent: String.t(),
          archive: String.t(),
          trash: String.t()
        }
  def microsoft_folders, do: @microsoft_folders

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
          optional(:security) => security() | nil,
          optional(:auth) => auth() | nil,
          optional(:oauth_client_id) => String.t() | nil,
          optional(:tls_cacert_file) => String.t() | nil,
          optional(:smtp) => map() | nil,
          optional(:notifications) => boolean() | nil,
          optional(:folders) => map() | nil,
          optional(:sync) => map() | nil
        }) :: :ok | {:error, :invalid_slug | :invalid_smtp | :invalid_auth | :invalid_security}
  def upsert_account!(root, slug, %{host: host, port: port, username: username} = attrs)
      when is_binary(root) and is_binary(slug) and is_binary(host) and is_integer(port) and
             port > 0 and is_binary(username) do
    with :ok <- validate_new_slug(root, slug),
         {:ok, auth} <- validate_auth_attr(Map.get(attrs, :auth)),
         {:ok, security} <- validate_security_attr(Map.get(attrs, :security), port),
         {:ok, smtp} <- validate_smtp_attrs(Map.get(attrs, :smtp)) do
      provider = detect_provider(host)

      account = %Settings{
        slug: slug,
        provider: provider,
        auth: auth,
        # Absent means "no override", i.e. the app-config client id — the same
        # whole-entry rule as `notifications:`/`folders:`/`sync:`. A caller
        # EDITING an account that carries one must send it back (the RPC layer
        # does, via `get_mail_account_settings`).
        oauth_client_id: string_override(Map.get(attrs, :oauth_client_id)),
        # Same whole-entry rule and the same degrade posture (see the load
        # path's `string_override/1` use): a pinned trust root only ever
        # narrows what a connect will accept, so a dropped one fails closed.
        tls_cacert_file: string_override(Map.get(attrs, :tls_cacert_file)),
        imap: %{host: host, port: port, security: security, username: username},
        smtp: smtp,
        # Absent means OFF, exactly like `folders:`/`sync:` absent means the
        # provider defaults: this call re-renders the account entry whole, so
        # a caller that doesn't state the flag is stating the default.
        notifications: Map.get(attrs, :notifications) == true,
        folders:
          merge_override(default_folders_for(provider), Map.get(attrs, :folders), &is_binary/1),
        sync: merge_sync_override(default_sync_for(provider), Map.get(attrs, :sync))
      }

      accounts = root |> current_accounts() |> Map.put(slug, account)
      atomic_write!(mail_yaml_path(root), render(accounts))
      :ok
    end
  end

  # The caller (the setup RPC) has already narrowed its string argument to one
  # of these two atoms; this is the last gate before an unusable mode is
  # RENDERED into the file, where it would invalidate the whole account on the
  # next load. Absent means `:password` — this call re-renders the account
  # entry whole, so a caller that doesn't state the mode is stating the
  # default, exactly as it already is for `notifications:`/`folders:`/`sync:`.
  defp validate_auth_attr(nil), do: {:ok, :password}
  defp validate_auth_attr(:password), do: {:ok, :password}
  defp validate_auth_attr(:oauth2), do: {:ok, :oauth2}
  defp validate_auth_attr(_other), do: {:error, :invalid_auth}

  # The IMAP-side counterpart of `fetch_security/2`'s convention check, over
  # the atoms the caller (the setup RPC) has already narrowed to. Absent means
  # the port's default — never a guess a caller has to know about.
  defp validate_security_attr(nil, port), do: {:ok, default_imap_security(port)}

  defp validate_security_attr(security, port) when security in [:tls, :starttls] do
    case check_imap_port_convention(security, port) do
      {:ok, security} -> {:ok, security}
      {:error, _reason} -> {:error, :invalid_security}
    end
  end

  defp validate_security_attr(_other, _port), do: {:error, :invalid_security}

  # An `smtp:` the caller (i.e. the setup RPC, i.e. a human filling a form)
  # got wrong must NEVER be written: a rendered-but-unloadable block would
  # invalidate the whole account on the next load — killing its IMAP sync
  # too, over a typo'd From address. Validated here through the SAME parser
  # the load path uses, so what upsert accepts is exactly what load accepts.
  defp validate_smtp_attrs(nil), do: {:ok, nil}

  defp validate_smtp_attrs(attrs) when is_map(attrs) do
    yaml_shape =
      attrs
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new(fn {key, value} -> {to_string(key), value} end)

    case parse_smtp(yaml_shape) do
      {:ok, smtp} -> {:ok, smtp}
      {:error, _reason} -> {:error, :invalid_smtp}
    end
  end

  defp validate_smtp_attrs(_attrs), do: {:error, :invalid_smtp}

  @doc """
  Writes `pem` — the certificate a "Fetch certificate" probe retrieved and
  the user confirmed (`Valea.Mail.CertProbe`) — to
  `config/mail-certs/<slug>.pem` (atomic, same discipline as the yaml
  itself) and returns the absolute path, i.e. the value the account's
  `tls_cacert_file:` carries from then on. Overwrites in place: a re-fetch
  replaces the pin. The file is deliberately plain PEM in `config/` —
  file-first like everything else mail: visible, hand-editable, and exactly
  what a user who exported the cert themselves would have pointed at.
  """
  @spec write_account_cert!(String.t(), String.t(), String.t()) :: String.t()
  def write_account_cert!(root, slug, pem)
      when is_binary(root) and is_binary(slug) and is_binary(pem) do
    # The slug names a file: grammar-checked HERE too (not only in the RPC),
    # since `../x` would otherwise write outside config/mail-certs/.
    unless valid_slug?(slug), do: raise(ArgumentError, "invalid slug #{inspect(slug)}")

    path = Path.join([root, "config", "mail-certs", "#{slug}.pem"])
    atomic_write!(path, pem)
    path
  end

  @doc "Removes the account at `slug` (a no-op `:ok` if it was already absent) and rewrites the file."
  @spec remove_account!(String.t(), String.t()) :: :ok
  def remove_account!(root, slug) when is_binary(root) and is_binary(slug) do
    accounts = root |> current_accounts() |> Map.delete(slug)
    atomic_write!(mail_yaml_path(root), render(accounts))
    :ok
  end

  @doc """
  Renders the full v5 `config/mail.yaml` bytes for `accounts` (a
  `%{slug => t()}` map, as `load/1`'s ok-map's `accounts:` field) — the
  fixed `safety:` block (`never_expunge: true`, `outbound:
  human_send_and_push`) is always emitted, and a per-account `smtp:` block
  only for an account that has one. String fields go through the
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
    version: 5
    #{accounts_block}safety:
      never_expunge: true
      outbound: human_send_and_push
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
    System.get_env("VALEA_MAIL_PASSWORD_#{env_var_suffix(slug)}")
  end

  @doc """
  The SMTP counterpart of `env_credential/1`:
  `VALEA_MAIL_SMTP_PASSWORD_<SLUG>`. A separate variable on purpose — the
  two secrets are independent (the setup UI's "same as IMAP" writes a COPY
  into the SMTP keychain entry, never an alias), so rotation of one never
  silently moves the other.
  """
  @spec smtp_env_credential(String.t()) :: String.t() | nil
  def smtp_env_credential(slug) when is_binary(slug) do
    System.get_env("VALEA_MAIL_SMTP_PASSWORD_#{env_var_suffix(slug)}")
  end

  defp env_var_suffix(slug), do: slug |> String.upcase() |> String.replace("-", "_")

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

      with {:ok, host} <- fetch_required_string(imap, "imap", "host"),
           {:ok, username} <- fetch_required_string(imap, "imap", "username"),
           {:ok, port} <- fetch_port(imap),
           {:ok, security} <- fetch_imap_security(imap, port),
           {:ok, auth} <- fetch_auth(attrs),
           {:ok, smtp} <- build_smtp(attrs) do
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
           auth: auth,
           oauth_client_id: string_override(Map.get(attrs, "oauth_client_id")),
           tls_cacert_file: string_override(Map.get(attrs, "tls_cacert_file")),
           imap: %{host: host, port: port, security: security, username: username},
           smtp: smtp,
           notifications: Map.get(attrs, "notifications") == true,
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
  defp provider_from_string("microsoft"), do: :microsoft
  defp provider_from_string(_other), do: :generic

  defp fetch_map(attrs, key) do
    case Map.get(attrs, key) do
      m when is_map(m) -> m
      _ -> %{}
    end
  end

  defp fetch_required_string(map, block, key) do
    case Map.fetch(map, key) do
      {:ok, v} when is_binary(v) and v != "" -> {:ok, v}
      {:ok, _other} -> {:error, "#{block}.#{key} must be a non-empty string"}
      :error -> {:error, "#{block}.#{key} is required"}
    end
  end

  defp fetch_port(imap) do
    case Map.fetch(imap, "port") do
      {:ok, v} when is_integer(v) and v > 0 -> {:ok, v}
      {:ok, _other} -> {:error, "imap.port must be a positive integer"}
      :error -> {:ok, @default_port}
    end
  end

  # The IMAP counterpart of `fetch_security/2`, with ONE deliberate
  # difference: an absent key on a non-convention port defaults to `:tls`
  # rather than erroring. Every file written before this key existed ran
  # implicit TLS on whatever port it had (the client knew no other mode), so
  # "absent means implicit" is the back-compat truth, not a guess — except on
  # 143, whose universal convention is STARTTLS and which structurally never
  # worked before. An explicit value is still checked against the 993/143
  # conventions, and an unusable one invalidates the account like `auth:`
  # (there is no plaintext to fall back to, only the WRONG kind of TLS).
  defp fetch_imap_security(imap, port) do
    case Map.get(imap, "security") do
      nil -> {:ok, default_imap_security(port)}
      "starttls" -> check_imap_port_convention(:starttls, port)
      "tls" -> check_imap_port_convention(:tls, port)
      _other -> {:error, ~s(imap.security must be "starttls" or "tls")}
    end
  end

  defp default_imap_security(143), do: :starttls
  defp default_imap_security(_port), do: :tls

  defp check_imap_port_convention(:starttls, 993) do
    {:error, "imap.security starttls contradicts port 993 (993 is tls, 143 is starttls)"}
  end

  defp check_imap_port_convention(:tls, 143) do
    {:error, "imap.security tls contradicts port 143 (143 is starttls, 993 is tls)"}
  end

  defp check_imap_port_convention(security, _port), do: {:ok, security}

  # The one override in this file that does NOT degrade to its default when
  # unusable (see the moduledoc, §The per-account `auth:` mode): a hand-edited
  # `auth: oath2` typo invalidates the account instead of quietly authenticating
  # with a password — which, for an account whose credential slots hold an
  # access token, would put that token in the LOGIN command.
  # `Map.fetch/2`, not `Map.get/2` (same distinction `fetch_port/1` draws): an
  # ABSENT key is the back-compat default, while a key that is PRESENT and
  # empty (`auth:` / `auth: ~`, both `nil` out of YamlElixir) is a hand-edit
  # that says nothing usable — and this is the one field that must not read
  # "nothing usable" as `password`.
  defp fetch_auth(attrs) do
    case Map.fetch(attrs, "auth") do
      {:ok, "password"} -> {:ok, :password}
      {:ok, "oauth2"} -> {:ok, :oauth2}
      {:ok, other} -> {:error, ~s[auth must be "password" or "oauth2", got #{inspect(other)}]}
      :error -> {:ok, :password}
    end
  end

  # The `oauth_client_id` override (M6 task 16), from either side: a YAML
  # value or an `upsert_account!/3` attr. A non-empty string is the override;
  # EVERYTHING else — absent, `nil`, blank, a number a hand-edit left unquoted
  # — is "no override", so the app-config client id applies. Deliberately not
  # an invalidating parse (see the moduledoc): a client id is public and a
  # wrong one only makes the sign-in visibly refuse, so degrading here cannot
  # misroute a secret the way an `auth:` fallback could.
  defp string_override(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp string_override(_value), do: nil

  # -- smtp block (v5) ------------------------------------------------------

  # No `smtp:` key at all is the NORMAL push-only account, not an error; a
  # present-but-not-a-mapping one is a hand-edit worth reporting.
  defp build_smtp(attrs) do
    case Map.get(attrs, "smtp") do
      nil -> {:ok, nil}
      smtp when is_map(smtp) -> parse_smtp(smtp)
      _other -> {:error, "smtp must be a mapping"}
    end
  end

  defp parse_smtp(smtp) do
    with {:ok, host} <- fetch_required_string(smtp, "smtp", "host"),
         {:ok, username} <- fetch_required_string(smtp, "smtp", "username"),
         {:ok, port} <- fetch_smtp_port(smtp),
         {:ok, security} <- fetch_security(smtp, port),
         {:ok, from} <- fetch_from(smtp, username),
         {:ok, from_name} <- fetch_from_name(smtp) do
      {:ok,
       %{
         host: host,
         port: port,
         security: security,
         username: username,
         from: from,
         from_name: from_name
       }}
    end
  end

  defp fetch_smtp_port(smtp) do
    case Map.fetch(smtp, "port") do
      {:ok, v} when is_integer(v) and v > 0 -> {:ok, v}
      {:ok, _other} -> {:error, "smtp.port must be a positive integer"}
      :error -> {:ok, @default_smtp_port}
    end
  end

  # There is no plaintext mode and no `none` value — TLS is mandatory and
  # verified either way (spec G, §Configuration & credentials). `security`
  # only ever picks WHICH TLS: implicit on connect (`:tls`) or a STARTTLS
  # upgrade. 587/465 carry their convention as the default; any other port
  # must say so explicitly rather than have one guessed for it.
  defp fetch_security(smtp, port) do
    case Map.get(smtp, "security") do
      nil -> default_security(port)
      "starttls" -> check_port_convention(:starttls, port)
      "tls" -> check_port_convention(:tls, port)
      _other -> {:error, ~s(smtp.security must be "starttls" or "tls")}
    end
  end

  defp default_security(587), do: {:ok, :starttls}
  defp default_security(465), do: {:ok, :tls}

  defp default_security(port) do
    {:error, "smtp.security is required for port #{port} (only 587 and 465 have a default)"}
  end

  defp check_port_convention(:tls, 587) do
    {:error, "smtp.security tls contradicts port 587 (587 is starttls, 465 is tls)"}
  end

  defp check_port_convention(:starttls, 465) do
    {:error, "smtp.security starttls contradicts port 465 (465 is tls, 587 is starttls)"}
  end

  defp check_port_convention(security, _port), do: {:ok, security}

  # The `From` identity is config-owned, never frontmatter-owned (spec G), so
  # it is validated HERE, once, rather than trusted at composition time: an
  # account whose From isn't a single addr-spec cannot compose a valid message
  # and is invalid outright.
  defp fetch_from(smtp, username) do
    case Map.get(smtp, "from") do
      nil -> check_addr_spec(username)
      "" -> check_addr_spec(username)
      from when is_binary(from) -> check_addr_spec(from)
      _other -> {:error, "smtp.from must be a string"}
    end
  end

  defp check_addr_spec(addr) do
    # ONE address grammar for the whole mail stack — the same predicate the
    # draft's own recipients are judged by (spec G, Task 3).
    if DraftFile.valid_addr_spec?(addr) do
      {:ok, addr}
    else
      {:error, "smtp.from must be a single addr-spec (defaults to smtp.username)"}
    end
  end

  defp fetch_from_name(smtp) do
    case Map.get(smtp, "from_name") do
      nil ->
        {:ok, nil}

      "" ->
        {:ok, nil}

      name when is_binary(name) ->
        # CR/LF/NUL would break out of the encoded display name at header
        # serialization — rejected at the config boundary, never sanitized
        # silently into something the user didn't write.
        if String.contains?(name, ["\r", "\n", <<0>>]) do
          {:error, "smtp.from_name must not contain CR, LF or NUL"}
        else
          {:ok, name}
        end

      _other ->
        {:error, "smtp.from_name must be a string"}
    end
  end

  # -- defaults by provider -------------------------------------------------

  defp default_folders_for(:gmail), do: @gmail_folders
  defp default_folders_for(:microsoft), do: @microsoft_folders
  defp default_folders_for(:generic), do: @default_folders

  defp default_sync_for(:gmail), do: %{@default_sync | exclude_folders: @gmail_excludes}
  # Exchange has no virtual mirror folders, so nothing to exclude.
  defp default_sync_for(:microsoft), do: @default_sync
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
        auth: #{a.auth}
        notifications: #{a.notifications == true}
    #{render_oauth_client_id(a.oauth_client_id)}#{render_tls_cacert_file(a.tls_cacert_file)}    imap:
          host: #{yaml_string(a.imap.host)}
          port: #{a.imap.port}
          security: #{a.imap.security}
          username: #{yaml_string(a.imap.username)}
    #{render_smtp(a.smtp)}    folders:
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

  # Emitted only for an account that actually overrides it, so a file for an
  # account taking the app-config client id keeps its exact previous bytes.
  # Carries its own final indentation for the same reason `render_smtp/1` does.
  defp render_oauth_client_id(nil), do: ""

  defp render_oauth_client_id(client_id),
    do: "    oauth_client_id: #{yaml_string(client_id)}\n"

  # Emitted only when a trust root is pinned, so an ordinary account keeps its
  # exact previous bytes — same posture as `render_oauth_client_id/1`.
  defp render_tls_cacert_file(nil), do: ""

  defp render_tls_cacert_file(path),
    do: "    tls_cacert_file: #{yaml_string(path)}\n"

  # Emitted only for a sending account — a push-only one keeps the v4 shape
  # exactly (no empty `smtp:` key). Every line carries its own final
  # indentation because it is interpolated into `render_account/2`'s heredoc
  # at column 0.
  defp render_smtp(nil), do: ""

  defp render_smtp(smtp) do
    """
        smtp:
          host: #{yaml_string(smtp.host)}
          port: #{smtp.port}
          security: #{smtp.security}
          username: #{yaml_string(smtp.username)}
          from: #{yaml_string(smtp.from)}
    """ <> render_from_name(smtp.from_name)
  end

  defp render_from_name(nil), do: ""
  defp render_from_name(from_name), do: "      from_name: #{yaml_string(from_name)}\n"

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
