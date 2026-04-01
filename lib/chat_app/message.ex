defmodule ChatApp.Message do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  alias ChatApp.Repo

  schema "messages" do
    field :username, :string
    field :body,     :string
    field :room,     :string, default: "general"
    field :mentions, {:array, :string}, default: []

    timestamps(type: :utc_datetime)
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [:username, :body, :room, :mentions])
    |> validate_required([:username, :body, :room])
    |> validate_length(:body, min: 1, max: 500)
  end

  # Extract @mentions from body
  # "Hi @Alice-1234!" → ["Alice-1234"]
  def extract_mentions(body) do
    Regex.scan(~r/@([\w-]+)/, body)
    |> Enum.map(fn [_full, name] -> name end)
  end

  # Save message to DB
  def save(username, body, room \\ "general") do
    mentions = extract_mentions(body)

    %ChatApp.Message{}
    |> changeset(%{
      username: username,
      body:     body,
      room:     room,
      mentions: mentions
    })
    |> Repo.insert()
  end

  # Load last 50 messages for a room
  def last_50(room \\ "general") do
    ChatApp.Message
    |> where([m], m.room == ^room)
    |> order_by([m], asc: m.inserted_at)
    |> limit(50)
    |> Repo.all()
  end
end
