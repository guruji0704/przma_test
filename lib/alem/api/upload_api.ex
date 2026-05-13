defmodule Alem.Api.UploadApi do
  @moduledoc """
  All upload business logic. LiveView MUST call this — never run upload
  logic directly in LiveView or controllers.

  Usage:
    {:ok, result} = UploadApi.upload(user, :personal, %{path:, filename:, content_type:, size:})
    {:ok, result} = UploadApi.random_upload(user, %{...})
    {:ok, files}  = UploadApi.list_files(user, :personal, [])
    {:ok, stats}  = UploadApi.vault_stats(user)
    {:ok, url}    = UploadApi.presigned_url(user, doc_id)
    :ok           = UploadApi.delete_file(user, doc_id, :for_me)
  """

  import Ecto.Query
  alias Alem.Repo
  alias Alem.Storage.{Paths, VaultCas}
  alias Alem.Cas.CasDedupRef
  alias Alem.Schemas.Document
  alias Alem.Services.StorageProvider
  alias Alem.Events
  alias Alem.Events.FileUploaded
  require Logger

  # ── Upload ─────────────────────────────────────────────────────────────────

  @doc "Upload file to a specific vault. Full CAS pipeline."
  def upload(user, vault, %{path: path, filename: filename,
                             content_type: content_type} = _params)
      when is_atom(vault) do
    did = user.did_id

    with {:ok, bytes}          <- read_file(path),
         {:ok, hash, s3_key}  <- VaultCas.put(user, vault, bytes, content_type),
         {:ok, doc}            <- create_document(user, did, vault, hash, s3_key, filename, content_type, byte_size(bytes)),
         :ok                   <- create_dedup_ref(did, vault, hash, doc.id, filename) do

      Events.publish(FileUploaded.new(%{
        doc_id: doc.id, user_id: user.id, did: did, vault: vault,
        filename: filename, content_type: content_type,
        content_hash: hash, file_size: byte_size(bytes),
        namespace_key: Paths.namespace_key(did, vault), s3_key: s3_key
      }))

      Logger.info("[UploadApi] ✅ #{vault} #{doc.id} #{filename}")
      {:ok, %{doc: doc, hash: hash, s3_key: s3_key, vault: vault}}
    end
  end

  def upload(user, vault, params) when is_binary(vault) do
    case Paths.parse_vault(vault) do
      {:ok, v}    -> upload(user, v, params)
      {:error, _} -> {:error, :invalid_vault}
    end
  end

  @doc "Upload to random vault (0=personal, 1=private, 2=public). For testing vault distribution."
  def random_upload(user, params) do
    vault_num  = :rand.uniform(3) - 1
    vault      = %{0 => :personal, 1 => :private, 2 => :public}[vault_num]
    case upload(user, vault, params) do
      {:ok, result} -> {:ok, Map.merge(result, %{vault_num: vault_num, vault_name: to_string(vault)})}
      err           -> err
    end
  end

  # ── List ───────────────────────────────────────────────────────────────────

  @doc "List files in a vault with optional sort/filter/search/pagination"
  def list_files(user, vault, opts \\ []) do
    limit      = Keyword.get(opts, :limit, 200)
    sort       = Keyword.get(opts, :sort, :newest)
    search     = Keyword.get(opts, :search)
    filter     = Keyword.get(opts, :filter)
    vault_str  = to_string(vault)

    q = from d in Document,
      where: d.user_id == ^user.id and d.folder == ^vault_str,
      limit: ^limit

    q = if search, do: where(q, [d], ilike(d.filename, ^"%#{search}%")), else: q

    q = if filter do
      cat = media_category(filter)
      where(q, [d], d.media_category == ^cat)
    else
      q
    end

    q = case sort do
      :newest -> order_by(q, [d], desc: d.inserted_at)
      :oldest -> order_by(q, [d], asc:  d.inserted_at)
      :az     -> order_by(q, [d], asc:  d.filename)
      :za     -> order_by(q, [d], desc: d.filename)
      _       -> order_by(q, [d], desc: d.inserted_at)
    end

    {:ok, Repo.all(q)}
  rescue
    e -> {:error, Exception.message(e)}
  end

  # ── Stats ──────────────────────────────────────────────────────────────────

  @doc "File counts per vault"
  def vault_stats(user) do
    stats = Repo.all(
      from d in Document,
      where: d.user_id == ^user.id,
      group_by: d.folder,
      select: {d.folder, count(d.id)}
    ) |> Map.new()

    {:ok, %{
      personal: Map.get(stats, "personal", 0),
      private:  Map.get(stats, "private",  0),
      public:   Map.get(stats, "public",   0),
      shared:   Map.get(stats, "shared",   0),
      total:    Enum.sum(Map.values(stats))
    }}
  end

  # ── Presigned URL ──────────────────────────────────────────────────────────

  @doc "Generate presigned download URL for a document (expires_in: seconds)"
  def presigned_url(user, doc_id, opts \\ []) do
    expires_in = Keyword.get(opts, :expires_in, 3600)
    with {:ok, doc} <- get_doc(user, doc_id) do
      provider = StorageProvider.for_user(user)
      StorageProvider.presigned_url(provider, doc.object_key, expires_in: expires_in)
    end
  end

  # ── Delete ─────────────────────────────────────────────────────────────────

  @doc "Delete file. type: :for_me | :for_everyone"
  def delete_file(user, doc_id, type \\ :for_me) do
    with {:ok, doc} <- get_doc(user, doc_id) do
      case type do
        :for_me ->
          Repo.update_all(
            from(d in Document, where: d.id == ^doc_id and d.user_id == ^user.id),
            set: [status: "deleted_for_me"]
          )
          {:ok, :deleted_for_me}

        :for_everyone ->
          provider = StorageProvider.for_user(user)
          StorageProvider.delete(provider, doc.object_key)
          Repo.delete(doc)
          {:ok, :deleted_for_everyone}
      end
    end
  end

  # ── Private ────────────────────────────────────────────────────────────────

  defp read_file(path) do
    case File.read(path) do
      {:ok, b}    -> {:ok, b}
      {:error, e} -> {:error, {:read_error, e}}
    end
  end

  defp create_document(user, did, vault, hash, _s3_key, filename, content_type, _file_size) do
    doc_id  = Ecto.UUID.generate()
    ns_key  = Paths.namespace_key(did, vault)
    obj_key = Paths.doc_path(did, vault, doc_id, filename)
    now     = DateTime.utc_now() |> DateTime.truncate(:second)

    doc = Repo.insert!(%Document{
      id:             doc_id,
      user_id:        user.id,
      tenant_id:      ns_key,
      filename:       filename,
      content_type:   content_type,
      folder:         to_string(vault),
      media_category: detect_category(content_type),
      is_encrypted:   vault == :private,
      status:         "synced",
      content_hash:   hash,
      object_key:     obj_key,
      inserted_at:    now,
      updated_at:     now
    })
    {:ok, doc}
  rescue
    e -> {:error, {:db_error, Exception.message(e)}}
  end

  defp create_dedup_ref(did, vault, hash, doc_id, filename) do
    ns_key = Paths.namespace_key(did, vault)
    now    = DateTime.utc_now() |> DateTime.truncate(:second)
    Repo.insert!(%CasDedupRef{
      tenant_id: ns_key, namespace_key: ns_key, actor_did: did,
      content_hash: hash, document_id: doc_id,
      user_filename: filename, is_active: true,
      inserted_at: now, updated_at: now
    })
    :ok
  rescue
    _ -> :ok
  end

  defp get_doc(user, doc_id) do
    case Repo.get_by(Document, id: doc_id, user_id: user.id) do
      nil -> {:error, :not_found}
      doc -> {:ok, doc}
    end
  end

  defp detect_category(ct) do
    cond do
      String.starts_with?(ct, "image/") -> "image"
      String.starts_with?(ct, "video/") -> "video"
      String.starts_with?(ct, "audio/") -> "audio"
      true -> "documents"
    end
  end

  defp media_category("audio"),    do: "audio"
  defp media_category("video"),    do: "video"
  defp media_category("image"),    do: "image"
  defp media_category("document"), do: "documents"
  defp media_category(_),          do: nil
end
