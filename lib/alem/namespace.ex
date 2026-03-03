defmodule Alem.Namespace do
  @moduledoc """
  Namespace management for multi-tenant document isolation.
  Each user gets a unique namespace based on their DID.
  """

  alias Alem.{Repo, Schemas.Namespace, DID}
  require Logger

  @doc """
  Create a namespace for a user based on their DID.
  Returns {:ok, namespace} or {:error, changeset}.
  """
  def create_for_user(%{id: user_id, did_id: did_id}) do
    namespace_key = DID.namespace_key(did_id)

    attrs = %{
      id: namespace_key,
      tenant_id: namespace_key,
      config: %{
        storage: %{
          s3_bucket: "perkeep",
          s3_prefix: "user/#{namespace_key}/",
          sqld_database: "alem_#{namespace_key}"
        }
      },
      status: "active",
      last_activity_at: DateTime.utc_now()
    }

    case Repo.insert(%Namespace{} |> Namespace.changeset(attrs)) do
      {:ok, namespace} ->
        Logger.info("[Namespace] Created for user #{user_id}: #{namespace_key}")
        {:ok, namespace}

      {:error, changeset} ->
        Logger.error("[Namespace] Failed to create for user #{user_id}: #{inspect(changeset.errors)}")
        {:error, changeset}
    end
  end

  @doc """
  Get namespace for a user by user_id.
  Returns {:ok, namespace} or {:error, :not_found}.
  """
  def get_for_user(user_id) do
    user = Repo.get(Alem.Pleroma.User, user_id)

    if user && user.did_id do
      namespace_key = DID.namespace_key(user.did_id)

      case Repo.get(Namespace, namespace_key) do
        nil -> {:error, :not_found}
        namespace -> {:ok, namespace}
      end
    else
      {:error, :no_did}
    end
  end

  @doc """
  Get namespace by namespace_key directly.
  """
  def get(namespace_key) do
    case Repo.get(Namespace, namespace_key) do
      nil -> {:error, :not_found}
      namespace -> {:ok, namespace}
    end
  end

  @doc """
  Update namespace last_activity timestamp.
  """
  def touch(namespace_key) do
    case get(namespace_key) do
      {:ok, namespace} ->
        namespace
        |> Namespace.changeset(%{last_activity_at: DateTime.utc_now()})
        |> Repo.update()

      error -> error
    end
  end

  @doc """
  Update namespace statistics (document count, storage bytes, etc).
  """
  def update_stats(namespace_key, stats) do
    case get(namespace_key) do
      {:ok, namespace} ->
        namespace
        |> Namespace.changeset(stats)
        |> Repo.update()

      error -> error
    end
  end
end
