defmodule Alem.Storage.CAS do
  @moduledoc """
  Content Addressable Storage — the S3 side.
  Computes SHA-256 hash, checks for existing content, uploads if new.

  Two users uploading the same file:
    → same hash → CAS detects existing → S3 NOT written again → ref_count + 1

  This module only handles S3. All DB operations go through Alem.Cas context.
  """

  require Logger
  alias Alem.{Repo, Storage.ObjectStore}
  alias Alem.Cas.CasObject

  @bucket System.get_env("AWS_S3_BUCKET", "perkeep")

  @doc """
  Store file bytes in CAS (S3 + DB).
  If same bytes exist → skip S3, increment ref_count.
  Returns {:ok, cas_object}.
  """
  def put(data, media_type \\ "application/octet-stream") do
    hash = compute_hash(data)

    case Repo.get(CasObject, hash) do
      nil ->
        # New content — upload to S3
        s3_key = s3_key_for(hash)
        Logger.info("[CAS] New content #{String.slice(hash, 0, 16)}… uploading #{byte_size(data)} bytes")

        case ObjectStore.put(@bucket, s3_key, data, %{content_type: media_type}) do
          :ok ->
            attrs = %{
              content_hash:    hash,
              storage_backend: "s3",
              storage_key:     s3_key,
              media_type:      media_type,
              file_size:       byte_size(data),
              ref_count:       1,
              namespace_key:   Map.get(ctx, :namespace_key, "system"),
              actor_did:       Map.get(ctx, :actor_did, "system"),
              user_id:         Map.get(ctx, :user_id, "system")
            }

            case Repo.insert(CasObject.ingest_changeset(%CasObject{}, attrs)) do
              {:ok, cas_obj} ->
                Logger.info("[CAS] ✅ Stored #{String.slice(hash, 0, 16)}…")
                {:ok, cas_obj}
              {:error, cs} ->
                {:error, cs}
            end

          {:error, reason} ->
            Logger.error("[CAS] ❌ S3 upload failed: #{inspect(reason)}")
            {:error, reason}
        end

      existing ->
        # Same bytes already in S3 — just increment ref_count
        Logger.info("[CAS] Dedup hit #{String.slice(hash, 0, 16)}… reusing (ref_count #{existing.ref_count + 1})")
        existing
        |> Ecto.Changeset.change(ref_count: existing.ref_count + 1)
        |> Repo.update()
    end
  end

  @doc "Generate a signed S3 download URL valid for 1 hour."
  def get_signed_url(content_hash, expires_in \\ 3600) do
    case Repo.get(CasObject, content_hash) do
      nil     -> {:error, :not_found}
      cas_obj -> ObjectStore.presigned_download_url(@bucket, cas_obj.storage_key, expires_in: expires_in)
    end
  end

  @doc "True if these bytes are already in CAS."
  def exists?(hash), do: Repo.get(CasObject, hash) != nil

  @doc "SHA-256 hex string of raw bytes."
  def compute_hash(data) do
    :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
  end

  # S3 key uses 2-level prefix to avoid hot-spotting (max 10k objects per prefix)
  # e.g. hash = "a7f8e9d2..." → key = "cas/a7/f8/a7f8e9d2..."
  defp s3_key_for(hash) do
    "cas/#{String.slice(hash, 0, 2)}/#{String.slice(hash, 2, 2)}/#{hash}"
  end
end
