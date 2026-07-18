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

  ## Mail opt-in grammar (Task 14, mail spec §"Mount & containment")

  A `related_icms:` LIST ENTRY that is a bare STRING `mail-<slug>` opts the
  session into that account's synthetic mail mount:

  ```yaml
  related_icms:
    - mail-wirdrei
  ```

  It resolves via `Valea.Mounts.mount_by_key/2` and requires an ENABLED,
  non-degraded `kind: :mail` mount — anything else (unconfigured account,
  degraded identity, or an `icms:` entry shadowing the key) surfaces as a
  `:mail_unavailable` issue, never a grant. The resolved entry has `id:
  nil`, `entrypoint: nil`, `manifest: nil`, `kind: :mail`.

  The bare string `calendar` (Spec F Task 5, calendar spec §"Mounts and
  policy") works the same way over the ONE synthetic calendar mount:
  it requires an enabled, non-degraded `kind: :calendar` mount (i.e.
  `config/calendar.yaml` exists and no `icms:` entry shadows the key)
  and resolves to the same entry shape with `kind: :calendar`; anything
  else is the same `:mail_unavailable` issue (the issue carries the
  entry's own name, so the UI can still say WHAT is unavailable).

  Bare strings outside the `mail-*` namespace and the exact `calendar`
  key are dropped exactly like any other malformed entry always was; map
  entries keep the ICM id semantics untouched (`kind: :icm`).
  """

  alias Valea.ICM
  alias Valea.Mounts
  alias Valea.Paths

  @default_entrypoint "CONTEXT.md"

  @type resolved :: %{
          mount_key: String.t(),
          id: String.t() | nil,
          root: String.t(),
          entrypoint: String.t() | nil,
          manifest: Valea.Mounts.Manifest.t() | nil,
          kind: :icm | :mail | :calendar
        }

  @type issue :: %{
          id: String.t() | nil,
          name: String.t() | nil,
          reason:
            :not_mounted
            | :disabled
            | :degraded
            | :duplicate_id
            | :entrypoint_escapes
            | :mail_unavailable
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
      # Maps are ICM id entries; a bare string is only meaningful in the
      # `mail-*` namespace (the mail opt-in grammar) or as the exact
      # `calendar` key (Spec F Task 5) — anything else stays dropped, as
      # every non-map entry always was.
      Enum.filter(
        list,
        &(is_map(&1) or
            (is_binary(&1) and (String.starts_with?(&1, "mail-") or &1 == "calendar")))
      )
    else
      _ -> []
    end
  end

  # -- per-entry resolution ---------------------------------------------------

  # Bare-string mail entry (Task 14): must resolve to an ENABLED,
  # non-degraded `kind: :mail` mount — the `kind` requirement is
  # load-bearing (a legacy `icms:` key inside the `mail-*` namespace
  # shadows the synthetic mount in `mount_by_key/2`; it must NOT grant
  # anything through the mail grammar). Everything else is
  # `:mail_unavailable` — configured-but-degraded and absent alike.
  defp resolve_entry(workspace, "mail-" <> _slug = mount_key) when is_binary(mount_key) do
    case Mounts.mount_by_key(workspace, mount_key) do
      %{kind: :mail, enabled: true, degraded: nil, root: root} ->
        {:ok,
         %{
           mount_key: mount_key,
           id: nil,
           root: root,
           entrypoint: nil,
           manifest: nil,
           kind: :mail
         }}

      _unavailable ->
        {:error, %{id: nil, name: mount_key, reason: :mail_unavailable}}
    end
  end

  # Bare-string calendar entry (Spec F Task 5): the mail grammar verbatim
  # over the single `calendar` mount — the `kind: :calendar` requirement is
  # just as load-bearing (an `icms:` entry named `calendar` shadows the
  # synthetic mount in `mount_by_key/2`; it must NOT grant anything through
  # this grammar). Unavailable (no `config/calendar.yaml`, or shadowed) is
  # the same issue shape the mail grammar produces — the issue's `name`
  # says what was declared.
  defp resolve_entry(workspace, "calendar") do
    case Mounts.mount_by_key(workspace, "calendar") do
      %{kind: :calendar, enabled: true, degraded: nil, root: root} ->
        {:ok,
         %{
           mount_key: "calendar",
           id: nil,
           root: root,
           entrypoint: nil,
           manifest: nil,
           kind: :calendar
         }}

      _unavailable ->
        {:error, %{id: nil, name: "calendar", reason: :mail_unavailable}}
    end
  end

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
           manifest: mount.manifest,
           kind: :icm
         }}

      {:error, _reason} ->
        {:error, %{id: id, name: name, reason: :entrypoint_escapes}}
    end
  end
end
