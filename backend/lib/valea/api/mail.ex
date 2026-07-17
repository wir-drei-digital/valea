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
      `list_mail_folders`, `get_mail_message`) take no `generation`, but
      still resolve `Manager.current/0` before touching the Engine/Store.
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

  alias Valea.Api.Error
  alias Valea.Mail.Account
  alias Valea.Mail.Engine
  alias Valea.Mail.MessageFile
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

      run fn input, _ctx ->
        %{
          account: slug,
          host: host,
          port: port,
          username: username,
          generation: generation
        } = input.arguments

        with :ok <- Manager.check_generation(generation),
             {:ok, %{path: root}} <- Manager.current(),
             :ok <- validate_slug(slug),
             :ok <- check_identity_for_setup(root, slug, host, username),
             :ok <-
               Settings.upsert_account!(root, slug, %{host: host, port: port, username: username}) do
          :ok = MailSupervisor.reload_settings_all(root)
          {:ok, %{"saved" => true}}
        else
          {:error, reason} -> {:error, error_for(reason)}
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
      argument :generation, :integer, allow_nil?: false

      run fn input, _ctx ->
        %{account: slug, secret: secret, generation: generation} = input.arguments

        with :ok <- Manager.check_generation(generation),
             :ok <- validate_slug(slug),
             :ok <- Engine.set_credential(slug, secret) do
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

          {:ok,
           %{"message" => %{"frontmatter" => frontmatter, "body" => body, "path" => rel_path}}}
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

      # Task 13 replaces this body with the real ops executor call — declared
      # now, with this exact shape, so codegen churns once (see moduledoc).
      run fn input, _ctx ->
        %{account: slug, ops: ops, generation: generation} = input.arguments

        with :ok <- Manager.check_generation(generation),
             :ok <- validate_slug(slug) do
          results =
            ops
            |> Enum.with_index()
            |> Enum.map(fn {_op, i} ->
              %{"op" => i, "result" => "rejected", "reason" => "ops_executor_not_wired"}
            end)

          {:ok, %{results: results}}
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

      # Task 15 fills this in — declared now, fixed shape, so codegen
      # churns once.
      run fn input, _ctx ->
        %{account: slug, generation: generation} = input.arguments

        with :ok <- Manager.check_generation(generation),
             :ok <- validate_slug(slug) do
          {:error, error_for(:not_implemented)}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :list_mail_drafts, :map do
      constraints fields: [drafts: [type: {:array, :map}, allow_nil?: false]]

      # Task 15 fills this in.
      run fn _input, _ctx ->
        with {:ok, _ws} <- Manager.current() do
          {:ok, %{drafts: []}}
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
  #   * `:enoent`/`:outside`/`:invalid` (a missing file, or
  #     `Paths.resolve_real/2` rejecting containment) -> `"not_found"` —
  #     never distinguishes "doesn't exist" from "resolves outside the
  #     allowed area" to the client (see `get_mail_message`'s moduledoc
  #     section).
  def error_for(:no_workspace), do: Error.new("workspace_not_open")
  def error_for(:blocked), do: Error.new("mailbox_replaced")
  def error_for(:enoent), do: Error.new("not_found")
  def error_for(:outside), do: Error.new("not_found")
  def error_for(:invalid), do: Error.new("not_found")
  def error_for(reason) when is_atom(reason), do: Error.new(to_string(reason))
  def error_for(reason), do: Error.new(inspect(reason))

  # -- slug / confirmation guards ----------------------------------------------

  defp validate_slug(slug) do
    if Settings.valid_slug?(slug), do: :ok, else: {:error, :invalid_slug}
  end

  defp require_confirmation(confirmation, expected) do
    if confirmation == expected, do: :ok, else: {:error, :confirmation_mismatch}
  end

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
end
