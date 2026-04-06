defmodule Przma.XRPC.Validator do
  @moduledoc """
  Validates XRPC request parameters against a lexicon schema.

  Checks:
    - All required fields are present
    - Field types match the schema definition
    - Enum values are valid
    - String maxLength is not exceeded
    - Integer min/max are respected
  """

  @doc "Validate params map against a lexicon schema map."
  def validate(schema, params) do
    # Determine if this is a query (GET) or procedure (POST)
    input_schema =
      case schema["type"] do
        "query"     -> schema["parameters"]
        "procedure" -> schema["input"]
        _           -> nil
      end

    if input_schema do
      validate_object(input_schema, params)
    else
      :ok
    end
  end

  # ── PRIVATE ───────────────────────────────────────────────────────────────

  defp validate_object(schema, params) when is_map(schema) do
    required = schema["required"] || []
    props    = schema["properties"] || %{}

    # Check required fields
    missing =
      Enum.filter(required, fn field ->
        not Map.has_key?(params, field) and not Map.has_key?(params, String.to_atom(field))
      end)

    if missing != [] do
      {:error, {:validation, %{missing_required: missing}}}
    else
      # Validate each present field
      errors =
        params
        |> Enum.flat_map(fn {key, value} ->
          key_str = to_string(key)
          case Map.get(props, key_str) do
            nil        -> []   # Unknown fields pass through (non-strict)
            field_spec -> validate_field(key_str, value, field_spec)
          end
        end)

      if errors == [], do: :ok, else: {:error, {:validation, errors}}
    end
  end

  defp validate_object(_schema, _params), do: :ok

  defp validate_field(key, value, %{"type" => "string"} = spec) do
    errors = []
    errors = if not is_binary(value), do: [{key, "must be a string"} | errors], else: errors
    errors =
      if is_binary(value) and spec["maxLength"] and byte_size(value) > spec["maxLength"] do
        [{key, "exceeds maxLength of #{spec["maxLength"]}"} | errors]
      else
        errors
      end
    errors =
      if is_binary(value) and spec["enum"] and value not in spec["enum"] do
        [{key, "must be one of: #{Enum.join(spec["enum"], ", ")}"} | errors]
      else
        errors
      end
    errors
  end

  defp validate_field(key, value, %{"type" => "integer"} = spec) do
    if not is_integer(value) do
      [{key, "must be an integer"}]
    else
      errors = []
      errors = if spec["minimum"] and value < spec["minimum"], do: [{key, "below minimum #{spec["minimum"]}"} | errors], else: errors
      errors = if spec["maximum"] and value > spec["maximum"], do: [{key, "above maximum #{spec["maximum"]}"} | errors], else: errors
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
      max_items = spec["maxItems"]
      if max_items and length(value) > max_items do
        [{key, "exceeds maxItems of #{max_items}"}]
      else
        []
      end
    end
  end

  defp validate_field(_key, _value, _spec), do: []
end
