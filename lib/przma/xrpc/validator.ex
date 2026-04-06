defmodule Przma.XRPC.Validator do
  @moduledoc "Validates XRPC request parameters against a lexicon schema."

  def validate(schema, params) do
    input_schema =
      case schema["type"] do
        "query"     -> schema["parameters"]
        "procedure" -> schema["input"]
        _           -> nil
      end

    if input_schema, do: validate_object(input_schema, params), else: :ok
  end

  defp validate_object(schema, params) when is_map(schema) do
    required = schema["required"] || []
    props    = schema["properties"] || %{}

    missing =
      Enum.filter(required, fn field ->
        not Map.has_key?(params, field) and
        not Map.has_key?(params, String.to_atom(field))
      end)

    if missing != [] do
      {:error, {:validation, %{missing_required: missing}}}
    else
      errors =
        Enum.flat_map(params, fn {key, value} ->
          key_str = to_string(key)
          case Map.get(props, key_str) do
            nil        -> []
            field_spec -> validate_field(key_str, value, field_spec)
          end
        end)

      if errors == [], do: :ok, else: {:error, {:validation, errors}}
    end
  end

  defp validate_object(_schema, _params), do: :ok

  defp validate_field(key, value, %{"type" => "string"} = spec) do
    errors = []

    errors =
      if not is_binary(value),
        do: [{key, "must be a string"} | errors],
        else: errors

    errors =
      if is_binary(value) and is_integer(spec["maxLength"]) and
           byte_size(value) > spec["maxLength"],
         do: [{key, "exceeds maxLength of #{spec["maxLength"]}"} | errors],
         else: errors

    errors =
      if is_binary(value) and is_list(spec["enum"]) and
           value not in spec["enum"],
         do: [{key, "must be one of: #{Enum.join(spec["enum"], ", ")}"} | errors],
         else: errors

    errors
  end

  defp validate_field(key, value, %{"type" => "integer"} = spec) do
    if not is_integer(value) do
      [{key, "must be an integer"}]
    else
      errors = []

      errors =
        if is_integer(spec["minimum"]) and value < spec["minimum"],
          do: [{key, "below minimum #{spec["minimum"]}"} | errors],
          else: errors

      errors =
        if is_integer(spec["maximum"]) and value > spec["maximum"],
          do: [{key, "above maximum #{spec["maximum"]}"} | errors],
          else: errors

      errors
    end
  end

  defp validate_field(key, value, %{"type" => "boolean"}) do
    if not is_boolean(value), do: [{key, "must be a boolean"}], else: []
  end

  defp validate_field(key, value, %{"type" => "array"} = spec) do
    if not is_list(value) do
      [{key, "must be an array"}]
    else
      if is_integer(spec["maxItems"]) and length(value) > spec["maxItems"],
        do: [{key, "exceeds maxItems of #{spec["maxItems"]}"}],
        else: []
    end
  end

  defp validate_field(_key, _value, _spec), do: []
end
