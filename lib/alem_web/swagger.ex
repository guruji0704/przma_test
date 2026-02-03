defmodule AlemWeb.Swagger do
  @moduledoc """
  Swagger/OpenAPI schema definitions
  """
  alias OpenApiSpex.{Components, Info, OpenApi, Reference, Schema, Server}

  @behaviour OpenApi

  @impl OpenApi
  def spec do
    %OpenApi{
      info: %Info{
        title: "PRZMA API",
        version: "1.0.0",
        description: """
        ALEM (Alem) - Multi-tenant Document Management System API

        This API provides endpoints for managing namespaces, documents, and storage
        across multiple backends (S3, CouchDB, PostgreSQL).

        ## Features
        - Multi-tenant architecture with complete data isolation
        - Distributed namespace management via Horde
        - Multi-backend storage coordination
        - Full-text search capabilities
        - Content deduplication
        """
      },
      servers: [
        %Server{
          url: "http://localhost:4000",
          description: "Development server"
        }
      ],
      paths: %{
        "/api/test-namespace" => test_namespace_path()
      },
      components: %Components{
        schemas: %{
          "TestNamespaceResponse" => test_namespace_response_schema(),
          "TestResult" => test_result_schema(),
          "ErrorResponse" => error_response_schema()
        }
      }
    }
  end

  defp test_namespace_path do
    %OpenApiSpex.PathItem{
      get: %OpenApiSpex.Operation{
        summary: "Test Namespace System",
        description: """
        Runs a comprehensive integration test suite for the namespace system.

        This endpoint:
        - Creates a test namespace with random user_id and tenant_id
        - Tests namespace lifecycle (start, status, stop)
        - Tests document operations (ingest, list, get, search)
        - Tests storage integration (S3, CouchDB, PostgreSQL)
        - Returns detailed test results
        """,
        operationId: "test_namespace",
        tags: ["Namespace"],
        responses: %{
          200 => OpenApiSpex.Operation.response("Test Results", "application/json", %Reference{"$ref": "#/components/schemas/TestNamespaceResponse"}),
          500 => OpenApiSpex.Operation.response("Server Error", "application/json", %Reference{"$ref": "#/components/schemas/ErrorResponse"})
        }
      }
    }
  end

  defp test_namespace_response_schema do
    %Schema{
      type: :object,
      title: "Test Namespace Response",
      description: "Response from the namespace test endpoint",
      required: [:user_id, :tenant_id, :tests],
      properties: %{
        user_id: %Schema{
          type: :string,
          description: "Generated test user ID",
          example: "test_user_123"
        },
        tenant_id: %Schema{
          type: :string,
          description: "Generated test tenant ID",
          example: "test_tenant_45"
        },
        tests: %Schema{
          type: :array,
          description: "Array of test results",
          items: %Reference{"$ref": "#/components/schemas/TestResult"}
        }
      },
      example: %{
        user_id: "test_user_123",
        tenant_id: "test_tenant_45",
        tests: [
          %{
            test: "start_namespace",
            status: "passed",
            data: %{
              pid: "#PID<0.123.0>",
              tenant_id: "test_tenant_45"
            }
          },
          %{
            test: "ingest_document",
            status: "passed",
            data: %{
              doc_id: "doc_4kOD1zv2dmLHI05v5n9PJg",
              tenant_id: "test_tenant_45",
              message: "Document uploaded to S3, CouchDB, and PostgreSQL"
            }
          }
        ]
      }
    }
  end

  defp test_result_schema do
    %Schema{
      type: :object,
      title: "Test Result",
      description: "Individual test result",
      required: [:test, :status],
      properties: %{
        test: %Schema{
          type: :string,
          description: "Name of the test",
          example: "start_namespace"
        },
        status: %Schema{
          type: :string,
          description: "Test status",
          enum: ["passed", "failed", "skipped"],
          example: "passed"
        },
        data: %Schema{
          type: :object,
          description: "Additional test data (optional)",
          additionalProperties: true
        }
      },
      example: %{
        test: "ingest_document",
        status: "passed",
        data: %{
          doc_id: "doc_4kOD1zv2dmLHI05v5n9PJg",
          tenant_id: "test_tenant_45",
          message: "Document uploaded to S3, CouchDB, and PostgreSQL"
        }
      }
    }
  end

  defp error_response_schema do
    %Schema{
      type: :object,
      title: "Error Response",
      description: "Standard error response",
      required: [:error],
      properties: %{
        error: %Schema{
          type: :string,
          description: "Error message",
          example: "Internal server error"
        },
        details: %Schema{
          type: :object,
          description: "Additional error details",
          additionalProperties: true
        }
      },
      example: %{
        error: "Internal server error",
        details: %{}
      }
    }
  end
end
