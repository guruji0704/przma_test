defmodule AlemWeb.Vault.PrivateVaultController do
  use AlemWeb, :controller
  alias AlemWeb.Vault.Helpers

  @vault "private"

  def list(conn, _params) do
    with {:ok, user} <- Helpers.get_current_user(conn) do
      files = Helpers.list_vault_files(user.id, @vault)
      json(conn, %{success: true, vault: @vault, files: files})
    else
      {:error, _} -> conn |> put_status(401) |> json(%{error: "Unauthorized"})
    end
  end

  def get(conn, %{"doc_id" => doc_id}) do
    with {:ok, user} <- Helpers.get_current_user(conn) do
      case Helpers.get_vault_file(user.id, doc_id) do
        nil -> conn |> put_status(404) |> json(%{error: "Not found"})
        doc ->
          url = case Helpers.presigned_url(doc.object_key) do
            {:ok, u} -> u; _ -> nil
          end
          json(conn, %{success: true, file: doc, download_url: url})
      end
    else
      {:error, _} -> conn |> put_status(401) |> json(%{error: "Unauthorized"})
    end
  end

  def delete(conn, %{"doc_id" => doc_id}) do
    with {:ok, user} <- Helpers.get_current_user(conn) do
      case Helpers.delete_vault_file(user.id, doc_id) do
        :ok              -> json(conn, %{success: true, deleted: doc_id})
        {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "Not found"})
      end
    else
      {:error, _} -> conn |> put_status(401) |> json(%{error: "Unauthorized"})
    end
  end

  # Recipient calls this with their own Bearer token + share_token
  def accept_share(conn, %{"share_token" => token}) do
    with {:ok, user} <- Helpers.get_current_user(conn) do
      case Helpers.resolve_share(token, user.id, @vault) do
        {:ok, share} ->
          url = case Helpers.presigned_url(share.source_s3_key) do
            {:ok, u} -> u; _ -> nil
          end
          json(conn, %{
            success:      true,
            doc_id:       share.doc_id,
            filename:     share.filename,
            content_type: share.content_type,
            source_vault: share.source_vault,
            permission:   share.permission,
            download_url: url,
            expires_in:   300
          })
        {:error, reason} ->
          conn |> put_status(403) |> json(%{error: "Share #{reason}"})
      end
    else
      {:error, _} -> conn |> put_status(401) |> json(%{error: "Unauthorized"})
    end
  end
end
