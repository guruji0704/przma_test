defmodule Alem.Repo.Migrations.AddJoinTokenToChatRooms do
  use Ecto.Migration

  def change do
    alter table(:chat_rooms) do
      add :join_token, :string
    end

    create unique_index(:chat_rooms, [:join_token])
  end
end
