defmodule Alem.Social do
  @moduledoc """
  Follow system + Connection system.

  Follow  = one-way. Sees target's public vault in feed.
  Connect = two-way request. Enables private chat when accepted.
  """

  import Ecto.Query
  alias Alem.{Repo, DID}
  alias Alem.Schemas.{Follow, Connection}
  alias Alem.Pleroma.User
  require Logger

  # ── Follow ──────────────────────────────────────────────────────────────

  @doc "Arun follows Guru. Arun sees Guru's public vault in feed."
  def follow(follower_did, following_did) do
    %Follow{}
    |> Follow.changeset(%{follower_did: follower_did, following_did: following_did})
    |> Repo.insert(on_conflict: :nothing)
  end

  @doc "Unfollow."
  def unfollow(follower_did, following_did) do
    Repo.delete_all(
      from f in Follow,
      where: f.follower_did == ^follower_did and f.following_did == ^following_did
    )
    :ok
  end

  @doc "Is follower_did following following_did?"
  def following?(follower_did, following_did) do
    Repo.exists?(
      from f in Follow,
      where: f.follower_did == ^follower_did and
             f.following_did == ^following_did and
             f.status == "active"
    )
  end

  @doc "List who a user is following."
  def following_list(did, limit \\ 50) do
    Repo.all(
      from f in Follow,
      join: u in User, on: u.did_id == f.following_did,
      where: f.follower_did == ^did and f.status == "active",
      select: %{did: f.following_did, nickname: u.nickname,
                avatar: u.avatar, followed_at: f.inserted_at},
      order_by: [desc: f.inserted_at],
      limit: ^limit
    )
  end

  @doc "List who follows a user."
  def followers_list(did, limit \\ 50) do
    Repo.all(
      from f in Follow,
      join: u in User, on: u.did_id == f.follower_did,
      where: f.following_did == ^did and f.status == "active",
      select: %{did: f.follower_did, nickname: u.nickname,
                avatar: u.avatar, followed_at: f.inserted_at},
      order_by: [desc: f.inserted_at],
      limit: ^limit
    )
  end

  @doc "Count followers and following."
  def counts(did) do
    followers  = Repo.aggregate(from(f in Follow, where: f.following_did == ^did and f.status == "active"), :count)
    following  = Repo.aggregate(from(f in Follow, where: f.follower_did == ^did and f.status == "active"), :count)
    %{followers: followers, following: following}
  end

  # ── Public Feed ──────────────────────────────────────────────────────────

  @doc """
  Get public vault content from all users that did follows.
  This is the user's feed.
  """
  def feed(did, limit \\ 50) do
    import Alem.Schemas.Document

    following_dids =
      Repo.all(from f in Follow,
        where: f.follower_did == ^did and f.status == "active",
        select: f.following_did)

    if following_dids == [] do
      []
    else
      Repo.all(
        from d in Alem.Schemas.Document,
        join: u in User, on: u.id == d.user_id,
        where: d.folder == "public" and
               d.user_id in subquery(
                 from(u2 in User,
                   where: u2.did_id in ^following_dids,
                   select: u2.id)
               ) and
               is_nil(d.deleted_for_everyone_at),
        select: %{
          id:           d.id,
          filename:     d.filename,
          content_type: d.content_type,
          folder:       d.folder,
          media_category: d.media_category,
          object_key:   d.object_key,
          content_hash: d.content_hash,
          inserted_at:  d.inserted_at,
          owner_nickname: u.nickname,
          owner_did:    u.did_id,
          owner_avatar: u.avatar
        },
        order_by: [desc: d.inserted_at],
        limit: ^limit
      )
    end
  end

  # ── Connections ───────────────────────────────────────────────────────────

  @doc "Send a connection request. Requires the two users are not already connected."
  def request_connection(requester_did, receiver_did) do
    case connection_status(requester_did, receiver_did) do
      :none ->
        %Connection{}
        |> Connection.changeset(%{
          requester_did: requester_did,
          receiver_did:  receiver_did,
          status:        "pending"
        })
        |> Repo.insert()

      status ->
        {:error, "Already #{status}"}
    end
  end

  @doc "Accept a connection request."
  def accept_connection(requester_did, receiver_did) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case Repo.get_by(Connection, requester_did: requester_did,
                                 receiver_did: receiver_did,
                                 status: "pending") do
      nil -> {:error, :not_found}
      conn ->
        Repo.update(Connection.changeset(conn, %{
          status: "accepted",
          accepted_at: now
        }))
    end
  end

  @doc "Reject a connection request."
  def reject_connection(requester_did, receiver_did) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    case Repo.get_by(Connection, requester_did: requester_did,
                                 receiver_did: receiver_did,
                                 status: "pending") do
      nil  -> {:error, :not_found}
      conn -> Repo.update(Connection.changeset(conn, %{
                status: "rejected", rejected_at: now}))
    end
  end

  @doc "Current connection status between two DIDs."
  def connection_status(did_a, did_b) do
    case Repo.one(
      from c in Connection,
      where: (c.requester_did == ^did_a and c.receiver_did == ^did_b) or
             (c.requester_did == ^did_b and c.receiver_did == ^did_a)
    ) do
      nil  -> :none
      conn -> String.to_atom(conn.status)
    end
  end

  @doc "List all accepted connections for a user."
  def connections_list(did) do
    Repo.all(
      from c in Connection,
      join: u in User,
        on: (c.requester_did == ^did and u.did_id == c.receiver_did) or
            (c.receiver_did == ^did and u.did_id == c.requester_did),
      where: c.status == "accepted" and
             (c.requester_did == ^did or c.receiver_did == ^did),
      select: %{
        connection_id: c.id,
        did:      u.did_id,
        nickname: u.nickname,
        avatar:   u.avatar,
        connected_at: c.accepted_at
      }
    )
  end

  @doc "Pending connection requests received by this user."
  def pending_requests(did) do
    Repo.all(
      from c in Connection,
      join: u in User, on: u.did_id == c.requester_did,
      where: c.receiver_did == ^did and c.status == "pending",
      select: %{
        connection_id: c.id,
        from_did:     c.requester_did,
        from_nickname: u.nickname,
        from_avatar:   u.avatar,
        requested_at: c.inserted_at
      },
      order_by: [desc: c.inserted_at]
    )
  end
end
