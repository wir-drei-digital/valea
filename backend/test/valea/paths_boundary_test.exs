defmodule Valea.PathsBoundaryTest do
  use ExUnit.Case, async: true

  # The ONLY wholesale exemption: `Valea.Paths` owns the path grammar, so there
  # the patterns ARE the implementation.
  @exempt ["lib/valea/paths.ex"]

  # Everything else exempts at SITE level: a `# paths-exempt: <reason>` comment
  # excuses THE SINGLE LINE THAT FOLLOWS IT, and nothing else. (It goes on its
  # own line above the site rather than trailing it, because `mix format`
  # hoists a trailing comment out of a `cond` clause to exactly that position.)
  #
  # This replaced file-level entries for `icm/backlinks.ex` and
  # `icm/link_rewrite.ex`, each of which exists for a single markdown-URL
  # classification — and each of which was, as a side effect, also excusing a
  # real filesystem gate in the same file (`to_abs/2`, in both).
  @exempt_marker "paths-exempt:"

  # The marker inventory, pinned. A THIRD marker anywhere — however well
  # commented — has to come here first, which is the review step the marker
  # mechanism would otherwise let someone skip.
  @expected_markers %{
    "lib/valea/icm/backlinks.ex" => 1,
    "lib/valea/icm/link_rewrite.ex" => 1
  }

  # WHAT THESE DETECTORS CANNOT SEE (grep-empty is not proof — the pattern
  # family below was itself invisible to the first detector for a whole
  # commit). Known blind spots, all of them real ways to reintroduce a
  # unix-only path decision without tripping anything here:
  #
  #   * a multi-line function head, where `def foo(` and the `"/" <> rest`
  #     pattern land on different lines (both regexes are line-anchored);
  #   * the binary-syntax spelling `<<"/", _::binary>>` — same decision, none
  #     of the literals these regexes look for;
  #   * a second argument that is not a bare literal: `starts_with?(x, ["/",
  #     …])` or `starts_with?(x, @root_prefix)`, and prefixes built by
  #     concatenation or from a module attribute;
  #   * a doubled separator, `starts_with?(root, "//")` — which is how the UNC
  #     check in `mounts/doctor.ex` sat unflagged until it was migrated to
  #     `Valea.Paths.unc?/2`;
  #   * host-dependent OTP calls that decide the same thing by other means:
  #     `Path.type/1`, `Path.absname/1`, `Path.dirname/1` at a root.
  #
  # Treat these as a regression net, not an audit. A new path decision still
  # needs a human to ask "does this belong in `Valea.Paths`?".

  test "absoluteness/ancestor string logic lives only in Valea.Paths (windows spec D4)" do
    offenders =
      scannable_files()
      |> Enum.filter(fn {_f, src} ->
        Regex.match?(~r/starts_with\?\([^\n)]*"\/"\s*\)/, src) or
          Regex.match?(~r/starts_with\?\([^\n)]*<>\s*"\/"/, src)
      end)
      |> Enum.map(&elem(&1, 0))

    assert offenders == [],
           "path logic outside Valea.Paths (route through absolute?/ancestor?): #{inspect(offenders)}"
  end

  # `defp f("/" <> rest)` is the SAME absoluteness decision as
  # `starts_with?(path, "/")`, written in binary-pattern syntax — and a
  # grep-based inventory over `starts_with?` misses the entire family (it did:
  # this detector was added after the first sweep shipped). Both forms have to
  # be gated, or "every path gate routes through Valea.Paths" is only true of
  # the syntax someone happened to grep for.
  #
  # NOT flagged: `"~/" <> rest` (Valea's own tilde convention, platform-neutral
  # and expanded by `Path.expand/1`) and `root <> "/" <> rest` string JOINS,
  # which decide nothing.
  test "absoluteness decisions are not smuggled in as binary patterns (windows spec D4)" do
    # a function-clause head: `def…(… "/" <> …)`
    head = ~r/def\w*\s+[^\n]*"\/"\s*<>/
    # a case/with/fn clause pattern: `"/" <> rest ->`
    clause = ~r/^\s*"\/"\s*<>[^\n]*->/m

    offenders =
      scannable_files()
      |> Enum.filter(fn {_f, src} ->
        Regex.match?(head, src) or Regex.match?(clause, src)
      end)
      |> Enum.map(&elem(&1, 0))

    assert offenders == [],
           "absoluteness decided by binary pattern outside Valea.Paths " <>
             "(route through absolute?/classify): #{inspect(offenders)}"
  end

  test "the site-exemption inventory is exactly the reviewed one (windows spec D4)" do
    actual =
      Path.wildcard("lib/**/*.ex")
      |> Enum.map(fn f ->
        {f, f |> File.read!() |> String.split("\n") |> Enum.count(&marker?/1)}
      end)
      |> Enum.reject(fn {_f, count} -> count == 0 end)
      |> Map.new()

    assert actual == @expected_markers,
           "the `# paths-exempt:` inventory changed — a new site exemption needs a reviewed " <>
             "reason in @expected_markers, not just a marker. " <>
             "expected #{inspect(@expected_markers)}, got #{inspect(actual)}"
  end

  # Every non-exempt `lib` module as `{path, source}`, with site-marked lines
  # removed so both detectors share one notion of what is in scope.
  defp scannable_files do
    Path.wildcard("lib/**/*.ex")
    |> Enum.reject(fn f -> Enum.any?(@exempt, &String.ends_with?(f, &1)) end)
    |> Enum.map(fn f -> {f, f |> File.read!() |> strip_marked_sites()} end)
  end

  # A marker must be a real COMMENT line — the marker text appearing inside a
  # string literal, a doc block's prose, or trailing live code excuses nothing.
  defp marker?(line),
    do: Regex.match?(~r/^\s*#/, line) and String.contains?(line, @exempt_marker)

  # Drops each `# paths-exempt:` marker together with the one line it excuses.
  defp strip_marked_sites(src) do
    {kept, _} =
      src
      |> String.split("\n")
      |> Enum.reduce({[], false}, fn line, {kept, excused?} ->
        cond do
          marker?(line) -> {kept, true}
          excused? -> {kept, false}
          true -> {[line | kept], false}
        end
      end)

    kept |> Enum.reverse() |> Enum.join("\n")
  end
end
