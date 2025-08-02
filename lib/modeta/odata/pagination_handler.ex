defmodule Modeta.OData.PaginationHandler do
  @moduledoc """
  Handles OData pagination and count operations.

  This module provides functionality for:
  - Processing $count parameter requests
  - Executing count queries with filter support
  - Managing total count calculations for pagination
  - Validating count-related parameters

  Extracted from ModetaWeb.ODataController to separate pagination logic
  from web layer concerns.
  """

  alias Modeta.Cache

  @doc """
  Checks if the $count parameter requests total count inclusion.

  Determines whether the client has requested the total count of entities
  to be included in the response via the @odata.count annotation.

  ## Parameters
  - count_param: The $count parameter value from the request

  ## Returns
  - true if count should be included
  - false if count should not be included

  ## Examples
      iex> PaginationHandler.should_include_count?("true")
      true
      
      iex> PaginationHandler.should_include_count?(true)
      true
      
      iex> PaginationHandler.should_include_count?("false")
      false
      
      iex> PaginationHandler.should_include_count?(nil)
      false
  """
  def should_include_count?(count_param) do
    case count_param do
      "true" -> true
      true -> true
      _ -> false
    end
  end

  @doc """
  Gets the total count of records matching filter criteria.

  Executes a COUNT(*) query against the base query with any filters applied,
  but without pagination, select, orderby, or expand operations that would
  affect the total count.

  ## Parameters
  - base_query: The base SQL query string
  - filter_param: Optional $filter parameter value

  ## Returns
  - Integer representing the total count of matching records
  - Returns 0 if the count query fails to prevent crashes

  ## Examples
      iex> PaginationHandler.get_total_count("SELECT * FROM customers", nil)
      150
      
      iex> PaginationHandler.get_total_count("SELECT * FROM customers", "age gt 21")
      85
  """
  def get_total_count(base_query, filter_param) do
    # Build count query with filter applied but without pagination, select, orderby, or expand
    count_query =
      case filter_param do
        nil ->
          "SELECT COUNT(*) as total_count FROM (#{base_query}) AS count_data"

        filter ->
          filtered_query = Modeta.ODataFilter.apply_filter_to_query(base_query, filter)
          "SELECT COUNT(*) as total_count FROM (#{filtered_query}) AS count_data"
      end

    case Cache.query(count_query) do
      {:ok, result} ->
        # Extract count from first row, first column
        rows = Cache.to_rows(result)

        case rows do
          [[count] | _] when is_integer(count) -> count
          _ -> 0
        end

      {:error, _reason} ->
        # If count query fails, return 0 rather than crashing
        0
    end
  end

  @doc """
  Builds a count query with optional filtering.

  Creates a SQL COUNT(*) query that respects any filter conditions but
  ignores other OData system query options that don't affect the total count.

  ## Parameters
  - base_query: The base SQL query string
  - filter_param: Optional $filter parameter value

  ## Returns
  - String containing the COUNT(*) SQL query

  ## Examples
      iex> PaginationHandler.build_count_query("SELECT * FROM customers", nil)
      "SELECT COUNT(*) as total_count FROM (SELECT * FROM customers) AS count_data"
      
      iex> PaginationHandler.build_count_query("SELECT * FROM customers", "age gt 21")
      "SELECT COUNT(*) as total_count FROM (SELECT * FROM customers WHERE age > 21) AS count_data"
  """
  def build_count_query(base_query, filter_param) do
    case filter_param do
      nil ->
        "SELECT COUNT(*) as total_count FROM (#{base_query}) AS count_data"

      filter ->
        filtered_query = Modeta.ODataFilter.apply_filter_to_query(base_query, filter)
        "SELECT COUNT(*) as total_count FROM (#{filtered_query}) AS count_data"
    end
  end

  @doc """
  Executes a count query and extracts the result.

  Runs the count query against the database and safely extracts the
  integer count value from the result.

  ## Parameters
  - count_query: SQL COUNT(*) query string

  ## Returns
  - Integer count value on success
  - 0 on failure to prevent crashes
  """
  def execute_count_query(count_query) do
    case Cache.query(count_query) do
      {:ok, result} ->
        extract_count_from_result(result)

      {:error, _reason} ->
        # If count query fails, return 0 rather than crashing
        0
    end
  end

  @doc """
  Validates count parameter value.

  Checks if the provided count parameter is in a valid format
  and represents a boolean-like value.

  ## Parameters
  - count_param: The $count parameter value to validate

  ## Returns
  - {:ok, boolean} if parameter is valid
  - {:error, reason} if parameter is invalid

  ## Examples
      iex> PaginationHandler.validate_count_param("true")
      {:ok, true}
      
      iex> PaginationHandler.validate_count_param("false")  
      {:ok, false}
      
      iex> PaginationHandler.validate_count_param("invalid")
      {:error, "Invalid $count value. Expected 'true' or 'false'"}
  """
  def validate_count_param(count_param) do
    case count_param do
      "true" -> {:ok, true}
      "false" -> {:ok, false}
      true -> {:ok, true}
      false -> {:ok, false}
      nil -> {:ok, false}
      _ -> {:error, "Invalid $count value. Expected 'true' or 'false'"}
    end
  end

  # Private helper functions

  # Extract count value from database result
  defp extract_count_from_result(result) do
    rows = Cache.to_rows(result)

    case rows do
      [[count] | _] when is_integer(count) ->
        count

      [[count] | _] when is_binary(count) ->
        # Handle cases where count might be returned as string
        case Integer.parse(count) do
          {int_count, ""} -> int_count
          _ -> 0
        end

      _ ->
        0
    end
  end
end
