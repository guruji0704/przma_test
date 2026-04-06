defmodule Przma.Workers.ParquetCompaction do
  @moduledoc "STUB: Weekly Oban worker for Iceberg/Parquet compaction."
  use Oban.Worker, queue: :analytics

  @impl Oban.Worker
  def perform(_job) do
    :ok
  end
end
