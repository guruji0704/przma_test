defmodule Alem.Namespace do
  @moduledoc """
  User Namespace Management System

  Provides isolated data coordination for each user with:
  - Distributed process management via Horde
  - Service registration and discovery
  - Document storage and retrieval
  - Resource tracking and health monitoring
  """

  alias Alem.Namespace.{Manager, Registry, DataRouter}

  @type user_id :: String.t()

  # Public API

  @doc "Start a namespace for a user"
  def start(user_id, tenant_id, opts \\ []) do
    Manager.start(user_id, tenant_id, opts)
  end

  @doc "Stop a user's namespace"
  def stop(user_id) do
    Manager.stop(user_id)
  end

  @doc "Check if a namespace exists"
  def exists?(user_id) do
    Manager.exists?(user_id)
  end

  @doc "Get namespace status"
  def status(user_id) do
    Manager.status(user_id)
  end

  @doc "Ensure namespace is started (idempotent)"
  def ensure_started(user_id, tenant_id, opts \\ []) do
    if exists?(user_id) do
      {:ok, Manager.whereis(user_id)}
    else
      start(user_id, tenant_id, opts)
    end
  end

  # Data Operations

  @doc "Ingest a document into the namespace"
  def ingest_document(user_id, tenant_id, document) do
    ensure_started(user_id, tenant_id)
    DataRouter.ingest(user_id, document)
  end

  @doc "List documents in the namespace"
  def list_documents(user_id, opts \\ []) do
    DataRouter.list_documents(user_id, opts)
  end

  @doc "Get a specific document"
  def get_document(user_id, document_id) do
    DataRouter.get_document(user_id, document_id)
  end

  @doc "Delete a document"
  def delete_document(user_id, document_id) do
    DataRouter.delete_document(user_id, document_id)
  end

  @doc "Sync from external source"
  def sync(user_id, source, opts \\ []) do
    DataRouter.sync(user_id, source, opts)
  end

  # Service Registry

  @doc "Register a service in the namespace"
  def register_service(user_id, service_name, pid \\ self()) do
    Registry.register(user_id, service_name, pid)
  end

  @doc "Lookup a service"
  def lookup_service(user_id, service_name) do
    Registry.lookup(user_id, service_name)
  end

  @doc "List all services"
  def list_services(user_id) do
    Registry.list(user_id)
  end

  # Configuration

  @doc "Get namespace configuration"
  def get_config(user_id) do
    Manager.get_config(user_id)
  end

  @doc "Update namespace configuration"
  def update_config(user_id, config) do
    Manager.update_config(user_id, config)
  end

  @doc "Get resource usage"
  def resource_usage(user_id) do
    Manager.resource_usage(user_id)
  end
end
