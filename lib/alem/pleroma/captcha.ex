# =============================================================================
# Alem.Pleroma.Captcha
# =============================================================================
# Based on Pleroma.Captcha
# Source: https://git.pleroma.social/pleroma/pleroma/src/branch/develop/lib/pleroma/captcha.ex
#
# Pleroma's Captcha is a GenServer. We simplify it into an Ecto schema
# while keeping the same interface pattern (answer_data, token, type).
#
# Pleroma captcha response format:
#   %{type: "image", token: "...", answer_data: "...", seconds_valid: 300}
# We follow this exact response structure.
# =============================================================================

  defmodule Alem.Pleroma.Captcha do
    use Ecto.Schema
    import Ecto.Changeset

    @moduledoc """
    Captcha challenge schema.

    Response format matches Pleroma.Captcha for API compatibility:
      type: "image", token: "...", answer_data: "..."

    Based on Pleroma (AGPL-3.0): https://git.pleroma.social/pleroma/pleroma
    Source: https://git.pleroma.social/pleroma/pleroma/src/branch/develop/lib/pleroma/captcha.ex
    """

    # Captcha valid for 5 minutes (300 seconds)
    # Pleroma default: 300 seconds
    @seconds_valid 300

    @primary_key {:id, :string, autogenerate: false}

    schema "captcha_challenges" do
      # Public token sent to user — used to look up the answer
      # Matches Pleroma's captcha token field
      field :token,      :string

      # The answer to the captcha challenge
      # Pleroma calls this `answer_data` in the response
      field :answer,     :string

      # Expiry time (seconds_valid in Pleroma is 300)
      field :expires_at, :utc_datetime

      # Prevents reuse of same captcha token
      field :used,       :boolean, default: false

      timestamps()
    end

    @doc """
    Changeset for creating a new captcha challenge.

    Generates token, answer, and expiry automatically.
    Response format follows Pleroma.Captcha.new/0 output.
    """
    def changeset(captcha, attrs \\ %{}) do
      captcha
      |> cast(attrs, [])
      |> put_id()
      |> put_token()
      |> put_answer()
      |> put_expiry()
    end

    @doc """
    Format the captcha response exactly as Pleroma returns it.

    Pleroma captcha response:
      %{type: "image", token: "...", answer_data: "...", seconds_valid: 300}
    """
    def to_response(%__MODULE__{} = captcha) do
      %{
        type:        "image",
        token:       captcha.token,
        answer_data: captcha.answer,  # Pleroma calls it answer_data
        seconds_valid: @seconds_valid
      }
    end

    # -------------------------------------------------------------------------
    # Private helpers
    # -------------------------------------------------------------------------

    defp put_id(changeset) do
      id =
        :crypto.strong_rand_bytes(8)
        |> Base.url_encode64(padding: false)
        |> String.slice(0, 10)

      put_change(changeset, :id, id)
    end

    # Captcha token: 32 random bytes → base64 string
    defp put_token(changeset) do
      token =
        :crypto.strong_rand_bytes(32)
        |> Base.url_encode64(padding: false)

      put_change(changeset, :token, token)
    end

    # Captcha answer: 4 random bytes → HEX → first 6 chars
    # e.g. "A8F3K2"
    defp put_answer(changeset) do
      answer =
        :crypto.strong_rand_bytes(4)
        |> Base.encode16()
        |> String.slice(0, 6)

      put_change(changeset, :answer, answer)
    end

    # Expiry: NOW + 300 seconds (5 minutes)
    defp put_expiry(changeset) do
      expires_at =
        DateTime.utc_now()
        |> DateTime.add(@seconds_valid, :second)
        |> DateTime.truncate(:second)

      put_change(changeset, :expires_at, expires_at)
    end
  end
