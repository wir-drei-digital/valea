defmodule Valea.Api.Mounts do
  @moduledoc """
  Data-layer-less Ash resource exposing `Valea.Mounts`
  (list/enable/create/declare/undeclare) and `Valea.Mounts.Doctor` over RPC.
  Follows `Valea.Api.Queue`/`Valea.Api.Mail`'s conventions:

    * `constraints fields: [...]` typed actions for structured returns —
      `list_mounts`'s `mounts` field is a fully-typed array of
      `name`/`title`/`description`/`relRoot`/`root`/`enabled`/`degraded`
      (`relRoot`/`degraded` nullable: `relRoot` is `nil` for an EXTERNAL
      mount, `degraded` is `nil` for a healthy one). This is a NESTED
      array-item field, not a top-level one, so `enabled` staying an
      ordinary atom-keyed `:boolean` field is fine — the top-level
      generic-action boolean/falsy-map-field bug documented in
      `Valea.Api.Queue`'s moduledoc only reaches a field of the action's
      OWN top-level return map, not one nested inside an array item's
      `fields:`. `mounts_doctor`'s `checks` field is the UNCONSTRAINED
      `:map` passthrough instead (mirrors `Valea.Api.Mail`'s `mail_doctor`)
      — `Valea.Mounts.Doctor.run/0,1`'s check shape is already
      string-keyed and homogeneous enough not to need per-field typing.
    * `set_mount_enabled`/`declare_mount`/`undeclare_mount`'s top-level
      boolean fields (`saved`/`declared`/`undeclared`) and `mounts_doctor`'s
      `ok` DO hit that top-level bug — each uses the same STRING-key
      workaround (`%{"saved" => true}`, etc.) every other top-level
      boolean-returning mutation in this codebase uses.
    * Mutating actions (`set_mount_enabled`, `create_mount`,
      `declare_mount`, `undeclare_mount`) take a `generation` argument and
      guard with `Valea.Workspace.Manager.check_generation/1` before
      touching anything, same as `Valea.Api.Queue`/`Valea.Api.Mail`.
      `mounts_doctor` ALSO takes and guards `generation` even though it
      never writes config — it probes LIVE state (the watcher's current
      root set, the filesystem under every external mount's resolved root),
      so it is "mutating-adjacent" the same way `Valea.Api.Mail`'s
      `mail_doctor` is (see that module's moduledoc).

  `set_mount_enabled`, `create_mount`, `declare_mount`, and
  `undeclare_mount` all regenerate workspace metadata
  (`regenerate_workspace_metadata/1`: `Valea.Mounts.MountsMd.regenerate/1`
  AND `Valea.Agents.ClaudeSettings.write!/1`) and broadcast
  `{:mounts_changed}` on the `"mounts"` PubSub topic afterwards — the EXACT
  same message `Valea.ICM.Watcher` broadcasts on filesystem discovery
  changes (Task A-T6), so a subscriber (the `mounts` topic push in
  `ValeaWeb.WorkspaceEventsChannel`) can't tell an RPC-driven change from a
  filesystem one. Since A2-T5 the Watcher observes `config/workspace.yaml`
  too, so the config write these actions perform would ALSO surface as a
  watcher-driven `{:mounts_changed}` (plus its own regeneration) after the
  watcher's ~200ms debounce — this explicit broadcast is therefore
  redundant-but-faster, and it is kept DELIBERATELY, not vestigially:
  it reaches subscribers immediately instead of a debounce later, and it
  is transactionally coupled to the regeneration this action just
  performed (broadcast follows regenerate in the same call, so a
  subscriber reacting to it always reads fresh MOUNTS.md/settings.json —
  never a window where the message raced its own metadata). Do not remove
  it in favor of the watcher path.

  `declare_mount`/`undeclare_mount` and (when the mount is EXTERNAL)
  `set_mount_enabled` are audited by `Valea.Mounts` itself
  (`mount_declared`/`mount_undeclared`/`mount_enabled`/`mount_disabled` —
  see that module's moduledoc, "Audit — external mounts are boundary
  changes") — this resource does not append audit entries directly, it
  only triggers the domain-layer mutation that does.

  The `ClaudeSettings.write!/1` half of that regeneration (Plan A2 Task 4)
  is what keeps `.claude/settings.json`'s per-external-mount `Read` allow
  in sync with `enabled` state for a workspace that is ALREADY open: an
  agent session started before this RPC call already has its ACP
  permission policy (`extra_roots`, computed once at session start) either
  way, but the settings FILE Claude Code itself reads is regenerated here
  so the very next session — or a bare Claude Code session outside Valea
  entirely — sees the current enabled set without needing a workspace
  reopen. (Session start, `Valea.Workspace.Scaffold`, and
  `Valea.Workspace.Migration` each also call `ClaudeSettings.write!/1`
  independently — this is the mutation-time counterpart, not a
  replacement.)
  """
  use Ash.Resource, domain: Valea.Api, extensions: [AshTypescript.Resource]

  typescript do
    type_name("Mounts")
  end

  alias Valea.Agents.ClaudeSettings
  alias Valea.Api.Error
  alias Valea.Mounts
  alias Valea.Mounts.Doctor
  alias Valea.Mounts.MountsMd
  alias Valea.Workspace.Manager

  actions do
    action :list_mounts, :map do
      constraints fields: [
                    mounts: [
                      type: {:array, :map},
                      allow_nil?: false,
                      constraints: [
                        items: [
                          fields: [
                            name: [type: :string, allow_nil?: false],
                            title: [type: :string, allow_nil?: false],
                            description: [type: :string, allow_nil?: false],
                            # `nil` for an EXTERNAL mount (`Valea.Mounts.mount()`'s own
                            # `rel_root: nil` — it has no workspace-relative path; see
                            # `Valea.Mounts.External`'s moduledoc). Was wrongly
                            # `allow_nil?: false` pre-A2-T8 — harmless while every
                            # mount was embedded, but an external row would have had
                            # this field silently nulled-then-rejected by
                            # ash_typescript's non-nullable typing the moment one
                            # existed (A2-T5b ledger).
                            rel_root: [type: :string, allow_nil?: true],
                            # ABSOLUTE path for every mount (embedded or external) —
                            # the one field of `Valea.Mounts.mount()` this action
                            # didn't expose before A2-T8. Always present (never
                            # `nil`): an external mount's `root` is the empty-string
                            # sentinel, never `nil`, when its ref isn't even
                            # absolute/`~`-based (see `Valea.Mounts.External`).
                            root: [type: :string, allow_nil?: false],
                            enabled: [type: :boolean, allow_nil?: false],
                            degraded: [type: :string, allow_nil?: true]
                          ]
                        ]
                      ]
                    ]
                  ]

      run fn _input, _ctx ->
        case Mounts.list() do
          {:ok, mounts} -> {:ok, %{mounts: Enum.map(mounts, &to_rpc_mount/1)}}
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :set_mount_enabled, :map do
      constraints fields: [saved: [type: :boolean, allow_nil?: false]]

      argument :name, :string, allow_nil?: false
      argument :enabled, :boolean, allow_nil?: false
      argument :generation, :integer, allow_nil?: false

      run fn input, _ctx ->
        %{name: name, enabled: enabled, generation: generation} = input.arguments

        with :ok <- Manager.check_generation(generation),
             {:ok, %{path: root}} <- Manager.current(),
             :ok <- Mounts.set_enabled(name, enabled) do
          regenerate_workspace_metadata(root)
          broadcast_mounts_changed()
          {:ok, %{"saved" => true}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :create_mount, :map do
      constraints fields: [rel_root: [type: :string, allow_nil?: false]]

      argument :name, :string, allow_nil?: false

      argument :description, :string,
        allow_nil?: false,
        constraints: [allow_empty?: true]

      argument :generation, :integer, allow_nil?: false

      run fn input, _ctx ->
        %{name: name, description: description, generation: generation} = input.arguments

        with :ok <- Manager.check_generation(generation),
             {:ok, %{path: root}} <- Manager.current(),
             {:ok, mount} <- Mounts.create(root, name, description) do
          regenerate_workspace_metadata(root)
          broadcast_mounts_changed()
          {:ok, %{rel_root: mount.rel_root}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :declare_mount, :map do
      constraints fields: [declared: [type: :boolean, allow_nil?: false]]

      argument :name, :string, allow_nil?: false
      argument :ref, :string, allow_nil?: false
      argument :generation, :integer, allow_nil?: false

      run fn input, _ctx ->
        %{name: name, ref: ref, generation: generation} = input.arguments

        with :ok <- Manager.check_generation(generation),
             {:ok, %{path: root}} <- Manager.current(),
             {:ok, _resolved} <- Mounts.declare_external(root, name, ref) do
          regenerate_workspace_metadata(root)
          broadcast_mounts_changed()
          {:ok, %{"declared" => true}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :undeclare_mount, :map do
      constraints fields: [undeclared: [type: :boolean, allow_nil?: false]]

      argument :name, :string, allow_nil?: false
      argument :generation, :integer, allow_nil?: false

      run fn input, _ctx ->
        %{name: name, generation: generation} = input.arguments

        with :ok <- Manager.check_generation(generation),
             {:ok, %{path: root}} <- Manager.current(),
             {:ok, _path} <- Mounts.undeclare(root, name) do
          regenerate_workspace_metadata(root)
          broadcast_mounts_changed()
          {:ok, %{"undeclared" => true}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    # No config write of its own, but — like `mail_doctor` — it probes live
    # state (the watcher's current root set, the filesystem under every
    # external mount's resolved root) rather than reading a cached value, so
    # it takes/guards `generation` the same "mutating-adjacent" way
    # `mail_doctor` does (see `Valea.Api.Mail`'s moduledoc).
    action :mounts_doctor, :map do
      constraints fields: [
                    ok: [type: :boolean, allow_nil?: false],
                    checks: [type: {:array, :map}, allow_nil?: false]
                  ]

      argument :generation, :integer, allow_nil?: false

      run fn input, _ctx ->
        with :ok <- Manager.check_generation(input.arguments.generation),
             {:ok, %{checks: checks, ok: ok}} <- Doctor.run() do
          {:ok, %{"ok" => ok, "checks" => checks}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end
  end

  @doc false
  # Central error mapping for every action in this resource — mirrors
  # `Valea.Api.Queue.error_for/1`. `:no_workspace` becomes the frontend's
  # `"workspace_not_open"` code; `:workspace_changed` (a stale generation)
  # and `Valea.Mounts`'s own atoms (`:invalid_mount_name`, `:already_exists`,
  # `:mount_not_declared`) already stringify to the exact code the frontend
  # expects — as do SEVEN of `Valea.Mounts.External.validate_ref/2`'s eight
  # reason atoms (`declare_mount`'s validation gate): `:not_absolute`,
  # `:inside_workspace`, `:ancestor_of_workspace`, `:home_or_root`,
  # `:not_found`, `:no_manifest`, `:unsafe_path`. The eighth,
  # `{:invalid_manifest, reason}`, is a 2-tuple (not a bare atom) and gets
  # its own clause below so it doesn't fall through to the catch-all
  # `inspect/1` code.
  def error_for(:no_workspace), do: Error.new("workspace_not_open")
  def error_for({:invalid_manifest, _reason}), do: Error.new("invalid_manifest")
  def error_for(reason) when is_atom(reason), do: Error.new(to_string(reason))
  def error_for(reason), do: Error.new(inspect(reason))

  defp to_rpc_mount(mount) do
    %{
      name: mount.name,
      title: title_for(mount),
      description: description_for(mount),
      rel_root: mount.rel_root,
      root: mount.root,
      enabled: mount.enabled,
      degraded: mount.degraded
    }
  end

  # A degraded mount may have `manifest: nil` — fall back to the directory
  # basename for `title` and to an empty string for `description` rather
  # than touching `mount.manifest`.
  defp title_for(%{manifest: %{name: name}}), do: name
  defp title_for(%{name: name}), do: name

  defp description_for(%{manifest: %{description: description}}), do: description
  defp description_for(_mount), do: ""

  # The single place both mutating actions regenerate workspace metadata
  # from — MOUNTS.md (the agent-readable mount index) and the managed
  # `.claude/settings.json` (the external-mount `Read` allow set, Plan
  # A2 Task 4) both derive from the SAME post-mutation mount set, so they
  # regenerate together rather than each call site remembering both calls
  # independently. See moduledoc for why `ClaudeSettings.write!/1` needs to
  # run here too, not just at session start.
  defp regenerate_workspace_metadata(root) do
    MountsMd.regenerate(root)
    ClaudeSettings.write!(root)
    :ok
  end

  # Mirrors `Valea.ICM.Watcher`'s own discovery-change broadcast EXACTLY
  # (same module, same topic, same message shape) — see moduledoc.
  defp broadcast_mounts_changed do
    Phoenix.PubSub.broadcast(Valea.PubSub, "mounts", {:mounts_changed})
  end
end
