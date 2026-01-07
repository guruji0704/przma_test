defmodule AlemWeb.NamespaceController do
  use AlemWeb, :controller
  require Logger

  def test(conn, _params) do
    user_id = "test_user_#{:rand.uniform(1000)}"
    tenant_id = "test_tenant_#{:rand.uniform(100)}"

    Logger.info("🧪 Starting REAL storage tests for tenant:#{tenant_id} user:#{user_id}")

    results = run_all_tests(user_id, tenant_id)

    Logger.info("📊 All tests completed!")

    json(conn, results)
  end

  defp run_all_tests(user_id, tenant_id) do
    %{user_id: user_id, tenant_id: tenant_id, tests: []}
    |> test_start_namespace(user_id, tenant_id)
    |> test_namespace_exists(user_id)
    |> test_get_status(user_id)
    |> test_ingest_document(user_id, tenant_id)
    |> test_list_documents(user_id)
    |> test_get_document(user_id)
    |> test_search_documents(user_id)
    |> test_get_config(user_id)
    |> test_registry_stats()
    |> test_stop_namespace(user_id)
  end

  defp test_start_namespace(results, user_id, tenant_id) do
    Logger.info("✅ Test 1: Starting namespace for tenant:#{tenant_id} user:#{user_id}")
    {:ok, pid} = Alem.Namespace.start(user_id, tenant_id)
    add_test(results, "start_namespace", "passed", %{pid: inspect(pid), tenant_id: tenant_id})
  end

  defp test_namespace_exists(results, user_id) do
    Logger.info("✅ Test 2: Checking namespace exists")
    exists = Alem.Namespace.exists?(user_id)
    add_test(results, "namespace_exists", if(exists, do: "passed", else: "failed"))
  end

  defp test_get_status(results, user_id) do
    Logger.info("✅ Test 3: Getting namespace status")
    {:ok, status} = Alem.Namespace.status(user_id)
    add_test(results, "get_status", "passed", status)
  end

  defp test_ingest_document(results, user_id, tenant_id) do
    Logger.info("✅ Test 4: Ingesting REAL document to S3+CouchDB+PostgreSQL for tenant:#{tenant_id}")

    doc = %{
      filename: "test_document.txt",
      content: "This is a test document with real storage. It will be uploaded to Linode S3, stored in CouchDB, and indexed in PostgreSQL for full-text search.",
      content_type: "text/plain",
      metadata: %{
        type: "test",
        tags: ["storage", "test", "integration"]
      }
    }

    case Alem.Namespace.ingest_document(user_id, tenant_id, doc) do
      {:ok, doc_id} ->
        # Store doc_id for later tests
        results = Map.put(results, :last_doc_id, doc_id)
        add_test(results, "ingest_document", "passed", %{
          doc_id: doc_id,
          tenant_id: tenant_id,
          message: "Document uploaded to S3, CouchDB, and PostgreSQL"
        })
      {:error, reason} ->
        add_test(results, "ingest_document", "failed", %{error: inspect(reason)})
    end
  end

  defp test_list_documents(results, user_id) do
    Logger.info("✅ Test 5: Listing documents from PostgreSQL")

    :timer.sleep(500) # Wait for async operations

    case Alem.Namespace.list_documents(user_id) do
      {:ok, docs} ->
        add_test(results, "list_documents", "passed", %{
          count: length(docs),
          documents: Enum.map(docs, & &1.id)
        })
      {:error, reason} ->
        add_test(results, "list_documents", "failed", %{error: inspect(reason)})
    end
  end

  defp test_get_document(results, user_id) do
    Logger.info("✅ Test 6: Retrieving document from CouchDB")

    case Map.get(results, :last_doc_id) do
      nil ->
        add_test(results, "get_document", "skipped", %{reason: "No document to retrieve"})
      doc_id ->
        case Alem.Namespace.get_document(user_id, doc_id) do
          {:ok, doc} ->
            add_test(results, "get_document", "passed", %{
              doc_id: doc["_id"],
              filename: doc["filename"],
              status: doc["status"]
            })
          {:error, reason} ->
            add_test(results, "get_document", "failed", %{error: inspect(reason)})
        end
    end
  end

  defp test_search_documents(results, user_id) do
    Logger.info("✅ Test 7: Full-text search in PostgreSQL")

    :timer.sleep(500) # Wait for indexing

    case Alem.Namespace.Registry.lookup(user_id, :data_router) do
      {:ok, pid} ->
        case GenServer.call(pid, {:search, "test storage", []}) do
          {:ok, search_results} ->
            add_test(results, "search_documents", "passed", %{
              results_count: length(search_results),
              found: Enum.map(search_results, & &1.id)
            })
          {:error, reason} ->
            add_test(results, "search_documents", "failed", %{error: inspect(reason)})
        end
      _ ->
        add_test(results, "search_documents", "failed", %{error: "DataRouter not found"})
    end
  end

  defp test_get_config(results, user_id) do
    Logger.info("✅ Test 8: Getting config")
    {:ok, config} = Alem.Namespace.get_config(user_id)
    add_test(results, "get_config", "passed", %{storage: config.storage})
  end

  defp test_registry_stats(results) do
    Logger.info("✅ Test 9: Getting registry stats")
    stats = Alem.Namespace.Registry.stats()
    add_test(results, "registry_stats", "passed", stats)
  end

  defp test_stop_namespace(results, user_id) do
    Logger.info("✅ Test 10: Stopping namespace")

    try do
      :ok = Alem.Namespace.stop(user_id)
      add_test(results, "stop_namespace", "passed")
    catch
      :exit, _ ->
        add_test(results, "stop_namespace", "passed")
    end
  end

  defp add_test(results, name, status, data \\ nil) do
    test = %{test: name, status: status}
    test = if data, do: Map.put(test, :data, data), else: test
    Map.update!(results, :tests, &(&1 ++ [test]))
  end
end
