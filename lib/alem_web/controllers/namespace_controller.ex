defmodule AlemWeb.NamespaceController do
  @moduledoc """
  GET /api/v1/test-namespace — integration smoke test.
  Exercises the full Namespace + CAS pipeline end-to-end.
  """

  use AlemWeb, :controller
  require Logger

  def test(conn, _params) do
    # Use a fixed test namespace_key so we can reuse it across requests
    namespace_key = "test_ns_smoke_001"
    tenant_id     = namespace_key

    Logger.info("[NSController] Starting smoke test for #{namespace_key}")

    results =
      %{namespace_key: namespace_key, tests: []}
      |> test_start(namespace_key, tenant_id)
      |> test_exists(namespace_key)
      |> test_status(namespace_key)
      |> test_ingest(namespace_key)
      |> test_list(namespace_key)
      |> test_get(namespace_key)
      |> test_search(namespace_key)
      |> test_registry()
      |> test_stop(namespace_key)

    json(conn, results)
  end

  # ── Test steps ─────────────────────────────────────────────────────────────

  defp test_start(r, ns_key, tenant_id) do
    case Alem.Namespace.start(ns_key, tenant_id) do
      {:ok, pid}                        -> add(r, "start_namespace", "passed", %{pid: inspect(pid)})
      {:error, {:already_started, pid}} -> add(r, "start_namespace", "passed", %{pid: inspect(pid), note: "already running"})
      {:error, reason}                  -> add(r, "start_namespace", "failed", %{error: inspect(reason)})
    end
  end

  defp test_exists(r, ns_key) do
    exists = Alem.Namespace.exists?(ns_key)
    add(r, "namespace_exists", if(exists, do: "passed", else: "failed"))
  end

  defp test_status(r, ns_key) do
    case Alem.Namespace.status(ns_key) do
      {:ok, status} -> add(r, "get_status", "passed", Map.take(status, [:health_status, :tenant_id]))
      {:error, e}   -> add(r, "get_status", "failed", %{error: inspect(e)})
    end
  end

  defp test_ingest(r, ns_key) do
    doc_id   = "smoke_doc_#{:rand.uniform(9999)}"
    content  = "PRZMA smoke test document. Uploaded via CAS. SHA-256 dedup active."

    attrs = %{
      doc_id:       doc_id,
      filename:     "smoke_test.txt",
      file_data:    content,
      content_type: "text/plain",
      metadata:     %{test: true, source: "namespace_controller"}
    }

    case Alem.Namespace.ingest_document(ns_key, attrs) do
      {:ok, doc, cas_obj} ->
        r
        |> Map.put(:last_doc_id, doc.id)
        |> Map.put(:last_hash, cas_obj.content_hash)
        |> add("ingest_document", "passed", %{
            doc_id:       doc.id,
            content_hash: String.slice(cas_obj.content_hash, 0, 16) <> "…",
            file_size:    byte_size(content),
            storage:      "S3 + PostgreSQL + CAS"
          })

      {:error, reason} ->
        add(r, "ingest_document", "failed", %{error: inspect(reason)})
    end
  end

  defp test_list(r, ns_key) do
    case Alem.Namespace.list_documents(ns_key, %{limit: 5}) do
      {:ok, docs} -> add(r, "list_documents", "passed", %{count: length(docs)})
      {:error, e} -> add(r, "list_documents", "failed", %{error: inspect(e)})
    end
  end

  defp test_get(r, ns_key) do
    case Map.get(r, :last_doc_id) do
      nil ->
        add(r, "get_document", "skipped", %{reason: "no doc from ingest"})

      doc_id ->
        case Alem.Namespace.get_document(ns_key, doc_id) do
          {:ok, doc} ->
            add(r, "get_document", "passed", %{
              id:          doc.id,
              filename:    doc.filename,
              status:      doc.status,
              content_hash: doc.content_hash && String.slice(doc.content_hash, 0, 16) <> "…"
            })

          {:error, e} ->
            add(r, "get_document", "failed", %{error: inspect(e)})
        end
    end
  end

  defp test_search(r, ns_key) do
    case Alem.Namespace.search_documents(ns_key, "PRZMA smoke test") do
      {:ok, results} -> add(r, "search_documents", "passed", %{matches: length(results)})
      {:error, e}    -> add(r, "search_documents", "failed", %{error: inspect(e)})
    end
  end

  defp test_registry(r) do
    stats = Alem.Namespace.Registry.stats()
    add(r, "registry_stats", "passed", stats)
  end

  defp test_stop(r, ns_key) do
    case Alem.Namespace.stop(ns_key) do
      :ok           -> add(r, "stop_namespace", "passed")
      {:error, :not_found} -> add(r, "stop_namespace", "passed", %{note: "was not running"})
      {:error, e}   -> add(r, "stop_namespace", "failed", %{error: inspect(e)})
    end
  end

  # ── Helper ─────────────────────────────────────────────────────────────────

  defp add(results, name, status, data \\ nil) do
    entry = %{test: name, status: status}
    entry = if data, do: Map.put(entry, :data, data), else: entry
    Map.update!(results, :tests, &(&1 ++ [entry]))
  end
end
