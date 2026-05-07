defmodule Alem.Chat do
  @moduledoc """
  Chat system — Direct Messages and Group Chats.
  All messages stored in private vault namespace.
  Files shared in chat use perception links — never copies.
  """

  import Ecto.Query
  alias Alem.{Repo, DID}
  alias Alem.Schemas.{Conversation, ConversationMember, Message, PerceptionLink}
  alias Alem.Pleroma.User
  alias Alem.Social
  require Logger

  # ── Direct Message ────────────────────────────────────────────────────────

  @doc """
  Get or create a DM between two connected users.
  Returns {:ok, conversation} or {:error, reason}
  """
  def get_or_create_dm(did_a, did_b) do
    # Must be connected to chat
    unless Social.connection_status(did_a, did_b) == :accepted do
      {:error, :not_connected}
    else
      # Check if DM already exists
      existing = find_direct_conversation(did_a, did_b)

      if existing do
        {:ok, existing}
      else
        create_direct_conversation(did_a, did_b)
      end
    end
  end

  defp find_direct_conversation(did_a, did_b) do
    Repo.one(
      from c in Conversation,
      join: m1 in ConversationMember, on: m1.conversation_id == c.id,
      join: m2 in ConversationMember, on: m2.conversation_id == c.id,
      where: c.type == "direct" and
             m1.member_did == ^did_a and is_nil(m1.left_at) and
             m2.member_did == ^did_b and is_nil(m2.left_at),
      limit: 1
    )
  end

  defp create_direct_conversation(did_a, did_b) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    prefix_a = DID.namespace_key(did_a)
    ns_key   = "dm-#{prefix_a}-#{String.slice(DID.namespace_key(did_b), 0, 8)}"

    Repo.transaction(fn ->
      {:ok, conv} =
        %Conversation{}
        |> Conversation.changeset(%{
          type:           "direct",
          created_by_did: did_a,
          namespace_key:  ns_key,
          member_count:   2
        })
        |> Repo.insert()

      # Add both members
      for did <- [did_a, did_b] do
        %ConversationMember{}
        |> ConversationMember.changeset(%{
          conversation_id: conv.id,
          member_did:      did,
          role:            "member",
          joined_at:       now
        })
        |> Repo.insert!()
      end

      conv
    end)
  end

  # ── Group Chat ────────────────────────────────────────────────────────────

  @doc """
  Create a group chat.
  creator_did becomes admin. member_dids are added as members.
  """
  def create_group(creator_did, name, member_dids, opts \\ []) do
    description = Keyword.get(opts, :description)
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    prefix = DID.namespace_key(creator_did)
    ns_key = "group-#{prefix}-#{Ecto.UUID.generate() |> String.slice(0, 8)}"

    Repo.transaction(fn ->
      {:ok, conv} =
        %Conversation{}
        |> Conversation.changeset(%{
          type:           "group",
          name:           name,
          description:    description,
          created_by_did: creator_did,
          namespace_key:  ns_key,
          member_count:   length(member_dids) + 1
        })
        |> Repo.insert()

      # Add creator as admin
      %ConversationMember{}
      |> ConversationMember.changeset(%{
        conversation_id: conv.id,
        member_did:      creator_did,
        role:            "admin",
        joined_at:       now
      })
      |> Repo.insert!()

      # Add all other members
      for did <- Enum.uniq(member_dids) -- [creator_did] do
        %ConversationMember{}
        |> ConversationMember.changeset(%{
          conversation_id: conv.id,
          member_did:      did,
          role:            "member",
          joined_at:       now
        })
        |> Repo.insert!()
      end

      conv
    end)
  end

  @doc "Add a member to a group. Only admins can do this."
  def add_member(conversation_id, adder_did, new_member_did) do
    with :ok    <- assert_admin(conversation_id, adder_did),
         :ok    <- assert_not_member(conversation_id, new_member_did) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      result =
        %ConversationMember{}
        |> ConversationMember.changeset(%{
          conversation_id: conversation_id,
          member_did:      new_member_did,
          role:            "member",
          joined_at:       now
        })
        |> Repo.insert()

      # Update member count
      Repo.update_all(
        from(c in Conversation, where: c.id == ^conversation_id),
        inc: [member_count: 1]
      )

      result
    end
  end

  @doc "Remove a member from a group. Admin can remove anyone. Member can remove self."
  def remove_member(conversation_id, actor_did, target_did) do
    is_self   = actor_did == target_did
    is_admin  = member_role(conversation_id, actor_did) == "admin"

    if is_self or is_admin do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.update_all(
        from(m in ConversationMember,
          where: m.conversation_id == ^conversation_id and
                 m.member_did == ^target_did and
                 is_nil(m.left_at)),
        set: [left_at: now]
      )

      Repo.update_all(
        from(c in Conversation, where: c.id == ^conversation_id),
        inc: [member_count: -1]
      )

      :ok
    else
      {:error, :not_authorized}
    end
  end

  # ── Messages ──────────────────────────────────────────────────────────────

  @doc "Send a text message."
  def send_message(conversation_id, sender_did, body) do
    with :ok <- assert_member(conversation_id, sender_did) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      result =
        %Message{}
        |> Message.changeset(%{
          conversation_id: conversation_id,
          sender_did:      sender_did,
          content_type:    "text",
          body:            body,
          sent_at:         now
        })
        |> Repo.insert()

      # Broadcast to all members via PubSub
      case result do
        {:ok, msg} ->
          broadcast_message(conversation_id, msg)
          {:ok, msg}
        err -> err
      end
    end
  end

  @doc "Send a file via perception link in chat."
  def send_file_link(conversation_id, sender_did, document_id, opts \\ []) do
    with :ok <- assert_member(conversation_id, sender_did) do
      expires_in = Keyword.get(opts, :expires_in, 7 * 86_400)
      can_forward = Keyword.get(opts, :can_forward, false)

      # Create perception link for this share
      doc = Repo.get(Alem.Schemas.Document, document_id)

      unless doc && doc.user_id == get_user_id(sender_did) do
        {:error, :not_owner}
      else
        now        = DateTime.utc_now() |> DateTime.truncate(:second)
        expires_at = DateTime.add(now, expires_in, :second)

        {:ok, link} =
          %PerceptionLink{}
          |> PerceptionLink.changeset(%{
            link_type:       "circle",
            content_hash:    doc.content_hash,
            document_id:     document_id,
            owner_did:       sender_did,
            issuer_did:      sender_did,
            conversation_id: conversation_id,
            can_forward:     can_forward,
            forward_depth:   0,
            scope:           "read",
            expires_at:      expires_at
          })
          |> Repo.insert()

        # Insert message pointing to the link
        %Message{}
        |> Message.changeset(%{
          conversation_id:   conversation_id,
          sender_did:        sender_did,
          content_type:      "perception_link",
          perception_link_id: link.id,
          sent_at:           now
        })
        |> Repo.insert()
        |> case do
          {:ok, msg} ->
            broadcast_message(conversation_id, msg)
            {:ok, msg, link}
          err -> err
        end
      end
    end
  end

  @doc """
  Delete a message FOR ME only.
  Message hidden from sender. Others still see it.
  """
  def delete_for_me(message_id, requester_did) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case Repo.get(Message, message_id) do
      nil -> {:error, :not_found}
      msg ->
        if msg.sender_did == requester_did do
          Repo.update(Message.changeset(msg, %{deleted_for_sender_at: now}))
        else
          {:error, :not_your_message}
        end
    end
  end

  @doc """
  Delete a message FOR EVERYONE.
  Only sender can do this. Message replaced with deletion notice.
  If message had a perception link — the link is revoked immediately.
  Users who already saved the file keep their copy.
  """
  def delete_for_everyone(message_id, requester_did) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case Repo.get(Message, message_id) do
      nil -> {:error, :not_found}
      msg ->
        if msg.sender_did == requester_did do
          # Revoke perception link if message had one
          if msg.perception_link_id do
            Repo.update_all(
              from(p in PerceptionLink,
                where: p.id == ^msg.perception_link_id),
              set: [revoked_at: now, revoked_by_did: requester_did]
            )
          end

          result = Repo.update(
            Message.changeset(msg, %{deleted_for_everyone_at: now})
          )

          # Broadcast deletion to all members
          broadcast_deletion(msg.conversation_id, message_id)
          result
        else
          {:error, :not_your_message}
        end
    end
  end

  @doc "Load messages for a conversation. Handles visibility per requester."
  def load_messages(conversation_id, requester_did, opts \\ []) do
    limit  = Keyword.get(opts, :limit, 50)
    before = Keyword.get(opts, :before)

    query =
      from m in Message,
        where: m.conversation_id == ^conversation_id and
               is_nil(m.deleted_for_everyone_at),
        order_by: [desc: m.sent_at],
        limit: ^limit

    query =
      if before,
        do: where(query, [m], m.sent_at < ^before),
        else: query

    messages = Repo.all(query)

    # Filter out sender-deleted messages for this requester
    Enum.filter(messages, fn msg ->
      not (msg.deleted_for_sender_at != nil and msg.sender_did == requester_did)
    end)
    |> Enum.reverse()
  end

  @doc "List all conversations for a user."
  def list_conversations(did) do
    Repo.all(
      from c in Conversation,
      join: m in ConversationMember,
        on: m.conversation_id == c.id and m.member_did == ^did,
      where: is_nil(m.left_at) and is_nil(c.archived_at),
      order_by: [desc: c.updated_at]
    )
  end

  @doc "Unread message count for a conversation."
  def unread_count(conversation_id, member_did) do
    member = Repo.get_by(ConversationMember,
      conversation_id: conversation_id, member_did: member_did)

    last_read = member && member.last_read_at || ~U[2000-01-01 00:00:00Z]

    Repo.aggregate(
      from(m in Message,
        where: m.conversation_id == ^conversation_id and
               m.sent_at > ^last_read and
               m.sender_did != ^member_did and
               is_nil(m.deleted_for_everyone_at)),
      :count
    )
  end

  @doc "Mark all messages as read up to now."
  def mark_read(conversation_id, member_did) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    Repo.update_all(
      from(m in ConversationMember,
        where: m.conversation_id == ^conversation_id and
               m.member_did == ^member_did),
      set: [last_read_at: now]
    )
    :ok
  end

  # ── Private Helpers ───────────────────────────────────────────────────────

  defp assert_member(conversation_id, did) do
    if Repo.exists?(
      from m in ConversationMember,
      where: m.conversation_id == ^conversation_id and
             m.member_did == ^did and
             is_nil(m.left_at)
    ), do: :ok, else: {:error, :not_a_member}
  end

  defp assert_admin(conversation_id, did) do
    if member_role(conversation_id, did) == "admin",
      do: :ok, else: {:error, :not_admin}
  end

  defp assert_not_member(conversation_id, did) do
    if Repo.exists?(
      from m in ConversationMember,
      where: m.conversation_id == ^conversation_id and
             m.member_did == ^did and is_nil(m.left_at)
    ), do: {:error, :already_member}, else: :ok
  end

  defp member_role(conversation_id, did) do
    Repo.one(
      from m in ConversationMember,
      where: m.conversation_id == ^conversation_id and
             m.member_did == ^did and is_nil(m.left_at),
      select: m.role
    )
  end

  defp get_user_id(did) do
    case Repo.get_by(Alem.Pleroma.User, did_id: did) do
      nil  -> nil
      user -> user.id
    end
  end

  defp broadcast_message(conversation_id, msg) do
    Phoenix.PubSub.broadcast(
      Alem.PubSub,
      "conversation:#{conversation_id}",
      {:new_message, msg}
    )
  end

  defp broadcast_deletion(conversation_id, message_id) do
    Phoenix.PubSub.broadcast(
      Alem.PubSub,
      "conversation:#{conversation_id}",
      {:message_deleted, message_id}
    )
  end
end
