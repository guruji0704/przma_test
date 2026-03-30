defmodule Alem.Namespace.DataRouter do
  @moduledoc """
  Per-user GenServer — routes storage operations for one namespace.
  CouchDB is REMOVED. All storage goes to PostgreSQL (via Ecto) + S3 (via CAS).

  This is a child of Namespace.Manager.
  If it crashes, Manager gets a :DOWN message and restarts it.
  Other users' DataRouters are completely unaffected.
  """

  use GenServer
  require Logger

  alias Alem.Namespace.Registry
  alias Alem.{Repo, Schemas.Document}
  alias Alem.Storage.{ObjectStore, RelationalStore}
  import Ecto.Query

  defstruct [:user_id, :tenant_id, :config, :storage_config, :stats]

  # ── Client API ─────────────────────────────────────────────────────────────

  def start(user_id, tenant_id, config) do
    name = Registry.via(user_id, :data_router)
    GenServer.start_link(__MODULE__, {user_id, tenant_id, config}, name: name)
  end

  def list_documents(user_id, opts \\ []) do
    GenServer.call(Registry.lookup!(user_id, :data_router), {:list_documents, opts}, 30_000)
  end

  def get_document(user_id, document_id) do
    GenServer.call(Registry.lookup!(user_id, :data_router), {:get_document, document_id})
  end

  def delete_document(user_id, document_id) do
    GenServer.call(Registry.lookup!(user_id, :data_router), {:delete_document, document_id})
  end

  def search(user_id, query, opts \\ []) do
    GenServer.call(Registry.lookup!(user_id, :data_router), {:search, query, opts})
  end

  def stats(user_id) do
    GenServer.call(Registry.lookup!(user_id, :data_router), :stats)
  end

  # ── GenServer ──────────────────────────────────────────────────────────────

  @impl true
  def init({user_id, tenant_id, config}) do
    Logger.info("[DataRouter:#{tenant_id}/#{user_id}] Starting")

    state = %__MODULE__{
      user_id:        user_id,
      tenant_id:      tenant_id,
      config:         config,
      storage_config: %{
        s3_bucket: Map.get(config, :s3_bucket, "perkeep"),
        s3_prefix: "user/#{tenant_id}/"
      },
      stats: %{documents_ingested: 0, bytes_stored: 0, last_sync: nil}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:list_documents, opts}, _from, state) do
    result = do_list_documents(state, opts)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:get_document, document_id}, _from, state) do
    result = do_get_document(state, document_id)
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

  # ── Private — all using PostgreSQL via Ecto ────────────────────────────────

  defp do_list_documents(state, opts) do
    limit  = Keyword.get(opts, :limit,  100)
    offset = Keyword.get(opts, :offset, 0)

    docs = Repo.all(
      from d in Document,
      where: d.tenant_id == ^state.tenant_id,
      order_by: [desc: d.inserted_at],
      limit: ^limit,
      offset: ^offset
    )

    {:ok, docs}
  end

  defp do_get_document(state, document_id) do
    case Repo.one(
      from d in Document,
      where: d.id == ^document_id and d.tenant_id == ^state.tenant_id
    ) do
      nil -> {:error, :not_found}
      doc -> {:ok, doc}
    end
  end

  defp do_delete_document(state, document_id) do
    case Repo.one(
      from d in Document,
      where: d.id == ^document_id and d.tenant_id == ^state.tenant_id
    ) do
      nil -> {:error, :not_found}
      doc ->
        case Repo.delete(doc) do
          {:ok, _}         -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp do_search(state, query, opts) do
    limit = Keyword.get(opts, :limit, 20)

    results = Repo.all(
      from d in Document,
      where: d.tenant_id == ^state.tenant_id,
      where: fragment(
        "to_tsvector('english', coalesce(?, '')) @@ plainto_tsquery('english', ?)",
        d.text_content, ^query
      ),
      limit: ^limit
    )

    {:ok, results}
  end
end
