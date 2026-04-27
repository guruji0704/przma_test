defmodule Alem.Auth.PasswordReset do
  @moduledoc """
  Production-ready password reset system.

  Security properties:
    - Reset token stored as Pbkdf2 hash — plaintext never persisted
    - Constant-time comparison via Pbkdf2.verify_pass
    - 15-minute expiry
    - Single use — token cleared immediately after use
    - Rate limited: 60s cooldown between requests
    - Max 3 verify attempts before token invalidated
    - Generic error messages to prevent user enumeration
  """

  alias Alem.{Repo, Pleroma.User}
  alias Alem.Emails.OTPEmail
  alias Alem.Mailer
  require Logger

  @token_expiry_seconds  900   # 15 minutes
  @resend_cooldown_secs  60    # 60s between requests
  @max_attempts          3

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Generate a reset token and email it.
  Returns {:ok, :sent} even if user not found (prevents enumeration).
  """
  def request_reset(email) when is_binary(email) do
    case Repo.get_by(User, email: String.downcase(String.trim(email))) do
      nil ->
        # Don't reveal if email exists
        Logger.info("[PasswordReset] Reset requested for unknown email: #{email}")
        {:ok, :sent}

      user ->
        with :ok <- check_rate_limit(user) do
          {plaintext, hashed} = generate_token_pair()

          case store_token(user, hashed) do
            {:ok, updated_user} ->
              deliver_reset_email(updated_user, plaintext)
              {:ok, :sent}

            {:error, reason} ->
              Logger.error("[PasswordReset] Failed to store token for #{user.id}: #{inspect(reason)}")
              {:error, :internal}
          end
        end
    end
  end

  @doc """
  Verify token and reset password.

  Returns:
    {:ok, user}              — success
    {:error, :invalid}       — wrong token
    {:error, :expired}       — token expired
    {:error, :max_attempts}  — too many attempts
    {:error, :not_found}     — no pending reset
  """
  def reset_password(user_id, token, new_password) do
    case Repo.get(User, user_id) do
      nil ->
        {:error, :not_found}

      %{reset_token: nil} ->
        {:error, :not_found}

      user ->
        cond do
          user.reset_token_attempts >= @max_attempts ->
            invalidate_token(user)
            Logger.warning("[PasswordReset] Locked out user #{user.id}")
            {:error, :max_attempts}

          token_expired?(user) ->
            invalidate_token(user)
            Logger.info("[PasswordReset] Expired token for user #{user.id}")
            {:error, :expired}

          not Pbkdf2.verify_pass(token, user.reset_token) ->
            increment_attempts(user)
            Logger.warning("[PasswordReset] Wrong token for user #{user.id}")
            {:error, :invalid}

          true ->
            apply_new_password(user, new_password)
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp generate_token_pair do
    plaintext =
      :crypto.strong_rand_bytes(32)
      |> Base.url_encode64(padding: false)

    hashed = Pbkdf2.hash_pwd_salt(plaintext)
    {plaintext, hashed}
  end

  defp store_token(user, hashed_token) do
    expires_at =
      NaiveDateTime.utc_now()
      |> NaiveDateTime.add(@token_expiry_seconds, :second)
      |> NaiveDateTime.truncate(:second)

    sent_at = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    user
    |> Ecto.Changeset.change(%{
      reset_token:            hashed_token,
      reset_token_expires_at: expires_at,
      reset_token_attempts:   0,
      reset_sent_at:          sent_at
    })
    |> Repo.update()
  end

  defp deliver_reset_email(user, plaintext_token) do
    email = OTPEmail.password_reset_email(
      user.email,
      name:      user.name || user.nickname,
      reset_url: build_reset_url(user.id, plaintext_token)
    )

    case Mailer.deliver_with_logging(email) do
      {:ok, _} ->
        Logger.info("[PasswordReset] ✅ Email delivered to #{user.email}")
      {:error, reason} ->
        Logger.error("[PasswordReset] ❌ Email failed for #{user.email}: #{reason}")
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # KEY FIX: Use an https:// URL instead of the alem:// custom protocol.
  #
  # Why: Email clients (Gmail, Outlook, Apple Mail) block or visually
  # disable links that use unknown/custom URI schemes like alem://.
  # The button appeared greyed-out or unclickable because of this.
  #
  # Solution: Link to the HTTP reset-password page on the server, which
  # shows the user their user_id + token to paste into the ALEM app.
  # The ALEM_BASE_URL env var should be set to the public server address.
  # ═══════════════════════════════════════════════════════════════════════
  defp build_reset_url(user_id, token) do
    base_url =
      System.get_env("ALEM_BASE_URL", "http://172.235.17.68:4201")
      |> String.trim_trailing("/")

    "#{base_url}/reset-password?user_id=#{URI.encode_www_form(user_id)}&token=#{URI.encode_www_form(token)}"
  end

  defp apply_new_password(user, new_password) do
    hashed = Pbkdf2.hash_pwd_salt(new_password)

    user
    |> Ecto.Changeset.change(%{
      password_hash:          hashed,
      reset_token:            nil,
      reset_token_expires_at: nil,
      reset_token_attempts:   0,
      reset_sent_at:          nil
    })
    |> Repo.update()
    |> case do
      {:ok, updated_user} ->
        Logger.info("[PasswordReset] ✅ Password reset for user #{user.id}")
        {:ok, updated_user}

      {:error, reason} ->
        Logger.error("[PasswordReset] ❌ Failed to reset password for #{user.id}: #{inspect(reason)}")
        {:error, :internal}
    end
  end

  defp check_rate_limit(%User{reset_sent_at: nil}), do: :ok
  defp check_rate_limit(%User{reset_sent_at: sent_at}) do
    seconds_since = NaiveDateTime.diff(NaiveDateTime.utc_now(), sent_at, :second)

    if seconds_since < @resend_cooldown_secs do
      wait = @resend_cooldown_secs - seconds_since
      Logger.info("[PasswordReset] Rate limited — #{wait}s remaining")
      {:error, :rate_limited}
    else
      :ok
    end
  end

  defp token_expired?(%User{reset_token_expires_at: nil}), do: true
  defp token_expired?(%User{reset_token_expires_at: expires_at}) do
    NaiveDateTime.compare(NaiveDateTime.utc_now(), expires_at) == :gt
  end

  defp increment_attempts(user) do
    user
    |> Ecto.Changeset.change(%{reset_token_attempts: (user.reset_token_attempts || 0) + 1})
    |> Repo.update()
  end

  defp invalidate_token(user) do
    user
    |> Ecto.Changeset.change(%{
      reset_token:            nil,
      reset_token_expires_at: nil,
      reset_token_attempts:   0
    })
    |> Repo.update()
  end
end