defmodule Alem.Lance.Table do
  @moduledoc "Table operations against the LanceDB REST API."

  alias Alem.Lance.{Config, HTTP, Query, Error}

  # ── Table management ───────────────────────────────────────────────────

  @spec list(Config.t()) :: {:ok, [String.t()]} | {:error, Error.t()}
  def list(%Config{} = cfg) do
    case HTTP.get(cfg, "table/") do
      {:ok, %{"tables" => tables}} -> {:ok, tables}
      {:ok, tables} when is_list(tables) -> {:ok, tables}
      {:error, _} = err -> err
    end
  end

  @spec create(Config.t(), String.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def create(%Config{} = cfg, table_name, body \\ %{}) do
    HTTP.post(cfg, "table/#{table_name}/create/", body)
  end

  @spec describe(Config.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def describe(%Config{} = cfg, table_name) do
    HTTP.get(cfg, "table/#{table_name}/describe/")
  end

  @spec drop(Config.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def drop(%Config{} = cfg, table_name) do
    HTTP.delete(cfg, "table/#{table_name}/")
  end

  # ── Data operations ────────────────────────────────────────────────────

  @spec insert(Config.t(), String.t(), [map()]) :: {:ok, map()} | {:error, Error.t()}
  def insert(%Config{} = cfg, table_name, records) when is_list(records) do
    HTTP.post(cfg, "table/#{table_name}/insert/", %{"data" => records})
  end

  @spec delete(Config.t(), String.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def delete(%Config{} = cfg, table_name, where_clause) do
    HTTP.post(cfg, "table/#{table_name}/delete/", %{"predicate" => where_clause})
  end

  @spec update(Config.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def update(%Config{} = cfg, table_name, updates, opts \\ []) do
    body =
      %{"updates" => updates}
      |> maybe_put_filter(Keyword.get(opts, :where))
    HTTP.post(cfg, "table/#{table_name}/update/", body)
  end

  # ── Search ─────────────────────────────────────────────────────────────

  @spec search(Config.t(), String.t(), Query.t()) :: {:ok, [map()]} | {:error, Error.t()}
  def search(%Config{} = cfg, table_name, %Query{} = query) do
    body = Query.to_request(query)
    case HTTP.post(cfg, "table/#{table_name}/query/", body) do
      {:ok, %{"data" => rows}} -> {:ok, rows}
      {:ok, rows} when is_list(rows) -> {:ok, rows}
      {:error, _} = err -> err
    end
  end

  @spec count(Config.t(), String.t(), String.t() | nil) ::
          {:ok, non_neg_integer()} | {:error, Error.t()}
  def count(%Config{} = cfg, table_name, filter \\ nil) do
    body = if filter, do: %{"predicate" => filter}, else: %{}
    case HTTP.post(cfg, "table/#{table_name}/count_rows/", body) do
      {:ok, %{"count" => n}} -> {:ok, n}
      {:ok, n} when is_integer(n) -> {:ok, n}
      {:error, _} = err -> err
    end
  end

  # ── Private ────────────────────────────────────────────────────────────

  defp maybe_put_filter(body, nil),    do: body
  defp maybe_put_filter(body, filter), do: Map.put(body, "filter", filter)
end
