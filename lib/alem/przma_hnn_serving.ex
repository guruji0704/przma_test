defmodule Alem.PrzmaHNNServing do
  @moduledoc """
  HNN Input Tensor Assembly.
  
  Assembles high-dimensional (391-dim) float arrays as Arrow arrays
  before passing them to ONNX inference engines. Using Arrow ensures
  zero-copy semantics when moving data from the assembly process to the
  serving/inference boundary.
  """
  require Logger

  @doc """
  Assembles a list of 391-dimensional float arrays into an Arrow IPC stream.
  
  Each array in the input list represents one event/observation to be scored.
  The output is a binary blob in Arrow IPC streaming format, which can be
  passed directly to an inference layer or written to shared memory.
  """
  def assemble_input_tensor(arrays) when is_list(arrays) do
    # Create column names: f0, f1, ..., f390
    col_names = Enum.map(0..390, &"f#{&1}")

    # Transpose the list of rows into a list of columns for Explorer
    # Note: For large batches, a more efficient matrix-to-column conversion would be used.
    cols = transpose(arrays)

    data = Enum.zip(col_names, cols) |> Map.new()

    case Explorer.DataFrame.new(data) do
      {:ok, df} ->
        # Dump to Arrow IPC stream format for zero-copy transport
        case Explorer.DataFrame.dump_ipc(df) do
          {:ok, bytes} -> {:ok, bytes}
          {:error, reason} -> 
            Logger.error("[HNN] Arrow IPC dump failed: #{inspect(reason)}")
            {:error, {:arrow_dump, reason}}
        end
      {:error, reason} -> 
        Logger.error("[HNN] DataFrame creation failed: #{inspect(reason)}")
        {:error, {:df_creation, reason}}
    end
  end

  # Helper to transpose a list of lists
  defp transpose([]), do: []
  defp transpose([[] | _]), do: []
  defp transpose(m) do
    [Enum.map(m, &hd/1) | transpose(Enum.map(m, &tl/1))]
  end
end
