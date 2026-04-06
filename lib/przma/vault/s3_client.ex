defmodule Przma.Vault.S3Client do
  @moduledoc """
  STUB: S3-compatible object store client wrapper.

  TODO Phase 2: Implement using ExAws.S3.
  Wraps put/get/head/delete with the configured bucket and credentials.
  """
  use GenServer

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    {:ok, %{}}
  end

  def get(_key), do: {:error, :not_found}

  def put(_key, _data, _opts \\ []), do: :ok

  def head(_key), do: {:error, :not_found}

  def delete(_key), do: :ok
end
