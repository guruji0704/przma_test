defmodule Alem.Lance.Supervisor do
  @moduledoc "Root supervisor for the LanceDB write subsystem."
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: Alem.Lance.Registry},
      Alem.Lance.DISSupervisor,
    ]
    Supervisor.init(children, strategy: :rest_for_one)
  end
end
