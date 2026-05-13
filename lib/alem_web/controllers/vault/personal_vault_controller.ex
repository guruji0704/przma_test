defmodule AlemWeb.Vault.PersonalVaultController do
  use AlemWeb, :controller
  alias AlemWeb.Vault.Helpers

  @vault "personal"

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

  def share(conn, %{"doc_id" => doc_id} = params) do
    with {:ok, user}        <- Helpers.get_current_user(conn),
         {:ok, target_vault} <- require_target_vault(params) do
      case Helpers.create_share(user.id, doc_id, target_vault, params) do
        {:ok, share} ->
          json(conn, %{
            success:     true,
            share_id:    share.share_id,
            share_token: share.share_token,
            source_vault: share.source_vault,
            target_vault: share.target_vault,
            expires_at:  share.expires_at
          })
        {:error, :not_found} ->
          conn |> put_status(404) |> json(%{error: "Document not found"})
        {:error, changeset} ->
          conn |> put_status(422) |> json(%{error: inspect(changeset.errors)})
      end
    else
      {:error, :missing_target_vault} ->
        conn |> put_status(400) |> json(%{error: "target_vault required (private or social)"})
      {:error, _} ->
        conn |> put_status(401) |> json(%{error: "Unauthorized"})
    end
  end

  defp require_target_vault(%{"target_vault" => v}) when v in ["private", "social"],
    do: {:ok, v}
  defp require_target_vault(_), do: {:error, :missing_target_vault}
end
