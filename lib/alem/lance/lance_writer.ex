defmodule Alem.Lance.LanceWriter do
  @moduledoc """
  Single-writer GenServer for one user DID's LanceDB namespace.
  One per active user. Terminates after 30 minutes idle.
  Uses Rust NIF (Alem.LanceDB) directly — no HTTP server needed.
  """
  use GenServer, restart: :transient
  require Logger

  @idle_timeout_ms :timer.minutes(30)

  def start_link(opts) do
    user_did = Keyword.fetch!(opts, :user_did)
    GenServer.start_link(__MODULE__, opts, name: via(user_did))
  end

  def insert_perception(user_did, payload) do
    GenServer.call(via(user_did), {:insert_perception, payload}, 30_000)
  end

  def insert_preserve(user_did, payload) do
    GenServer.call(via(user_did), {:insert_preserve, payload}, 30_000)
  end

  def query_perception(user_did, limit \\ 10) do
    GenServer.call(via(user_did), {:query_perception, limit}, 15_000)
  end

  @impl true
  def init(opts) do
    user_did = Keyword.fetch!(opts, :user_did)
    Logger.info("[LanceWriter] Starting for #{user_did}")

    state = %{
      user_did:      user_did,
      write_count:   0,
      last_write_at: System.monotonic_time(:millisecond),
    }

    {:ok, state, @idle_timeout_ms}
  end

  @impl true
  def handle_call({:insert_perception, payload}, _from, state) do
    record = Map.merge(payload, %{
      "user_did"   => state.user_did,
      "created_at" => System.os_time(:second)
    })

    result = case Jason.encode(record) do
      {:ok, json} ->
        case Alem.LanceDB.insert_json("perception_events", json) do
          :ok    -> {:ok, %{"rows" => 1, "status" => "ok"}}
          :error -> {:error, "NIF insert failed"}
        end
      {:error, reason} ->
        {:error, "JSON encode failed: #{inspect(reason)}"}
    end

    {:reply, result, bump_write(state), @idle_timeout_ms}
  end

  def handle_call({:insert_preserve, payload}, _from, state) do
    record = Map.merge(payload, %{
      "user_did"   => state.user_did,
      "created_at" => System.os_time(:second)
    })

    result = case Jason.encode(record) do
      {:ok, json} ->
        case Alem.LanceDB.insert_json("preserve_events", json) do
          :ok    -> {:ok, %{"rows" => 1, "status" => "ok"}}
          :error -> {:error, "NIF insert failed"}
        end
      {:error, reason} ->
        {:error, "JSON encode failed: #{inspect(reason)}"}
    end

    {:reply, result, bump_write(state), @idle_timeout_ms}
  end

  def handle_call({:query_perception, limit}, _from, state) do
    result = case Alem.LanceDB.query("perception_events", "", limit) do
      {:ok, ipc_bytes} when byte_size(ipc_bytes) > 0 ->
        {:ok, %{"status" => "ok", "bytes" => byte_size(ipc_bytes)}}
      {:ok, _} ->
        {:ok, []}
      {:error, reason} ->
        {:error, reason}
    end

    {:reply, result, state, @idle_timeout_ms}
  end

  @impl true
  def handle_info(:timeout, state) do
    Logger.info("[LanceWriter] Idle timeout — stopping #{state.user_did}")
    {:stop, :normal, state}
  end

  # ── Private ────────────────────────────────────────────────────────────

  defp via(user_did),
    do: {:via, Registry, {Alem.Lance.Registry, user_did}}

  defp bump_write(state) do
    %{state |
      write_count:   state.write_count + 1,
      last_write_at: System.monotonic_time(:millisecond)
    }
  end
end
