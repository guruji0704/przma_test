defmodule Alem.Lance.VaultStore do
  @moduledoc """
  Server-side three-vault architecture backed by LanceDB on S3.

  Each user's documents are stored in three separate LanceDB tables:
    personal_vault  — personal files
    private_vault   — E2EE encrypted private files
    social_vault    — shared / social files

  Tables are shared across all users; per-user isolation is enforced by the
  `user_did` column.  Tables are created on first write (no pre-provisioning).

  The schema is a lightweight metadata mirror of the client vault tables:
  file bytes stay in S3; only metadata + semantic vector live here.

  Primary use: semantic/vector search per vault.
  Secondary use: server-side sync index (complements PostgreSQL documents).
  """

  require Logger

  @vault_tables %{
    "personal" => "personal_vault",
    "private"  => "private_vault",
    "social"   => "social_vault"
  }

  @doc """
  Upserts a document record into the appropriate server vault table.

  `vault_category` is one of "personal", "private", "social".
  `vector` is a list of 128 floats (semantic embedding); pass [] to store zeros.
  `attrs` map must include:
    doc_id, user_did, namespace_key, filename, content_type, file_size,
    status, device_id, content_hash (optional), epoch_id (optional),
    object_key, created_at, updated_at
  """
  def upsert_document(vault_category, attrs, vector \\ []) do
    table_name = table_for(vault_category)

    json =
      %{
        id:             attrs.doc_id,
        user_did:       attrs.user_did,
        namespace_key:  attrs.namespace_key,
        filename:       attrs.filename,
        content_type:   attrs[:content_type] || "application/octet-stream",
        file_size:      attrs[:file_size],
        status:         attrs[:status] || "synced",
        device_id:      attrs[:device_id] || "server",
        vault_category: vault_category,
        content_hash:   attrs[:content_hash],
        epoch_id:       attrs[:epoch_id],
        object_key:     attrs.object_key,
        created_at:     attrs[:created_at] || DateTime.utc_now() |> DateTime.to_iso8601(),
        updated_at:     attrs[:updated_at] || DateTime.utc_now() |> DateTime.to_iso8601(),
        vector:         if(length(vector) == 128, do: vector, else: List.duplicate(0.0, 128))
      }
      |> Jason.encode!()

    case Alem.LanceDB.upsert_vault_doc(table_name, json) do
      :ok ->
        Logger.debug("[VaultStore] upserted #{attrs.doc_id} → #{table_name}")
        :ok
      :error ->
        Logger.warning("[VaultStore] upsert failed for #{attrs.doc_id} → #{table_name}")
        :error
    end
  end

  @doc """
  Returns the LanceDB table name for a vault category string.
  Defaults to private_vault for unknown categories.
  """
  def table_for(category), do: Map.get(@vault_tables, category, "private_vault")
end
