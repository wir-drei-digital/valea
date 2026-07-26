defmodule Valea.PathsBoundaryTest do
  use ExUnit.Case, async: true

  @exempt ["lib/valea/paths.ex", "lib/valea/icm/backlinks.ex"]

  # Same offender/exempt mechanism for the binary-pattern family below. Each
  # entry is exempt for a stated reason, not by convenience:
  #
  #   * `paths.ex` — owns the path grammar; the patterns ARE the implementation.
  #   * `icm/backlinks.ex` — `dest_entry/3` classifies MARKDOWN URL
  #     destinations, where a leading `/` means root-relative in URL space.
  #     Not a filesystem decision, so `Valea.Paths` must not touch it. KNOWN
  #     HOLE: its `to_abs/2` is the unmigrated twin of the one in
  #     `link_rewrite.ex` (a real filesystem gate) and is only exempt because
  #     the exemption is file-level — migrate it when that file next opens.
  #   * `icm/link_rewrite.ex` — same class: `replacement/3`'s first argument is
  #     the raw markdown destination string from the document (see the
  #     `# markdown-URL classification` comment there). File-level, so it can
  #     no longer ENFORCE the filesystem sites in that file; `to_abs/2` there
  #     was migrated to `Valea.Paths.absolute?/1` regardless.
  @pattern_exempt [
    "lib/valea/paths.ex",
    "lib/valea/icm/backlinks.ex",
    "lib/valea/icm/link_rewrite.ex"
  ]

  test "absoluteness/ancestor string logic lives only in Valea.Paths (windows spec D4)" do
    offenders =
      Path.wildcard("lib/**/*.ex")
      |> Enum.reject(fn f -> Enum.any?(@exempt, &String.ends_with?(f, &1)) end)
      |> Enum.filter(fn f ->
        src = File.read!(f)

        Regex.match?(~r/starts_with\?\([^\n)]*"\/"\s*\)/, src) or
          Regex.match?(~r/starts_with\?\([^\n)]*<>\s*"\/"/, src)
      end)

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
      Path.wildcard("lib/**/*.ex")
      |> Enum.reject(fn f -> Enum.any?(@pattern_exempt, &String.ends_with?(f, &1)) end)
      |> Enum.filter(fn f ->
        src = File.read!(f)
        Regex.match?(head, src) or Regex.match?(clause, src)
      end)

    assert offenders == [],
           "absoluteness decided by binary pattern outside Valea.Paths " <>
             "(route through absolute?/classify): #{inspect(offenders)}"
  end
end
