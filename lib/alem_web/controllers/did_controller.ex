defmodule AlemWeb.DIDController do
  @moduledoc "DID (Decentralized Identifier) endpoints."

  use AlemWeb, :controller

  alias Alem.DID
  alias Alem.Namespace.Manager

  @doc "POST /api/v1/did/generate — generate a new DID for a user_id"
  def generate(conn, params) do
    user_id = params["user_id"] || UUID.uuid4()

    did = DID.generate(user_id)

    conn
    |> json(%{
      did:           did,
      namespace_key: DID.namespace_key(did),
      valid:         DID.valid?(did)
    })
  end

  @doc "POST /api/v1/did/validate"
  def validate(conn, %{"did" => did}) do
    conn |> json(%{
      did:           did,
      valid:         DID.valid?(did),
      namespace_key: DID.namespace_key(did)
    })
  end
  def validate(conn, _), do:
    conn |> put_status(400) |> json(%{error: "did is required"})

  @doc "GET /api/v1/did/:did/resolve"
  def resolve(conn, %{"did" => did}) do
    if DID.valid?(did) do
      namespace = Manager.find_by_did(did)
      conn |> json(%{
        did:           did,
        namespace_key: DID.namespace_key(did),
        namespace:     format_namespace(namespace)
      })
    else
      conn |> put_status(400) |> json(%{error: "Invalid DID format"})
    end
  end

  @doc "GET /api/v1/did/:did"
  def show(conn, %{"did" => did}) do
    if DID.valid?(did) do
      namespace = Manager.find_by_did(did)
      conn |> json(%{
        did:           did,
        namespace_key: DID.namespace_key(did),
        namespace:     format_namespace(namespace)
      })
    else
      conn |> put_status(400) |> json(%{error: "Invalid DID"})
    end
  end

  defp format_namespace(nil), do: nil
  defp format_namespace(ns) do
    %{id: ns.id, tenant_id: ns.tenant_id, status: ns.status,
      identity_type: ns.identity_type}
  end
end
