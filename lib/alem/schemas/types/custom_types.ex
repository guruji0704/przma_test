defmodule AlemWeb.Schema.Types.Custom do
  use Absinthe.Schema.Notation

  scalar :json, name: "Json" do
    description "Arbitrary JSON value"

    serialize  &encode_json/1
    parse      &decode_json/1
  end

  defp encode_json(value), do: value

  defp decode_json(%Absinthe.Blueprint.Input.String{value: value}) do
    case Jason.decode(value) do
      {:ok, result} -> {:ok, result}
      _             -> :error
    end
  end
  defp decode_json(%Absinthe.Blueprint.Input.Null{}), do: {:ok, nil}
  defp decode_json(_), do: :error
end
