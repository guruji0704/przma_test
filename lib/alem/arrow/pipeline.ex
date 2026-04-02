defmodule Alem.Arrow.Pipeline do
  @moduledoc """
  Shared Arrow IPC → Parquet → S3 pipeline.

  Used by both the analytics controller (bulk export) and the sync
  controller (per-file upload metadata).  Every uploaded file now
  produces one Parquet shard on S3:

    vault/{user_id}/year={Y}/month={M}/week={W}/{doc_id}.parquet

  This makes the vault fully queryable by DuckDB / Athena / Presto:

    SELECT * FROM read_parquet('s3://bucket/vault/user_123/**/*.parquet')
    WHERE content_type = 'image/jpeg' AND year = 2026

  Arrow is the transport format — Parquet is the storage format.
  """

  require Logger

  # ── Arrow IPC stream → DataFrame ──────────────────────────────────────

  @doc """
  Decode base64 Arrow IPC bytes to an Explorer DataFrame.
  Accepts the IPC stream format produced by the Rust client (StreamWriter).
  """
  def decode_ipc_b64(b64) when is_binary(b64) and b64 != "" do
    case Base.decode64(b64) do
      {:ok, bytes} -> load_ipc_stream(bytes)
      :error       -> {:error, :invalid_base64}
    end
  end
  def decode_ipc_b64(_), do: {:error, :missing_arrow_ipc}

  def load_ipc_stream(bytes) when is_list(bytes) do
    load_ipc_stream(:erlang.list_to_binary(bytes))
  end

  def load_ipc_stream(bytes) when is_binary(bytes) do
    case Explorer.DataFrame.load_ipc_stream(bytes) do
      {:ok, df}        -> {:ok, df}
      {:error, reason} -> {:error, {:load_ipc, reason}}
    end
  end

  def load_ipc_stream(_), do: {:error, {:load_ipc, :invalid_input}}

  # ── DataFrame → Parquet bytes ──────────────────────────────────────────

  def to_parquet(df) do
    case Explorer.DataFrame.dump_parquet(df) do
      {:ok, bytes}     -> {:ok, bytes}
      {:error, reason} -> {:error, {:dump_parquet, reason}}
    end
  end

  # ── Parquet bytes → S3 (Hive-partitioned path) ────────────────────────

  @doc """
  Write a Parquet shard to S3 at:
    vault/{user_id}/year={Y}/month={M}/week={W}/{shard_id}.parquet

  Partition columns (year/month/week) are read from the first row of the
  DataFrame.  If the batch spans multiple partitions the caller should
  split it first; for single-file uploads (one row) this is exact.
  """
  def store_parquet(user_id, df, pq_bytes, shard_id \\ nil) do
    id = shard_id || UUID.uuid4()

    {year, month, week} =
      try do
        y = df |> Explorer.DataFrame.pull("year")  |> Explorer.Series.first()
        m = df |> Explorer.DataFrame.pull("month") |> Explorer.Series.first()
        w = df |> Explorer.DataFrame.pull("week")  |> Explorer.Series.first()
        {y || "unknown", m || "unknown", w || "unknown"}
      rescue
        _ -> {"unknown", "unknown", "unknown"}
      end

    s3_key = "vault/#{user_id}/year=#{year}/month=#{month}/week=#{week}/#{id}.parquet"
    bucket = System.get_env("AWS_S3_BUCKET", "perkeep")

    Logger.info("[Arrow.Pipeline] Writing Parquet shard: #{s3_key} (#{byte_size(pq_bytes)} bytes)")

    case upload_parquet_to_s3(bucket, s3_key, pq_bytes) do
      :ok  -> {:ok, s3_key}
      err  -> err
    end
  end

  # ── Full pipeline: b64 IPC → DataFrame → Parquet → S3 ─────────────────

  @doc """
  One-call pipeline used by the sync controller on every file upload.
  Returns {:ok, s3_key} or {:error, reason}.
  Errors are non-fatal — callers should log and continue.
  """
  def ingest(user_id, arrow_ipc_b64, shard_id \\ nil) do
    with {:ok, df}       <- decode_ipc_b64(arrow_ipc_b64),
         {:ok, pq_bytes} <- to_parquet(df)
    do
      store_parquet(user_id, df, pq_bytes, shard_id)
    end
  end

  # ── S3 upload ─────────────────────────────────────────────────────────

  defp upload_parquet_to_s3(bucket, s3_key, bytes) do
    if Application.get_env(:alem, :analytics_dev_bypass, false) do
      Logger.info("[Arrow.Pipeline] Dev bypass — skipping S3 write for #{s3_key}")
      :ok
    else
      case ExAws.S3.upload(bucket, s3_key, bytes,
             content_type: "application/x-parquet"
           ) |> ExAws.request(timeout: 600_000, recv_timeout: 600_000) do
        {:ok, _}         -> :ok
        {:error, reason} ->
          Logger.error("[Arrow.Pipeline] S3 write failed #{s3_key}: #{inspect(reason)}")
          {:error, {:s3_write_failed, reason}}
      end
    end
  end
end
