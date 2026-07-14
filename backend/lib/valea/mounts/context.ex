defmodule Valea.Mounts.Context do
  @moduledoc """
  Resolves a primary ICM's DIRECTLY-declared related ICMs from its own
  `CONTEXT.md` frontmatter (spec §"Related ICMs"):

  ```yaml
  ---
  format: 1
  related_icms:
    - id: 31201697-cff8-4d99-9dc5-b140e4178716
      name: "Legal & Administration"
      entrypoint: CONTEXT.md
  ---
  ```

  `resolve/2` reads `<primary_mount.root>/CONTEXT.md` (missing file, no
  frontmatter, or an absent/non-list `related_icms` all yield
  `%{related: [], issues: []}` — this is a soft, optional declaration, never
  a hard requirement) and, for each declared entry, resolves `id` against the
  CURRENT workspace mount table (`Valea.Mounts.mount_by_id/2` plus
  `Valea.Mounts.list/1` to disambiguate WHY a lookup missed) and its
  `entrypoint` (default `"CONTEXT.md"`) against the related ICM's OWN root
  via `Valea.Paths.resolve_real/2` — an entrypoint that resolves outside that
  root is a hard reject (`:entrypoint_escapes`), never granted, regardless of
  how "close" it looks lexically.

  Direct-only, cycle-safe by construction: this module never reads a related
  ICM's own `CONTEXT.md` — only the primary's. A related ICM that itself
  declares the primary (or anything else) back is simply never visited, so a
  cyclic declaration is inert rather than an infinite loop or an unbounded
  read-surface expansion.
  """

  alias Valea.ICM
  alias Valea.Mounts
  alias Valea.Paths

  @default_entrypoint "CONTEXT.md"

  @type resolved :: %{
          mount_key: String.t(),
          id: String.t(),
          root: String.t(),
          entrypoint: String.t(),
          manifest: Valea.Mounts.Manifest.t()
        }

  @type issue :: %{
          id: String.t() | nil,
          name: String.t() | nil,
          reason: :not_mounted | :disabled | :degraded | :duplicate_id | :entrypoint_escapes
        }

  @doc """
  `%{related: [resolved], issues: [issue]}` for every ICM `primary_mount`'s
  own `CONTEXT.md` directly declares under `related_icms:` — see the
  moduledoc for the missing-file/absent-declaration default and the
  cycle-safety guarantee.
  """
  @spec resolve(workspace :: String.t(), primary_mount :: Mounts.mount()) :: %{
          related: [resolved],
          issues: [issue]
        }
  def resolve(workspace, primary_mount) when is_binary(workspace) and is_map(primary_mount) do
    primary_mount.root
    |> read_related_icms()
    |> Enum.reduce({[], []}, fn entry, {related, issues} ->
      case resolve_entry(workspace, entry) do
        {:ok, resolved} -> {[resolved | related], issues}
        {:error, issue} -> {related, [issue | issues]}
      end
    end)
    |> then(fn {related, issues} ->
      %{related: Enum.reverse(related), issues: Enum.reverse(issues)}
    end)
  end

  # -- CONTEXT.md frontmatter -----------------------------------------------

  defp read_related_icms(primary_root) do
    case File.read(Path.join(primary_root, "CONTEXT.md")) do
      {:ok, content} -> parse_related_icms(content)
      {:error, _reason} -> []
    end
  end

  defp parse_related_icms(content) do
    {block, _body} = ICM.split_frontmatter(content)

    with true <- block != "",
         yaml <- block |> String.trim_leading("---\n") |> String.trim_trailing("---\n"),
         {:ok, doc} when is_map(doc) <- YamlElixir.read_from_string(yaml),
         1 <- Map.get(doc, "format", 1),
         list when is_list(list) <- Map.get(doc, "related_icms") do
      Enum.filter(list, &is_map/1)
    else
      _ -> []
    end
  end

  # -- per-entry resolution ---------------------------------------------------

  defp resolve_entry(workspace, %{"id" => id} = entry) when is_binary(id) do
    name = Map.get(entry, "name")
    entrypoint = entry |> Map.get("entrypoint") |> default_if_blank()

    case find_related_mount(workspace, id) do
      {:ok, mount} -> resolve_entrypoint(mount, id, name, entrypoint)
      {:error, reason} -> {:error, %{id: id, name: name, reason: reason}}
    end
  end

  # A declared entry with no (or a non-string) `id` can never resolve against
  # the mount table — folded into the same `:not_mounted` an absent id would
  # produce, rather than crashing on a hand-edited/malformed CONTEXT.md.
  defp resolve_entry(_workspace, entry) do
    {:error, %{id: Map.get(entry, "id"), name: Map.get(entry, "name"), reason: :not_mounted}}
  end

  defp default_if_blank(v) when is_binary(v) do
    if String.trim(v) == "", do: @default_entrypoint, else: v
  end

  defp default_if_blank(_not_a_string), do: @default_entrypoint

  # `mount_by_id/2` already requires HEALTHY (`degraded == nil`); this only
  # additionally requires ENABLED (brief: "require enabled + degraded ==
  # nil"). A `nil` from `mount_by_id/2` means either the id is not mounted at
  # all, or it IS mounted but degraded (generically, or because the id is
  # ambiguous) — `disambiguate_miss/2` tells those apart via `Mounts.list/1`
  # so the issue carries the right reason instead of a blanket `:not_mounted`.
  defp find_related_mount(workspace, id) do
    case Mounts.mount_by_id(workspace, id) do
      %{enabled: true} = mount -> {:ok, mount}
      %{enabled: false} -> {:error, :disabled}
      nil -> disambiguate_miss(workspace, id)
    end
  end

  defp disambiguate_miss(workspace, id) do
    case Enum.find(Mounts.list(workspace), &(&1.manifest != nil and &1.manifest.id == id)) do
      nil -> {:error, :not_mounted}
      %{degraded: reason} -> {:error, degraded_reason(reason)}
    end
  end

  # `Valea.Mounts.degrade_duplicate_ids/1` is the only degradation path that
  # still leaves a `manifest` on the entry (see its own doc) and always
  # stamps this exact prefix — every other still-manifested degradation here
  # is the duplicate-ROOT post-pass, a plain `:degraded`.
  defp degraded_reason("ambiguous id" <> _rest), do: :duplicate_id
  defp degraded_reason(_other), do: :degraded

  defp resolve_entrypoint(mount, id, name, entrypoint) do
    case Paths.resolve_real(entrypoint, mount.root) do
      {:ok, resolved_entrypoint} ->
        {:ok,
         %{
           mount_key: mount.name,
           id: id,
           root: mount.root,
           entrypoint: resolved_entrypoint,
           manifest: mount.manifest
         }}

      {:error, _reason} ->
        {:error, %{id: id, name: name, reason: :entrypoint_escapes}}
    end
  end
end
