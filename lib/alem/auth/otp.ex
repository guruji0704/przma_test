defmodule Alem.Auth.OTP do
  @moduledoc """
  Production-ready secure OTP system.

  Security properties:
    - OTP stored as Pbkdf2 hash — plaintext NEVER persisted after sending
    - Constant-time comparison via Pbkdf2.verify_pass (no timing attacks)
    - Max 3 verify attempts before lockout
    - 10-minute expiry
    - Rate limit: cooldown enforced between resends
  """

  alias Alem.{Repo, Pleroma.User}
  alias Alem.Emails.OTPEmail
  alias Alem.Mailer
  require Logger

  @otp_expiry_seconds   600   # 10 minutes
  @max_verify_attempts  3
  @resend_cooldown_secs 60    # must wait 60s between resends

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Generate a fresh OTP, store its Pbkdf2 hash, and email the plaintext code.

  Returns {:ok, user} or {:error, :rate_limited | reason}.
  """
  def generate_and_send(%User{} = user) do
    with :ok <- check_resend_cooldown(user) do
      {plaintext, hashed} = generate_otp_pair()

      case store_otp(user, hashed) do
        {:ok, updated_user} ->
          deliver_otp_email(updated_user, plaintext)
          {:ok, updated_user}

        {:error, reason} ->
          Logger.error("[OTP] Failed to store OTP for #{user.id}: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @doc """
  Verify a submitted OTP code against the stored hash.

  Returns:
    {:ok, user}              — correct code, user marked verified
    {:error, :invalid}       — wrong code (attempts incremented)
    {:error, :expired}       — code has expired
    {:error, :max_attempts}  — too many wrong attempts
  """
  def verify(%User{} = user, submitted_code) when is_binary(submitted_code) do
    cond do
      user.otp_attempts >= @max_verify_attempts ->
        Logger.warning("[OTP] Locked out user #{user.id} — max attempts reached")
        {:error, :max_attempts}

      is_nil(user.otp_code) ->
        {:error, :invalid}

      otp_expired?(user) ->
        Logger.info("[OTP] Expired OTP attempt for user #{user.id}")
        {:error, :expired}

      not Pbkdf2.verify_pass(submitted_code, user.otp_code) ->
        increment_attempts(user)
        Logger.warning("[OTP] Wrong code for user #{user.id} (attempt #{user.otp_attempts + 1})")
        {:error, :invalid}

      true ->
        Logger.info("[OTP] ✅ Code verified for user #{user.id}")
        mark_verified(user)
    end
  end

  def verify(_user, _code), do: {:error, :invalid}

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  # Generate a 6-digit numeric code and its Pbkdf2 hash
  defp generate_otp_pair do
    plaintext =
      :rand.uniform(999_999)
      |> Integer.to_string()
      |> String.pad_leading(6, "0")

    # Hash with Pbkdf2 — same library used for passwords
    hashed = Pbkdf2.hash_pwd_salt(plaintext)

    {plaintext, hashed}
  end

  # Persist the hashed OTP and reset attempt counter
  defp store_otp(user, hashed_code) do
    expires_at =
      NaiveDateTime.utc_now()
      |> NaiveDateTime.add(@otp_expiry_seconds, :second)
      |> NaiveDateTime.truncate(:second)

    user
    |> Ecto.Changeset.change(%{
      otp_code:       hashed_code,
      otp_expires_at: expires_at,
      otp_attempts:   0
    })
    |> Repo.update()
  end

  # Send plaintext OTP via email — plaintext is never stored
  defp deliver_otp_email(user, plaintext_code) do
    email =
      OTPEmail.verification_email(
        user.email,
        plaintext_code,
        name:            user.name || user.nickname,
        expires_minutes: div(@otp_expiry_seconds, 60)
      )

    case Mailer.deliver_with_logging(email) do
      {:ok, _} ->
        Logger.info("[OTP] ✅ Email delivered to #{user.email}")

      {:error, reason} ->
        # Log but do not block registration — ops can re-trigger resend
        Logger.error("[OTP] ❌ Email delivery failed for #{user.email}: #{reason}")
    end
  end

  # Prevent rapid resends — require cooldown between requests
  defp check_resend_cooldown(%User{otp_expires_at: nil}), do: :ok
  defp check_resend_cooldown(%User{otp_expires_at: expires_at}) do
    # otp_expires_at = sent_at + @otp_expiry_seconds
    # So sent_at = otp_expires_at - @otp_expiry_seconds
    sent_at = NaiveDateTime.add(expires_at, -@otp_expiry_seconds, :second)
    seconds_since_sent = NaiveDateTime.diff(NaiveDateTime.utc_now(), sent_at, :second)

    if seconds_since_sent < @resend_cooldown_secs do
      wait = @resend_cooldown_secs - seconds_since_sent
      Logger.info("[OTP] Resend rate limited — #{wait}s remaining")
      {:error, :rate_limited}
    else
      :ok
    end
  end

  defp otp_expired?(%User{otp_expires_at: nil}), do: true
  defp otp_expired?(%User{otp_expires_at: expires_at}) do
    NaiveDateTime.compare(NaiveDateTime.utc_now(), expires_at) == :gt
  end

  defp increment_attempts(user) do
    user
    |> Ecto.Changeset.change(%{otp_attempts: (user.otp_attempts || 0) + 1})
    |> Repo.update()
  end

  defp mark_verified(user) do
    user
    |> Ecto.Changeset.change(%{
      is_verified:    true,
      otp_code:       nil,
      otp_expires_at: nil,
      otp_attempts:   0
    })
    |> Repo.update()
  end
end
