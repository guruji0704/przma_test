defmodule Przma.Vault.ProcessManager do
  @moduledoc """
  STUB: Evicts idle VaultManagers (hot/warm/cold lifecycle).
  TODO Phase 2: Implement periodic sweep using Process.list/0
  and Horde.Registry to find and terminate idle managers.
  """
  use GenServer

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_), do: {:ok, %{}}
end
