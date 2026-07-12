defmodule Valea.Mounts do
  @moduledoc """
  Discovery, relationship state (enabled/disabled), and the effective
  composition set for `mounts/<name>/` — the unit Plan A refactors the
  single hardcoded `icm/` tree into.

  Two independent sources of truth compose here:
  - The filesystem (`mounts/<name>/icm.yaml`, via `Valea.Mounts.Manifest`)
    is the source of truth for a mount's *identity* — its name is the
    directory basename, nothing more.
  - `config/workspace.yaml`'s `mounts:` section is the source of truth for
    whether a mount is *enabled* — a purely relational, mutable overlay
    that never touches the mount's own files.

  A mount is "degraded" when its `icm.yaml` is missing or invalid: it is
  still discovered and listed (so the UI can show *something* is wrong and
  the user can fix or remove it), but it is always excluded from
  `enabled/0,1` regardless of its config `enabled` flag — the effective set
  every later consumer (ICM tree, Workflows, References, ...) composes
  over.

  A mount whose directory BASENAME itself carries a C0 control character or
  DEL (e.g. a stray newline) is also always degraded — regardless of
  whether its `icm.yaml` is otherwise fine — with reason `"invalid mount
  directory name"`. This is a discovery-time guard, not a rendering one:
  `Valea.Mounts.MountsMd` interpolates a mount's `rel_root` RAW into a live
  `@`-import line for every enabled mount, so a corrupted basename reaching
  that renderer at all would forge a line the routing file's own reader
  can't distinguish from a real import. Quarantining it here — before
  `rel_root` is ever built from the raw name — is the only layer that can
  fix this without breaking the real `@`-import path for legitimately-named
  mounts. `validate_mount_name/1` (used by `set_enabled/2` and `create/3`)
  rejects the same class of name outright for anything this module writes
  itself.
  """

  alias Valea.Mounts.Manifest
  alias Valea.Workspace.Manager
  alias Valea.Workspace.Scaffold
  alias Valea.Yaml

  # A resolved mount. `root` is the ABSOLUTE path; `rel_root` is
  # workspace-relative ("mounts/<name>") for embedded mounts and `nil` for
  # external (by-reference) mounts produced by `Valea.Mounts.External` — an
  # ICM outside the workspace has no workspace-relative path. `enabled` from
  # config. `degraded` carries a reason string when the manifest is
  # missing/broken (still listed for the UI, excluded from the effective
  # set).
  @type mount :: %{
          name: String.t(),
          rel_root: String.t() | nil,
          root: String.t(),
          manifest: %Valea.Mounts.Manifest{} | nil,
          enabled: boolean(),
          degraded: String.t() | nil
        }

  @doc "All discovered mounts in the current workspace (enabled + disabled + degraded), sorted by name."
  @spec list() :: {:ok, [mount]} | {:error, :no_workspace}
  def list do
    with {:ok, ws} <- workspace_root() do
      {:ok, list(ws)}
    end
  end

  @doc "Pure form of `list/0` — every discovered mount under `workspace`, sorted by name."
  @spec list(workspace :: String.t()) :: [mount]
  def list(workspace) when is_binary(workspace) do
    config_mounts = read_config_mounts(workspace)

    workspace
    |> Path.join("mounts/*")
    |> Path.wildcard()
    |> Enum.filter(&File.dir?/1)
    |> Enum.map(&build_mount(&1, config_mounts))
    |> Enum.sort_by(& &1.name)
  end

  @doc "Only enabled, non-degraded mounts in the current workspace — the effective composition set."
  @spec enabled() :: {:ok, [mount]} | {:error, :no_workspace}
  def enabled do
    with {:ok, ws} <- workspace_root() do
      {:ok, enabled(ws)}
    end
  end

  @doc "Pure form of `enabled/0` for `workspace`."
  @spec enabled(workspace :: String.t()) :: [mount]
  def enabled(workspace) when is_binary(workspace) do
    workspace |> list() |> Enum.filter(&effective?/1)
  end

  @doc """
  Resolves a workspace-relative path to the mount that owns it, in the
  current workspace.

  Attribution only — it does not validate or contain the path. Callers
  that go on to do filesystem I/O with `rel_path` must independently
  expand it and prefix-check it against the resolved mount's `root`
  (mirroring `Valea.ICM.contain/2`); this function only identifies which
  mount a path *names*, it does not authorize access to it.
  """
  @spec mount_for(rel_path :: String.t()) ::
          {:ok, mount} | {:error, :not_in_mount | :no_workspace}
  def mount_for(rel_path) when is_binary(rel_path) do
    with {:ok, ws} <- workspace_root() do
      case mount_for(ws, rel_path) do
        nil -> {:error, :not_in_mount}
        mount -> {:ok, mount}
      end
    end
  end

  @doc """
  Pure form of `mount_for/1` for `workspace` — the owning mount, or `nil`.

  Attribution only — it does not validate or contain `rel_path`. Callers
  that go on to do filesystem I/O with `rel_path` must independently
  expand it and prefix-check it against the resolved mount's `root`
  (mirroring `Valea.ICM.contain/2`); this function only identifies which
  mount a path *names*, it does not authorize access to it.
  """
  @spec mount_for(workspace :: String.t(), rel_path :: String.t()) :: mount | nil
  def mount_for(workspace, rel_path) when is_binary(workspace) and is_binary(rel_path) do
    case mount_name_from_rel_path(rel_path) do
      nil -> nil
      name -> workspace |> list() |> Enum.find(&(&1.name == name))
    end
  end

  @doc """
  Sets `mounts.<name>.enabled` in the current workspace's
  `config/workspace.yaml`, writing atomically. Preserves `version`, `id`,
  and every other key on every mount entry (including this one) — so
  hand-added or by-reference-mount fields like `kind`/`ref` survive.

  Rejects a `name` containing `/`, `..`, or a C0 control character/DEL
  (defense in depth: a mount name is a safe directory basename).
  """
  @spec set_enabled(name :: String.t(), boolean()) :: :ok | {:error, term()}
  def set_enabled(name, enabled) when is_binary(name) and is_boolean(enabled) do
    with :ok <- validate_mount_name(name),
         {:ok, ws} <- workspace_root(),
         {:ok, doc} <- read_workspace_config_for_write(ws) do
      write_workspace_config(ws, render_config(doc, name, enabled))
    end
  end

  @doc """
  Scaffolds a brand-new, empty mount under `workspace` — `mounts/<slug>`,
  where `<slug>` is `Scaffold.slugify/1` of `name` (the same slugging a
  fresh workspace scaffold gives its starter mount). `name` here is a
  DISPLAY name, not a directory basename — "Sales/Marketing" or
  "Ops (EU/APAC)" are legitimate business names — so it gets the narrower
  `validate_display_name/1` (non-blank, no C0 control chars/DEL), NOT
  `set_enabled/2`'s strict basename validator: the raw name only ever
  flows into `Scaffold.slugify/1` (which strips everything outside
  `[a-z0-9-]` before any filesystem use), `Manifest.render/1` (which
  `Valea.Yaml.escape/1`s it), and this module's own AGENTS.md skeleton
  heading — a single line, which is exactly why control chars stay
  rejected. It becomes the minted manifest's `name:` (the GIVEN name, not
  the slug).

  Mints a fresh manifest (uuid4 `id`, `name`, `description`) via
  `Manifest.write!/2`, and a minimal self-describing `AGENTS.md` +
  `CLAUDE.md` (`@AGENTS.md`) skeleton — the mount's ICM is empty at
  creation; the skeleton says so and invites it to grow. A directory
  collision (the slug already exists) is rejected outright
  (`{:error, :already_exists}`) rather than disambiguated, mirroring
  `Valea.ICM.create_page/2`'s stance on name collisions.

  Does NOT touch `config/workspace.yaml` (a freshly created mount is
  enabled by default — `config_enabled?/2`'s absent-means-true default
  already covers it) or regenerate `MOUNTS.md` — callers that need it
  refreshed (the `create_mount` RPC action) call
  `Valea.Mounts.MountsMd.regenerate/1` themselves, same as `set_enabled/2`'s
  callers already do.
  """
  @spec create(workspace :: String.t(), name :: String.t(), description :: String.t()) ::
          {:ok, mount} | {:error, term()}
  def create(workspace, name, description)
      when is_binary(workspace) and is_binary(name) and is_binary(description) do
    with :ok <- validate_display_name(name) do
      slug = Scaffold.slugify(name)
      dir = Path.join([workspace, "mounts", slug])

      if File.exists?(dir) do
        {:error, :already_exists}
      else
        do_create(dir, name, description, workspace)
      end
    end
  end

  # Display-name validator for `create/3` — deliberately NARROWER than
  # `validate_mount_name/1` (the directory-basename validator `set_enabled/2`
  # keeps): a display name may legitimately contain `/` or `..`
  # ("Sales/Marketing"), since `Scaffold.slugify/1` strips everything outside
  # [a-z0-9-] before the name ever touches the filesystem and
  # `Manifest.render/1` Yaml.escape's it. Control chars/DEL stay rejected
  # (the raw name lands single-line in the AGENTS.md skeleton heading), and
  # a blank (all-whitespace) name is rejected too — it would slugify to the
  # "mount" fallback and mint a manifest that `Manifest.load/1` immediately
  # degrades ("name must not be blank").
  defp validate_display_name(name) do
    if String.trim(name) == "" or control_chars?(name) do
      {:error, :invalid_mount_name}
    else
      :ok
    end
  end

  defp do_create(dir, name, description, workspace) do
    File.mkdir_p!(dir)

    Manifest.write!(dir, %{id: Ecto.UUID.generate(), name: name, description: description})
    File.write!(Path.join(dir, "AGENTS.md"), agents_md_skeleton(name, description))
    File.write!(Path.join(dir, "CLAUDE.md"), "@AGENTS.md\n")

    {:ok, build_mount(dir, read_config_mounts(workspace))}
  end

  defp agents_md_skeleton(name, description) do
    body = if String.trim(description) == "", do: "No description yet.", else: description

    """
    # This mount: #{name}

    #{body}

    This mount is new and empty — it has no pages yet. As Clients, Offers,
    Workflows, or other pages are added here, describe them in this file
    the way another mount's own AGENTS.md does, so an agent reading this
    file knows what it can rely on.
    """
  end

  # -- discovery ---------------------------------------------------------

  defp build_mount(dir, config_mounts) do
    name = Path.basename(dir)

    if control_chars?(name) do
      degraded_basename_mount(dir, name, config_mounts)
    else
      {manifest, degraded} = load_manifest(dir)

      %{
        name: name,
        rel_root: Path.join("mounts", name),
        root: Path.expand(dir),
        manifest: manifest,
        enabled: config_enabled?(config_mounts, name),
        degraded: degraded
      }
    end
  end

  # A directory basename carrying a C0 control char or DEL (e.g. a newline)
  # is quarantined unconditionally — degraded regardless of whether its
  # icm.yaml is otherwise valid, so it can never reach `effective?/1` (never
  # enabled) or `MountsMd`'s enabled/deactivated render paths, which both
  # interpolate `rel_root` RAW into a live `@`-import line. `rel_root` here
  # is built from a SANITIZED display name (control-char runs collapsed to a
  # single space, mirroring `MountsMd`'s own `sanitize/1`) rather than the
  # raw basename: `rel_root` is the one field a degraded mount still renders
  # into MOUNTS.md (the "Needs attention" line), so this is the layer where
  # that value must already be safe — the renderer cannot fix it without
  # corrupting the real `@`-import path for legitimately-named mounts. `name`
  # stays the raw basename (round-trips identification; MountsMd's own
  # `sanitize/1` already neutralizes it at that render site), and `root`
  # stays the real, unsanitized absolute path — filesystem calls, unlike
  # text rendered into a routing file, don't care about control chars.
  defp degraded_basename_mount(dir, name, config_mounts) do
    %{
      name: name,
      rel_root: Path.join("mounts", sanitize_display(name)),
      root: Path.expand(dir),
      manifest: nil,
      enabled: config_enabled?(config_mounts, name),
      degraded: "invalid mount directory name"
    }
  end

  defp control_chars?(name), do: Regex.match?(~r/[\x00-\x1F\x7F]/, name)

  defp sanitize_display(name), do: String.replace(name, ~r/[\x00-\x1F\x7F]+/, " ")

  defp load_manifest(dir) do
    case Manifest.load(dir) do
      {:ok, manifest} -> {manifest, nil}
      {:error, :missing} -> {nil, "icm.yaml is missing"}
      {:error, {:invalid, reason}} -> {nil, reason}
    end
  end

  defp effective?(%{enabled: true, degraded: nil}), do: true
  defp effective?(_), do: false

  defp mount_name_from_rel_path(rel_path) do
    case Path.split(rel_path) do
      ["mounts", name | _rest] when name not in ["", ".", ".."] -> name
      _ -> nil
    end
  end

  defp workspace_root do
    case Manager.current() do
      {:ok, %{path: ws}} -> {:ok, ws}
      {:error, :no_workspace} -> {:error, :no_workspace}
    end
  end

  # -- relationship-state config (config/workspace.yaml `mounts:`) -------

  defp config_path(workspace), do: Path.join(workspace, "config/workspace.yaml")

  defp read_workspace_config(workspace) do
    case YamlElixir.read_from_file(config_path(workspace)) do
      {:ok, doc} when is_map(doc) -> {:ok, doc}
      {:ok, _not_a_map} -> {:ok, %{}}
      {:error, %YamlElixir.FileNotFoundError{}} -> {:ok, %{}}
      {:error, _reason} -> {:ok, %{}}
    end
  end

  # Write-path variant of `read_workspace_config/1`. A missing file is safe
  # to treat as an empty config (there is nothing on disk to lose). Any
  # other failure to read an EXISTING file — parse error, or a document
  # that didn't parse to a map — must not fall through to `%{}`: doing so
  # would make `set_enabled/2` atomically overwrite a real (if currently
  # unreadable) config, discarding `version`/`id` and anything else in it.
  # Callers must treat this as a hard stop, not a fail-open default.
  defp read_workspace_config_for_write(workspace) do
    case YamlElixir.read_from_file(config_path(workspace)) do
      {:ok, doc} when is_map(doc) -> {:ok, doc}
      {:error, %YamlElixir.FileNotFoundError{}} -> {:ok, %{}}
      {:ok, not_a_map} -> {:error, {:config_unreadable, {:not_a_map, not_a_map}}}
      {:error, reason} -> {:error, {:config_unreadable, reason}}
    end
  end

  @doc false
  # Internal-public for `Valea.Mounts.External` (BY-REFERENCE mounts): reads
  # the same `mounts:` section this module's own discovery reads, keyed by
  # config name, string keys/values as parsed by YamlElixir. Not part of the
  # public contract — do not call from outside the `Valea.Mounts` namespace.
  @spec read_config_mounts(workspace :: String.t()) :: map()
  def read_config_mounts(workspace) do
    case read_workspace_config(workspace) do
      {:ok, doc} -> normalize_mounts(Map.get(doc, "mounts"))
    end
  end

  defp normalize_mounts(mounts) when is_map(mounts), do: mounts
  defp normalize_mounts(_not_a_map), do: %{}

  defp config_enabled?(config_mounts, name) do
    case config_mounts[name] do
      %{"enabled" => false} -> false
      _ -> true
    end
  end

  defp validate_mount_name(name) do
    if name == "" or String.contains?(name, "/") or String.contains?(name, "..") or
         control_chars?(name) do
      {:error, :invalid_mount_name}
    else
      :ok
    end
  end

  defp write_workspace_config(workspace, contents) do
    path = config_path(workspace)
    tmp = path <> ".tmp"

    with :ok <- File.write(tmp, contents) do
      File.rename(tmp, path)
    end
  end

  # -- rendering: preserves version/id + every key on every mount entry --

  defp render_config(doc, name, enabled) do
    mounts =
      doc
      |> Map.get("mounts")
      |> normalize_mounts()
      |> put_enabled(name, enabled)

    header = [top_level_line(doc, "version"), top_level_line(doc, "id")] |> Enum.reject(&is_nil/1)
    lines = header ++ render_mounts_section(mounts)
    Enum.join(lines, "\n") <> "\n"
  end

  defp put_enabled(mounts, name, enabled) do
    entry =
      case Map.get(mounts, name) do
        m when is_map(m) -> m
        _absent_or_invalid -> %{}
      end

    Map.put(mounts, name, Map.put(entry, "enabled", enabled))
  end

  defp top_level_line(doc, key) do
    case Map.fetch(doc, key) do
      {:ok, value} -> "#{key}: #{render_scalar(value)}"
      :error -> nil
    end
  end

  defp render_mounts_section(mounts) when map_size(mounts) == 0, do: ["mounts: {}"]

  defp render_mounts_section(mounts) do
    entries =
      mounts
      |> Enum.sort_by(fn {name, _entry} -> name end)
      |> Enum.flat_map(fn {name, entry} ->
        ["  #{yaml_key(name)}:" | render_entry_lines(entry)]
      end)

    ["mounts:" | entries]
  end

  defp render_entry_lines(entry) when map_size(entry) == 0, do: ["    {}"]

  defp render_entry_lines(entry) do
    entry
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, value} -> "    #{yaml_key(key)}: #{render_scalar(value)}" end)
  end

  defp yaml_key(key) when is_binary(key), do: Yaml.escape(key)
  defp yaml_key(key), do: Yaml.escape(to_string(key))

  defp render_scalar(value) when is_binary(value), do: Yaml.escape(value)
  defp render_scalar(value) when is_boolean(value), do: to_string(value)
  defp render_scalar(value) when is_integer(value), do: Integer.to_string(value)
  defp render_scalar(value) when is_float(value), do: to_string(value)
  defp render_scalar(nil), do: "null"
  defp render_scalar(value), do: Yaml.escape(inspect(value))
end
