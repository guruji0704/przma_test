defmodule Alem.Vault.EpochKeyManager do
  @moduledoc """
  GenServer that manages server-side epoch x25519 keypairs.

  Each epoch is a 90-day window. The server generates a fresh x25519 keypair
  at the start of each epoch. Stored in LanceDB.
  """

  use GenServer
  require Logger

  @epoch_days    90
  @grace_days    30
  @check_interval_ms :timer.hours(6)

  # ── Public API ─────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def current_public_key do
    GenServer.call(__MODULE__, :current_public_key)
  end

  def decrypt_file_key(epoch_id, ephemeral_pub_b64, server_wrapped_b64) do
    GenServer.call(__MODULE__, {:decrypt_file_key, epoch_id, ephemeral_pub_b64, server_wrapped_b64})
  end

  # ── GenServer callbacks ────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    state = load_or_generate_epoch()
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
          Logger.warning("[EpochKeyManager] Unknown epoch_id=#{epoch_id}")
          {:error, "No epoch private key for epoch #{epoch_id}"}
        enc_private_b64 ->
          do_decrypt_file_key(enc_private_b64, ephemeral_pub_b64, server_wrapped_b64)
      end
    {:reply, result, state}
  end

  @impl true
  def handle_info(:check_rotation, state) do
    new_state = maybe_rotate(state)
    {:noreply, new_state}
  end

  # ── Epoch lifecycle ────────────────────────────────────────────────────

  defp load_or_generate_epoch do
    case load_current_from_lancedb() do
      {:ok, data} -> data
      _ -> generate_and_store_epoch()
    end
  end

  defp maybe_rotate(state) do
    if DateTime.compare(DateTime.utc_now(), state.current_expires_at) == :gt do
      Logger.info("[EpochKeyManager] Rotating epoch #{state.current_epoch_id}")
      new_state = generate_and_store_epoch()
      expire_old_epoch(state.current_epoch_id)
      new_state
    else
      state
    end
  end

  defp generate_and_store_epoch do
    {public_key, private_key} = :crypto.generate_key(:ecdh, :x25519)
    epoch_id = div(System.os_time(:second), @epoch_days * 86_400)
    started_at = DateTime.utc_now()
    expires_at = DateTime.add(started_at, @epoch_days * 86_400, :second)
    grace_until = DateTime.add(expires_at, @grace_days * 86_400, :second)

    master_key = server_master_key()
    nonce = :crypto.strong_rand_bytes(12)
    {ciphertext, tag} = :crypto.crypto_one_time_aead(:chacha20_poly1305, master_key, nonce, private_key, "", true)
    enc_private_b64 = Base.encode64(nonce <> ciphertext <> tag)
    public_key_b64 = Base.encode64(public_key)

    Alem.LanceDB.delete("epoch_keys", "is_current = 1")
    Alem.LanceDB.insert_json("epoch_keys", Jason.encode!(%{
      "epoch_id" => epoch_id,
      "public_key_b64" => public_key_b64,
      "enc_private_key_b64" => enc_private_b64,
      "started_at" => DateTime.to_iso8601(started_at),
      "expires_at" => DateTime.to_iso8601(expires_at),
      "grace_until" => DateTime.to_iso8601(grace_until),
      "is_current" => 1
    }))

    %{
      current_epoch_id: epoch_id,
      current_public_key_b64: public_key_b64,
      current_expires_at: expires_at,
      epoch_private_keys: %{epoch_id => enc_private_b64}
    }
  end

  defp load_current_from_lancedb do
    case Alem.LanceDB.query("epoch_keys", "is_current = 1", 1) do
      json when is_binary(json) ->
        case Jason.decode(json) do
          {:ok, [row | _]} ->
            epoch_id = row["epoch_id"]
            {:ok, expires_at, _} = DateTime.from_iso8601(row["expires_at"])
            {:ok, %{
              current_epoch_id: epoch_id,
              current_public_key_b64: row["public_key_b64"],
              current_expires_at: expires_at,
              epoch_private_keys: %{epoch_id => row["enc_private_key_b64"]}
            }}
          _ -> :error
        end
      _ -> :error
    end
  end

  defp expire_old_epoch(epoch_id) do
    Alem.LanceDB.delete("epoch_keys", "epoch_id = #{epoch_id}")
  end

  # ── Crypto Logic ──────────────────────────────────────────────────────

  defp do_decrypt_file_key(enc_private_b64, ephemeral_pub_b64, server_wrapped_b64) do
    with {:ok, enc_private} <- Base.decode64(enc_private_b64),
         {:ok, ephemeral_pub} <- Base.decode64(ephemeral_pub_b64),
         {:ok, server_wrapped} <- Base.decode64(server_wrapped_b64) do
      <<priv_nonce::12-binary, priv_rest::binary>> = enc_private
      data_len = byte_size(priv_rest) - 16
      <<priv_ciphertext::size(data_len)-binary, priv_tag::16-binary>> = priv_rest

      master_key = server_master_key()
      case :crypto.crypto_one_time_aead(:chacha20_poly1305, master_key, priv_nonce, priv_ciphertext, "", priv_tag, false) do
        :error -> {:error, :master_key_decrypt_failed}
        epoch_private ->
          shared_secret = :crypto.compute_key(:ecdh, ephemeral_pub, epoch_private, :x25519)
          server_wrap_key = hkdf_expand_sha256(shared_secret, "przma-vault-server-v2", 32)
          
          <<key_nonce::12-binary, key_rest::binary>> = server_wrapped
          key_data_len = byte_size(key_rest) - 16
          <<key_ciphertext::size(key_data_len)-binary, key_tag::16-binary>> = key_rest
          
          case :crypto.crypto_one_time_aead(:chacha20_poly1305, server_wrap_key, key_nonce, key_ciphertext, "", key_tag, false) do
            :error -> {:error, :file_key_decrypt_failed}
            file_key -> {:ok, file_key}
          end
      end
    else
      _ -> {:error, "base64/crypto failure"}
    end
  end

  defp hkdf_expand_sha256(ikm, info, length) do
    salt = :binary.copy(<<0>>, 32)
    prk = :crypto.mac(:hmac, :sha256, salt, ikm)
    okm = :crypto.mac(:hmac, :sha256, prk, info <> <<1>>)
    binary_part(okm, 0, length)
  end

  defp server_master_key do
    (System.get_env("EPOCH_MASTER_KEY") || Application.get_env(:alem, :epoch_master_key))
    |> Base.decode64!()
  end
end
