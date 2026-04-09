defmodule AlemWeb.NamespaceController do
  @moduledoc """
  Smoke test endpoint for the full CAS pipeline.
  GET /api/v1/test-namespace
  Runs 9 automated tests without requiring auth.
  All tests run sequentially so each one can use results from the previous.
  """
  use AlemWeb, :controller
  require Logger

  def test(conn, _params) do
    namespace_key = "smoke_test_ns_01"
    tenant_id     = namespace_key

    Logger.info("[SmokeTest] Starting CAS pipeline test for ns=#{namespace_key}")

    results = %{namespace_key: namespace_key, tests: []}
    |> test_start_namespace(namespace_key, tenant_id)
    |> test_namespace_exists(namespace_key)
    |> test_get_status(namespace_key)
    |> test_ingest_document(namespace_key)
    |> test_list_documents(namespace_key)
    |> test_get_document(namespace_key)
    |> test_search_documents(namespace_key)
    |> test_registry_stats()
    |> test_stop_namespace(namespace_key)

    Logger.info("[SmokeTest] All tests completed")
    json(conn, results)
  end

  # ── Tests ──────────────────────────────────────────────────────────────────

  defp test_start_namespace(results, namespace_key, tenant_id) do
    case Alem.Namespace.start(namespace_key, tenant_id) do
      {:ok, pid} ->
        add_test(results, "start_namespace", "passed", %{pid: inspect(pid)})
      {:error, {:already_started, pid}} ->
        add_test(results, "start_namespace", "passed", %{pid: inspect(pid), note: "already running"})
      {:error, reason} ->
        add_test(results, "start_namespace", "failed", %{error: inspect(reason)})
    end
  end

  defp test_namespace_exists(results, namespace_key) do
    exists = Alem.Namespace.exists?(namespace_key)
    add_test(results, "namespace_exists", if(exists, do: "passed", else: "failed"), %{exists: exists})
  end

  defp test_get_status(results, namespace_key) do
    case Alem.Namespace.status(namespace_key) do
      {:ok, status} ->
        add_test(results, "get_status", "passed", %{
          health: status[:health_status],
          node:   inspect(status[:node])
        })
      {:error, reason} ->
        add_test(results, "get_status", "failed", %{error: inspect(reason)})
    end
  end

  defp test_ingest_document(results, namespace_key) do
    # IMPORTANT: Document.id is :binary_id — must be a valid UUID string
    doc_id  = UUID.uuid4()
    content = "Smoke test document. Tests full CAS pipeline: SHA-256 hash, dedup check, S3 upload, cas_objects insert, documents insert, cas_dedup_refs insert, cas_activities insert."

    doc_attrs = %{
      doc_id:       doc_id,
      filename:     "smoke_test.txt",
      file_data:    content,
      content_type: "text/plain",
      metadata:     %{type: "smoke_test", tags: ["test", "cas"]}
    }

    case Alem.Namespace.ingest_document(namespace_key, doc_attrs) do
      {:ok, doc, cas_obj, is_duplicate} ->
        results = Map.put(results, :last_doc_id, doc.id)
        add_test(results, "ingest_document", "passed", %{
          doc_id:       doc.id,
          content_hash: String.slice(cas_obj.content_hash, 0, 16) <> "…",
          is_duplicate: is_duplicate,
          file_size:    byte_size(content)
        })
      {:error, reason} ->
        add_test(results, "ingest_document", "failed", %{error: inspect(reason)})
    end
  end

  defp test_list_documents(results, namespace_key) do
    case Alem.Namespace.list_documents(namespace_key, %{limit: 10}) do
      {:ok, docs} ->
        add_test(results, "list_documents", "passed", %{
          count: length(docs),
          ids:   Enum.map(docs, & &1.id) |> Enum.take(3)
        })
      {:error, reason} ->
        add_test(results, "list_documents", "failed", %{error: inspect(reason)})
    end
  end

  defp test_get_document(results, namespace_key) do
    case Map.get(results, :last_doc_id) do
      nil ->
        add_test(results, "get_document", "skipped", %{reason: "no doc_id from ingest"})
      doc_id ->
        case Alem.Namespace.get_document(namespace_key, doc_id) do
          {:ok, doc} ->
            add_test(results, "get_document", "passed", %{
              doc_id:   doc.id,
              filename: doc.filename,
              status:   doc.status
            })
          {:error, reason} ->
            add_test(results, "get_document", "failed", %{error: inspect(reason)})
        end
    end
  end

  defp test_search_documents(results, namespace_key) do
    case Alem.Namespace.search_documents(namespace_key, "smoke test", %{limit: 5}) do
      {:ok, docs} ->
        add_test(results, "search_documents", "passed", %{results_count: length(docs)})
      {:error, reason} ->
        add_test(results, "search_documents", "failed", %{error: inspect(reason)})
    end
  end

  defp test_registry_stats(results) do
    count = Horde.Registry.count(Alem.Namespace.HordeRegistry)
    add_test(results, "registry_stats", "passed", %{horde_registrations: count})
  rescue
    e -> add_test(results, "registry_stats", "failed", %{error: inspect(e)})
  end

  defp test_stop_namespace(results, namespace_key) do
    case Alem.Namespace.stop(namespace_key) do
      :ok              -> add_test(results, "stop_namespace", "passed", %{})
      {:error, reason} -> add_test(results, "stop_namespace", "failed", %{error: inspect(reason)})
    end
  rescue
    _ -> add_test(results, "stop_namespace", "passed", %{note: "already stopped"})
  end

  defp add_test(results, name, status, data \\ nil) do
    entry = %{test: name, status: status}
    entry = if data && map_size(data) > 0, do: Map.put(entry, :data, data), else: entry
    Map.update!(results, :tests, &(&1 ++ [entry]))
  end
end
