defmodule AlemWeb.Vault.VaultShareController do
  use AlemWeb, :controller
  alias AlemWeb.Vault.Helpers
  alias Alem.{Repo}
  alias Alem.Schemas.VaultShare
  import Ecto.Query

  def outgoing(conn, _params) do
    with {:ok, user} <- Helpers.get_current_user(conn) do
      shares = Helpers.list_outgoing_shares(user.id)
      json(conn, %{success: true, shares: shares})
    else
      {:error, _} -> conn |> put_status(401) |> json(%{error: "Unauthorized"})
    end
  end

  def incoming(conn, _params) do
    with {:ok, user} <- Helpers.get_current_user(conn) do
      shares = Helpers.list_incoming_shares(user.id)
      json(conn, %{success: true, shares: shares})
    else
      {:error, _} -> conn |> put_status(401) |> json(%{error: "Unauthorized"})
    end
  end

  def revoke(conn, %{"share_id" => share_id}) do
    with {:ok, user} <- Helpers.get_current_user(conn) do
      case Helpers.revoke_share(share_id, user.id) do
        :ok                  -> json(conn, %{success: true, revoked: share_id})
        {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "Share not found"})
      end
    else
      {:error, _} -> conn |> put_status(401) |> json(%{error: "Unauthorized"})
    end
  end

  def update(conn, %{"share_id" => share_id} = params) do
    with {:ok, user} <- Helpers.get_current_user(conn) do
      case Repo.one(from s in VaultShare,
             where: s.share_id == ^share_id and s.owner_user_id == ^user.id) do
        nil -> conn |> put_status(404) |> json(%{error: "Share not found"})
        share ->
          updates = %{}
          updates = if Map.has_key?(params, "expires_in"),
            do: Map.put(updates, :expires_at,
              DateTime.add(DateTime.utc_now(), params["expires_in"], :second)
              |> DateTime.truncate(:second)),
            else: updates
          updates = if Map.has_key?(params, "permission"),
            do: Map.put(updates, :permission, params["permission"]),
            else: updates
          updated = Repo.update!(Ecto.Changeset.change(share, updates))
          json(conn, %{success: true, share: updated})
      end
    else
      {:error, _} -> conn |> put_status(401) |> json(%{error: "Unauthorized"})
    end
  end

  def access_log(conn, %{"share_id" => share_id}) do
    with {:ok, user} <- Helpers.get_current_user(conn) do
      case Repo.one(from s in VaultShare,
             where: s.share_id == ^share_id and s.owner_user_id == ^user.id) do
        nil -> conn |> put_status(404) |> json(%{error: "Share not found"})
        _   -> json(conn, %{success: true, share_id: share_id, log: []})
      end
    else
      {:error, _} -> conn |> put_status(401) |> json(%{error: "Unauthorized"})
    end
  end
end
