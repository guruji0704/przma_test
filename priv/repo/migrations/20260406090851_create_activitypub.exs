defmodule Przma.Repo.Migrations.CreateActivityPub do
  use Ecto.Migration

  def change do
    create table(:ap_actors, primary_key: false) do
      add :did,              :string,  primary_key: true
      add :actor_type,       :string,  null: false, default: "Person"
      add :inbox_url,        :string
      add :outbox_url,       :string
      add :public_key_pem,   :text
      add :remote,           :boolean, default: false

      timestamps(type: :utc_datetime)
    end

    create table(:ap_follows, primary_key: false) do
      add :id,           :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :follower_did, :string, null: false
      add :followee_did, :string, null: false
      add :state,        :string, null: false, default: "pending"  # pending|accepted|rejected

      timestamps(type: :utc_datetime)
    end

    create unique_index(:ap_follows, [:follower_did, :followee_did])
    create index(:ap_follows, [:followee_did, :state])

    create table(:ap_activities, primary_key: false) do
      add :id,         :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :actor_did,  :string,    null: false
      add :type,       :string,    null: false
      add :object,     :jsonb,     null: false
      add :recipients, {:array, :string}, default: []
      add :tier,       :string,    default: "social"
      add :status,     :string,    default: "pending"

      timestamps(type: :utc_datetime)
    end

    create index(:ap_activities, [:actor_did, :inserted_at])
    create index(:ap_activities, [:status])
  end
end
