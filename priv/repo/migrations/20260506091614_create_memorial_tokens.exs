defmodule Alem.Repo.Migrations.CreateMemorialTokens do
  use Ecto.Migration

  @doc """
  Memorial token config — user sets trusted contacts during setup.
  When activated by quorum vote, a read-only share_token is generated
  for the personal namespace only. Private folder is NEVER opened.
  """
  def change do
    create table(:memorial_tokens, primary_key: false) do
      add :id,                  :binary_id, primary_key: true
      add :owner_did,           :string, null: false
      add :trusted_dids,        {:array, :string}, null: false, default: []
      add :quorum,              :integer, default: 1
      add :scope_folders,       {:array, :string}, default: ["personal"]
      # Always ["personal"]. Private NEVER included.
      add :expiry_days,         :integer, default: 365
      add :is_activated,        :boolean, default: false
      add :activated_at,        :utc_datetime
      add :activated_by,        {:array, :string}, default: []
      add :generated_token_id,  :binary_id   # → share_tokens.id once activated
      add :revoked_at,          :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:memorial_tokens, [:owner_did])
    create index(:memorial_tokens, [:is_activated])
  end
end
