# ── PRZMA Admin Panel Demo Data ─────────────────────────────────────────────
# Run with: iex.bat -S mix run priv/repo/seeds_admin_demo.exs
# Or paste into: iex.bat -S mix  then run: c "priv/repo/seeds_admin_demo.exs"

import Ecto.Query
alias Alem.Repo
alias Alem.Pleroma.User
alias Alem.Schemas.{Document, Namespace}
alias Alem.Cas.CasObject
require Logger

IO.puts("\n🌱 Seeding PRZMA admin demo data...\n")

# ── 1. Users ────────────────────────────────────────────────────────────────

users_data = [
  %{nickname: "alice_chen",     email: "alice@example.com",   is_admin: false, is_verified: true,  is_active: true},
  %{nickname: "bob_smith",      email: "bob@example.com",     is_admin: false, is_verified: true,  is_active: true},
  %{nickname: "carol_doe",      email: "carol@example.com",   is_admin: false, is_verified: false, is_active: true},
  %{nickname: "david_wu",       email: "david@example.com",   is_admin: false, is_verified: true,  is_active: false},
  %{nickname: "eva_martinez",   email: "eva@example.com",     is_admin: false, is_verified: true,  is_active: true},
  %{nickname: "frank_jones",    email: "frank@example.com",   is_admin: true,  is_verified: true,  is_active: true},
  %{nickname: "grace_kim",      email: "grace@example.com",   is_admin: false, is_verified: false, is_active: true},
  %{nickname: "henry_okafor",   email: "henry@example.com",   is_admin: false, is_verified: true,  is_active: true},
]

created_users = Enum.map(users_data, fn attrs ->
  case Repo.get_by(User, email: attrs.email) do
    nil ->
      id = :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false) |> binary_part(0, 16)
      did = "did:przma:#{:crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)}"
      namespace_key = String.slice(did |> String.split(":") |> List.last(), 0, 16)

      user = %User{
        id:           id,
        nickname:     attrs.nickname,
        name:         attrs.nickname |> String.replace("_", " ") |> String.split() |> Enum.map(&String.capitalize/1) |> Enum.join(" "),
        email:        attrs.email,
        password_hash: Pbkdf2.hash_pwd_salt("Password123!"),
        is_admin:     attrs.is_admin,
        is_verified:  attrs.is_verified,
        is_active:    attrs.is_active,
        is_moderator: false,
        otp_attempts: 0,
        reset_token_attempts: 0,
        did_id:       did,
        inserted_at:  NaiveDateTime.add(NaiveDateTime.utc_now(), -:rand.uniform(60) * 86400, :second) |> NaiveDateTime.truncate(:second),
        updated_at:   NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      }
      Repo.insert!(user, on_conflict: :nothing)
      IO.puts("  ✅ Created user: #{attrs.nickname} (#{id})")
      {user, namespace_key}

    existing ->
      ns_key = if existing.did_id, do: Alem.DID.namespace_key(existing.did_id), else: existing.id |> String.slice(0, 16)
      IO.puts("  ℹ️  Exists: #{attrs.nickname}")
      {existing, ns_key}
  end
end)

IO.puts("\n👥 #{length(created_users)} users ready\n")

# ── 2. Namespaces ────────────────────────────────────────────────────────────

Enum.each(created_users, fn {user, ns_key} ->
  unless Repo.get(Namespace, ns_key) do
    Repo.insert!(%Namespace{
      id:             ns_key,
      tenant_id:      ns_key,
      status:         "active",
      document_count: 0,
      storage_bytes:  0,
      did:            user.did_id,
      inserted_at:    DateTime.utc_now() |> DateTime.truncate(:second),
      updated_at:     DateTime.utc_now() |> DateTime.truncate(:second)
    }, on_conflict: :nothing)
  end
end)

# ── 3. CAS Objects (shared storage) ─────────────────────────────────────────

content_types = [
  {"application/pdf",   "pdf"},
  {"image/jpeg",        "jpg"},
  {"image/png",         "png"},
  {"application/vnd.openxmlformats-officedocument.wordprocessingml.document", "docx"},
  {"text/plain",        "txt"},
  {"video/mp4",         "mp4"},
  {"application/zip",   "zip"},
]

# Create 15 unique CAS objects
cas_objects = Enum.map(1..15, fn i ->
  hash = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
  {content_type, ext} = Enum.at(content_types, rem(i, length(content_types)))
  file_size = (:rand.uniform(50) + 1) * 1024 * 1024  # 1–50 MB
  # Some files are duplicated (ref_count > 1)
  ref_count = case rem(i, 4) do
    0 -> :rand.uniform(4) + 1
    _ -> 1
  end
  {ns_user, ns_key} = Enum.at(created_users, rem(i, length(created_users)))

  obj = %CasObject{
    content_hash:   hash,
    tenant_id:      ns_key,
    namespace_key:  ns_key,
    user_id:        ns_user.id,
    storage_backend: "s3",
    storage_key:    "cas/#{String.slice(hash, 0, 2)}/#{String.slice(hash, 2, 2)}/#{hash}",
    media_type:     content_type,
    file_size:      file_size,
    ref_count:      ref_count,
    is_corrupt:     false,
    is_verified:    true,
    is_current:     true,
    effective_from: DateTime.utc_now() |> DateTime.truncate(:second),
    inserted_at:    DateTime.utc_now() |> DateTime.truncate(:second),
    updated_at:     DateTime.utc_now() |> DateTime.truncate(:second)
  }
  Repo.insert!(obj, on_conflict: :nothing)
  IO.puts("  ✅ CAS object: #{String.slice(hash, 0, 16)}… (#{ext}, #{ref_count}×, #{div(file_size, 1_048_576)}MB)")
  {obj, ext}
end)

IO.puts("\n📦 #{length(cas_objects)} CAS objects ready\n")

# ── 4. Documents (per-user file records) ─────────────────────────────────────

file_names = [
  "Q1_Report_2026.pdf",
  "Profile_Photo.jpg",
  "Architecture_Diagram.png",
  "Technical_Spec.docx",
  "README.txt",
  "Demo_Video.mp4",
  "Source_Code.zip",
  "Meeting_Notes.docx",
  "Invoice_March.pdf",
  "Logo_Final.png",
  "Contract_Draft.docx",
  "Database_Backup.zip",
  "User_Guide.pdf",
  "Screenshot.png",
  "Config.txt",
]

doc_count = 0

# Give each user 3-6 documents
Enum.each(Enum.with_index(created_users), fn {{user, ns_key}, ui} ->
  num_docs = 3 + rem(ui, 4)
  Enum.each(1..num_docs, fn di ->
    {cas_obj, _ext} = Enum.at(cas_objects, rem(ui * 3 + di, length(cas_objects)))
    filename = Enum.at(file_names, rem(ui * 3 + di, length(file_names)))
    doc_id = Ecto.UUID.generate()

    Repo.insert!(%Document{
      id:           doc_id,
      tenant_id:    ns_key,
      user_id:      user.id,
      filename:     filename,
      content_type: cas_obj.media_type,
      object_key:   cas_obj.storage_key,
      content_hash: cas_obj.content_hash,
      status:       "ready",
      inserted_at:  DateTime.utc_now() |> DateTime.truncate(:second),
      updated_at:   DateTime.utc_now() |> DateTime.truncate(:second)
    }, on_conflict: :nothing)
  end)
  IO.puts("  ✅ #{user.nickname}: #{num_docs} documents")
end)

# ── 5. Summary ───────────────────────────────────────────────────────────────

total_users = Repo.aggregate(User, :count, :id)
total_docs  = Repo.aggregate(Document, :count, :id)
total_cas   = Repo.aggregate(CasObject, :count, :content_hash)
dup_cas     = Repo.aggregate(from(c in CasObject, where: c.ref_count > 1), :count, :content_hash)
total_bytes = Repo.one(from c in CasObject, select: coalesce(sum(c.file_size), 0)) || 0

IO.puts("""

╔══════════════════════════════════════╗
║      PRZMA Admin Demo Data Ready     ║
╠══════════════════════════════════════╣
║  Users:        #{String.pad_leading("#{total_users}", 4)}                    ║
║  Documents:    #{String.pad_leading("#{total_docs}", 4)}                    ║
║  CAS Objects:  #{String.pad_leading("#{total_cas}", 4)}                    ║
║  Duplicates:   #{String.pad_leading("#{dup_cas}", 4)}                    ║
║  Total bytes:  #{String.pad_leading("#{div(total_bytes, 1_048_576)} MB", 4)}                    ║
╚══════════════════════════════════════╝

Now open: http://localhost:4000/admin
""")
