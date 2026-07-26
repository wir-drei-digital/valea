defmodule Valea.PathsBoundaryTest do
  use ExUnit.Case, async: true

  @exempt ["lib/valea/paths.ex", "lib/valea/icm/backlinks.ex"]

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
end
