defmodule Alem.Lance.DISSupervisor do
  @moduledoc "DynamicSupervisor — one LanceWriter per active user DID."
  use DynamicSupervisor

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def ensure_writer(user_did) do
    spec = {Alem.Lance.LanceWriter, [user_did: user_did]}
    case DynamicSupervisor.start_child(__MODULE__, spec) do
      {:ok, _pid}                        -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason}                   -> {:error, reason}
    end
  end
end
