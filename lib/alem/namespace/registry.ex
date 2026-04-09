defmodule Alem.Namespace.Registry do
  @moduledoc """
  Distributed Service Registry using Horde
  """

  require Logger

  @registry Alem.Namespace.HordeRegistry

  # Registration

  def register(user_id, service_name, pid \\ self(), metadata \\ %{}) do
    key = make_key(user_id, service_name)

    case Horde.Registry.register(@registry, key, metadata) do
      {:ok, _} ->
        Logger.debug("[Registry] Registered #{inspect(key)} -> #{inspect(pid)}")
        :ok
      {:error, {:already_registered, _}} ->
        {:error, :already_registered}
    end
  end

  def unregister(user_id, service_name) do
    key = make_key(user_id, service_name)
    Horde.Registry.unregister(@registry, key)
  end

  # Lookup

  def lookup(user_id, service_name) do
    key = make_key(user_id, service_name)

    case Horde.Registry.lookup(@registry, key) do
      [{pid, _metadata}] -> {:ok, pid}
      [] -> :error
    end
  end

  def lookup!(user_id, service_name) do
    case lookup(user_id, service_name) do
      {:ok, pid} -> pid
      :error -> raise "Service not found: #{user_id}/#{service_name}"
    end
  end

  def registered?(user_id, service_name) do
    lookup(user_id, service_name) != :error
  end

  # Listing - simplified to avoid complex Horde.Registry.select patterns

  def list(user_id) do
    known_services = [:data_router, :agent_coordinator, :pipeline_manager]

    Enum.reduce(known_services, [], fn service_name, acc ->
      case lookup(user_id, service_name) do
        {:ok, pid} ->
          [%{
            service: service_name,
            pid: pid,
            metadata: %{},
            node: node(pid),
            alive: Process.alive?(pid)
          } | acc]
        :error ->
          acc
      end
    end)
  end

  def list_namespaces do
    []
  end

  # Via tuple - FIXED: Remove metadata parameter, Horde doesn't support it in name tuple
  def via(user_id, service_name) do
    {:via, Horde.Registry, {@registry, make_key(user_id, service_name)}}
  end

  def make_key(user_id, service_name) do
    {:user, user_id, service_name}
  end

  # Stats

  def stats do
    %{
      total_registrations: count_registrations(),
      namespaces: 0
    }
  end

  defp count_registrations do
    try do
      case Horde.Registry.count(@registry) do
        count when is_integer(count) -> count
        _ -> 0
      end
    rescue
      _ -> 0
    end
  end
end
