defmodule AlemWeb.DIDController do
  @moduledoc """
  Controller for DID (Decentralized Identifier) operations
  """

  use AlemWeb, :controller

  alias Alem.DID
  alias Alem.Namespace.Manager

  @doc """
  Generate a new DID
  POST /api/v1/did/generate
  """
  def generate(conn, params) do
    method = (params["method"] || "key") |> String.to_existing_atom()
    opts = parse_did_opts(params)

    case DID.generate(method, opts) do
      {:ok, did, keypair} ->
        conn
        |> json(%{
          did: did,
          method: method,
          keypair: sanitize_keypair(keypair)
        })

      {:ok, did} ->
        conn
        |> json(%{
          did: did,
          method: method
        })

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Failed to generate DID", details: inspect(reason)})
    end
  end

  @doc """
  Validate a DID
  POST /api/v1/did/validate
  """
  def validate(conn, params) do
    did = params["did"]

    if is_nil(did) or did == "" do
      conn
      |> put_status(:bad_request)
      |> json(%{error: "DID is required"})
    else
      case DID.validate(did) do
        {:ok, valid_did} ->
          {:ok, method} = DID.method(valid_did)
          {:ok, identifier} = DID.identifier(valid_did)

          conn
          |> json(%{
            valid: true,
            did: valid_did,
            method: method,
            identifier: identifier
          })

        {:error, reason} ->
          conn
          |> json(%{
            valid: false,
            did: did,
            error: reason
          })
      end
    end
  end

  @doc """
  Resolve a DID to its DID document
  GET /api/v1/did/:did/resolve
  """
  def resolve(conn, %{"did" => did}) do
    case DID.resolve(did) do
      {:ok, did_document} ->
        conn
        |> json(%{
          did: did,
          document: did_document
        })

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Failed to resolve DID", details: inspect(reason)})
    end
  end

  @doc """
  Get DID information
  GET /api/v1/did/:did
  """
  def show(conn, %{"did" => did}) do
    case DID.validate(did) do
      {:ok, valid_did} ->
        {:ok, method} = DID.method(valid_did)
        {:ok, identifier} = DID.identifier(valid_did)

        # Try to resolve to namespace
        namespace = Manager.find_by_did(valid_did)

        conn
        |> json(%{
          did: valid_did,
          method: method,
          identifier: identifier,
          namespace: if(namespace, do: format_namespace(namespace), else: nil)
        })

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid DID", details: inspect(reason)})
    end
  end

  # Private helpers

  defp parse_did_opts(params) do
    opts = []
    opts = if params["domain"], do: Keyword.put(opts, :domain, params["domain"]), else: opts
    opts = if params["path"], do: Keyword.put(opts, :path, params["path"]), else: opts
    opts
  end

  defp sanitize_keypair(keypair) when is_map(keypair) do
    # Don't expose private keys in response
    # Encode binary keys to base64 strings for JSON encoding
    case Map.get(keypair, :public_key) do
      nil -> %{}
      public_key when is_binary(public_key) ->
        %{public_key: Base.encode64(public_key)}
      _ -> %{}
    end
  end

  defp sanitize_keypair(_), do: %{}

  defp format_namespace(namespace) do
    %{
      id: namespace.id,
      tenant_id: namespace.tenant_id,
      identity_type: namespace.identity_type,
      status: namespace.status
    }
  end
end
