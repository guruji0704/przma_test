defmodule Alem.Storage.RelationalStore do
  @moduledoc """
  PostgreSQL Relational Storage Integration
  """

  require Logger
  import Ecto.Query
  alias Alem.Repo
  alias Alem.Schemas.Document

  @doc """
  Insert a document record
  """
  def insert(:documents, attrs) do
    Logger.info("[PostgreSQL] Inserting document #{attrs[:id]} for tenant:#{attrs[:tenant_id]}")

    changeset = Document.changeset(%Document{}, attrs)

    case Repo.insert(changeset) do
      {:ok, document} ->
        Logger.info("[PostgreSQL] ✅ Document inserted: #{document.id}")
        {:ok, document}
      {:error, changeset} ->
        Logger.error("[PostgreSQL] ❌ Insert failed: #{inspect(changeset.errors)}")
        {:error, changeset}
    end
  end

  @doc """
  Get a document by ID
  """
  def get(:documents, id) do
    Logger.info("[PostgreSQL] Fetching document #{id}")

    case Repo.get(Document, id) do
      nil ->
        Logger.warning("[PostgreSQL] Document not found: #{id}")
        {:error, :not_found}
      document ->
        Logger.info("[PostgreSQL] ✅ Document retrieved")
        {:ok, document}
    end
  end

  @doc """
  Update a document
  """
  def update(:documents, id, attrs) do
    Logger.info("[PostgreSQL] Updating document #{id}")

    case Repo.get(Document, id) do
      nil ->
        {:error, :not_found}
      document ->
        changeset = Document.changeset(document, attrs)
        case Repo.update(changeset) do
          {:ok, updated} ->
            Logger.info("[PostgreSQL] ✅ Document updated")
            {:ok, updated}
          {:error, changeset} ->
            Logger.error("[PostgreSQL] ❌ Update failed: #{inspect(changeset.errors)}")
            {:error, changeset}
        end
    end
  end

  @doc """
  Delete a document
  """
  def delete(:documents, id) do
    Logger.info("[PostgreSQL] Deleting document #{id}")

    case Repo.get(Document, id) do
      nil ->
        {:error, :not_found}
      document ->
        case Repo.delete(document) do
          {:ok, _} ->
            Logger.info("[PostgreSQL] ✅ Document deleted")
            :ok
          {:error, changeset} ->
            Logger.error("[PostgreSQL] ❌ Delete failed: #{inspect(changeset.errors)}")
            {:error, changeset}
        end
    end
  end

  @doc """
  List documents with filters
  """
  def list(:documents, filters \\ %{}) do
    Logger.info("[PostgreSQL] Listing documents for tenant:#{filters[:tenant_id]}")

    query = from d in Document

    query = if tenant_id = filters[:tenant_id] do
      where(query, [d], d.tenant_id == ^tenant_id)
    else
      query
    end

    query = if user_id = filters[:user_id] do
      where(query, [d], d.user_id == ^user_id)
    else
      query
    end

    query = if limit = filters[:limit] do
      limit(query, ^limit)
    else
      query
    end

    query = if offset = filters[:offset] do
      offset(query, ^offset)
    else
      query
    end

    documents = Repo.all(query)
    Logger.info("[PostgreSQL] ✅ Found #{length(documents)} documents")
    {:ok, documents}
  end

  @doc """
  Full-text search
  """
  def search(:documents, search_query, filters \\ %{}) do
    Logger.info("[PostgreSQL] Searching: #{search_query} in tenant:#{filters[:tenant_id]}")

    query = from d in Document,
      where: fragment("? @@ plainto_tsquery(?)", d.text_content, ^search_query),
      order_by: [desc: fragment("ts_rank(to_tsvector(?), plainto_tsquery(?))", d.text_content, ^search_query)]

    query = if tenant_id = filters[:tenant_id] do
      where(query, [d], d.tenant_id == ^tenant_id)
    else
      query
    end

    query = if user_id = filters[:user_id] do
      where(query, [d], d.user_id == ^user_id)
    else
      query
    end

    query = if limit = filters[:limit] do
      limit(query, ^limit)
    else
      limit(query, 20)
    end

    results = Repo.all(query)
    Logger.info("[PostgreSQL] ✅ Search returned #{length(results)} results")
    {:ok, results}
  end
end
