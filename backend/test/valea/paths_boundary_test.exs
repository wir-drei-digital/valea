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

  # Every non-exempt `lib` module as `{path, source}`, with site-marked lines
  # removed so both detectors share one notion of what is in scope.
  defp scannable_files do
    Path.wildcard("lib/**/*.ex")
    |> Enum.reject(fn f -> Enum.any?(@exempt, &String.ends_with?(f, &1)) end)
    |> Enum.map(fn f -> {f, f |> File.read!() |> strip_marked_sites()} end)
  end

  # Drops each `# paths-exempt:` marker together with the one line it excuses.
  defp strip_marked_sites(src) do
    {kept, _} =
      src
      |> String.split("\n")
      |> Enum.reduce({[], false}, fn line, {kept, excused?} ->
        cond do
          String.contains?(line, @exempt_marker) -> {kept, true}
          excused? -> {kept, false}
          true -> {[line | kept], false}
        end
      end)

    kept |> Enum.reverse() |> Enum.join("\n")
  end
end
