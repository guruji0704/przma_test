defmodule Alem.FileDelete do
  @moduledoc """
  Two-type delete system per Sir's design.

  DELETE FOR ME:
    → File moves to archive
    → Disappears from user's vault view
    → All shares STILL WORK (others not affected)
    → 60 day recovery window
    → After 60 days → permanent delete from S3

  DELETE FOR EVERYONE:
    → All perception links immediately invalid
    → S3 deleted if ref_count = 0
    → Users who already SAVED file keep their copy
    → No restore possible

  RESTORE:
    → Any time within 60 days
    → File returns to vault
    → All original shares resume working
  """

  import Ecto.Query
  alias Alem.{Repo, Cas}
  alias Alem.Schemas.{Document, Archive, PerceptionLink}
  require Logger

  @archive_days 60

  # ── Delete For Me ─────────────────────────────────────────────────────────

  @doc """
  Soft delete — file hidden from vault, recoverable for 60 days.
  Other users' access via perception links: UNAFFECTED.
  """
  def delete_for_me(document_id, owner_did) do
    case get_owned_doc(document_id, owner_did) do
      nil -> {:error, :not_found}
      doc ->
        now        = DateTime.utc_now() |> DateTime.truncate(:second)
        expires_at = DateTime.add(now, @archive_days * 86_400, :second)

        Repo.transaction(fn ->
          # Mark document as archived
          Repo.update!(
            Document.changeset(doc, %{
              deleted_for_me_at: now,
              is_archived:       true
            })
          )

          # Create archive record for recovery
          %Archive{}
          |> Archive.changeset(%{
            document_id: document_id,
            owner_did:   owner_did,
            archived_at: now,
            expires_at:  expires_at
          })
          |> Repo.insert!()

          Logger.info("[FileDelete] 🗂️  #{document_id} archived by #{owner_did}. Recoverable until #{Date.to_string(DateTime.to_date(expires_at))}")
          :ok
        end)
    end
  end

  # ── Delete For Everyone ───────────────────────────────────────────────────

  @doc """
  Hard delete — all perception links immediately invalid.
  Users who already SAVED to their own vault keep their copy.
  S3 deleted only if ref_count reaches 0.
  No restore possible.
  """
  def delete_for_everyone(document_id, owner_did) do
    case get_owned_doc(document_id, owner_did) do
      nil -> {:error, :not_found}
      doc ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        Repo.transaction(fn ->
          # 1. Revoke ALL perception links for this document immediately
          {revoked_count, _} =
            Repo.update_all(
              from(p in PerceptionLink,
                where: p.document_id == ^document_id and
                       is_nil(p.revoked_at)),
              set: [revoked_at: now, revoked_by_did: owner_did]
            )

          Logger.info("[FileDelete] 🔥 Revoked #{revoked_count} links for #{document_id}")

          # 2. Mark document as deleted for everyone
          Repo.update!(
            Document.changeset(doc, %{
              deleted_for_everyone_at: now
            })
          )

          # 3. Remove cas_dedup_ref for owner's namespace
          Repo.update_all(
            from(r in Alem.Cas.CasDedupRef,
              where: r.document_id == ^document_id),
            set: [is_active: false]
          )

          # 4. Decrement ref_count in cas_objects
          if doc.content_hash do
            Repo.update_all(
              from(c in Alem.Cas.CasObject,
                where: c.content_hash == ^doc.content_hash),
              inc: [ref_count: -1]
            )

            # 5. Check if ref_count hit 0 — delete from S3 if so
            ref_count = Repo.one(
              from c in Alem.Cas.CasObject,
              where: c.content_hash == ^doc.content_hash,
              select: c.ref_count
            )

            if ref_count != nil and ref_count <= 0 do
              cas_obj = Repo.get(Alem.Cas.CasObject, doc.content_hash)
              if cas_obj do
                delete_from_s3(cas_obj.storage_key)
                Repo.delete(cas_obj)
                Logger.info("[FileDelete] 🗑️  S3 object deleted: #{cas_obj.storage_key}")
              end
            else
              Logger.info("[FileDelete] S3 kept — ref_count=#{ref_count} (others have saved copies)")
            end
          end

          Logger.info("[FileDelete] 💀 #{document_id} deleted for everyone by #{owner_did}")
          :ok
        end)
    end
  end

  # ── Restore ───────────────────────────────────────────────────────────────

  @doc """
  Restore a file from archive within 60 days.
  File returns to vault. Original shares resume working.
  """
  def restore(document_id, owner_did) do
    archive = Repo.one(
      from a in Archive,
      where: a.document_id == ^document_id and
             a.owner_did == ^owner_did and
             is_nil(a.restored_at) and
             is_nil(a.permanently_deleted_at)
    )

    cond do
      is_nil(archive) ->
        {:error, :not_in_archive}

      DateTime.compare(archive.expires_at, DateTime.utc_now()) != :gt ->
        {:error, :archive_expired}

      true ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)
        doc = Repo.get(Document, document_id)

        Repo.transaction(fn ->
          # Restore document
          Repo.update!(
            Document.changeset(doc, %{
              deleted_for_me_at: nil,
              is_archived:       false
            })
          )

          # Mark archive as restored
          Repo.update!(Archive.changeset(archive, %{restored_at: now}))

          Logger.info("[FileDelete] ♻️  #{document_id} restored by #{owner_did}")
          :ok
        end)
    end
  end

  # ── Save to My Vault ─────────────────────────────────────────────────────

  @doc """
  Recipient saves a shared file to their own personal vault.
  Creates their own CAS reference — independent of original owner.
  If original owner deletes: recipient KEEPS their copy.
  """
  def save_to_vault(perception_link_id, saver_did, target_folder \\ "personal") do
    link = Repo.get(PerceptionLink, perception_link_id)

    cond do
      is_nil(link) ->
        {:error, :link_not_found}

      not PerceptionLink.valid?(link) ->
        {:error, :link_invalid}

      true ->
        original_doc = Repo.get(Alem.Schemas.Document, link.document_id)

        if is_nil(original_doc) do
          {:error, :original_deleted}
        else
          # Create a new document record in saver's vault
          # pointing to the SAME CAS hash (zero extra S3 space)
          saver_user = Repo.get_by(Alem.Pleroma.User, did_id: saver_did)
          prefix     = Alem.DID.namespace_key(saver_did)
          doc_id     = Ecto.UUID.generate()
          now        = DateTime.utc_now() |> DateTime.truncate(:second)
          ns_key     = "#{prefix}-#{target_folder}"
          category   = Alem.Schemas.Document.media_category(original_doc.content_type)
          s3_key     = Alem.Schemas.Document.s3_key(
                         prefix, target_folder, doc_id,
                         original_doc.filename, original_doc.content_type)

          Repo.transaction(fn ->
            # New document row for the saver
            saved_doc = Repo.insert!(%Alem.Schemas.Document{
              id:             doc_id,
              user_id:        saver_user.id,
              tenant_id:      ns_key,
              filename:       original_doc.filename,
              content_type:   original_doc.content_type,
              object_key:     s3_key,
              content_hash:   original_doc.content_hash,
              folder:         target_folder,
              media_category: category,
              is_encrypted:   false,
              status:         "synced",
              inserted_at:    now,
              updated_at:     now
            })

            # Increment CAS ref_count — saver now has own reference
            if original_doc.content_hash do
              Repo.update_all(
                from(c in Alem.Cas.CasObject,
                  where: c.content_hash == ^original_doc.content_hash),
                inc: [ref_count: 1]
              )

              # New dedup_ref for saver's namespace
              Repo.insert!(%Alem.Cas.CasDedupRef{
                tenant_id:     ns_key,
                namespace_key: ns_key,
                actor_did:     saver_did,
                content_hash:  original_doc.content_hash,
                document_id:   doc_id,
                user_filename: original_doc.filename,
                is_active:     true
              })
            end

            Logger.info("[FileDelete] 💾 #{original_doc.filename} saved to #{saver_did}'s #{target_folder}")
            saved_doc
          end)
        end
    end
  end

  # ── Archive Cleanup Job ──────────────────────────────────────────────────

  @doc """
  Run daily to permanently delete files that have been in archive
  for more than 60 days. Call from a scheduled task.
  """
  def cleanup_expired_archives do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    expired =
      Repo.all(
        from a in Archive,
        where: a.expires_at <= ^now and
               is_nil(a.restored_at) and
               is_nil(a.permanently_deleted_at)
      )

    Enum.each(expired, fn archive ->
      doc = Repo.get(Alem.Schemas.Document, archive.document_id)

      if doc do
        # Now permanently delete
        delete_for_everyone(archive.document_id, archive.owner_did)
      end

      Repo.update!(
        Archive.changeset(archive, %{permanently_deleted_at: now})
      )

      Logger.info("[Archive] 🗑️  Expired archive cleaned: #{archive.document_id}")
    end)

    Logger.info("[Archive] Cleanup done. #{length(expired)} archives processed.")
    {:ok, length(expired)}
  end

  # ── List Archives ─────────────────────────────────────────────────────────

  @doc "List files in user's archive (recoverable)."
  def list_archives(owner_did) do
    now = DateTime.utc_now()

    Repo.all(
      from a in Archive,
      join: d in Alem.Schemas.Document, on: d.id == a.document_id,
      where: a.owner_did == ^owner_did and
             a.expires_at > ^now and
             is_nil(a.restored_at) and
             is_nil(a.permanently_deleted_at),
      select: %{
        archive_id:   a.id,
        document_id:  a.document_id,
        filename:     d.filename,
        content_type: d.content_type,
        folder:       d.folder,
        archived_at:  a.archived_at,
        expires_at:   a.expires_at,
        days_left:    fragment("EXTRACT(DAY FROM ? - NOW())::integer", a.expires_at)
      },
      order_by: [asc: a.expires_at]
    )
  end

  # ── Private ───────────────────────────────────────────────────────────────

  defp get_owned_doc(document_id, owner_did) do
    user = Repo.get_by(Alem.Pleroma.User, did_id: owner_did)
    if user do
      Repo.get_by(Alem.Schemas.Document, id: document_id, user_id: user.id)
    end
  end

  defp delete_from_s3(storage_key) do
    bucket = System.get_env("AWS_S3_BUCKET", "perkeep")
    try do
      ExAws.S3.delete_object(bucket, storage_key)
      |> ExAws.request(virtual_host: false)
    rescue e ->
      Logger.error("[FileDelete] S3 delete failed for #{storage_key}: #{Exception.message(e)}")
    end
  end
end
