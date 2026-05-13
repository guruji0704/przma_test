defmodule Alem.Chat do
  @moduledoc """
  Chat context — vault-scoped rooms, persistent messages, and room membership.

  Each room belongs to exactly one vault (personal/private/social).
  Membership is tracked per room; owners can invite others.
  Messages are persisted in PostgreSQL and broadcast over Phoenix Channels.
  """

  import Ecto.Query
  alias Alem.Repo
  alias Alem.Schemas.{ChatRoom, ChatMessage, ChatRoomMember}
  alias Alem.Pleroma.User

  # ── Rooms ────────────────────────────────────────────────────────────────────

  @doc """
  Returns all non-DM rooms in the vault (for discovery) plus DM rooms the user is in.
  This allows users to see and join public rooms, while DMs remain private.
  """
  def list_rooms("private", user_id), do: list_joined_rooms("private", user_id)
  def list_rooms(vault, user_id) do
    from(r in ChatRoom,
      where: r.vault == ^vault,
      where: r.is_dm == false or ^user_id in r.dm_user_ids,
      order_by: [asc: r.inserted_at]
    )
    |> Repo.all()
  end

  @doc "Returns only rooms the user has explicitly joined (is a member of)."
  def list_joined_rooms(vault, user_id) do
    from(r in ChatRoom,
      join: m in ChatRoomMember, on: m.room_id == r.id and m.user_id == ^user_id,
      where: r.vault == ^vault,
      order_by: [asc: r.inserted_at],
      select: r
    )
    |> Repo.all()
  end

  def get_room(id), do: Repo.get(ChatRoom, id)
  def get_room!(id), do: Repo.get!(ChatRoom, id)

  def get_room_by_token(nil), do: nil
  def get_room_by_token(token) do
    Repo.get_by(ChatRoom, join_token: token)
  end

  @doc "Create a room and automatically add the owner as a member."
  def create_room(attrs) do
    Repo.transaction(fn ->
      case %ChatRoom{} |> ChatRoom.changeset(attrs) |> Repo.insert() do
        {:ok, room} ->
          owner_id       = to_string(attrs[:owner_user_id] || attrs["owner_user_id"] || "")
          owner_username = to_string(attrs[:owner_username] || attrs["owner_username"] || owner_id)

          case add_member(room.id, owner_id, owner_username, "owner") do
            {:ok, _}    -> room
            {:error, _} -> Repo.rollback(:member_insert_failed)
          end

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
    |> case do
      {:ok, room}       -> {:ok, room}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc "Get or create a DM room between two users, adding both as members."
  def get_or_create_dm(vault, user_ids, usernames \\ []) when length(user_ids) == 2 do
    sorted = Enum.sort(user_ids)

    case Repo.one(
      from r in ChatRoom,
        where: r.vault == ^vault and r.is_dm == true and r.dm_user_ids == ^sorted
    ) do
      %ChatRoom{} = room ->
        {:ok, room}

      nil ->
        owner_id = hd(sorted)
        owner_username =
          if length(usernames) == 2 do
            Enum.at(usernames, Enum.find_index(user_ids, &(&1 == owner_id)) || 0)
          else
            owner_id
          end

        Repo.transaction(fn ->
          case %ChatRoom{}
               |> ChatRoom.changeset(%{
                 name:          "DM",
                 vault:         vault,
                 owner_user_id: owner_id,
                 is_dm:         true,
                 dm_user_ids:   sorted
               })
               |> Repo.insert() do
            {:ok, room} ->
              user_ids
              |> Enum.with_index()
              |> Enum.each(fn {uid, i} ->
                uname = Enum.at(usernames, i, uid)
                role  = if uid == owner_id, do: "owner", else: "member"
                add_member(room.id, uid, uname, role)
              end)
              room

            {:error, cs} ->
              Repo.rollback(cs)
          end
        end)
        |> case do
          {:ok, room} -> {:ok, room}
          {:error, cs} -> {:error, cs}
        end
    end
  end

  # ── Members ──────────────────────────────────────────────────────────────────

  def add_member(room_id, user_id, username, role \\ "member") do
    %ChatRoomMember{}
    |> ChatRoomMember.changeset(%{
      room_id:  to_string(room_id),
      user_id:  to_string(user_id),
      username: to_string(username),
      role:     role
    })
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:room_id, :user_id])
  end

  def remove_member(room_id, user_id) do
    from(m in ChatRoomMember,
      where: m.room_id == ^room_id and m.user_id == ^user_id
    )
    |> Repo.delete_all()
    :ok
  end

  def delete_room(room_id, user_id) do
    case get_room(room_id) do
      nil -> {:error, :not_found}
      %ChatRoom{owner_user_id: ^user_id} = room ->
        Repo.transaction(fn ->
          Repo.delete_all(from m in ChatMessage, where: m.room_id == ^room_id)
          Repo.delete_all(from m in ChatRoomMember, where: m.room_id == ^room_id)
          Repo.delete!(room)
        end)
      _ -> {:error, :unauthorized}
    end
  end

  def list_members(room_id) do
    from(m in ChatRoomMember,
      where: m.room_id == ^room_id,
      order_by: [asc: m.inserted_at]
    )
    |> Repo.all()
  end

  def is_member?(room_id, user_id) do
    Repo.exists?(
      from m in ChatRoomMember,
        where: m.room_id == ^room_id and m.user_id == ^user_id
    )
  end

  @doc "Returns a MapSet of room IDs the given user belongs to — used for bulk membership checks."
  def list_user_room_ids(user_id) do
    from(m in ChatRoomMember, where: m.user_id == ^user_id, select: m.room_id)
    |> Repo.all()
    |> MapSet.new()
  end

  def get_member_role(room_id, user_id) do
    Repo.one(
      from m in ChatRoomMember,
        where: m.room_id == ^room_id and m.user_id == ^user_id,
        select: m.role
    )
  end

  def room_status(room_id) do
    member_count = Repo.one(
      from m in ChatRoomMember,
        where: m.room_id == ^room_id,
        select: count(m.id)
    )
    %{member_count: member_count || 0}
  end

  # ── Messages ─────────────────────────────────────────────────────────────────

  @doc "Paginated message history for a room (most recent first, then reversed)."
  def list_messages(room_id, opts \\ []) do
    limit     = Keyword.get(opts, :limit, 50)
    before_id = Keyword.get(opts, :before_id)

    query =
      from m in ChatMessage,
        where: m.room_id == ^room_id and is_nil(m.deleted_at),
        order_by: [desc: m.inserted_at],
        limit: ^limit

    query =
      if before_id do
        case Repo.get(ChatMessage, before_id) do
          nil -> query
          ref -> where(query, [m], m.inserted_at < ^ref.inserted_at)
        end
      else
        query
      end

    query |> Repo.all() |> Enum.reverse()
  end

  def create_message(attrs) do
    %ChatMessage{}
    |> ChatMessage.changeset(attrs)
    |> Repo.insert()
  end

  def soft_delete_message(id, requesting_user_id) do
    with %ChatMessage{} = msg <- Repo.get(ChatMessage, id),
         true <- msg.user_id == requesting_user_id do
      msg
      |> Ecto.Changeset.change(%{deleted_at: DateTime.utc_now() |> DateTime.truncate(:second)})
      |> Repo.update()
    else
      nil   -> {:error, :not_found}
      false -> {:error, :unauthorized}
    end
  end

  # ── Users ────────────────────────────────────────────────────────────────────

  @doc "List all active przma users, optionally filtered by nickname/name search."
  def list_users(search \\ nil) do
    query =
      from u in User,
        where: u.is_active == true,
        select: %{id: u.id, nickname: u.nickname, name: u.name},
        order_by: [asc: u.nickname]

    query =
      if search && String.length(search) > 0 do
        pattern = "%#{search}%"
        where(query, [u], ilike(u.nickname, ^pattern) or ilike(u.name, ^pattern))
      else
        query
      end

    Repo.all(query)
  end

  # ── Serialization ────────────────────────────────────────────────────────────

  def room_json(%ChatRoom{} = r) do
    %{
      id:            r.id,
      name:          r.name,
      vault:         r.vault,
      owner_user_id: r.owner_user_id,
      description:   r.description,
      is_dm:         r.is_dm,
      dm_user_ids:   r.dm_user_ids,
      max_members:   r.max_members,
      inserted_at:   r.inserted_at
    }
  end

  def message_json(%ChatMessage{} = m) do
    %{
      id:          m.id,
      room_id:     m.room_id,
      user_id:     m.user_id,
      username:    m.username,
      body:        m.body,
      msg_type:    m.msg_type,
      file_doc_id: m.file_doc_id,
      file_name:   m.file_name,
      file_type:   m.file_type,
      vault:       m.vault,
      inserted_at: m.inserted_at
    }
  end

  def member_json(%ChatRoomMember{} = m) do
    %{
      user_id:   m.user_id,
      username:  m.username,
      role:      m.role,
      joined_at: m.inserted_at
    }
  end

  def user_json(u) do
    %{
      id:       u.id,
      nickname: u.nickname,
      name:     u.name || u.nickname
    }
  end
end
