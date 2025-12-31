defmodule Alem.Storage.DocumentStore do
  @moduledoc """
  CouchDB Document Storage Integration
  """

  require Logger

  defp config do
    Application.get_env(:alem, :couchdb)
  end

  defp base_url do
    config()[:url]
  end

  defp auth_header do
    credentials = Base.encode64("#{config()[:user]}:#{config()[:password]}")
    {"Authorization", "Basic #{credentials}"}
  end

  defp headers do
    [
      {"Content-Type", "application/json"},
      auth_header()
    ]
  end

  @doc """
  Ensure database exists
  """
  def ensure_database(database_name) do
    url = "#{base_url()}/#{database_name}"

    # Check if database exists
    case HTTPoison.get(url, [auth_header()]) do
      {:ok, %{status_code: 200}} ->
        Logger.debug("[CouchDB] Database #{database_name} exists")
        :ok
      {:ok, %{status_code: 404}} ->
        # Database doesn't exist, create it
        Logger.info("[CouchDB] Creating database #{database_name}")
        case HTTPoison.put(url, "", headers()) do
          {:ok, %{status_code: 201}} ->
            :ok
          {:error, reason} ->
            {:error, reason}
        end
      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Store a document in CouchDB
  """
  def put(database, doc) when is_map(doc) do
    ensure_database(database)

    url = "#{base_url()}/#{database}"
    doc_id = doc["_id"]

    Logger.info("[CouchDB] Storing document #{doc_id} in #{database}")

    body = Jason.encode!(doc)

    case HTTPoison.post(url, body, headers()) do
      {:ok, %{status_code: code, body: response_body}} when code in [200, 201] ->
        case Jason.decode(response_body) do
          {:ok, %{"rev" => rev}} ->
            Logger.info("[CouchDB] ✅ Document stored: #{doc_id}")
            {:ok, rev}
          _ ->
            {:ok, "unknown"}
        end
      {:ok, %{status_code: status, body: body}} ->
        Logger.error("[CouchDB] ❌ Store failed with status #{status}: #{body}")
        {:error, {:http_error, status}}
      {:error, reason} ->
        Logger.error("[CouchDB] ❌ Store failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Retrieve a document from CouchDB
  """
  def get(database, doc_id) do
    url = "#{base_url()}/#{database}/#{doc_id}"

    Logger.info("[CouchDB] Fetching document #{doc_id} from #{database}")

    case HTTPoison.get(url, [auth_header()]) do
      {:ok, %{status_code: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, doc} ->
            Logger.info("[CouchDB] ✅ Document retrieved")
            {:ok, doc}
          _ ->
            {:error, :invalid_response}
        end
      {:ok, %{status_code: 404}} ->
        Logger.warning("[CouchDB] Document not found: #{doc_id}")
        {:error, :not_found}
      {:error, reason} ->
        Logger.error("[CouchDB] ❌ Fetch failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Delete a document from CouchDB
  """
  def delete(database, doc_id, rev) do
    url = "#{base_url()}/#{database}/#{doc_id}?rev=#{rev}"

    Logger.info("[CouchDB] Deleting document #{doc_id}")

    case HTTPoison.delete(url, [auth_header()]) do
      {:ok, %{status_code: code}} when code in [200, 202] ->
        Logger.info("[CouchDB] ✅ Document deleted")
        :ok
      {:error, reason} ->
        Logger.error("[CouchDB] ❌ Delete failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Find documents using Mango query
  """
  def find(database, query) do
    ensure_database(database)

    Logger.info("[CouchDB] Executing query on #{database}")

    url = "#{base_url()}/#{database}/_find"
    body = Jason.encode!(query)

    case HTTPoison.post(url, body, headers()) do
      {:ok, %{status_code: 200, body: response_body}} ->
        case Jason.decode(response_body) do
          {:ok, %{"docs" => docs}} ->
            Logger.info("[CouchDB] ✅ Query returned #{length(docs)} documents")
            {:ok, docs}
          _ ->
            {:error, :invalid_response}
        end
      {:ok, %{status_code: status}} ->
        Logger.error("[CouchDB] ❌ Query failed with status #{status}")
        {:error, {:http_error, status}}
      {:error, reason} ->
        Logger.error("[CouchDB] ❌ Query failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Create an index for queries
  """
  def create_index(database, index_def) do
    url = "#{base_url()}/#{database}/_index"
    body = Jason.encode!(index_def)

    case HTTPoison.post(url, body, headers()) do
      {:ok, %{status_code: 200}} ->
        Logger.info("[CouchDB] ✅ Index created")
        :ok
      {:error, reason} ->
        Logger.error("[CouchDB] ❌ Index creation failed: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
