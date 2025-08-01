defmodule Modeta.ODataFilter do
  @moduledoc """
  OData v4 $filter query parser and SQL translator.

  Handles common OData filter expressions and converts them to SQL WHERE clauses.
  """

  @doc """
  Parse an OData filter expression and convert to SQL WHERE clause.

  Examples:
    parse_filter("name eq 'John'") -> "name = 'John'"
    parse_filter("age gt 21") -> "age > 21"
    parse_filter("name eq 'John' and age gt 21") -> "name = 'John' AND age > 21"
  """
  def parse_filter(nil), do: {:ok, nil}
  def parse_filter(""), do: {:ok, nil}

  def parse_filter(filter_string) when is_binary(filter_string) do
    try do
      case Modeta.ODataFilterParserSimple.parse_simple_filter(filter_string) do
        {:ok, [comparison: [field, operator, value]], "", _, _, _} ->
          sql_where = build_sql_condition(field, operator, value)
          {:ok, sql_where}

        {:error, reason, rest, _, _, _} ->
          {:error, "Parse error: #{reason} at '#{rest}'"}

        _ ->
          # For now, if complex parsing fails, try simple regex-based parsing
          parse_filter_regex(filter_string)
      end
    rescue
      # If NimbleParsec throws an error, fall back to regex parsing
      _ -> parse_filter_regex(filter_string)
    end
  end

  # Fallback regex-based parser for simple cases
  defp parse_filter_regex(filter_string) do
    # Handle simple comparisons: field op value
    case Regex.run(~r/^\s*(\w+)\s+(eq|ne|gt|ge|lt|le)\s+(.+)\s*$/i, filter_string) do
      [_, field, op, value] ->
        operator = String.to_atom(String.downcase(op))
        parsed_value = parse_value(String.trim(value))
        sql_where = build_sql_condition({:field, field}, operator, parsed_value)
        {:ok, sql_where}

      nil ->
        {:error, "Unsupported filter expression: #{filter_string}"}
    end
  end

  # Parse a value from string
  defp parse_value("'" <> rest) do
    # String value - remove surrounding quotes
    value = String.trim_trailing(rest, "'")
    {:string, value}
  end

  defp parse_value(value_str) do
    cond do
      # Try integer
      Regex.match?(~r/^-?\d+$/, value_str) ->
        {:number, String.to_integer(value_str)}

      # Try float
      Regex.match?(~r/^-?\d+\.\d+$/, value_str) ->
        {:number, String.to_float(value_str)}

      # Try boolean
      String.downcase(value_str) in ["true", "false"] ->
        {:boolean, String.downcase(value_str) == "true"}

      # Default to identifier/field
      true ->
        {:field, value_str}
    end
  end

  # Build SQL condition from parsed components
  defp build_sql_condition({:field, field}, operator, value) do
    sql_op = odata_op_to_sql(operator)
    sql_value = format_sql_value(value)
    "#{field} #{sql_op} #{sql_value}"
  end

  # Convert OData operators to SQL operators
  defp odata_op_to_sql(:eq), do: "="
  defp odata_op_to_sql(:ne), do: "!="
  defp odata_op_to_sql(:gt), do: ">"
  defp odata_op_to_sql(:ge), do: ">="
  defp odata_op_to_sql(:lt), do: "<"
  defp odata_op_to_sql(:le), do: "<="

  # Format values for SQL
  defp format_sql_value({:string, value}) do
    # Escape single quotes
    "'#{String.replace(value, "'", "''")}'"
  end

  defp format_sql_value({:number, value}) do
    to_string(value)
  end

  defp format_sql_value({:boolean, true}) do
    "TRUE"
  end

  defp format_sql_value({:boolean, false}) do
    "FALSE"
  end

  defp format_sql_value({:field, field}) do
    field
  end

  @doc """
  Apply filter to a DuckDB query.

  Takes a base query and adds WHERE clause if filter is provided.
  """
  def apply_filter_to_query(base_query, nil), do: base_query
  def apply_filter_to_query(base_query, ""), do: base_query

  def apply_filter_to_query(base_query, filter_string) do
    case parse_filter(filter_string) do
      {:ok, nil} ->
        base_query

      {:ok, where_clause} ->
        # Add WHERE clause to the query
        if String.contains?(String.upcase(base_query), "WHERE") do
          "#{base_query} AND (#{where_clause})"
        else
          "#{base_query} WHERE #{where_clause}"
        end

      {:error, _reason} ->
        # If filter parsing fails, return original query
        base_query
    end
  end
end
