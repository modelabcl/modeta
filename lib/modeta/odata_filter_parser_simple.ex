defmodule Modeta.ODataFilterParserSimple do
  @moduledoc """
  Simple OData v4 $filter parser using NimbleParsec.
  
  Supports basic comparison operations for now.
  """
  
  import NimbleParsec

  # Whitespace
  whitespace = ascii_char([?\s, ?\t]) |> times(min: 1) |> ignore()
  optional_ws = ascii_char([?\s, ?\t]) |> times(min: 0) |> ignore()

  # Basic identifier (field name)
  identifier = 
    ascii_char([?a..?z, ?A..?Z, ?_])
    |> repeat(ascii_char([?a..?z, ?A..?Z, ?0..?9, ?_]))
    |> reduce({:chars_to_string, []})
    |> unwrap_and_tag(:field)

  # String value with single quotes
  string_value = 
    ascii_char([?'])
    |> repeat(ascii_char([{:not, ?'}]))
    |> ascii_char([?'])
    |> reduce({:chars_to_string, []})
    |> map({:extract_string_content, []})
    |> unwrap_and_tag(:string)

  # Number value
  number_value = 
    optional(ascii_char([?-]))
    |> integer(min: 1)
    |> optional(ascii_char([?.]) |> integer(min: 1))
    |> reduce({:chars_to_string, []})
    |> map({:parse_number_content, []})
    |> unwrap_and_tag(:number)

  # Value (string or number or identifier)
  value = choice([string_value, number_value, identifier])

  # Comparison operators
  comparison_op = 
    choice([
      string("eq") |> replace(:eq),
      string("ne") |> replace(:ne),
      string("gt") |> replace(:gt),
      string("ge") |> replace(:ge),
      string("lt") |> replace(:lt),
      string("le") |> replace(:le)
    ])

  # Simple comparison: field op value
  defparsec :parse_simple_filter,
    optional_ws
    |> concat(value)
    |> concat(whitespace)
    |> concat(comparison_op)
    |> concat(whitespace)  
    |> concat(value)
    |> concat(optional_ws)
    |> eos()
    |> tag(:comparison)

  # Helper functions
  defp extract_string_content(str) do
    String.slice(str, 1..-2//1)  # Remove surrounding quotes
  end

  defp parse_number_content(str) do
    if String.contains?(str, ".") do
      String.to_float(str)
    else
      String.to_integer(str)
    end
  end

  defp chars_to_string(chars) do
    chars
    |> List.flatten()
    |> Enum.map(fn
      n when is_integer(n) -> <<n>>
      s when is_binary(s) -> s
      other -> Kernel.to_string(other)
    end)
    |> Enum.join("")
  end
end