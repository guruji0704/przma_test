defmodule Alem.Namespace.Manager do
  @moduledoc """
  Namespace Manager - Coordinates all services for a user
  """

  use GenServer
  require Logger
  import Ecto.Query

  alias Alem.Namespace.DataRouter
  alias Alem.Repo
  alias Alem.Schemas.Namespace
  alias Alem.Storage.DocumentStore

  defstruct [
    :user_id,
    :tenant_id,
    :config,
    :services,
    :started_at,
    :resource_usage,
    :health_status
  ]

  # Client API

  def start(user_id, tenant_id, opts \\ []) do
    config = build_config(user_id, tenant_id, opts)

    # Persist to database first (create or update)
    case ensure_namespace_in_db(user_id, tenant_id, config) do
      {:ok, _namespace} ->
        child_spec = %{
          id: {:namespace_manager, user_id},
          start: {__MODULE__, :start_link, [user_id, tenant_id, config]},
          restart: :transient
        }

        case Horde.DynamicSupervisor.start_child(Alem.Namespace.DynamicSupervisor, child_spec) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          error -> error
        end

      error ->
        error
    end
  end

  # Ensure namespace exists in database
  defp ensure_namespace_in_db(user_id, tenant_id, config) do
    # Extract DID and Pleroma account ID from config
    did = get_in(config, [:did])
    pleroma_account_id = get_in(config, [:pleroma, :pleroma_account_id])
    identity_type = determine_identity_type(did, pleroma_account_id)

    # Try to find existing namespace by ID, DID, or Pleroma account ID
    namespace = find_namespace(user_id) ||
                (if did, do: find_by_did(did), else: nil) ||
                (if pleroma_account_id, do: find_by_pleroma_account(pleroma_account_id), else: nil)

    case namespace do
      nil ->
        # Create new namespace
        attrs = %{
          id: user_id,
          tenant_id: tenant_id,
          config: config,
          status: "active",
          identity_type: identity_type
        }
        attrs = if did, do: Map.put(attrs, :did, did), else: attrs
        attrs = if pleroma_account_id, do: Map.put(attrs, :pleroma_account_id, pleroma_account_id), else: attrs

        %Namespace{}
        |> Namespace.changeset(attrs)
        |> Repo.insert()

      existing ->
        # Update existing namespace
        updated_config = Map.merge(existing.config || %{}, config)
        attrs = %{config: updated_config}
        attrs = if did && existing.did != did, do: Map.put(attrs, :did, did), else: attrs
        attrs = if pleroma_account_id && existing.pleroma_account_id != pleroma_account_id,
                 do: Map.put(attrs, :pleroma_account_id, pleroma_account_id),
                 else: attrs
        attrs = if identity_type && existing.identity_type != identity_type,
                 do: Map.put(attrs, :identity_type, identity_type),
                 else: attrs

        if map_size(attrs) > 1 do  # More than just config
          existing
          |> Namespace.changeset(attrs)
          |> Repo.update()
        else
          {:ok, existing}
        end
    end
  end

  defp determine_identity_type(did, pleroma_account_id) do
    cond do
      did && pleroma_account_id -> "hybrid"
      did -> "did"
      pleroma_account_id -> "pleroma"
      true -> "pleroma"  # Default
    end
  end

  defp valid_did?(did) when is_binary(did) do
    Alem.DID.valid?(did)
  end

  defp valid_did?(_), do: false

  def start_link(user_id, tenant_id, config) do
    GenServer.start_link(__MODULE__, {user_id, tenant_id, config}, name: via(user_id))
  end

  def stop(user_id) do
    case whereis(user_id) do
      nil -> {:error, :not_found}
      pid -> GenServer.stop(pid, :normal)
    end
  end

  def exists?(user_id) do
    # Check if GenServer is running (active namespace)
    case whereis(user_id) do
      pid when is_pid(pid) -> true
      nil ->
        # Check database for persistent namespace (by ID, DID, or Pleroma account ID)
        case find_namespace(user_id) do
          nil -> false
          namespace -> namespace.status != "deleted"
        end
    end
  end

  @doc """
  Find namespace by ID, DID, or Pleroma account ID
  """
  def find_namespace(identifier) do
    cond do
      valid_did?(identifier) ->
        # Lookup by DID
        Repo.one(from n in Namespace, where: n.did == ^identifier)

      true ->
        # Try as namespace ID first
        case Repo.get(Namespace, identifier) do
          nil ->
            # Try as Pleroma account ID
            Repo.one(from n in Namespace, where: n.pleroma_account_id == ^identifier)
          namespace ->
            namespace
        end
    end
  end

  @doc """
  Find namespace by DID
  """
  def find_by_did(did) do
    Repo.one(from n in Namespace, where: n.did == ^did)
  end

  @doc """
  Find namespace by Pleroma account ID
  """
  def find_by_pleroma_account(pleroma_account_id) do
    Repo.one(from n in Namespace, where: n.pleroma_account_id == ^pleroma_account_id)
  end

  def whereis(user_id) do
    case Horde.Registry.lookup(Alem.Namespace.HordeRegistry, {:manager, user_id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  def status(user_id) do
    case whereis(user_id) do
      nil ->
        # Try to load from database (supports ID, DID, or Pleroma account ID)
        case find_namespace(user_id) do
          nil -> {:error, :not_found}
          namespace ->
            {:ok, %{
              user_id: namespace.id,
              tenant_id: namespace.tenant_id,
              did: namespace.did,
              identity_type: namespace.identity_type,
              pleroma_account_id: namespace.pleroma_account_id,
              started_at: namespace.inserted_at,
              health_status: if(namespace.status == "active", do: :inactive, else: :suspended),
              services: [],
              resource_usage: %{
                documents: namespace.document_count || 0,
                storage_bytes: namespace.storage_bytes || 0
              },
              config: namespace.config || %{},
              node: Node.self(),
              persisted: true
            }}
        end

      pid -> GenServer.call(pid, :status)
    end
  end

  def get_config(user_id) do
    GenServer.call(via(user_id), :get_config)
  end

  def update_config(user_id, config) do
    GenServer.call(via(user_id), {:update_config, config})
  end

  def resource_usage(user_id) do
    GenServer.call(via(user_id), :resource_usage)
  end

  defp via(user_id) do
    {:via, Horde.Registry, {Alem.Namespace.HordeRegistry, {:manager, user_id}}}
  end

  # GenServer Implementation

  @impl true
  def init({user_id, tenant_id, config}) do
    Logger.info("[Namespace:#{tenant_id}/#{user_id}] Starting namespace manager")

    # Load from database if exists, merge with provided config
    db_config = case Repo.get(Namespace, user_id) do
      nil ->
        # New namespace, use provided config
        config
      namespace ->
        # Merge database config with provided config (provided takes precedence)
        Map.merge(namespace.config || %{}, config)
    end

    state = %__MODULE__{
      user_id: user_id,
      tenant_id: tenant_id,
      config: db_config,
      services: %{},
      started_at: DateTime.utc_now(),
      resource_usage: %{
        documents: 0,
        storage_bytes: 0
      },
      health_status: :starting
    }

    send(self(), :initialize)
    schedule_sync_to_db()
    {:ok, state}
  end

  @impl true
  def handle_info(:initialize, state) do
    Logger.info("[Namespace:#{state.tenant_id}/#{state.user_id}] Initializing services")

    services = start_core_services(state.user_id, state.tenant_id, state.config)
    schedule_health_check()

    new_state = %{state |
      services: services,
      health_status: :healthy
    }

    # Sync to database after initialization
    sync_to_db(new_state)

    Logger.info("[Namespace:#{state.tenant_id}/#{state.user_id}] Initialization complete")
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:health_check, state) do
    new_state = perform_health_check(state)
    schedule_health_check()
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:sync_to_db, state) do
    sync_to_db(state)
    schedule_sync_to_db()
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    {service_name, _} = Enum.find(state.services, fn {_, {p, _}} -> p == pid end) || {nil, nil}

    if service_name do
      Logger.warning("[Namespace:#{state.tenant_id}/#{state.user_id}] Service #{service_name} died: #{inspect(reason)}")
      new_services = restart_service(state.user_id, state.tenant_id, service_name, state.services, state.config)
      {:noreply, %{state | services: new_services}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      user_id: state.user_id,
      tenant_id: state.tenant_id,
      started_at: state.started_at,
      health_status: state.health_status,
      services: format_services(state.services),
      resource_usage: state.resource_usage,
      config: sanitize_config(state.config),
      node: Node.self()
    }
    {:reply, {:ok, status}, state}
  end

  @impl true
  def handle_call(:get_config, _from, state) do
    {:reply, {:ok, state.config}, state}
  end

  @impl true
  def handle_call({:update_config, new_config}, _from, state) do
    merged_config = Map.merge(state.config, new_config)
    new_state = %{state | config: merged_config}

    # Persist config change to database
    case Repo.get(Namespace, state.user_id) do
      nil -> :ok
      namespace ->
        namespace
        |> Namespace.changeset(%{config: merged_config})
        |> Repo.update()
        |> case do
          {:ok, _} -> :ok
          {:error, _} -> :ok  # Don't fail on DB error, just log
        end
    end

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:resource_usage, _from, state) do
    {:reply, {:ok, state.resource_usage}, %{state | resource_usage: state.resource_usage}}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("[Namespace:#{state.tenant_id}/#{state.user_id}] Shutting down: #{inspect(reason)}")

    # Save final state to database before terminating
    sync_to_db(state)

    Enum.each(state.services, fn {name, {pid, _ref}} ->
      Logger.debug("[Namespace:#{state.tenant_id}/#{state.user_id}] Stopping #{name}")
      if Process.alive?(pid), do: GenServer.stop(pid, :shutdown)
    end)

    :ok
  end

  # Private Functions

  defp build_config(user_id, tenant_id, opts) do
    defaults = %{
      storage: %{
        s3_bucket: "perkeep",
        s3_prefix: "tenant/#{tenant_id}/#{user_id}/",
        database: DocumentStore.sanitize_database_name("alem_#{tenant_id}_#{user_id}")
      },
      limits: %{
        max_documents: 10_000,
        max_storage_gb: 10
      }
    }

    deep_merge(defaults, Enum.into(opts, %{}))
  end

  defp start_core_services(user_id, tenant_id, config) do
    services = %{}

    services = case DataRouter.start(user_id, tenant_id, config) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        Map.put(services, :data_router, {pid, ref})
      _ ->
        services
    end

    services
  end

  defp restart_service(user_id, tenant_id, service_name, services, config) do
    Logger.info("[Namespace:#{tenant_id}/#{user_id}] Restarting service: #{service_name}")

    result = case service_name do
      :data_router -> DataRouter.start(user_id, tenant_id, config)
      _ -> {:error, :unknown_service}
    end

    case result do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        Map.put(services, service_name, {pid, ref})
      _ ->
        Map.delete(services, service_name)
    end
  end

  defp perform_health_check(state) do
    service_health = Enum.map(state.services, fn {name, {pid, _ref}} ->
      {name, if(Process.alive?(pid), do: :healthy, else: :dead)}
    end)

    all_healthy = Enum.all?(service_health, fn {_, status} -> status == :healthy end)
    health_status = if all_healthy, do: :healthy, else: :degraded

    %{state | health_status: health_status}
  end

  defp schedule_health_check do
    Process.send_after(self(), :health_check, 30_000)
  end

  defp schedule_sync_to_db do
    # Sync to database every 60 seconds
    Process.send_after(self(), :sync_to_db, 60_000)
  end

  # Sync GenServer state to database
  defp sync_to_db(state) do
    case Repo.get(Namespace, state.user_id) do
      nil ->
        # Shouldn't happen, but create if missing
        %Namespace{}
        |> Namespace.changeset(%{
          id: state.user_id,
          tenant_id: state.tenant_id,
          config: state.config,
          status: "active",
          document_count: state.resource_usage.documents,
          storage_bytes: state.resource_usage.storage_bytes,
          last_activity_at: DateTime.utc_now()
        })
        |> Repo.insert()
        |> case do
          {:ok, _} -> :ok
          {:error, _} -> :ok  # Don't fail on error
        end

      namespace ->
        # Update existing namespace
        namespace
        |> Namespace.changeset(%{
          config: state.config,
          document_count: state.resource_usage.documents,
          storage_bytes: state.resource_usage.storage_bytes,
          last_activity_at: DateTime.utc_now()
        })
        |> Repo.update()
        |> case do
          {:ok, _} -> :ok
          {:error, _} -> :ok  # Don't fail on error
        end
    end
  end

  defp format_services(services) do
    Enum.map(services, fn {name, {pid, _ref}} ->
      %{
        name: name,
        pid: inspect(pid),
        alive: Process.alive?(pid),
        node: node(pid)
      }
    end)
  end

  defp sanitize_config(config) do
    config
    |> Map.delete(:secrets)
    |> Map.delete(:api_keys)
  end

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _k, v1, v2 ->
      if is_map(v1) and is_map(v2), do: deep_merge(v1, v2), else: v2
    end)
  end
end
