defmodule Alem.Vault.EpochKeyManager do
  @moduledoc """
  GenServer that manages server-side epoch x25519 keypairs.

  ## Design (ATProto-inspired rotating keys)

  Each epoch is a 90-day window.  The server generates a fresh x25519 keypair
  at the start of each epoch.  The public key is published via
  `GET /api/v1/vault/epoch/current` (and in the DID document at
  `/.well-known/did.json`).  Clients use it to wrap per-file encryption keys
  so the server can decrypt vault files for CAS content extraction.

  The epoch private key is encrypted at rest with `EPOCH_MASTER_KEY` (env var)
  using ChaCha20-Poly1305 before being stored in sqld.

  After the grace period (30 days post-rotation), the old epoch private key is
  **permanently deleted** — forward secrecy: a future breach cannot decrypt
  files from that epoch.

  ## sqld table: epoch_keys
    epoch_id            INTEGER PRIMARY KEY
    public_key_b64      TEXT     — base64 x25519 public key (32 bytes)
    enc_private_key_b64 TEXT     — base64(nonce||ciphertext||tag) encrypted private key
    started_at          TEXT     — ISO-8601 epoch start time
    expires_at          TEXT     — ISO-8601 epoch expiry (started_at + 90 days)
    grace_until         TEXT     — ISO-8601 delete private key after this date
    is_current          INTEGER  — 1 for the active epoch, 0 for historical
  """

  use GenServer
  require Logger

  @epoch_days    90
  @grace_days    30
  @check_interval_ms :timer.hours(6)   # check for rotation every 6 hours

  # ── Public API ─────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns {epoch_id, public_key_b64} for the current epoch."
  def current_public_key do
    GenServer.call(__MODULE__, :current_public_key)
  end

  @doc """
  Decrypts the per-file key from a vault v2 server_wrapped_key blob.

  `epoch_id`          — from vault header or upload metadata
  `ephemeral_pub_b64` — base64 x25519 public key from vault header (bytes 17-48)
  `server_wrapped_b64`— base64 of [12-byte nonce][48-byte encrypted file_key]
                        from vault header (bytes 121-168)

  Returns {:ok, file_key_binary} or {:error, reason}.
  """
  def decrypt_file_key(epoch_id, ephemeral_pub_b64, server_wrapped_b64) do
    GenServer.call(__MODULE__, {:decrypt_file_key, epoch_id, ephemeral_pub_b64, server_wrapped_b64})
  end

  # ── GenServer callbacks ────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    sqld_url = Application.get_env(:alem, :sqld_url, "http://172.235.17.68:8080")
    state = load_or_generate_epoch(sqld_url)
    :timer.send_interval(@check_interval_ms, :check_rotation)
    Logger.info("[EpochKeyManager] Started — current epoch_id=#{state.current_epoch_id}")
    {:ok, state}
  end

  @impl true
  def handle_call(:current_public_key, _from, state) do
    {:reply, {:ok, state.current_epoch_id, state.current_public_key_b64}, state}
  end

  @impl true
  def handle_call({:decrypt_file_key, epoch_id, ephemeral_pub_b64, server_wrapped_b64}, _from, state) do
    result =
      case Map.get(state.epoch_private_keys, epoch_id) do
        nil ->
          Logger.warning("[EpochKeyManager] Unknown epoch_id=#{epoch_id} (key may be expired)")
          {:error, "No epoch private key for epoch #{epoch_id}"}

        enc_private_b64 ->
          do_decrypt_file_key(enc_private_b64, ephemeral_pub_b64, server_wrapped_b64)
      end

    {:reply, result, state}
  end

  @impl true
  def handle_info(:check_rotation, state) do
    sqld_url = Application.get_env(:alem, :sqld_url, "http://172.235.17.68:8080")
    new_state = maybe_rotate(state, sqld_url)
    {:noreply, new_state}
  end

  # ── Epoch lifecycle ────────────────────────────────────────────────────

  defp load_or_generate_epoch(sqld_url) do
    case load_current_epoch_from_sqld(sqld_url) do
      {:ok, epoch_data} ->
        Logger.info("[EpochKeyManager] Loaded epoch_id=#{epoch_data.current_epoch_id} from sqld")
        epoch_data

      {:error, reason} ->
        Logger.info("[EpochKeyManager] No epoch in sqld (#{inspect(reason)}) — generating new one")
        generate_and_store_epoch(sqld_url)
    end
  end

  defp maybe_rotate(state, sqld_url) do
    expires_at = state.current_expires_at

    if DateTime.compare(DateTime.utc_now(), expires_at) == :gt do
      Logger.info("[EpochKeyManager] Epoch #{state.current_epoch_id} expired — rotating")
      new_state = generate_and_store_epoch(sqld_url)
      expire_old_epoch(state.current_epoch_id, sqld_url)
      new_state
    else
      state
    end
  end

  defp generate_and_store_epoch(sqld_url) do
    # Generate x25519 keypair using Erlang :crypto
    {public_key, private_key} = :crypto.generate_key(:ecdh, :x25519)

    epoch_id    = compute_epoch_id()
    started_at  = DateTime.utc_now()
    expires_at  = DateTime.add(started_at, @epoch_days * 86_400, :second)
    grace_until = DateTime.add(expires_at, @grace_days  * 86_400, :second)

    # Encrypt private key at rest with server master key
    master_key      = server_master_key()
    nonce           = :crypto.strong_rand_bytes(12)
    {ciphertext, tag} = :crypto.crypto_one_time_aead(
      :chacha20_poly1305, master_key, nonce, private_key, "", true
    )
    enc_private_b64 = Base.encode64(nonce <> ciphertext <> tag)
    public_key_b64  = Base.encode64(public_key)

    # Persist to sqld
    store_epoch_key(sqld_url, %{
      epoch_id:            epoch_id,
      public_key_b64:      public_key_b64,
      enc_private_key_b64: enc_private_b64,
      started_at:          DateTime.to_iso8601(started_at),
      expires_at:          DateTime.to_iso8601(expires_at),
      grace_until:         DateTime.to_iso8601(grace_until),
    })

    Logger.info("[EpochKeyManager] ✅ Generated epoch_id=#{epoch_id}, expires #{DateTime.to_iso8601(expires_at)}")

    %{
      current_epoch_id:      epoch_id,
      current_public_key_b64: public_key_b64,
      current_expires_at:    expires_at,
      epoch_private_keys:    %{epoch_id => enc_private_b64},
    }
  end

  # Permanently delete private key for expired epoch (forward secrecy)
  defp expire_old_epoch(epoch_id, sqld_url) do
    sql = "UPDATE epoch_keys SET enc_private_key_b64 = NULL, is_current = 0 WHERE epoch_id = ?"
    sqld_execute(sql, [epoch_id], sqld_url)
    Logger.info("[EpochKeyManager] 🗑️  Epoch #{epoch_id} private key deleted (forward secrecy)")
  end

  # ── Crypto: decrypt file key from vault v2 server_wrapped_key ─────────

  defp do_decrypt_file_key(enc_private_b64, ephemeral_pub_b64, server_wrapped_b64) do
    with {:ok, enc_private}    <- Base.decode64(enc_private_b64),
         {:ok, ephemeral_pub}  <- Base.decode64(ephemeral_pub_b64),
         {:ok, server_wrapped} <- Base.decode64(server_wrapped_b64)
    do
      Logger.debug("[EpochKeyManager] ephemeral_pub length: #{byte_size(ephemeral_pub)}")
      Logger.debug("[EpochKeyManager] server_wrapped length: #{byte_size(server_wrapped)}")
      
      # 1. Unwrap epoch private key
      <<priv_nonce::binary-12, priv_rest::binary>> = enc_private
      data_len = byte_size(priv_rest) - 16
      <<priv_ciphertext::binary-size(data_len), priv_tag::binary-16>> = priv_rest

      master_key   = server_master_key()
      case :crypto.crypto_one_time_aead(
        :chacha20_poly1305, master_key, priv_nonce, priv_ciphertext, "", priv_tag, false
      ) do
        :error -> 
          Logger.error("[EpochKeyManager] Master key failed to decrypt epoch private key! Check EPOCH_MASTER_KEY.")
          {:error, :master_key_decrypt_failed}

        epoch_private ->
          # 2. ECDH: epoch_private × ephemeral_public → shared_secret
          # Note: epoch_private is the actual raw private key bytes
          shared_secret = :crypto.compute_key(:ecdh, ephemeral_pub, epoch_private, :x25519)
          Logger.debug("[EpochKeyManager] shared_secret derived (32 bytes)")

          # 3. HKDF-SHA256
          server_wrap_key = hkdf_expand_sha256(shared_secret, "przma-vault-server-v2", 32)
          Logger.debug("[EpochKeyManager] server_wrap_key expanded")

          # 4. Unwrap file_key from server_wrapped_key
          <<key_nonce::binary-12, key_rest::binary>> = server_wrapped
          key_data_len = byte_size(key_rest) - 16
          <<key_ciphertext::binary-size(key_data_len), key_tag::binary-16>> = key_rest

          case :crypto.crypto_one_time_aead(
            :chacha20_poly1305, server_wrap_key, key_nonce, key_ciphertext, "", key_tag, false
          ) do
            :error -> 
               Logger.error("[EpochKeyManager] Failed to decrypt file key! Possible epoch key mismatch or HKDF drift.")
               {:error, :file_key_decrypt_failed}
            file_key ->
               Logger.info("[EpochKeyManager] Successfully decrypted file key (32 bytes)")
               {:ok, file_key}
          end
      end
    else
      :error       -> {:error, "base64 decode failed"}
      error        -> {:error, "decrypt_file_key failed: #{inspect(error)}"}
    end
  end

  # ── HKDF-SHA256 (matches Rust hkdf crate with None salt) ──────────────
  # HKDF-Extract: PRK = HMAC-SHA256(salt = 0x00×32, IKM)
  # HKDF-Expand:  T(1) = HMAC-SHA256(PRK, info || 0x01), truncate to `length`
  defp hkdf_expand_sha256(ikm, info, length) when length <= 32 do
    salt = :binary.copy(<<0>>, 32)
    prk  = :crypto.mac(:hmac, :sha256, salt, ikm)
    okm  = :crypto.mac(:hmac, :sha256, prk, info <> <<1>>)
    binary_part(okm, 0, length)
  end

  # ── Server master key ──────────────────────────────────────────────────
  defp server_master_key do
    key_b64 =
      System.get_env("EPOCH_MASTER_KEY") ||
      Application.get_env(:alem, :epoch_master_key) ||
      raise "EPOCH_MASTER_KEY env var must be set (32 random bytes, base64-encoded)"

    case Base.decode64(key_b64) do
      {:ok, key} when byte_size(key) == 32 -> key
      _ -> raise "EPOCH_MASTER_KEY must be exactly 32 bytes base64-encoded"
    end
  end

  # ── epoch_id: seconds-since-epoch ÷ epoch_duration_seconds ───────────
  defp compute_epoch_id do
    div(System.os_time(:second), @epoch_days * 86_400)
  end

  # ── sqld helpers ───────────────────────────────────────────────────────

  defp load_current_epoch_from_sqld(sqld_url) do
    sql = """
    SELECT epoch_id, public_key_b64, enc_private_key_b64, expires_at
    FROM epoch_keys
    WHERE is_current = 1
    ORDER BY epoch_id DESC
    LIMIT 1
    """
    case sqld_query(sql, [], sqld_url) do
      {:ok, [%{"epoch_id" => epoch_id, "public_key_b64" => pub_b64,
               "enc_private_key_b64" => enc_priv_b64, "expires_at" => exp_str}]} ->
        {:ok, expires_at, _offset} = DateTime.from_iso8601(exp_str)
        {:ok, %{
          current_epoch_id:       epoch_id,
          current_public_key_b64: pub_b64,
          current_expires_at:     expires_at,
          epoch_private_keys:     %{epoch_id => enc_priv_b64},
        }}

      {:ok, []} ->
        {:error, :no_current_epoch}

      error ->
        {:error, error}
    end
  end

  defp store_epoch_key(sqld_url, attrs) do
    # Mark all existing epochs as not current
    sqld_execute("UPDATE epoch_keys SET is_current = 0", [], sqld_url)

    sql = """
    INSERT INTO epoch_keys
      (epoch_id, public_key_b64, enc_private_key_b64, started_at, expires_at, grace_until, is_current)
    VALUES (?, ?, ?, ?, ?, ?, 1)
    ON CONFLICT(epoch_id) DO UPDATE SET
      public_key_b64      = excluded.public_key_b64,
      enc_private_key_b64 = excluded.enc_private_key_b64,
      is_current          = 1
    """
    sqld_execute(sql, [
      attrs.epoch_id, attrs.public_key_b64, attrs.enc_private_key_b64,
      attrs.started_at, attrs.expires_at, attrs.grace_until,
    ], sqld_url)
  end

  # ── sqld HTTP client (same pattern as SyncController) ─────────────────

  defp sqld_execute(sql, args, sqld_url) do
    body = Jason.encode!(%{
      requests: [
        %{type: "execute", stmt: %{sql: sql, args: Enum.map(args, &encode_arg/1)}},
        %{type: "close"}
      ]
    })

    case Req.post("#{sqld_url}/v3/pipeline",
           body: body,
           headers: [{"content-type", "application/json"}],
           receive_timeout: 10_000) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: s}}   -> {:error, {:http, s}}
      {:error, reason}      -> {:error, reason}
    end
  end

  defp sqld_query(sql, args, sqld_url) do
    body = Jason.encode!(%{
      requests: [
        %{type: "execute", stmt: %{sql: sql, args: Enum.map(args, &encode_arg/1)}},
        %{type: "close"}
      ]
    })

    case Req.post("#{sqld_url}/v3/pipeline",
           body: body,
           headers: [{"content-type", "application/json"}],
           receive_timeout: 10_000) do
      {:ok, %{status: 200, body: %{"results" => [%{"response" => %{"result" => result}} | _]}}} ->
        cols = Enum.map(result["cols"], & &1["name"])
        rows = Enum.map(result["rows"], fn row ->
          cols
          |> Enum.zip(Enum.map(row, &decode_sqld_value/1))
          |> Map.new()
        end)
        {:ok, rows}

      {:ok, %{status: s, body: b}} -> {:error, {:http, s, b}}
      {:error, reason}             -> {:error, reason}
    end
  end

  defp encode_arg(nil),                   do: %{"type" => "null",    "value" => nil}
  defp encode_arg(v) when is_integer(v),  do: %{"type" => "integer", "value" => to_string(v)}
  defp encode_arg(v) when is_binary(v),   do: %{"type" => "text",    "value" => v}
  defp encode_arg(v),                     do: %{"type" => "text",    "value" => to_string(v)}

  defp decode_sqld_value(%{"type" => "integer", "value" => v}), do: String.to_integer(v)
  defp decode_sqld_value(%{"type" => "text",    "value" => v}), do: v
  defp decode_sqld_value(%{"type" => "null"}),                  do: nil
  defp decode_sqld_value(v),                                    do: v
end
