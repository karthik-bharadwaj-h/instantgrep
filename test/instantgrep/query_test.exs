defmodule Instantgrep.QueryTest do
  use ExUnit.Case, async: true

  alias Instantgrep.Query

  describe "decompose/1" do
    test "literal string produces AND of trigrams" do
      assert {:all, trigrams} = Query.decompose("hello")
      assert "hel" in trigrams
      assert "ell" in trigrams
      assert "llo" in trigrams
    end

    test "alternation produces OR of branches" do
      assert {:any, branches} = Query.decompose("cat|dog")

      assert Enum.any?(branches, fn
               {:all, t} -> "cat" in t
               _ -> false
             end)

      assert Enum.any?(branches, fn
               {:all, t} -> "dog" in t
               _ -> false
             end)
    end

    test "pure wildcard returns :none" do
      assert Query.decompose(".*") == :none
      assert Query.decompose(".+") == :none
    end

    test "mixed literal and wildcard extracts literal trigrams" do
      assert {:all, trigrams} = Query.decompose("hello.*world")
      assert "hel" in trigrams
      assert "wor" in trigrams
    end

    test "short pattern with no trigrams returns :none" do
      assert Query.decompose("ab") == :none
      assert Query.decompose(".") == :none
    end

    test "character class breaks trigram chain" do
      result = Query.decompose("[abc]def")
      assert result == {:all, ["def"]} or result == :none
    end
  end

  describe "evaluate/2" do
    test ":none evaluates to :all" do
      assert Query.evaluate(:none, fn _ -> MapSet.new() end) == :all
    end

    test "AND intersects posting lists" do
      query = {:all, ["abc", "bcd"]}

      result =
        Query.evaluate(query, fn
          "abc" -> MapSet.new([1, 2, 3])
          "bcd" -> MapSet.new([2, 3, 4])
        end)

      assert result == MapSet.new([2, 3])
    end

    test "OR unions posting lists" do
      query = {:any, [{:all, ["abc"]}, {:all, ["xyz"]}]}

      result =
        Query.evaluate(query, fn
          "abc" -> MapSet.new([1, 2])
          "xyz" -> MapSet.new([3, 4])
        end)

      assert result == MapSet.new([1, 2, 3, 4])
    end
  end

  describe "extract_literals/1" do
    test "extracts literal segments from patterns" do
      assert "hello" in Query.extract_literals("hello")
      assert "world" in Query.extract_literals("hello.*world")
    end

    test "handles escaped characters as literals" do
      literals = Query.extract_literals("a\\.b")
      assert Enum.any?(literals, &String.contains?(&1, "."))
    end
  end
end
