defmodule Przma.Workers.ContentGCSweep do
  @moduledoc "STUB: Nightly Oban worker that sweeps orphaned S3 blobs."
  use Oban.Worker, queue: :analytics

  @impl Oban.Worker
  def perform(_job) do
    Przma.Vault.ContentGC.run()
    :ok
  end
end
