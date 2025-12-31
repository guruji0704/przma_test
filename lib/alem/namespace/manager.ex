defmodule Alem.Namespace.Manager do
  @moduledoc """
  Namespace Manager - Coordinates all services for a user
  """

  use GenServer
  require Logger

  alias Alem.Namespace.DataRouter

  defstruct [
    :user_id,
    :config,
    :services,
    :started_at,
    :resource_usage,
    :health_status
  ]

  # Client API

  def start(user_id, opts \\ []) do
    config = build_config(user_id, opts)

    child_spec = %{
      id: {:namespace_manager, user_id},
      start: {__MODULE__, :start_link, [user_id, config]},
      restart: :transient
    }

    case Horde.DynamicSupervisor.start_child(Alem.Namespace.DynamicSupervisor, child_spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      error -> error
    end
  end

  def start_link(user_id, config) do
    GenServer.start_link(__MODULE__, {user_id, config}, name: via(user_id))
  end

  def stop(user_id) do
    case whereis(user_id) do
      nil -> {:error, :not_found}
      pid -> GenServer.stop(pid, :normal)
    end
  end

  def exists?(user_id) do
    whereis(user_id) != nil
  end

  def whereis(user_id) do
    case Horde.Registry.lookup(Alem.Namespace.HordeRegistry, {:manager, user_id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  def status(user_id) do
    case whereis(user_id) do
      nil -> {:error, :not_found}
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
  def init({user_id, config}) do
    Logger.info("[Namespace:#{user_id}] Starting namespace manager")

    state = %__MODULE__{
      user_id: user_id,
      config: config,
      services: %{},
      started_at: DateTime.utc_now(),
      resource_usage: %{
        documents: 0,
        storage_bytes: 0
      },
      health_status: :starting
    }

    send(self(), :initialize)
    {:ok, state}
  end

  @impl true
  def handle_info(:initialize, state) do
    Logger.info("[Namespace:#{state.user_id}] Initializing services")

    services = start_core_services(state.user_id, state.config)
    schedule_health_check()

    new_state = %{state |
      services: services,
      health_status: :healthy
    }

    Logger.info("[Namespace:#{state.user_id}] Initialization complete")
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:health_check, state) do
    new_state = perform_health_check(state)
    schedule_health_check()
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    {service_name, _} = Enum.find(state.services, fn {_, {p, _}} -> p == pid end) || {nil, nil}

    if service_name do
      Logger.warning("[Namespace:#{state.user_id}] Service #{service_name} died: #{inspect(reason)}")
      new_services = restart_service(state.user_id, service_name, state.services, state.config)
      {:noreply, %{state | services: new_services}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      user_id: state.user_id,
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
    {:reply, :ok, %{state | config: merged_config}}
  end

  @impl true
  def handle_call(:resource_usage, _from, state) do
    {:reply, {:ok, state.resource_usage}, %{state | resource_usage: state.resource_usage}}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("[Namespace:#{state.user_id}] Shutting down: #{inspect(reason)}")

    Enum.each(state.services, fn {name, {pid, _ref}} ->
      Logger.debug("[Namespace:#{state.user_id}] Stopping #{name}")
      if Process.alive?(pid), do: GenServer.stop(pid, :shutdown)
    end)

    :ok
  end

  # Private Functions

  defp build_config(user_id, opts) do
    defaults = %{
      storage: %{
        s3_bucket: "alem-data",
        s3_prefix: "namespaces/#{user_id}/",
        database: "alem_#{user_id}"
      },
      limits: %{
        max_documents: 10_000,
        max_storage_gb: 10
      }
    }

    deep_merge(defaults, Enum.into(opts, %{}))
  end

  defp start_core_services(user_id, config) do
    services = %{}

    services = case DataRouter.start(user_id, config) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        Map.put(services, :data_router, {pid, ref})
      _ ->
        services
    end

    services
  end

  defp restart_service(user_id, service_name, services, config) do
    Logger.info("[Namespace:#{user_id}] Restarting service: #{service_name}")

    result = case service_name do
      :data_router -> DataRouter.start(user_id, config)
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
