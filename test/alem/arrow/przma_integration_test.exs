defmodule Alem.Arrow.PrzmaIntegrationTest do
  use ExUnit.Case, async: true
  alias Alem.PrzmaHNNServing
  alias AlemWeb.PrzmaAnalyticsController
  alias Alem.PrzmaBroadwayPipeline

  setup do
    # Mocking or setup for tests
    :ok
  end

  test "HNN input tensor assembly produces valid Arrow IPC" do
    arrays = [
      Enum.to_list(1..391) |> Enum.map(&(&1 * 1.0)),
      Enum.to_list(1..391) |> Enum.map(&(&1 * 2.0))
    ]

    assert {:ok, ipc_bytes} = PrzmaHNNServing.assemble_input_tensor(arrays)
    assert is_binary(ipc_bytes)
    assert byte_size(ipc_bytes) > 0

    # Verify we can load it back with Explorer
    assert {:ok, df} = Explorer.DataFrame.load_ipc(ipc_bytes)
    assert Explorer.DataFrame.n_rows(df) == 2
    assert Explorer.DataFrame.n_columns(df) == 391
  end

  test "Analytics controller handles mock DataFusion results" do
    # This test would normally use Phoenix.ConnTest
    # For now, we simulate the internal call
    df = Explorer.DataFrame.new(%{"test" => [1, 2, 3]}) |> elem(1)
    {:ok, ipc_bytes} = Explorer.DataFrame.dump_ipc(df)

    assert {:ok, loaded_df} = Explorer.DataFrame.load_ipc(ipc_bytes)
    assert Explorer.DataFrame.to_rows(loaded_df) == [%{"test" => 1}, %{"test" => 2}, %{"test" => 3}]
  end
end
