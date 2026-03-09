defmodule Alem.Mailer do
  use Swoosh.Mailer, otp_app: :alem

  require Logger

  @doc """
  Deliver email with full structured error logging.

  Returns {:ok, metadata} or {:error, reason_string}.
  Unlike deliver/1, this never raises — always returns a tuple.
  """
  def deliver_with_logging(email) do
    recipient =
      case email.to do
        [{_name, addr} | _] -> addr
        [addr | _] when is_binary(addr) -> addr
        _ -> "unknown"
      end

    case deliver(email) do
      {:ok, metadata} ->
        Logger.info("[Mailer] ✅ Delivered to #{recipient}")
        {:ok, metadata}

      {:error, {code, _headers, body}} when is_integer(code) ->
        msg = "SMTP #{code}: #{inspect(body)}"
        Logger.error("[Mailer] ❌ #{msg} — recipient=#{recipient}")
        {:error, msg}

      {:error, {:timeout, _}} ->
        Logger.error("[Mailer] ❌ Timeout connecting to SMTP — recipient=#{recipient}")
        {:error, "SMTP connection timeout"}

      {:error, :econnrefused} ->
        Logger.error("[Mailer] ❌ SMTP connection refused — check relay/port config")
        {:error, "SMTP connection refused"}

      {:error, reason} ->
        msg = inspect(reason)
        Logger.error("[Mailer] ❌ Delivery failed for #{recipient}: #{msg}")
        {:error, msg}
    end
  end
end
