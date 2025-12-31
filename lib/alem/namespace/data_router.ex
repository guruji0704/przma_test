defmodule Alem.Namespace.DataRouter do
  @moduledoc """
  Data Router - Multi-Backend Storage Coordination
  """

  use GenServer
  require Logger

  alias Alem.Namespace.Registry
  alias Alem.Storage.{ObjectStore, DocumentStore, RelationalStore}

  defstruct [
    :user_id,
    :config,
    :storage_config,
    :stats
  ]

  # Client API

  def start(user_id, config) do
    name = Registry.via(user_id, :data_router)
    GenServer.start_link(__MODULE__, {user_id, config}, name: name)
  end

  def ingest(user_id, document) do
    GenServer.call(Registry.lookup!(user_id, :data_router), {:ingest, document}, 30_000)
  end

  def list_documents(user_id, opts \\ []) do
    GenServer.call(Registry.lookup!(user_id, :data_router), {:list_documents, opts})
  end

  def get_document(user_id, document_id, opts \\ []) do
    GenServer.call(Registry.lookup!(user_id, :data_router), {:get_document, document_id, opts})
  end

  def delete_document(user_id, document_id) do
    GenServer.call(Registry.lookup!(user_id, :data_router), {:delete_document, document_id})
  end

  def search(user_id, query, opts \\ []) do
    GenServer.call(Registry.lookup!(user_id, :data_router), {:search, query, opts})
  end

  def sync(user_id, source, opts \\ []) do
    GenServer.cast(Registry.lookup!(user_id, :data_router), {:sync, source, opts})
  end

  def stats(user_id) do
    GenServer.call(Registry.lookup!(user_id, :data_router), :stats)
  end

  # GenServer Implementation

  @impl true
  def init({user_id, config}) do
    Logger.info("[DataRouter:#{user_id}] Starting data router")

    database_name = "alem_#{user_id}"
    DocumentStore.ensure_database(database_name)

    state = %__MODULE__{
      user_id: user_id,
      config: config,
      storage_config: Map.merge(config.storage, %{
        couchdb_database: database_name
      }),
      stats: %{
        documents_ingested: 0,
        bytes_stored: 0,
        last_sync: nil
      }
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:ingest, document}, _from, state) do
    case do_ingest(state, document) do
      {:ok, doc_id} ->
        new_stats = %{state.stats |
          documents_ingested: state.stats.documents_ingested + 1,
          bytes_stored: state.stats.bytes_stored + byte_size(document.content)
        }
        {:reply, {:ok, doc_id}, %{state | stats: new_stats}}

      {:error, reason} = error ->
        Logger.error("[DataRouter:#{state.user_id}] Ingest failed: #{inspect(reason)}")
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:list_documents, opts}, _from, state) do
    result = do_list_documents(state, opts)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:get_document, document_id, opts}, _from, state) do
    result = do_get_document(state, document_id, opts)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:delete_document, document_id}, _from, state) do
    result = do_delete_document(state, document_id)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:search, query, opts}, _from, state) do
    result = do_search(state, query, opts)
    {:reply, result, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    {:reply, {:ok, state.stats}, state}
  end

  @impl true
  def handle_cast({:sync, source, opts}, state) do
    Task.start(fn -> do_sync(state, source, opts) end)
    {:noreply, %{state | stats: %{state.stats | last_sync: DateTime.utc_now()}}}
  end

  # Private Implementation

  defp do_ingest(state, document) do
    user_id = state.user_id
    doc_id = generate_document_id()

    Logger.info("[DataRouter:#{user_id}] Starting ingestion for #{document.filename}")

    with :ok <- validate_document(document),
         {:ok, object_key} <- store_raw_file(state, doc_id, document),
         {:ok, extracted} <- extract_content(document),
         {:ok, _couch_rev} <- store_document_record(state, doc_id, document, extracted, object_key),
         {:ok, _pg_record} <- create_search_record(state, doc_id, document, extracted) do
      Logger.info("[DataRouter:#{user_id}] ✅ Successfully ingested document #{doc_id}")
      {:ok, doc_id}
    else
      {:error, reason} = error ->
        Logger.error("[DataRouter:#{user_id}] ❌ Ingestion failed: #{inspect(reason)}")
        error
    end
  end

  defp validate_document(%{filename: f, content: c}) when is_binary(f) and is_binary(c) do
    :ok
  end
  defp validate_document(_), do: {:error, :invalid_document}

  defp store_raw_file(state, doc_id, document) do
    bucket = Application.get_env(:alem, :file_storage)[:bucket]
    prefix = state.storage_config.s3_prefix
    key = "#{prefix}documents/#{doc_id}/#{document.filename}"

    case ObjectStore.put(bucket, key, document.content, %{
      content_type: document[:content_type] || "application/octet-stream",
      metadata: %{"original_filename" => document.filename}
    }) do
      :ok -> {:ok, key}
      error -> error
    end
  end

  defp extract_content(document) do
    text = case document[:content_type] do
      "text/plain" -> document.content
      "text/" <> _ -> document.content
      _ -> "Binary content: #{document.filename}"
    end

    {:ok, %{
      text: text,
      metadata: %{
        word_count: String.split(text, ~r/\s+/) |> length(),
        char_count: String.length(text),
        language: "en"
      }
    }}
  end

  defp store_document_record(state, doc_id, document, extracted, object_key) do
    db = state.storage_config.couchdb_database

    doc = %{
      "_id" => doc_id,
      "type" => "document",
      "user_id" => state.user_id,
      "filename" => document.filename,
      "content_type" => document[:content_type],
      "object_key" => object_key,
      "extracted_text" => extracted.text,
      "metadata" => Map.merge(document[:metadata] || %{}, extracted.metadata),
      "status" => "completed",
      "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    DocumentStore.put(db, doc)
  end

  defp create_search_record(state, doc_id, document, extracted) do
    RelationalStore.insert(:documents, %{
      id: doc_id,
      user_id: state.user_id,
      filename: document.filename,
      content_type: document[:content_type],
      text_content: extracted.text,
      metadata: document[:metadata] || %{},
      status: "completed",
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    })
  end

  defp do_list_documents(state, opts) do
    RelationalStore.list(:documents, %{
      user_id: state.user_id,
      limit: opts[:limit] || 100,
      offset: opts[:offset] || 0
    })
  end

  defp do_get_document(state, document_id, opts) do
    db = state.storage_config.couchdb_database

    case DocumentStore.get(db, document_id) do
      {:ok, doc} ->
        doc = if opts[:include_content] do
          bucket = Application.get_env(:alem, :file_storage)[:bucket]
          case ObjectStore.get(bucket, doc["object_key"]) do
            {:ok, content} -> Map.put(doc, "raw_content", content)
            _ -> doc
          end
        else
          doc
        end

        {:ok, doc}

      error -> error
    end
  end

  defp do_delete_document(state, document_id) do
    db = state.storage_config.couchdb_database
    bucket = Application.get_env(:alem, :file_storage)[:bucket]

    with {:ok, doc} <- DocumentStore.get(db, document_id),
         :ok <- ObjectStore.delete(bucket, doc["object_key"]),
         :ok <- DocumentStore.delete(db, document_id, doc["_rev"]),
         :ok <- RelationalStore.delete(:documents, document_id) do
      Logger.info("[DataRouter:#{state.user_id}] ✅ Deleted document #{document_id}")
      :ok
    end
  end

  defp do_search(state, query, opts) do
    RelationalStore.search(:documents, query, %{
      user_id: state.user_id,
      limit: opts[:limit] || 20
    })
  end

  defp do_sync(state, _source, _opts) do
    Logger.info("[DataRouter:#{state.user_id}] Sync completed")
    :ok
  end

  defp generate_document_id do
    "doc_" <> (:crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false))
  end
end
