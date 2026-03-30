defmodule AlemWeb.IdentityController do
  @moduledoc """
  Identity resolution — find a namespace by any of its identifiers.
  Accepts: namespace_key, DID (did:przma:...), or Pleroma account ID.
  """

  use AlemWeb, :controller
  alias Alem.Namespace.Manager
  alias Alem.DID

  @doc "GET /api/v1/identity/resolve/:identifier"
  def resolve(conn, %{"identifier" => identifier}) do
    case Manager.find_namespace(identifier) do
      nil ->
        conn |> put_status(404) |> json(%{error: "Namespace not found for: #{identifier}"})

      namespace ->
        conn |> json(%{
          identifier:       identifier,
          namespace:        format(namespace),
          all_identifiers:  all_ids(namespace),
          primary_identifier: primary_id(namespace)
        })
    end
  end

  @doc "POST /api/v1/identity/compare — are two identifiers the same person?"
  def compare(conn, %{"identifier1" => id1, "identifier2" => id2}) do
    ns1 = Manager.find_namespace(id1)
    ns2 = Manager.find_namespace(id2)

    same =
      ns1 != nil && ns2 != nil &&
      (ns1.id == ns2.id ||
       (ns1.did && ns1.did == ns2.did) ||
       (ns1.pleroma_account_id && ns1.pleroma_account_id == ns2.pleroma_account_id))

    conn |> json(%{identifier1: id1, identifier2: id2, same_identity: same})
  end
  def compare(conn, _),
    do: conn |> put_status(400) |> json(%{error: "identifier1 and identifier2 required"})

  @doc "GET /api/v1/identity/:identifier/identifiers"
  def identifiers(conn, %{"identifier" => identifier}) do
    case Manager.find_namespace(identifier) do
      nil ->
        conn |> put_status(404) |> json(%{error: "Namespace not found"})

      namespace ->
        conn |> json(%{
          namespace_id:      namespace.id,
          identifiers:       all_ids(namespace),
          primary_identifier: primary_id(namespace)
        })
    end
  end

  defp format(ns) do
    %{
      id:                 ns.id,
      tenant_id:          ns.tenant_id,
      did:                ns.did,
      identity_type:      ns.identity_type,
      pleroma_account_id: ns.pleroma_account_id,
      status:             ns.status,
      document_count:     ns.document_count     || 0,
      storage_bytes:      ns.storage_bytes || 0,
      last_activity_at:   ns.last_activity_at
    }
  end

  defp all_ids(ns) do
    [ns.id, ns.did, ns.pleroma_account_id]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp primary_id(ns) do
    cond do
      ns.did                -> ns.did
      ns.pleroma_account_id -> ns.pleroma_account_id
      true                  -> ns.id
    end
  end
end
