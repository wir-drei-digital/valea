defmodule Valea.Ledger.CanonicalTest do
  use ExUnit.Case, async: true

  alias Valea.Ledger.Canonical

  defp encoded(value), do: IO.iodata_to_binary(Canonical.encode(value))

  # What the encoder would produce if it trusted map iteration order. For a
  # 40-key hashmap that is NOT the sorted order, which is what makes the
  # load-bearing assertion below bite.
  defp inline_order(map) do
    "{" <> Enum.map_join(map, ",", fn {key, value} -> ~s("#{key}":#{value}) end) <> "}"
  end

  describe "encode/1" do
    test "sorts object keys, recursively — the golden vector" do
      assert encoded(%{"b" => 1, "a" => [1, %{"d" => 2, "c" => 3}]}) ==
               ~s({"a":[1,{"c":3,"d":2}],"b":1})
    end

    test "leaves go through Jason: escaping, unicode, numbers, null" do
      assert encoded(%{"q" => ~s(a "b" \\ c\n)}) == ~s({"q":"a \\"b\\" \\\\ c\\n"})
      assert encoded(%{"z" => "ü", "a" => nil}) == ~s({"a":null,"z":"ü"})
      assert encoded([1, -2, 1.5, true, false]) == "[1,-2,1.5,true,false]"
      assert encoded(%{}) == "{}"
      assert encoded([]) == "[]"
    end

    test "atom keys are stringified, so a mixed map still has one order" do
      assert encoded(%{:b => 1, "a" => 2}) == ~s({"a":2,"b":1})
    end

    # Small maps are flatmaps, whose iteration order happens to be insertion
    # order — which can mask a missing sort. Past 32 keys a map becomes a hashmap
    # and iterates in an order that has nothing to do with insertion, so this is
    # where the sort is genuinely load-bearing.
    test "40 keys, built in two different orders, encode identically and sorted" do
      keys = for n <- 1..40, do: "k#{n}"
      forwards = Map.new(keys, &{&1, 1})
      backwards = keys |> Enum.reverse() |> Map.new(&{&1, 1})

      assert encoded(forwards) == encoded(backwards)

      assert encoded(forwards) ==
               "{" <> Enum.map_join(Enum.sort(keys), ",", &~s("#{&1}":1)) <> "}"

      refute encoded(forwards) == inline_order(forwards)
    end
  end

  describe "hash/1" do
    test "is the pinned SHA-256 of the canonical encoding" do
      value = %{"b" => 1, "a" => [1, %{"d" => 2, "c" => 3}]}

      assert Canonical.hash(value) ==
               "e23f8d4197e06fb14090fd7ae275b6f9f4e8449202851dab79c411cb3426d4a2"
    end

    test "key order never moves it; content always does" do
      assert Canonical.hash(%{"a" => 1, "b" => 2}) == Canonical.hash(%{"b" => 2, "a" => 1})

      assert Canonical.hash(%{"payload" => %{"x" => 1, "y" => 2}}) ==
               Canonical.hash(%{"payload" => %{"y" => 2, "x" => 1}})

      refute Canonical.hash(%{"a" => 1}) == Canonical.hash(%{"a" => "1"})
      refute Canonical.hash(%{"a" => 1}) == Canonical.hash(%{"a" => 1, "b" => nil})
    end

    test "is lowercase hex" do
      assert String.match?(Canonical.hash(%{"a" => 1}), ~r/\A[0-9a-f]{64}\z/)
    end
  end
end
