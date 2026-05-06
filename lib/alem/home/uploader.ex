defmodule Alem.Home.Uploader do
  @moduledoc """
  Handles the upload pipeline for all 3 folder types.

  Personal + Public:
    1. Compute SHA-256 (CAS dedup)
    2. Upload to S3 (skipped if dedup hit)
    3. Insert document row
    4. Insert cas_dedup_ref
    5. Encode 446-dim vector → LanceDB (server)
    6. If public → add to commons_index

  Private:
    1. Receive encrypted blob (device already encrypted it)
    2. Upload encrypted blob to S3 — server NEVER sees plaintext
    3. Insert document row (is_encrypted=true)
    4. NO CAS hash (can't hash ciphertext for dedup)
    5. NO LanceDB on server (vector encoded on device only)
  """

  require Logger
  import Ecto.Query
  alias Alem.{Repo, DID}
  alias Alem.Schemas.{Document, ShareToken}
  alias Alem.Storage.{CAS, ObjectStore}
  alias Alem.Lance.{VectorEncoder, DISSupervisor}
  alias Alem.LanceDB

  @bucket System.get_env("AWS_S3_BUCKET", "perkeep")

  def run(file_bytes, filename, content_type, ctx) do
    folder    = ctx.folder
    user_id   = ctx.user_id
    did_id    = ctx.did_id
    encrypted = Map.get(ctx, :encrypted, false)

    if folder == "private" or encrypted do
      upload_private(file_bytes, filename, content_type, ctx)
    else
      upload_open(file_bytes, filename, content_type, ctx)
    end
  end

  # ── Private folder upload (E2EE — server zero knowledge) ──────────────────

  defp upload_private(cipher_bytes, filename, content_type, ctx) do
    user_id = ctx.user_id
    did_id  = ctx.did_id
    prefix  = DID.namespace_key(did_id)
    doc_id  = Ecto.UUID.generate()

    # Encrypted files go to /private/encrypted/ — no media_category routing
    s3_key = "user/#{prefix}/private/encrypted/#{doc_id}/#{filename}"

    Logger.info("[Uploader] Private upload #{filename} — server sees ciphertext only")

    with :ok <- ObjectStore.put(@bucket, s3_key, cipher_bytes, %{content_type: "application/octet-stream"}),
         {:ok, doc} <- insert_document(%{
           id:           doc_id,
           user_id:      user_id,
           tenant_id:    "#{prefix}-private",
           filename:     filename,
           content_type: content_type,
           object_key:   s3_key,
           folder:       "private",
           media_category: "encrypted",
           is_encrypted: true,
           status:       "synced"
         }) do
      Logger.info("[Uploader] ✅ Private doc #{doc_id} stored encrypted")
      {:ok, doc}
    else
      {:error, reason} ->
        Logger.error("[Uploader] ❌ Private upload failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ── Personal / Public upload (CAS + LanceDB) ──────────────────────────────

  defp upload_open(file_bytes, filename, content_type, ctx) do
    user_id   = ctx.user_id
    did_id    = ctx.did_id
    folder    = ctx.folder
    prefix    = DID.namespace_key(did_id)
    ns_key    = "#{prefix}-#{folder}"
    doc_id    = Ecto.UUID.generate()
    category  = Document.media_category(content_type)
    s3_key    = Document.s3_key(prefix, folder, doc_id, filename, content_type)

    Logger.info("[Uploader] #{folder} upload #{filename} (#{byte_size(file_bytes)} bytes)")

    with {:ok, cas_obj} <- CAS.put(file_bytes, content_type, %{
           namespace_key: ns_key,
           actor_did:     did_id
         }),
         {:ok, doc} <- insert_document(%{
           id:             doc_id,
           user_id:        user_id,
           tenant_id:      ns_key,
           filename:       filename,
           content_type:   content_type,
           object_key:     s3_key,
           content_hash:   cas_obj.content_hash,
           folder:         folder,
           media_category: category,
           is_encrypted:   false,
           status:         "synced"
         }),
         :ok <- insert_dedup_ref(doc, cas_obj, ns_key, did_id),
         :ok <- encode_vector(file_bytes, content_type, doc, folder, did_id) do

      # Public → index in commons
      if folder == "public" do
        Alem.Commons.index(doc, cas_obj)
      end

      Logger.info("[Uploader] ✅ #{folder} doc #{doc_id} stored")
      {:ok, doc}
    else
      {:error, reason} ->
        Logger.error("[Uploader] ❌ #{folder} upload failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp insert_document(attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    attrs
    |> Map.merge(%{inserted_at: now, updated_at: now})
    |> then(&Repo.insert(%Document{} |> Document.changeset(&1)))
  end

  defp insert_dedup_ref(doc, cas_obj, ns_key, actor_did) do
    try do
      Repo.insert!(%Alem.Cas.CasDedupRef{
        namespace_key:  ns_key,
        actor_did:      actor_did,
        content_hash:   cas_obj.content_hash,
        document_id:    doc.id,
        user_filename:  doc.filename,
        is_active:      true
      })
      :ok
    rescue e ->
      Logger.warning("[Uploader] CasDedupRef insert failed: #{Exception.message(e)}")
      :ok  # non-fatal
    end
  end

  defp encode_vector(file_bytes, content_type, doc, folder, did_id) do
    try do
      cls = %{
        "seven_p_primary"   => classify_seven_p(content_type),
        "preserve_primary"  => "engagement",
        "light_element"     => "transform"
      }

      vec = VectorEncoder.encode(file_bytes, content_type, cls)
      DISSupervisor.ensure_writer(did_id)

      LanceDB.insert_with_vector("perception_events", vec,
        Jason.encode!(%{
          "id"               => doc.id,
          "verb"             => "Create",
          "media_type"       => content_type,
          "filename"         => doc.filename,
          "folder"           => folder,
          "seven_p_primary"  => cls["seven_p_primary"],
          "preserve_primary" => cls["preserve_primary"],
          "light_element"    => cls["light_element"],
          "user_did"         => did_id,
          "commons"          => folder == "public"
        })
      )
      :ok
    rescue e ->
      Logger.warning("[Uploader] LanceDB vector failed: #{Exception.message(e)}")
      :ok  # non-fatal
    end
  end

  defp classify_seven_p(ct) do
    cond do
      String.starts_with?(ct, "audio/") -> "portfolio"
      String.starts_with?(ct, "video/") -> "perception"
      String.starts_with?(ct, "image/") -> "platform"
      true -> "product"
    end
  end
end
