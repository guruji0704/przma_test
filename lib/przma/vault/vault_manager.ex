defmodule Przma.Vault.VaultManager do
  @moduledoc """
  Per-user vault GenServer.

  One VaultManager runs per active user. It holds the user's
  decrypted vault key in memory for the lifetime of the process.
  When the user is idle, the process hibernates (key cleared).
  After extended idle, the process terminates.

  Never persists the vault key to disk. On restart, the user
  must re-authenticate to restore the key.
  """
  use GenServer, restart: :transient

  require Logger

  @hot_threshold_ms  Application.compile_env(:przma, [:vault, :hot_threshold_ms],  300_000)
  @warm_threshold_ms Application.compile_env(:przma, [:vault, :warm_threshold_ms], 1_800_000)

  defstruct [
    :did,
    :vault_key,
    :db_connection,
    :last_active,
    :device_count
  ]

  # ── PUBLIC API ────────────────────────────────────────────────────────────

  def get_or_start(did) do
    case Horde.Registry.lookup(Przma.Vault.Registry, did) do
      [{pid, _}] -> {:ok, pid}
      []         ->
        Horde.DynamicSupervisor.start_child(
          Przma.Vault.DynamicSupervisor,
          {__MODULE__, did: did}
        )
    end
  end

  def execute(did, sql, params) do
    with {:ok, pid} <- get_or_start(did) do
      GenServer.call(pid, {:execute, sql, params}, 10_000)
    end
  end

  def query(did, sql, params) do
    with {:ok, pid} <- get_or_start(did) do
      GenServer.call(pid, {:query, sql, params}, 10_000)
    end
  end

  def get_vault_key(did) do
    with {:ok, pid} <- get_or_start(did) do
      GenServer.call(pid, :get_vault_key, 5_000)
    end
  end

  # ── GENSERVER CALLBACKS ───────────────────────────────────────────────────

  def start_link(opts) do
    did = Keyword.fetch!(opts, :did)
    GenServer.start_link(__MODULE__,
      did,
      name: {:via, Horde.Registry, {Przma.Vault.Registry, did}}
    )
  end

  @impl true
  def init(did) do
    with {:ok, vault_key} <- Przma.Identity.VaultKeyring.derive_vault_key(did),
         {:ok, conn}      <- Przma.Vault.SQLdPool.checkout(did) do

      Process.send_after(self(), :check_idle, @hot_threshold_ms)

      {:ok, %__MODULE__{
        did:           did,
        vault_key:     vault_key,
        db_connection: conn,
        last_active:   now(),
        device_count:  0
      }}
    else
      {:error, reason} ->
        Logger.error("[VaultManager] Failed to init #{did}: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:execute, sql, params}, _from, state) do
    result = Przma.Vault.SQLdPool.execute(state.db_connection, sql, params)
    {:reply, result, touch(state)}
  end

  @impl true
  def handle_call({:query, sql, params}, _from, state) do
    result = Przma.Vault.SQLdPool.query(state.db_connection, sql, params)
    {:reply, result, touch(state)}
  end

  @impl true
  def handle_call(:get_vault_key, _from, %{vault_key: nil} = state) do
    case Przma.Identity.VaultKeyring.derive_vault_key(state.did) do
      {:ok, key} -> {:reply, {:ok, key}, %{state | vault_key: key}}
      err        -> {:reply, err, state}
    end
  end

  def handle_call(:get_vault_key, _from, state) do
    {:reply, {:ok, state.vault_key}, touch(state)}
  end

  @impl true
  def handle_info(:hibernate, state) do
    Logger.debug("[VaultManager] Hibernating #{state.did}")
    Process.send_after(self(), :check_idle, @warm_threshold_ms)
    {:noreply, %{state | vault_key: nil}, :hibernate}
  end

  @impl true
  def handle_info(:check_idle, state) do
    idle_ms = now() - state.last_active

    cond do
      idle_ms > @warm_threshold_ms and state.device_count == 0 ->
        Logger.debug("[VaultManager] Terminating idle #{state.did}")
        {:stop, :normal, state}

      idle_ms > @hot_threshold_ms and state.device_count == 0 ->
        send(self(), :hibernate)
        {:noreply, state}

      true ->
        Process.send_after(self(), :check_idle, @hot_threshold_ms)
        {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    if state.vault_key, do: :crypto.strong_rand_bytes(byte_size(state.vault_key))
    if state.db_connection, do: Przma.Vault.SQLdPool.checkin(state.db_connection)
    :ok
  end

  defp touch(state), do: %{state | last_active: now()}
  defp now, do: System.monotonic_time(:millisecond)
end
