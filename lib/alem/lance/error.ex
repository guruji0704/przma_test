defmodule Alem.Lance.Error do
  @moduledoc "Structured error types for LanceDB client."

  @type kind ::
          :not_found
          | :conflict
          | :bad_request
          | :unauthorized
          | :timeout
          | :network
          | :server_error
          | :unknown

  @type t :: %__MODULE__{
          kind:    kind(),
          message: String.t(),
          status:  integer() | nil
        }

  defstruct [:kind, :message, :status]

  def not_found(msg),    do: %__MODULE__{kind: :not_found,    message: to_string(msg), status: 404}
  def conflict(msg),     do: %__MODULE__{kind: :conflict,     message: to_string(msg), status: 409}
  def bad_request(msg),  do: %__MODULE__{kind: :bad_request,  message: to_string(msg), status: 400}
  def unauthorized(msg), do: %__MODULE__{kind: :unauthorized, message: to_string(msg), status: 401}
  def timeout(msg),      do: %__MODULE__{kind: :timeout,      message: to_string(msg), status: nil}
  def network(msg),      do: %__MODULE__{kind: :network,      message: to_string(msg), status: nil}

  def from_response(status, body) do
    message = extract_message(body)
    kind     = kind_from_status(status)
    %__MODULE__{kind: kind, message: message, status: status}
  end

  defp kind_from_status(404), do: :not_found
  defp kind_from_status(409), do: :conflict
  defp kind_from_status(400), do: :bad_request
  defp kind_from_status(401), do: :unauthorized
  defp kind_from_status(s) when s >= 500, do: :server_error
  defp kind_from_status(_), do: :unknown

  defp extract_message(%{"detail" => d}), do: to_string(d)
  defp extract_message(%{"message" => m}), do: to_string(m)
  defp extract_message(%{"error" => e}), do: to_string(e)
  defp extract_message(body) when is_binary(body), do: body
  defp extract_message(_), do: "Unknown error"
end
