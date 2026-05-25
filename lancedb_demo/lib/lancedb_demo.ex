defmodule LanceLinode do
  @moduledoc """
  Simple wrapper around LanceDB + Linode Object Storage.
  """

  # Your Linode credentials — use env vars in real apps
  @bucket     "perkeep"
  @endpoint   "https://in-maa-1.linodeobjects.com"
  @region     "in-maa-1"
  @access_key System.get_env("AWS_ACCESS_KEY_ID", "QBQ24J1P1BV957AUYYXV")
  @secret_key System.get_env("AWS_SECRET_ACCESS_KEY", "LqqbMn1gBggICrvrqQMOKQ57T9rnqeXXOx6x8H7B")

  @doc """
  Write a record to Linode Object Storage via LanceDB.

  Example:
      LanceLinode.write(1, "hello world")
      # => :ok
  """
  def write(id, name) do
    LancedbNif.write_record(
      @bucket,
      @endpoint,
      @region,
      @access_key,
      @secret_key,
      id,
      name
    )
  end

  @doc """
  Read all records back from Linode Object Storage.

  Example:
      LanceLinode.read()
      # => ["hello world", "second record"]
  """
  def read do
    LancedbNif.read_records(
      @bucket,
      @endpoint,
      @region,
      @access_key,
      @secret_key
    )
  end
end