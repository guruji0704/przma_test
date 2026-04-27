defmodule Alem.Vault.EpochKeyManager do
  @moduledoc """
  GenServer that manages server-side epoch x25519 keypairs.

  Each epoch is a 90-day window. The server generates a fresh x25519 keypair
  at the start of each epoch. The public key is published via
  GET /api/v1/vault/epoch/current.

  Clients use the public key to wrap per-file encryption keys so the server
  can decrypt vault files for CAS content extraction.

  The epoch private key is encrypted at rest with EPOCH_MASTER_KEY (env var)
  using ChaCha20-Poly1305.

  Storage: PostgreSQL epoch_keys table (was: sqld).
  """

  use GenServer
  require Logger
  import Ecto.Query

  alias Alem.Repo
  alias Alem.Vault.EpochKey

  @epoch_days         90
  @grace_days         30
  @check_interval_ms  :timer.hours(6)

  # ── Public API ──────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns {:ok, epoch_id, public_key_b64} for the current epoch."
  def current_public_key do
    GenServer.call(__MODULE__, :current_public_key)
  end

  @doc """
  Decrypts the per-file key from a vault v2 server_wrapped_key blob.
  Returns {:ok, file_key_binary} or {:error, reason}.
  """
  def decrypt_file_key(epoch_id, ephemeral_pub_b64, server_wrapped_b64) do
    GenServer.call(__MODULE__, {:decrypt_file_key, epoch_id, ephemeral_pub_b64, server_wrapped_b64})
  end

  # ── GenServer callbacks ─────────────────────────────────────────────────

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
          Logger.warning("[EpochKeyManager] Unknown epoch_id=#{epoch_id} — loading from DB")
          case load_epoch_private_key(epoch_id) do
            {:ok, enc_priv_b64} ->
              do_decrypt_file_key(enc_priv_b64, ephemeral_pub_b64, server_wrapped_b64)
            {:error, _} ->
              {:error, "No epoch private key for epoch #{epoch_id}"}
          end

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

  # ── Epoch lifecycle ─────────────────────────────────────────────────────

  defp load_or_generate_epoch do
    case load_current_epoch_from_pg() do
      {:ok, epoch_data} ->
        Logger.info("[EpochKeyManager] Loaded epoch_id=#{epoch_data.current_epoch_id} from PostgreSQL")
        epoch_data

      {:error, reason} ->
        Logger.info("[EpochKeyManager] No epoch in PostgreSQL (#{inspect(reason)}) — generating new one")
        generate_and_store_epoch()
    end
  end

  defp maybe_rotate(state) do
    if DateTime.compare(DateTime.utc_now(), state.current_expires_at) == :gt do
      Logger.info("[EpochKeyManager] Epoch #{state.current_epoch_id} expired — rotating")
      new_state = generate_and_store_epoch()
      expire_old_epoch(state.current_epoch_id)
      new_state
    else
      state
    end
  end

  defp generate_and_store_epoch do
    {public_key, private_key} = :crypto.generate_key(:ecdh, :x25519)

    epoch_id    = compute_epoch_id()
    started_at  = DateTime.utc_now() |> DateTime.truncate(:second)
    expires_at  = DateTime.add(started_at, @epoch_days * 86_400, :second)
    grace_until = DateTime.add(expires_at, @grace_days * 86_400, :second)

    master_key        = server_master_key()
    nonce             = :crypto.strong_rand_bytes(12)
    {ciphertext, tag} = :crypto.crypto_one_time_aead(
      :chacha20_poly1305, master_key, nonce, private_key, "", true
    )
    enc_private_b64 = Base.encode64(nonce <> ciphertext <> tag)
    public_key_b64  = Base.encode64(public_key)

    # Mark all existing epochs as not current
    Repo.update_all(EpochKey, set: [is_current: false])

    # Insert or update this epoch
    Repo.insert!(
      %EpochKey{
        epoch_id:            epoch_id,
        public_key_b64:      public_key_b64,
        enc_private_key_b64: enc_private_b64,
        started_at:          started_at,
        expires_at:          expires_at,
        grace_until:         grace_until,
        is_current:          true,
      },
      on_conflict: {:replace, [:public_key_b64, :enc_private_key_b64, :is_current]},
      conflict_target: :epoch_id
    )

    Logger.info("[EpochKeyManager] ✅ Generated epoch_id=#{epoch_id}, expires #{DateTime.to_iso8601(expires_at)}")

    %{
      current_epoch_id:       epoch_id,
      current_public_key_b64: public_key_b64,
      current_expires_at:     expires_at,
      epoch_private_keys:     %{epoch_id => enc_private_b64},
    }
  end

  defp expire_old_epoch(epoch_id) do
    Repo.update_all(
      from(e in EpochKey, where: e.epoch_id == ^epoch_id),
      set: [enc_private_key_b64: nil, is_current: false]
    )
    Logger.info("[EpochKeyManager] 🗑️  Epoch #{epoch_id} private key deleted (forward secrecy)")
  end

  # ── PostgreSQL helpers ──────────────────────────────────────────────────

  defp load_current_epoch_from_pg do
    case Repo.one(from e in EpochKey, where: e.is_current == true, order_by: [desc: e.epoch_id], limit: 1) do
      nil ->
        {:error, :no_current_epoch}

      %EpochKey{} = e ->
        {:ok, %{
          current_epoch_id:       e.epoch_id,
          current_public_key_b64: e.public_key_b64,
          current_expires_at:     e.expires_at,
          epoch_private_keys:     %{e.epoch_id => e.enc_private_key_b64},
        }}
    end
  end

  defp load_epoch_private_key(epoch_id) do
    case Repo.one(from e in EpochKey, where: e.epoch_id == ^epoch_id, select: e.enc_private_key_b64) do
      nil -> {:error, :not_found}
      key -> {:ok, key}
    end
  end

  # ── Crypto helpers (unchanged) ──────────────────────────────────────────

  defp do_decrypt_file_key(enc_private_b64, ephemeral_pub_b64, server_wrapped_b64) do
    with {:ok, enc_private}    <- Base.decode64(enc_private_b64),
         {:ok, ephemeral_pub}  <- Base.decode64(ephemeral_pub_b64),
         {:ok, server_wrapped} <- Base.decode64(server_wrapped_b64) do

      <<priv_nonce::binary-12, priv_rest::binary>> = enc_private
      data_len = byte_size(priv_rest) - 16
      <<priv_ciphertext::binary-size(data_len), priv_tag::binary-16>> = priv_rest

      master_key = server_master_key()
      case :crypto.crypto_one_time_aead(
        :chacha20_poly1305, master_key, priv_nonce, priv_ciphertext, "", priv_tag, false
      ) do
        :error ->
          Logger.error("[EpochKeyManager] Master key failed to decrypt epoch private key!")
          {:error, :master_key_decrypt_failed}

        epoch_private ->
          shared_secret   = :crypto.compute_key(:ecdh, ephemeral_pub, epoch_private, :x25519)
          server_wrap_key = hkdf_expand_sha256(shared_secret, "przma-vault-server-v2", 32)

          <<key_nonce::binary-12, key_rest::binary>> = server_wrapped
          key_data_len = byte_size(key_rest) - 16
          <<key_ciphertext::binary-size(key_data_len), key_tag::binary-16>> = key_rest

          case :crypto.crypto_one_time_aead(
            :chacha20_poly1305, server_wrap_key, key_nonce, key_ciphertext, "", key_tag, false
          ) do
            :error ->
              Logger.error("[EpochKeyManager] Failed to decrypt file key!")
              {:error, :file_key_decrypt_failed}
            file_key ->
              Logger.info("[EpochKeyManager] ✅ File key decrypted successfully")
              {:ok, file_key}
          end
      end
    else
      :error -> {:error, "base64 decode failed"}
      error  -> {:error, "decrypt_file_key failed: #{inspect(error)}"}
    end
  end

  defp hkdf_expand_sha256(ikm, info, length) when length <= 32 do
    salt = :binary.copy(<<0>>, 32)
    prk  = :crypto.mac(:hmac, :sha256, salt, ikm)
    okm  = :crypto.mac(:hmac, :sha256, prk, info <> <<1>>)
    binary_part(okm, 0, length)
  end

  defp server_master_key do
    key_b64 =
      System.get_env("EPOCH_MASTER_KEY") ||
      Application.get_env(:alem, :epoch_master_key) ||
      raise "EPOCH_MASTER_KEY env var must be set"

    case Base.decode64(key_b64) do
      {:ok, key} when byte_size(key) == 32 -> key
      _ -> raise "EPOCH_MASTER_KEY must be exactly 32 bytes base64-encoded"
    end
  end

  defp compute_epoch_id do
    div(System.os_time(:second), @epoch_days * 86_400)
  end
end
