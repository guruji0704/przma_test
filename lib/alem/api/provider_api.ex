defmodule Alem.Api.ProviderApi do
  @moduledoc "BYOS provider management. Settings → Providers calls this."

  import Ecto.Query
  alias Alem.Repo
  alias Alem.Schemas.UserProvider
  alias Alem.Services.StorageProvider

  def list_providers(user) do
    Repo.all(from p in UserProvider,
      where: p.user_id == ^user.id,
      order_by: [asc: p.provider_type, asc: p.inserted_at])
  end

  def get_provider(user, id) do
    case Repo.get_by(UserProvider, id: id, user_id: user.id) do
      nil -> {:error, :not_found}
      p   -> {:ok, p}
    end
  end

  def create_provider(user, attrs) do
    %UserProvider{}
    |> UserProvider.changeset(Map.put(attrs, "user_id", user.id))
    |> Repo.insert()
  end

  def delete_provider(user, id) do
    with {:ok, p} <- get_provider(user, id), do: Repo.delete(p)
  end

  def set_active(user, id) do
    with {:ok, p} <- get_provider(user, id) do
      Repo.update_all(
        from(x in UserProvider,
          where: x.user_id == ^user.id and x.provider_type == ^p.provider_type),
        set: [is_active: false])
      p |> Ecto.Changeset.change(is_active: true) |> Repo.update()
    end
  end

  def set_managed(user) do
    Repo.update_all(
      from(p in UserProvider, where: p.user_id == ^user.id),
      set: [is_active: false])
    :ok
  end

  def test_connection(user, id) do
    with {:ok, p} <- get_provider(user, id) do
      cfg = build_adapter_config(p)
      key = "przma-test-#{System.os_time(:second)}"
      case StorageProvider.put(cfg, key, "przma-ok", "text/plain") do
        :ok ->
          StorageProvider.delete(cfg, key)
          p |> Ecto.Changeset.change(is_verified: true,
               verified_at: DateTime.utc_now() |> DateTime.truncate(:second))
            |> Repo.update()
          {:ok, :connected}
        {:error, r} ->
          {:error, {:connection_failed, inspect(r)}}
      end
    end
  end

  def build_adapter_config(%UserProvider{} = p) do
    %{
      adapter:    Alem.Adapters.Storage.S3Adapter,
      bucket:     p.bucket,
      endpoint:   p.endpoint,
      region:     p.region || "us-east-1",
      access_key: decrypt(p.enc_access_key),
      secret_key: decrypt(p.enc_secret_key),
      managed:    false
    }
  end

  def active_storage_provider(user) do
    case Repo.get_by(UserProvider,
           user_id: user.id, provider_type: "storage", is_active: true) do
      nil -> {:managed, StorageProvider.default_provider()}
      p   -> {:custom, build_adapter_config(p)}
    end
  end

  defp decrypt(nil), do: nil
  defp decrypt(enc) do
    case Base.decode64(enc) do
      {:ok, k} -> k
      _        -> enc
    end
  end
end
