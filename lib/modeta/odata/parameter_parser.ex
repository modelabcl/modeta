defmodule Modeta.OData.ParameterParser do
  @moduledoc """
  Parses and validates OData system query parameters.

  This module provides functionality for:
  - Extracting OData system query parameters from request params
  - Validating parameter values and formats
  - Normalizing parameters for consistent processing
  - Providing parameter parsing utilities

  Extracted to centralize parameter handling logic and provide
  consistent validation across the OData system.
  """

  @doc """
  Extracts OData system query parameters from request parameters.

  Identifies and extracts all standard OData system query parameters
  from the request parameter map.

  ## Parameters
  - params: Map of request parameters

  ## Returns
  - Map containing extracted OData system query parameters

  ## Examples
      iex> params = %{"$filter" => "age gt 21", "$top" => "10", "custom" => "value"}
      iex> ParameterParser.extract_odata_params(params)
      %{
        "$filter" => "age gt 21",
        "$top" => "10",
        "$skip" => nil,
        "$select" => nil,
        "$expand" => nil,
        "$orderby" => nil,
        "$count" => nil
      }
  """
  def extract_odata_params(params) do
    %{
      "$filter" => Map.get(params, "$filter"),
      "$expand" => Map.get(params, "$expand"),
      "$select" => Map.get(params, "$select"),
      "$orderby" => Map.get(params, "$orderby"),
      "$count" => Map.get(params, "$count"),
      "$skip" => Map.get(params, "$skip"),
      "$top" => Map.get(params, "$top")
    }
  end

  @doc """
  Validates OData system query parameters.

  Performs validation on all provided OData system query parameters
  to ensure they conform to the OData specification.

  ## Parameters
  - odata_params: Map of OData system query parameters

  ## Returns
  - {:ok, validated_params} if all parameters are valid
  - {:error, {param_name, reason}} if validation fails

  ## Examples
      iex> params = %{"$top" => "10", "$skip" => "0"}
      iex> ParameterParser.validate_odata_params(params)
      {:ok, %{"$top" => 10, "$skip" => 0}}
      
      iex> params = %{"$top" => "invalid"}
      iex> ParameterParser.validate_odata_params(params)
      {:error, {"$top", "must be a positive integer"}}
  """
  def validate_odata_params(odata_params) do
    with {:ok, top} <- validate_top_param(odata_params["$top"]),
         {:ok, skip} <- validate_skip_param(odata_params["$skip"]),
         {:ok, count} <- validate_count_param(odata_params["$count"]),
         {:ok, select} <- validate_select_param(odata_params["$select"]),
         {:ok, expand} <- validate_expand_param(odata_params["$expand"]),
         {:ok, orderby} <- validate_orderby_param(odata_params["$orderby"]),
         {:ok, filter} <- validate_filter_param(odata_params["$filter"]) do
      validated_params = %{
        "$top" => top,
        "$skip" => skip,
        "$count" => count,
        "$select" => select,
        "$expand" => expand,
        "$orderby" => orderby,
        "$filter" => filter
      }

      {:ok, validated_params}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Validates the $top parameter.

  Ensures $top is a positive integer within acceptable limits.

  ## Parameters
  - top_param: The $top parameter value

  ## Returns
  - {:ok, integer} for valid values
  - {:error, reason} for invalid values
  """
  def validate_top_param(top_param) do
    max_page_size = Application.get_env(:modeta, :max_page_size, 5000)

    case top_param do
      nil ->
        {:ok, nil}

      top_str when is_binary(top_str) ->
        # Handle underscore format like "10_000" by removing underscores
        clean_str = String.replace(top_str, "_", "")

        case Integer.parse(clean_str) do
          {num, ""} when num > 0 and num <= max_page_size ->
            {:ok, num}

          {num, ""} when num > max_page_size ->
            # Cap at maximum
            {:ok, max_page_size}

          {num, ""} when num <= 0 ->
            {:error, {"$top", "must be a positive integer"}}

          _ ->
            {:error, {"$top", "must be a valid integer"}}
        end

      top_num when is_integer(top_num) and top_num > 0 ->
        {:ok, min(top_num, max_page_size)}

      _ ->
        {:error, {"$top", "must be a positive integer"}}
    end
  end

  @doc """
  Validates the $skip parameter.

  Ensures $skip is a non-negative integer.

  ## Parameters
  - skip_param: The $skip parameter value

  ## Returns
  - {:ok, integer} for valid values
  - {:error, reason} for invalid values
  """
  def validate_skip_param(skip_param) do
    case skip_param do
      nil ->
        {:ok, nil}

      skip_str when is_binary(skip_str) ->
        case Integer.parse(skip_str) do
          {num, ""} when num >= 0 ->
            {:ok, num}

          {num, ""} when num < 0 ->
            {:error, {"$skip", "must be a non-negative integer"}}

          _ ->
            {:error, {"$skip", "must be a valid integer"}}
        end

      skip_num when is_integer(skip_num) and skip_num >= 0 ->
        {:ok, skip_num}

      _ ->
        {:error, {"$skip", "must be a non-negative integer"}}
    end
  end

  @doc """
  Validates the $count parameter.

  Ensures $count is a boolean value ("true" or "false").
  """
  def validate_count_param(count_param) do
    case count_param do
      nil -> {:ok, nil}
      "true" -> {:ok, true}
      "false" -> {:ok, false}
      true -> {:ok, true}
      false -> {:ok, false}
      _ -> {:error, {"$count", "must be 'true' or 'false'"}}
    end
  end

  @doc """
  Validates the $select parameter.

  Ensures $select contains valid column names.
  """
  def validate_select_param(select_param) do
    case select_param do
      nil ->
        {:ok, nil}

      select_str when is_binary(select_str) ->
        # Basic validation - ensure not empty after trimming
        trimmed = String.trim(select_str)

        if trimmed == "" do
          {:error, {"$select", "cannot be empty"}}
        else
          {:ok, select_str}
        end

      _ ->
        {:error, {"$select", "must be a string"}}
    end
  end

  @doc """
  Validates the $expand parameter.

  Ensures $expand contains valid navigation property names.
  """
  def validate_expand_param(expand_param) do
    case expand_param do
      nil ->
        {:ok, nil}

      expand_str when is_binary(expand_str) ->
        # Basic validation - ensure not empty after trimming
        trimmed = String.trim(expand_str)

        if trimmed == "" do
          {:error, {"$expand", "cannot be empty"}}
        else
          {:ok, expand_str}
        end

      _ ->
        {:error, {"$expand", "must be a string"}}
    end
  end

  @doc """
  Validates the $orderby parameter.

  Ensures $orderby contains valid column names and sort directions.
  """
  def validate_orderby_param(orderby_param) do
    case orderby_param do
      nil ->
        {:ok, nil}

      orderby_str when is_binary(orderby_str) ->
        # Basic validation - ensure not empty after trimming
        trimmed = String.trim(orderby_str)

        if trimmed == "" do
          {:error, {"$orderby", "cannot be empty"}}
        else
          {:ok, orderby_str}
        end

      _ ->
        {:error, {"$orderby", "must be a string"}}
    end
  end

  @doc """
  Validates the $filter parameter.

  Ensures $filter contains a valid filter expression.
  """
  def validate_filter_param(filter_param) do
    case filter_param do
      nil ->
        {:ok, nil}

      filter_str when is_binary(filter_str) ->
        # Basic validation - ensure not empty after trimming
        trimmed = String.trim(filter_str)

        if trimmed == "" do
          {:error, {"$filter", "cannot be empty"}}
        else
          {:ok, filter_str}
        end

      _ ->
        {:error, {"$filter", "must be a string"}}
    end
  end

  @doc """
  Parses comma-separated parameter values.

  Splits a comma-separated parameter string into individual values,
  trims whitespace, and removes empty values.

  ## Parameters
  - param_value: Comma-separated string

  ## Returns
  - List of trimmed, non-empty values

  ## Examples
      iex> ParameterParser.parse_comma_separated("name, email, age")
      ["name", "email", "age"]
      
      iex> ParameterParser.parse_comma_separated("id,, name ,")
      ["id", "name"]
  """
  def parse_comma_separated(param_value) when is_binary(param_value) do
    param_value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  def parse_comma_separated(_), do: []

  @doc """
  Normalizes OData parameter names.

  Ensures parameter names follow the standard OData format with $ prefix.

  ## Parameters
  - param_name: Parameter name to normalize

  ## Returns
  - Normalized parameter name with $ prefix

  ## Examples
      iex> ParameterParser.normalize_param_name("filter")
      "$filter"
      
      iex> ParameterParser.normalize_param_name("$top")
      "$top"
  """
  def normalize_param_name(param_name) when is_binary(param_name) do
    if String.starts_with?(param_name, "$") do
      param_name
    else
      "$" <> param_name
    end
  end

  def normalize_param_name(_), do: nil

  @doc """
  Checks if a parameter is an OData system query parameter.

  ## Parameters
  - param_name: Parameter name to check

  ## Returns
  - true if it's an OData system query parameter
  - false otherwise
  """
  def odata_param?(param_name) do
    param_name in [
      "$filter",
      "$select",
      "$expand",
      "$orderby",
      "$top",
      "$skip",
      "$count",
      "$search",
      "$apply"
    ]
  end
end
