defmodule Alem.Repo.Migrations.CreateShareTokens do
  use Ecto.Migration

  @doc """
  Capability tokens for sharing personal namespace content.
  Signed by issuer DID — server verifies signature on every use.
  No file copy ever made. Share = time-limited read access via signed S3 URL.
  """
  def change do
    create table(:share_tokens, primary_key: false) do
      add :id,               :binary_id, primary_key: true
      add :issuer_did,       :string, null: false
      add :target_did,       :string                    # null = anyone with link
      add :namespace_key,    :string                    # which namespace
      add :document_id,      :binary_id                 # null = entire namespace
      add :content_hash,     :string                    # specific CAS object
      add :folder,           :string, default: "personal"
      add :scope,            :string, default: "read"   # read | read_write
      add :expires_at,       :utc_datetime, null: false # mandatory — no forever tokens
      add :is_memorial,      :boolean, default: false
      add :note,             :string
      add :signature,        :text, null: false          # DID-signed token payload
      add :revoked_at,       :utc_datetime
      add :last_used_at,     :utc_datetime
      add :use_count,        :integer, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:share_tokens, [:issuer_did])
    create index(:share_tokens, [:target_did])
    create index(:share_tokens, [:document_id])
    create index(:share_tokens, [:namespace_key])

    execute """
      CREATE INDEX idx_share_tokens_active
      ON share_tokens (expires_at, issuer_did)
      WHERE revoked_at IS NULL
    """,
    "DROP INDEX IF EXISTS idx_share_tokens_active"
  end
end
