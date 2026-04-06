defmodule Przma.Identity.Supervisor do
  @moduledoc "Supervises DID registry, JWT verifier, key management."
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      Przma.Identity.DIDRegistry
    ]
    Supervisor.init(children, strategy: :one_for_one)
  end
end
