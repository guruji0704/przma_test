defmodule Alem.Lance.TestConnection do
  @moduledoc "Quick smoke test to verify LanceDB is reachable and working."

  alias Alem.Lance.{Config, Table, Query}
  require Logger

  def run do
    Logger.info("[LanceDB Test] ========= Starting connection test =========")

    cfg = Config.new() |> Config.validate!()
    Logger.info("[LanceDB Test] Connecting to: #{cfg.base_url}")

    # Step 1: List tables
    Logger.info("[LanceDB Test] Step 1: List tables")
    case Table.list(cfg) do
      {:ok, tables} ->
        Logger.info("[LanceDB Test] ✅ Connected! Existing tables: #{inspect(tables)}")
      {:error, err} ->
        Logger.error("[LanceDB Test] ❌ Cannot connect: #{inspect(err)}")
        raise "LanceDB connection failed — is the server running on #{cfg.base_url}?"
    end

    # Step 2: Create test table
    Logger.info("[LanceDB Test] Step 2: Create test table")
    schema = %{
      fields: [
        %{name: "id",         type: "utf8"},
        %{name: "message",    type: "utf8"},
        %{name: "created_at", type: "int64"}
      ]
    }
    case Table.create(cfg, "przma_connection_test", %{schema: schema}) do
      {:ok, _} ->
        Logger.info("[LanceDB Test] ✅ Table created")
      {:error, %{kind: :conflict}} ->
        Logger.info("[LanceDB Test] ✅ Table already exists (ok)")
      {:error, err} ->
        Logger.error("[LanceDB Test] ❌ Create failed: #{inspect(err)}")
    end

    # Step 3: Insert a row
    Logger.info("[LanceDB Test] Step 3: Insert row")
    record = %{
      "id"         => "test_#{System.os_time(:second)}",
      "message"    => "Hello PRZMA LanceDB #{DateTime.utc_now()}",
      "created_at" => System.os_time(:second)
    }
    case Table.insert(cfg, "przma_connection_test", [record]) do
      {:ok, _} ->
        Logger.info("[LanceDB Test] ✅ Row inserted: #{record["id"]}")
      {:error, err} ->
        Logger.error("[LanceDB Test] ❌ Insert failed: #{inspect(err)}")
    end

    # Step 4: Query it back
    Logger.info("[LanceDB Test] Step 4: Query rows")
    q = Query.new() |> Query.limit(10)
    case Table.search(cfg, "przma_connection_test", q) do
      {:ok, rows} ->
        Logger.info("[LanceDB Test] ✅ Query returned #{length(rows)} row(s)")
        Enum.each(rows, fn row ->
          Logger.info("[LanceDB Test]    → #{row["id"]}: #{row["message"]}")
        end)
        {:ok, rows}
      {:error, err} ->
        Logger.error("[LanceDB Test] ❌ Query failed: #{inspect(err)}")
        {:error, err}
    end
  end
end
