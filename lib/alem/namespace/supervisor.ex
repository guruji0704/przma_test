defmodule Alem.Namespace.Supervisor do
  @moduledoc """
  Namespace Supervisor - Distributed Process Supervision
  =======================================================

  This supervisor manages all namespace-related processes using Horde
  for distributed supervision and automatic failover.

  ## Supervision Tree

  ```
  Alem.Namespace.Supervisor (Horde.DynamicSupervisor)
      │
      ├── Namespace Manager (user_1)
      │       ├── Data Router
      │       ├── Agent Coordinator
      │       │       ├── Ingestion Agent
      │       │       ├── Embedding Agent
      │       │       ├── Query Agent
      │       │       └── Knowledge Graph Agent
      │       └── Pipeline Manager
      │
      ├── Namespace Manager (user_2)
      │       └── ...
      │
      └── Namespace Manager (user_N)
              └── ...
  ```

  ## Distribution

  Horde automatically distributes namespace managers across cluster nodes:

  - Processes are evenly distributed
  - When a node dies, processes restart on surviving nodes
  - New nodes receive processes via redistribution
  """

  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      # Horde Registry for namespace service discovery
      {Horde.Registry, [
        name: Alem.Namespace.HordeRegistry,
        keys: :unique,
        members: :auto
      ]},

      # Horde DynamicSupervisor for namespace managers
      {Horde.DynamicSupervisor, [
        name: Alem.Namespace.Supervisor,
        strategy: :one_for_one,
        members: :auto,
        distribution_strategy: Horde.UniformDistribution
      ]}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  @doc """
  Start a namespace under this supervisor.
  """
  def start_namespace(user_id, opts \\ []) do
    Alem.Namespace.Manager.start(user_id, opts)
  end

  @doc """
  Stop a namespace.
  """
  def stop_namespace(user_id) do
    Alem.Namespace.Manager.stop(user_id)
  end

  @doc """
  List all running namespaces.
  """
  def list_namespaces do
    Alem.Namespace.Registry.list_namespaces()
  end

  @doc """
  Get statistics about namespace distribution.
  """
  def distribution_stats do
    namespaces = list_namespaces()

    by_node = Enum.group_by(namespaces, fn ns -> ns.node end)

    %{
      total_namespaces: length(namespaces),
      nodes: length(Map.keys(by_node)),
      distribution: Enum.map(by_node, fn {node, nss} -> {node, length(nss)} end) |> Enum.into(%{})
    }
  end
end
