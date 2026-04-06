defmodule PrzmaWeb.Channels.Chat.DMChannel do
  @moduledoc """
  Direct Message Channel — private 1:1 conversations.

  Topic: "chat:dm:{thread_id}"
  where thread_id = BLAKE3 hash of sorted pair of DIDs

  Events (client → server):
    "message.send"   - Send a new DM
    "message.read"   - Mark messages as read
    "message.delete" - Retract a sent message
    "typing"         - Typing indicator (ephemeral)

  Events (server → client):
    "message.new"    - New message delivered
    "message.read"   - Read receipt from other party
    "message.deleted"- Message retracted
    "typing"         - Typing indicator from other party
  """
  use Phoenix.Channel

  alias Przma.Vault.ContentStore
  alias Przma.Vault.VaultManager
  alias Przma.Federation.Outbox

  def join("chat:dm:" <> thread_id, _params, socket) do
    did = socket.assigns.did

    case verify_thread_participant(thread_id, did) do
      :ok ->
        messages = load_recent_messages(thread_id, did, limit: 30)
        {:ok, %{messages: messages, thread_id: thread_id}, socket}

      {:error, :not_participant} ->
        {:error, %{reason: "You are not a participant in this thread"}}
    end
  end

  def handle_in("message.send", %{"content" => content} = params, socket) do
    sender_did    = socket.assigns.did
    thread_id     = thread_id_from_topic(socket.topic)
    recipient_did = other_participant(thread_id, sender_did)
    message_id    = Uniq.UUID.uuid7()
    ns_path       = "przma://#{sender_did}/vault/private/dm/#{thread_id}/#{message_id}"

    with {:ok, cid} <- ContentStore.store(content, sender_did, ns_path,
                         tier: :private, mime_type: "text/plain"),
         :ok <- write_to_vault(sender_did, thread_id, message_id, cid, params),
         :ok <- Outbox.enqueue(sender_did, :Create,
                  build_note(content, cid, sender_did, recipient_did, params),
                  [recipient_did],
                  tier: :private) do

      broadcast!(socket, "message.new", %{
        message_id:   message_id,
        cas_cid:      cid,
        sender_did:   sender_did,
        content:      content,
        light_signal: params["light_signal"],
        created_at:   DateTime.utc_now() |> DateTime.to_iso8601()
      })

      {:reply, {:ok, %{message_id: message_id, cas_cid: cid}}, socket}
    else
      {:error, reason} ->
        {:reply, {:error, %{reason: inspect(reason)}}, socket}
    end
  end

  def handle_in("typing", _params, socket) do
    broadcast_except(socket, "typing", %{sender_did: socket.assigns.did})
    {:noreply, socket}
  end

  def handle_in("message.read", %{"message_ids" => ids}, socket) do
    did       = socket.assigns.did
    thread_id = thread_id_from_topic(socket.topic)

    mark_messages_read(did, thread_id, ids)

    broadcast_except(socket, "message.read", %{
      reader_did:  did,
      message_ids: ids,
      read_at:     DateTime.utc_now() |> DateTime.to_iso8601()
    })

    {:noreply, socket}
  end

  # ── HELPERS ───────────────────────────────────────────────────────────────

  defp verify_thread_participant(thread_id, did) do
    case VaultManager.query(did,
      "SELECT 1 FROM chat_messages WHERE thread_id = ? LIMIT 1",
      [thread_id]
    ) do
      {:ok, [_]} -> :ok
      {:ok, []}  -> :ok   # New thread — allow join
      {:error, _} -> {:error, :not_participant}
    end
  end

  defp load_recent_messages(thread_id, did, opts) do
    limit = Keyword.get(opts, :limit, 30)

    case VaultManager.query(did, """
      SELECT id, body_enc, body_nonce, sender_did, light_signal,
             delivery_status, created_at
      FROM   chat_messages
      WHERE  thread_id = ?
      ORDER  BY created_at DESC
      LIMIT  ?
    """, [thread_id, limit]) do
      {:ok, rows} -> Enum.map(rows, &decrypt_message(&1, did))
      {:error, _} -> []
    end
  end

  defp write_to_vault(did, thread_id, message_id, cid, params) do
    {:ok, vault_key} = VaultManager.get_vault_key(did)
    nonce            = :crypto.strong_rand_bytes(12)
    {body_enc, tag}  = :crypto.crypto_one_time_aead(
      :aes_256_gcm, vault_key, nonce, params["content"], "", true
    )

    VaultManager.execute(did, """
      INSERT INTO chat_messages
        (id, thread_id, sender_did, recipient_id, body_enc, body_nonce,
         light_signal, ap_activity_id, delivery_status, created_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'sent', datetime('now'))
    """, [
      message_id, thread_id, did,
      other_participant(thread_id, did),
      body_enc <> tag, nonce,
      params["light_signal"],
      cid
    ])
    |> then(fn
      {:ok, _} -> :ok
      err      -> err
    end)
  end

  defp build_note(content, cid, sender_did, recipient_did, params) do
    %{
      "type"      => "Note",
      "content"   => content,
      "cas_proof" => cid,
      "to"        => [Przma.ActivityPub.actor_url(recipient_did)],
      "cc"        => [],
      "tag"       => filter_tags(params)
    }
  end

  defp filter_tags(params) do
    if signal = params["light_signal"] do
      [%{"type" => "Tag", "name" => "##{signal}"}]
    else
      []
    end
  end

  defp decrypt_message(row, did) do
    {:ok, vault_key} = VaultManager.get_vault_key(did)
    body_size  = byte_size(row.body_enc) - 16
    <<ciphertext::binary-size(body_size), tag::binary-16>> = row.body_enc
    decrypted  = :crypto.crypto_one_time_aead(
      :aes_256_gcm, vault_key, row.body_nonce, ciphertext, "", tag, false
    )
    Map.put(row, :content, decrypted)
  end

  defp thread_id_from_topic("chat:dm:" <> thread_id), do: thread_id

  defp other_participant(_thread_id, _my_did), do: "unknown"

  defp mark_messages_read(did, thread_id, ids) do
    VaultManager.execute(did, """
      UPDATE chat_messages
      SET    delivery_status = 'read'
      WHERE  thread_id = ?
        AND  id IN (#{Enum.map(ids, fn _ -> "?" end) |> Enum.join(",")})
    """, [thread_id | ids])
  end
end
