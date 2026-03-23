defmodule Instantgrep.Trigram do
  @moduledoc """
  Trigram extraction from binaries with optional probabilistic masks.

  Extracts all overlapping 3-byte sequences from input binaries. Optionally computes
  bloom-filter-style masks for the 4th character (next_mask) and position (loc_mask)
  to enable "3.5-gram" selectivity without full quadgram index storage.
  """

  @type trigram :: <<_::24>>
  @type mask :: 0..255
  @type trigram_masks :: %{trigram() => {next_mask :: mask(), loc_mask :: mask()}}

  @doc """
  Extract all unique overlapping 3-byte trigrams from a binary.

  Returns a `MapSet` of 3-byte binaries.

  ## Examples

      iex> Instantgrep.Trigram.extract("hello")
      MapSet.new(["hel", "ell", "llo"])

  """
  @spec extract(binary()) :: MapSet.t(trigram())
  def extract(binary) when is_binary(binary) do
    do_extract(binary, 0, MapSet.new())
  end

  @doc """
  Extract trigrams with probabilistic masks for enhanced filtering.

  For each trigram, computes:
  - `next_mask`: 8-bit bloom filter of characters immediately following the trigram
  - `loc_mask`: 8-bit mask with `(position rem 8)` bit set for each occurrence

  Returns a map of `%{trigram => {next_mask, loc_mask}}`.
  """
  @spec extract_with_masks(binary()) :: trigram_masks()
  def extract_with_masks(binary) when is_binary(binary) do
    do_extract_with_masks(binary, 0, %{})
  end

  @doc """
  Extract trigrams from a literal string for query decomposition.

  Returns a list of trigrams in order (not deduplicated).
  """
  @spec extract_ordered(binary()) :: [trigram()]
  def extract_ordered(binary) when is_binary(binary) do
    do_extract_ordered(binary, [])
  end

  # --- Private Implementation ---

  defp do_extract(binary, pos, acc) when byte_size(binary) - pos >= 3 do
    trigram = binary_part(binary, pos, 3)
    do_extract(binary, pos + 1, MapSet.put(acc, trigram))
  end

  defp do_extract(_binary, _pos, acc), do: acc

  defp do_extract_with_masks(binary, pos, acc) when byte_size(binary) - pos >= 3 do
    trigram = binary_part(binary, pos, 3)
    loc_bit = Bitwise.bsl(1, Bitwise.band(pos, 7))

    next_bit =
      if pos + 3 < byte_size(binary) do
        next_char = :binary.at(binary, pos + 3)
        Bitwise.bsl(1, Bitwise.band(next_char, 7))
      else
        0
      end

    acc =
      Map.update(acc, trigram, {next_bit, loc_bit}, fn {existing_next, existing_loc} ->
        {Bitwise.bor(existing_next, next_bit), Bitwise.bor(existing_loc, loc_bit)}
      end)

    do_extract_with_masks(binary, pos + 1, acc)
  end

  defp do_extract_with_masks(_binary, _pos, acc), do: acc

  defp do_extract_ordered(<<a, b, c, rest::binary>>, acc) do
    do_extract_ordered(<<b, c, rest::binary>>, [<<a, b, c>> | acc])
  end

  defp do_extract_ordered(_, acc), do: Enum.reverse(acc)
end
