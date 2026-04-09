defmodule Alem.Plug.MsgpackParser do
  @moduledoc """
  Plug.Parsers-compatible parser for application/x-msgpack bodies.

  Registered in AlemWeb.Endpoint alongside :json so any controller
  receives already-decoded params when the client sends MsgPack.

  The Tauri client sends:
    Content-Type: application/x-msgpack
    Body: MsgPack({ "arrow_ipc": <binary>, "epoch_id": <int|nil>, ... })

  After this parser runs, conn.params contains:
    %{
      "arrow_ipc"        => <<...binary IPC bytes...>>,
      "epoch_id"         => 7,
      "automerge_state"  => <<...>>,
      "text_content"     => "...",
      "last_modified_at" => "2026-03-26T..."
    }

  binary: true is required so that binary fields (arrow_ipc, automerge_state)
  come through as raw Elixir binaries rather than decoded UTF-8 strings.
  """

  require Logger
  @behaviour Plug.Parsers

  def init(opts), do: opts

  # Only handle application/x-msgpack; pass everything else to the next parser.
  def parse(conn, "application", "x-msgpack", _headers, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        case Msgpax.unpack(body, binary: true) do
          {:ok, params} when is_map(params) ->
            Logger.debug("[MsgpackParser] Decoded keys: #{inspect(Map.keys(params))}")
            {:ok, params, conn}

          {:ok, _other} ->
            {:error, :bad_request, conn}

          {:error, reason} ->
            raise Plug.Parsers.ParseError,
              exception: %RuntimeError{message: "MsgPack parse failed: #{inspect(reason)}"}
        end

      {:more, _partial, conn} ->
        {:error, :too_large, conn}

      {:error, :timeout} ->
        raise Plug.TimeoutError

      {:error, _reason} ->
        raise Plug.BadRequestError
    end
  end

  def parse(conn, _type, _subtype, _headers, _opts), do: {:next, conn}
end
