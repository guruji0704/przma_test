defmodule Alem.Sqld do
  require Logger

  @sqld_url Application.compile_env(:alem, :sqld_url, "http://localhost:8080")

  # ══════════════════════════════════════════════════════════════════════════
  # Schema Setup
  # ══════════════════════════════════════════════════════════════════════════

  def ensure_schema do
    Logger.info("[sqld] Bootstrapping schema...")

    statements = [
      """
      CREATE TABLE IF NOT EXISTS documents (
        id               TEXT PRIMARY KEY,
        user_id          TEXT NOT NULL,
        filename         TEXT NOT NULL,
        automerge_state  BLOB,
        s3_content_key   TEXT,
        epoch_id         INTEGER,
        device_id        TEXT,
        last_modified_at TEXT,
        file_size        INTEGER DEFAULT 0,
        status           TEXT DEFAULT 'synced',
        inserted_at      TEXT NOT NULL,
        updated_at       TEXT NOT NULL
      )
      """,
      "CREATE INDEX IF NOT EXISTS idx_docs_user    ON documents(user_id)",
      "CREATE INDEX IF NOT EXISTS idx_docs_updated ON documents(updated_at)",
      """
      CREATE TABLE IF NOT EXISTS epoch_keys (
        epoch_id            INTEGER PRIMARY KEY,
        public_key_b64      TEXT    NOT NULL,
        enc_private_key_b64 TEXT,
        started_at          TEXT    NOT NULL,
        expires_at          TEXT    NOT NULL,
        grace_until         TEXT,
        is_current          INTEGER DEFAULT 0
      )
      """,
      "CREATE INDEX IF NOT EXISTS idx_epoch_current ON epoch_keys(is_current)"
    ]

    results = Enum.map(statements, fn sql -> execute(sql) end)

    if Enum.all?(results, &(&1 == :ok)) do
      Logger.info("[sqld] ✅ Schema ready")
    else
      Logger.error("[sqld] ❌ Schema partially failed. Results: #{inspect(results)}")
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Execute Function - WITH ERROR HANDLING
  # ══════════════════════════════════════════════════════════════════════════

  def execute(sql, args \\ []) do
    body = Jason.encode!(%{
      requests: [
        %{type: "execute", stmt: %{sql: sql, args: Enum.map(args, &encode_arg/1)}},
        %{type: "close"}
      ]
    })

    case Req.post("#{@sqld_url}/v3/pipeline",
           body: body,
           headers: [{"content-type", "application/json"}],
           receive_timeout: 15_000,
           # ✅ FIX: Automatically retry on connection closed or timeout
           retry: :transient,
           max_retries: 3
         ) do
      {:ok, %{status: 200, body: resp_body}} ->
        case resp_body do
          %{"results" => [%{"response" => %{"error" => error}} | _]} ->
            Logger.error("[sqld] SQL Error: #{inspect(error)}")
            {:error, {:sql_error, error}}
          _ ->
            :ok
        end

      {:ok, %{status: status, body: resp_body}} ->
        Logger.error("[sqld] HTTP #{status}: #{inspect(resp_body)}")
        {:error, {:http, status}}

      {:error, reason} ->
        Logger.error("[sqld] Request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Encoders
  # ══════════════════════════════════════════════════════════════════════════

  defp encode_arg(v) when is_binary(v) do
    if String.valid?(v) do
      %{"type" => "text", "value" => v}
    else
      %{"type" => "blob", "base64" => Base.encode64(v)}
    end
  end

  defp encode_arg(nil), do: %{"type" => "null", "value" => nil}
  defp encode_arg(v) when is_integer(v), do: %{"type" => "integer", "value" => to_string(v)}
  defp encode_arg(v), do: %{"type" => "text", "value" => to_string(v)}
end
