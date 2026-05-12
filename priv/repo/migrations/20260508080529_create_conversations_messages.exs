defmodule Alem.Repo.Migrations.CreateConversationsMessages do
  use Ecto.Migration

  def change do
    # ── Conversations (DM or Group) ───────────────────────────────────────
    create table(:conversations, primary_key: false) do
      add :id,              :binary_id, primary_key: true
      add :type,            :string, null: false, default: "direct"
      # direct | group
      add :name,            :string
      # null for direct, required for group
      add :description,     :string
      add :created_by_did,  :string, null: false
      add :namespace_key,   :string
      # private namespace for this conversation
      add :avatar,          :string
      # group avatar S3 key
      add :archived_at,     :utc_datetime
      add :member_count,    :integer, default: 2

      timestamps(type: :utc_datetime)
    end

    create index(:conversations, [:created_by_did])
    create index(:conversations, [:type])

    # ── Conversation Members ──────────────────────────────────────────────
    create table(:conversation_members, primary_key: false) do
      add :id,                :binary_id, primary_key: true
      add :conversation_id,   :binary_id, null: false
      add :member_did,        :string, null: false
      add :role,              :string, default: "member"
      # admin | member
      add :joined_at,         :utc_datetime, null: false
      add :left_at,           :utc_datetime
      add :last_read_at,      :utc_datetime
      # for unread message count
      add :is_muted,          :boolean, default: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:conversation_members, [:conversation_id, :member_did])
    create index(:conversation_members, [:member_did])
    create index(:conversation_members, [:conversation_id])

    # ── Messages ──────────────────────────────────────────────────────────
    create table(:messages, primary_key: false) do
      add :id,                       :binary_id, primary_key: true
      add :conversation_id,          :binary_id, null: false
      add :sender_did,               :string, null: false
      add :content_type,             :string, default: "text"
      # text | file | perception_link | system
      add :body,                     :text
      # text content
      add :perception_link_id,       :binary_id
      # if content_type = perception_link
      add :reply_to_id,              :binary_id
      # reply to another message
      add :sent_at,                  :utc_datetime, null: false
      add :edited_at,                :utc_datetime
      add :deleted_for_sender_at,    :utc_datetime
      # delete for me
      add :deleted_for_everyone_at,  :utc_datetime
      # delete for everyone

      timestamps(type: :utc_datetime)
    end

    create index(:messages, [:conversation_id])
    create index(:messages, [:sender_did])
    create index(:messages, [:conversation_id, :sent_at])
    # Partial index for active messages only
    execute """
      CREATE INDEX idx_messages_active
      ON messages (conversation_id, sent_at DESC)
      WHERE deleted_for_everyone_at IS NULL
    """,
    "DROP INDEX IF EXISTS idx_messages_active"
  end
end
