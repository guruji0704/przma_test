defmodule Alem.Repo.Migrations.CreateFollowsConnections do
  use Ecto.Migration

  def change do
    # ── Follows (one-way, sees public vault) ──────────────────────────────
    create table(:follows, primary_key: false) do
      add :id,             :binary_id, primary_key: true
      add :follower_did,   :string, null: false
      add :following_did,  :string, null: false
      add :status,         :string, default: "active"
      # active | muted | blocked
      timestamps(type: :utc_datetime)
    end

    create unique_index(:follows, [:follower_did, :following_did])
    create index(:follows, [:follower_did])
    create index(:follows, [:following_did])

    # ── Connections (two-way, enables chat) ───────────────────────────────
    create table(:connections, primary_key: false) do
      add :id,              :binary_id, primary_key: true
      add :requester_did,   :string, null: false
      add :receiver_did,    :string, null: false
      add :status,          :string, default: "pending"
      # pending | accepted | rejected | blocked
      add :accepted_at,     :utc_datetime
      add :rejected_at,     :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:connections, [:requester_did, :receiver_did])
    create index(:connections, [:requester_did])
    create index(:connections, [:receiver_did])
    create index(:connections, [:status])
  end
end
