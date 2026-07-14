defmodule Valea.Icm.Locator do
  @moduledoc """
  A stable, JSON-safe address for a file that survives an ICM being moved
  or an agent working across multiple mounted ICMs plus the workspace's
  own tree.

  Every OTHER path vocabulary in this codebase (`Valea.ICM`'s
  workspace-relative `mounts/<name>/…` for embedded mounts, absolute
  physical paths for external ones) is anchored to a mount's CURRENT
  location — rename the mount key, move the ICM folder on disk, or
  re-mount the same ICM under a different key, and a persisted path goes
  stale. A locator instead pairs the ICM's own stable `icm.yaml` `id:`
  with a path RELATIVE TO THAT ICM's root; `resolve/2` re-derives the
  current physical root from the workspace's live mount table
  (`Valea.Mounts.mount_by_id/2`) every time, so a persisted locator keeps
  resolving correctly across a move/remount. A workspace-native path (not
  inside any mounted ICM) has no such indirection to offer — its locator
  is just its path relative to the workspace root, resolved directly
  against it.

  Both locator shapes are plain maps with STRING keys — JSON-safe as-is,
  no atom-exhaustion risk decoding one back from storage (a queue entry,
  an audit record, Phase 7):

      %{"kind" => "icm", "icm_id" => "<uuid>", "path" => "Pricing/Current Pricing.md"}
      %{"kind" => "workspace", "path" => "sources/mail/messages/42.md"}

  `resolve/2` is the one place a locator turns back into a physical path
  to actually touch — and the one place containment matters. It never
  builds that path itself: it delegates to `Valea.Paths.resolve_real/2`,
  the same symlink-hardened, physically-walked containment chokepoint
  every other ICM/workspace path operation goes through. A `path` that
  tries to escape via `..` or an absolute override, or that walks through
  a symlink to somewhere else, comes back `{:error, :outside}` —
  containment is `resolve_real/2`'s job alone and is never re-implemented
  or weakened here.

  Before an ICM locator's `path` is even handed to `resolve_real/2`, its
  `icm_id` is checked against the workspace's CURRENT mount table
  (`Valea.Mounts.mount_by_id/2`, which only ever returns a HEALTHY —
  non-degraded — mount, matched by manifest id regardless of its enabled
  state): no mount with that id at all is `:icm_not_mounted`; a disabled
  mount is `:icm_disabled`; a mount whose own `degraded` field somehow
  carries a reason is `:icm_degraded` (defensive — `mount_by_id/2`
  currently never returns a degraded mount at all, since a degraded
  entry's id can't be trusted to match against, but the guard costs
  nothing and keeps this resilient to that contract narrowing further).
  Only a healthy, enabled mount's resolved root is ever handed to
  `resolve_real/2` as the containment base.

  `for_path/2` is the inverse direction — given a physical absolute path
  (already known-good, e.g. one just written to or read from disk),
  attribute it to the mount that owns it (`Valea.Mounts.mount_for/2` —
  attribution among enabled, non-degraded mounts, most-specific-root on
  overlap) and produce an ICM locator (id + path relative to that mount's
  root); a path outside every mount instead produces a workspace locator
  (path relative to the workspace root). Used to SNAPSHOT a locator for
  something persisted later (an audit entry, a queue item — Phase 7),
  not for containment; it does not itself validate that `physical_abs`
  stays inside the workspace or any mount — the caller already has an
  attributionally-valid absolute path in hand.
  """

  alias Valea.Mounts
  alias Valea.Paths

  @doc """
  Builds an ICM locator: `icm_id` is a mounted ICM's stable `icm.yaml`
  `id:`, `rel_path` is relative to THAT ICM's own root (never
  workspace-relative, never absolute).
  """
  @spec icm(icm_id :: String.t(), rel_path :: String.t()) :: map()
  def icm(icm_id, rel_path) when is_binary(icm_id) and is_binary(rel_path) do
    %{"kind" => "icm", "icm_id" => icm_id, "path" => rel_path}
  end

  @doc """
  Builds a workspace locator: `rel_path` is relative to the workspace
  root (not inside any mounted ICM).
  """
  @spec workspace(rel_path :: String.t()) :: map()
  def workspace(rel_path) when is_binary(rel_path) do
    %{"kind" => "workspace", "path" => rel_path}
  end

  @doc """
  Resolves `locator` to its CURRENT physical absolute path in `workspace`.

  An icm locator's `icm_id` is looked up against the workspace's live
  mount table before its `path` is ever touched — see the moduledoc for
  the full nil/degraded/disabled guard order. A workspace locator's
  `path` resolves directly against `workspace`. Either way, the final
  step is always `Valea.Paths.resolve_real/2` — the sole containment
  chokepoint, never re-implemented here.
  """
  @spec resolve(workspace :: String.t(), locator :: map()) ::
          {:ok, String.t()}
          | {:error, :icm_not_mounted | :icm_disabled | :icm_degraded | :outside | :invalid}
  def resolve(workspace, %{"kind" => "icm", "icm_id" => icm_id, "path" => path})
      when is_binary(workspace) and is_binary(icm_id) and is_binary(path) do
    case Mounts.mount_by_id(workspace, icm_id) do
      nil ->
        {:error, :icm_not_mounted}

      %{degraded: reason} when not is_nil(reason) ->
        {:error, :icm_degraded}

      %{enabled: false} ->
        {:error, :icm_disabled}

      %{root: root} ->
        Paths.resolve_real(path, root)
    end
  end

  def resolve(workspace, %{"kind" => "workspace", "path" => path})
      when is_binary(workspace) and is_binary(path) do
    Paths.resolve_real(path, workspace)
  end

  def resolve(_workspace, _locator), do: {:error, :invalid}

  @doc """
  Attributes an already-known-good physical absolute path to a locator:
  an ICM locator (id + path relative to the owning mount's root) when
  `physical_abs` falls under a currently enabled, non-degraded mount
  (`Valea.Mounts.mount_for/2`), otherwise a workspace locator (path
  relative to `workspace`).
  """
  @spec for_path(workspace :: String.t(), physical_abs :: String.t()) :: map()
  def for_path(workspace, physical_abs)
      when is_binary(workspace) and is_binary(physical_abs) do
    case Mounts.mount_for(workspace, physical_abs) do
      %{root: root, manifest: %{id: id}} ->
        icm(id, Path.relative_to(physical_abs, root))

      nil ->
        workspace(Path.relative_to(physical_abs, workspace))
    end
  end
end
