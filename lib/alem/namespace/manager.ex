defmodule Alem.Namespace.Manager do
  @moduledoc """
  Per-user GenServer — manages lifecycle, health, and stats for one namespace.
  Supervised by Horde: if this crashes, Horde restarts it on the same or
  another node. Other users' managers are completely unaffected.

  This does NOT handle document operations — those go through Alem.Namespace.
  This manages: startup, health monitoring, stats syncing to DB.
  """

  use GenServer
  require Logger
  import Ecto.Query

  alias Alem.Namespace.DataRouter
  alias Alem.Repo
  alias Alem.Schemas.Namespace
  alias Alem.DID

  defstruct [
    :user_id,
    :tenant_id,
    :config,
    :services,
    :started_at,
    :resource_usage,
    :health_status
  ]

  # ── Client API ─────────────────────────────────────────────────────────────

  def start(user_id, tenant_id, opts \\ []) do
    config = build_config(user_id, tenant_id, opts)

    case ensure_namespace_in_db(user_id, tenant_id, config) do
      {:ok, _namespace} ->
        child_spec = %{
          # id:      {:namespace_manager, user_id},
          start:   {__MODULE__, :start_link, [user_id, tenant_id, config]},
          restart: :transient
        }

        case Horde.DynamicSupervisor.start_child(Alem.Namespace.DynamicSupervisor, child_spec) do
          {:ok, pid}                       -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          error                             -> error
        end

      error -> error
    end
  end

  def start_link(user_id, tenant_id, config) do
    GenServer.start_link(__MODULE__, {user_id, tenant_id, config}, name: via(user_id))
  end

  def stop(user_id) do
    case whereis(user_id) do
      nil -> {:error, :not_found}
      pid ->
        try do
          GenServer.stop(pid, :normal)
          :ok
        catch
          :exit, _ -> :ok
        end
    end
  end

  def exists?(user_id) do
    case whereis(user_id) do
      pid when is_pid(pid) -> true
      nil ->
        case find_namespace(user_id) do
          nil       -> false
          namespace -> namespace.status != "deleted"
        end
    end
  end

  def status(user_id) do
    case whereis(user_id) do
      nil ->
        case find_namespace(user_id) do
          nil -> {:error, :not_found}
          ns  ->
            {:ok, %{
              user_id:            ns.id,
              tenant_id:          ns.tenant_id,
              did:                ns.did,
              identity_type:      ns.identity_type,
              pleroma_account_id: ns.pleroma_account_id,
              started_at:         ns.inserted_at,
              health_status:      :persisted_offline,
              services:           [],
              resource_usage: %{
                documents:     ns.document_count     || 0,
                storage_bytes: ns.storage_bytes || 0
              },
              config:    ns.config || %{},
              node:      Node.self(),
              persisted: true
            }}
        end

      pid -> GenServer.call(pid, :status)
    end
  end

  def get_config(user_id),          do: GenServer.call(via(user_id), :get_config)
  def update_config(user_id, cfg),  do: GenServer.call(via(user_id), {:update_config, cfg})
  def resource_usage(user_id),      do: GenServer.call(via(user_id), :resource_usage)

  def whereis(user_id) do
    case Horde.Registry.lookup(Alem.Namespace.HordeRegistry, {:manager, user_id}) do
      [{pid, _}] -> pid
      []         -> nil
    end
  end

  # Find namespace by namespace_key, DID, or Pleroma account ID
  def find_namespace(identifier) do
    cond do
      DID.valid?(identifier) ->
        Repo.one(from n in Namespace, where: n.did == ^identifier)

      true ->
        case Repo.get(Namespace, identifier) do
          nil -> Repo.one(from n in Namespace, where: n.pleroma_account_id == ^identifier)
          ns  -> ns
        end
    end
  end

  def find_by_did(did),
    do: Repo.one(from n in Namespace, where: n.did == ^did)

  def find_by_pleroma_account(pleroma_account_id),
    do: Repo.one(from n in Namespace, where: n.pleroma_account_id == ^pleroma_account_id)

  # ── GenServer callbacks ────────────────────────────────────────────────────

  @impl true
  def init({user_id, tenant_id, config}) do
    Logger.info("[Manager:#{tenant_id}/#{user_id}] Starting")

    db_config = case Repo.get(Namespace, user_id) do
      nil -> config
      ns  ->
        db_cfg = atomize_keys(ns.config || %{})
        Map.merge(db_cfg, config)
    end

    state = %__MODULE__{
      user_id:        user_id,
      tenant_id:      tenant_id,
      config:         db_config,
      services:       %{},
      started_at:     DateTime.utc_now(),
      resource_usage: %{documents: 0, storage_bytes: 0},
      health_status:  :starting
    }

    send(self(), :initialize)
    schedule_sync_to_db()
    {:ok, state}
  end

  @impl true
  def handle_info(:initialize, state) do
    services = start_core_services(state.user_id, state.tenant_id, state.config)
    schedule_health_check()

    new_state = %{state | services: services, health_status: :healthy}
    sync_to_db(new_state)

    Logger.info("[Manager:#{state.tenant_id}/#{state.user_id}] Ready")
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
      Logger.warning("[Manager:#{state.user_id}] Service #{service_name} died: #{inspect(reason)}")
      new_services = restart_service(state.user_id, state.tenant_id, service_name, state.services, state.config)
      {:noreply, %{state | services: new_services}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, {:ok, %{
      user_id:        state.user_id,
      tenant_id:      state.tenant_id,
      started_at:     state.started_at,
      health_status:  state.health_status,
      services:       format_services(state.services),
      resource_usage: state.resource_usage,
      config:         Map.drop(state.config, [:secrets, :api_keys]),
      node:           Node.self()
    }}, state}
  end

  @impl true
  def handle_call(:get_config, _from, state),
    do: {:reply, {:ok, state.config}, state}

  @impl true
  def handle_call({:update_config, new_config}, _from, state) do
    merged = Map.merge(state.config, new_config)
    new_state = %{state | config: merged}

    case Repo.get(Namespace, state.user_id) do
      nil -> :ok
      ns  ->
        ns |> Namespace.changeset(%{config: merged}) |> Repo.update()
    end

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:resource_usage, _from, state),
    do: {:reply, {:ok, state.resource_usage}, state}

  @impl true
  def terminate(reason, state) do
    Logger.info("[Manager:#{state.user_id}] Shutting down: #{inspect(reason)}")
    sync_to_db(state)

    Enum.each(state.services, fn {_name, {pid, _ref}} ->
      if Process.alive?(pid), do: GenServer.stop(pid, :shutdown)
    end)

    :ok
  end

  # ── Private ────────────────────────────────────────────────────────────────

  defp via(user_id) do
    {:via, Horde.Registry, {Alem.Namespace.HordeRegistry, {:manager, user_id}}}
  end

  defp build_config(user_id, tenant_id, opts) do
    defaults = %{
      storage: %{
        s3_bucket:  "perkeep",
        s3_prefix:  "user/#{tenant_id}/",
      },
      limits: %{
        max_documents:   10_000,
        max_storage_gb:  10
      }
    }
    deep_merge(defaults, Enum.into(opts, %{}))
  end

  defp ensure_namespace_in_db(user_id, tenant_id, config) do
    did                = get_in(config, [:did])
    pleroma_account_id = get_in(config, [:pleroma, :pleroma_account_id])
    identity_type      = determine_identity_type(did, pleroma_account_id)

    namespace =
      find_namespace(user_id)
      || (if did, do: find_by_did(did))
      || (if pleroma_account_id, do: find_by_pleroma_account(pleroma_account_id))

    case namespace do
      nil ->
        attrs =
          %{id: user_id, tenant_id: tenant_id, config: config,
            status: "active", identity_type: identity_type}
          |> maybe_put(:did, did)
          |> maybe_put(:pleroma_account_id, pleroma_account_id)

        %Namespace{} |> Namespace.changeset(attrs) |> Repo.insert()

      existing ->
        merged = Map.merge(existing.config || %{}, config)
        attrs  = %{config: merged}
          |> maybe_put(:did, if(did && existing.did != did, do: did))
          |> maybe_put(:pleroma_account_id,
              if(pleroma_account_id && existing.pleroma_account_id != pleroma_account_id,
                do: pleroma_account_id))

        if map_size(attrs) > 1 do
          existing |> Namespace.changeset(attrs) |> Repo.update()
        else
          {:ok, existing}
        end
    end
  end

  defp maybe_put(map, _key, nil),   do: map
  defp maybe_put(map, key, value),  do: Map.put(map, key, value)

  defp determine_identity_type(did, pleroma_account_id) do
    cond do
      did && pleroma_account_id -> "hybrid"
      did                       -> "did"
      pleroma_account_id        -> "pleroma"
      true                      -> "did"
    end
  end

  defp start_core_services(user_id, tenant_id, config) do
    case DataRouter.start(user_id, tenant_id, config) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        %{data_router: {pid, ref}}
      _ ->
        %{}
    end
  end

  defp restart_service(user_id, tenant_id, service_name, services, config) do
    result = case service_name do
      :data_router -> DataRouter.start(user_id, tenant_id, config)
      _            -> {:error, :unknown_service}
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
    all_healthy =
      Enum.all?(state.services, fn {_, {pid, _}} -> Process.alive?(pid) end)

    %{state | health_status: if(all_healthy, do: :healthy, else: :degraded)}
  end

  defp schedule_health_check,  do: Process.send_after(self(), :health_check, 30_000)
  defp schedule_sync_to_db,    do: Process.send_after(self(), :sync_to_db,   60_000)

  defp sync_to_db(state) do
    attrs = %{
      config:          state.config,
      document_count:  state.resource_usage.documents,
      storage_bytes:   state.resource_usage.storage_bytes,
      last_activity_at: DateTime.utc_now()
    }

    case Repo.get(Namespace, state.user_id) do
      nil ->
        %Namespace{}
        |> Namespace.changeset(Map.merge(attrs, %{
          id: state.user_id, tenant_id: state.tenant_id, status: "active"
        }))
        |> Repo.insert()

      namespace ->
        namespace |> Namespace.changeset(attrs) |> Repo.update()
    end
    |> case do
      {:ok, _}    -> :ok
      {:error, _} -> :ok
    end
  end

  defp format_services(services) do
    Enum.map(services, fn {name, {pid, _ref}} ->
      %{name: name, pid: inspect(pid), alive: Process.alive?(pid), node: node(pid)}
    end)
  end

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _k, v1, v2 ->
      if is_map(v1) and is_map(v2), do: deep_merge(v1, v2), else: v2
    end)
  end

    defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) ->
        try do
          {String.to_existing_atom(k), atomize_keys(v)}
        rescue
          ArgumentError -> {k, atomize_keys(v)}
        end
      {k, v} -> {k, atomize_keys(v)}
    end)
  end
  defp atomize_keys(v), do: v

end
