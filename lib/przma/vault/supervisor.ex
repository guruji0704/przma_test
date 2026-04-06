defmodule Przma.Vault.Supervisor do
  @moduledoc """
  Supervises all vault storage infrastructure.
  """
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {Przma.Vault.SQLdPool, pool_size: pool_size()},
      {Horde.Registry,
        name:    Przma.Vault.Registry,
        keys:    :unique,
        members: :auto},
      {Horde.DynamicSupervisor,
        name:     Przma.Vault.DynamicSupervisor,
        strategy: :one_for_one,
        members:  :auto},
      Przma.Vault.S3Client,
      Przma.Vault.ProcessManager
    ]
    Supervisor.init(children, strategy: :one_for_one)
  end

  defp pool_size, do: Application.get_env(:przma, :vault)[:pool_size] || 4
end
