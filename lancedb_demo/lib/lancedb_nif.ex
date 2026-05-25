defmodule LancedbNif do
  use Rustler,
    otp_app: :lance_linode,
    crate: "lancedb_nif",
    mode: :debug        # ← use debug mode, uses half the RAM

  def write_record(_bucket, _endpoint, _region, _access_key, _secret_key, _id, _name),
    do: :erlang.nif_error(:nif_not_loaded)

  def read_records(_bucket, _endpoint, _region, _access_key, _secret_key),
    do: :erlang.nif_error(:nif_not_loaded)
end