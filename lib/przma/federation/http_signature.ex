defmodule Przma.Federation.HttpSignature do
  @moduledoc """
  HTTP Signature implementation (draft-cavage-http-signatures-12).

  Two functions:
    verify/2 - Validate an inbound request (inbox POST from remote server)
    sign/6   - Sign an outbound request (delivering to remote inbox)

  Supports two algorithms:
    rsa-sha256 - Legacy. Required for Mastodon compatibility.
    ed25519    - Native PRZMA. Used for PRZMA-to-PRZMA delivery.

  Clock skew tolerance: 30 seconds.
  Digest header required on all POST requests.
  """

  require Logger

  @max_clock_skew_seconds 30
  @required_post_headers  ["(request-target)", "host", "date", "digest"]
  @required_get_headers   ["(request-target)", "host", "date"]

  # ── INBOUND VERIFICATION ──────────────────────────────────────────────────

  @doc """
  Verify HTTP Signature on an inbound request.

  Called by InboxController before processing any inbound activity.
  The raw_body must be captured before Plug.Parsers runs (see RawBodyCapture plug).

  Returns :ok or {:error, reason}.
  """
  def verify(conn, raw_body, opts \\ []) do
    with {:ok, sig_params}  <- parse_signature_header(conn),
         :ok                <- check_required_headers(conn.method, sig_params["headers"]),
         :ok                <- check_date_freshness(conn),
         :ok                <- verify_digest(conn.method, raw_body, conn),
         {:ok, public_key}  <- fetch_public_key(sig_params["keyId"], opts),
         {:ok, signing_str} <- build_signing_string(conn, sig_params["headers"], raw_body),
         :ok                <- verify_signature(
                                 signing_str,
                                 sig_params["signature"],
                                 public_key,
                                 sig_params["algorithm"]
                               ) do
      {:ok, sig_params["keyId"]}
    else
      {:error, reason} = err ->
        Logger.warning("[HttpSignature] Verification failed: #{inspect(reason)}")
        err
    end
  end

  # ── OUTBOUND SIGNING ──────────────────────────────────────────────────────

  @doc """
  Sign an outbound HTTP request.

  Returns {:ok, headers_map} with Signature, Date, Digest headers added.

  Use algorithm: :ed25519 for PRZMA-to-PRZMA delivery.
  Use algorithm: :rsa_sha256 for Mastodon / Fediverse compatibility.

  ## Example

      {:ok, headers} = HttpSignature.sign(
        "POST",
        "https://mastodon.social/users/alice/inbox",
        Jason.encode!(payload),
        "did:przma:user:abc#key-assert-1",
        private_key_bytes,
        algorithm: :rsa_sha256
      )
  """
  def sign(method, url, body, key_id, private_key, opts \\ []) do
    algorithm = Keyword.get(opts, :algorithm, :ed25519)
    uri       = URI.parse(url)
    date      = format_http_date(DateTime.utc_now())
    digest    = "SHA-256=" <> Base.encode64(:crypto.hash(:sha256, body))
    path      = uri.path <> if(uri.query, do: "?#{uri.query}", else: "")
    target    = "#{String.downcase(method)} #{path}"

    signed_headers = ["(request-target)", "host", "date", "digest", "content-type"]

    header_map = %{
      "(request-target)" => target,
      "host"             => uri.host,
      "date"             => date,
      "digest"           => digest,
      "content-type"     => "application/activity+json"
    }

    signing_str =
      signed_headers
      |> Enum.map(&"#{&1}: #{Map.fetch!(header_map, &1)}")
      |> Enum.join("\n")

    with {:ok, sig_bytes} <- sign_string(signing_str, private_key, algorithm) do
      sig_b64     = Base.encode64(sig_bytes)
      headers_str = Enum.join(signed_headers, " ")
      alg_str     = if algorithm == :ed25519, do: "ed25519", else: "rsa-sha256"

      sig_header =
        ~s(keyId="#{key_id}",algorithm="#{alg_str}",) <>
        ~s(headers="#{headers_str}",signature="#{sig_b64}")

      {:ok, %{
        "Host"         => uri.host,
        "Date"         => date,
        "Digest"       => digest,
        "Content-Type" => "application/activity+json",
        "Signature"    => sig_header
      }}
    end
  end

  # ── PRIVATE: VERIFY STEPS ─────────────────────────────────────────────────

  defp parse_signature_header(conn) do
    case Plug.Conn.get_req_header(conn, "signature") do
      []        -> {:error, :missing_signature_header}
      [raw | _] -> parse_params(raw)
    end
  end

  defp parse_params(raw) do
    params =
      raw
      |> String.split(",")
      |> Enum.reduce(%{}, fn part, acc ->
        case Regex.run(~r/(\w+)="([^"]*)"/, String.trim(part)) do
          [_, k, v] -> Map.put(acc, k, v)
          _         -> acc
        end
      end)

    required = ["keyId", "headers", "signature"]
    missing  = Enum.filter(required, &(not Map.has_key?(params, &1)))

    if missing == [] do
      headers = String.split(params["headers"] || "", " ")
      {:ok, Map.put(params, "headers", headers)}
    else
      {:error, {:missing_signature_params, missing}}
    end
  end

  defp check_required_headers(method, signed) do
    required =
      if String.upcase(method) == "POST",
        do: @required_post_headers,
        else: @required_get_headers

    missing = Enum.filter(required, &(&1 not in signed))
    if missing == [], do: :ok, else: {:error, {:unsigned_required_headers, missing}}
  end

  # defp check_date_freshness(conn) do
  #   case Plug.Conn.get_req_header(conn, "date") do
  #     [] -> {:error, :missing_date_header}
  #     [date_str | _] ->
  #       with {:ok, naive}    <- Timex.parse(date_str, "{RFC1123}"),
  #            {:ok, req_time} <- DateTime.from_naive(naive, "Etc/UTC") do
  #         skew = abs(DateTime.diff(DateTime.utc_now(), req_time, :second))
  #         if skew <= @max_clock_skew_seconds,
  #           do: :ok,
  #           else: {:error, {:clock_skew_exceeded, skew}}
  #       else
  #         _ -> {:error, {:invalid_date_format, date_str}}
  #       end
  #   end
  # end

  # ADD THESE TWO functions instead:
defp check_date_freshness(conn) do
  case Plug.Conn.get_req_header(conn, "date") do
    [] -> {:error, :missing_date_header}
    [date_str | _] ->
      case parse_http_date(date_str) do
        {:ok, req_time} ->
          skew = abs(DateTime.diff(DateTime.utc_now(), req_time, :second))
          if skew <= @max_clock_skew_seconds,
            do: :ok,
            else: {:error, {:clock_skew_exceeded, skew}}
        :error ->
          {:error, {:invalid_date_format, date_str}}
      end
  end
end

defp parse_http_date(date_str) do
  try do
    case :httpd_util.convert_request_date(String.to_charlist(date_str)) do
      {{year, month, day}, {hour, min, sec}} ->
        {:ok, dt} = DateTime.new(
          Date.new!(year, month, day),
          Time.new!(hour, min, sec),
          "Etc/UTC"
        )
        {:ok, dt}
      :bad_date -> :error
    end
  rescue
    _ -> :error
  end
end

  defp verify_digest("GET", _body, _conn), do: :ok
  defp verify_digest(_method, raw_body, conn) do
    case Plug.Conn.get_req_header(conn, "digest") do
      [] -> {:error, :missing_digest_header}
      [digest_header | _] ->
        computed = "SHA-256=" <> Base.encode64(:crypto.hash(:sha256, raw_body))
        if computed == digest_header, do: :ok, else: {:error, :digest_mismatch}
    end
  end

  defp fetch_public_key(key_id, opts) do
    case Keyword.get(opts, :public_key) do
      nil -> Przma.Federation.ActorKeyCache.get_or_fetch(key_id)
      key -> {:ok, key}
    end
  end

  defp build_signing_string(conn, headers, raw_body) do
    method = String.downcase(conn.method)
    path   = conn.request_path <> if(conn.query_string == "", do: "", else: "?#{conn.query_string}")

    header_map =
      Enum.into(conn.req_headers, %{})
      |> Map.put("(request-target)", "#{method} #{path}")
      |> Map.put("digest", "SHA-256=" <> Base.encode64(:crypto.hash(:sha256, raw_body)))

    lines =
      Enum.map(headers, fn h ->
        "#{String.downcase(h)}: #{Map.get(header_map, String.downcase(h), "")}"
      end)

    {:ok, Enum.join(lines, "\n")}
  end

  defp verify_signature(signing_str, sig_b64, public_key, algorithm) do
    sig_bytes = Base.decode64!(sig_b64, ignore: :whitespace)

    result =
      case normalize_algorithm(algorithm) do
        :rsa_sha256 ->
          rsa_key = decode_pem(public_key)
          :public_key.verify(signing_str, :sha256, sig_bytes, rsa_key)

        :ed25519 ->
          :crypto.verify(:eddsa, :none, signing_str, sig_bytes, [public_key, :ed25519])

        _ ->
          false
      end

    if result, do: :ok, else: {:error, :signature_mismatch}
  end

  # ── PRIVATE: SIGN HELPERS ─────────────────────────────────────────────────

  defp sign_string(str, key, :ed25519) do
    {:ok, :crypto.sign(:eddsa, :none, str, [key, :ed25519])}
  end

  defp sign_string(str, pem, :rsa_sha256) do
    [entry] = :public_key.pem_decode(pem)
    key     = :public_key.pem_entry_decode(entry)
    {:ok, :public_key.sign(str, :sha256, key)}
  end

  defp normalize_algorithm(nil),          do: :rsa_sha256
  defp normalize_algorithm("rsa-sha256"), do: :rsa_sha256
  defp normalize_algorithm("hs2019"),     do: :rsa_sha256
  defp normalize_algorithm("ed25519"),    do: :ed25519
  defp normalize_algorithm(other),        do: other

  defp decode_pem(pem) when is_binary(pem) do
    [entry] = :public_key.pem_decode(pem)
    :public_key.pem_entry_decode(entry)
  end
  defp decode_pem(key), do: key

  defp format_http_date(dt) do
    Calendar.strftime(dt, "%a, %d %b %Y %H:%M:%S GMT")
  end
end
