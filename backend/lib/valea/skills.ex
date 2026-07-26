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
end
