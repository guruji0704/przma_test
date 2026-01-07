# Tenant ID Usage Examples

This document provides practical examples of using the tenant-aware PRZMA architecture in ALEM.

## Basic Setup

### Starting a Tenant Namespace

```elixir
# Single tenant, single user
{:ok, pid} = Alem.Namespace.start("user_123", "tenant_A")

# Now the namespace is ready to accept documents
# All operations are automatically scoped to tenant_A
```

### Multiple Users in Same Tenant

```elixir
# Same tenant, different users
{:ok, pid_1} = Alem.Namespace.start("user_123", "tenant_A")
{:ok, pid_2} = Alem.Namespace.start("user_456", "tenant_A")
{:ok, pid_3} = Alem.Namespace.start("user_789", "tenant_A")

# Each user has isolated storage:
# Database: alem_tenant_A_user_123
# Database: alem_tenant_A_user_456
# Database: alem_tenant_A_user_789

# But they all use the same S3 prefix pattern for efficient organization
# S3: tenant/tenant_A/user_123/...
# S3: tenant/tenant_A/user_456/...
# S3: tenant/tenant_A/user_789/...
```

## Document Management

### Ingesting Documents

```elixir
# Single document
doc = %{
  filename: "Q1_Financial_Report.pdf",
  content: File.read!("report.pdf"),
  content_type: "application/pdf",
  metadata: %{
    quarter: "Q1",
    year: 2026,
    department: "Finance",
    tags: ["financial", "report", "compliance"]
  }
}

{:ok, doc_id} = Alem.Namespace.ingest_document(
  "user_123",
  "tenant_A",
  doc
)

# Document is now:
# 1. Stored in S3: s3://bucket/tenant/tenant_A/user_123/documents/doc_xyz/...
# 2. Indexed in CouchDB: alem_tenant_A_user_123 database
# 3. Searchable in PostgreSQL for full-text search
# All automatically tagged with tenant_A for isolation
```

### Batch Ingestion

```elixir
documents = [
  %{filename: "file1.txt", content: "..."},
  %{filename: "file2.txt", content: "..."},
  %{filename: "file3.txt", content: "..."}
]

results = Enum.map(documents, fn doc ->
  Alem.Namespace.ingest_document("user_123", "tenant_A", doc)
end)

# Each document is independently tenant-scoped
```

## Content Deduplication

### Deduplication Across Users in Same Tenant

```elixir
# User 1 uploads a PDF
file_content = File.read!("shared_policy.pdf")

{:ok, doc_id_1} = Alem.Namespace.ingest_document(
  "user_123",
  "tenant_A",
  %{filename: "policy.pdf", content: file_content}
)

# User 2 uploads the exact same PDF
{:ok, doc_id_2} = Alem.Namespace.ingest_document(
  "user_456",
  "tenant_A",
  %{filename: "policy.pdf", content: file_content}
)

# Both documents reference the same content_hash
# SHA-256(file_content) is calculated once and shared
# S3 storage: Only 1 copy, not 2
# CouchDB has 2 documents (one per user) with same content_hash

storage_saved = doc_size_mb  # 100% savings for this file pair
```

### Deduplication Across Tenants

```elixir
# Tenant A uploads: cat-video.mp4 (100MB)
# SHA-256: abc123...
{:ok, doc_a} = Alem.Namespace.ingest_document(
  "user_a",
  "tenant_A",
  %{filename: "cat-video.mp4", content: viral_content}
)

# Tenant B uploads SAME file: cat-video.mp4 (100MB)
# SHA-256: abc123... (SAME!)
{:ok, doc_b} = Alem.Namespace.ingest_document(
  "user_b",
  "tenant_B",
  %{filename: "cat-video.mp4", content: viral_content}
)

# Results:
# - Tenant A CouchDB: references hash abc123...
# - Tenant B CouchDB: references hash abc123...
# - S3 storage: Only 1 copy of the file (100MB)
# - Savings: 100MB (50% reduction)
# - Isolation: Maintained (different CouchDB databases)
```

## Querying & Search

### List Documents

```elixir
# Automatically scoped to tenant and user
{:ok, documents} = Alem.Namespace.list_documents(
  "user_123",
  limit: 50,
  offset: 0
)

# Returns only documents from:
# - Tenant: tenant_A (determined from user_123's namespace)
# - User: user_123
# - Prevents accidental cross-tenant access
```

### Get Specific Document

```elixir
# Safe retrieval with tenant verification
case Alem.Namespace.get_document(
  "user_123",
  "doc_xyz_id"
) do
  {:ok, document} ->
    # Document belongs to this user and tenant
    IO.inspect(document)
  
  {:error, :unauthorized} ->
    # Tenant mismatch - document belongs to different tenant
    IO.puts("Access denied")
  
  {:error, :not_found} ->
    # Document doesn't exist
    IO.puts("Not found")
end
```

### Full-Text Search

```elixir
# Search only within tenant's documents
{:ok, results} = Alem.Namespace.search(
  "user_123",
  "quarterly earnings",
  limit: 20
)

# Results include:
# - Full-text match ranking
# - Only documents from tenant_A
# - Only documents accessible to user_123
# - Sorted by relevance

results |> Enum.each(fn doc ->
  IO.puts("#{doc.filename}: #{doc.text_content |> String.slice(0..100)}")
end)
```

## Multi-Tenant Scenarios

### SaaS Application with Multiple Customers

```elixir
defmodule AlemWeb.DocumentController do
  def upload(conn, %{"file" => upload}) do
    # Get tenant from authenticated user
    tenant_id = conn.assigns.current_user.tenant_id  # "acme_corp"
    user_id = conn.assigns.current_user.id           # "user_123"
    
    # Document automatically isolated to tenant
    {:ok, doc_id} = Alem.Namespace.ingest_document(
      user_id,
      tenant_id,
      %{
        filename: upload.filename,
        content: File.read!(upload.path),
        content_type: upload.content_type,
        metadata: %{
          upload_ip: conn.remote_ip |> Tuple.to_list() |> Enum.join("."),
          user_agent: get_req_header(conn, "user-agent")
        }
      }
    )
    
    json(conn, %{
      success: true,
      doc_id: doc_id,
      tenant_id: tenant_id
    })
  end

  def list(conn, _params) do
    tenant_id = conn.assigns.current_user.tenant_id
    user_id = conn.assigns.current_user.id
    
    {:ok, documents} = Alem.Namespace.list_documents(user_id)
    
    json(conn, %{
      documents: documents,
      tenant_id: tenant_id,
      count: length(documents)
    })
  end

  def search(conn, %{"query" => query}) do
    tenant_id = conn.assigns.current_user.tenant_id
    user_id = conn.assigns.current_user.id
    
    {:ok, results} = Alem.Namespace.search(
      user_id,
      query,
      limit: 50
    )
    
    json(conn, %{
      query: query,
      results: results,
      count: length(results),
      tenant_id: tenant_id
    })
  end
end
```

## Database Isolation

### Per-Tenant Database

```elixir
# DataRouter creates isolated database per tenant/user combination
# CouchDB: alem_tenant_A_user_123
# CouchDB: alem_tenant_A_user_456
# CouchDB: alem_tenant_B_user_789

# Queries are automatically scoped:
query = from d in Document,
  where: d.tenant_id == "tenant_A" and d.user_id == "user_123"

results = Repo.all(query)
# Returns only tenant_A user_123 documents
```

### Indexes for Performance

```elixir
# Migration creates efficient indexes
create index(:documents, [:tenant_id])              # Tenant scan
create index(:documents, [:tenant_id, :user_id])   # Tenant + user lookup
create index(:documents, [:content_hash])          # Deduplication check

# Queries use indexes:
# WHERE tenant_id = 'A' AND user_id = 'u123'  → index (tenant_id, user_id)
# WHERE content_hash = 'abc123'                → index (content_hash)
```

## Storage Organization

### S3 Prefix Structure

```
s3://bucket/
├── tenant/
│   ├── tenant_A/
│   │   ├── user_123/
│   │   │   └── documents/
│   │   │       ├── doc_abc/report.pdf
│   │   │       ├── doc_def/image.png
│   │   │       └── doc_ghi/data.json
│   │   ├── user_456/
│   │   │   └── documents/
│   │   │       ├── doc_jkl/presentation.pptx
│   │   │       └── doc_mno/spreadsheet.xlsx
│   │   └── user_789/
│   │       └── documents/
│   │           └── doc_pqr/video.mp4
│   └── tenant_B/
│       ├── user_aaa/
│       │   └── documents/
│       │       └── doc_stu/contract.pdf
│       └── user_bbb/
│           └── documents/
│               └── doc_vwx/invoice.pdf

# Benefits:
# - Each tenant has own S3 prefix
# - Easy to apply lifecycle policies per tenant
# - Clean data organization
# - Quick bulk operations per tenant
```

## Security & Compliance

### Authorization Check

```elixir
defp authorize_document_access(user_id, tenant_id, doc_id) do
  # Step 1: Verify document exists
  case Alem.Namespace.get_document(user_id, doc_id) do
    {:ok, document} ->
      # Step 2: Verify tenant match
      if document.tenant_id == tenant_id do
        {:ok, document}
      else
        {:error, :unauthorized}  # Different tenant, deny access
      end
    
    error ->
      error
  end
end

# Usage in controller
case authorize_document_access(user_id, tenant_id, doc_id) do
  {:ok, document} -> send_document(document)
  {:error, :unauthorized} -> forbidden(conn)
  {:error, :not_found} -> not_found(conn)
end
```

### Audit Trail

```elixir
defmodule AlemWeb.AuditLog do
  def log_access(user_id, tenant_id, doc_id, action) do
    Repo.insert(%AuditLog{
      tenant_id: tenant_id,
      user_id: user_id,
      document_id: doc_id,
      action: action,  # "view", "download", "delete"
      timestamp: DateTime.utc_now(),
      ip_address: get_ip()
    })
  end

  # Compliance: Get audit trail for specific tenant
  def get_tenant_audit_trail(tenant_id, date_range) do
    from(al in AuditLog,
      where: al.tenant_id == ^tenant_id,
      where: al.timestamp >= ^date_range.start and al.timestamp <= ^date_range.end,
      order_by: [desc: :timestamp]
    )
    |> Repo.all()
  end
end
```

## Performance Example

### Scenario: 1000 Tenants, 1000 Users Each

```
Total users: 1,000,000
Total documents: 10,000,000 (10 per user average)
Average file size: 10MB

Without CAS:
- Total storage: 10,000,000 × 10MB = 100TB
- No deduplication savings

With CAS:
- Unique content: ~40% (due to shared templates, policies, etc.)
- Actual storage: 100TB × 40% = 40TB (60% savings!)
- CouchDB metadata: 100TB × 1% = 1TB (pointers to S3)
- PostgreSQL indexes: 100TB × 0.1% = 100GB (search indexes)

Tenant isolation:
- Average per tenant: 40TB / 1000 = 40GB
- Queries use (tenant_id, user_id) index → O(log n) lookup
- Full-text search: 45ms average per tenant
```

## Testing

```elixir
defmodule AlemTest do
  setup do
    {:ok, pid_a} = Alem.Namespace.start("user_a", "tenant_A")
    {:ok, pid_b} = Alem.Namespace.start("user_b", "tenant_B")
    
    {:ok, tenant_a: pid_a, tenant_b: pid_b}
  end

  test "documents are isolated by tenant", %{tenant_a: _, tenant_b: _} do
    # Tenant A uploads document
    {:ok, doc_id} = Alem.Namespace.ingest_document(
      "user_a",
      "tenant_A",
      %{filename: "secret.pdf", content: "..."}
    )
    
    # Tenant B cannot access it
    assert {:error, :unauthorized} ==
      Alem.Namespace.get_document("user_b", doc_id)
  end

  test "deduplication across tenants", %{} do
    content = "shared content"
    
    # Both tenants upload same content
    {:ok, id_a} = ingest("user_a", "tenant_A", content)
    {:ok, id_b} = ingest("user_b", "tenant_B", content)
    
    # Different document IDs
    assert id_a != id_b
    
    # Same content hash
    doc_a = Document.get(id_a)
    doc_b = Document.get(id_b)
    assert doc_a.content_hash == doc_b.content_hash
  end
end
```

---

This comprehensive approach ensures:
- ✅ Complete tenant isolation
- ✅ Cross-tenant deduplication
- ✅ Security and compliance
- ✅ Performance optimization
- ✅ Scalable multi-tenant SaaS
