defmodule Alem.Schemas.Conversation do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @types ~w(direct group)

  schema "conversations" do
    field :type,            :string, default: "direct"
    field :name,            :string
    field :description,     :string
    field :created_by_did,  :string
    field :namespace_key,   :string
    field :avatar,          :string
    field :member_count,    :integer, default: 2
    field :archived_at,     :utc_datetime
    timestamps(type: :utc_datetime)
  end

  def changeset(conv, attrs) do
    conv
    |> cast(attrs, [:type, :name, :description, :created_by_did,
                    :namespace_key, :avatar, :member_count])
    |> validate_required([:type, :created_by_did])
    |> validate_inclusion(:type, @types)
    |> validate_group_name()
  end

  defp validate_group_name(changeset) do
    if get_field(changeset, :type) == "group" and
       (get_field(changeset, :name) == nil or get_field(changeset, :name) == ""),
      do: add_error(changeset, :name, "group name is required"),
      else: changeset
  end
end

defmodule Alem.Schemas.ConversationMember do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @roles ~w(admin member)

  schema "conversation_members" do
    field :conversation_id, :binary_id
    field :member_did,      :string
    field :role,            :string, default: "member"
    field :joined_at,       :utc_datetime
    field :left_at,         :utc_datetime
    field :last_read_at,    :utc_datetime
    field :is_muted,        :boolean, default: false
    timestamps(type: :utc_datetime)
  end

  def changeset(member, attrs) do
    member
    |> cast(attrs, [:conversation_id, :member_did, :role,
                    :joined_at, :left_at, :last_read_at, :is_muted])
    |> validate_required([:conversation_id, :member_did, :joined_at])
    |> validate_inclusion(:role, @roles)
    |> unique_constraint([:conversation_id, :member_did])
  end
end

defmodule Alem.Schemas.Message do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @content_types ~w(text file perception_link system)

  schema "messages" do
    field :conversation_id,         :binary_id
    field :sender_did,              :string
    field :content_type,            :string, default: "text"
    field :body,                    :string
    field :perception_link_id,      :binary_id
    field :reply_to_id,             :binary_id
    field :sent_at,                 :utc_datetime
    field :edited_at,               :utc_datetime
    field :deleted_for_sender_at,   :utc_datetime
    field :deleted_for_everyone_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end

  def changeset(msg, attrs) do
    msg
    |> cast(attrs, [:conversation_id, :sender_did, :content_type,
                    :body, :perception_link_id, :reply_to_id, :sent_at])
    |> validate_required([:conversation_id, :sender_did, :sent_at])
    |> validate_inclusion(:content_type, @content_types)
    |> validate_body_or_link()
  end

  defp validate_body_or_link(changeset) do
    body = get_field(changeset, :body)
    link = get_field(changeset, :perception_link_id)
    ct   = get_field(changeset, :content_type)
    if ct == "text" and (body == nil or body == ""),
      do: add_error(changeset, :body, "text message cannot be empty"),
      else: changeset
  end

  @doc "True if message is visible to this DID."
  def visible_to?(%__MODULE__{} = msg, requester_did) do
    everyone_deleted = msg.deleted_for_everyone_at != nil
    sender_deleted   = msg.deleted_for_sender_at != nil and
                       msg.sender_did == requester_did
    not everyone_deleted and not sender_deleted
  end
end

defmodule Alem.Schemas.PerceptionLink do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @link_types ~w(personal circle forward)
  @scopes     ~w(read annotate)

  schema "perception_links" do
    field :link_type,        :string
    field :content_hash,     :string
    field :document_id,      :binary_id
    field :owner_did,        :string
    field :issuer_did,       :string
    field :target_did,       :string
    field :target_group_id,  :binary_id
    field :conversation_id,  :binary_id
    field :parent_link_id,   :binary_id
    field :can_forward,      :boolean, default: false
    field :forward_depth,    :integer, default: 0
    field :scope,            :string, default: "read"
    field :expires_at,       :utc_datetime
    field :revoked_at,       :utc_datetime
    field :revoked_by_did,   :string
    field :access_count,     :integer, default: 0
    field :last_accessed_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end

  def changeset(link, attrs) do
    link
    |> cast(attrs, [:link_type, :content_hash, :document_id,
                    :owner_did, :issuer_did, :target_did,
                    :target_group_id, :conversation_id,
                    :parent_link_id, :can_forward,
                    :forward_depth, :scope, :expires_at])
    |> validate_required([:link_type, :content_hash, :document_id,
                          :owner_did, :issuer_did, :expires_at])
    |> validate_inclusion(:link_type, @link_types)
    |> validate_inclusion(:scope, @scopes)
    |> validate_max_depth()
    |> validate_expiry()
  end

  defp validate_max_depth(changeset) do
    depth = get_field(changeset, :forward_depth) || 0
    if depth > 2,
      do: add_error(changeset, :forward_depth, "maximum forward depth is 2"),
      else: changeset
  end

  defp validate_expiry(changeset) do
    case get_change(changeset, :expires_at) do
      nil -> changeset
      exp ->
        if DateTime.compare(exp, DateTime.utc_now()) == :gt,
          do: changeset,
          else: add_error(changeset, :expires_at, "must be in the future")
    end
  end

  @doc "True if link is currently usable."
  def valid?(%__MODULE__{} = link) do
    link.revoked_at == nil and
    DateTime.compare(link.expires_at, DateTime.utc_now()) == :gt
  end
end

defmodule Alem.Schemas.Archive do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "archives" do
    field :document_id,              :binary_id
    field :owner_did,                :string
    field :archived_at,              :utc_datetime
    field :expires_at,               :utc_datetime
    field :restored_at,              :utc_datetime
    field :permanently_deleted_at,   :utc_datetime
    timestamps(type: :utc_datetime)
  end

  def changeset(archive, attrs) do
    archive
    |> cast(attrs, [:document_id, :owner_did, :archived_at,
                    :expires_at, :restored_at, :permanently_deleted_at])
    |> validate_required([:document_id, :owner_did, :archived_at, :expires_at])
  end
end
