# Storage Structure - Tenant ID Implementation

Complete overview of how data is organized across S3, CouchDB, and PostgreSQL with tenant partitioning.

---

## 1. Object Storage (S3/Linode)

### Bucket Structure

```
perkeep/
│
├── tenant/
│   │
│   ├── tenant_a/
│   │   │
│   │   ├── user_1/
│   │   │   ├── documents/
│   │   │   │   ├── doc_xyz123/
│   │   │   │   │   ├── filename.txt
│   │   │   │   │   ├── report.pdf
│   │   │   │   │   └── image.png
│   │   │   │   │
│   │   │   │   └── doc_abc456/
│   │   │   │       └── data.json
│   │   │   │
│   │   │   └── vectors/
│   │   │       ├── vec_001.bin
│   │   │       └── vec_002.bin
│   │   │
│   │   └── user_2/
│   │       ├── documents/
│   │       │   └── doc_def789/
│   │       │       └── contract.docx
│   │       │
│   │       └── vectors/
│   │           └── vec_003.bin
│   │
│   ├── tenant_b/
│   │   │
│   │   ├── user_1/
│   │   │   ├── documents/
│   │   │   │   └── doc_xyz999/
│   │   │   │       └── presentation.pptx
│   │   │   │
│   │   │   └── vectors/
│   │   │
│   │   └── user_3/
│   │       ├── documents/
│   │       │   └── doc_ghi012/
│   │       │       └── spreadsheet.xlsx
│   │       │
│   │       └── vectors/
│   │
│   └── tenant_c/
│       └── ...
│
└── [other buckets or old structure]
```

### S3 Object Key Format

**Pattern:** `tenant/{tenant_id}/{user_id}/documents/{doc_id}/{filename}`

**Examples:**

```
✅ tenant/tenant_a/user_1/documents/doc_4kOD1zv2dmLHI05v5n9PJg/test_document.txt
✅ tenant/tenant_a/user_1/documents/doc_xyz123/report.pdf
✅ tenant/tenant_b/user_3/documents/doc_ghi012/spreadsheet.xlsx
✅ tenant/tenant_c/user_2/documents/doc_mno345/contract.docx
```

### S3 Metadata Example

```json
{
  "metadata": {
    "tenant_id": "tenant_a",
    "user_id": "user_1",
    "doc_id": "doc_4kOD1zv2dmLHI05v5n9PJg",
    "filename": "test_document.txt",
    "content_type": "text/plain",
    "content_hash": "sha256_abc123...",
    "created_at": "2026-01-07T09:19:24Z"
  }
}
```

### Key Characteristics

✅ **Isolation:** Each tenant has separate folder tree  
✅ **Hierarchical:** Organized by tenant → user → document  
✅ **Scalable:** Easy to add new tenants/users  
✅ **Deduplication:** Files with same content_hash can share storage  
✅ **Access Control:** Prefix-based IAM policies possible

---

## 2. CouchDB (Document Database)

### Database Structure

```
CouchDB Server
│
├── alem_tenant_a_user_1
│   ├── Document 1: {
│   │     "_id": "doc_4kOD1zv2dmLHI05v5n9PJg",
│   │     "_rev": "3-abc123",
│   │     "tenant_id": "tenant_a",
│   │     "user_id": "user_1",
│   │     "filename": "test_document.txt",
│   │     "content_type": "text/plain",
│   │     "status": "completed",
│   │     "object_key": "tenant/tenant_a/user_1/documents/doc_4kOD1zv2dmLHI05v5n9PJg/test_document.txt",
│   │     "content_hash": "sha256_abc123...",
│   │     "metadata": {
│   │       "type": "test",
│   │       "tags": ["storage", "test", "integration"]
│   │     },
│   │     "created_at": "2026-01-07T09:19:24Z",
│   │     "updated_at": "2026-01-07T09:19:24Z",
│   │     "versions": [
│   │       {
│   │         "_id": "doc_4kOD1zv2dmLHI05v5n9PJg",
│   │         "timestamp": "2026-01-07T09:19:24Z",
│   │         "user": "user_1"
│   │       }
│   │     ]
│   │   }
│   │
│   ├── Document 2: { ... }
│   │
│   └── Document N: { ... }
│
├── alem_tenant_a_user_2
│   ├── Document 1: { ... }
│   ├── Document 2: { ... }
│   └── Document N: { ... }
│
├── alem_tenant_b_user_1
│   ├── Document 1: { ... }
│   ├── Document 2: { ... }
│   └── Document N: { ... }
│
├── alem_tenant_b_user_3
│   ├── Document 1: { ... }
│   └── Document N: { ... }
│
└── alem_tenant_c_user_X
    ├── Document 1: { ... }
    └── Document N: { ... }
```

### Database Naming Convention

**Pattern:** `alem_{tenant_id}_{user_id}`

**Examples:**

```
✅ alem_tenant_a_user_1        (tenant_a, user 1)
✅ alem_tenant_a_user_2        (tenant_a, user 2)
✅ alem_tenant_b_user_1        (tenant_b, user 1)
✅ alem_tenant_b_user_3        (tenant_b, user 3)
✅ alem_tenant_c_user_enterprise (tenant_c, enterprise user)
```

### Document Structure in CouchDB

```json
{
  "_id": "doc_4kOD1zv2dmLHI05v5n9PJg",
  "_rev": "3-abc123xyz",
  "tenant_id": "tenant_a",
  "user_id": "user_1",
  "filename": "test_document.txt",
  "content_type": "text/plain",
  "status": "completed",
  "object_key": "tenant/tenant_a/user_1/documents/doc_4kOD1zv2dmLHI05v5n9PJg/test_document.txt",
  "content_hash": "sha256_e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
  "metadata": {
    "type": "test",
    "tags": ["storage", "test", "integration"],
    "author": "system"
  },
  "created_at": "2026-01-07T09:19:24Z",
  "updated_at": "2026-01-07T09:19:24Z",
  "versions": [
    {
      "_id": "doc_4kOD1zv2dmLHI05v5n9PJg",
      "timestamp": "2026-01-07T09:19:24Z",
      "user": "user_1",
      "action": "created"
    }
  ]
}
```

### Key Characteristics

✅ **One DB per tenant/user pair:** Complete isolation  
✅ **Document versioning:** Built-in revision history (_rev)  
✅ **Metadata storage:** Full document metadata in CouchDB  
✅ **Replication ready:** Can replicate per-tenant databases  
✅ **Flexible schema:** Supports evolving document structures  

---

## 3. PostgreSQL (Relational Database)

### Table Schema

```
PostgreSQL Database: alem_dev (or alem_prod)
│
└── documents table
    │
    ├── Columns:
    │   ├── id (string, PK)
    │   ├── tenant_id (string, FK)          ← PARTITION KEY
    │   ├── user_id (string)
    │   ├── filename (string)
    │   ├── content_type (string)
    │   ├── object_key (string)
    │   ├── content_hash (string)
    │   ├── text_content (text, searchable)
    │   ├── metadata (jsonb)
    │   ├── status (string)
    │   ├── inserted_at (timestamp)
    │   └── updated_at (timestamp)
    │
    ├── Indexes:
    │   ├── PK: documents_pkey (id)
    │   ├── documents_tenant_id_index
    │   ├── documents_tenant_id_user_id_index  ← COMPOSITE
    │   ├── documents_content_hash_index
    │   ├── documents_filename_index
    │   ├── documents_status_index
    │   ├── documents_user_id_index
    │   └── documents_text_content_idx (GIN, full-text search)
    │
    └── Row Data:
        ├── Row 1: {
        │     id: "doc_4kOD1zv2dmLHI05v5n9PJg",
        │     tenant_id: "tenant_a",
        │     user_id: "user_1",
        │     filename: "test_document.txt",
        │     content_type: "text/plain",
        │     object_key: "tenant/tenant_a/user_1/documents/doc_4kOD1zv2dmLHI05v5n9PJg/test_document.txt",
        │     content_hash: "sha256_e3b0c44...",
        │     text_content: "This is a test document with real storage...",
        │     metadata: {"type": "test", "tags": ["storage"]},
        │     status: "completed",
        │     inserted_at: 2026-01-07 09:19:24,
        │     updated_at: 2026-01-07 09:19:24
        │   }
        │
        ├── Row 2: {
        │     id: "doc_xyz123",
        │     tenant_id: "tenant_a",
        │     user_id: "user_1",
        │     filename: "report.pdf",
        │     ...
        │   }
        │
        ├── Row 3: {
        │     id: "doc_abc456",
        │     tenant_id: "tenant_a",
        │     user_id: "user_2",
        │     filename: "contract.docx",
        │     ...
        │   }
        │
        ├── Row 4: {
        │     id: "doc_def789",
        │     tenant_id: "tenant_b",
        │     user_id: "user_1",
        │     filename: "presentation.pptx",
        │     ...
        │   }
        │
        └── Row N: { ... }
```

### PostgreSQL Query Examples

**List all documents for a tenant/user:**
```sql
SELECT * FROM documents 
WHERE tenant_id = 'tenant_a' 
  AND user_id = 'user_1'
LIMIT 100;
```
Uses composite index: `documents_tenant_id_user_id_index`

**Full-text search within tenant:**
```sql
SELECT * FROM documents 
WHERE text_content @@ plainto_tsquery('test storage')
  AND tenant_id = 'tenant_a'
  AND user_id = 'user_1'
ORDER BY ts_rank(to_tsvector(text_content), plainto_tsquery('test storage')) DESC;
```
Uses: `documents_text_content_idx` (GIN index)

**Find duplicate content across users in same tenant:**
```sql
SELECT content_hash, COUNT(*) as count, ARRAY_AGG(id) as docs
FROM documents
WHERE tenant_id = 'tenant_a'
  AND content_hash IS NOT NULL
GROUP BY content_hash
HAVING COUNT(*) > 1;
```
Uses: `documents_content_hash_index`

**Get all tenants stats:**
```sql
SELECT 
  tenant_id, 
  COUNT(*) as document_count,
  SUM(OCTET_LENGTH(text_content)) as total_text_bytes
FROM documents
GROUP BY tenant_id
ORDER BY document_count DESC;
```

### Key Characteristics

✅ **Single unified table:** All documents in one table  
✅ **Tenant as partition key:** Efficient queries by tenant  
✅ **Full-text search:** Native PostgreSQL GIN indexes  
✅ **JSONB metadata:** Flexible, queryable metadata  
✅ **Indexes optimized:** Composite (tenant, user) for performance  

---

## Data Flow Diagram

### Document Ingestion Flow

```
1. CREATE DOCUMENT
   ↓
2. SPLIT DATA:
   ├─ File content  → Object Storage (S3)
   ├─ Metadata      → Document Database (CouchDB)
   └─ Index record  → Relational DB (PostgreSQL)
   ↓
3. STORE WITH TENANT CONTEXT:

   S3:
   tenant/tenant_a/user_1/documents/doc_xyz/file.txt
                    ↑                       ↑
                 tenant_id             doc_id

   CouchDB:
   alem_tenant_a_user_1  ← Database name
   {
     "_id": "doc_xyz",
     "tenant_id": "tenant_a",
     ...
   }

   PostgreSQL:
   INSERT INTO documents (id, tenant_id, user_id, ...)
   VALUES ('doc_xyz', 'tenant_a', 'user_1', ...)
```

### Document Retrieval Flow

```
REQUEST: Get document for tenant_a/user_1/doc_xyz
   ↓
1. PostgreSQL: Query metadata
   SELECT * FROM documents 
   WHERE id='doc_xyz' AND tenant_id='tenant_a'
   ↓ (get object_key: tenant/tenant_a/user_1/documents/doc_xyz/file.txt)
   
2. S3: Download file from prefixed location
   GET /perkeep/tenant/tenant_a/user_1/documents/doc_xyz/file.txt
   
3. CouchDB: Get full document record (optional)
   GET /alem_tenant_a_user_1/doc_xyz
   
4. RETURN: Combined data to client
   {
     metadata: { ... from PostgreSQL ... },
     content: { ... from S3 ... },
     versions: [ ... from CouchDB ... ]
   }
```

### Search Flow

```
REQUEST: Search for "test storage" in tenant_a/user_1
   ↓
PostgreSQL full-text search:
   SELECT * FROM documents
   WHERE text_content @@ plainto_tsquery('test storage')
     AND tenant_id = 'tenant_a'
     AND user_id = 'user_1'
   ORDER BY relevance DESC
   ↓
RESULTS: [doc_xyz, doc_abc, ...]
   ↓
(Optional) Load full content from S3/CouchDB as needed
```

---

## Deduplication Example

### Scenario: Same content uploaded by two users in same tenant

**User A uploads:** "quarterly_report.pdf"
**User B uploads:** "quarterly_report.pdf" (identical content)

```
SHA256 hash of file = "abc123def456..."

S3 Storage:
├── tenant/tenant_a/user_1/documents/doc_001/quarterly_report.pdf
│   └── Object Key: perkeep/tenant/tenant_a/user_1/documents/doc_001/quarterly_report.pdf
│       Metadata: {content_hash: "abc123def456..."}
│
├── tenant/tenant_a/user_2/documents/doc_002/quarterly_report.pdf
│   └── Object Key: perkeep/tenant/tenant_a/user_2/documents/doc_002/quarterly_report.pdf
│       Metadata: {content_hash: "abc123def456..."}
│
└── [Actual file only stored ONCE in S3 dedup storage]

CouchDB:
├── alem_tenant_a_user_1:
│   {
│     "_id": "doc_001",
│     "tenant_id": "tenant_a",
│     "user_id": "user_1",
│     "content_hash": "abc123def456...",
│     "object_key": "tenant/tenant_a/user_1/documents/doc_001/quarterly_report.pdf"
│   }
│
└── alem_tenant_a_user_2:
    {
      "_id": "doc_002",
      "tenant_id": "tenant_a",
      "user_id": "user_2",
      "content_hash": "abc123def456...",
      "object_key": "tenant/tenant_a/user_2/documents/doc_002/quarterly_report.pdf"
    }

PostgreSQL:
┌─────────────────────────────────────────┐
│ documents                               │
├───────────────────────────────────────┬─┤
│ id      │ tenant_id│ user_id│ file... │ │
├─────────┼─────────┼────────┼────────┬─┤
│ doc_001 │tenant_a │ user_1 │ ...... │ │
│ doc_002 │tenant_a │ user_2 │ ...... │ │
└─────────┴────────┴────────┴────────┴─┘
      ↑                                    
      └─ Both point to same content_hash
         "abc123def456..." in index
         
[S3 Dedup Storage]
Actual content stored only ONCE:
└── /dedup/abc123def456.../quarterly_report.pdf
```

**Storage Savings:** 60-90% depending on duplicate content

---

## Migration & Partition Strategy

### Tenant Isolation Guarantees

```
Tenant A can NEVER access:
├── Tenant B's S3 objects
│   └── Different prefix: tenant/tenant_b/...
├── Tenant B's CouchDB database
│   └── Different database: alem_tenant_b_user_X
└── Tenant B's PostgreSQL rows
    └── WHERE clause filters: tenant_id != 'tenant_b'

Query Example - Authorization Check:
SELECT * FROM documents 
WHERE id = 'doc_xyz' 
  AND tenant_id = 'tenant_a'  ← REQUIRED
  AND user_id = 'user_1'       ← REQUIRED
LIMIT 1;

If doc_xyz belongs to tenant_b:
Result: 0 rows (not found, access denied)
```

### Scaling Considerations

```
Current state (1 database):
├── All tenants' documents in one PostgreSQL DB
├── One CouchDB server with per-tenant DBs
└── One S3 bucket with tenant prefixes

Future optimization:
├── PostgreSQL: Could partition table by tenant_id
├── CouchDB: Already isolated per tenant/user
└── S3: Could use separate buckets per tenant for compliance

Advantages of current approach:
✅ Simple to implement and manage
✅ Easy cross-tenant analytics (if needed)
✅ Flexible partitioning without code changes
✅ Cost-effective for most deployments
```

---

## Summary Table

| Aspect | S3/Object Storage | CouchDB | PostgreSQL |
|--------|-------------------|---------|-----------|
| **Organization** | Prefix-based folders | Per database | Single table |
| **Tenant isolation** | `tenant/{tenant_id}/` | `alem_{tenant_id}_user_id` | WHERE tenant_id = ... |
| **Partitioning** | By tenant/user/doc | By tenant/user pair | Composite index |
| **Purpose** | File/content storage | Metadata & versioning | Search & querying |
| **Scalability** | High (distributed) | Medium (per-tenant DBs) | High (indexed) |
| **Deduplication** | Via content_hash | Via content_hash | Query tracking |
| **Failure isolation** | Per-prefix | Per-database | Row-level |
| **Replication** | Per-prefix policies | Per-database replication | Standard DB replication |

