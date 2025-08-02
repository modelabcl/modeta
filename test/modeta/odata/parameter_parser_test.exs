defmodule Modeta.OData.ParameterParserTest do
  use ExUnit.Case, async: true
  alias Modeta.OData.ParameterParser

  @moduletag capture_log: true

  describe "extract_odata_params/1" do
    test "extracts all OData system query parameters" do
      params = %{
        "$filter" => "age gt 21",
        "$select" => "name,email",
        "$expand" => "orders",
        "$orderby" => "name asc",
        "$count" => "true",
        "$skip" => "10",
        "$top" => "20",
        "custom" => "ignored"
      }

      result = ParameterParser.extract_odata_params(params)

      expected = %{
        "$filter" => "age gt 21",
        "$expand" => "orders",
        "$select" => "name,email",
        "$orderby" => "name asc",
        "$count" => "true",
        "$skip" => "10",
        "$top" => "20"
      }

      assert result == expected
    end

    test "handles missing parameters with nil values" do
      params = %{"custom" => "value"}

      result = ParameterParser.extract_odata_params(params)

      expected = %{
        "$filter" => nil,
        "$expand" => nil,
        "$select" => nil,
        "$orderby" => nil,
        "$count" => nil,
        "$skip" => nil,
        "$top" => nil
      }

      assert result == expected
    end

    test "handles empty params map" do
      result = ParameterParser.extract_odata_params(%{})

      assert result["$filter"] == nil
      assert result["$select"] == nil
      assert result["$expand"] == nil
      assert result["$orderby"] == nil
      assert result["$count"] == nil
      assert result["$skip"] == nil
      assert result["$top"] == nil
    end

    test "ignores non-OData parameters" do
      params = %{
        "$filter" => "test",
        "page" => "1",
        "limit" => "50",
        "sort" => "name",
        "format" => "json"
      }

      result = ParameterParser.extract_odata_params(params)

      assert result["$filter"] == "test"
      # Only OData params
      assert Map.keys(result) |> length() == 7
      refute Map.has_key?(result, "page")
      refute Map.has_key?(result, "limit")
    end
  end

  describe "validate_top_param/1" do
    test "validates positive integer strings" do
      assert ParameterParser.validate_top_param("10") == {:ok, 10}
      assert ParameterParser.validate_top_param("1") == {:ok, 1}
      assert ParameterParser.validate_top_param("1000") == {:ok, 1000}
    end

    test "validates positive integers" do
      assert ParameterParser.validate_top_param(10) == {:ok, 10}
      assert ParameterParser.validate_top_param(1) == {:ok, 1}
      assert ParameterParser.validate_top_param(1000) == {:ok, 1000}
    end

    test "handles nil value" do
      assert ParameterParser.validate_top_param(nil) == {:ok, nil}
    end

    test "enforces maximum page size" do
      # Assuming max_page_size is 5000
      assert ParameterParser.validate_top_param("10000") == {:ok, 5000}
      assert ParameterParser.validate_top_param(10000) == {:ok, 5000}
    end

    test "rejects zero and negative values" do
      assert ParameterParser.validate_top_param("0") ==
               {:error, {"$top", "must be a positive integer"}}

      assert ParameterParser.validate_top_param("-1") ==
               {:error, {"$top", "must be a positive integer"}}

      assert ParameterParser.validate_top_param(0) ==
               {:error, {"$top", "must be a positive integer"}}

      assert ParameterParser.validate_top_param(-1) ==
               {:error, {"$top", "must be a positive integer"}}
    end

    test "rejects invalid formats" do
      assert ParameterParser.validate_top_param("abc") ==
               {:error, {"$top", "must be a valid integer"}}

      assert ParameterParser.validate_top_param("10.5") ==
               {:error, {"$top", "must be a valid integer"}}

      assert ParameterParser.validate_top_param("") ==
               {:error, {"$top", "must be a valid integer"}}

      assert ParameterParser.validate_top_param([]) ==
               {:error, {"$top", "must be a positive integer"}}
    end

    test "handles partial integer parsing" do
      assert ParameterParser.validate_top_param("10abc") ==
               {:error, {"$top", "must be a valid integer"}}
    end
  end

  describe "validate_skip_param/1" do
    test "validates non-negative integer strings" do
      assert ParameterParser.validate_skip_param("0") == {:ok, 0}
      assert ParameterParser.validate_skip_param("10") == {:ok, 10}
      assert ParameterParser.validate_skip_param("1000") == {:ok, 1000}
    end

    test "validates non-negative integers" do
      assert ParameterParser.validate_skip_param(0) == {:ok, 0}
      assert ParameterParser.validate_skip_param(10) == {:ok, 10}
      assert ParameterParser.validate_skip_param(1000) == {:ok, 1000}
    end

    test "handles nil value" do
      assert ParameterParser.validate_skip_param(nil) == {:ok, nil}
    end

    test "rejects negative values" do
      assert ParameterParser.validate_skip_param("-1") ==
               {:error, {"$skip", "must be a non-negative integer"}}

      assert ParameterParser.validate_skip_param(-1) ==
               {:error, {"$skip", "must be a non-negative integer"}}
    end

    test "rejects invalid formats" do
      assert ParameterParser.validate_skip_param("abc") ==
               {:error, {"$skip", "must be a valid integer"}}

      assert ParameterParser.validate_skip_param("10.5") ==
               {:error, {"$skip", "must be a valid integer"}}

      assert ParameterParser.validate_skip_param("") ==
               {:error, {"$skip", "must be a valid integer"}}

      assert ParameterParser.validate_skip_param([]) ==
               {:error, {"$skip", "must be a non-negative integer"}}
    end
  end

  describe "validate_count_param/1" do
    test "validates boolean string values" do
      assert ParameterParser.validate_count_param("true") == {:ok, true}
      assert ParameterParser.validate_count_param("false") == {:ok, false}
    end

    test "validates boolean values" do
      assert ParameterParser.validate_count_param(true) == {:ok, true}
      assert ParameterParser.validate_count_param(false) == {:ok, false}
    end

    test "handles nil value" do
      assert ParameterParser.validate_count_param(nil) == {:ok, nil}
    end

    test "rejects invalid values" do
      assert ParameterParser.validate_count_param("yes") ==
               {:error, {"$count", "must be 'true' or 'false'"}}

      assert ParameterParser.validate_count_param("1") ==
               {:error, {"$count", "must be 'true' or 'false'"}}

      assert ParameterParser.validate_count_param(1) ==
               {:error, {"$count", "must be 'true' or 'false'"}}

      assert ParameterParser.validate_count_param("") ==
               {:error, {"$count", "must be 'true' or 'false'"}}
    end

    test "is case sensitive" do
      assert ParameterParser.validate_count_param("TRUE") ==
               {:error, {"$count", "must be 'true' or 'false'"}}

      assert ParameterParser.validate_count_param("False") ==
               {:error, {"$count", "must be 'true' or 'false'"}}
    end
  end

  describe "validate_select_param/1" do
    test "validates non-empty strings" do
      assert ParameterParser.validate_select_param("name,email") == {:ok, "name,email"}
      assert ParameterParser.validate_select_param("id") == {:ok, "id"}
      assert ParameterParser.validate_select_param("  name  ") == {:ok, "  name  "}
    end

    test "handles nil value" do
      assert ParameterParser.validate_select_param(nil) == {:ok, nil}
    end

    test "rejects empty strings" do
      assert ParameterParser.validate_select_param("") == {:error, {"$select", "cannot be empty"}}

      assert ParameterParser.validate_select_param("   ") ==
               {:error, {"$select", "cannot be empty"}}
    end

    test "rejects non-string values" do
      assert ParameterParser.validate_select_param([]) ==
               {:error, {"$select", "must be a string"}}

      assert ParameterParser.validate_select_param(123) ==
               {:error, {"$select", "must be a string"}}

      assert ParameterParser.validate_select_param(%{}) ==
               {:error, {"$select", "must be a string"}}
    end
  end

  describe "validate_expand_param/1" do
    test "validates non-empty strings" do
      assert ParameterParser.validate_expand_param("orders") == {:ok, "orders"}
      assert ParameterParser.validate_expand_param("orders,products") == {:ok, "orders,products"}
    end

    test "handles nil value" do
      assert ParameterParser.validate_expand_param(nil) == {:ok, nil}
    end

    test "rejects empty strings" do
      assert ParameterParser.validate_expand_param("") == {:error, {"$expand", "cannot be empty"}}

      assert ParameterParser.validate_expand_param("   ") ==
               {:error, {"$expand", "cannot be empty"}}
    end

    test "rejects non-string values" do
      assert ParameterParser.validate_expand_param([]) ==
               {:error, {"$expand", "must be a string"}}
    end
  end

  describe "validate_orderby_param/1" do
    test "validates non-empty strings" do
      assert ParameterParser.validate_orderby_param("name asc") == {:ok, "name asc"}

      assert ParameterParser.validate_orderby_param("name desc, age asc") ==
               {:ok, "name desc, age asc"}
    end

    test "handles nil value" do
      assert ParameterParser.validate_orderby_param(nil) == {:ok, nil}
    end

    test "rejects empty strings" do
      assert ParameterParser.validate_orderby_param("") ==
               {:error, {"$orderby", "cannot be empty"}}
    end

    test "rejects non-string values" do
      assert ParameterParser.validate_orderby_param([]) ==
               {:error, {"$orderby", "must be a string"}}
    end
  end

  describe "validate_filter_param/1" do
    test "validates non-empty strings" do
      assert ParameterParser.validate_filter_param("age gt 21") == {:ok, "age gt 21"}
      assert ParameterParser.validate_filter_param("name eq 'John'") == {:ok, "name eq 'John'"}
    end

    test "handles nil value" do
      assert ParameterParser.validate_filter_param(nil) == {:ok, nil}
    end

    test "rejects empty strings" do
      assert ParameterParser.validate_filter_param("") == {:error, {"$filter", "cannot be empty"}}
    end

    test "rejects non-string values" do
      assert ParameterParser.validate_filter_param([]) ==
               {:error, {"$filter", "must be a string"}}
    end
  end

  describe "parse_comma_separated/1" do
    test "parses comma-separated values" do
      result = ParameterParser.parse_comma_separated("name,email,age")
      assert result == ["name", "email", "age"]
    end

    test "trims whitespace from values" do
      result = ParameterParser.parse_comma_separated(" name , email , age ")
      assert result == ["name", "email", "age"]
    end

    test "removes empty values" do
      result = ParameterParser.parse_comma_separated("name,,email,")
      assert result == ["name", "email"]
    end

    test "handles single value" do
      result = ParameterParser.parse_comma_separated("name")
      assert result == ["name"]
    end

    test "handles empty string" do
      result = ParameterParser.parse_comma_separated("")
      assert result == []
    end

    test "handles only whitespace and commas" do
      result = ParameterParser.parse_comma_separated(" , , ")
      assert result == []
    end

    test "handles non-string input" do
      assert ParameterParser.parse_comma_separated(nil) == []
      assert ParameterParser.parse_comma_separated(123) == []
      assert ParameterParser.parse_comma_separated([]) == []
    end
  end

  describe "normalize_param_name/1" do
    test "adds $ prefix to parameter names" do
      assert ParameterParser.normalize_param_name("filter") == "$filter"
      assert ParameterParser.normalize_param_name("select") == "$select"
      assert ParameterParser.normalize_param_name("top") == "$top"
    end

    test "preserves existing $ prefix" do
      assert ParameterParser.normalize_param_name("$filter") == "$filter"
      assert ParameterParser.normalize_param_name("$select") == "$select"
    end

    test "handles empty string" do
      assert ParameterParser.normalize_param_name("") == "$"
    end

    test "handles non-string input" do
      assert ParameterParser.normalize_param_name(nil) == nil
      assert ParameterParser.normalize_param_name(123) == nil
    end
  end

  describe "is_odata_param?/1" do
    test "identifies OData system query parameters" do
      assert ParameterParser.is_odata_param?("$filter") == true
      assert ParameterParser.is_odata_param?("$select") == true
      assert ParameterParser.is_odata_param?("$expand") == true
      assert ParameterParser.is_odata_param?("$orderby") == true
      assert ParameterParser.is_odata_param?("$top") == true
      assert ParameterParser.is_odata_param?("$skip") == true
      assert ParameterParser.is_odata_param?("$count") == true
      assert ParameterParser.is_odata_param?("$search") == true
      assert ParameterParser.is_odata_param?("$apply") == true
    end

    test "rejects non-OData parameters" do
      assert ParameterParser.is_odata_param?("filter") == false
      assert ParameterParser.is_odata_param?("page") == false
      assert ParameterParser.is_odata_param?("limit") == false
      assert ParameterParser.is_odata_param?("$custom") == false
      assert ParameterParser.is_odata_param?("") == false
    end

    test "handles nil input" do
      assert ParameterParser.is_odata_param?(nil) == false
    end
  end

  describe "validate_odata_params/1 integration" do
    test "validates all parameters successfully" do
      params = %{
        "$top" => "10",
        "$skip" => "0",
        "$count" => "true",
        "$select" => "name,email",
        "$expand" => "orders",
        "$orderby" => "name asc",
        "$filter" => "age gt 21"
      }

      result = ParameterParser.validate_odata_params(params)

      assert {:ok, validated} = result
      assert validated["$top"] == 10
      assert validated["$skip"] == 0
      assert validated["$count"] == true
      assert validated["$select"] == "name,email"
      assert validated["$expand"] == "orders"
      assert validated["$orderby"] == "name asc"
      assert validated["$filter"] == "age gt 21"
    end

    test "returns error for first invalid parameter" do
      params = %{
        "$top" => "invalid",
        "$skip" => "0"
      }

      result = ParameterParser.validate_odata_params(params)
      assert {:error, {"$top", "must be a valid integer"}} = result
    end

    test "handles nil parameters" do
      params = %{
        "$top" => nil,
        "$skip" => nil,
        "$count" => nil,
        "$select" => nil,
        "$expand" => nil,
        "$orderby" => nil,
        "$filter" => nil
      }

      result = ParameterParser.validate_odata_params(params)
      assert {:ok, validated} = result
      assert Enum.all?(validated, fn {_, v} -> v == nil end)
    end
  end
end
