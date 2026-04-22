defmodule Alem.LanceDB do
  use Rustler, otp_app: :alem, crate: "lancedb_nif"

  @doc """
  Appends an Arrow IPC batch to a LanceDB table.
  """
  def append_ipc(_table_name, _ipc_data), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Queries a LanceDB table and returns results.
  """
  def query(_table_name, _filter, _limit), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Lists all tables in the database.
  """
  def list_tables(), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Deletes data from a table.
  """
  def delete(_table_name, _filter), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Inserts JSON data into a table.
  """
  def insert_json(_table_name, _json_data), do: :erlang.nif_error(:nif_not_loaded)
end
