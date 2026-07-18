defmodule Valea.Agents.PermissionPolicy do
  @moduledoc """
  deny -> allow -> ask, unclassifiable = ask (spec §PermissionPolicy).

  Pure: decisions depend only on the permission item and the ctx. Every
  decision is audited by the `SessionServer`, not here.

  All path reasoning goes through `Valea.Paths.resolve_real/2` so a symlink
  can never smuggle a read/write outside a recognized root. Every ctx-supplied
  base/root is ALSO symlink-resolved before comparison — otherwise `/var` vs
  `/private/var` (macOS) and any other symlinked ancestor would defeat
  containment and exact-match checks.

  ## One contract

  `decide/2` implements a single split contract — `ctx` always carries
  `workspace_root` (absolute; protects operational state), `cwd` (absolute
  primary ICM root; base for *relative* candidate paths), `read_roots`
  (absolute list: primary root + related roots + exact task inputs),
  `session_kind`, `write_paths` (absolute), `write_roots` (absolute).
  `SessionServer.init/1` — the only caller — has always built this shape
  since Task 5.3; the earlier workspace-relative legacy contract
  (`ctx.workspace`/`ctx.extra_roots`, no `workspace_root`/`cwd` split) and
  its dedicated dispatch branch were deleted outright in Task 6 (Spec D)
  once every caller was confirmed migrated.

  Every path decision goes through `Valea.Paths.resolve_real/2`, membership
  is segment-boundary (never a lexical string-prefix — `mounts/a` must not
  match `mounts/ab/...`), and deny always wins over allow; an unclassifiable
  candidate is `:ask`, never a silent allow.

  ## Write grants are kind-agnostic

  Write access is never inferred from *what* a session is — it is granted
  explicitly, per-run, via `write_paths` (exact absolute paths) and
  `write_roots` (absolute directories, segment-boundary contained). Those
  grants are minted only by Valea's own `SessionScope`/session-creation
  callers — never by the agent, and never widened by anything the agent can
  say or do — so honoring a populated grant regardless of `session_kind` is
  safe: an agent can only write where its own trusted caller already decided
  to let it write. A ctx with empty `write_paths`/`write_roots` (the default
  for an ordinary chat session) still gets no write allowance and falls
  through to `:ask`, same as always.

  ## Decision order (deny -> allow -> ask)

    1. **Deny** if the tool is `WebFetch`/`WebSearch`.
    2. **Deny** if any resolved candidate is inside a protected workspace dir
       (`<workspace_root>/{logs,config,secrets,runtime,.git}` or
       `<workspace_root>/app.sqlite*`).
    3. **Deny** (ICM secrets, Spec D §D5) if any candidate names secret
       material inside an `icm_root`.
    4. **Deny** (mail rules, Task 14 — see "Mail rules" below) if any
       candidate violates the mail tier: unmounted mail territory, an
       in-scope `spool/` read, or an in-scope write outside
       `ops/pending/`+`drafts/`.
    4b. **Deny** (calendar rules, Spec F Task 5 — see "Calendar rules"
       below) if any candidate violates the calendar tier: unmounted
       calendar territory, or an in-scope write outside `valea/events/`.
    5. **Deny** (symlink escape) if any candidate resolves OUTSIDE every
       recognized area — `workspace_root` itself, every `read_root`, and
       every write grant (`write_paths`/`write_roots`). A relative candidate
       that lexically escapes `cwd` (`resolve_real`'s own `{:error,
       :outside}`) counts as escaping too, since relative candidates only
       ever resolve against `cwd`. Landing INSIDE `workspace_root` without
       being in a granted root is NOT an escape — it just isn't granted yet,
       so it falls through to `:ask` (step 8) rather than being denied; only
       territory outside the whole recognized universe is treated as a
       symlink-escape-style deny.
    6. **Allow read** if `kind` is a read kind and EVERY candidate resolves
       inside some `read_root` (or is a root instruction file — see below).
    7. **Allow write** if `kind` is a write kind and every candidate is in
       `write_paths` or under a `write_root` — for ANY `session_kind`; see
       "Write grants are kind-agnostic" above.
    8. Else **ask**.

  ## Mail rules (Task 14, mail spec §"Mount & containment")

  `ctx` carries `mail_roots_all` (every configured account's
  `sources/mail/<slug>` root) and `mail_roots_in_scope` (the accounts this
  session's scope includes) — both threaded from `SessionScope` like
  `icm_roots`, both defaulting to `[]`.

    * **Unmounted deny (deny, not ask).** Any candidate under mail
      territory — a `mail_roots_all` root, or ANYTHING under
      `<workspace_root>/sources/mail` (the spec's "deny covering all of
      `sources/mail/`": leftover files from a removed account, or an
      invalid account's subtree, must never be one generic ask-approval
      away) — that is NOT under an in-scope root is `{:deny,
      "reject_once"}`, for every kind.
    * **Write surface.** Within an in-scope mail root, write kinds are
      denied everywhere EXCEPT `ops/pending/` and `drafts/` (which fall
      through to the ordinary grant/ask flow — deny still precedes the
      write-allow tier, so a broad grant can never buy `maildir/` back).
      Read kinds: `spool/` is denied; everything else stays readable via
      the ordinary read-root allow.

  ## Calendar rules (Spec F Task 5, calendar spec §"Mounts and policy")

  `ctx` carries `calendar_in_scope?` (boolean, default `false` —
  fail-closed for any ctx built before the calendar kind existed). The
  territory is ALWAYS `<workspace_root>/sources/calendar` — ONE synthetic
  mount, so there are no per-slug root lists to thread.

    * **Unmounted deny (deny, not ask).** Any candidate under calendar
      territory in a session whose scope does NOT include the calendar
      mount is `{:deny, "reject_once"}`, for every kind — leftover files
      from removed sources included, exactly like mail's blanket
      `sources/mail` deny.
    * **Write surface.** In scope, write kinds are denied everywhere
      EXCEPT `valea/events/` (which falls through to the ordinary
      grant/ask flow — deny still precedes the write-allow tier, so a
      broad grant can never buy `.source`/`feed.ics`/`views/` back).
      Read kinds are allowed EVERYWHERE in scope (mirrors and views are
      exactly the calendar data the session was granted; there is no
      spool-like secret area).

  Calendar matching shares the mail tier's `casefold/1`/
  `casefold_under_root?/2` helpers verbatim (extracted, not duplicated).

  Mail and calendar matching — and ONLY those — are casefolded on BOTH
  sides (`casefold/1`: NFC-normalize, then `String.downcase/1`): APFS is
  case- and normalization-insensitive, so `sources/MAIL/…` or an
  NFD-variant spelling names the same mailbox and must hit the same
  deny. The global `split_under_root?/2` used by every other tier is
  untouched.

  Relative candidates resolve against `cwd` (never `workspace_root`) — this
  is the behavioral heart of the split. `read_roots`/`write_paths`/
  `write_roots` are absolute, so membership is segment-boundary: `resolved ==
  root or starts_with?(resolved <> "/", root <> "/")`.

  `@root_files` (`AGENTS.md`/`CLAUDE.md`, always-allowed relative reads) now
  resolve against `cwd` (the ICM root that actually carries those files),
  never `workspace_root` — kept as an explicit bypass (on top of ordinary
  `read_roots` membership, which already covers it whenever `cwd` is itself a
  read root, per the contract) so a root instruction file stays readable even
  if a caller's `read_roots` construction ever omits `cwd` itself.
  """

  @read_kinds ["read"]
  @write_kinds ["edit", "write", "delete", "move"]

  ## ===========================================================================
  ## Decision logic: workspace_root / cwd / read_roots (absolute)
  ## ===========================================================================

  @protected_dirs ~w(logs config secrets runtime .git)
  @db_prefix "app.sqlite"
  @root_files ["AGENTS.md", "CLAUDE.md"]
  @denied_tools ["WebFetch", "WebSearch"]

  @spec decide(map(), map()) :: :ask | {:allow, String.t()} | {:deny, String.t()}
  def decide(item, ctx) do
    decide_split(item, ctx)
  end

  defp decide_split(item, ctx) do
    kind = item["kind"]
    tool = item["toolName"]

    workspace_root = split_real(ctx.workspace_root)
    cwd = split_real(ctx.cwd)
    read_roots = Enum.map(ctx[:read_roots] || [], &split_real/1)
    write_paths = Enum.map(ctx[:write_paths] || [], &split_real/1)
    write_roots = Enum.map(ctx[:write_roots] || [], &split_real/1)
    icm_roots = Enum.map(ctx[:icm_roots] || [], &split_real/1)

    # Mail rules (Task 14) compare CASEFOLDED, symlink-resolved roots —
    # see the moduledoc's "Mail rules". The blanket `sources/mail` root is
    # derived from `workspace_root`, so the deny covers territory no
    # configured account claims (removed/invalid accounts' leftovers).
    mail_in_scope = Enum.map(ctx[:mail_roots_in_scope] || [], &casefold(split_real(&1)))

    mail_territory =
      [casefold(Path.join([workspace_root, "sources", "mail"]))] ++
        Enum.map(ctx[:mail_roots_all] || [], &casefold(split_real(&1)))

    # Calendar rules (Spec F Task 5) — same casefolded, symlink-resolved
    # posture as mail, over the ONE `sources/calendar` territory root
    # (derived from `workspace_root`, so the deny covers leftover files no
    # configured source claims). In/out of scope is a ctx boolean;
    # defaults false — fail-closed.
    calendar_territory = casefold(Path.join([workspace_root, "sources", "calendar"]))
    calendar_in_scope? = ctx[:calendar_in_scope?] || false

    paths = extract_paths(item)
    resolved = Enum.map(paths, &split_resolve_candidate(&1, cwd))

    cond do
      tool in @denied_tools ->
        {:deny, "reject_once"}

      Enum.any?(resolved, &split_protected?(&1, workspace_root)) ->
        {:deny, "reject_once"}

      Enum.any?(resolved, &split_icm_secret?(&1, icm_roots)) ->
        {:deny, "reject_once"}

      Enum.any?(resolved, &mail_denied?(&1, kind, mail_territory, mail_in_scope)) ->
        {:deny, "reject_once"}

      Enum.any?(resolved, &calendar_denied?(&1, kind, calendar_territory, calendar_in_scope?)) ->
        {:deny, "reject_once"}

      Enum.any?(
        resolved,
        &split_escaped?(&1, workspace_root, read_roots, write_paths, write_roots)
      ) ->
        {:deny, "reject_once"}

      paths == [] ->
        :ask

      Enum.any?(resolved, &(elem(&1, 0) == :error)) ->
        :ask

      kind in @read_kinds and split_all_read?(resolved, cwd, read_roots) ->
        {:allow, "allow_once"}

      kind in @write_kinds and split_all_write?(resolved, write_paths, write_roots) ->
        {:allow, "allow_once"}

      true ->
        :ask
    end
  end

  # Self-base realpath resolution: every absolute ctx-supplied base/root
  # (`workspace_root`, `cwd`, each `read_roots`/`write_paths`/`write_roots`
  # member) is walked through `resolve_real/2` against ITSELF before use, so
  # a symlinked ancestor (macOS `/var` -> `/private/var`, historically `/tmp`
  # -> `/private/tmp`) can't desync a ctx-supplied root from the fully
  # symlink-chased candidate paths it's compared against. Falls back to the
  # input unresolved if the path doesn't exist yet or can't be walked (a
  # `write_paths` target commonly doesn't exist until the agent creates it).
  defp split_real(path) do
    case Valea.Paths.resolve_real(path, path) do
      {:ok, real} -> real
      _ -> path
    end
  end

  # Absolute candidates (every related-root/exact-input read arrives this
  # way) are resolved against THEMSELVES — a fixed `cwd` base would reject
  # every legitimately-absolute result as `{:error, :outside}` before
  # `read_roots` membership could ever be checked, since `read_roots` is no
  # longer required to be an ancestor of `cwd`. Relative candidates are the
  # one case that resolves against `cwd` — the behavioral heart of the split.
  defp split_resolve_candidate(path, cwd) do
    if String.starts_with?(path, "/") do
      Valea.Paths.resolve_real(path, path)
    else
      Valea.Paths.resolve_real(path, cwd)
    end
  end

  # Case-INSENSITIVE match: on a case-insensitive filesystem (macOS APFS
  # default) `SECRETS/x` and `Secrets/x` resolve to the same protected dir as
  # `secrets/x`, so the hard-deny must not be defeated by casing.
  #
  # Scoped to `workspace_root`: this check only ever hard-denies
  # `<workspace_root>/{logs,config,secrets,runtime,.git}` and
  # `<workspace_root>/app.sqlite*` (spec §PermissionPolicy step 1). A
  # resolved candidate that is NOT under `workspace_root` at all — e.g. a
  # file in a granted `read_root` that happens to be named `app.sqlite.md`,
  # or an exact task input outside the workspace — must not be swept into
  # this deny just because `Path.basename/1` matches the db prefix; that
  # would over-deny territory the spec never asked this check to cover.
  # `Path.relative_to/2` on a path outside `workspace_root` returns it
  # unchanged, so the basename/top-segment tests below are only meaningful
  # once containment is confirmed first.
  defp split_protected?({:error, _}, _workspace_root), do: false

  defp split_protected?({:ok, resolved}, workspace_root) do
    split_under_root?(resolved, workspace_root) and
      protected_relative?(resolved, workspace_root, @protected_dirs, @db_prefix)
  end

  # Spec D §D5: ICM-internal secret material is deny-by-default — mirrors
  # the workspace-protected tier. Checked against each ICM root by the
  # candidate's ICM-relative segments, so `mysecrets/` and `secretsfoo/`
  # never match a `secrets` SEGMENT.
  defp split_icm_secret?({:ok, abs}, icm_roots) do
    Enum.any?(icm_roots, fn root ->
      if split_under_root?(abs, root) do
        rel = String.trim_leading(abs, root <> "/")
        secret_relative?(rel)
      else
        false
      end
    end)
  end

  defp split_icm_secret?(_resolved, _icm_roots), do: false

  @doc false
  # Public only so the managedSettings mirror's tests can assert the same
  # pattern set; not part of the module's decision API.
  #
  # Case-INSENSITIVE, mirroring `protected_relative?/2` below: on this
  # project's own platform (macOS/APFS, case-insensitive by default),
  # `SECRETS/api_key.txt`, `.ENV`, `SERVER.PEM`, `ID.KEY` etc. name the same
  # file the lowercase form would, so every comparison here runs against
  # downcased segments/basename rather than downcasing only the
  # `credentials` check.
  def secret_relative?(rel) do
    segments = Path.split(rel)
    basename = String.downcase(List.last(segments) || "")
    dir_segments = Enum.drop(segments, -1)

    cond do
      Enum.any?(dir_segments, &(String.downcase(&1) == "secrets")) -> true
      basename == "secrets" -> true
      basename == ".env" -> true
      String.starts_with?(basename, ".env.") and basename != ".env.example" -> true
      String.ends_with?(basename, ".pem") -> true
      String.ends_with?(basename, ".key") -> true
      String.contains?(basename, "credentials") -> true
      true -> false
    end
  end

  # -- mail rules (Task 14) — see the moduledoc's "Mail rules" section ------

  # `mail_territory` and `in_scope_roots` arrive ALREADY symlink-resolved
  # (`split_real/1`) and casefolded; the candidate is casefolded here.
  # Resolve failures are never a mail deny — `{:error, :outside}` still
  # hits the escape deny right after this tier, and other errors keep
  # falling to `:ask`.
  defp mail_denied?({:error, _}, _kind, _mail_territory, _in_scope_roots), do: false

  defp mail_denied?({:ok, path}, kind, mail_territory, in_scope_roots) do
    cf = casefold(path)

    case Enum.find(in_scope_roots, &casefold_under_root?(cf, &1)) do
      nil ->
        # Not in any in-scope account: ANY touch of mail territory is a
        # deny — never a prompt (one generic-looking approval must not be
        # able to expose a whole mailbox).
        Enum.any?(mail_territory, &casefold_under_root?(cf, &1))

      scope_root ->
        cond do
          kind in @read_kinds ->
            casefold_under_root?(cf, scope_root <> "/spool")

          kind in @write_kinds ->
            not (casefold_under_root?(cf, scope_root <> "/ops/pending") or
                   casefold_under_root?(cf, scope_root <> "/drafts"))

          true ->
            false
        end
    end
  end

  # -- calendar rules (Spec F Task 5) — see the moduledoc's "Calendar
  # rules" section ----------------------------------------------------------

  # `territory_root` arrives ALREADY symlink-resolved (`split_real/1` on
  # `workspace_root`) and casefolded; the candidate is casefolded here via
  # the SAME `casefold/1`/`casefold_under_root?/2` helpers the mail tier
  # uses (shared, not duplicated). Resolve failures are never a calendar
  # deny — `{:error, :outside}` still hits the escape deny right after
  # this tier, and other errors keep falling to `:ask` — mirroring
  # `mail_denied?/4` exactly.
  defp calendar_denied?({:error, _}, _kind, _territory_root, _in_scope?), do: false

  defp calendar_denied?({:ok, path}, kind, territory_root, in_scope?) do
    cf = casefold(path)

    cond do
      not casefold_under_root?(cf, territory_root) ->
        false

      # Not in scope: ANY touch of calendar territory is a deny — never a
      # prompt (one generic-looking approval must not be able to expose
      # the whole calendar subtree).
      not in_scope? ->
        true

      # In scope, write kinds: ONLY `valea/events/` is agent-writable —
      # `.source`, `feed.ics`, `views/`, crash leftovers, and valea's own
      # rendered feed are engine-owned. Deny precedes the write-allow
      # tier, so a broad grant can never buy them back.
      write_kind?(kind) ->
        not casefold_under_root?(cf, territory_root <> "/valea/events")

      # In scope, reads (and any non-write kind): allowed everywhere in
      # the territory — the ordinary read-root allow decides from here.
      true ->
        false
    end
  end

  defp write_kind?(kind), do: kind in @write_kinds

  # Casefold for mail AND calendar comparisons ONLY: NFC-normalize (APFS
  # is normalization-insensitive — NFD and NFC spellings name the same
  # file), then downcase (APFS is case-insensitive). Applied to BOTH sides
  # of every mail/calendar membership check. Invalid UTF-8 falls back to
  # the raw binary — downcase alone still applies.
  defp casefold(path) do
    case :unicode.characters_to_nfc_binary(path) do
      nfc when is_binary(nfc) -> String.downcase(nfc)
      _invalid -> String.downcase(path)
    end
  end

  # Same segment-boundary membership as `split_under_root?/2`, over
  # already-casefolded strings — a separate helper so the global,
  # case-sensitive one stays untouched (moduledoc pin).
  defp casefold_under_root?(cf_path, cf_root),
    do: cf_path == cf_root or String.starts_with?(cf_path <> "/", cf_root <> "/")

  # A relative candidate that lexically escapes `cwd` (the only base relative
  # candidates ever resolve against) can't be checked against any OTHER root
  # — `resolve_real/2` doesn't hand back a resolved path on `{:error,
  # :outside}` — so it's treated the same as any other candidate landing
  # outside the whole recognized universe: a deny, never a silent `:ask`
  # widen. `{:error, :invalid}` (32-hop symlink budget exhausted) is left for
  # the `:ask` fallback in `decide_split/2`, same as an ordinary resolve
  # failure.
  defp split_escaped?(
         {:error, :outside},
         _workspace_root,
         _read_roots,
         _write_paths,
         _write_roots
       ),
       do: true

  defp split_escaped?({:error, _}, _workspace_root, _read_roots, _write_paths, _write_roots),
    do: false

  defp split_escaped?({:ok, resolved}, workspace_root, read_roots, write_paths, write_roots) do
    not (split_under_root?(resolved, workspace_root) or
           split_root_member?(resolved, read_roots) or
           resolved in write_paths or
           split_root_member?(resolved, write_roots))
  end

  defp split_all_read?(resolved, cwd, read_roots) do
    Enum.all?(resolved, fn
      {:ok, path} -> split_root_member?(path, read_roots) or split_root_file?(path, cwd)
      _ -> false
    end)
  end

  defp split_root_file?(resolved, cwd) do
    split_under_root?(resolved, cwd) and Path.relative_to(resolved, cwd) in @root_files
  end

  defp split_all_write?(resolved, write_paths, write_roots) do
    Enum.all?(resolved, fn
      {:ok, path} -> path in write_paths or split_root_member?(path, write_roots)
      _ -> false
    end)
  end

  # Root-SET membership by leading PATH COMPONENTS — never a lexical
  # `String.starts_with?/2`, which would let `mounts/a` wrongly match
  # `mounts/ab/...` (a component boundary, not a character boundary).
  defp split_root_member?(path, roots), do: Enum.any?(roots, &split_under_root?(path, &1))

  defp split_under_root?(path, root),
    do: path == root or String.starts_with?(path <> "/", root <> "/")

  ## ===========================================================================
  ## Shared
  ## ===========================================================================

  # Protected-dir / db-prefix test against an ALREADY-CONFIRMED-contained
  # `path` (callers must check containment under `root` first — see
  # `split_protected?/2` above): a hard-deny if the resolved path's top
  # segment (relative to `root`) is a protected dir name, or its basename
  # starts with the db prefix — both compared case-insensitively.
  defp protected_relative?(path, root, protected_dirs, db_prefix) do
    rel = Path.relative_to(path, root)
    top = rel |> Path.split() |> List.first()

    (is_binary(top) and String.downcase(top) in protected_dirs) or
      String.starts_with?(String.downcase(Path.basename(rel)), db_prefix)
  end

  defp extract_paths(item) do
    raw = item["rawInput"] || %{}

    ["file_path", "path", "notebook_path", "filePath"]
    |> Enum.map(&raw[&1])
    |> Enum.filter(&is_binary/1)
  end
end
