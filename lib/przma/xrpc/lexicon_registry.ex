defmodule Przma.XRPC.LexiconRegistry do
  @moduledoc """
  XRPC Lexicon Registry.

  Loads all lexicon schemas at startup into an ETS table.
  Provides fast O(1) lookup for validation and routing.
  """
  use GenServer

  @table_name __MODULE__

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init([]) do
    table = :ets.new(@table_name, [
      :named_table, :set, :public,
      read_concurrency: true
    ])

    lexicon_modules()
    |> Enum.flat_map(fn mod -> mod.all() end)
    |> Enum.each(fn {id, schema} ->
      :ets.insert(table, {id, schema})
    end)

    count = :ets.info(table, :size)
    require Logger
    Logger.info("[LexiconRegistry] Loaded #{count} lexicons")

    {:ok, %{table: table}}
  end

  @doc "Validate request params against a lexicon schema."
  def validate(lexicon_id, params) do
    case :ets.lookup(@table_name, lexicon_id) do
      [{^lexicon_id, schema}] ->
        Przma.XRPC.Validator.validate(schema, params)
      [] ->
        {:error, {:unknown_lexicon, lexicon_id}}
    end
  end

  @doc "Get a lexicon schema by ID."
  def get(lexicon_id) do
    case :ets.lookup(@table_name, lexicon_id) do
      [{^lexicon_id, schema}] -> {:ok, schema}
      []                      -> {:error, :not_found}
    end
  end

  @doc "List all registered lexicon IDs."
  def list_ids do
    :ets.tab2list(@table_name)
    |> Enum.map(fn {id, _} -> id end)
    |> Enum.sort()
  end

  defp lexicon_modules do
    [
      Przma.Lexicons.Inbox,
      Przma.Lexicons.Chat.DM,
      Przma.Lexicons.Chat.Circle,
      Przma.Lexicons.Chat.Shout,
      Przma.Lexicons.Chat.Agent,
      Przma.Lexicons.Memorial,
      Przma.Lexicons.Vault,
      Przma.Lexicons.Studio,
      Przma.Lexicons.Collab,
      Przma.Lexicons.Perception,
      Przma.Lexicons.Circles,
      Przma.Lexicons.Analytics
    ]
  end
end
