defmodule Valea.Api.Mail do
  @moduledoc """
  Data-layer-less Ash resource exposing the mail account, its sync engine,
  and its indexed messages over RPC (mail design spec, §RPC surface).

  Wraps `Valea.Mail.Engine` (status/setup/credential/sync/doctor/folders),
  `Valea.Mail.Settings.upsert_account!/3` (account setup), and
  `Valea.Mail.Store` + `Valea.Mail.MessageFile.parse/1` (the read side —
  files under `sources/mail/messages/` are canonical, `Store` is only ever
  a cache of them, so `get_mail_message` reads the file, not the cache row).
  Follows `Valea.Api.ICM`'s conventions throughout:

    * `constraints fields: [...]` typed actions for structured returns
      (`list_mail_messages`, `mail_inbox`), UNCONSTRAINED `:map` for raw
      passthrough where the shape is heterogeneous or arbitrary
      (`mail_status`'s `status`, `mail_doctor`'s `checks`,
      `get_mail_message`'s `message`) — string keys, no camelCase
      translation, same typed-vs-unconstrained split as `Valea.Api.ICM`'s
      moduledoc.
    * The SAME top-level generic-action boolean/falsy-map-field bug
      previously documented in the deleted `Valea.Api.Queue`'s moduledoc
      (ash_typescript 0.17.3 nulls a top-level atom-keyed field whose value
      is `false`): every action here that can genuinely return `false` at
      the top level (`setup_mail_account`'s `saved`, `set_mail_credential`'s
      `accepted`, `mail_sync_now`'s `started`, `mail_doctor`'s `ok`,
      `get_mail_message`'s `inbox`) uses a STRING key for that field.
    * Mutating actions (`setup_mail_account`, `set_mail_credential`,
      `mail_sync_now`, `create_mail_folders`) take a
      `generation` argument and guard with
      `Valea.Workspace.Manager.check_generation/1` before touching anything.
      `mail_doctor` ALSO takes `generation` and guards, even though it never
      itself errors (`Valea.Mail.Doctor.run/1` always succeeds) — it probes
      the live network with the workspace's credential, so it is treated as
      mutating-adjacent rather than a plain read.
    * Read-only actions (`mail_status`, `list_mail_messages`,
      `get_mail_message`, `mail_inbox`) take no `generation`, but still
      resolve `Valea.Workspace.Manager.current/0` before touching the
      Engine/Store — those only exist while a workspace's
      `Valea.Workspace.Runtime` is up, and calling them with none open would
      otherwise crash (`:noproc` / no `Valea.Repo` connection) instead of
      surfacing the ordinary `"workspace_not_open"` error every other
      no-workspace path uses.

  ## `set_mail_credential`'s secret

  The `secret` argument is marked `sensitive? true` (the standard Ash
  option — see `Ash.Resource.Actions.Argument`). Concretely, this app's
  `config :ash, redact_sensitive_values_in_errors?: true` (config.exs) makes
  `Ash.Resource.Validation.maybe_redact/3` scrub any `sensitive?: true`
  field's value out of an error a *validation* builds against it (e.g.
  `argument_in`/`argument_equals`) — this action declares no such
  validation on `secret`, so that path is dormant here, but the flag keeps
  the action correct/forward-compatible if one is ever added, and documents
  the field's status for the next reader either way. Beyond that mechanism,
  nothing on the request path logs action inputs at all — there is no
  `Plug.Logger` (or similar) on `ValeaWeb.Endpoint`, and Ash does not log
  action arguments by default — so the secret never reaches a log line or
  telemetry event regardless. The `run` callback itself never echoes it
  back (`set_credential/1`'s return here is the fixed `%{"accepted" =>
  true}`, never the input), and `Valea.Mail.Engine` holds it only as a
  zero-arity closure in process state (see that module's moduledoc).
  """
  use Ash.Resource, domain: Valea.Api, extensions: [AshTypescript.Resource]

  typescript do
    type_name("Mail")
  end

  alias Valea.Api.Error
  alias Valea.Mail.Doctor
  alias Valea.Mail.Engine
  alias Valea.Mail.MessageFile
  alias Valea.Mail.Settings
  alias Valea.Mail.Store
  alias Valea.Mail.Supervisor, as: MailSupervisor
  alias Valea.Workspace.Manager
  alias Valea.Workspace.Scaffold

  # TEMP T9->T10 bridge: this whole resource is rewritten in Task 10 onto
  # the real account-scoped RPC surface (an explicit `account` argument on
  # every action, per the mail-as-maildir design spec E's RPC table). Task 9
  # made `Valea.Mail.Engine`/`Valea.Mail.Doctor` per-account (Registry-keyed
  # by slug), which this NOT-yet-rewritten, still-single-implicit-account
  # resource must keep working against in the meantime — `default_slug/1`
  # is the bridge: "the first (only, in practice) valid account by slug",
  # mirroring the exact precedent `Valea.Mail.Engine`'s old `load_settings/1`
  # v3-bridge used. Deleted whole-cloth, alongside this resource's rewrite,
  # in Task 10.
  defp default_slug(root) do
    case Settings.load(root) do
      {:ok, %{accounts: accounts}} when map_size(accounts) > 0 ->
        accounts |> Map.keys() |> Enum.sort() |> List.first()

      _ ->
        nil
    end
  end

  actions do
    action :mail_status, :map do
      constraints fields: [status: [type: :map, allow_nil?: false]]

      run fn _input, _ctx ->
        with {:ok, %{path: root}} <- Manager.current() do
          {:ok, %{status: stringify(status_for(root))}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :setup_mail_account, :map do
      constraints fields: [saved: [type: :boolean, allow_nil?: false]]

      argument :account, :string, allow_nil?: false
      argument :host, :string, allow_nil?: false
      argument :port, :integer, allow_nil?: false, constraints: [min: 1]
      argument :username, :string, allow_nil?: false
      argument :generation, :integer, allow_nil?: false

      run fn input, _ctx ->
        %{
          account: account,
          host: host,
          port: port,
          username: username,
          generation: generation
        } = input.arguments

        # TEMP v3-bridge: reworked in Task 10 — `account` is still the RPC's
        # display-label argument (frontend hasn't moved to slugs yet), so it's
        # derived into a v4-grammar slug here rather than threading a real
        # slug argument through the whole call chain.
        slug = account |> Scaffold.slugify() |> String.slice(0, 32)

        with :ok <- Manager.check_generation(generation),
             {:ok, %{path: root}} <- Manager.current(),
             :ok <-
               Settings.upsert_account!(root, slug, %{host: host, port: port, username: username}) do
          :ok = MailSupervisor.reload_settings_all(root)
          {:ok, %{"saved" => true}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :set_mail_credential, :map do
      constraints fields: [accepted: [type: :boolean, allow_nil?: false]]

      argument :secret, :string, allow_nil?: false, sensitive?: true
      argument :generation, :integer, allow_nil?: false

      run fn input, _ctx ->
        %{secret: secret, generation: generation} = input.arguments

        with :ok <- Manager.check_generation(generation),
             {:ok, %{path: root}} <- Manager.current() do
          case default_slug(root) do
            nil -> :ok
            slug -> Engine.set_credential(slug, secret)
          end

          {:ok, %{"accepted" => true}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :mail_sync_now, :map do
      constraints fields: [started: [type: :boolean, allow_nil?: false]]

      argument :generation, :integer, allow_nil?: false

      run fn input, _ctx ->
        with :ok <- Manager.check_generation(input.arguments.generation),
             {:ok, %{path: root}} <- Manager.current(),
             :ok <- sync_now_for(root) do
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

      argument :generation, :integer, allow_nil?: false

      run fn input, _ctx ->
        with :ok <- Manager.check_generation(input.arguments.generation),
             {:ok, %{path: root}} <- Manager.current() do
          {:ok, %{checks: checks, ok: ok}} = doctor_for(root)
          {:ok, %{"ok" => ok, "checks" => checks}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :create_mail_folders, :map do
      constraints fields: [created: [type: {:array, :string}, allow_nil?: false]]

      argument :generation, :integer, allow_nil?: false

      run fn input, _ctx ->
        with :ok <- Manager.check_generation(input.arguments.generation),
             {:ok, %{path: root}} <- Manager.current(),
             {:ok, created} <- create_folders_for(root) do
          {:ok, %{created: created}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

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
                            status: [type: :string, allow_nil?: true],
                            has_attachments: [type: :boolean, allow_nil?: false],
                            uid: [type: :integer, allow_nil?: true],
                            path: [type: :string, allow_nil?: true]
                          ]
                        ]
                      ]
                    ]
                  ]

      run fn _input, _ctx ->
        with {:ok, _ws} <- Manager.current() do
          messages =
            Store.list_messages()
            |> Enum.map(
              &Map.take(&1, [
                :msg_id,
                :from_name,
                :from_email,
                :subject,
                :date,
                :status,
                :has_attachments,
                :uid,
                :path
              ])
            )

          {:ok, %{messages: messages}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :get_mail_message, :map do
      constraints fields: [
                    message: [type: :map, allow_nil?: false],
                    inbox: [type: :boolean, allow_nil?: false]
                  ]

      argument :msg_id, :string, allow_nil?: false

      run fn input, _ctx ->
        with {:ok, %{path: root}} <- Manager.current(),
             {:ok, %{path: path}} <- Store.get_message(input.arguments.msg_id),
             {:ok, bytes} <- File.read(Path.join(root, path)),
             {:ok, %{frontmatter: frontmatter, body: body}} <- MessageFile.parse(bytes) do
          {:ok,
           %{
             "message" => %{"frontmatter" => frontmatter, "body" => body, "path" => path},
             "inbox" => false
           }}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :mail_inbox, :map do
      constraints fields: [
                    entries: [
                      type: {:array, :map},
                      allow_nil?: false,
                      constraints: [
                        items: [
                          fields: [
                            uid: [type: :integer, allow_nil?: false],
                            from_text: [type: :string, allow_nil?: true],
                            subject: [type: :string, allow_nil?: true],
                            date: [type: :string, allow_nil?: true]
                          ]
                        ]
                      ]
                    ]
                  ]

      run fn _input, _ctx ->
        with {:ok, _ws} <- Manager.current() do
          {:ok, %{entries: Store.inbox_headers()}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end
  end

  @doc false
  # Central error mapping for every action in this resource — mirrors
  # `Valea.Api.ICM.error_for/1`. `:no_workspace` becomes the frontend's
  # `"workspace_not_open"`; every other atom this resource's dependencies
  # return (`:workspace_changed`, `:not_configured`, `:no_credential`,
  # `:inactive`, `:not_found`, ...) already stringifies to the exact code
  # the frontend expects.
  def error_for(:no_workspace), do: Error.new("workspace_not_open")
  def error_for(reason) when is_atom(reason), do: Error.new(to_string(reason))
  def error_for(reason), do: Error.new(inspect(reason))

  # `Valea.Mail.Engine.status/1`'s map is atom-keyed; stringify the top
  # level so this unconstrained field is delivered RAW (see the moduledoc),
  # matching `Valea.Api.ICM.page/1`'s identical top-level stringify.
  defp stringify(status), do: Map.new(status, fn {k, v} -> {to_string(k), v} end)

  # -- TEMP T9->T10 bridge helpers — see `default_slug/1`'s comment above --

  defp status_for(root) do
    case default_slug(root) do
      nil -> default_status(root)
      slug -> Engine.status(slug) || default_status(root)
    end
  end

  defp default_status(root) do
    %{
      account: nil,
      configured: false,
      credential: "missing",
      state: "idle",
      last_sync_at: nil,
      last_error: nil,
      username: nil,
      workspace_id: workspace_id(root),
      pending_ops: 0,
      held_folders: [],
      backfill: nil,
      notices: []
    }
  end

  defp workspace_id(root) do
    case YamlElixir.read_from_file(Path.join(root, "config/workspace.yaml")) do
      {:ok, %{"id" => id}} when is_binary(id) -> id
      _ -> nil
    end
  end

  defp sync_now_for(root) do
    case default_slug(root) do
      nil -> {:error, :not_configured}
      slug -> Engine.sync_now(slug)
    end
  end

  defp doctor_for(root) do
    case default_slug(root) do
      nil ->
        Doctor.run(%{
          root: root,
          account: "",
          settings: nil,
          credential: nil,
          transport: Application.get_env(:valea, :mail_transport, Valea.Mail.ImapClient)
        })

      slug ->
        Engine.doctor(slug)
    end
  end

  defp create_folders_for(root) do
    case default_slug(root) do
      nil -> {:error, :not_configured}
      slug -> Engine.create_folders(slug)
    end
  end
end
