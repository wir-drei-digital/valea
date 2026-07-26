defmodule Valea.Paths do
  @moduledoc """
  Symlink-aware containment with realpath semantics. The ICM chokepoint's
  lexical check is not enough for the agent boundary: a symlink inside the
  workspace can point anywhere.

  `resolve_real/2` resolves `path` against `base` the way the OS does —
  symlinks are resolved BEFORE any following `..` is applied. It walks the
  path components left-to-right from the resolved base. The physically-
  resolved path so far is carried as a `{root, comps}` pair, where `root` is
  the filesystem floor the path hangs off — `"/"` on Unix, `"C:/"` or
  `"//host/share"` on Windows — and `comps` is the list of resolved
  components below it:

    * a normal component is appended, then if the result is a symlink its
      target is resolved against the symlink's PHYSICAL parent (absolute
      targets restart from their own root, relative ones extend the parent);
    * `..` pops the last element of `comps` — the physical parent of what has
      actually been resolved so far, NOT a lexical stack pop, so a symlink
      followed by `..` lands in the symlink target's real parent. When
      `comps` is already empty the pop is a no-op: `root` is a floor `..`
      can never climb above (the root-floor rule — spec §D1 — which is why
      the walk never calls host `Path.dirname`, whose behaviour at `C:/` is
      host-dependent);
    * `.` is skipped;
    * once a component does not exist the remainder cannot contain symlinks,
      so it is appended literally — but any `..` in that remainder is still
      applied physically against the resolved-so-far parent.

  Symlink resolution is bounded to 32 hops across the whole walk. Only after
  the physical path is fully resolved is it checked for containment in the
  (also symlink-resolved) `base`. Containment, absoluteness and root parsing
  are all platform-aware (`host_platform/0`): on Windows drive letters and
  UNC host/share compare case-folded (NTFS default) and `\\` is a separator;
  on Unix the comparison stays case-sensitive and `/` is the only separator.
  Ambiguous Windows forms (drive-relative `C:foo`, device `\\.\…`, bare
  `//host`) fail closed — `resolve_real` returns `{:error, :invalid}` rather
  than guessing a root.

  The classifier is our OWN (OTP's `Path.type/1` is host-dependent — on a
  Unix host `Path.type("C:/x")` is `:relative`), so Windows path semantics
  are testable on any host through the pure seams `classify/2`,
  `normalize/2`, `ancestor?/3` and `resolve_lexical/3`.
  """

  @max_hops 32

  @typedoc "Platform whose path grammar to apply."
  @type platform :: :unix | :windows

  @doc """
  The current host's platform, from `:os.type/0`. Every public function
  defaults its `platform` argument to this, so host behaviour is unchanged.
  """
  @spec host_platform() :: platform()
  def host_platform do
    case :os.type() do
      {:win32, _} -> :windows
      _ -> :unix
    end
  end

  @doc """
  Lexical relative path from `from_dir` to `to_path` (same vocabulary on
  both sides — both workspace-relative, or both absolute physical paths).
  Pure segment math — no filesystem access, no symlink resolution: drops
  the common leading path segments, then emits one `".."` per remaining
  `from_dir` segment, joined with the remaining `to_path` segments.
  """
  @spec relative(String.t(), String.t()) :: String.t()
  def relative(from_dir, to_path) do
    from = Path.split(from_dir)
    to = Path.split(to_path)
    {common_from, common_to} = drop_common(from, to)
    Path.join(List.duplicate("..", length(common_from)) ++ common_to)
  end

  defp drop_common([h | t1], [h | t2]), do: drop_common(t1, t2)
  defp drop_common(from, to), do: {from, to}

  @doc """
  Classify a path's absoluteness under `platform`.

    * `:absolute` — starts from a filesystem root: `/x` on Unix; `C:/x`,
      `C:\\x`, or a UNC `//host/share/…` on Windows.
    * `:drive_relative` — Windows `C:foo` / bare `C:`: current directory on
      drive C. Not a root; rejected wherever a path is consumed.
    * `:invalid` — Windows device (`\\\\.\\…`), bare `//host` (no share), or a
      current-drive-rooted `/x`. Fails closed.
    * `:relative` — everything else (extended-length `\\\\?\\…` wrappers are
      unwrapped first via `normalize/2`, they are not a category).

  On Unix the only distinction is the leading `/`; a Windows-shaped string
  like `C:/x` is a perfectly legal relative Unix name.
  """
  @spec classify(String.t(), platform()) :: :absolute | :relative | :drive_relative | :invalid
  def classify(path, platform \\ host_platform())
  def classify("/" <> _, :unix), do: :absolute
  def classify(_, :unix), do: :relative
  def classify(path, :windows), do: path |> String.replace("\\", "/") |> classify_normalized()

  # Device paths (\\.\COM1 -> //./COM1) are never a filesystem location.
  defp classify_normalized("//./" <> _), do: :invalid
  # Extended-length wrappers are syntactic: unwrap and classify the plain form.
  defp classify_normalized("//?/" <> _ = p), do: p |> strip_extended() |> classify_normalized()

  defp classify_normalized(p) do
    cond do
      match?({_, _}, unc_root(p)) -> :absolute
      # Two leading slashes but not a well-formed //host/share: bare host.
      String.starts_with?(p, "//") -> :invalid
      drive_abs?(p) -> :absolute
      Regex.match?(~r/^[A-Za-z]:/, p) -> :drive_relative
      # Single leading slash on Windows = rooted on the CURRENT drive: which
      # drive is ambiguous, so it fails closed rather than assuming one.
      String.starts_with?(p, "/") -> :invalid
      true -> :relative
    end
  end

  @doc "True iff `classify/2` is `:absolute`."
  @spec absolute?(String.t(), platform()) :: boolean()
  def absolute?(path, platform \\ host_platform()), do: classify(path, platform) == :absolute

  @doc """
  Normalize a path to Valea's canonical internal form for `platform`.

  Identity on `:unix` (where `\\` is a legal filename byte, so nothing is
  rewritten). On `:windows`: `\\` → `/`, the extended-length wrappers
  `\\\\?\\C:\\…` → `C:/…` and `\\\\?\\UNC\\h\\s\\…` → `//h/s/…` are stripped,
  and a drive letter is upcased. Applied where user/config paths enter
  (mount roots, adopt-a-folder, session cwd, configured commands) — spec §D2.
  """
  @spec normalize(String.t(), platform()) :: String.t()
  def normalize(path, platform \\ host_platform())
  def normalize(path, :unix), do: path

  def normalize(path, :windows) do
    path
    |> String.replace("\\", "/")
    |> strip_extended()
    |> upcase_drive()
  end

  @doc """
  True iff `descendant` is `ancestor` itself or lies beneath it — the
  `prefix <> "/"` idiom, in one place. Case-folded on `:windows` (NTFS is
  case-insensitive by default), exact on `:unix`. The trailing-slash guard
  stops a sibling prefix collision (`/a/icm` is NOT an ancestor of
  `/a/icm-private`).
  """
  @spec ancestor?(String.t(), String.t(), platform()) :: boolean()
  def ancestor?(ancestor, descendant, platform \\ host_platform()) do
    {a, d} = fold(ancestor, descendant, platform)
    a == d or String.starts_with?(d <> "/", a <> "/")
  end

  defp fold(a, d, :windows), do: {String.downcase(a), String.downcase(d)}
  defp fold(a, d, :unix), do: {a, d}

  @doc """
  Pure lexical resolution of `path` against absolute `base` under `platform`
  — the segment/floor walk `resolve_real/2` shares, WITHOUT filesystem
  access or symlink resolution. `..` pops against the resolved accumulator
  and can never climb above the path's root (`/`, `C:/`, `//host/share`).
  Exists so the Windows root-floor semantics are testable on a Unix host
  (spec §D testing split).

  `base` is the root the walk floors against and MUST classify `:absolute`
  for `platform`. A base that does not (drive-relative `C:foo`, device
  `\\\\.\\…`, bare `//host`, or a plain relative path) has no root to floor
  `..` against, so it raises `ArgumentError`: callers of this seam always
  hold a root, and inventing one here is exactly the ambiguity containment
  must never resolve — least of all silently.
  """
  @spec resolve_lexical(String.t(), String.t(), platform()) :: String.t()
  def resolve_lexical(path, base, platform \\ host_platform()) do
    base_pair = base_root!(base, platform)

    case start_pair(path, base_pair, platform) do
      {:ok, root, acc, remaining} ->
        render(lexical_walk(root, acc, remaining))

      # A non-resolvable `path` shape (drive-relative/device/invalid) has no
      # walk to run; the floored base is the fail-closed answer.
      {:error, _} ->
        render(base_pair)
    end
  end

  # Parse a caller-supplied base, refusing anything without a root. The
  # classifier is the single gate: it rejects device paths that `unc_root/1`
  # would otherwise happily read as `//host/share`.
  defp base_root!(base, platform) do
    case classify(base, platform) do
      :absolute ->
        absolute_root(base, platform)

      other ->
        raise ArgumentError,
              "resolve_lexical/3 needs a root-anchored base, got #{inspect(base)} " <>
                "(#{other} on #{platform})"
    end
  end

  # Lexical-only walk: no symlink hops, so `.`/`..`/normal handling matches
  # the physical walk's non-symlink clauses exactly.
  defp lexical_walk(root, acc, []), do: {root, acc}
  defp lexical_walk(root, acc, ["." | rest]), do: lexical_walk(root, acc, rest)
  defp lexical_walk(root, acc, [".." | rest]), do: lexical_walk(root, pop(acc), rest)
  defp lexical_walk(root, acc, [comp | rest]), do: lexical_walk(root, acc ++ [comp], rest)

  @spec resolve_real(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, :outside | :invalid}
  def resolve_real(path, base) do
    platform = host_platform()
    # `Path.expand` (host-native, so appropriate for the host-supplied base)
    # makes the base absolute and collapses its lexical `.`/`..` first.
    expanded = Path.expand(base)

    if absolute?(expanded, platform) do
      resolve_from_base(path, resolve_base(expanded, platform), platform)
    else
      # Unreachable on Unix — `Path.expand` always returns a "/"-rooted path
      # there, so the Unix contract is untouched. On Windows a base that
      # expands to a rootless/ambiguous form fails CLOSED here rather than
      # reaching the root parser with nothing to anchor the walk on.
      {:error, :invalid}
    end
  end

  defp resolve_from_base(path, base_pair, platform) do
    case start_pair(path, base_pair, platform) do
      {:error, _} ->
        # Drive-relative / device / current-drive-rooted: fail closed.
        {:error, :invalid}

      {:ok, root, acc, remaining} ->
        with {:ok, resolved_pair, _hops} <- walk(root, acc, remaining, @max_hops, platform),
             resolved = render(resolved_pair),
             true <- ancestor?(render(base_pair), resolved, platform) do
          {:ok, resolved}
        else
          false -> {:error, :outside}
          {:error, _} = err -> err
        end
    end
  end

  # Resolve an already-expanded, root-anchored base to a symlink-resolved
  # `{root, comps}` floor+components pair, the way the old resolve_fully did
  # for a string: the physical walk resolves its symlinks (e.g. macOS
  # /var -> /private/var). Falls back to the parsed-but-unwalked pair if the
  # base cannot be resolved.
  defp resolve_base(expanded, platform) do
    {root, comps} = absolute_root(expanded, platform)

    case walk(root, [], comps, @max_hops, platform) do
      {:ok, pair, _hops} -> pair
      {:error, _} -> {root, comps}
    end
  end

  # Establish the walk's starting {root, acc, remaining}. Absolute paths start
  # from their OWN root with an empty accumulator; relative paths extend the
  # base's already-resolved {root, comps}. Windows-invalid shapes surface as
  # {:error, reason} so the caller can fail closed. Never Path.split on a
  # Windows shape — absolute_root parses the root explicitly.
  defp start_pair(path, {base_root, base_comps}, platform) do
    case classify(path, platform) do
      :absolute ->
        {root, comps} = absolute_root(path, platform)
        {:ok, root, [], comps}

      :relative ->
        {:ok, base_root, base_comps, segments(path, platform)}

      invalid ->
        {:error, invalid}
    end
  end

  # Parse an absolute path into {root, comps}. root is the floor `..` cannot
  # climb above; comps are the components below it. PRECONDITION: `path`
  # classifies `:absolute` for `platform` — every caller gates on `classify`
  # first, which is also what keeps device paths out of `unc_root/1`.
  defp absolute_root(path, :unix), do: {"/", segments(path, :unix)}

  defp absolute_root(path, :windows) do
    p = normalize(path, :windows)

    case unc_root(p) do
      {root, comps} ->
        {root, comps}

      # Drive-absolute "C:/...": the root keeps its trailing slash so it
      # renders as a floor ("C:/"), distinct from drive-relative "C:".
      nil ->
        case p do
          <<letter, ?:, ?/, rest::binary>> ->
            {<<letter, ?:, ?/>>, segments(rest, :windows)}

          # Precondition violated. Total on purpose: a future caller that
          # forgets to classify gets a named error naming the input, never a
          # MatchError from a partial binary match — and never a half-parsed
          # root, which is the only way this could go fail-OPEN.
          _ ->
            raise ArgumentError, "not an absolute windows path: #{inspect(path)}"
        end
    end
  end

  # //host/share[/...] -> {"//host/share", remaining_components} | nil.
  # Host AND share are both part of the root (spec §D1); neither may be empty.
  defp unc_root("//" <> rest) do
    case String.split(rest, "/", trim: true) do
      [host, share | comps] when host != "" and share != "" -> {"//#{host}/#{share}", comps}
      _ -> nil
    end
  end

  defp unc_root(_), do: nil

  # The slash is REQUIRED: bare "C:" means "current directory on drive C" —
  # drive-RELATIVE (rejected), not a root.
  defp drive_abs?(p), do: Regex.match?(~r{^[A-Za-z]:/}, p)

  # \\?\UNC\h\s\... (as //?/UNC/h/s/...) -> //h/s/...  ;  \\?\C:\... -> C:/...
  defp strip_extended("//?/UNC/" <> rest), do: "//" <> rest
  defp strip_extended("//?/" <> rest), do: rest
  defp strip_extended(p), do: p

  defp upcase_drive(<<letter, ?:, rest::binary>>) when letter in ?a..?z,
    do: <<letter - 32, ?:, rest::binary>>

  defp upcase_drive(p), do: p

  # Split a path into components on `/`. Backslashes are separators on
  # Windows (folded first) but legal filename bytes on Unix, so only Windows
  # folds them. Matches `Path.split/1` for relative Unix inputs (verified),
  # but is host-independent so Windows shapes split correctly on any host.
  defp segments(path, :unix), do: String.split(path, "/", trim: true)

  defp segments(path, :windows),
    do: path |> String.replace("\\", "/") |> String.split("/", trim: true)

  # Pop the last resolved component. Empty stays empty — that IS the floor.
  defp pop([]), do: []
  defp pop(comps), do: Enum.drop(comps, -1)

  # Render a {root, comps} pair back to a path string. An empty comps list is
  # just the root (a floor: "/", "C:/", "//host/share"); otherwise join with
  # "/", avoiding a doubled slash when the root already ends in one.
  defp render({root, []}), do: root

  defp render({root, comps}) do
    joined = Enum.join(comps, "/")
    if String.ends_with?(root, "/"), do: root <> joined, else: root <> "/" <> joined
  end

  # Walk `remaining` components left-to-right, maintaining {root, acc} — the
  # physically-resolved path so far. `hops` is the remaining symlink budget
  # shared across the whole walk (including nested target resolution).
  defp walk(root, acc, [], hops, _platform), do: {:ok, {root, acc}, hops}

  defp walk(root, acc, ["." | rest], hops, platform),
    do: walk(root, acc, rest, hops, platform)

  # Physical parent pop: `..` applies to what we have actually resolved, so a
  # preceding symlink has already redirected `acc` to its real location. At
  # the floor (`acc == []`) it is a no-op — `root` cannot be climbed above.
  defp walk(root, acc, [".." | rest], hops, platform),
    do: walk(root, pop(acc), rest, hops, platform)

  defp walk(root, acc, [comp | rest], hops, platform) do
    candidate = render({root, acc ++ [comp]})

    case File.read_link(candidate) do
      # A symlink (existing or dangling) — resolve it against its physical
      # parent, {root, acc}, before continuing with the remainder.
      {:ok, _target} when hops <= 0 ->
        {:error, :invalid}

      {:ok, target} ->
        with {:ok, {root2, acc2}, hops2} <-
               resolve_target(target, {root, acc}, hops - 1, platform) do
          walk(root2, acc2, rest, hops2, platform)
        end

      # Not a symlink (a real file/dir, or a non-existent component). Append
      # literally; a non-existent remainder still gets its `..` popped
      # physically by the clauses above.
      {:error, _} ->
        walk(root, acc ++ [comp], rest, hops, platform)
    end
  end

  # Resolve a symlink target: it re-enters through `classify` exactly like an
  # incoming path — absolute targets restart from their own root, relative
  # targets extend the symlink's physical parent. The target path is itself
  # walked so any symlinks/`..` inside it resolve physically too. A target
  # whose shape is Windows-invalid fails the walk closed.
  defp resolve_target(target, parent_pair, hops, platform) do
    case start_pair(target, parent_pair, platform) do
      {:error, _} -> {:error, :invalid}
      {:ok, root, acc, remaining} -> walk(root, acc, remaining, hops, platform)
    end
  end
end
