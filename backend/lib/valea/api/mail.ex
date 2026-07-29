defmodule Valea.Api.Mail do
  @moduledoc """
  Data-layer-less Ash resource exposing the per-account mail engines and
  their indexed messages over RPC (mail-as-maildir design spec E, §RPC
  surface). Every action takes an explicit `account` slug argument — there
  is no more implicit "the one configured account": `Valea.Mail.Engine` is
  per-slug (`Valea.Mail.Registry`-keyed) since Task 9, and this resource is
  the RPC-facing wrapper matching that one-for-one.

  Follows `Valea.Api.ICM`'s conventions throughout:

    * `constraints fields: [...]` typed actions for structured returns
      (`list_mail_messages`, `list_mail_folders`, `mail_apply_ops`),
      UNCONSTRAINED `:map`/`{:array, :map}` for raw or heterogeneous
      passthrough (`mail_status`'s `accounts` — valid entries carry the full
      `Valea.Mail.Engine.status/1` shape, invalid-config entries carry only
      `account`/`valid`/`state`/`reason`; `mail_doctor`'s `checks`;
      `get_mail_message`'s `message`) — string keys, no camelCase
      translation, same typed-vs-unconstrained split as `Valea.Api.ICM`'s
      moduledoc.
    * The SAME top-level generic-action boolean/falsy-map-field bug
      previously documented in the deleted `Valea.Api.Queue`'s moduledoc
      (ash_typescript 0.17.3 nulls a top-level atom-keyed field whose value
      is `false`): every action here that can genuinely return `false` at
      the top level uses a STRING key for that field (`saved`, `removed`,
      `purged`, `readopted`, `discarded`, `accepted`, `started`, `ok`).
    * Every MUTATING action takes a `generation` argument and guards with
      `Valea.Workspace.Manager.check_generation/1` before touching
      anything. Read-only actions (`mail_status`, `list_mail_messages`,
      `search_mail`, `list_mail_folders`, `get_mail_message`) take no
      `generation`, but still resolve `Manager.current/0` before touching
      the Engine/Store.
    * Every action that takes an `account` argument validates its grammar
      FIRST (`Valea.Mail.Settings.valid_slug?/1`, via `validate_slug/1`
      below) — before it is ever interpolated into a filesystem path
      (`Valea.Mail.Account`'s `.account`/`.readopt` paths,
      `get_mail_message`'s view path). A malformed slug (`"../x"`, an
      absolute path, anything outside `^[a-z0-9][a-z0-9-]{0,31}$`) is
      rejected as `"invalid_slug"` before any I/O, never left to whatever a
      downstream path-join happens to do with it.

  ## `get_mail_message`'s `msg_id` containment

  `msg_id` must match `^[0-9]{4}-[0-9]{2}-[0-9]{2}-[a-z0-9-]+-[0-9a-f]{8,64}$`
  (rejected otherwise, before any file I/O — this alone already rules out a
  `../`-laden or absolute-path value, since neither can match the pattern).
  The view file is then resolved via `Valea.Paths.resolve_real/2` — NEVER
  weakened, called exactly as every other containment chokepoint in this
  codebase calls it — rooted at `sources/mail/<account>/views/messages/`,
  so a symlinked view file whose target escapes that directory is rejected
  (`{:error, :outside}`) exactly like a real traversal attempt, never
  followed and read.

  ## `search_mail`'s `query`

  The argument is free text a human typed, and it never becomes FTS5 query
  syntax. `Valea.Mail.Store.match_expression/1` is the single chokepoint:
  it tokenizes the string into runs of letters/digits and re-emits each as a
  double-quoted prefix term, so boolean/proximity keywords (`OR`, `NEAR`),
  column filters (`subject:foo`), negation (`-foo`), and any embedded or
  unbalanced `"` are all reduced to ordinary search words rather than
  escaped — nothing this action passes down can widen, redirect, or break
  out of the query. See that function's docs.

  ## Why `remove_mail_account`/`purge_mail_account_files` clear `mail_search`

  `mail_search` is the first thing this app persists MESSAGE BODY TEXT into
  `app.sqlite`. That makes the account-teardown actions load-bearing in a way
  they weren't when the leftover cache held only metadata:

    * `purge_mail_account_files` deletes `sources/mail/<slug>` — after which
      the search index would be the LAST remaining copy of those bodies, and
      `search_mail` on the purged slug would still answer with body snippets.
      "Purge my mail files" is a promise a user reads literally, so the rows
      go with the files.
    * `remove_mail_account` leaves the files alone (purge is the separate,
      confirmation-gated action) but drops the account from `config/mail.yaml`
      — so its rows become cache for an account that no longer exists, still
      reachable by slug through `search_mail`. They are cleared too, and
      nothing is lost by it: the view files on disk are the source of truth,
      and re-adding the account re-activates its Engine, whose `do_activate`
      runs `Valea.Mail.Index.rebuild/2` and re-feeds every row.

  Neither clears `mail_messages`/`mail_uid_map`/`mail_sync_state`; that
  metadata-cache gap predates the search index and is tracked separately.

  ## `set_mail_credential`'s `kind`

  `kind` selects which of the account's TWO credential slots the secret
  fills — `"imap"` (the default when the argument is omitted, i.e. what
  every caller predating settings v5 means) or `"smtp"`. They are separate
  secrets with separate keychain entries; the setup UI's "same as IMAP"
  sends the same value twice, as a copy. An unknown value is rejected
  (`"invalid_credential_kind"`) — never `String.to_atom/1`'d.

  ## `set_mail_credential`'s secret

  The `secret` argument is marked `sensitive? true` (the standard Ash
  option — see `Ash.Resource.Actions.Argument`). Concretely, this app's
  `config :ash, redact_sensitive_values_in_errors?: true` (config.exs) makes
  `Ash.Resource.Validation.maybe_redact/3` scrub any `sensitive?: true`
  field's value out of an error a *validation* builds against it — this
  action declares no such validation on `secret`, so that path is dormant
  here, but the flag keeps the action correct/forward-compatible and
  documents the field's status either way. The `run` callback itself never
  echoes it back, and `Valea.Mail.Engine` holds it only as a zero-arity
  closure in process state (see that module's moduledoc).

  ## `revise_mail_draft` and agent sessions

  This is the one action here that reaches outside mail — it prompts or
  creates an agent session so the human's feedback reaches whatever is
  writing the draft. It is deliberately the INBOUND direction only: it
  creates `kind: "chat"` sessions scoped exactly like every other mail
  session (the account's mount included read-only, plus one exact read
  grant for the draft) and prompts them, and nothing about it hands a
  session a route to `send_draft`/`push_draft_to_mailbox` — those live on
  this control-token-gated RPC surface, which agent sessions have no
  transport to.

  Which session gets the feedback is decided by CORRELATION, never by the
  caller: a LIVE session whose own input locator already NAMES this draft
  (`Valea.Agents.list_running_session_inputs/0`) gets it as another turn, so
  a second round of changes continues the conversation instead of forking a
  new one. Only with no such session is one created.

  Matching is on the DECLARED path, not on where that path currently
  resolves to — see `locator_names_draft?/4`. Symlink-following comparison
  would let anything able to write a live session's input file redirect it
  at a draft and claim that draft's feedback; a declared path is a name, and
  a name cannot be repointed after the fact.

  ## Stubs

  `mail_apply_ops` (Task 13 wires the real ops executor), `push_draft_to_mailbox`
  and `list_mail_drafts` (Task 15) are declared now so their exact shapes are
  fixed and ash_typescript codegen only churns once — each `run` callback
  is a fixed, honest stub (never silently "succeeds").
  """
  use Ash.Resource, domain: Valea.Api, extensions: [AshTypescript.Resource]

  typescript do
    type_name("Mail")
  end

  alias Valea.Agents.SessionScope
  alias Valea.Agents.SessionServer
  alias Valea.Api.Error
  alias Valea.Mail.Account
  alias Valea.Mail.Autoconfig
  alias Valea.Mail.DraftFile
  alias Valea.Mail.Engine
  alias Valea.Mail.HtmlSanitizer
  alias Valea.Mail.MessageFile
  alias Valea.Mail.Normalizer
  alias Valea.Mail.Trust
  alias Valea.Mail.OpsExecutor
  alias Valea.Mail.Reconcile
  alias Valea.Mail.Settings
  alias Valea.Mail.Store
  alias Valea.Mail.Supervisor, as: MailSupervisor
  alias Valea.Mail.Views
  alias Valea.Paths
  alias Valea.Workspace.Manager

  @msg_id_re ~r/^[0-9]{4}-[0-9]{2}-[0-9]{2}-[a-z0-9-]+-[0-9a-f]{8,64}$/

  actions do
    # -- status -----------------------------------------------------------

    action :mail_status, :map do
      constraints fields: [accounts: [type: {:array, :map}, allow_nil?: false]]

      run fn _input, _ctx ->
        with {:ok, %{path: root}} <- Manager.current() do
          {:ok, %{accounts: mail_status_accounts(root)}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    # -- account lifecycle --------------------------------------------------

    action :setup_mail_account, :map do
      constraints fields: [saved: [type: :boolean, allow_nil?: false]]

      argument :account, :string, allow_nil?: false
      argument :host, :string, allow_nil?: false
      argument :port, :integer, allow_nil?: false, constraints: [min: 1]
      argument :username, :string, allow_nil?: false
      argument :generation, :integer, allow_nil?: false

      # The optional v5 SMTP block, flat (this resource's argument style is
      # flat throughout, never nested maps). ALL of them blank/absent = a
      # push-only account, which is the v4 behaviour verbatim. Any of them
      # present builds the block, validated by `Settings` — an invalid one is
      # REFUSED (`"invalid_smtp"`) rather than written, since a rendered-but-
      # unloadable smtp block would invalidate the whole account, IMAP sync
      # included.
      argument :smtp_host, :string, allow_nil?: true
      argument :smtp_port, :integer, allow_nil?: true, constraints: [min: 1]
      argument :smtp_security, :string, allow_nil?: true
      argument :smtp_username, :string, allow_nil?: true
      argument :smtp_from, :string, allow_nil?: true
      argument :smtp_from_name, :string, allow_nil?: true

      run fn input, _ctx ->
        %{
          account: slug,
          host: host,
          port: port,
          username: username,
          generation: generation
        } = input.arguments

        attrs = %{
          host: host,
          port: port,
          username: username,
          smtp: smtp_attrs(input.arguments)
        }

        with :ok <- Manager.check_generation(generation),
             {:ok, %{path: root}} <- Manager.current(),
             :ok <- validate_slug(slug),
             :ok <- check_identity_for_setup(root, slug, host, username),
             :ok <- Settings.upsert_account!(root, slug, attrs) do
          :ok = MailSupervisor.reload_settings_all(root)
          {:ok, %{"saved" => true}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :get_mail_account_settings, :map do
      # The non-secret config of one account, for the settings form's EDIT
      # mode (prefill) — passwords never live in `config/mail.yaml`, so
      # nothing here can leak one. `security` is stringified from the
      # settings atom (`:starttls`/`:tls`).
      constraints fields: [
                    account: [
                      type: :map,
                      allow_nil?: false,
                      constraints: [
                        fields: [
                          host: [type: :string, allow_nil?: false],
                          port: [type: :integer, allow_nil?: false],
                          username: [type: :string, allow_nil?: false],
                          smtp: [
                            type: :map,
                            allow_nil?: true,
                            constraints: [
                              fields: [
                                host: [type: :string, allow_nil?: false],
                                port: [type: :integer, allow_nil?: false],
                                security: [type: :string, allow_nil?: false],
                                username: [type: :string, allow_nil?: false],
                                from: [type: :string, allow_nil?: true],
                                from_name: [type: :string, allow_nil?: true]
                              ]
                            ]
                          ]
                        ]
                      ]
                    ]
                  ]

      argument :account, :string, allow_nil?: false

      run fn input, _ctx ->
        %{account: slug} = input.arguments

        with :ok <- validate_slug(slug),
             {:ok, %{path: root}} <- Manager.current(),
             {:ok, %{accounts: accounts}} <- Settings.load(root),
             %Settings{} = settings <- Map.get(accounts, slug) || {:error, :not_found} do
          {:ok, %{account: account_settings_payload(settings)}}
        else
          {:error, {:invalid, _reason}} -> {:error, error_for(:not_found)}
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :mail_autoconfig, :map do
      # Settings discovery for the setup form (`Valea.Mail.Autoconfig`):
      # short-timeout ISPDB/DNS probing, best-effort — an all-nil answer just
      # leaves the form manual. No generation guard: this reads no workspace
      # state and writes nothing.
      constraints fields: [
                    imap: [
                      type: :map,
                      allow_nil?: true,
                      constraints: [
                        fields: [
                          host: [type: :string, allow_nil?: false],
                          port: [type: :integer, allow_nil?: false],
                          security: [type: :string, allow_nil?: false]
                        ]
                      ]
                    ],
                    smtp: [
                      type: :map,
                      allow_nil?: true,
                      constraints: [
                        fields: [
                          host: [type: :string, allow_nil?: false],
                          port: [type: :integer, allow_nil?: false],
                          security: [type: :string, allow_nil?: false]
                        ]
                      ]
                    ],
                    source: [type: :string, allow_nil?: true]
                  ]

      argument :email, :string, allow_nil?: false

      run fn input, _ctx ->
        case Autoconfig.discover(input.arguments.email) do
          {:ok, result} -> {:ok, result}
          {:error, :invalid_email} -> {:error, Error.new("invalid_email")}
        end
      end
    end

    action :remove_mail_account, :map do
      constraints fields: [removed: [type: :boolean, allow_nil?: false]]

      argument :account, :string, allow_nil?: false
      argument :generation, :integer, allow_nil?: false

      run fn input, _ctx ->
        %{account: slug, generation: generation} = input.arguments

        with :ok <- Manager.check_generation(generation),
             {:ok, %{path: root}} <- Manager.current(),
             :ok <- validate_slug(slug),
             :ok <- Settings.remove_account!(root, slug) do
          :ok = MailSupervisor.reload_settings_all(root)
          :ok = Store.clear_search_rows(slug)
          {:ok, %{"removed" => true}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :purge_mail_account_files, :map do
      constraints fields: [purged: [type: :boolean, allow_nil?: false]]

      argument :account, :string, allow_nil?: false
      argument :confirmation, :string, allow_nil?: false
      argument :generation, :integer, allow_nil?: false

      run fn input, _ctx ->
        %{account: slug, confirmation: confirmation, generation: generation} = input.arguments

        with :ok <- Manager.check_generation(generation),
             {:ok, %{path: root}} <- Manager.current(),
             :ok <- validate_slug(slug),
             :ok <- require_confirmation(confirmation, slug),
             :ok <- ensure_purge_allowed(slug),
             {:ok, target} <- Paths.resolve_real(slug, Path.join([root, "sources", "mail"])) do
          File.rm_rf!(target)
          :ok = Store.clear_search_rows(slug)
          {:ok, %{"purged" => true}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :readopt_mail_account, :map do
      constraints fields: [readopted: [type: :boolean, allow_nil?: false]]

      argument :account, :string, allow_nil?: false
      argument :confirmation, :string, allow_nil?: false
      argument :generation, :integer, allow_nil?: false

      run fn input, _ctx ->
        %{account: slug, confirmation: confirmation, generation: generation} = input.arguments

        with :ok <- Manager.check_generation(generation),
             :ok <- validate_slug(slug),
             :ok <- require_confirmation(confirmation, slug),
             :ok <- Engine.readopt(slug) do
          {:ok, %{"readopted" => true}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :discard_held_folder, :map do
      constraints fields: [discarded: [type: :boolean, allow_nil?: false]]

      argument :account, :string, allow_nil?: false
      argument :folder, :string, allow_nil?: false
      argument :confirmation, :string, allow_nil?: false
      argument :generation, :integer, allow_nil?: false

      run fn input, _ctx ->
        %{
          account: slug,
          folder: folder,
          confirmation: confirmation,
          generation: generation
        } = input.arguments

        with :ok <- Manager.check_generation(generation),
             {:ok, %{path: root}} <- Manager.current(),
             :ok <- validate_slug(slug),
             :ok <- require_confirmation(confirmation, folder),
             :ok <- Reconcile.discard_held!(root, slug, folder) do
          {:ok, %{"discarded" => true}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :set_mail_credential, :map do
      constraints fields: [accepted: [type: :boolean, allow_nil?: false]]

      argument :account, :string, allow_nil?: false
      argument :secret, :string, allow_nil?: false, sensitive?: true
      # Which credential slot this secret fills: `"imap"` (the default, and
      # what every pre-v5 caller means) or `"smtp"`. The two are independent
      # secrets with separate keychain entries — "same as IMAP" in the setup
      # UI sends the same value twice, as a copy.
      argument :kind, :string, allow_nil?: true
      argument :generation, :integer, allow_nil?: false

      run fn input, _ctx ->
        %{account: slug, secret: secret, generation: generation} = input.arguments

        with :ok <- Manager.check_generation(generation),
             :ok <- validate_slug(slug),
             {:ok, kind} <- credential_kind(input.arguments[:kind]),
             :ok <- Engine.set_credential(slug, secret, kind) do
          {:ok, %{"accepted" => true}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    # -- sync / doctor --------------------------------------------------------

    action :mail_sync_now, :map do
      constraints fields: [started: [type: :boolean, allow_nil?: false]]

      argument :account, :string, allow_nil?: false
      argument :generation, :integer, allow_nil?: false

      run fn input, _ctx ->
        %{account: slug, generation: generation} = input.arguments

        with :ok <- Manager.check_generation(generation),
             :ok <- validate_slug(slug),
             :ok <- Engine.sync_now(slug) do
          {:ok, %{"started" => true}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :mail_doctor, :map do
      constraints fields: [
                    ok: [type: :boolean, allow_nil?: false],
                    checks: [type: {:array, :map}, allow_nil?: false]
                  ]

      argument :account, :string, allow_nil?: false
      argument :generation, :integer, allow_nil?: false

      run fn input, _ctx ->
        %{account: slug, generation: generation} = input.arguments

        with :ok <- Manager.check_generation(generation),
             :ok <- validate_slug(slug),
             {:ok, %{checks: checks, ok: ok}} <- Engine.doctor(slug) do
          {:ok, %{"ok" => ok, "checks" => checks}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :create_mail_folders, :map do
      constraints fields: [created: [type: {:array, :string}, allow_nil?: false]]

      argument :account, :string, allow_nil?: false
      argument :generation, :integer, allow_nil?: false

      run fn input, _ctx ->
        %{account: slug, generation: generation} = input.arguments

        with :ok <- Manager.check_generation(generation),
             :ok <- validate_slug(slug),
             {:ok, created} <- Engine.create_folders(slug) do
          {:ok, %{created: created}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    # -- messages / folders (read-only) -------------------------------------

    action :list_mail_messages, :map do
      constraints fields: [
                    messages: [
                      type: {:array, :map},
                      allow_nil?: false,
                      constraints: [
                        items: [
                          fields: [
                            msg_id: [type: :string, allow_nil?: false],
                            from_name: [type: :string, allow_nil?: true],
                            from_email: [type: :string, allow_nil?: true],
                            subject: [type: :string, allow_nil?: true],
                            date: [type: :string, allow_nil?: true],
                            flags: [type: :string, allow_nil?: true],
                            has_attachments: [type: :boolean, allow_nil?: false],
                            uid: [type: :integer, allow_nil?: true],
                            path: [type: :string, allow_nil?: true],
                            view_path: [type: :string, allow_nil?: false]
                          ]
                        ]
                      ]
                    ]
                  ]

      argument :account, :string, allow_nil?: false
      argument :folder, :string, allow_nil?: false
      argument :limit, :integer, allow_nil?: true, constraints: [min: 1]
      argument :before, :string, allow_nil?: true

      run fn input, _ctx ->
        %{account: slug, folder: folder} = input.arguments
        limit = input.arguments[:limit] || 100
        before = input.arguments[:before]

        with :ok <- validate_slug(slug),
             {:ok, _ws} <- Manager.current() do
          messages =
            slug
            |> Store.list_messages(folder, limit, before)
            |> Enum.map(&message_summary(slug, &1))

          {:ok, %{messages: messages}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    # Full-text search across ONE account's landed messages — the RPC half
    # of `mail_search` (the FTS5 index fed by `Valea.Mail.Views`/
    # `Valea.Mail.Index`). Read-only, so no `generation`; `account` is
    # slug-validated before any I/O like everywhere else here.
    #
    # `messages` is deliberately the SAME per-row shape `list_mail_messages`
    # returns, plus `snippet` — a hit renders through the same list
    # components as a folder listing, so the two must not drift.
    action :search_mail, :map do
      constraints fields: [
                    messages: [
                      type: {:array, :map},
                      allow_nil?: false,
                      constraints: [
                        items: [
                          fields: [
                            msg_id: [type: :string, allow_nil?: false],
                            from_name: [type: :string, allow_nil?: true],
                            from_email: [type: :string, allow_nil?: true],
                            subject: [type: :string, allow_nil?: true],
                            date: [type: :string, allow_nil?: true],
                            flags: [type: :string, allow_nil?: true],
                            has_attachments: [type: :boolean, allow_nil?: false],
                            uid: [type: :integer, allow_nil?: true],
                            path: [type: :string, allow_nil?: true],
                            view_path: [type: :string, allow_nil?: false],
                            snippet: [type: :string, allow_nil?: true]
                          ]
                        ]
                      ]
                    ]
                  ]

      argument :account, :string, allow_nil?: false
      # `allow_empty?` so a caller that sends the search box's current
      # contents doesn't get an "argument is required" error the moment the
      # user clears it — an empty query is a legitimate "nothing to search
      # for" that comes back as an empty result list (Ash otherwise casts
      # `""` to `nil`, which `allow_nil?: false` then rejects).
      argument :query, :string, allow_nil?: false, constraints: [allow_empty?: true]
      argument :limit, :integer, allow_nil?: true, constraints: [min: 1]

      run fn input, _ctx ->
        %{account: slug, query: query} = input.arguments
        limit = input.arguments[:limit] || 40

        with :ok <- validate_slug(slug),
             {:ok, _ws} <- Manager.current() do
          # `Store.search/3` owns the whole query path: it transforms the
          # user string into quoted prefix terms (no FTS5 syntax is ever
          # reachable from here), short-circuits an empty/oversized query to
          # `[]`, and clamps `limit`.
          messages =
            slug
            |> Store.search(query, limit)
            |> Enum.flat_map(&search_hit(slug, &1))

          {:ok, %{messages: messages}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :list_mail_folders, :map do
      constraints fields: [
                    folders: [
                      type: {:array, :map},
                      allow_nil?: false,
                      constraints: [
                        items: [
                          fields: [
                            name: [type: :string, allow_nil?: false],
                            dir: [type: :string, allow_nil?: true],
                            held: [type: :boolean, allow_nil?: false],
                            message_count: [type: :integer, allow_nil?: false],
                            backfill_complete: [type: :boolean, allow_nil?: false]
                          ]
                        ]
                      ]
                    ]
                  ]

      argument :account, :string, allow_nil?: false

      run fn input, _ctx ->
        %{account: slug} = input.arguments

        with :ok <- validate_slug(slug),
             {:ok, _ws} <- Manager.current() do
          folders = slug |> Store.folders() |> Enum.map(&folder_summary(slug, &1))
          {:ok, %{folders: folders}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :get_mail_message, :map do
      constraints fields: [message: [type: :map, allow_nil?: false]]

      argument :account, :string, allow_nil?: false
      argument :msg_id, :string, allow_nil?: false

      run fn input, _ctx ->
        %{account: slug, msg_id: msg_id} = input.arguments

        with :ok <- validate_slug(slug),
             :ok <- validate_msg_id(msg_id),
             {:ok, %{path: root}} <- Manager.current(),
             views_dir = Path.join([root, "sources", "mail", slug, "views", "messages"]),
             {:ok, resolved} <- Paths.resolve_real("#{msg_id}.md", views_dir),
             {:ok, bytes} <- File.read(resolved),
             {:ok, %{frontmatter: frontmatter, body: body}} <- MessageFile.parse(bytes) do
          rel_path = Views.view_rel_path(slug, msg_id)

          # HTML rendering (sanitized; nil when the message has no usable
          # text/html part) + the trust gate the frontend's remote-content
          # banner keys off. String keys inside the unconstrained `message`
          # map, so the legitimate `false` values survive delivery.
          message =
            %{"frontmatter" => frontmatter, "body" => body, "path" => rel_path}
            |> Map.merge(message_html(root, slug, msg_id))
            |> Map.put("sender_trusted", Trust.trusted?(root, sender_email(frontmatter)))

          {:ok, %{"message" => message}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :list_trusted_mail_senders, :map do
      constraints fields: [senders: [type: {:array, :string}, allow_nil?: false]]

      run fn _input, _ctx ->
        with {:ok, %{path: root}} <- Manager.current() do
          {:ok, %{senders: Trust.list(root)}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :set_mail_sender_trust, :map do
      # `"trusted"` echoes the new state under a STRING key — it is
      # legitimately `false` on an untrust (the falsy-map-field rule from
      # the moduledoc).
      constraints fields: [trusted: [type: :boolean, allow_nil?: false]]

      argument :email, :string, allow_nil?: false
      argument :trusted, :boolean, allow_nil?: false
      argument :generation, :integer, allow_nil?: false

      run fn input, _ctx ->
        %{email: email, trusted: trusted, generation: generation} = input.arguments

        with :ok <- Manager.check_generation(generation),
             {:ok, %{path: root}} <- Manager.current(),
             :ok <- Trust.set_trusted(root, email, trusted) do
          {:ok, %{"trusted" => trusted}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    # -- stubs (fixed shape now, real bodies land in later tasks) -----------

    action :mail_apply_ops, :map do
      constraints fields: [
                    results: [
                      type: {:array, :map},
                      allow_nil?: false,
                      constraints: [
                        items: [
                          fields: [
                            op: [type: :integer, allow_nil?: false],
                            result: [type: :string, allow_nil?: false],
                            reason: [type: :string, allow_nil?: true]
                          ]
                        ]
                      ]
                    ]
                  ]

      argument :account, :string, allow_nil?: false
      argument :ops, {:array, :map}, allow_nil?: false
      argument :generation, :integer, allow_nil?: false

      # The UI's archive/move/flag actions, executed through the SAME ops
      # executor as ops files, serialized through the account's Engine (spec
      # §RPC surface). Returns per-op results synchronously (frozen shape).
      run fn input, _ctx ->
        %{account: slug, ops: ops, generation: generation} = input.arguments

        with :ok <- Manager.check_generation(generation),
             :ok <- validate_slug(slug) do
          case Engine.apply_ops(slug, ops) do
            {:ok, results} -> {:ok, %{results: results}}
            # A gating failure (no engine/credential, blocked, inactive) maps
            # to per-op rejections so the results array stays populated rather
            # than surfacing a bare RPC error the per-op UI can't attribute.
            {:error, reason} -> {:ok, %{results: reject_all_ops(ops, to_string(reason))}}
          end
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :push_draft_to_mailbox, :map do
      constraints fields: [state: [type: :string, allow_nil?: false]]

      argument :account, :string, allow_nil?: false
      argument :draft_name, :string, allow_nil?: false
      argument :content_hash, :string, allow_nil?: false
      argument :generation, :integer, allow_nil?: false

      # One of the TWO user-initiated outbound actions (spec E §Drafting &
      # push; `send_draft` below is the other). The invariant both serve:
      # Valea transmits mail only on an explicit human action, hash-bound to
      # the exact draft the human reviewed — agents have no transport to this
      # RPC surface at all, and nothing here retransmits
      # (docs/superpowers/specs/2026-07-26-mail-smtp-send-design.md,
      # §Invariant rewrite + §Safety invariants).
      #
      # Serialized through the account's Engine (`Engine.push_draft/3`):
      # atomic claim + hash-bound snapshot + compose + fsynced spool, then the
      # idempotent APPEND into the account's own Drafts folder. Returns the
      # resulting draft display state
      # (`pushing`/`pushed`/`needs_review`/`rejected`).
      run fn input, _ctx ->
        %{
          account: slug,
          draft_name: draft_name,
          content_hash: content_hash,
          generation: generation
        } = input.arguments

        with :ok <- Manager.check_generation(generation),
             {:ok, _ws} <- Manager.current(),
             :ok <- validate_slug(slug),
             {:ok, state} <- Engine.push_draft(slug, draft_name, content_hash) do
          {:ok, %{"state" => state}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    # -- send (spec G) ------------------------------------------------------

    action :get_mail_draft_review, :map do
      constraints fields: [
                    content: [type: :string, allow_nil?: false],
                    content_hash: [type: :string, allow_nil?: false],
                    recipients: [type: :map, allow_nil?: false],
                    subject: [type: :string, allow_nil?: false],
                    attachments: [type: {:array, :map}, allow_nil?: false],
                    threading: [type: :map, allow_nil?: true],
                    threading_warning: [type: :boolean, allow_nil?: false],
                    identity: [type: :map, allow_nil?: false],
                    review_fingerprint: [type: :string, allow_nil?: true],
                    smtp_configured: [type: :boolean, allow_nil?: false]
                  ]

      argument :account, :string, allow_nil?: false
      argument :draft_name, :string, allow_nil?: false

      # THE atomic review snapshot behind the send confirm modal (spec G §RPC
      # surface). ONE no-follow read inside the account's Engine call, under
      # the same captured settings `send_draft` will be checked against:
      # everything the human sees — recipients, subject, attachments,
      # threading, sending identity — and BOTH tokens they confirm with
      # (`content_hash`, `review_fingerprint`) come out of that single buffer.
      # Read-only: it claims nothing and touches no network.
      #
      # `attachments` is `[{filename, path, bytes}]`, resolved and read at
      # this instant; their CONTENT hashes ride `review_fingerprint`, so a
      # file rewritten between this call and the confirm comes back
      # `re_review_required` rather than going out unreviewed.
      run fn input, _ctx ->
        %{account: slug, draft_name: draft_name} = input.arguments

        with {:ok, _ws} <- Manager.current(),
             :ok <- validate_slug(slug),
             {:ok, review} <- Engine.draft_review(slug, draft_name) do
          {:ok, review}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :send_draft, :map do
      constraints fields: [state: [type: :string, allow_nil?: false]]

      argument :account, :string, allow_nil?: false
      argument :draft_name, :string, allow_nil?: false
      argument :content_hash, :string, allow_nil?: false
      argument :review_fingerprint, :string, allow_nil?: true
      argument :generation, :integer, allow_nil?: false

      # The one action in this codebase that transmits (spec G §Send
      # pipeline) — human-only by construction: this surface is
      # control-token-gated and agent sessions have no transport to it.
      # Serialized through the account's Engine, which re-derives the review
      # fingerprint from ITS captured settings and refuses
      # `re_review_required` before any claim, spool write, or composition.
      run fn input, _ctx ->
        %{
          account: slug,
          draft_name: draft_name,
          content_hash: content_hash,
          generation: generation
        } = input.arguments

        with :ok <- Manager.check_generation(generation),
             {:ok, _ws} <- Manager.current(),
             :ok <- validate_slug(slug),
             {:ok, state} <-
               Engine.send_draft(
                 slug,
                 draft_name,
                 content_hash,
                 input.arguments[:review_fingerprint]
               ) do
          {:ok, %{"state" => state}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :resolve_send_review, :map do
      constraints fields: [resolved: [type: :boolean, allow_nil?: false]]

      argument :account, :string, allow_nil?: false
      argument :op_id, :string, allow_nil?: false
      # Closed vocabulary, twice: rejected at the Ash boundary by the match
      # constraint, and mapped to an atom by `send_resolution/1`'s closed
      # clauses — RPC input is never `String.to_atom/1`'d (same posture as
      # `set_mail_credential`'s `kind`).
      argument :resolution, :string,
        allow_nil?: false,
        constraints: [match: ~r/^(sent|not_sent)$/]

      argument :generation, :integer, allow_nil?: false

      # The human's verdict on a send parked in `send_review` (spec G §Send
      # pipeline 4). `sent` runs the idempotent Sent copy and completes the
      # op; `not_sent` rejects it and reverts the draft for another explicit
      # click. Neither transmits.
      run fn input, _ctx ->
        %{
          account: slug,
          op_id: op_id,
          resolution: resolution,
          generation: generation
        } = input.arguments

        with :ok <- Manager.check_generation(generation),
             {:ok, _ws} <- Manager.current(),
             :ok <- validate_slug(slug),
             {:ok, verdict} <- send_resolution(resolution),
             :ok <- Engine.resolve_send_review(slug, op_id, verdict) do
          {:ok, %{"resolved" => true}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :retry_sent_copy, :map do
      constraints fields: [retried: [type: :boolean, allow_nil?: false]]

      argument :account, :string, allow_nil?: false
      argument :op_id, :string, allow_nil?: false
      argument :generation, :integer, allow_nil?: false

      # Re-runs ONLY the idempotent Sent-copy append of a send that completed
      # with a `sent_copy_failed` notice — the mail is already transmitted,
      # and this path cannot reach the SMTP transport at all.
      run fn input, _ctx ->
        %{account: slug, op_id: op_id, generation: generation} = input.arguments

        with :ok <- Manager.check_generation(generation),
             {:ok, _ws} <- Manager.current(),
             :ok <- validate_slug(slug),
             :ok <- Engine.retry_sent_copy(slug, op_id) do
          {:ok, %{"retried" => true}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :list_mail_drafts, :map do
      constraints fields: [drafts: [type: {:array, :map}, allow_nil?: false]]

      # Every account's drafts with their LEDGER-derived display state (never
      # the frontmatter's — an agent-forged `status: pushed` with no ledger op
      # renders `draft` with a `status_forged` notice) and their parsed
      # recipients (parse errors surface as `invalid`).
      run fn _input, _ctx ->
        with {:ok, %{path: root}} <- Manager.current() do
          {:ok, %{drafts: list_all_drafts(root)}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :revise_mail_draft, :map do
      constraints fields: [
                    session_id: [type: :string, allow_nil?: false],
                    routed: [type: :string, allow_nil?: false]
                  ]

      argument :account, :string, allow_nil?: false
      argument :draft_name, :string, allow_nil?: false
      argument :feedback, :string, allow_nil?: false
      # The ICM that HOSTS the session when a new one has to be started —
      # never where the draft lives (that is always the account's own mail
      # mount, included by key below). Unused on the routing path.
      argument :mount_key, :string, allow_nil?: false
      argument :generation, :integer, allow_nil?: false

      # "Request changes" (spec G §UI): hand the human's feedback to an
      # agent, which edits the draft file in place. The one thing this must
      # get right is CORRELATION — a user who asks for a second round of
      # changes means "keep going", not "start over" — so a LIVE session
      # whose own input locator already resolves to this exact draft gets the
      # feedback as another turn, and only when there is none is a session
      # created (scoped exactly like every other mail session: the account
      # mounted read-only via `include_mounts`, plus ONE exact read grant for
      # the draft itself).
      #
      # Creating or prompting a chat session is the whole of what this does.
      # It never reaches `send_draft`/`push_draft_to_mailbox` — those live on
      # this control-token-gated RPC surface, which agent sessions have no
      # transport to, and nothing here hands one out.
      run fn input, _ctx ->
        %{
          account: slug,
          draft_name: name,
          feedback: feedback,
          mount_key: mount_key,
          generation: generation
        } = input.arguments

        with :ok <- Manager.check_generation(generation),
             {:ok, %{path: root}} <- Manager.current(),
             :ok <- validate_slug(slug),
             :ok <- validate_draft_name(name),
             {:ok, draft_abs} <- existing_draft_path(root, slug, name),
             {:ok, routed} <-
               route_revision(%{
                 root: root,
                 slug: slug,
                 name: name,
                 feedback: feedback,
                 draft_abs: draft_abs,
                 mount_key: mount_key,
                 generation: generation
               }) do
          {:ok, routed}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :get_mail_draft, :map do
      constraints fields: [
                    content: [type: :string, allow_nil?: false],
                    path: [type: :string, allow_nil?: false]
                  ]

      argument :account, :string, allow_nil?: false
      argument :draft_name, :string, allow_nil?: false

      # Reads one draft's raw bytes for the push flow: the UI hashes EXACTLY
      # what it fetched (sha256 hex, `DraftFile.content_hash/1`'s encoding)
      # and binds `push_draft_to_mailbox` to that revision — the CAS contract
      # only means something if the hash covers the bytes the USER reviewed.
      # `draft_name` is a bare basename (separator/traversal rejected before
      # any path construction); the read is no-follow, same posture as the
      # listing and push paths.
      run fn input, _ctx ->
        %{account: slug, draft_name: name} = input.arguments

        with {:ok, %{path: root}} <- Manager.current(),
             :ok <- validate_slug(slug),
             :ok <- validate_draft_name(name),
             {:ok, content} <- read_draft_raw(root, slug, name) do
          {:ok, %{content: content, path: draft_rel_path(slug, name)}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :write_mail_draft, :map do
      # `saved` is a top-level boolean, so it goes back under a STRING key
      # (the falsy-map-field rule from the moduledoc) — as does `name`, which
      # travels with it.
      constraints fields: [
                    name: [type: :string, allow_nil?: false],
                    saved: [type: :boolean, allow_nil?: false]
                  ]

      argument :account, :string, allow_nil?: false
      # `nil` MINTS a name (`mint_draft_name/3`) — the create case. Otherwise
      # a bare `.md` basename, same grammar as `get_mail_draft`'s.
      argument :name, :string, allow_nil?: true
      # VERBATIM bytes: `Ash.Type.String` trims and nils-out the empty string
      # by default, which would silently drop a draft's trailing newline (and
      # any deliberate leading blank line) — the file would then no longer
      # hash to what the caller wrote, breaking the very CAS this action is
      # built on. Emptiness is refused a line later by the grammar gate, with
      # a coherent `invalid_draft` instead of a bare "is required".
      argument :content, :string,
        allow_nil?: false,
        constraints: [trim?: false, allow_empty?: true]

      # The revision this write is based on: the sha256 hex
      # (`DraftFile.content_hash/1`) of the bytes the caller last read. `nil`
      # means "create" — accepted only when nothing is at that name, so a
      # blind overwrite of an existing draft is never possible.
      argument :base_hash, :string, allow_nil?: true
      argument :generation, :integer, allow_nil?: false

      # THE human's pen for draft files (spec E §Drafting & push): the one way
      # the composer UI puts bytes under `sources/mail/<account>/drafts/`.
      # Everything downstream — the ledger, push, the review snapshot, the
      # hash-bound send — reads those bytes and is untouched by this action;
      # what this owns is the four refusals that keep them trustworthy:
      #
      #   1. the content must PARSE (`DraftFile.parse_and_validate/1`, the same
      #      grammar composition serializes from) — an unparseable draft is
      #      refused, never stored;
      #   2. the name must stay inside the account's own drafts dir
      #      (`validate_draft_name/1` + `Paths.resolve_real/2`);
      #   3. the draft must be in plain `draft` state by the LEDGER's reckoning
      #      — the same projection `list_mail_drafts` renders — so nothing can
      #      rewrite a file mid-push/send, or under a completed send whose
      #      revision the ledger still names;
      #   4. the write is compare-and-swap on `base_hash`, so an edit made
      #      against bytes an agent has since replaced is refused
      #      (`content_changed`) rather than silently clobbering them.
      #
      # The write itself is temp + rename, so the `mail_draft` watcher push
      # (which fires on the `.md` rename, never on the `.md.tmp`) refreshes
      # every panel with complete bytes.
      run fn input, _ctx ->
        %{account: slug, content: content, generation: generation} = input.arguments
        base_hash = input.arguments[:base_hash]

        with :ok <- Manager.check_generation(generation),
             {:ok, %{path: root}} <- Manager.current(),
             :ok <- validate_slug(slug),
             :ok <- ensure_configured_account(root, slug),
             {:ok, parsed} <- validate_draft_content(content),
             {:ok, name} <- draft_write_name(root, slug, input.arguments[:name], parsed),
             {:ok, path} <- contained_draft_path(root, slug, name),
             :ok <- ensure_draft_writable(root, slug, name),
             :ok <- check_draft_cas(path, base_hash),
             :ok <- write_draft_atomic(path, content) do
          {:ok, %{"name" => name, "saved" => true}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end
  end

  @doc false
  # Central error mapping for every action in this resource — mirrors
  # `Valea.Api.ICM.error_for/1`. Most of this resource's dependencies
  # already return an atom that stringifies to the exact code the frontend
  # expects (`to_string/1` — the generic clause below); the handful that
  # don't get an explicit clause:
  #   * `:blocked` (Engine.sync_now/1's mailbox_replaced-sticky refusal) ->
  #     `"mailbox_replaced"` — the client-facing name for the SAME
  #     condition `mail_status`'s `state` field already uses.
  #   * `:icm_unavailable` (`SessionScope.resolve/1` refusing the primary
  #     ICM `revise_mail_draft` would host its session on) ->
  #     `"no_icm_available"` — the mail UI has no ICM picker, so from here
  #     an unknown/disabled/degraded mount key all mean the same thing to
  #     the user: nothing can host the session yet.
  #   * `:enoent`/`:outside`/`:invalid` (a missing file, or
  #     `Paths.resolve_real/2` rejecting containment) -> `"not_found"` —
  #     never distinguishes "doesn't exist" from "resolves outside the
  #     allowed area" to the client (see `get_mail_message`'s moduledoc
  #     section).
  def error_for(:no_workspace), do: Error.new("workspace_not_open")
  def error_for(:blocked), do: Error.new("mailbox_replaced")
  def error_for(:icm_unavailable), do: Error.new("no_icm_available")
  def error_for(:enoent), do: Error.new("not_found")
  def error_for(:outside), do: Error.new("not_found")
  def error_for(:invalid), do: Error.new("not_found")
  def error_for(reason) when is_atom(reason), do: Error.new(to_string(reason))
  # `push_draft_to_mailbox` (via `Engine.push_draft/3`) surfaces its
  # per-draft rejection reasons as ready-made string codes
  # (`"content_changed"`, `"status_forged"`, `"invalid_draft_name"`,
  # `"not_found"`, ...) — pass them through verbatim, never `inspect`-quoted.
  def error_for(reason) when is_binary(reason), do: Error.new(reason)
  def error_for(reason), do: Error.new(inspect(reason))

  # -- slug / confirmation guards ----------------------------------------------

  defp validate_slug(slug) do
    if Settings.valid_slug?(slug), do: :ok, else: {:error, :invalid_slug}
  end

  # Maps every op to a per-op rejection with `reason` — keeps `mail_apply_ops`'s
  # frozen results-array shape populated when the Engine can't run the batch.
  defp reject_all_ops(ops, reason) do
    ops
    |> Enum.with_index()
    |> Enum.map(fn {_op, index} ->
      %{"op" => index, "result" => "rejected", "reason" => reason}
    end)
  end

  defp require_confirmation(confirmation, expected) do
    if confirmation == expected, do: :ok, else: {:error, :confirmation_mismatch}
  end

  # -- smtp block / credential kind (v5) --------------------------------------

  # Collapses `setup_mail_account`'s flat `smtp_*` arguments into the nested
  # `:smtp` attrs `Settings.upsert_account!/3` takes — `nil` (a push-only
  # account) when the form left every one of them empty. Blank strings count
  # as absent: the setup form submits `""` for an untouched field, and an
  # empty `security`/`from`/`from_name` means "use the default", not "this
  # value is the empty string". Everything past this point is validated by
  # `Settings` itself, so there is exactly one smtp grammar in the codebase.
  defp smtp_attrs(arguments) do
    smtp = %{
      host: blank_to_nil(arguments[:smtp_host]),
      port: arguments[:smtp_port],
      security: blank_to_nil(arguments[:smtp_security]),
      username: blank_to_nil(arguments[:smtp_username]),
      from: blank_to_nil(arguments[:smtp_from]),
      from_name: blank_to_nil(arguments[:smtp_from_name])
    }

    if Enum.all?(smtp, fn {_key, value} -> is_nil(value) end), do: nil, else: smtp
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil

  # The two verdicts a human can give a parked send. Closed clauses, never
  # `String.to_atom/1` on RPC input (same posture as `credential_kind/1`).
  defp send_resolution("sent"), do: {:ok, :sent}
  defp send_resolution("not_sent"), do: {:ok, :not_sent}
  defp send_resolution(_other), do: {:error, :invalid_resolution}

  # `nil` (the argument omitted) is `:imap` — what every caller predating the
  # SMTP slot means. Never `String.to_atom/1` on RPC input.
  defp credential_kind(nil), do: {:ok, :imap}
  defp credential_kind("imap"), do: {:ok, :imap}
  defp credential_kind("smtp"), do: {:ok, :smtp}
  defp credential_kind(_other), do: {:error, :invalid_credential_kind}

  defp check_identity_for_setup(root, slug, host, username) do
    case Account.verify(root, slug, %{host: host, username: username}) do
      :ok -> :ok
      :absent -> :ok
      {:error, :identity_mismatch} = error -> error
    end
  end

  # A purge may proceed against a slug with NO running engine (already
  # removed from config) or one stuck in `identity_mismatch`/
  # `mailbox_replaced` (exactly the states purging is meant to resolve) —
  # never against a healthy, actively-running engine, so files can't be
  # yanked out from under an in-flight sync.
  defp ensure_purge_allowed(slug) do
    case Engine.status(slug) do
      nil -> :ok
      %{state: state} when state in ["identity_mismatch", "mailbox_replaced"] -> :ok
      %{} -> {:error, :account_active}
    end
  end

  defp validate_msg_id(msg_id) do
    if Regex.match?(@msg_id_re, msg_id), do: :ok, else: {:error, :invalid_msg_id}
  end

  # -- mail_status --------------------------------------------------------------

  # -- get_mail_message: HTML rendering + trust ------------------------------

  # The sanitized text/html rendering of a message, from its raw maildir
  # occurrence bytes (the view file only ever stores the flattened text).
  # Best-effort throughout: any miss — no index row, a path outside the
  # account's own maildir (containment check + `Paths.resolve_real/2`), an
  # unreadable file, no text/html part, a sanitize-to-empty — degrades to
  # "no HTML view" rather than failing the read.
  defp message_html(root, slug, msg_id) do
    maildir_rel = Path.join(["sources", "mail", slug, "maildir"])

    with [row | _] <- Store.message_rows_by_msg_id(slug, msg_id),
         path when is_binary(path) <- row.path,
         true <- Paths.ancestor?(maildir_rel, path),
         rel = Paths.relative_to(path, maildir_rel),
         {:ok, resolved} <- Paths.resolve_real(rel, Path.join(root, maildir_rel)),
         {:ok, raw} <- File.read(resolved),
         html when is_binary(html) <- Normalizer.html_body(raw),
         sanitized when sanitized != "" <- HtmlSanitizer.sanitize(html) do
      %{
        "html" => sanitized,
        "external_content" => HtmlSanitizer.external_content?(sanitized)
      }
    else
      _ -> %{"html" => nil, "external_content" => false}
    end
  rescue
    # `Store` reads can raise when the Repo is down mid-close — the plain
    # text view is still perfectly servable without an HTML rendering.
    _ -> %{"html" => nil, "external_content" => false}
  end

  defp sender_email(frontmatter) do
    case frontmatter do
      %{"from" => %{"email" => email}} when is_binary(email) -> email
      _ -> nil
    end
  end

  # The settings-form prefill payload: non-secret connection config only
  # (passwords live in the OS keychain / Engine memory, never in
  # `config/mail.yaml`, so there is nothing secret here to withhold).
  defp account_settings_payload(%Settings{imap: imap, smtp: smtp}) do
    %{
      host: imap.host,
      port: imap.port,
      username: imap.username,
      smtp: smtp_settings_payload(smtp)
    }
  end

  defp smtp_settings_payload(nil), do: nil

  defp smtp_settings_payload(smtp) do
    %{
      host: smtp.host,
      port: smtp.port,
      security: to_string(smtp.security),
      username: smtp.username,
      from: smtp.from,
      from_name: smtp.from_name
    }
  end

  defp mail_status_accounts(root) do
    invalid =
      case Settings.load(root) do
        {:ok, %{invalid: invalid}} -> invalid
        _ -> %{}
      end

    valid_entries =
      Enum.map(Engine.statuses(), fn {_slug, status} ->
        status |> stringify() |> Map.put("valid", true)
      end)

    invalid_entries =
      Enum.map(invalid, fn {slug, reason} ->
        %{"account" => slug, "valid" => false, "state" => "invalid_config", "reason" => reason}
      end)

    (valid_entries ++ invalid_entries) |> Enum.sort_by(& &1["account"])
  end

  defp stringify(status), do: Map.new(status, fn {k, v} -> {to_string(k), v} end)

  # -- list_mail_messages / list_mail_folders -----------------------------------

  defp message_summary(account, row) do
    row
    |> Map.take([
      :msg_id,
      :from_name,
      :from_email,
      :subject,
      :date,
      :flags,
      :has_attachments,
      :uid,
      :path
    ])
    |> Map.put(:view_path, Views.view_rel_path(account, row.msg_id))
  end

  # One search hit -> zero or one summary row. `mail_search` is keyed per
  # MESSAGE while `mail_messages` is keyed per OCCURRENCE, so a hit is
  # rendered through whichever of its occurrences sorts first by folder
  # name — an arbitrary but STABLE choice, so repeating a search doesn't
  # reshuffle which folder/uid a row reports.
  #
  # No occurrence at all means the search index is momentarily ahead of the
  # message index (a view landed whose occurrence row isn't written yet, or
  # an orphaned view). The hit is DROPPED rather than emitted with a blank
  # uid/path/flags: every summary field the list UI needs comes from the
  # occurrence row, so a half-filled row would render as a broken entry.
  defp search_hit(account, %{msg_id: msg_id, snippet: snippet}) do
    case Store.message_rows_by_msg_id(account, msg_id) do
      [] ->
        []

      rows ->
        row = Enum.min_by(rows, & &1.folder)
        [account |> message_summary(row) |> Map.put(:snippet, snippet)]
    end
  end

  defp folder_summary(account, sync_state) do
    %{
      name: sync_state.folder,
      dir: sync_state.dir,
      held: sync_state.held,
      message_count: folder_message_count(account, sync_state.folder),
      backfill_complete: sync_state.backfill_complete
    }
  end

  # Every real (non-oversize-sentinel) occurrence currently bound to this
  # folder in `mail_uid_map` — the identity-map table, not `mail_messages`,
  # so this count is accurate even for a folder whose index rows haven't
  # been (re)built yet.
  defp folder_message_count(account, folder) do
    account
    |> Store.occurrences(folder)
    |> Enum.count(&(&1.msg_id != "__oversize__"))
  end

  # -- list_mail_drafts ---------------------------------------------------------

  # Every configured account's `drafts/*.md`, sorted by (account, name). A
  # scan/read failure on any single account or file never aborts the list.
  defp list_all_drafts(root) do
    root
    |> valid_account_slugs()
    |> Enum.flat_map(&account_drafts(root, &1))
    |> Enum.sort_by(&{&1["account"], &1["name"]})
  end

  defp valid_account_slugs(root) do
    case Settings.load(root) do
      {:ok, %{accounts: accounts}} -> accounts |> Map.keys() |> Enum.sort()
      _other -> []
    end
  end

  defp account_drafts(root, account) do
    dir = Path.join([root, "sources", "mail", account, "drafts"])

    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.map(&draft_entry(root, account, &1))

      {:error, _reason} ->
        []
    end
  end

  defp draft_entry(root, account, name) do
    {parsed, raw_hash} = read_and_parse_draft(root, account, name)
    {display, notice, pushed?, op_id} = draft_display(account, name, parsed, raw_hash)

    %{
      "account" => account,
      "name" => name,
      "path" => draft_rel_path(account, name),
      "status_display" => display,
      "notice" => notice,
      # The op the send-resolution actions act on, when this row has one:
      # `resolve_send_review` for a parked send, `retry_sent_copy` for a
      # completed one whose Sent copy is outstanding. `nil` everywhere else.
      "op_id" => op_id,
      # A separate FACT, not a state: any completed push. Rendered as a badge
      # beside the primary state, never overriding it (spec G §Display
      # projection) — Send and Push both key off the primary state.
      "pushed" => pushed?,
      "parsed_recipients" => parsed_recipients(parsed)
    }
  end

  # Same no-follow posture as the push path's snapshot open: only a REGULAR
  # file with a SINGLE link is ever read — an agent-planted symlink (or
  # hard-linked file) under `drafts/` lists as invalid (`link_unsafe`) with
  # its target content NEVER read. Returns the parse result AND the raw
  # bytes' hash (the projection's gate for "is this still the revision that
  # was sent?"); `nil` when nothing could be read.
  defp read_and_parse_draft(root, account, name) do
    path = Path.join([root, "sources", "mail", account, "drafts", name])

    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, links: 1}} ->
        case File.read(path) do
          {:ok, bytes} -> {DraftFile.parse_and_validate(bytes), DraftFile.content_hash(bytes)}
          {:error, _reason} -> {{:error, "unreadable"}, nil}
        end

      {:ok, _link_or_special} ->
        {{:error, "link_unsafe"}, nil}

      {:error, _reason} ->
        {{:error, "unreadable"}, nil}
    end
  end

  # Displayed state derives from the LEDGER, never the frontmatter (spec G
  # §Display projection), and is KIND-AWARE and ORDERED — one draft's origin
  # can carry both a push and a send, and `complete` means `pushed` for one
  # and `sent` for the other:
  #
  #   1. The active op governs (the widened claim index guarantees at most
  #      one): `pushing` | `sending` | `send_review` | `needs_review`.
  #   2. Else the NEWEST terminal send governs — `sent` while the file still
  #      hashes to the revision that was sent, `draft` + an
  #      `earlier_revision_sent` note once it has been edited (push's CAS
  #      reporting rule, applied to display), `draft` + the surfaced error
  #      when it was rejected (which is retryable).
  #   3. Else no ledger op governs the state, so the file is a DRAFT — and the
  #      only question left is whether its engine-owned `status:` stamp is
  #      corroborated by history (the engine wrote it: a completed push, a
  #      resolved send) or forged by an agent → `draft` + `status_forged`.
  #      The frontmatter never supplies the state itself, only that verdict.
  #
  # A completed push is NOT a state here — it is the `pushed` badge, so a
  # pushed draft still reads `draft` and still offers Send and Push (spec G
  # §Display projection: "`pushed` becomes a separate boolean fact … rendered
  # as a badge beside the primary state, never overriding it. Send and Push
  # buttons key off the primary state (`draft`), independent of the badge.").
  defp draft_display(account, name, parsed, raw_hash) do
    ops = Store.ops_by_origin(account, "drafts/" <> name)
    active = Enum.find(ops, &(&1.state in OpsExecutor.active_states()))
    newest_send = Enum.find(ops, &(&1.kind == "send" and &1.state in ["complete", "rejected"]))
    pushed? = Enum.any?(ops, &(&1.kind == "append" and &1.state == "complete"))
    fm_status = frontmatter_status(parsed)

    {state, error, op_id} =
      cond do
        active != nil ->
          {OpsExecutor.op_display(active.kind, active.state), active.error, send_op_id(active)}

        newest_send != nil and newest_send.state == "complete" and
            newest_send.content_hash == raw_hash ->
          # `error` may be `sent_copy_failed`: sent, with its Sent copy
          # outstanding and a retry affordance — which needs this op's id.
          {"sent", newest_send.error, newest_send.id}

        newest_send != nil and newest_send.state == "complete" ->
          {"draft", "earlier_revision_sent", nil}

        newest_send != nil ->
          {"draft", newest_send.error, nil}

        not stamp_corroborated?(ops, fm_status) ->
          {"draft", "status_forged", nil}

        true ->
          {"draft", nil, nil}
      end

    {state, error, pushed?, op_id}
  end

  # The op the send-resolution RPCs act on for this row: `resolve_send_review`
  # needs the parked op's id, `retry_sent_copy` the completed send's. Only ever
  # a SEND op — no RPC takes an append op id, and a row governed by an append
  # has no resolution to offer.
  defp send_op_id(%{kind: "send", id: id}), do: id
  defp send_op_id(_append), do: nil

  # Anti-forgery (spec §Drafting & push, extended to the send stamps): a
  # non-`draft` `status:` is believable only when a ledger op OF THE MATCHING
  # KIND corroborates it — i.e. the engine wrote it, on this draft, for this
  # kind of outbound action. Mirrors the executor's own `prior_op?/3` rule one
  # notch stricter: a completed push does NOT corroborate an agent-written
  # `status: sent`.
  defp stamp_corroborated?(_ops, status) when status in [nil, "draft"], do: true

  defp stamp_corroborated?(ops, status) when status in ["pushing", "pushed"],
    do: Enum.any?(ops, &(&1.kind == "append"))

  defp stamp_corroborated?(ops, _sending_or_sent),
    do: Enum.any?(ops, &(&1.kind == "send"))

  defp frontmatter_status({:ok, %{status: status}}), do: status
  defp frontmatter_status(_other), do: nil

  defp parsed_recipients({:ok, %{to: to, cc: cc, bcc: bcc, subject: subject}}) do
    %{
      "to" => Enum.map(to, &addr_map/1),
      "cc" => Enum.map(cc, &addr_map/1),
      "bcc" => Enum.map(bcc, &addr_map/1),
      "subject" => subject
    }
  end

  defp parsed_recipients({:error, reason}), do: %{"invalid" => reason}

  defp addr_map(%{name: name, email: email}), do: %{"name" => name, "email" => email}

  defp draft_rel_path(account, name),
    do: Path.join(["sources", "mail", account, "drafts", name])

  # A bare `.md` basename only — any separator or traversal is rejected
  # BEFORE a path is ever constructed from it (get_mail_draft).
  defp validate_draft_name(name) do
    if is_binary(name) and String.ends_with?(name, ".md") and name != ".md" and
         not String.contains?(name, ["/", "\\", ".."]) do
      :ok
    else
      {:error, :invalid_draft_name}
    end
  end

  # -- write_mail_draft (spec E §Drafting & push) ------------------------------

  # A subject slug is capped here, not at the whole name: the timestamp prefix
  # is fixed-width, so this is what bounds the minted basename.
  @draft_slug_max 40

  # The grammar gate. A draft that does not parse is REFUSED, never stored —
  # the file this action writes is exactly the file the push/send flows compose
  # from, so admitting bytes they would later choke on would only move the
  # failure to the moment the human clicks Send. The parsed result is also what
  # mints a name, so the subject slug can never be taken from a field that
  # failed validation.
  defp validate_draft_content(content) do
    case DraftFile.parse_and_validate(content) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, _reason} -> {:error, :invalid_draft}
    end
  end

  # A caller-supplied name is validated exactly like `get_mail_draft`'s;
  # `nil` mints one.
  defp draft_write_name(_root, _slug, name, _parsed) when is_binary(name) do
    with :ok <- validate_draft_name(name), do: {:ok, name}
  end

  defp draft_write_name(root, slug, nil, parsed), do: {:ok, mint_draft_name(root, slug, parsed)}

  # `YYYYMMDDTHHMMSS-<subject-slug>.md`, UTC. The `.md` suffix is part of the
  # NAME everywhere on this surface — it is what `get_mail_draft`,
  # `push_draft_to_mailbox` and `send_draft` take, and what
  # `list_mail_drafts` reports — so the minted name carries it too.
  defp mint_draft_name(root, slug, parsed) do
    stamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%dT%H%M%S")
    unique_draft_name(root, slug, stamp <> "-" <> subject_slug(parsed))
  end

  # ASCII-only by construction: every run of non-alphanumerics (a colon, a
  # space, an umlaut) collapses to one `-`, so the slug can never grow a path
  # separator, a dot segment, or a byte the name grammar would reject.
  defp subject_slug(%{subject: subject}) when is_binary(subject) do
    slug =
      subject
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.slice(0, @draft_slug_max)
      |> String.trim("-")

    if slug == "", do: "draft", else: slug
  end

  defp subject_slug(_other), do: "draft"

  # Two drafts minted in the same second (or one subject written twice) get a
  # numeric suffix — a minted name NEVER lands on an existing entry, since the
  # caller that supplied no name cannot have meant to overwrite anything.
  defp unique_draft_name(root, slug, base) do
    dir = drafts_dir(root, slug)

    0..99
    |> Stream.map(fn
      0 -> base <> ".md"
      n -> "#{base}-#{n + 1}.md"
    end)
    |> Enum.find(&(not draft_entry_exists?(dir, &1)))
    |> case do
      nil -> "#{base}-#{System.unique_integer([:positive])}.md"
      name -> name
    end
  end

  # `lstat`, not `stat`: a DANGLING symlink at the minted name is still an
  # entry a rename would replace, so it counts as taken.
  defp draft_entry_exists?(dir, name), do: match?({:ok, _stat}, File.lstat(Path.join(dir, name)))

  # Writing creates directories, so — unlike the read paths — a grammar-valid
  # slug is not enough: an unconfigured account would get a stray
  # `sources/mail/<slug>/drafts/` tree holding a draft `list_mail_drafts`
  # (which enumerates CONFIGURED accounts) would never show. Same roster the
  # listing walks, so "writable account" and "listed account" cannot drift.
  defp ensure_configured_account(root, slug) do
    if slug in valid_account_slugs(root), do: :ok, else: {:error, :not_found}
  end

  # Containment, exactly as the executor does it
  # (`Valea.Mail.OpsExecutor.resolve_draft_path/2`): `Paths.resolve_real/2`
  # refuses a name whose entry resolves outside the account's own drafts dir,
  # and the path handed back is the LITERAL `drafts/<name>` — never the
  # symlink-followed one — so the rename below replaces the ENTRY rather than
  # writing through it.
  defp contained_draft_path(root, slug, name) do
    dir = drafts_dir(root, slug)

    case Paths.resolve_real(name, dir) do
      {:ok, _resolved} -> {:ok, Path.join(dir, name)}
      {:error, _reason} -> {:error, :link_unsafe}
    end
  end

  # The ledger's verdict on this draft, from the SAME projection
  # `list_mail_drafts` renders (`draft_display/4`) — one state machine, not
  # two. The pen may only rewrite a file in plain `draft` state: never one
  # mid-push/send (`pushing`/`sending`/`send_review`/`needs_review`, where the
  # bytes are claimed and hash-bound), and never one displaying `sent`, whose
  # ledger op still names this exact revision.
  defp ensure_draft_writable(root, slug, name) do
    {parsed, raw_hash} = read_and_parse_draft(root, slug, name)

    case draft_display(slug, name, parsed, raw_hash) do
      {"draft", _notice, _pushed?, _op_id} -> :ok
      _busy -> {:error, :draft_busy}
    end
  end

  # Compare-and-swap on the EXACT bytes on disk, under
  # `DraftFile.content_hash/1` — the same encoding `get_mail_draft`'s caller
  # hashes and the push binds to. `base_hash: nil` means "create", and is
  # accepted ONLY when nothing is at that name: a blind overwrite of an
  # existing draft would silently discard whatever an agent (or the human's
  # other window) put there in the meantime.
  defp check_draft_cas(path, base_hash) do
    case read_draft_bytes_nofollow(path) do
      {:ok, bytes} ->
        if is_binary(base_hash) and base_hash == DraftFile.content_hash(bytes),
          do: :ok,
          else: {:error, :content_changed}

      :absent ->
        # A `base_hash` naming a revision that is no longer there is stale in
        # exactly the sense the CAS exists to catch (deleted or renamed under
        # the caller) — refused rather than quietly resurrected.
        if is_nil(base_hash), do: :ok, else: {:error, :content_changed}

      # A `link_unsafe` entry keeps its own name; an errno does not (see
      # `write_failed/1`) — the CAS basis being unreadable is this save
      # failing, not a fact about the host's filesystem.
      {:error, reason} ->
        {:error, write_failed(reason)}
    end
  end

  # Same no-follow posture as every other draft read here: only a REGULAR file
  # with a SINGLE link is hashed, so a planted symlink or hard link can neither
  # supply the CAS basis nor be silently replaced.
  defp read_draft_bytes_nofollow(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, links: 1}} ->
        case File.read(path) do
          {:ok, bytes} -> {:ok, bytes}
          {:error, reason} -> {:error, reason}
        end

      {:ok, _link_or_special} ->
        {:error, :link_unsafe}

      {:error, :enoent} ->
        :absent

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Temp + rename in the SAME directory: a reader — the push snapshot, the
  # review read, the watcher's refresh — sees either the old bytes or the new
  # ones, never a half-written draft. The temp name still ends `.tmp`, which
  # neither `list_mail_drafts` (`.md` only) nor the watcher's
  # `classify_sources/2` (`.md` only) picks up, so no ghost row and no
  # spurious push.
  #
  # The temp path is UNIQUE and opened EXCLUSIVELY, and both halves are load-
  # bearing. `drafts/` is agent-writable — that is the whole premise of the
  # `earlier_revision_sent` display — so a PREDICTABLE temp name is an entry
  # an agent can plant ahead of the human's next save: a plain write opens
  # `O_WRONLY|O_CREAT|O_TRUNC`, which FOLLOWS a symlink, so
  # `ln -s ~/.ssh/authorized_keys drafts/reply.md.tmp` would have this
  # function truncate and overwrite that file and then leave the link itself
  # renamed into place as the draft — an arbitrary write straight through the
  # containment gate `contained_draft_path/3` only ever applied to the `.md`.
  # `:exclusive` is `O_EXCL|O_CREAT`, which never follows a symlink and never
  # truncates, and the unique suffix means there is no name to plant at.
  defp write_draft_atomic(path, content) do
    tmp = "#{path}.#{System.unique_integer([:positive])}.tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, written} <-
           File.open(tmp, [:write, :binary, :exclusive], &IO.binwrite(&1, content)) do
      rename_draft_into_place(tmp, path, written)
    else
      # Nothing of ours is on disk yet: either `mkdir_p` never got there, or
      # the exclusive create refused — which IS the planted-entry refusal, so
      # this branch must not go on to delete what it found.
      {:error, reason} -> {:error, write_failed(reason)}
    end
  end

  # Past the exclusive create the temp file is OURS, so every failure from
  # here removes it: the name carries a unique integer and is never reused, so
  # an orphan would sit under `drafts/` forever — invisible to the listing and
  # the watcher, but real.
  defp rename_draft_into_place(tmp, path, :ok) do
    case File.rename(tmp, path) do
      :ok -> :ok
      {:error, reason} -> abandon_draft_write(tmp, reason)
    end
  end

  defp rename_draft_into_place(tmp, _path, {:error, reason}),
    do: abandon_draft_write(tmp, reason)

  defp abandon_draft_write(tmp, reason) do
    File.rm(tmp)
    {:error, write_failed(reason)}
  end

  # ONE stable code for every filesystem failure this action can hit. A raw
  # errno would reach the client through `error_for/1`'s `to_string/1` clause
  # as `"eacces"`/`"enospc"`/`"erofs"` — codes no caller maps and no doc
  # lists, describing the host's filesystem for no one's benefit.
  # `:link_unsafe` is not a filesystem failure but a refusal this surface
  # names deliberately (`get_mail_draft` returns it too), so it passes
  # through.
  defp write_failed(:link_unsafe), do: :link_unsafe
  defp write_failed(_errno), do: :write_failed

  defp drafts_dir(root, account), do: Path.join([root, "sources", "mail", account, "drafts"])

  # -- revise_mail_draft (spec G §Request changes) -----------------------------

  # The draft must EXIST before any session is created or prompted, and it is
  # stat'd with the same no-follow posture as every other draft path here: a
  # symlink or hard-linked entry is `link_unsafe`, never followed.
  #
  # The absolute path it returns is re-derived through
  # `Valea.Icm.Locator.resolve/2` for ONE of the two correlation branches:
  # `locator_names_draft?/4`'s ICM-locator clause, which resolves the
  # session's locator and compares absolute paths — both sides must therefore
  # be symlink-resolved, on a platform where `/var` really is `/private/var`.
  # The WORKSPACE clause deliberately does NOT use this path: it compares
  # DECLARED relative paths, so that redirecting some live session's input
  # symlink at a draft cannot make that session claim the draft's feedback.
  # Do not "unify" the two branches on resolved paths — that reintroduces
  # exactly the wrong-session routing the workspace clause exists to prevent.
  defp existing_draft_path(root, slug, name) do
    path = Path.join([root, "sources", "mail", slug, "drafts", name])

    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, links: 1}} ->
        Valea.Icm.Locator.resolve(root, draft_locator(slug, name))

      {:ok, _link_or_special} ->
        {:error, :link_unsafe}

      {:error, _reason} ->
        {:error, :not_found}
    end
  end

  # Correlation, then action. A LIVE session whose own input locator already
  # names this draft gets the feedback as another TURN — a second round of
  # changes means "keep going", not "start over" — and only when there is
  # none does a session get created.
  defp route_revision(%{root: root, slug: slug, name: name, draft_abs: draft_abs} = req) do
    rel_path = draft_rel_path(slug, name)
    prompt = revise_prompt(rel_path, req.feedback)

    case find_session_for_draft(root, rel_path, draft_abs) do
      {:ok, session_id} ->
        # `SessionServer.prompt/2` resolves the id through a plain Registry
        # lookup — no GenServer round-trip — and answers
        # `{:error, :not_running}` when the entry is gone by the time it
        # looks, i.e. the session died AND was reaped between the enumeration
        # above and this call. Honour that rather than discarding it:
        # reporting "sent to session" for a turn that provably never landed,
        # behind a link to a transcript that will never show it, is worse
        # than starting the session the user asked for.
        #
        # The wider half of the same window — died but not yet reaped, where
        # the lookup still yields a dead pid and the cast is silently `:ok` —
        # is closed upstream, by `list_running_session_inputs/0` filtering on
        # liveness. What remains is a session dying in the microseconds
        # between that filter and this cast: best-effort by design, as the
        # spec accepts for correlation.
        case SessionServer.prompt(session_id, prompt) do
          :ok -> {:ok, %{"session_id" => session_id, "routed" => "existing"}}
          {:error, :not_running} -> start_revise_session(req, prompt)
        end

      :none ->
        start_revise_session(req, prompt)
    end
  end

  # The one live session already working on this exact file, if any. An input
  # locator that is absent, malformed, or no longer resolvable (its ICM
  # unmounted, its file gone) simply doesn't match — never an error, since a
  # stale locator on some UNRELATED session says nothing about this request.
  defp find_session_for_draft(root, rel_path, draft_abs) do
    Valea.Agents.list_running_session_inputs()
    |> Enum.find(fn {_id, input} -> locator_names_draft?(root, input, rel_path, draft_abs) end)
    |> case do
      {id, _input} -> {:ok, id}
      nil -> :none
    end
  end

  # A WORKSPACE locator is matched on the path it DECLARES, never on where
  # that path happens to point right now. `Valea.Icm.Locator.resolve/2`
  # follows symlinks, so resolve-based matching would let anything able to
  # write some live session's input file redirect it at a draft and thereby
  # claim that draft's feedback — the human's words landing in an unrelated
  # session's transcript, under a "Sent to session" link pointing at the
  # wrong place. No capability is gained either way (the policy's mail tier
  # still denies that session the draft), but the wrong session must not
  # match. A declared path is a NAME, and comparing names is what correlation
  # actually means here; the `/var` -> `/private/var` normalization that
  # motivated resolving in the first place applies to the workspace ROOT,
  # which both sides drop entirely.
  #
  # A locator spelling the same file differently (`./sources/...`) simply
  # doesn't match, and falls through to starting a session — the safe
  # direction.
  defp locator_names_draft?(
         _root,
         %{"kind" => "workspace", "path" => path},
         rel_path,
         _draft_abs
       ),
       do: path == rel_path

  # Every other locator kind keeps resolve-based comparison: an ICM locator
  # addresses a path relative to a mount root that only `resolve/2` knows.
  defp locator_names_draft?(root, input, _rel_path, draft_abs) when is_map(input) do
    case Valea.Icm.Locator.resolve(root, input) do
      {:ok, ^draft_abs} -> true
      _other -> false
    end
  end

  defp locator_names_draft?(_root, _input, _rel_path, _draft_abs), do: false

  # A fresh session for this draft, resolved and started exactly the way
  # `Valea.Api.Agents`'s `create_session` does it (id first, so the scope can
  # be resolved against it, then `start_session/1` with that same id): a chat
  # session on the caller's chosen primary ICM, the account's mail mount
  # included by key, and ONE exact read grant for the draft.
  defp start_revise_session(
         %{
           slug: slug,
           name: name,
           draft_abs: draft_abs,
           mount_key: mount_key,
           generation: generation
         },
         prompt
       ) do
    id = Valea.Agents.generate_session_id()
    include_mounts = ["mail-" <> slug]
    input_locator = draft_locator(slug, name)

    with {:ok, scope} <-
           SessionScope.resolve(%{
             kind: "chat",
             mount_key: mount_key,
             generation: generation,
             session_id: id,
             read_paths: [draft_abs],
             include_mounts: include_mounts
           }),
         {:ok, %{id: id}} <-
           Valea.Agents.start_session(%{
             id: id,
             kind: "chat",
             title: "New session",
             scope: scope,
             run: nil,
             initial_prompt: prompt,
             on_turn_end: nil,
             context_doc: nil,
             input: input_locator,
             include_mounts: include_mounts
           }) do
      Valea.Audit.append("session_started", %{
        "session_id" => id,
        "mount_key" => mount_key,
        "context_doc" => nil,
        "input" => input_locator,
        "include_mounts" => include_mounts
      })

      {:ok, %{"session_id" => id, "routed" => "new"}}
    end
  end

  defp draft_locator(slug, name),
    do: %{"kind" => "workspace", "path" => draft_rel_path(slug, name)}

  # The pinned prompt for a revision turn. It names the file by its
  # workspace-relative path (what the session was granted), and states the
  # two things an agent must not get wrong: the frontmatter vocabulary, and
  # that `status:` is engine-owned — a forged stamp is what the display
  # projection's `status_forged` notice exists to catch.
  defp revise_prompt(rel_path, feedback) do
    """
    Revise the mail draft at #{rel_path} per this feedback. Edit the file in place. Keep the \
    frontmatter valid (to/cc/bcc/subject/in_reply_to only) and do not touch the status field.

    Feedback:
    #{feedback}
    """
  end

  # Raw no-follow read for get_mail_draft — same lstat posture as
  # `read_and_parse_draft/3` above, but returning the exact bytes (the push
  # hash must cover what the user fetched, unparsed). Non-UTF8 content is
  # rejected rather than crashing the JSON encoder.
  defp read_draft_raw(root, account, name) do
    path = Path.join([root, "sources", "mail", account, "drafts", name])

    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, links: 1}} ->
        case File.read(path) do
          {:ok, bytes} ->
            if String.valid?(bytes), do: {:ok, bytes}, else: {:error, :invalid_encoding}

          {:error, _reason} ->
            {:error, :not_found}
        end

      {:ok, _link_or_special} ->
        {:error, :link_unsafe}

      {:error, _reason} ->
        {:error, :not_found}
    end
  end
end
