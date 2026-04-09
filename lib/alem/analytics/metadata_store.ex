defmodule Alem.Analytics.MetadataStore do
  @moduledoc """
  Service for ingesting and persisting document metadata for analytics.
  Converts Arrow IPC batches from clients into Parquet shards on S3.
  """

  require Logger
  alias Explorer.DataFrame

  @bucket "perkeep"

  @doc """
  Ingests an Arrow IPC binary batch and persists it to S3 as a Parquet shard.
  Partitioned by user_id and date.
  """
  def ingest(ipc_binary, user_id, doc_id) do
    Logger.info("[Analytics] Ingesting metadata for doc_id: #{doc_id}")

    try do
      # 1. Load Arrow IPC into Explorer (Polars)
      df = DataFrame.load_ipc!(ipc_binary)
      
      # 2. Add server-side dimensions (ingested_at)
      now = DateTime.utc_now() |> DateTime.to_iso8601()
      df = DataFrame.put(df, :ingested_at, [now])
      
      # 3. Create a temporary Parquet file
      temp_path = "/tmp/metadata_#{doc_id}.parquet"
      DataFrame.to_parquet(df, temp_path)
      
      # 4. Upload to S3
      date_str = DateTime.utc_now() |> Calendar.strftime("%Y-%m-%d")
      s3_key = "analytics/user_id=#{user_id}/dt=#{date_str}/#{doc_id}.parquet"
      
      content = File.read!(temp_path)
      
      ExAws.S3.put_object(@bucket, s3_key, content)
      |> ExAws.request!(virtual_host: false)

      # 5. Cleanup
      File.rm(temp_path)
      
      Logger.info("[Analytics] Metadata persisted to S3: #{s3_key}")
      {:ok, s3_key}
    rescue
      e ->
        Logger.error("[Analytics] Failed to ingest metadata: #{inspect(e)}")
        {:error, e}
    end
  end

  @doc """
  Example query: Get total storage used by a user across all synced files.
  This demonstrates how we can query the Parquet files directly.
  """
  def get_user_stats(user_id) do
    # In a real scenario, we would use a glob pattern to load all parquet shards for the user
    # Explorer.DataFrame.from_parquet("s3://perkeep/analytics/user_id=#{user_id}/**/*.parquet")
    # For now, this is a placeholder for the Track B query engine.
    {:ok, %{note: "Query engine implementation in progress"}}
  end
end
