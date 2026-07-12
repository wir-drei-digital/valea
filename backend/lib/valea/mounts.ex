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
  """

  alias Valea.Mounts.Manifest
  alias Valea.Workspace.Manager
  alias Valea.Yaml

  # A resolved mount. `root` is the ABSOLUTE path; `rel_root` is
  # workspace-relative ("mounts/<name>"). `enabled` from config. `degraded`
  # carries a reason string when the manifest is missing/broken (still listed
  # for the UI, excluded from the effective set).
  @type mount :: %{
          name: String.t(),
          rel_root: String.t(),
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

  @doc "Resolves a workspace-relative path to the mount that owns it, in the current workspace."
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

  @doc "Pure form of `mount_for/1` for `workspace` — the owning mount, or `nil`."
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

  Rejects a `name` containing `/` or `..` (defense in depth: a mount name
  is a safe directory basename).
  """
  @spec set_enabled(name :: String.t(), boolean()) :: :ok | {:error, term()}
  def set_enabled(name, enabled) when is_binary(name) and is_boolean(enabled) do
    with :ok <- validate_mount_name(name),
         {:ok, ws} <- workspace_root(),
         {:ok, doc} <- read_workspace_config(ws) do
      write_workspace_config(ws, render_config(doc, name, enabled))
    end
  end

  # -- discovery ---------------------------------------------------------

  defp build_mount(dir, config_mounts) do
    name = Path.basename(dir)
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

  defp read_config_mounts(workspace) do
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
    if String.contains?(name, "/") or String.contains?(name, "..") do
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
