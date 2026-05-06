defmodule Alem.Home do
  @moduledoc """
  THE HOME FOLDER GATEWAY.

  Every user has exactly 3 folders:
    personal  — private by default, shareable by token
    private   — E2EE, server sees only ciphertext, no vector on server
    public    — open, PRZMA Commons reads this

  This module is the ONLY place that creates home folders.
  Call Alem.Home.create_for_user/1 after registration.
  Call Alem.Home.upload/4 to store a file in a folder.
  Call Alem.Home.list_files/3 to list files in a folder.
  """

  import Ecto.Query
  alias Alem.{Repo, DID}
  alias Alem.Schemas.{Namespace, Document}
  alias Alem.Storage.{CAS, ObjectStore}
  alias Alem.Home.{Uploader, Lister, Access}
  require Logger

  @bucket System.get_env("AWS_S3_BUCKET", "perkeep")
  @folders ~w(personal private public)

  # ── Lifecycle ─────────────────────────────────────────────────────────────

  @doc """
  Create 3 namespaces for a new user. Call this right after registration.

  Returns {:ok, %{personal: ns, private: ns, public: ns}}
  """
  def create_for_user(%{id: user_id, did_id: did_id}) when is_binary(did_id) do
    prefix = DID.namespace_key(did_id)

    results =
      @folders
      |> Enum.map(fn folder ->
        ns_key = "#{prefix}-#{folder}"

        attrs = %{
          id:             ns_key,
          tenant_id:      ns_key,
          did:            did_id,
          identity_type:  "did",
          folder_type:    folder,
          parent_did:     did_id,
          config: %{
            storage: %{
              s3_bucket:  @bucket,
              s3_prefix:  "user/#{prefix}/#{folder}/",
            },
            # private folder: zero server knowledge
            encrypted:   folder == "private",
            # public folder: commons indexer watches this
            commons_indexed: folder == "public",
          },
          status:           "active",
          last_activity_at: DateTime.utc_now()
        }

        case Repo.get(Namespace, ns_key) do
          nil ->
            Repo.insert(%Namespace{} |> Namespace.changeset(attrs))

          existing ->
            Logger.info("[Home] Namespace #{ns_key} already exists — skipping")
            {:ok, existing}
        end
      end)

    errors = Enum.filter(results, &match?({:error, _}, &1))

    if errors == [] do
      [personal, private, public] = Enum.map(results, fn {:ok, ns} -> ns end)
      Logger.info("[Home] ✅ Created 3 folders for #{did_id}")
      {:ok, %{personal: personal, private: private, public: public}}
    else
      Logger.error("[Home] ❌ Failed to create some folders for #{did_id}: #{inspect(errors)}")
      {:error, errors}
    end
  end

  @doc "Get all 3 namespaces for a user by DID."
  def folders_for(did_id) do
    prefix = DID.namespace_key(did_id)

    ns_map =
      Repo.all(
        from n in Namespace,
        where: n.parent_did == ^did_id and n.folder_type in ^@folders,
        order_by: n.folder_type
      )
      |> Map.new(&{&1.folder_type, &1})

    {:ok, ns_map}
  end

  @doc "Get one namespace for a user + folder combo."
  def get_namespace(did_id, folder) when folder in @folders do
    prefix = DID.namespace_key(did_id)
    ns_key = "#{prefix}-#{folder}"
    case Repo.get(Namespace, ns_key) do
      nil -> {:error, :not_found}
      ns  -> {:ok, ns}
    end
  end

  # ── Upload ────────────────────────────────────────────────────────────────

  @doc """
  Upload a file to a specific folder.

  For personal + public: runs full CAS pipeline (dedup + LanceDB vector).
  For private:          stores encrypted blob only — NO CAS, NO vector on server.

  Returns {:ok, document}
  """
  def upload(file_bytes, filename, content_type, opts) do
    folder    = Keyword.get(opts, :folder, "personal")
    user_id   = Keyword.fetch!(opts, :user_id)
    did_id    = Keyword.fetch!(opts, :did_id)
    encrypted = Keyword.get(opts, :encrypted, false)
    # For private folder, caller encrypts on device first and sets encrypted: true

    Uploader.run(file_bytes, filename, content_type, %{
      folder:    folder,
      user_id:   user_id,
      did_id:    did_id,
      encrypted: encrypted or folder == "private"
    })
  end

  # ── List ──────────────────────────────────────────────────────────────────

  @doc """
  List files in a specific folder for a user.
  Returns list of document maps.
  """
  def list_files(user_id, folder, opts \\ []) when folder in @folders do
    Lister.run(user_id, folder, opts)
  end

  @doc "List files across all 3 folders."
  def list_all(user_id, opts \\ []) do
    Enum.flat_map(@folders, fn folder ->
      case list_files(user_id, folder, opts) do
        {:ok, files} -> files
        _ -> []
      end
    end)
  end

  # ── Presigned URL ─────────────────────────────────────────────────────────

  @doc """
  Get a 1-hour presigned S3 download URL for a document.
  Validates the requesting user owns this document.
  """
  def presign(doc_id, user_id) do
    Access.presign(doc_id, user_id)
  end

  # ── Delete ────────────────────────────────────────────────────────────────

  @doc """
  Remove a file from a folder.
  Decrements CAS ref_count. If ref_count reaches 0, S3 object is deleted.
  For public folder: also removes from commons_index.
  """
  def delete(doc_id, user_id) do
    case Repo.one(from d in Document,
           where: d.id == ^doc_id and d.user_id == ^user_id) do
      nil ->
        {:error, :not_found}

      doc ->
        Repo.delete(doc)

        # Decrement CAS ref_count
        if doc.content_hash do
          Alem.Cas.decrement_ref_count(doc.content_hash)
          # If ref_count reaches 0, GC will clean S3 (deferred cleanup job)
        end

        # If public → remove from commons
        if doc.folder == "public" do
          Alem.Commons.remove(doc.id)
        end

        {:ok, doc}
    end
  end
end
