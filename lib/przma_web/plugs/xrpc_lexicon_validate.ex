defmodule PrzmaWeb.Plugs.XRPCLexiconValidate do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    lexicon_id = List.last(conn.path_info)

    # Coerce string integers from query params to integers
    params =
      Map.merge(conn.params || %{}, conn.body_params || %{})
      |> coerce_integers()

    case Przma.XRPC.LexiconRegistry.validate(lexicon_id, params) do
      :ok ->
        assign(conn, :lexicon_id, lexicon_id)

      {:error, {:unknown_lexicon, id}} ->
        conn
        |> put_status(404)
        |> Phoenix.Controller.json(%{error: "unknown_xrpc_method", lexicon: id})
        |> halt()

      {:error, {:validation, errors}} ->
        # Convert errors to a JSON-safe format
        safe_errors =
          cond do
            is_map(errors) -> errors
            is_list(errors) ->
              Enum.map(errors, fn
                {field, msg} -> %{field: field, message: msg}
                other -> inspect(other)
              end)
            true -> inspect(errors)
          end

        conn
        |> put_status(400)
        |> Phoenix.Controller.json(%{error: "validation_failed", detail: safe_errors})
        |> halt()
    end
  end

  # Coerce string numbers to integers for query string params
  defp coerce_integers(params) do
    Map.new(params, fn {k, v} ->
      case v do
        v when is_binary(v) ->
          case Integer.parse(v) do
            {int, ""} -> {k, int}
            _         -> {k, v}
          end
        _ ->
          # Leave lists, maps, booleans, integers as-is
          {k, v}
      end
    end)
  end
end
