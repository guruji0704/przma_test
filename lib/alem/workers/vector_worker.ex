defmodule Alem.Workers.VectorWorker do
  @moduledoc "Async vector worker using Task (no Oban required)"
  require Logger
  alias Alem.Repo
  alias Alem.Schemas.Document
  alias Alem.Storage.Paths

  def new(args) do
    Task.start(fn -> perform(args) end)
    {:ok, :enqueued}
  end

  def perform(args) do
    doc_id       = args["doc_id"]
    did          = args["did"]
    vault        = String.to_existing_atom(args["vault"])
    content_hash = args["content_hash"]
    content_type = args["content_type"]
    Logger.info("[VectorWorker] #{doc_id} vault=#{vault}")
    with {:ok, _doc}   <- get_doc(doc_id),
         {:ok, vector} <- generate_vector(content_hash, content_type),
         :ok           <- write_lancedb(did, vault, doc_id, content_hash, vector) do
      Logger.info("[VectorWorker] ✅ #{doc_id}")
    else
      {:error, r} -> Logger.error("[VectorWorker] ❌ #{doc_id}: #{inspect(r)}")
    end
  end

  defp get_doc(id) do
    case Alem.Repo.get(Document, id) do
      nil -> {:error, :not_found}
      doc -> {:ok, doc}
    end
  end

  defp generate_vector(hash, ctype) do
    try do
      {:ok, Alem.Lance.encode(hash, ctype)}
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  defp write_lancedb(did, vault, doc_id, hash, vector) do
    uri   = System.get_env("LANCEDB_URI")
    table = "przma_#{vault}_vectors"
    entry = %{doc_id: doc_id, content_hash: hash, vault: to_string(vault),
              namespace: Paths.namespace_key(did, vault), vector: vector,
              indexed_at: DateTime.utc_now() |> DateTime.to_iso8601()}
    try do
      Alem.Lance.write(uri, table, entry)
      :ok
    rescue
      e -> Logger.warning("[VectorWorker] LanceDB skip: #{Exception.message(e)}"); :ok
    end
  end
end
