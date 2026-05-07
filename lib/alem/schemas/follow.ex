defmodule Alem.Schemas.Follow do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @statuses ~w(active muted blocked)

  schema "follows" do
    field :follower_did,  :string
    field :following_did, :string
    field :status,        :string, default: "active"
    timestamps(type: :utc_datetime)
  end

  def changeset(follow, attrs) do
    follow
    |> cast(attrs, [:follower_did, :following_did, :status])
    |> validate_required([:follower_did, :following_did])
    |> validate_inclusion(:status, @statuses)
    |> validate_not_self_follow()
    |> unique_constraint([:follower_did, :following_did])
  end

  defp validate_not_self_follow(changeset) do
    follower  = get_field(changeset, :follower_did)
    following = get_field(changeset, :following_did)
    if follower == following,
      do: add_error(changeset, :following_did, "cannot follow yourself"),
      else: changeset
  end
end

defmodule Alem.Schemas.Connection do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @statuses ~w(pending accepted rejected blocked)

  schema "connections" do
    field :requester_did, :string
    field :receiver_did,  :string
    field :status,        :string, default: "pending"
    field :accepted_at,   :utc_datetime
    field :rejected_at,   :utc_datetime
    timestamps(type: :utc_datetime)
  end

  def changeset(conn, attrs) do
    conn
    |> cast(attrs, [:requester_did, :receiver_did, :status, :accepted_at, :rejected_at])
    |> validate_required([:requester_did, :receiver_did])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:requester_did, :receiver_did])
  end

  @doc "True if two DIDs are connected (accepted)."
  def connected?(did_a, did_b) do
    import Ecto.Query
    Alem.Repo.exists?(
      from c in __MODULE__,
      where: c.status == "accepted" and
             ((c.requester_did == ^did_a and c.receiver_did == ^did_b) or
              (c.requester_did == ^did_b and c.receiver_did == ^did_a))
    )
  end
end
