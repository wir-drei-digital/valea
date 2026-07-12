defmodule Valea.Agents.PermissionPolicy do
  @moduledoc """
  deny -> allow -> ask, unclassifiable = ask (spec §PermissionPolicy).

  Pure: decisions depend only on the permission item and the ctx. Every
  decision is audited by the `SessionServer`, not here.

  All path reasoning goes through `Valea.Paths.resolve_real/2` so a symlink
  inside the workspace can never smuggle a read/write outside it. The
  workspace base and the workflow write targets are ALSO symlink-resolved
  before comparison — otherwise `/var` vs `/private/var` (macOS) and any
  other symlinked ancestor would defeat the containment and exact-match
  checks.

  ## Root-set containment (A2-T3, by-reference/external mounts)

  Containment generalizes from a single workspace root to a ROOT SET: the
  workspace root (existing `read_roots` logic, unchanged) UNION every
  member of `ctx[:extra_roots]` — absolute, already-realpath-resolved
  external mount roots (`Valea.Mounts.enabled/1` entries with
  `rel_root: nil`; see `SessionServer.init/1`, which computes both lists
  fresh at every session start). The invariants:

    * A path is readable iff its `resolve_real` result lands inside SOME
      enabled root — the workspace root or any `extra_roots` member.
    * A symlink inside an external root escaping it is DENIED unless it
      resolves into ANOTHER enabled root: the candidate NOMINALLY claims a
      currently-enabled root (by its raw, un-resolved path — the "physical
      paths" the ACP layer always uses for external candidates), but its
      TRUE resolved location lands in no enabled root at all. This is a
      stronger signal than an ordinary unrecognized path (which merely
      ask-gates, below) — the address itself lied about where it points,
      so it fails closed the same way the deny-list does.
    * The deny-list applies to the WORKSPACE tree only — external mounts
      have no Valea-managed deny-list (the secrets-hygiene doctor warning
      is a separate concern). A path inside the workspace that IS
      deny-listed stays denied even when some `extra_roots` member would
      also (coincidentally) match it — the deny-list check runs first and
      is unconditional.
    * Write containment is UNCHANGED: `extra_roots` grants READS only. A
      write target under an external root is never auto-allowed by it.
    * A disabled or degraded external mount is simply absent from
      `extra_roots` (see `SessionServer`'s `extra_roots/1`) — its reads
      ask-gate, exactly like a disabled embedded mount's `read_roots`
      absence. Absence is never itself a deny.
    * An absolute path that never nominally claimed ANY enabled root (not
      the workspace, not an `extra_roots` member) is simply unrecognized —
      ask-gates like any other unclassifiable candidate, it does NOT hard
      deny (that blanket "anything outside the workspace is denied"
      behavior predates external mounts and no longer holds).
  """

  @protected_dirs ["secrets", "logs", ".claude", ".git"]
  @db_prefix "app.sqlite"
  @read_kinds ["read"]
  @write_kinds ["edit", "write", "delete", "move"]
  # Fallback when a caller starts a session without computing read_roots
  # (e.g. a bare PermissionPolicy.decide/2 call in a test). The real value
  # every live session gets is computed at session start
  # (`SessionServer.init/1`): `["sources"] ++ Enum.map(Mounts.enabled(ws), &
  # &1.rel_root)`, so each mount's `mounts/<name>` is a read root ONLY while
  # that mount is enabled — a disabled/absent mount is simply not in the
  # list, so its reads fall through to `:ask` (never a hard deny; deny is
  # reserved for the protected dirs above). `icm` and `prompts` are gone
  # from the default: `icm/` no longer exists (mounts replaced it) and
  # `prompts/` now lives inside each mount, covered by that mount's own
  # `mounts/<name>` root.
  @default_read_roots ["sources"]
  @root_files ["AGENTS.md", "CLAUDE.md"]

  @spec decide(map(), map()) :: :ask | {:allow, String.t()} | {:deny, String.t()}
  def decide(item, ctx) do
    kind = item["kind"]
    read_roots = ctx[:read_roots] || @default_read_roots
    # Fallback `[]` mirrors `read_roots`' own bare-call fallback above: a
    # caller (or test) that starts a session/calls `decide/2` directly
    # without computing extra_roots simply gets no external read surface,
    # never a crash.
    extra_roots = ctx[:extra_roots] || []
    ws = base_real(ctx.workspace)
    paths = extract_paths(item)
    resolved = Enum.map(paths, &resolve_candidate(&1, ctx.workspace))
    pairs = Enum.zip(paths, resolved)

    cond do
      Enum.any?(resolved, &denied?(&1, ws)) ->
        {:deny, "reject_once"}

      Enum.any?(pairs, fn {raw, r} ->
        escaped_root?(raw, r, ctx.workspace, ws, read_roots, extra_roots)
      end) ->
        {:deny, "reject_once"}

      paths == [] ->
        :ask

      Enum.any?(resolved, &(elem(&1, 0) == :error)) ->
        :ask

      kind in @read_kinds and all_in_read_roots?(resolved, ws, read_roots, extra_roots) ->
        {:allow, "allow_once"}

      kind in @write_kinds and ctx.session_kind == "workflow" and
          all_in_write_paths?(resolved, ctx.write_paths, ctx.workspace) ->
        {:allow, "allow_once"}

      true ->
        :ask
    end
  end

  # Absolute candidates (every external-mount read arrives this way — the
  # "physical paths" constraint: the agent always addresses a by-reference
  # mount's contents by its real absolute location, never workspace-
  # relative) are resolved against THEMSELVES. `resolve_real/2` only ever
  # returns the walked path when it lands inside `base` — a FIXED workspace
  # base would swallow every legitimately-external result as
  # `{:error, :outside}` before extra_roots membership could ever be
  # checked. Passing the candidate as its own base makes containment
  # trivially satisfied (`resolved == base_real`, since both are the exact
  # same physical walk) while still fully realpathing it — symlinks chased,
  # `..` applied physically, exactly the same trick `Valea.Mounts.External`
  # already uses to resolve a declared mount's own root. Relative
  # candidates are UNCHANGED: always workspace-relative, resolved against
  # `workspace` as before A2-T3.
  #
  # (A candidate that mixes a symlink with a literal `..` in the SAME raw
  # string can make this self-base call spuriously report `{:error,
  # :outside}` — `Path.expand/1`'s purely lexical `..` collapse, used only
  # to compute the base to check containment against, can disagree with the
  # physical, symlink-aware walk that computes the actual result. That
  # mismatch only ever turns a would-be `{:ok, _}` into an error — which
  # `decide/2` treats as `:ask` (or `:deny` when `denied?/2`'s existing
  # `{:error, :outside}` clause also fires) — never the reverse, so it
  # cannot widen access.)
  defp resolve_candidate(path, workspace) do
    if String.starts_with?(path, "/") do
      Valea.Paths.resolve_real(path, path)
    else
      Valea.Paths.resolve_real(path, workspace)
    end
  end

  # A candidate that NOMINALLY names a currently-enabled root — by its raw,
  # un-resolved path string, before any symlink is chased — but whose TRUE
  # `resolve_real` location lands in NO enabled root at all is a symlink
  # escaping that root. Denied outright: the same fail-closed treatment as
  # the deny-list, because the request's own address lied about where it
  # points (a stronger signal than a plain unrecognized path, which only
  # ask-gates — see `decide/2`'s final `:ask` fallback). A disabled or
  # degraded mount's root is simply absent from `extra_roots`, so a path
  # nominally under it never satisfies the first half of this check and
  # correctly ask-gates instead of denying — same for a plain absolute path
  # that was never claiming to be under any root to begin with.
  defp escaped_root?(raw, {:ok, resolved}, workspace, ws, read_roots, extra_roots) do
    root_membership?(raw, workspace, read_roots, extra_roots) and
      not root_membership?(resolved, ws, read_roots, extra_roots)
  end

  defp escaped_root?(_raw, _resolved, _workspace, _ws, _read_roots, _extra_roots), do: false

  defp base_real(workspace) do
    case Valea.Paths.resolve_real(workspace, workspace) do
      {:ok, real} -> real
      _ -> workspace
    end
  end

  defp extract_paths(item) do
    raw = item["rawInput"] || %{}

    ["file_path", "path", "notebook_path", "filePath"]
    |> Enum.map(&raw[&1])
    |> Enum.filter(&is_binary/1)
  end

  defp denied?({:error, :outside}, _ws), do: true
  defp denied?({:error, _}, _ws), do: false

  # Case-INSENSITIVE match: on a case-insensitive filesystem (macOS APFS
  # default) `SECRETS/x` and `Secrets/x` resolve to the same protected dir as
  # `secrets/x`, so the hard-deny must not be defeated by casing. The
  # `@protected_dirs` / `@db_prefix` references are already lowercase.
  defp denied?({:ok, path}, ws) do
    rel = Path.relative_to(path, ws)
    top = rel |> Path.split() |> List.first()

    (is_binary(top) and String.downcase(top) in @protected_dirs) or
      String.starts_with?(String.downcase(Path.basename(rel)), @db_prefix)
  end

  defp all_in_read_roots?(resolved, ws, read_roots, extra_roots) do
    Enum.all?(resolved, fn {:ok, path} -> root_membership?(path, ws, read_roots, extra_roots) end)
  end

  # Root-SET membership by leading PATH COMPONENTS — never a lexical
  # `String.starts_with?/2`, which would let `mounts/a` wrongly match
  # `mounts/ab/...` (a component boundary, not a character boundary; same
  # reasoning extends `extra_roots`' absolute members, so `/ext/icm` must
  # not match `/ext/icm-other/...`).
  #
  # `path` and `ws_base` MUST be a consistent pair: both physically-resolved
  # (checking where a candidate TRULY lands — called from
  # `all_in_read_roots?/4` and the second half of `escaped_root?/6`) or both
  # raw/un-resolved (checking what root a candidate NOMINALLY claims, before
  # any symlink is chased — the first half of `escaped_root?/6`). Mixing a
  # resolved `path` with a raw `ws_base` (or vice-versa) would silently fail
  # every membership check for a workspace living behind a symlink (macOS
  # `/tmp` -> `/private/tmp`).
  #
  # A relative `path` is always workspace-relative by definition (skips the
  # `ws_base` comparison entirely — relative candidates only ever arise from
  # `resolve_candidate/2`'s own relative branch, resolved against the
  # workspace already). An absolute `path` under `ws_base` is checked
  # against the workspace-relative `read_roots`; an absolute path NOT under
  # `ws_base` is checked against the absolute `extra_roots` members instead
  # — the two halves of the root SET this module now contains reads over.
  defp root_membership?(path, ws_base, read_roots, extra_roots) do
    cond do
      not String.starts_with?(path, "/") ->
        matches_any_root?(read_roots, path) or path in @root_files

      under_lexical?(path, ws_base) ->
        rel = Path.relative_to(path, ws_base)
        matches_any_root?(read_roots, rel) or rel in @root_files

      true ->
        matches_any_root?(extra_roots, path)
    end
  end

  defp matches_any_root?(roots, candidate_rel) do
    parts = Path.split(candidate_rel)
    Enum.any?(roots, &under_root?(Path.split(&1), parts))
  end

  defp under_root?(root_parts, parts), do: Enum.take(parts, length(root_parts)) == root_parts

  defp under_lexical?(path, base),
    do: path == base or String.starts_with?(path <> "/", base <> "/")

  defp all_in_write_paths?(resolved, write_paths, workspace) do
    allowed =
      write_paths
      |> Enum.map(&Valea.Paths.resolve_real(&1, workspace))
      |> Enum.flat_map(fn
        {:ok, p} -> [p]
        _ -> []
      end)

    Enum.all?(resolved, fn {:ok, path} -> path in allowed end)
  end
end
