defmodule Alem.PrzmaBroadwayPipeline do
  @moduledoc """
  Broadway Analytics Pipeline.
  
  Processes scan event batches and assembles them as Arrow RecordBatches
  before final durable write to Parquet on S3.
  """
  use Broadway
  require Logger

  def start_link(_opts) do
    Broadway.start_link(__MODULE__,
      name: __MODULE__,
      producer: [
        module: {Broadway.DummyProducer, []}, # Replace with actual event producer (Kafka/Rabbit/etc)
        concurrency: 1
      ],
      processors: [
        default: [concurrency: 5]
      ],
      batchers: [
        analytics_vault: [
          batch_size: 50,
          batch_timeout: 5000,
          concurrency: 2
        ]
      ]
    )
  end

  @impl true
  def handle_message(_processor, message, _context) do
    # Each message is a scan event
    message
  end

  @impl true
  def handle_batch(:analytics_vault, messages, _batch_info, _context) do
    Logger.info("[Broadway] Processing batch of #{length(messages)} scan events")

    # 1. Collect event data from messages
    events = Enum.map(messages, & &1.data)

    # 2. Assemble as Arrow RecordBatch (via Explorer DataFrame)
    case Explorer.DataFrame.new(events) do
      {:ok, df} ->
        # 3. Direct path to Parquet (Arrow and Parquet share the same columnar model)
        case Explorer.DataFrame.dump_parquet(df) do
          {:ok, pq_bytes} ->
            # 4. Use existing Pipeline to store on S3
            case Alem.Arrow.Pipeline.store_parquet("broadway-analytics", df, pq_bytes) do
              {:ok, s3_key} ->
                Logger.info("[Broadway] Successfully stored batch at #{s3_key}")
                messages
              {:error, reason} ->
                Logger.error("[Broadway] S3 store failed: #{inspect(reason)}")
                messages # In production, might want to signal failure
            end
          {:error, reason} ->
            Logger.error("[Broadway] Parquet dump failed: #{inspect(reason)}")
            messages
        end
      {:error, reason} ->
        Logger.error("[Broadway] DataFrame assembly failed: #{inspect(reason)}")
        messages
    end
  end
end
