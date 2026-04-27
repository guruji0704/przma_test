defmodule Alem.Lance.HTTP do
  @moduledoc "HTTP transport for LanceDB REST API."

  alias Alem.Lance.{Config, Error}
  require Logger

  @api_version "v1"

  @spec get(Config.t(), String.t()) :: {:ok, term()} | {:error, Error.t()}
  def get(%Config{} = cfg, path) do
    request(cfg, :get, path, nil)
  end

  @spec post(Config.t(), String.t(), map() | list()) :: {:ok, term()} | {:error, Error.t()}
  def post(%Config{} = cfg, path, body) do
    request(cfg, :post, path, body)
  end

  @spec delete(Config.t(), String.t()) :: {:ok, term()} | {:error, Error.t()}
  def delete(%Config{} = cfg, path) do
    request(cfg, :delete, path, nil)
  end

  @spec url(Config.t(), String.t()) :: String.t()
  def url(%Config{base_url: base}, path) do
    base = String.trim_trailing(base, "/")
    path = String.trim_leading(path, "/")
    "#{base}/#{@api_version}/#{path}"
  end

  # ── Private ────────────────────────────────────────────────────────────

  defp request(%Config{} = cfg, method, path, body) do
    full_url = url(cfg, path)
    headers  = build_headers(cfg)
    do_request_with_retry(cfg, method, full_url, headers, body, cfg.retry_attempts)
  end

  defp do_request_with_retry(_cfg, _method, url, _headers, _body, 0) do
    {:error, Error.network("Exhausted all retry attempts for #{url}")}
  end

  defp do_request_with_retry(cfg, method, url, headers, body, attempts_left) do
    req_opts =
      [method: method, url: url, headers: headers, receive_timeout: cfg.timeout]
      |> maybe_put_body(body)

    case Req.request(req_opts) do
      {:ok, %Req.Response{status: s, body: resp_body}} when s in 200..299 ->
        {:ok, resp_body}

      {:ok, %Req.Response{status: s, body: resp_body}} ->
        {:error, Error.from_response(s, resp_body)}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, Error.timeout(url)}

      {:error, %Req.TransportError{} = err} when attempts_left > 1 ->
        Logger.warning("[Alem.Lance] Transport error, retrying (#{attempts_left - 1} left): #{inspect(err)}")
        Process.sleep(cfg.retry_delay_ms)
        do_request_with_retry(cfg, method, url, headers, body, attempts_left - 1)

      {:error, %Req.TransportError{} = err} ->
        {:error, Error.network(inspect(err))}
    end
  end

  defp build_headers(%Config{api_key: nil}),
    do: [{"content-type", "application/json"}]
  defp build_headers(%Config{api_key: key}),
    do: [{"content-type", "application/json"}, {"authorization", "Bearer #{key}"}]

  defp maybe_put_body(opts, nil),  do: opts
  defp maybe_put_body(opts, body), do: Keyword.put(opts, :json, body)
end
