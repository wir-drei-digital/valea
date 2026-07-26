defmodule Valea.Skills do
  @moduledoc """
  ICM skills: consent-gated install/update/uninstall of repo-vendored
  skill snapshots into a user-owned ICM's `.claude/skills/`, and the
  per-mount state derivation the settings UI renders (ICM skills design
  spec `docs/superpowers/specs/2026-07-26-icm-skills-design.md`).

  The agent never calls this; only the control-token-gated UI RPC
  (`Valea.Api.Skills`) does, and only on an explicit user click — the
  click IS the consent step. After install the files are the user's:
  Valea touches them again only on an explicit update or uninstall.

  State precedence (spec §On-disk contract, first match wins):
  `not_installed` → `foreign` → `edited` → `update_available` →
  `installed`. `foreign` (a dir Valea can't attribute to itself — no
  parseable sidecar, or a symlink inside the tree) is listed read-only
  and never updated or removed through Valea.
  """

  alias Valea.Mounts
  alias Valea.Paths
  alias Valea.Skills.Catalog
  alias Valea.Skills.Provenance

  @spec skill_dir(String.t(), String.t()) :: String.t()
  def skill_dir(icm_root, skill_id),
    do: Path.join([icm_root, ".claude", "skills", skill_id])

  @spec state(map(), String.t()) :: {atom(), %{installed_version: String.t() | nil}}
  def state(entry, icm_root) do
    dir = skill_dir(icm_root, entry.id)

    cond do
      not File.dir?(dir) ->
        {:not_installed, %{installed_version: nil}}

      true ->
        with {:ok, prov} <- Provenance.read(dir),
             {:ok, on_disk} <- Provenance.hash_tree(dir) do
          cond do
            on_disk != prov.files ->
              {:edited, %{installed_version: prov.version}}

            prov.version != entry.pinned ->
              {:update_available, %{installed_version: prov.version}}

            true ->
              {:installed, %{installed_version: prov.version}}
          end
        else
          _no_sidecar_or_symlink -> {:foreign, %{installed_version: nil}}
        end
    end
  end

  @spec list(String.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def list(workspace, mount_key) do
    with {:ok, root} <- effective_root(workspace, mount_key),
         {:ok, catalog} <- Catalog.load() do
      catalog_rows =
        for {_id, entry} <- Enum.sort(catalog) do
          {state, meta} = state(entry, root)

          %{
            skill_id: entry.id,
            name: entry.name,
            description: entry.description,
            source_url: entry.source_url,
            license: entry.license,
            pinned: entry.pinned,
            state: Atom.to_string(state),
            installed_version: meta.installed_version
          }
        end

      {:ok, catalog_rows ++ foreign_rows(root, catalog)}
    end
  end

  # On-disk dirs under .claude/skills/ with no catalog entry: listed
  # read-only as foreign, never mutated through Valea.
  defp foreign_rows(root, catalog) do
    skills_root = Path.join([root, ".claude", "skills"])

    case File.ls(skills_root) do
      {:ok, names} ->
        for name <- Enum.sort(names),
            not Map.has_key?(catalog, name),
            not String.starts_with?(name, ".tmp-"),
            File.dir?(Path.join(skills_root, name)) do
          %{
            skill_id: name,
            name: name,
            description: nil,
            source_url: nil,
            license: nil,
            pinned: nil,
            state: "foreign",
            installed_version: nil
          }
        end

      {:error, _reason} ->
        []
    end
  end

  @spec install(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def install(workspace, mount_key, skill_id) do
    with {:ok, root, entry} <- resolve(workspace, mount_key, skill_id),
         {:ok, skills_root} <- contained_skills_root(root) do
      case state(entry, root) do
        {:not_installed, _meta} -> stage_in(entry, skills_root)
        {:foreign, _meta} -> {:error, :foreign}
        {_installed_any, _meta} -> {:error, :already_installed}
      end
    end
  end

  @spec update(String.t(), String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def update(workspace, mount_key, skill_id, opts \\ []) do
    force = Keyword.get(opts, :force, false)

    with {:ok, root, entry} <- resolve(workspace, mount_key, skill_id),
         {:ok, skills_root} <- contained_skills_root(root) do
      case state(entry, root) do
        {:update_available, _meta} -> replace(entry, skills_root)
        {:edited, _meta} when force -> replace(entry, skills_root)
        {:edited, _meta} -> {:error, :edited}
        {:installed, _meta} -> {:error, :up_to_date}
        {:not_installed, _meta} -> {:error, :not_installed}
        {:foreign, _meta} -> {:error, :foreign}
      end
    end
  end

  @spec uninstall(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def uninstall(workspace, mount_key, skill_id) do
    with {:ok, root, entry} <- resolve(workspace, mount_key, skill_id),
         {:ok, skills_root} <- contained_skills_root(root) do
      case state(entry, root) do
        {:not_installed, _meta} ->
          {:error, :not_installed}

        {:foreign, _meta} ->
          {:error, :foreign}

        {_removable, _meta} ->
          File.rm_rf!(Path.join(skills_root, entry.id))
          :ok
      end
    end
  end

  # -- shared plumbing --------------------------------------------------------

  defp resolve(workspace, mount_key, skill_id) do
    with {:ok, root} <- effective_root(workspace, mount_key),
         {:ok, catalog} <- Catalog.load(),
         %{defect: nil} = entry <- catalog[skill_id] || {:error, :unknown_skill} do
      {:ok, root, entry}
    else
      {:error, _} = err -> err
      %{defect: :snapshot_missing} -> {:error, :snapshot_missing}
    end
  end

  defp effective_root(workspace, mount_key) do
    case Mounts.mount_by_key(workspace, mount_key) do
      %{enabled: true, degraded: nil, root: root} -> {:ok, root}
      _missing_or_ineffective -> {:error, :icm_unavailable}
    end
  end

  # `.claude/skills` must resolve INSIDE the mount root — a symlinked
  # `.claude` (or `skills`) pointing elsewhere refuses rather than follows.
  # `resolve_real` walks symlinks; a missing suffix resolves to where it
  # WOULD live, so a fresh ICM (no `.claude` yet) still passes.
  defp contained_skills_root(root) do
    case Paths.resolve_real(".claude/skills", root) do
      {:ok, resolved} ->
        File.mkdir_p!(resolved)
        {:ok, resolved}

      {:error, _outside_or_invalid} ->
        {:error, :containment}
    end
  end

  defp stage_in(entry, skills_root) do
    staging =
      Path.join(skills_root, ".tmp-#{entry.id}-#{System.unique_integer([:positive])}")

    File.cp_r!(entry.snapshot_dir, staging)

    :ok =
      Provenance.write!(staging, %{
        skill: entry.id,
        version: entry.pinned,
        source_url: entry.source_url
      })

    File.rename!(staging, Path.join(skills_root, entry.id))
    :ok
  end

  # Update: stage the new copy, move the old aside, rename in, drop the old.
  defp replace(entry, skills_root) do
    live = Path.join(skills_root, entry.id)
    aside = Path.join(skills_root, ".tmp-old-#{entry.id}-#{System.unique_integer([:positive])}")

    staging =
      Path.join(skills_root, ".tmp-#{entry.id}-#{System.unique_integer([:positive])}")

    File.cp_r!(entry.snapshot_dir, staging)

    :ok =
      Provenance.write!(staging, %{
        skill: entry.id,
        version: entry.pinned,
        source_url: entry.source_url
      })

    File.rename!(live, aside)
    File.rename!(staging, live)
    File.rm_rf!(aside)
    :ok
  end
end
