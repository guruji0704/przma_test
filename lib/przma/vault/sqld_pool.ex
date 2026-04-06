defmodule Przma.Vault.SQLdPool do
  @moduledoc """
  STUB: HTTP connection pool to sqld shards.

  TODO Phase 2: Implement real sqld HTTP connection pool using
  Finch or Req. Each shard is a libsql-server instance.
  Connection assignment is based on DID hash % shard_count.
  """
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @doc "Check out a connection handle for a given DID."
  def checkout(_did) do
    # Stub: return a fake connection reference
    {:ok, :stub_connection}
  end

  @doc "Return a connection back to the pool."
  def checkin(_conn), do: :ok

  @doc "Execute a write SQL statement."
  def execute(_conn, _sql, _params) do
    # Stub: return empty success
    {:ok, %{rows_affected: 0}}
  end

  @doc "Execute a read SQL query."
  def query(_conn, _sql, _params) do
    # Stub: return empty rows
    {:ok, []}
  end
end
