defmodule AlemWeb.PrzmaAnalyticsController do
  @moduledoc """
  Analytics Controller for PRZMA.
  
  Handles DataFusion query results which are returned as Arrow RecordBatches over
  Arrow IPC. This ensures peak performance by avoiding deserialization unless
  explicitly requested (e.g., for JSON-only API boundaries).
  """
  use AlemWeb, :controller
  require Logger

  @doc """
  Execute a query and return results.
  
  Defaults to returning raw Arrow IPC bytes (application/vnd.apache.arrow.stream)
  to maintain zero-copy performance down to the client.
  """
  def query(conn, %{"sql" => sql} = params) do
    # In a real implementation, this would call a DataFusion NIF or service.
    # DataFusion returns RecordBatches natively, which we obtain as IPC bytes.
    case execute_datafusion_query(sql) do
      {:ok, ipc_bytes} ->
        if Map.get(params, "accept") == "application/json" do
          # Only convert to JSON at the API boundary if requested.
          case Explorer.DataFrame.load_ipc(ipc_bytes) do
            {:ok, df} ->
              # Convert DataFrame to JSON rows
              json(conn, %{
                success: true,
                data: Explorer.DataFrame.to_rows(df),
                count: Explorer.DataFrame.n_rows(df)
              })
            {:error, reason} ->
              Logger.error("[Analytics] Arrow decode failed: #{inspect(reason)}")
              conn |> put_status(500) |> json(%{error: "Internal Arrow error"})
          end
        else
          # FAST PATH: Return raw Arrow IPC bytes directly.
          conn
          |> put_resp_content_type("application/vnd.apache.arrow.stream")
          |> send_resp(200, ipc_bytes)
        end

      {:error, reason} ->
        Logger.error("[Analytics] Query failed: #{inspect(reason)}")
        conn |> put_status(400) |> json(%{error: reason})
    end
  end

  # Mock implementation of DataFusion query execution.
  # Returns Arrow IPC bytes.
  defp execute_datafusion_query(_sql) do
    # Generate some dummy data via Explorer and dump to IPC
    df = Explorer.DataFrame.new(%{
      "heart_score" => [85.5, 87.2, 84.8],
      "timestamp" => [1711800000, 1711803600, 1711807200],
      "user_id" => ["user_1", "user_1", "user_1"]
    }) |> elem(1)

    Explorer.DataFrame.dump_ipc(df)
  end
end
