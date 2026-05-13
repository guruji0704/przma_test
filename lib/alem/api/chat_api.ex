defmodule Alem.Api.ChatApi do
  @moduledoc """
  Chat API. ChatLive calls this — no business logic in LiveView.
  """

  alias Alem.{Chat, Repo}
  alias Alem.Api.UploadApi
  alias Alem.Schemas.{Message, PerceptionLink}

  @doc "Send a text message"
  def send_message(conversation_id, sender_did, body) do
    Chat.send_message(conversation_id, sender_did, body)
  end

  @doc "Upload file in chat — random vault assignment"
  def upload_file(user, conversation_id, file_params) do
    did = user.did_id

    # Random vault: 0=personal, 1=private, 2=public
    vault_num  = :rand.uniform(3) - 1
    vault_name = %{0 => :personal, 1 => :private, 2 => :public}[vault_num]

    # Build chat-specific file params with chat path
    chat_params = Map.put(file_params, :conversation_id, conversation_id)

    case UploadApi.upload(user, vault_name, chat_params) do
      {:ok, %{doc: doc, hash: hash}} ->
        # Create perception link for the conversation
        now = DateTime.utc_now() |> DateTime.truncate(:second)
        {:ok, link} = Repo.insert(%PerceptionLink{
          link_type:       "circle",
          content_hash:    hash,
          document_id:     doc.id,
          owner_did:       did,
          issuer_did:      did,
          conversation_id: conversation_id,
          can_forward:     false,
          forward_depth:   0,
          scope:           "read",
          expires_at:      DateTime.add(now, 30 * 86_400, :second)
        })

        {:ok, msg} = Repo.insert(%Message{
          conversation_id:    conversation_id,
          sender_did:         did,
          content_type:       "perception_link",
          body:               file_params.filename,
          perception_link_id: link.id,
          sent_at:            now
        })

        Phoenix.PubSub.broadcast(
          Alem.PubSub,
          "conversation:#{conversation_id}",
          {:new_message, msg}
        )

        flash = "✅ #{file_params.filename} → vault #{vault_num} (#{vault_name})"
        {:ok, %{message: msg, link: link, vault_num: vault_num, vault_name: vault_name, flash: flash}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Delete message for me"
  def delete_for_me(message_id, did), do: Chat.delete_for_me(message_id, did)

  @doc "Delete message for everyone"
  def delete_for_everyone(message_id, did), do: Chat.delete_for_everyone(message_id, did)

  @doc "Load messages for a conversation"
  def load_messages(conversation_id, did, opts \\ []) do
    Chat.load_messages(conversation_id, did, opts)
  end

  @doc "Mark conversation as read"
  def mark_read(conversation_id, did), do: Chat.mark_read(conversation_id, did)
end
