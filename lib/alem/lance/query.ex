defmodule Alem.Lance.Query do
  @moduledoc "Composable query builder for LanceDB."

  @type t :: %__MODULE__{
          vector:  [float()] | nil,
          filter:  String.t() | nil,
          limit:   pos_integer(),
          columns: [String.t()] | nil,
          metric:  atom()
        }

  defstruct [
    :vector,
    :filter,
    :columns,
    limit:  10,
    metric: :cosine
  ]

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec vector(t(), [float()]) :: t()
  def vector(%__MODULE__{} = q, vec) when is_list(vec),
    do: %{q | vector: vec}

  @spec filter(t(), String.t()) :: t()
  def filter(%__MODULE__{} = q, f) when is_binary(f),
    do: %{q | filter: f}

  @spec limit(t(), pos_integer()) :: t()
  def limit(%__MODULE__{} = q, n) when is_integer(n) and n > 0,
    do: %{q | limit: n}

  @spec columns(t(), [String.t()]) :: t()
  def columns(%__MODULE__{} = q, cols) when is_list(cols),
    do: %{q | columns: cols}

  @spec metric(t(), atom()) :: t()
  def metric(%__MODULE__{} = q, m) when is_atom(m),
    do: %{q | metric: m}

  @spec to_request(t()) :: map()
  def to_request(%__MODULE__{} = q) do
    %{"limit" => q.limit}
    |> maybe_put("vector",  q.vector)
    |> maybe_put("filter",  q.filter)
    |> maybe_put("columns", q.columns)
    |> maybe_put("metric",  q.metric && Atom.to_string(q.metric))
  end

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, k, v),    do: Map.put(map, k, v)
end
