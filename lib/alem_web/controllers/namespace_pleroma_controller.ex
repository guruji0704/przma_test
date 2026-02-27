# =============================================================================
# AlemWeb.NamespacePleromaController
# =============================================================================
# Namespace management for PRZMA/ALEM system.
#
# Uses Pleroma-compatible auth via aliases:
#   alias Alem.Auth
#   alias Alem.Pleroma.User
#
# Key change from old mock version:
#   OLD: Called mock server on port 4001 → always got user_id "12345"
#   NEW: Calls Auth.verify_token/1 → gets real unique user.id from DB
#
# Based on Pleroma's authentication plug pattern:
# Source: https://git.pleroma.social/pleroma/pleroma/src/branch/develop/lib/pleroma/web
# =============================================================================

defmodule AlemWeb.NamespacePleromaController do
  use AlemWeb, :controller

  # ─── Pleroma-style aliases ──────────────────────────────────────────────────
  alias Alem.Auth
  alias Alem.Pleroma.User
  # ────────────────────────────────────────────────────────────────────────────

  alias Alem.PleromaIntegration

  @moduledoc """
  Namespace management endpoints.
  All endpoints require Bearer token authentication.
  Token is verified against DB using Pleroma-compatible token schema.
  """

  # ===========================================================================
  # POST /api/namespaces/pleroma
  # Create or get namespace for authenticated user
  # ===========================================================================

  def create_or_get(conn, params) do
    with {:ok, token}      <- extract_token(conn),
         {:ok, account_id} <- verify_and_get_account_id(token) do

      case PleromaIntegration.create_or_get_namespace_for_pleroma_account(account_id, params) do
        {:ok, namespace} ->
          json(conn, %{status: "success", namespace: namespace})

        {:error, reason} ->
          conn |> put_status(400) |> json(%{error: to_string(reason)})
      end
    else
      error -> handle_auth_error(conn, error)
    end
  end

  # ===========================================================================
  # GET /api/namespaces/pleroma
  # Get namespace for authenticated user
  # ===========================================================================

  def get(conn, _params) do
    with {:ok, token}      <- extract_token(conn),
         {:ok, account_id} <- verify_and_get_account_id(token) do

      case PleromaIntegration.get_namespace_for_pleroma_account(account_id) do
        {:ok, namespace} ->
          json(conn, namespace)

        {:error, :not_found} ->
          conn |> put_status(404) |> json(%{error: "Namespace not found"})

        {:error, reason} ->
          conn |> put_status(400) |> json(%{error: to_string(reason)})
      end
    else
      error -> handle_auth_error(conn, error)
    end
  end

  # ===========================================================================
  # POST /api/namespaces/pleroma/sync
  # Sync namespace data
  # ===========================================================================

  def sync(conn, params) do
    with {:ok, token}      <- extract_token(conn),
         {:ok, account_id} <- verify_and_get_account_id(token) do

      case PleromaIntegration.sync_namespace_for_pleroma_account(account_id, params) do
        {:ok, result} ->
          json(conn, %{status: "synced", result: result})

        {:error, reason} ->
          conn |> put_status(400) |> json(%{error: to_string(reason)})
      end
    else
      error -> handle_auth_error(conn, error)
    end
  end

  # ===========================================================================
  # GET /api/namespaces/pleroma/account
  # Get account info for authenticated user
  # ===========================================================================

  def get_account_info(conn, _params) do
    with {:ok, token}      <- extract_token(conn),
         {:ok, account_id} <- verify_and_get_account_id(token),
         user              <- Auth.get_user_by_id(account_id) do

      case user do
        nil ->
          conn |> put_status(404) |> json(%{error: "User not found"})

        user ->
          json(conn, render_account_info(user))
      end
    else
      error -> handle_auth_error(conn, error)
    end
  end

  # ===========================================================================
  # Private helpers
  # ===========================================================================

  # Extract Bearer token from Authorization header
  # Based on Pleroma's OAuthPlug pattern
  defp extract_token(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] ->
        {:ok, String.trim(token)}

      _ ->
        {:error, :missing_token}
    end
  end

  # THE KEY CHANGE from mock server:
  # OLD: called mock server HTTP request → always "12345"
  # NEW: calls Auth.verify_token/1 → real user.id from oauth_tokens table
  #
  # Based on Pleroma.Plugs.OAuthPlug.call/2 pattern
  defp verify_and_get_account_id(token) do
    case Auth.verify_token(token) do
      {:ok, %User{} = user} ->
        {:ok, user.id}        # ← john's real unique id "mK92pqRtYuIoplKj"
                               #    NOT the fake "12345" from the mock

      {:error, :invalid_token} ->
        {:error, :invalid_token}
    end
  end

  # Handle auth errors uniformly
  defp handle_auth_error(conn, error) do
    case error do
      {:error, :missing_token} ->
        conn
        |> put_status(401)
        |> json(%{error: "Missing authorization token"})

      {:error, :invalid_token} ->
        conn
        |> put_status(401)
        |> json(%{error: "Invalid or expired token"})

      _ ->
        conn
        |> put_status(401)
        |> json(%{error: "Unauthorized"})
    end
  end

  # Render user account info
  # Field names follow Pleroma.Web.MastoAPI.AccountView pattern
  defp render_account_info(%User{} = user) do
    %{
      id:           user.id,
      nickname:     user.nickname,
      name:         user.name,
      email:        user.email,
      bio:          user.bio,
      is_active:    user.is_active,
      is_admin:     user.is_admin,
      created_at:   NaiveDateTime.to_iso8601(user.inserted_at) <> "Z"
      # NOTE: private_key is NOT included — security improvement
    }
  end
end
