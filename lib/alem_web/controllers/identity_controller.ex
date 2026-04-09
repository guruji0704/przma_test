defmodule AlemWeb.IdentityController do
  @moduledoc """
  Controller for identity resolution operations
  """

  use AlemWeb, :controller

  alias Alem.Identity.Resolver

  @doc """
  Resolve an identifier to a namespace
  GET /api/v1/identity/resolve/:identifier
  """
  def resolve(conn, %{"identifier" => identifier}) do
    case Resolver.resolve_to_namespace(identifier) do
      {:ok, namespace} ->
        conn
        |> json(%{
          identifier: identifier,
          namespace: format_namespace(namespace),
          all_identifiers: Resolver.all_identifiers(namespace),
          primary_identifier: Resolver.primary_identifier(namespace)
        })

      {:error, :namespace_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Namespace not found for identifier: #{identifier}"})
    end
  end

  @doc """
  Check if two identifiers refer to the same identity
  POST /api/v1/identity/compare
  """
  def compare(conn, params) do
    identifier1 = params["identifier1"]
    identifier2 = params["identifier2"]

    if is_nil(identifier1) or is_nil(identifier2) do
      conn
      |> put_status(:bad_request)
      |> json(%{error: "Both identifier1 and identifier2 are required"})
    else
      same = Resolver.same_identity?(identifier1, identifier2)

      conn
      |> json(%{
        identifier1: identifier1,
        identifier2: identifier2,
        same_identity: same
      })
    end
  end

  @doc """
  Get all identifiers for a namespace
  GET /api/v1/identity/:identifier/identifiers
  """
  def identifiers(conn, %{"identifier" => identifier}) do
    case Resolver.resolve_to_namespace(identifier) do
      {:ok, namespace} ->
        conn
        |> json(%{
          namespace_id: namespace.id,
          identifiers: Resolver.all_identifiers(namespace),
          primary_identifier: Resolver.primary_identifier(namespace)
        })

      {:error, :namespace_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Namespace not found"})
    end
  end

  # Private helpers

  defp format_namespace(namespace) do
    %{
      id: namespace.id,
      tenant_id: namespace.tenant_id,
      did: namespace.did,
      identity_type: namespace.identity_type,
      pleroma_account_id: namespace.pleroma_account_id,
      status: namespace.status,
      document_count: namespace.document_count || 0,
      storage_bytes: namespace.storage_bytes || 0,
      last_activity_at: namespace.last_activity_at
    }
  end
end
