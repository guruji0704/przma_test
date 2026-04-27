defmodule Alem.Lance.LanceWriter do
  @moduledoc """
  Single-writer GenServer for one user DID's LanceDB namespace.
  One per active user. Terminates after 30 minutes idle.
  Uses the HTTP client (not NIF) at this stage.
  """
  use GenServer, restart: :transient
  require Logger

  alias Alem.Lance.{Config, Table, Query}

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

    cfg = Config.new() |> Config.for_user(user_did)

    state = %{
      user_did:      user_did,
      cfg:           cfg,
      write_count:   0,
      last_write_at: System.monotonic_time(:millisecond),
    }

    {:ok, state, @idle_timeout_ms}
  end

  @impl true
  def handle_call({:insert_perception, payload}, _from, state) do
    # Ensure table exists
    ensure_perception_table(state.cfg)

    record = Map.merge(payload, %{
      "user_did"   => state.user_did,
      "created_at" => System.os_time(:second)
    })

    result = Table.insert(state.cfg, "perception_events", [record])
    {:reply, result, bump_write(state), @idle_timeout_ms}
  end

  def handle_call({:insert_preserve, payload}, _from, state) do
    ensure_preserve_table(state.cfg)
    record = Map.merge(payload, %{
      "user_did"   => state.user_did,
      "created_at" => System.os_time(:second)
    })
    result = Table.insert(state.cfg, "preserve_events", [record])
    {:reply, result, bump_write(state), @idle_timeout_ms}
  end

  def handle_call({:query_perception, limit}, _from, state) do
    q = Query.new() |> Query.limit(limit)
    result = Table.search(state.cfg, "perception_events", q)
    {:reply, result, state, @idle_timeout_ms}
  end

  @impl true
  def handle_info(:timeout, state) do
    Logger.info("[LanceWriter] Idle timeout — stopping #{state.user_did}")
    {:stop, :normal, state}
  end

  # ── Private ───────────────────────────────────────────────────────────

  defp via(user_did), do: {:via, Registry, {Alem.Lance.Registry, user_did}}

  defp bump_write(state) do
    %{state | write_count: state.write_count + 1,
              last_write_at: System.monotonic_time(:millisecond)}
  end

  defp ensure_perception_table(cfg) do
    schema = %{fields: [
      %{name: "id",              type: "utf8"},
      %{name: "user_did",        type: "utf8"},
      %{name: "verb",            type: "utf8"},
      %{name: "seven_p_primary", type: "utf8"},
      %{name: "preserve_primary",type: "utf8"},
      %{name: "light_element",   type: "utf8"},
      %{name: "altruistic_axis", type: "utf8"},
      %{name: "vault_tier",      type: "utf8"},
      %{name: "created_at",      type: "int64"},
    ]}
    Table.create(cfg, "perception_events", %{schema: schema})
    :ok
  end

  defp ensure_preserve_table(cfg) do
    schema = %{fields: [
      %{name: "id",              type: "utf8"},
      %{name: "user_did",        type: "utf8"},
      %{name: "preserve_primary",type: "utf8"},
      %{name: "light_element",   type: "utf8"},
      %{name: "vault_tier",      type: "utf8"},
      %{name: "created_at",      type: "int64"},
    ]}
    Table.create(cfg, "preserve_events", %{schema: schema})
    :ok
  end
end
