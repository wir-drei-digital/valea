defmodule Valea.Workspace.Adopt do
  @moduledoc """
  ICM-aware onboarding: adopts an existing, non-workspace knowledge folder
  into a brand-new workspace BY MOVE. Users commonly have an ICM folder
  before they have Valea — this is the "create a workspace around this
  knowledge module" path, so the open/create dialog never dead-ends on a
  folder that merely isn't a workspace yet.

  Copy is never implemented anywhere in this module (a silent fork of the
  user's knowledge is worse than a clear rejection) — every path either
  moves the folder in place with `File.rename/2` or leaves it completely
  untouched. By-reference adoption (mounting a folder without moving it) is
  a separate, later spec (A2) — this module intentionally does move-only
  and stops there.

  ## `classify_path/1`

  Backs the `inspect_path` RPC's `{kind: "workspace"|"icm"|"other"}`
  branch decision:

    * `{:workspace, nil}` — `Valea.Workspace.Scaffold.valid?/1` — a full
      Valea workspace. Checked FIRST, so a workspace wins even in the
      (contrived) case where its root also happens to carry an `icm.yaml`.
    * `{:icm, manifest}` — not a workspace, but `Valea.Mounts.Manifest.load/1`
      parses a valid `icm.yaml` at `path` — a knowledge module Valea can
      adopt.
    * `{:other, nil}` — anything else, INCLUDING a knowledge-shaped folder
      whose `icm.yaml` is missing or invalid (unparseable YAML, blank/absent
      `name`). This is deliberate, not an oversight: `create_with_icm/3`
      mints a fresh manifest during adoption regardless of whether one was
      there to begin with, so a folder that fails to classify as `:icm`
      here isn't blocked from ever being adopted — it just isn't
      *auto-offered* the one-click "adopt" branch by the onboarding UI,
      which only fires for `:icm`. A future relaxation (offering adoption
      for ANY non-workspace directory, "knowledge-shaped" or not) is a UI
      decision on top of this classification, not a change to it.

  ## `create_with_icm/3`

  Scaffold choice: this scaffolds the FULL shell via
  `Valea.Workspace.Scaffold.create/2` (starter mount included) and then
  removes the starter mount directory, rather than growing a
  starter-mount-less variant of `Scaffold.create/2`. The starter mount is
  Valea's own template content, minted (and, here, deleted) entirely before
  the workspace is ever opened or shown to the user — nothing user-owned is
  at risk, and this keeps `Scaffold.create/2` itself (already covered by
  its own extensive test suite) as the single source of truth for "what a
  fresh shell looks like," rather than forking its internals.

  Rejections (checked before anything touches disk beyond
  read-only `File.dir?`/`File.exists?` probes):

    * the source doesn't exist / isn't a directory — `:source_not_found`
    * the source IS the currently-open workspace's directory —
      `:source_is_open_workspace` (checked before the general
      `:source_is_workspace` case below so the more specific, more
      actionable error wins for this common accident)
    * the source IS a workspace itself (`Scaffold.valid?/1`) —
      `:source_is_workspace`
    * the source is nested inside an existing workspace found by walking
      its ancestors — `:source_in_workspace`
    * `parent_dir` is the source, or nested inside it — `:cycle` (the new
      workspace would be scaffolded inside the very folder about to be
      moved into it)
    * the target (`parent_dir/name`) IS the source — `:target_is_source`
      (adopting a folder into its own parent under its own name). Without
      this guard an EMPTY source would be scaffolded INTO —
      `Scaffold.create/2` accepts an empty existing dir — and then renamed
      into itself, and a non-empty one would bounce off the misleading
      `:target_not_empty` ("that folder already has files in it" — the
      user's own folder). The frontend's `decideOnboardingMode` adjusts its
      default suggested name so a prefilled config never hits this, but a
      hand-edited name still can — this is the backstop.

  A same-device move failure is mapped by `map_move_error/1`; `:exdev`
  (cross-device rename) becomes the distinct `:cross_device` — the
  frontend messages this as "keep the ICM on the same disk as the
  workspace for now" per the by-reference (A2) seam this task leaves
  clean, rather than silently falling back to a copy. Any rename failure
  removes the freshly-scaffolded (still unopened) target directory before
  returning, so a failed adopt never leaves an orphaned half-workspace
  behind — the source is always left exactly as it was.
  """

  alias Valea.Mounts.Manifest
  alias Valea.Mounts.MountsMd
  alias Valea.Workspace.Manager
  alias Valea.Workspace.Scaffold

  @doc "See moduledoc — classifies `path` as `:workspace`, `:icm`, or `:other`."
  @spec classify_path(String.t()) ::
          {:workspace, nil} | {:icm, Manifest.t()} | {:other, nil}
  def classify_path(path) when is_binary(path) do
    if Scaffold.valid?(path) do
      {:workspace, nil}
    else
      case Manifest.load(path) do
        {:ok, manifest} -> {:icm, manifest}
        {:error, _reason} -> {:other, nil}
      end
    end
  end

  @doc """
  Adopts `icm_source_path` into a brand-new workspace scaffolded at
  `Path.join(parent_dir, name)`, by MOVE. See moduledoc for the full
  rejection list and the scaffold-then-remove-starter choice.
  """
  @spec create_with_icm(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def create_with_icm(parent_dir, name, icm_source_path)
      when is_binary(parent_dir) and is_binary(name) and is_binary(icm_source_path) do
    target = Path.join(parent_dir, name)

    with :ok <- validate_source_exists(icm_source_path),
         :ok <- validate_not_open_workspace(icm_source_path),
         :ok <- validate_not_a_workspace(icm_source_path),
         :ok <- validate_not_nested_in_workspace(icm_source_path),
         :ok <- validate_no_cycle(parent_dir, icm_source_path),
         :ok <- validate_target_not_source(target, icm_source_path) do
      do_create_with_icm(target, name, icm_source_path)
    end
  end

  @doc false
  # Public only so the EXDEV branch — not portably reproducible in a
  # sandboxed test run, which has no second filesystem/device to rename
  # across — can be unit-tested directly instead of via a real cross-device
  # move. See moduledoc.
  @spec map_move_error(atom()) :: :cross_device | {:move_failed, atom()}
  def map_move_error(:exdev), do: :cross_device
  def map_move_error(reason), do: {:move_failed, reason}

  # -- rejections -------------------------------------------------------

  defp validate_source_exists(path) do
    if File.dir?(path), do: :ok, else: {:error, :source_not_found}
  end

  defp validate_not_open_workspace(path) do
    case Manager.current() do
      {:ok, %{path: open_path}} ->
        if Path.expand(path) == Path.expand(open_path) do
          {:error, :source_is_open_workspace}
        else
          :ok
        end

      {:error, :no_workspace} ->
        :ok
    end
  end

  defp validate_not_a_workspace(path) do
    if Scaffold.valid?(path), do: {:error, :source_is_workspace}, else: :ok
  end

  defp validate_not_nested_in_workspace(path) do
    if find_workspace_ancestor(Path.dirname(Path.expand(path))) do
      {:error, :source_in_workspace}
    else
      :ok
    end
  end

  defp find_workspace_ancestor(dir) do
    cond do
      Scaffold.valid?(dir) -> dir
      Path.dirname(dir) == dir -> nil
      true -> find_workspace_ancestor(Path.dirname(dir))
    end
  end

  defp validate_no_cycle(parent_dir, icm_source_path) do
    parent = Path.expand(parent_dir)
    source = Path.expand(icm_source_path)

    if parent == source or String.starts_with?(parent, source <> "/") do
      {:error, :cycle}
    else
      :ok
    end
  end

  # See moduledoc (`:target_is_source`) — adopting a folder into its own
  # parent under its own name would scaffold into (empty source) or bounce
  # confusingly off (non-empty source) the very folder being adopted.
  # On case-insensitive filesystems (macOS APFS), string comparison alone
  # misses "client notes" vs "Client Notes" — so also check filesystem
  # identity (inode + device) when target exists.
  defp validate_target_not_source(target, icm_source_path) do
    # Fast path: string comparison catches exact matches and non-existent targets
    if Path.expand(target) == Path.expand(icm_source_path) do
      {:error, :target_is_source}
    else
      # If target already exists, verify it's not the same filesystem object
      # (catches case-insensitive matches and symlinks pointing to source).
      case identity_identical?(target, icm_source_path) do
        true -> {:error, :target_is_source}
        false -> :ok
      end
    end
  end

  # Compare filesystem identity using inode (device-independent uniqueness check).
  # File.stat/2 follows symlinks, so both paths resolve to the same inode if they
  # point to the same filesystem object (catches case-insensitive matches & symlinks).
  defp identity_identical?(path1, path2) do
    with {:ok, stat1} <- File.stat(path1, time: :posix),
         {:ok, stat2} <- File.stat(path2, time: :posix) do
      stat1.inode == stat2.inode
    else
      # If either path doesn't exist or stat fails, they can't be identical
      _ -> false
    end
  end

  # -- the move itself ----------------------------------------------------

  defp do_create_with_icm(target, name, icm_source_path) do
    with :ok <- Scaffold.create(target, name) do
      remove_starter_mount!(target, name)
      move_and_finish(target, icm_source_path)
    end
  end

  # The starter mount was minted by `Scaffold.create/2` a moment ago and has
  # never been opened or shown to anyone — deleting it here is not the
  # never-delete-user-content rule biting, it's discarding Valea's own
  # not-yet-surfaced template output.
  defp remove_starter_mount!(target, name) do
    starter_dir = Path.join(target, "mounts/#{Scaffold.slugify(name)}")
    File.rm_rf!(starter_dir)
  end

  defp move_and_finish(target, icm_source_path) do
    mount_dir = Path.join(target, "mounts/#{Scaffold.slugify(Path.basename(icm_source_path))}")

    case File.rename(icm_source_path, mount_dir) do
      :ok ->
        ensure_manifest!(mount_dir, icm_source_path)
        MountsMd.regenerate(target)
        Manager.open(target)

      {:error, reason} ->
        # Belt-and-suspenders: never delete target if it's the source
        # (filesystem-identical, caught by validate but failsafe here).
        unless identity_identical?(target, icm_source_path) do
          File.rm_rf!(target)
        end

        {:error, map_move_error(reason)}
    end
  end

  # Preserves an existing manifest untouched (it rode along with the
  # `File.rename/2` above); mints a fresh one — name from the folder's own
  # (pre-move) basename — only when absent or unparseable.
  defp ensure_manifest!(mount_dir, icm_source_path) do
    case Manifest.load(mount_dir) do
      {:ok, _manifest} ->
        :ok

      {:error, _reason} ->
        Manifest.write!(mount_dir, %{
          id: Ecto.UUID.generate(),
          name: Path.basename(icm_source_path),
          description: ""
        })
    end
  end
end
