defmodule AlemWeb.AnalyticsController do
  @moduledoc """
  Receives Arrow IPC batches from Tauri clients and converts them to
  Parquet for S3/MinIO cold storage.

  Flow:
    Client (Rust/Tauri)
      │  documents_to_ipc_bytes()   ← arrow/mod.rs
      │  base64 encode
      ▼
    POST /api/v1/analytics/ingest
      │  Base64 decode → binary
      │  Explorer.DataFrame.load_ipc/1  ← zero-copy columnar load
      │  Explorer.DataFrame.dump_parquet/1
      ▼
    S3/MinIO
      vault/{user_did}/year=YYYY/month=MM/week=WW/{batch_id}.parquet

  The Parquet files are Hive-partitioned so DuckDB can prune entire
  year/month/week folder groups without scanning individual rows.
  """

  use AlemWeb, :controller
  require Logger

  # Dynamic bucket resolution
  defp get_s3_bucket do
    case System.get_env("AWS_S3_BUCKET") do
      nil -> Application.get_env(:alem, :file_storage)[:bucket] || "perkeep"
      ""  -> Application.get_env(:alem, :file_storage)[:bucket] || "perkeep"
      val -> val
    end
  end

  # ── POST /api/v1/analytics/ingest ──────────────────────────────────────────

  def ingest(conn, params) do
    with {:ok, user}      <- get_current_user(conn),
         {:ok, ipc_b64}   <- require_param(params, "ipc_base64"),
         {:ok, ipc_bytes}  <- decode_base64(ipc_b64),
         {:ok, df}         <- load_arrow_ipc(ipc_bytes),
         {:ok, pq_bytes}   <- to_parquet(df),
         {:ok, s3_key}     <- store_parquet(user.id, df, pq_bytes)
    do
      record_count = Explorer.DataFrame.n_rows(df)
      Logger.info("[Analytics] Ingested #{record_count} rows → #{s3_key} (#{byte_size(pq_bytes)} bytes Parquet)")

      json(conn, %{
        success:      true,
        record_count: record_count,
        s3_key:       s3_key,
        parquet_size: byte_size(pq_bytes)
      })
    else
      {:error, reason} ->
        Logger.error("[Analytics] Ingest failed: #{inspect(reason)}")
        conn |> put_status(400) |> json(%{error: inspect(reason)})
    end
  end

  # ── GET /api/v1/analytics/schema ───────────────────────────────────────────

  @doc """
  Returns the canonical Arrow schema so clients can validate their batch
  before sending. Useful during development.
  """
  def schema(conn, _params) do
    json(conn, %{
      schema: %{
        doc_id:          "utf8",
        filename:        "utf8",
        file_size:       "int64",
        content_type:    "utf8",
        status:          "utf8",
        is_synced:       "boolean",
        needs_upload:    "boolean",
        inserted_at:     "timestamp[ms, UTC]",
        day:             "utf8  (YYYY-MM-DD)",
        week:            "int32 (ISO week 1-53)",
        month:           "int32 (1-12)",
        year:            "int32"
      },
      partition_path: "vault/{user_did}/year=YYYY/month=MM/week=WW/{batch_id}.parquet",
      note: "Pre-partition Arrow batches by year+month+week for optimal DuckDB pruning."
    })
  end

  # ── Private helpers ────────────────────────────────────────────────────────

  defp get_current_user(conn) do
    # In dev mode, allow unauthenticated requests from localhost for testing.
    dev_bypass = Application.get_env(:alem, :analytics_dev_bypass, false)
    remote_ip  = conn.remote_ip |> Tuple.to_list() |> Enum.join(".")

    if dev_bypass and remote_ip in ["127.0.0.1", "0.0.0.0", "::1"] do
      {:ok, %{id: "dev-local-user"}}
    else
      token = get_req_header(conn, "authorization")
      |> List.first("")
      |> String.replace_prefix("Bearer ", "")

      case Alem.Auth.verify_token(token) do
        {:ok, user} -> {:ok, user}
        _           -> {:error, :unauthorized}
      end
    end
  end

  defp require_param(params, key) do
    case Map.get(params, key) do
      nil -> {:error, "Missing required param: #{key}"}
      val -> {:ok, val}
    end
  end

  defp decode_base64(b64) do
    case Base.decode64(b64) do
      {:ok, bytes} -> {:ok, bytes}
      :error       -> {:error, "Invalid base64 in ipc_base64"}
    end
  end

  defp load_arrow_ipc(bytes) do
    # The Tauri client uses arrow::ipc::writer::StreamWriter (IPC stream format).
    # Explorer.DataFrame.load_ipc/1 expects the IPC file format (with footer magic).
    # load_ipc_stream/1 handles the stream format produced by the Rust client.
    case Explorer.DataFrame.load_ipc_stream(bytes) do
      {:ok, df} -> {:ok, df}
      {:error, reason} -> {:error, {:load_ipc, reason}}
    end
  end

  defp to_parquet(df) do
    case Explorer.DataFrame.dump_parquet(df) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, reason} -> {:error, {:dump_parquet, reason}}
    end
  end

  # Build Hive-partitioned S3 key from the first row's partition columns.
  # If the batch spans multiple partitions the caller should split first;
  # for now we use the dominant (first-row) partition.
  defp store_parquet(user_id, df, pq_bytes) do
    batch_id = UUID.uuid4()

    # Extract partition from first row
    {year, month, week} =
      try do
        year  = df |> Explorer.DataFrame.pull("year")  |> Explorer.Series.first()
        month = df |> Explorer.DataFrame.pull("month") |> Explorer.Series.first()
        week  = df |> Explorer.DataFrame.pull("week")  |> Explorer.Series.first()
        {year || "unknown", month || "unknown", week || "unknown"}
      rescue
        _ -> {"unknown", "unknown", "unknown"}
      end

    s3_key = "vault/#{user_id}/year=#{year}/month=#{month}/week=#{week}/#{batch_id}.parquet"

    case upload_to_s3(s3_key, pq_bytes) do
      :ok -> {:ok, s3_key}
      err -> err
    end
  end

  defp upload_to_s3(s3_key, bytes) do
    if Application.get_env(:alem, :analytics_dev_bypass, false) do
      # Dev mode: save Parquet to priv/parquet_dev/ instead of S3
      local_path = Path.join([:code.priv_dir(:alem), "parquet_dev", s3_key])
      File.mkdir_p!(Path.dirname(local_path))
      File.write!(local_path, bytes)
      Logger.info("[Analytics] [DEV] Parquet saved locally: #{local_path}")
      :ok
    else
      op = ExAws.S3.put_object(get_s3_bucket(), s3_key, bytes, [
        {:content_type, "application/vnd.apache.parquet"},
        {:acl, :private}
      ])

      case ExAws.request(op) do
        {:ok, _}         -> :ok
        {:error, reason} -> {:error, {:s3_upload, reason}}
      end
    end
  end
end
