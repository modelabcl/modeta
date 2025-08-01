defmodule Modeta.ODataFilterParser do
  @moduledoc """
  Parser for OData v4 $filter query expressions using NimbleParsec.
  
  Supports common OData filter operations:
  - Comparison operators: eq, ne, gt, ge, lt, le
  - Logical operators: and, or, not
  - Functions: contains, startswith, endswith
  - Data types: strings, numbers, booleans, null
  
  Example filters:
  - name eq 'John'
  - age gt 21 and country eq 'USA'
  - contains(name, 'Smith')
  """
  
  import NimbleParsec

  # Whitespace handling - define as combinators
  whitespace = ascii_char([?\s, ?\t]) |> times(min: 1) |> ignore()
  optional_whitespace = ascii_char([?\s, ?\t]) |> times(min: 0) |> ignore()

  # Basic tokens
  identifier = 
    ascii_char([?a..?z, ?A..?Z, ?_])
    |> repeat(ascii_char([?a..?z, ?A..?Z, ?0..?9, ?_]))
    |> reduce({IO, :iodata_to_binary, []})
    |> unwrap_and_tag(:identifier)

  # String literals with single quotes (OData standard)
  string_literal = 
    ascii_char([?'])
    |> repeat(
      choice([
        string("''") |> replace(?'),  # Escaped single quote
        ascii_char([{:not, ?'}])      # Any character except single quote
      ])
    )
    |> ascii_char([?'])
    |> reduce({:extract_string, []})
    |> unwrap_and_tag(:string)

  # Numeric literals
  number = 
    optional(ascii_char([?-]))
    |> integer(min: 1)
    |> optional(
      ascii_char([?.])
      |> integer(min: 1)
    )
    |> reduce({:parse_number, []})
    |> unwrap_and_tag(:number)

  # Boolean literals
  boolean = 
    choice([
      string("true") |> replace(true),
      string("false") |> replace(false)
    ])
    |> unwrap_and_tag(:boolean)

  # Null literal
  null_literal = 
    string("null")
    |> replace(nil)
    |> unwrap_and_tag(:null)

  # Values (identifiers, literals)
  value = 
    choice([
      string_literal,
      number,
      boolean,
      null_literal,
      identifier
    ])

  # Comparison operators
  comparison_operator = 
    choice([
      string("eq") |> replace(:eq),
      string("ne") |> replace(:ne),
      string("gt") |> replace(:gt),
      string("ge") |> replace(:ge),
      string("lt") |> replace(:lt),
      string("le") |> replace(:le)
    ])
    |> unwrap_and_tag(:operator)

  # Function calls (contains, startswith, endswith)
  function_call = 
    choice([
      string("contains"),
      string("startswith"), 
      string("endswith")
    ])
    |> reduce({IO, :iodata_to_binary, []})
    |> ignore(ascii_char([?(]))
    |> concat(optional_whitespace)
    |> concat(value)
    |> ignore(ascii_char([?,]))
    |> concat(optional_whitespace)
    |> concat(value)
    |> concat(optional_whitespace)
    |> ignore(ascii_char([?)]))
    |> tag(:function)

  # Helper functions for the parser
  defp extract_string([?' | chars]) do
    chars
    |> Enum.reverse()
    |> tl()  # Remove closing quote
    |> IO.iodata_to_binary()
  end

  defp parse_number(parts) do
    parts
    |> IO.iodata_to_binary()
    |> case do
      str ->
        if String.contains?(str, ".") do
          String.to_float(str)
        else
          String.to_integer(str)
        end
    end
  end


  # Define comparison as a separate parsec
  defparsec :comparison_expression,
    choice([
      function_call,
      value
      |> concat(optional_whitespace)
      |> concat(comparison_operator)
      |> concat(optional_whitespace)
      |> concat(value)
      |> tag(:comparison)
    ])

  # Forward declare the expression parsers
  defparsec :primary_expression,
    choice([
      # NOT expressions
      string("not")
      |> concat(whitespace)
      |> choice([
        ignore(ascii_char([?(]))
        |> concat(optional_whitespace)
        |> parsec(:or_expression)
        |> concat(optional_whitespace)
        |> ignore(ascii_char([?)]))
        |> tag(:parenthesized),
        parsec(:comparison_expression)
      ])
      |> tag(:not),
      
      # Parenthesized expressions
      ignore(ascii_char([?(]))
      |> concat(optional_whitespace)
      |> parsec(:or_expression)
      |> concat(optional_whitespace)
      |> ignore(ascii_char([?)]))
      |> tag(:parenthesized),
      
      # Basic comparisons
      parsec(:comparison_expression)
    ])

  # AND expressions (higher precedence than OR)
  defparsec :and_expression,
    parsec(:primary_expression)
    |> repeat(
      optional_whitespace
      |> ignore(string("and"))
      |> concat(whitespace)
      |> parsec(:primary_expression)
    )
    |> post_traverse({:build_logical_tree, [:and]})

  # OR expressions (lower precedence)
  defparsec :or_expression,
    parsec(:and_expression)
    |> repeat(
      optional_whitespace
      |> ignore(string("or"))
      |> concat(whitespace)
      |> parsec(:and_expression)
    )
    |> post_traverse({:build_logical_tree, [:or]})

  # Main public parser
  defparsec :parse_filter,
    optional_whitespace
    |> parsec(:or_expression)
    |> concat(optional_whitespace)
    |> eos()

  # Helper function to build logical expression trees
  defp build_logical_tree(_rest, [single], _context, _line, _offset, op) when length([single]) == 1 do
    {[single], _context}
  end

  defp build_logical_tree(_rest, args, context, _line, _offset, [op]) do
    tree = build_tree(args, op)
    {[tree], context}
  end

  defp build_tree([left, right], op) do
    {op, left, right}
  end

  defp build_tree([first | rest], op) do
    Enum.reduce(rest, first, fn right, left ->
      {op, left, right}
    end)
  end
end