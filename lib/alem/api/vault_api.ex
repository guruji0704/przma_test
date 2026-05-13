defmodule Alem.Api.VaultApi do
  @moduledoc """
  Vault management API. All vault-level operations.
  LiveView calls this for vault listing, stats, and management.
  """

  alias Alem.Repo
  alias Alem.Storage.Paths
  alias Alem.Schemas.Document
  import Ecto.Query

  @doc "Initialize all three vaults for a new user"
  def create_vaults_for_user(user) do
    did = user.did_id
    for vault <- [:personal, :private, :public] do
      ns_key = Paths.namespace_key(did, vault)
      %{
        vault:     vault,
        root:      Paths.vault_root(did, vault),
        cas_root:  Paths.cas_path(did, vault, ""),
        namespace: ns_key
      }
    end
  end

  @doc "Get stats for all vaults"
  def all_vault_stats(user) do
    stats = Repo.all(
      from d in Document,
      where: d.user_id == ^user.id,
      group_by: d.folder,
      select: {d.folder, count(d.id)}
    ) |> Map.new()

    %{
      personal: Map.get(stats, "personal", 0),
      private:  Map.get(stats, "private",  0),
      public:   Map.get(stats, "public",   0),
      shared:   Map.get(stats, "shared",   0),
      total:    Enum.sum(Map.values(stats))
    }
  end

  @doc "Get recent files across all vaults"
  def recent_files(user, limit \\ 20) do
    Repo.all(
      from d in Document,
      where: d.user_id == ^user.id,
      order_by: [desc: d.inserted_at],
      limit: ^limit
    )
  end

  @doc "Namespace key for a DID + vault combination"
  def namespace_key(did, vault), do: Paths.namespace_key(did, vault)

  @doc "Full S3 path structure for a user (for display/debugging)"
  def path_structure(did) do
    p = Paths.did_prefix(did)
    %{
      personal: %{
        root:      "home/#{p}/personal",
        cas:       "home/#{p}/personal/cas/{ab}/{cd}/{hash}",
        documents: "home/#{p}/personal/documents/{doc_id}/{filename}",
        vectors:   "home/#{p}/personal/vectors"
      },
      private: %{
        root:      "home/#{p}/private",
        cas:       "home/#{p}/private/cas/{ab}/{cd}/{hash}",
        encrypted: "home/#{p}/private/encrypted/{doc_id}/{filename}"
      },
      public: %{
        root:      "home/#{p}/public",
        cas:       "home/#{p}/public/cas/{ab}/{cd}/{hash}",
        documents: "home/#{p}/public/documents/{doc_id}/{filename}",
        vectors:   "home/#{p}/public/vectors"
      },
      shared: %{
        root:      "home/#{p}/shared",
        documents: "home/#{p}/shared/documents/{doc_id}/{filename}"
      }
    }
  end
end
