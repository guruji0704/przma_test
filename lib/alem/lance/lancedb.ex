defmodule Alem.LanceDB do
  use Rustler, otp_app: :alem, crate: "lancedb_nif"

  def append_ipc(_table_name, _ipc_data),
    do: :erlang.nif_error(:nif_not_loaded)

  def query(_table_name, _filter, _limit),
    do: :erlang.nif_error(:nif_not_loaded)

  def list_tables(),
    do: :erlang.nif_error(:nif_not_loaded)

  def delete(_table_name, _filter),
    do: :erlang.nif_error(:nif_not_loaded)

  def insert_json(_table_name, _json_data),
    do: :erlang.nif_error(:nif_not_loaded)
end
