defmodule Alem.Lance.Config do
  @moduledoc "Connection configuration for LanceDB client."

  @type t :: %__MODULE__{
          base_url:       String.t(),
          api_key:        String.t() | nil,
          namespace:      String.t(),
          pool_size:      pos_integer(),
          timeout:        pos_integer(),
          retry_attempts: non_neg_integer(),
          retry_delay_ms: pos_integer()
        }

  defstruct [
    :base_url,
    :api_key,
    namespace:      "przma",
    pool_size:      10,
    timeout:        30_000,
    retry_attempts: 3,
    retry_delay_ms: 500
  ]

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    app_cfg = Application.get_env(:alem, :lancedb, [])
    merged  = Keyword.merge(app_cfg, opts)
    struct!(__MODULE__, merged)
  end

  @spec for_user(t(), String.t()) :: t()
  def for_user(%__MODULE__{namespace: ns} = cfg, user_id) do
    %{cfg | namespace: "#{ns}:user:#{user_id}"}
  end

  @spec for_namespace(t(), String.t()) :: t()
  def for_namespace(%__MODULE__{} = cfg, namespace) do
    %{cfg | namespace: namespace}
  end

  @spec validate!(t()) :: t()
  def validate!(%__MODULE__{base_url: nil}),
    do: raise(ArgumentError, "Alem.Lance.Config requires :base_url — check config :alem, :lancedb")
  def validate!(%__MODULE__{} = cfg), do: cfg
end
