defmodule Alem.Przma.VerbRegistry do
  @moduledoc "Mirrors the Rust VerbRegistry. Validates classification payloads from Tauri client."

  @verb_map %{
    "Create"   => %{seven_p: "portfolio",    preserve: "engagement",  light: "transform", altruistic: "serve"},
    "Read"     => %{seven_p: "perspectives", preserve: "purpose",     light: "inquire",   altruistic: "return"},
    "Update"   => %{seven_p: "progress",     preserve: "vitality",    light: "heal",      altruistic: "serve"},
    "Delete"   => %{seven_p: "protect",      preserve: "equanimity",  light: "grace",     altruistic: "surrender"},
    "Follow"   => %{seven_p: "people",       preserve: "social",      light: "live",      altruistic: "serve"},
    "Like"     => %{seven_p: "people",       preserve: "social",      light: "live",      altruistic: "return"},
    "Announce" => %{seven_p: "pursuits",     preserve: "esteem",      light: "transform", altruistic: "serve"},
    "Accept"   => %{seven_p: "people",       preserve: "social",      light: "grace",     altruistic: "return"},
    "Arrive"   => %{seven_p: "presence",     preserve: "renewal",     light: "live",      altruistic: "serve"},
    "Leave"    => %{seven_p: "protect",      preserve: "equanimity",  light: "grace",     altruistic: "surrender"},
    "Listen"   => %{seven_p: "people",       preserve: "social",      light: "inquire",   altruistic: "return"},
    "Move"     => %{seven_p: "presence",     preserve: "vitality",    light: "transform", altruistic: "serve"},
    "Play"     => %{seven_p: "pursuits",     preserve: "renewal",     light: "live",      altruistic: "serve"},
    "Travel"   => %{seven_p: "pursuits",     preserve: "renewal",     light: "live",      altruistic: "serve"},
    "View"     => %{seven_p: "perspectives", preserve: "purpose",     light: "inquire",   altruistic: "return"},
    "Watch"    => %{seven_p: "perspectives", preserve: "renewal",     light: "inquire",   altruistic: "return"},
    "Reflect"  => %{seven_p: "presence",     preserve: "purpose",     light: "inquire",   altruistic: "return"},
    "Commit"   => %{seven_p: "progress",     preserve: "purpose",     light: "transform", altruistic: "serve"},
    "Witness"  => %{seven_p: "people",       preserve: "social",      light: "inquire",   altruistic: "return"},
    "Release"  => %{seven_p: "protect",      preserve: "equanimity",  light: "grace",     altruistic: "surrender"},
    "Practice" => %{seven_p: "progress",     preserve: "vitality",    light: "heal",      altruistic: "serve"},
    "Breathe"  => %{seven_p: "presence",     preserve: "vitality",    light: "heal",      altruistic: "serve"},
    "Connect"  => %{seven_p: "people",       preserve: "social",      light: "live",      altruistic: "serve"},
    "Serve"    => %{seven_p: "protect",      preserve: "equanimity",  light: "grace",     altruistic: "serve"},
  }

  def lookup(verb), do: Map.get(@verb_map, verb)
  def known_verbs,  do: Map.keys(@verb_map)

  def validate_classification(%{"verb" => verb} = payload) do
    case lookup(verb) do
      nil ->
        {:error, "Unknown verb: #{inspect(verb)}"}
      expected ->
        errors =
          []
          |> check_field(payload, "seven_p_primary",  expected.seven_p)
          |> check_field(payload, "preserve_primary", expected.preserve)
          |> check_field(payload, "light_element",    expected.light)
          |> check_field(payload, "altruistic_axis",  expected.altruistic)

        case errors do
          []     -> {:ok, :valid}
          errors -> {:error, errors}
        end
    end
  end

  def validate_classification(_), do: {:error, "Payload must include 'verb'"}

  defp check_field(errors, payload, field, expected) do
    actual = Map.get(payload, field)
    if actual == expected, do: errors, else: [{field, "expected #{expected}, got #{inspect(actual)}"} | errors]
  end
end
