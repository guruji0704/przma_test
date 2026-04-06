defmodule Przma.AI.Supervisor do
  @moduledoc "STUB: Supervises AI agent and memorial agent processes. TODO Phase 2."
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Supervisor.init([], strategy: :one_for_one)
  end
end
