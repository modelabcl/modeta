defmodule Modeta.DataLoader do
  @moduledoc """
  Handles loading initial data into DuckDB on application startup.
  """

  alias Modeta.Cache

  @customers_csv_path "test/fixtures/customers.csv"

  @doc """
  Loads all initial data required for the application.
  This should be called during application startup.
  """
  def load_initial_data do
    load_customers_data()
  end

  @doc """
  Loads customers data from the fixture CSV file.
  """
  def load_customers_data do
    case Cache.load_csv(@customers_csv_path, "customers") do
      {:ok, _table_name} ->
        :ok

      {:error, reason} ->
        raise "Failed to load customers data: #{inspect(reason)}"
    end
  end
end
