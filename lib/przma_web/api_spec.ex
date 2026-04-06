defmodule PrzmaWeb.ApiSpec do
  @moduledoc """
  OpenAPI 3.0 specification for the PRZMA API.
  Served at /api/openapi and rendered as Swagger UI at /api/swaggerui.
  """
  alias OpenApiSpex.{Components, Info, OpenApi, Paths, Schema, SecurityScheme, Server}

  @behaviour OpenApiSpex.OpenApi

  @impl OpenApiSpex.OpenApi
  def spec do
    %OpenApi{
      info: %Info{
        title:       "PRZMA Perception Intelligence API",
        version:     "0.4.0",
        description: """
        PRZMA — Sovereign perception intelligence platform.

        ## Authentication
        Most endpoints require a **DID JWT Bearer token**.

        ### How to get a token (dev):
        1. `POST /auth/did/register` with `{"did": "did:przma:user:alice"}`
        2. `POST /auth/did/verify` with `{"did": "did:przma:user:alice", "signature": "stub"}`
        3. Copy the `token` field from the response
        4. Click **Authorize** above and enter: `Bearer <token>`

        ## XRPC Protocol
        All `/xrpc/*` endpoints are validated against JSON lexicon schemas.
        - **Queries** use `GET` — params go in query string
        - **Procedures** use `POST` — params go in JSON body

        ## LiGHT Signals
        The platform uses 5 perception signals: `L` (Stop), `i` (Caution),
        `G` (Turn), `H` (Go), `T` (Ascend).
        """
      },
      servers: [
        %Server{url: "http://localhost:4000", description: "Local development"}
      ],
      components: %Components{
        securitySchemes: %{
          "BearerAuth" => %SecurityScheme{
            type:         "http",
            scheme:       "bearer",
            bearerFormat: "JWT",
            description:  "DID JWT. Obtain via POST /auth/did/verify"
          }
        },
        schemas: schemas()
      },
      paths: build_paths(),
      security: [%{"BearerAuth" => []}]
    }
  end

  # ── SCHEMAS ───────────────────────────────────────────────────────────────

  defp schemas do
    %{
      "DID" => %Schema{
        type:        :string,
        description: "Decentralized Identifier",
        example:     "did:przma:user:alice",
        pattern:     "^did:przma:"
      },
      "CID" => %Schema{
        type:        :string,
        description: "BLAKE3 Content Identifier",
        example:     "blake3:abc123def456"
      },
      "LightSignal" => %Schema{
        type:        :string,
        enum:        ["L", "i", "G", "H", "T"],
        description: "LiGHT perception signal: L=Stop, i=Caution, G=Turn, H=Go, T=Ascend"
      },
      "Error" => %Schema{
        type: :object,
        properties: %{
          error:  %Schema{type: :string},
          detail: %Schema{type: :string}
        }
      },
      "TokenResponse" => %Schema{
        type: :object,
        properties: %{
          token:      %Schema{type: :string, description: "JWT Bearer token"},
          did:        %Schema{type: :string},
          token_type: %Schema{type: :string, example: "Bearer"},
          expires_in: %Schema{type: :integer, example: 86_400}
        }
      },
      "DMMessage" => %Schema{
        type: :object,
        properties: %{
          message_id:      %Schema{type: :string},
          cas_cid:         %Schema{type: :string},
          thread_id:       %Schema{type: :string},
          sender_did:      %Schema{type: :string},
          content:         %Schema{type: :string},
          light_signal:    %Schema{type: :string},
          delivery_status: %Schema{type: :string, enum: ["sent", "delivered", "read"]},
          created_at:      %Schema{type: :string, format: "date-time"}
        }
      }
    }
  end

  # ── PATHS ─────────────────────────────────────────────────────────────────

  defp build_paths do
    %{
      # ── AUTH ──────────────────────────────────────────────────────────────
      "/auth/did/register" => %OpenApiSpex.PathItem{
        post: %OpenApiSpex.Operation{
          tags:        ["Auth"],
          summary:     "Register a DID",
          operationId: "auth.did.register",
          security:    [],
          requestBody: json_body(%Schema{
            type:     :object,
            required: ["did"],
            properties: %{
              "did" => %Schema{type: :string, example: "did:przma:user:alice"}
            }
          }),
          responses: %{
            200 => json_response("Registration result", %Schema{type: :object})
          }
        }
      },

      "/auth/did/verify" => %OpenApiSpex.PathItem{
        post: %OpenApiSpex.Operation{
          tags:        ["Auth"],
          summary:     "Verify DID challenge and get JWT token",
          description: "**DEV STUB**: Any valid `did:przma:` DID is accepted without a real signature.",
          operationId: "auth.did.verify",
          security:    [],
          requestBody: json_body(%Schema{
            type:     :object,
            required: ["did"],
            properties: %{
              "did"       => %Schema{type: :string, example: "did:przma:user:alice"},
              "signature" => %Schema{type: :string, example: "stub"}
            }
          }),
          responses: %{
            200 => json_response("JWT token", %Schema{
              type: :object,
              properties: %{
                "token"      => %Schema{type: :string},
                "did"        => %Schema{type: :string},
                "token_type" => %Schema{type: :string},
                "expires_in" => %Schema{type: :integer}
              }
            })
          }
        }
      },

      # ── HEALTH ────────────────────────────────────────────────────────────
      "/health" => %OpenApiSpex.PathItem{
        get: %OpenApiSpex.Operation{
          tags:        ["System"],
          summary:     "Health check",
          operationId: "health.check",
          security:    [],
          responses: %{
            200 => json_response("Health status", %Schema{
              type: :object,
              properties: %{
                "status"  => %Schema{type: :string, example: "ok"},
                "version" => %Schema{type: :string},
                "time"    => %Schema{type: :string, format: "date-time"}
              }
            })
          }
        }
      },

      # ── INBOX ─────────────────────────────────────────────────────────────
      "/xrpc/app.przma.inbox.list" => %OpenApiSpex.PathItem{
        get: %OpenApiSpex.Operation{
          tags:        ["Inbox"],
          summary:     "List inbox activities",
          operationId: "inbox.list",
          parameters: [
            query_param("did", :string, true,  "User DID"),
            query_param("limit", :integer, false, "Max results (1–100, default 20)"),
            query_param("cursor", :string, false, "Pagination cursor"),
            query_param("unread_only", :boolean, false, "Filter to unread only"),
            query_param("activity_type", :string, false, "Filter by AP activity type")
          ],
          responses: %{
            200 => json_response("Inbox activities", %Schema{
              type: :object,
              properties: %{
                "activities"   => %Schema{type: :array, items: %Schema{type: :object}},
                "cursor"       => %Schema{type: :string, nullable: true},
                "unread_count" => %Schema{type: :integer}
              }
            }),
            401 => json_response("Unauthorized", %Schema{type: :object})
          }
        }
      },

      "/xrpc/app.przma.inbox.markRead" => %OpenApiSpex.PathItem{
        post: %OpenApiSpex.Operation{
          tags:        ["Inbox"],
          summary:     "Mark activities as read",
          operationId: "inbox.markRead",
          requestBody: json_body(%Schema{
            type:     :object,
            required: ["did", "activity_ids"],
            properties: %{
              "did"          => %Schema{type: :string},
              "activity_ids" => %Schema{type: :array, items: %Schema{type: :string}}
            }
          }),
          responses: %{200 => json_response("Marked count", %Schema{type: :object})}
        }
      },

      # ── DM CHAT ───────────────────────────────────────────────────────────
      "/xrpc/app.przma.chat.dm.send" => %OpenApiSpex.PathItem{
        post: %OpenApiSpex.Operation{
          tags:        ["DM Chat"],
          summary:     "Send a direct message",
          operationId: "chat.dm.send",
          requestBody: json_body(%Schema{
            type:     :object,
            required: ["sender_did", "recipient_did", "content"],
            properties: %{
              "sender_did"    => %Schema{type: :string, example: "did:przma:user:alice"},
              "recipient_did" => %Schema{type: :string, example: "did:przma:user:bob"},
              "content"       => %Schema{type: :string, maxLength: 5000},
              "light_signal"  => %Schema{type: :string, enum: ["L","i","G","H","T"]},
              "reply_to_id"   => %Schema{type: :string, nullable: true}
            }
          }),
          responses: %{
            200 => json_response("Message sent", %Schema{
              type: :object,
              properties: %{
                "message_id"      => %Schema{type: :string},
                "cas_cid"         => %Schema{type: :string},
                "thread_id"       => %Schema{type: :string},
                "delivery_status" => %Schema{type: :string}
              }
            })
          }
        }
      },

      "/xrpc/app.przma.chat.dm.list" => %OpenApiSpex.PathItem{
        get: %OpenApiSpex.Operation{
          tags:        ["DM Chat"],
          summary:     "List messages in a DM thread",
          operationId: "chat.dm.list",
          parameters: [
            query_param("did", :string, true,  "User DID"),
            query_param("thread_id", :string, true,  "Thread ID"),
            query_param("limit", :integer, false, "Max messages (default 30)"),
            query_param("cursor", :string, false, "Pagination cursor")
          ],
          responses: %{
            200 => json_response("Messages", %Schema{type: :object})
          }
        }
      },

      "/xrpc/app.przma.chat.dm.threads" => %OpenApiSpex.PathItem{
        get: %OpenApiSpex.Operation{
          tags:        ["DM Chat"],
          summary:     "List all DM threads",
          operationId: "chat.dm.threads",
          parameters: [
            query_param("did", :string, true, "User DID"),
            query_param("limit", :integer, false, "Max threads"),
            query_param("unread_only", :boolean, false, "Only unread threads")
          ],
          responses: %{200 => json_response("Threads", %Schema{type: :object})}
        }
      },

      # ── VAULT ─────────────────────────────────────────────────────────────
      "/xrpc/app.przma.vault.put" => %OpenApiSpex.PathItem{
        post: %OpenApiSpex.Operation{
          tags:        ["Vault"],
          summary:     "Store content in vault",
          description: "Encrypts content with AES-256-GCM and stores with a BLAKE3 CID.",
          operationId: "vault.put",
          requestBody: json_body(%Schema{
            type:     :object,
            required: ["did", "path", "content"],
            properties: %{
              "did"     => %Schema{type: :string},
              "path"    => %Schema{type: :string, example: "journal/entry-1"},
              "content" => %Schema{type: :string},
              "tier"    => %Schema{type: :string, enum: ["personal","private","social"],
                                   default: "personal"}
            }
          }),
          responses: %{
            200 => json_response("CID", %Schema{
              type: :object,
              properties: %{
                "cid"  => %Schema{type: :string},
                "path" => %Schema{type: :string},
                "tier" => %Schema{type: :string}
              }
            })
          }
        }
      },

      "/xrpc/app.przma.vault.get" => %OpenApiSpex.PathItem{
        get: %OpenApiSpex.Operation{
          tags:        ["Vault"],
          summary:     "Retrieve content from vault by path",
          operationId: "vault.get",
          parameters: [
            query_param("did",  :string, true, "Owner DID"),
            query_param("path", :string, true, "Vault path")
          ],
          responses: %{200 => json_response("Content", %Schema{type: :object})}
        }
      },

      "/xrpc/app.przma.vault.list" => %OpenApiSpex.PathItem{
        get: %OpenApiSpex.Operation{
          tags:        ["Vault"],
          summary:     "List vault contents",
          operationId: "vault.list",
          parameters: [
            query_param("did",    :string,  true,  "Owner DID"),
            query_param("prefix", :string,  false, "Path prefix filter"),
            query_param("limit",  :integer, false, "Max results")
          ],
          responses: %{200 => json_response("Items", %Schema{type: :object})}
        }
      },

      # ── OUTBOX ────────────────────────────────────────────────────────────
      "/xrpc/app.przma.outbox.list" => %OpenApiSpex.PathItem{
        get: %OpenApiSpex.Operation{
          tags:        ["Outbox"],
          summary:     "List outbox (sent activities)",
          operationId: "outbox.list",
          parameters: [
            query_param("did",    :string,  true,  "User DID"),
            query_param("limit",  :integer, false, "Max results"),
            query_param("cursor", :string,  false, "Pagination cursor")
          ],
          responses: %{200 => json_response("Activities", %Schema{type: :object})}
        }
      },

      # ── SCAN / SIGNAL ──────────────────────────────────────────────────────
      "/xrpc/app.przma.scan.create" => %OpenApiSpex.PathItem{
        post: %OpenApiSpex.Operation{
          tags:        ["Perception"],
          summary:     "Create a filter scan entry",
          operationId: "scan.create",
          requestBody: json_body(%Schema{
            type:     :object,
            required: ["did", "filters"],
            properties: %{
              "did"          => %Schema{type: :string},
              "filters"      => %Schema{type: :array, items: %Schema{type: :object}},
              "light_signal" => %Schema{type: :string, enum: ["L","i","G","H","T"]},
              "note"         => %Schema{type: :string}
            }
          }),
          responses: %{200 => json_response("Scan result", %Schema{type: :object})}
        }
      },

      "/xrpc/app.przma.signal.emit" => %OpenApiSpex.PathItem{
        post: %OpenApiSpex.Operation{
          tags:        ["Perception"],
          summary:     "Emit a LiGHT signal",
          operationId: "signal.emit",
          requestBody: json_body(%Schema{
            type:     :object,
            required: ["did", "signal"],
            properties: %{
              "did"    => %Schema{type: :string},
              "signal" => %Schema{type: :string, enum: ["L","i","G","H","T"]}
            }
          }),
          responses: %{200 => json_response("Signal recorded", %Schema{type: :object})}
        }
      }
    }
  end

  # ── HELPERS ───────────────────────────────────────────────────────────────

  defp json_body(schema) do
    %OpenApiSpex.RequestBody{
      required: true,
      content: %{
        "application/json" => %OpenApiSpex.MediaType{schema: schema}
      }
    }
  end

  defp json_response(description, schema) do
    %OpenApiSpex.Response{
      description: description,
      content: %{
        "application/json" => %OpenApiSpex.MediaType{schema: schema}
      }
    }
  end

  defp query_param(name, type, required, description) do
    %OpenApiSpex.Parameter{
      name:        name,
      in:          :query,
      required:    required,
      description: description,
      schema:      %Schema{type: type}
    }
  end
end
