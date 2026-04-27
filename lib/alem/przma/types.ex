defmodule Alem.Przma.Types do
  @moduledoc "Boundary validator for PRZMA domain types from the Rust client."

  @filter_names ~w[Body Senses Mind Heart Ego Knowledge Detachment]
  @filter_states ~w[CLEAR FOGGED]
  @seven_p_dimensions ~w[presence people portfolio progress perspectives pursuits protect]
  @preserve_components ~w[purpose resilience engagement social esteem renewal vitality equanimity]
  @light_elements ~w[live inquire grace heal transform]
  @altruistic_orientations ~w[serve return surrender]
  @vault_tiers ~w[private vault federated]
  @activity_verbs ~w[
    Create Read Update Delete Follow Like Announce Accept
    Arrive Leave Listen Move Play Travel View Watch
    Reflect Commit Witness Release Practice Breathe Connect Serve
  ]
  @confidence_levels ~w[confirmed high medium low]

  def valid_filter_name?(n),  do: n in @filter_names
  def valid_filter_state?(s), do: s in @filter_states
  def valid_seven_p?(d),      do: d in @seven_p_dimensions
  def valid_preserve?(c),     do: c in @preserve_components
  def valid_light_element?(e),do: e in @light_elements
  def valid_altruistic?(a),   do: a in @altruistic_orientations
  def valid_vault_tier?(t),   do: t in @vault_tiers
  def valid_verb?(v),         do: v in @activity_verbs
  def valid_confidence?(c),   do: c in @confidence_levels
  def default_vault_tier,     do: "private"
  def filter_names,           do: @filter_names
  def seven_p_dimensions,     do: @seven_p_dimensions
  def activity_verbs,         do: @activity_verbs

  @doc "Validate a perception event payload from the Tauri client."
  def validate_perception_event(payload) when is_map(payload) do
    errors =
      []
      |> validate_field(payload, "verb",             &valid_verb?/1)
      |> validate_field(payload, "seven_p_primary",  &valid_seven_p?/1)
      |> validate_field(payload, "preserve_primary", &valid_preserve?/1)
      |> validate_field(payload, "light_element",    &valid_light_element?/1)
      |> validate_field(payload, "altruistic_axis",  &valid_altruistic?/1)
      |> validate_field(payload, "vault_tier",       &valid_vault_tier?/1)
      |> validate_optional(payload, "seven_p_secondary",   &valid_seven_p?/1)
      |> validate_optional(payload, "registry_confidence", &valid_confidence?/1)

    case errors do
      []     -> {:ok, payload}
      errors -> {:error, errors}
    end
  end

  def validate_perception_event(_), do: {:error, [{"payload", "must be a map"}]}

  defp validate_field(errors, payload, field, validator) do
    value = Map.get(payload, field)
    if is_nil(value) do
      [{field, "is required"} | errors]
    else
      if validator.(value), do: errors, else: [{field, "#{inspect(value)} is not valid"} | errors]
    end
  end

  defp validate_optional(errors, payload, field, validator) do
    case Map.get(payload, field) do
      nil   -> errors
      value -> if validator.(value), do: errors, else: [{field, "#{inspect(value)} is not valid"} | errors]
    end
  end
end
