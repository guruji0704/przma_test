defmodule AlemWeb.Swagger do
  @moduledoc "OpenAPI/Swagger specification for PRZMA/ALEM API"

  alias OpenApiSpex.{Components, Info, OpenApi, Reference, Schema, Server}

  @behaviour OpenApi

  @impl OpenApi
  def spec do
    %OpenApi{
      info: %Info{
        title: "PRZMA / ALEM API",
        version: "1.0.0",
        description: """
        ALEM — Multi-tenant Document Management & Perception Intelligence Platform

        ## Authentication Flow
        1. `GET /api/v1/pleroma/captcha` — get captcha challenge
        2. `POST /api/v1/apps` — register OAuth app, get client_id/client_secret
        3. `POST /api/v1/account/register` — register user (DID auto-generated)
        4. `POST /api/v1/oauth/token` — login, get Bearer token (a session is also created)
        5. `GET /api/v1/accounts/verify_credentials` — verify token
        6. `GET /api/v1/accounts/did` — get your Decentralized Identifier

        ## Chat Flow
        1. Login via `POST /api/v1/oauth/token` → get `access_token`
        2. `POST /api/v1/chat/socket/token` → get chat token
        3. `GET /api/v1/chat/rooms` → list rooms
        4. `POST /api/v1/chat/rooms/:id/join` → join as member or audience
        5. `POST /api/v1/chat/rooms/:id/messages` → send messages
        6. `GET /api/v1/chat/rooms/:id/messages` → get history

        ## Session Management
        Each login automatically creates a session record (device, IP, browser).
        - `GET /api/v1/sessions` — list all active sessions
        - `DELETE /api/v1/sessions/:id` — logout from one specific device
        - `DELETE /api/v1/sessions/all` — logout from every device immediately

        ## DID (Decentralized Identifier)
        Every user gets exactly **one** DID at registration. Format: `did:przma:<sha256-fingerprint>`
        The DID is the root identity used to create and isolate namespaces.
        """
      },
      servers: [
        %Server{url: "http://localhost:4000", description: "Development"}
      ],
      paths: %{

        # ══════════════════════════════════════════════════════
        # AUTH
        # ══════════════════════════════════════════════════════

        "/api/v1/pleroma/captcha" => %OpenApiSpex.PathItem{
          get: op("Get Captcha", "Authentication", "get_captcha",
            "Get a captcha challenge (token + answer). Use token+solution when registering.",
            %{200 => resp("Captcha", "CaptchaResponse"),
              500 => resp("Error",   "ErrorResponse")})
        },

        "/api/v1/apps" => %OpenApiSpex.PathItem{
          post: op_body("Register OAuth App", "Authentication", "register_app",
            "Register a new OAuth application. Returns client_id and client_secret.",
            "RegisterAppRequest",
            %{200 => resp("App registered",  "RegisterAppResponse"),
              422 => resp("Validation error", "ErrorResponse")})
        },

        "/api/v1/account/register" => %OpenApiSpex.PathItem{
          post: op_body("Register Account", "Authentication", "register_account",
            "Create a new user account. A DID (did:przma:...) is automatically generated and stored.",
            "RegisterAccountRequest",
            %{200 => resp("Account created", "AccountResponse"),
              400 => resp("Bad request",      "ErrorResponse")})
        },

        "/api/v1/oauth/token" => %OpenApiSpex.PathItem{
          post: op_body("Login / Get Token", "Authentication", "get_oauth_token",
            """
            Login with nickname + password.

            On success:
            - Returns `access_token` (Bearer) and `did`
            - Automatically creates a **session record** tracking your IP and device

            After login, use the `access_token` in the Authorization header:
            `Authorization: Bearer <access_token>`
            """,
            "OAuthTokenRequest",
            %{200 => resp("Token + DID",    "OAuthTokenResponse"),
              401 => resp("Unauthorized",    "ErrorResponse"),
              400 => resp("Bad grant type",  "ErrorResponse")})
        },

        "/api/v1/accounts/verify_credentials" => %OpenApiSpex.PathItem{
          get: op_auth("Verify Credentials", "Authentication", "verify_credentials",
            "Verify your Bearer token. Returns account info including DID.",
            %{200 => resp("Account info", "AccountResponse"),
              401 => resp("Unauthorized",  "ErrorResponse")})
        },

        "/api/v1/accounts/did" => %OpenApiSpex.PathItem{
          get: op_auth("Get My DID", "DID", "get_did",
            """
            Get the authenticated user's Decentralized Identifier (DID).

            Format: `did:przma:<sha256-base64url-fingerprint>`

            The DID is:
            - Generated once at registration — never changes
            - Globally unique (cryptographic hash of user_id + random nonce + timestamp)
            - The root identity for namespace creation
            """,
            %{200 => resp("DID info",    "DIDResponse"),
              401 => resp("Unauthorized", "ErrorResponse")})
        },

        # ══════════════════════════════════════════════════════
        # SESSIONS
        # ══════════════════════════════════════════════════════

        "/api/v1/sessions" => %OpenApiSpex.PathItem{
          get: op_auth("List Active Sessions", "Sessions", "list_sessions",
            """
            Get all active login sessions for your account.

            Each session shows:
            - `id` — use this to revoke a specific session
            - `device` — desktop / mobile / tablet / api_client / unknown
            - `ip_address` — IP address that was used to log in
            - `user_agent` — browser or app identifier
            - `last_active_at` — most recent activity time
            - `created_at` — when you logged in from this device
            """,
            %{200 => resp("Sessions list", "SessionsResponse"),
              401 => resp("Unauthorized",   "ErrorResponse")}),

          delete: op_auth("Logout From All Devices", "Sessions", "revoke_all_sessions",
            """
            Immediately revoke ALL active sessions and tokens across every device.

            Use this if you suspect your account has been compromised.
            You will need to log in again on all devices after this.
            """,
            %{200 => resp("All sessions revoked", "MessageResponse"),
              401 => resp("Unauthorized",           "ErrorResponse")})
        },

        "/api/v1/sessions/{id}" => %OpenApiSpex.PathItem{
          delete: op_auth_param("Revoke Session by ID", "Sessions", "revoke_session",
            """
            Logout from one specific device by session ID.

            Get the `id` from `GET /api/v1/sessions`.
            Only the session belonging to the authenticated user can be revoked.
            All other sessions remain active.
            """,
            [session_id_param()],
            %{200 => resp("Session revoked", "MessageResponse"),
              404 => resp("Not found",        "ErrorResponse"),
              401 => resp("Unauthorized",     "ErrorResponse")})
        },

        "/oauth/token/revoke" => %OpenApiSpex.PathItem{
          delete: op_auth("Logout (Revoke Token)", "Authentication", "revoke_token",
            "Revoke the current Bearer token. The token will return 401 after this.",
            %{200 => resp("Revoked",   "MessageResponse"),
              404 => resp("Not found", "ErrorResponse")})
        },

        "/api/v1/pleroma/delete_account" => %OpenApiSpex.PathItem{
          post: op_auth_body("Delete Account", "Authentication", "delete_account",
            "Delete account (requires password). Revokes all tokens and sessions.",
            "PasswordConfirmRequest",
            %{200 => resp("Deleted",       "StatusResponse"),
              401 => resp("Unauthorized",   "ErrorResponse"),
              403 => resp("Wrong password", "ErrorResponse")})
        },

        "/api/v1/pleroma/disable_account" => %OpenApiSpex.PathItem{
          post: op_auth_body("Disable Account", "Authentication", "disable_account",
            "Disable account (requires password). Revokes all tokens and sessions.",
            "PasswordConfirmRequest",
            %{200 => resp("Disabled",      "StatusResponse"),
              401 => resp("Unauthorized",   "ErrorResponse"),
              403 => resp("Wrong password", "ErrorResponse")})
        },

        # ══════════════════════════════════════════════════════
        # NAMESPACE
        # ══════════════════════════════════════════════════════

        "/api/v1/namespaces" => %OpenApiSpex.PathItem{
          post: op_auth("Create/Get Namespace", "Namespace", "create_or_get_namespace",
            "Create or retrieve the namespace for the authenticated user (keyed by DID).",
            %{200 => resp("Namespace", "NamespaceResponse"),
              401 => resp("Unauthorized", "ErrorResponse")}),
          get: op_auth("Get Namespace", "Namespace", "get_namespace",
            "Get namespace status for the authenticated user.",
            %{200 => resp("Namespace", "NamespaceResponse"),
              404 => resp("Not found",  "ErrorResponse"),
              401 => resp("Unauthorized", "ErrorResponse")})
        },

        "/api/v1/namespaces/account" => %OpenApiSpex.PathItem{
          get: op_auth("Get Account in Namespace", "Namespace", "get_namespace_account",
            "Get account info stored in the authenticated user's namespace.",
            %{200 => resp("Account",     "AccountResponse"),
              401 => resp("Unauthorized", "ErrorResponse")})
        },

        # ══════════════════════════════════════════════════════
        # CHAT
        # ══════════════════════════════════════════════════════

        "/api/v1/chat/socket/token" => %OpenApiSpex.PathItem{
          post: op_body("Get Chat Token", "Chat", "chat_get_token",
            """
            Get a token to connect to WebSocket.

            ## Flow:
            1. Login via POST /api/v1/oauth/token → get access_token
            2. Call this endpoint with your username
            3. Use returned token to connect WebSocket
            """,
            "ChatTokenRequest",
            %{200 => resp("Token issued", "ChatTokenResponse"),
              422 => resp("Error",         "ErrorResponse")})
        },

        "/api/v1/chat/rooms" => %OpenApiSpex.PathItem{
          get: op_auth("List Chat Rooms", "Chat", "chat_list_rooms",
            "List all rooms with live member counts. is_full = true means audience mode.",
            %{200 => resp("Rooms list", "ChatRoomsResponse")}),
          post: op_body("Create Chat Room", "Chat", "chat_create_room",
            "Dynamically create a new chat room.",
            "ChatCreateRoomRequest",
            %{200 => resp("Room created", "ChatRoomResponse"),
              422 => resp("Error",         "ErrorResponse")})
        },

        "/api/v1/chat/rooms/{id}" => %OpenApiSpex.PathItem{
          get: op_auth_param("Get Room Details", "Chat", "chat_get_room",
            "Get room metadata, online members, and capacity info.",
            [room_id_param()],
            %{200 => resp("Room details", "ChatRoomResponse")})
        },

        "/api/v1/chat/rooms/{id}/status" => %OpenApiSpex.PathItem{
          get: op_auth_param("Room Status", "Chat", "chat_room_status",
            """
            Check room capacity before joining.

            - `mode: member`   → room has space, you can send messages
            - `mode: audience` → room is full, you can only read
            """,
            [room_id_param()],
            %{200 => resp("Room status", "ChatRoomStatusResponse")})
        },

        "/api/v1/chat/rooms/{id}/members" => %OpenApiSpex.PathItem{
          get: op_auth_param("Online Members", "Chat", "chat_room_members",
            "Get list of currently online members in the room.",
            [room_id_param()],
            %{200 => resp("Members list", "ChatMembersResponse")})
        },

        "/api/v1/chat/rooms/{id}/join" => %OpenApiSpex.PathItem{
          post: op_body_param("Join Room", "Chat", "chat_join_room",
            """
            Join a chat room.

            - Room has space → `mode: member` → can send messages
            - Room is full   → `mode: audience` → read only, input hidden
            """,
            [room_id_param()],
            "ChatJoinRequest",
            %{200 => resp("Joined", "ChatJoinResponse"),
              422 => resp("Error",  "ErrorResponse")})
        },

        "/api/v1/chat/rooms/{id}/leave" => %OpenApiSpex.PathItem{
          delete: op_body_param("Leave Room", "Chat", "chat_leave_room",
            "Leave a room. Removes you from the online members list.",
            [room_id_param()],
            "ChatLeaveRequest",
            %{200 => resp("Left room", "ChatLeaveResponse"),
              422 => resp("Error",     "ErrorResponse")})
        },

        "/api/v1/chat/rooms/{id}/messages" => %OpenApiSpex.PathItem{
          get: op_auth_param("Message History", "Chat", "chat_get_messages",
            """
            Get paginated message history for a room.

            Use `?page=1&per_page=20` for pagination.
            Private (@tagged) messages are NOT stored here.
            """,
            [room_id_param(), page_param(), per_page_param()],
            %{200 => resp("Message history", "ChatMessagesResponse")}),
          post: op_body_param("Send Message", "Chat", "chat_send_message",
            """
            Send a message to a room.

            - Max 280 characters
            - Use `@username` in body to send a private message
            - Private messages are NOT stored in history
            """,
            [room_id_param()],
            "ChatSendMessageRequest",
            %{200 => resp("Message sent", "ChatMessageResponse"),
              422 => resp("Error",         "ErrorResponse")})
        },

        "/api/v1/chat/messages/private" => %OpenApiSpex.PathItem{
          post: op_body("Send Private DM", "Chat", "chat_send_private",
            "Send a direct private message to a specific user. Only sender and receiver see it.",
            "ChatPrivateDMRequest",
            %{200 => resp("DM delivered", "ChatDMResponse"),
              422 => resp("Error",         "ErrorResponse")})
        },

        "/api/v1/chat/rooms/{id}/typing" => %OpenApiSpex.PathItem{
          post: op_body_param("Typing Indicator", "Chat", "chat_typing",
            "Broadcast typing indicator. Others in room will see 'karthiga is typing...'",
            [room_id_param()],
            "ChatTypingRequest",
            %{200 => resp("Broadcast sent", "ChatTypingResponse")})
        }

      },

      # ════════════════════════════════════════════════════════
      # COMPONENTS
      # ════════════════════════════════════════════════════════

      components: %Components{
        schemas: %{

          # ── Auth Request Schemas ───────────────────────────
          "RegisterAppRequest"     => register_app_request_schema(),
          "OAuthTokenRequest"      => oauth_token_request_schema(),
          "RegisterAccountRequest" => register_account_request_schema(),
          "PasswordConfirmRequest" => password_confirm_schema(),

          # ── Auth Response Schemas ──────────────────────────
          "RegisterAppResponse"    => register_app_response_schema(),
          "OAuthTokenResponse"     => oauth_token_response_schema(),
          "AccountResponse"        => account_response_schema(),
          "CaptchaResponse"        => captcha_response_schema(),
          "DIDResponse"            => did_response_schema(),
          "SessionsResponse"       => sessions_response_schema(),
          "SessionObject"          => session_object_schema(),
          "NamespaceResponse"      => namespace_response_schema(),
          "ErrorResponse"          => error_response_schema(),
          "MessageResponse"        => message_response_schema(),
          "StatusResponse"         => status_response_schema(),

          # ── Chat Request Schemas ───────────────────────────
          "ChatTokenRequest" => %Schema{
            type: :object, title: "ChatTokenRequest",
            required: [:username],
            properties: %{
              username: %Schema{type: :string, example: "karthiga"}
            }
          },

          "ChatCreateRoomRequest" => %Schema{
            type: :object, title: "ChatCreateRoomRequest",
            required: [:name],
            properties: %{
              name:  %Schema{type: :string, example: "general"},
              emoji: %Schema{type: :string, example: "💬"}
            }
          },

          "ChatJoinRequest" => %Schema{
            type: :object, title: "ChatJoinRequest",
            properties: %{
              username: %Schema{type: :string, example: "karthiga",
                                description: "Use if no session"}
            }
          },

          "ChatLeaveRequest" => %Schema{
            type: :object, title: "ChatLeaveRequest",
            properties: %{
              username: %Schema{type: :string, example: "karthiga"}
            }
          },

          "ChatSendMessageRequest" => %Schema{
            type: :object, title: "ChatSendMessageRequest",
            required: [:body],
            properties: %{
              body: %Schema{
                type: :string,
                example: "hello @ravi",
                description: "Max 280 chars. Use @username in body to send private DM."
              },
              username: %Schema{type: :string, example: "karthiga",
                                description: "Use if no session"}
            }
          },

          "ChatPrivateDMRequest" => %Schema{
            type: :object, title: "ChatPrivateDMRequest",
            required: [:to, :body],
            properties: %{
              to:       %Schema{type: :string, example: "ravi",
                                description: "Target username"},
              body:     %Schema{type: :string, example: "hey only you see this"},
              username: %Schema{type: :string, example: "karthiga",
                                description: "Sender — use if no session"}
            }
          },

          "ChatTypingRequest" => %Schema{
            type: :object, title: "ChatTypingRequest",
            properties: %{
              username: %Schema{type: :string, example: "karthiga"}
            }
          },

          # ── Chat Response Schemas ──────────────────────────
          "ChatTokenResponse" => %Schema{
            type: :object, title: "ChatTokenResponse",
            properties: %{
              token:      %Schema{type: :string, example: "a2FydGhpZ2E6MTcxMjM="},
              username:   %Schema{type: :string, example: "karthiga"},
              expires_in: %Schema{type: :integer, example: 3600}
            }
          },

          "ChatRoomsResponse" => %Schema{
            type: :object, title: "ChatRoomsResponse",
            properties: %{
              rooms: %Schema{
                type: :array,
                items: %Schema{
                  type: :object,
                  properties: %{
                    id:           %Schema{type: :string,  example: "lobby"},
                    name:         %Schema{type: :string,  example: "Lobby"},
                    emoji:        %Schema{type: :string,  example: "🏠"},
                    member_count: %Schema{type: :integer, example: 3},
                    max:          %Schema{type: :integer, example: 5},
                    is_full:      %Schema{type: :boolean, example: false}
                  }
                }
              }
            }
          },

          "ChatRoomResponse" => %Schema{
            type: :object, title: "ChatRoomResponse",
            properties: %{
              id:      %Schema{type: :string,  example: "lobby"},
              members: %Schema{type: :array, items: %Schema{type: :string}},
              count:   %Schema{type: :integer, example: 2},
              max:     %Schema{type: :integer, example: 5},
              is_full: %Schema{type: :boolean, example: false}
            }
          },

          "ChatRoomStatusResponse" => %Schema{
            type: :object, title: "ChatRoomStatusResponse",
            properties: %{
              room:    %Schema{type: :string,  example: "lobby"},
              count:   %Schema{type: :integer, example: 3},
              max:     %Schema{type: :integer, example: 5},
              is_full: %Schema{type: :boolean, example: false},
              mode:    %Schema{type: :string,  example: "member",
                               description: "member = can send | audience = read only"}
            }
          },

          "ChatMembersResponse" => %Schema{
            type: :object, title: "ChatMembersResponse",
            properties: %{
              room:    %Schema{type: :string},
              members: %Schema{type: :array, items: %Schema{type: :string},
                               example: ["karthiga", "ravi"]},
              count:   %Schema{type: :integer, example: 2}
            }
          },

          "ChatJoinResponse" => %Schema{
            type: :object, title: "ChatJoinResponse",
            properties: %{
              ok:          %Schema{type: :boolean, example: true},
              mode:        %Schema{type: :string,  example: "member",
                                   description: "member | audience"},
              is_audience: %Schema{type: :boolean, example: false},
              room:        %Schema{type: :string,  example: "lobby"},
              message:     %Schema{type: :string,  example: "karthiga joined as member"}
            }
          },

          "ChatLeaveResponse" => %Schema{
            type: :object, title: "ChatLeaveResponse",
            properties: %{
              ok:       %Schema{type: :boolean, example: true},
              username: %Schema{type: :string,  example: "karthiga"},
              room:     %Schema{type: :string,  example: "lobby"}
            }
          },

          "ChatMessagesResponse" => %Schema{
            type: :object, title: "ChatMessagesResponse",
            properties: %{
              room:     %Schema{type: :string,  example: "lobby"},
              page:     %Schema{type: :integer, example: 1},
              per_page: %Schema{type: :integer, example: 20},
              total:    %Schema{type: :integer, example: 45},
              messages: %Schema{
                type: :array,
                items: %Schema{
                  type: :object,
                  properties: %{
                    user:   %Schema{type: :string,          example: "karthiga"},
                    body:   %Schema{type: :string,          example: "hello everyone"},
                    tagged: %Schema{type: :string,          example: nil,
                                    nullable: true,
                                    description: "null = public, username = private"}
                  }
                }
              }
            }
          },

          "ChatMessageResponse" => %Schema{
            type: :object, title: "ChatMessageResponse",
            properties: %{
              ok: %Schema{type: :boolean, example: true},
              message: %Schema{
                type: :object,
                properties: %{
                  user:   %Schema{type: :string, example: "karthiga"},
                  body:   %Schema{type: :string, example: "hello everyone"},
                  tagged: %Schema{type: :string, nullable: true}
                }
              }
            }
          },

          "ChatDMResponse" => %Schema{
            type: :object, title: "ChatDMResponse",
            properties: %{
              ok:           %Schema{type: :boolean, example: true},
              delivered_to: %Schema{type: :string,  example: "ravi"}
            }
          },

          "ChatTypingResponse" => %Schema{
            type: :object, title: "ChatTypingResponse",
            properties: %{
              ok: %Schema{type: :boolean, example: true}
            }
          }

        },

        securitySchemes: %{
          "BearerAuth" => %OpenApiSpex.SecurityScheme{
            type: "http",
            scheme: "bearer",
            description: "OAuth Bearer token. Obtain from POST /api/v1/oauth/token"
          }
        }
      }
    }
  end

  # ════════════════════════════════════════════════════════════
  # SCHEMA DEFINITIONS
  # ════════════════════════════════════════════════════════════

  defp register_app_request_schema do
    %Schema{
      type: :object, title: "RegisterAppRequest",
      required: [:client_name],
      properties: %{
        client_name:   %Schema{type: :string, example: "My PRZMA App"},
        redirect_uris: %Schema{type: :string, example: "urn:ietf:wg:oauth:2.0:oob"},
        scopes:        %Schema{type: :string, example: "read write", default: "read write"},
        website:       %Schema{type: :string, example: "https://example.com"}
      }
    }
  end

  defp register_app_response_schema do
    %Schema{
      type: :object, title: "RegisterAppResponse",
      properties: %{
        id:            %Schema{type: :string, example: "K7mF2xQ9rP..."},
        name:          %Schema{type: :string, example: "My PRZMA App"},
        client_id:     %Schema{type: :string, example: "K7mF2xQ9rP..."},
        client_secret: %Schema{type: :string, example: "abc123..."},
        redirect_uri:  %Schema{type: :string, example: "urn:ietf:wg:oauth:2.0:oob"},
        vapid_key:     %Schema{type: :string, nullable: true}
      }
    }
  end

  defp oauth_token_request_schema do
    %Schema{
      type: :object, title: "OAuthTokenRequest",
      required: [:grant_type],
      properties: %{
        grant_type:    %Schema{type: :string, enum: ["password", "client_credentials"],
                               example: "password"},
        username:      %Schema{type: :string, description: "Your nickname", example: "johndoe"},
        password:      %Schema{type: :string, format: :password, example: "securepassword123"},
        client_id:     %Schema{type: :string, example: "K7mF2xQ9rP..."},
        client_secret: %Schema{type: :string, example: "abc123..."},
        scope:         %Schema{type: :string, example: "read write"}
      }
    }
  end

  defp oauth_token_response_schema do
    %Schema{
      type: :object, title: "OAuthTokenResponse",
      description: "Login response. Includes access_token, DID, and creates a session record.",
      properties: %{
        access_token:  %Schema{type: :string, example: "a-GvXrUzM9Fv..."},
        token_type:    %Schema{type: :string, example: "Bearer"},
        scope:         %Schema{type: :string, example: "read write"},
        expires_in:    %Schema{type: :integer, example: 2592000},
        refresh_token: %Schema{type: :string, example: "refresh_abc123..."},
        me:            %Schema{type: :string, description: "Your nickname", example: "johndoe"},
        did: %Schema{
          type: :string,
          description: "Your Decentralized Identifier",
          example: "did:przma:K7mF2xQ9rPvN3wLtZoYeA8hCbDsJuGiMnRkXpWqTcVlH"
        },
        created_at: %Schema{type: :integer, example: 1740614645}
      }
    }
  end

  defp register_account_request_schema do
    %Schema{
      type: :object, title: "RegisterAccountRequest",
      required: [:nickname, :email, :password],
      properties: %{
        nickname:         %Schema{type: :string, example: "johndoe"},
        email:            %Schema{type: :string, format: :email, example: "john@example.com"},
        password:         %Schema{type: :string, format: :password, example: "securepassword123"},
        fullname:         %Schema{type: :string, example: "John Doe"},
        bio:              %Schema{type: :string, example: "Software developer"},
        captcha_token:    %Schema{type: :string,
                                  description: "Token from GET /api/v1/pleroma/captcha"},
        captcha_solution: %Schema{type: :string,
                                  description: "Answer from the captcha challenge"}
      }
    }
  end

  defp account_response_schema do
    %Schema{
      type: :object, title: "AccountResponse",
      properties: %{
        id:           %Schema{type: :string, example: "mK92pqRtYuIoplKj"},
        username:     %Schema{type: :string, example: "johndoe"},
        acct:         %Schema{type: :string, example: "johndoe"},
        display_name: %Schema{type: :string, example: "John Doe"},
        note:         %Schema{type: :string, example: "Software developer"},
        avatar:       %Schema{type: :string, example: ""},
        created_at:   %Schema{type: :string, example: "2026-02-27T00:00:00Z"},
        did: %Schema{type: :string,
                     example: "did:przma:K7mF2xQ9rPvN3wLtZoYeA8hCbDsJuGiMnRkXpWqTcVlH"},
        pleroma: %Schema{
          type: :object,
          properties: %{
            is_admin:     %Schema{type: :boolean},
            is_moderator: %Schema{type: :boolean},
            is_active:    %Schema{type: :boolean}
          }
        }
      }
    }
  end

  defp captcha_response_schema do
    %Schema{
      type: :object, title: "CaptchaResponse",
      properties: %{
        type:          %Schema{type: :string, example: "image"},
        token:         %Schema{type: :string, example: "oU-MJtbyHv..."},
        answer_data:   %Schema{type: :string, example: "A8F3K2"},
        seconds_valid: %Schema{type: :integer, example: 300}
      }
    }
  end

  defp did_response_schema do
    %Schema{
      type: :object, title: "DIDResponse",
      properties: %{
        user_id:       %Schema{type: :string, example: "mK92pqRtYuIoplKj"},
        nickname:      %Schema{type: :string, example: "johndoe"},
        did:           %Schema{type: :string,
                               example: "did:przma:K7mF2xQ9rPvN3wLtZoYeA8hCbDsJuGiMnRkXpWqTcVlH"},
        did_method:    %Schema{type: :string, example: "przma"},
        fingerprint:   %Schema{type: :string,
                               example: "K7mF2xQ9rPvN3wLtZoYeA8hCbDsJuGiMnRkXpWqTcVlH"},
        namespace_key: %Schema{type: :string, example: "k7mf2xq9rpvn3wlt"},
        description:   %Schema{type: :string}
      }
    }
  end

  defp sessions_response_schema do
    %Schema{
      type: :object, title: "SessionsResponse",
      description: "All active sessions for the authenticated user",
      properties: %{
        sessions: %Schema{
          type: :array,
          items: %Reference{"$ref": "#/components/schemas/SessionObject"}
        }
      }
    }
  end

  defp session_object_schema do
    %Schema{
      type: :object, title: "SessionObject",
      properties: %{
        id: %Schema{
          type: :string,
          description: "Session ID — pass to DELETE /api/v1/sessions/:id to revoke",
          example: "abc123xyz"
        },
        device: %Schema{
          type: :string,
          description: "Detected device type: desktop / mobile / tablet / api_client / unknown",
          example: "desktop"
        },
        ip_address:     %Schema{type: :string, example: "192.168.1.1"},
        user_agent:     %Schema{type: :string, example: "Mozilla/5.0..."},
        last_active_at: %Schema{type: :string, format: :"date-time"},
        created_at:     %Schema{type: :string, format: :"date-time",
                                description: "Login time"}
      }
    }
  end

  defp password_confirm_schema do
    %Schema{
      type: :object, title: "PasswordConfirmRequest",
      required: [:password],
      properties: %{
        password: %Schema{type: :string, format: :password, example: "securepassword123"}
      }
    }
  end

  defp namespace_response_schema do
    %Schema{
      type: :object, title: "NamespaceResponse",
      properties: %{
        status:    %Schema{type: :string, example: "success"},
        namespace: %Schema{type: :object, additionalProperties: true}
      }
    }
  end

  defp error_response_schema do
    %Schema{
      type: :object, title: "ErrorResponse",
      required: [:error],
      properties: %{
        error: %Schema{type: :string, example: "Invalid or expired token"}
      }
    }
  end

  defp message_response_schema do
    %Schema{
      type: :object, title: "MessageResponse",
      properties: %{
        message: %Schema{type: :string, example: "Session revoked"}
      }
    }
  end

  defp status_response_schema do
    %Schema{
      type: :object, title: "StatusResponse",
      properties: %{
        status: %Schema{type: :string, example: "success"}
      }
    }
  end

  # ════════════════════════════════════════════════════════════
  # HELPER BUILDERS
  # ════════════════════════════════════════════════════════════

  defp op(summary, tag, op_id, desc, responses) do
    %OpenApiSpex.Operation{
      summary: summary, tags: [tag], operationId: op_id,
      description: desc, responses: build_responses(responses)
    }
  end

  defp op_auth(summary, tag, op_id, desc, responses) do
    %OpenApiSpex.Operation{
      summary: summary, tags: [tag], operationId: op_id,
      description: desc, security: [%{"BearerAuth" => []}],
      responses: build_responses(responses)
    }
  end

  defp op_body(summary, tag, op_id, desc, schema_name, responses) do
    %OpenApiSpex.Operation{
      summary: summary, tags: [tag], operationId: op_id,
      description: desc,
      requestBody: OpenApiSpex.Operation.request_body(
        "Request body", "application/json",
        %Reference{"$ref": "#/components/schemas/#{schema_name}"},
        required: true
      ),
      responses: build_responses(responses)
    }
  end

  defp op_auth_body(summary, tag, op_id, desc, schema_name, responses) do
    %OpenApiSpex.Operation{
      summary: summary, tags: [tag], operationId: op_id,
      description: desc, security: [%{"BearerAuth" => []}],
      requestBody: OpenApiSpex.Operation.request_body(
        "Request body", "application/json",
        %Reference{"$ref": "#/components/schemas/#{schema_name}"},
        required: true
      ),
      responses: build_responses(responses)
    }
  end

  defp op_auth_param(summary, tag, op_id, desc, parameters, responses) do
    %OpenApiSpex.Operation{
      summary: summary, tags: [tag], operationId: op_id,
      description: desc, security: [%{"BearerAuth" => []}],
      parameters: parameters,
      responses: build_responses(responses)
    }
  end

  defp op_param(summary, tag, op_id, desc, parameters, responses) do
    %OpenApiSpex.Operation{
      summary: summary, tags: [tag], operationId: op_id,
      description: desc, parameters: parameters,
      responses: build_responses(responses)
    }
  end

  defp op_body_param(summary, tag, op_id, desc, parameters, schema_name, responses) do
  %OpenApiSpex.Operation{
    summary: summary,
    tags: [tag],
    operationId: op_id,
    description: desc,

    # ✅ Swagger Bearer Auth
    security: [%{"BearerAuth" => []}],

    parameters: parameters,

    requestBody:
      OpenApiSpex.Operation.request_body(
        "Request body",
        "application/json",
        %Reference{"$ref": "#/components/schemas/#{schema_name}"},
        required: true
      ),

    responses: build_responses(responses)
  }
end

  defp room_id_param do
    %OpenApiSpex.Parameter{
      name: :id, in: :path, required: true,
      description: "Room ID — lobby | tamil | gaming",
      schema: %Schema{type: :string, example: "lobby"}
    }
  end
  defp session_id_param do
  %OpenApiSpex.Parameter{
    name: :id,
    in: :path,
    required: true,
    description: "Session ID",
    schema: %Schema{
      type: :string,
      example: "abc123xyz"
    }
  }
end

  defp page_param do
    %OpenApiSpex.Parameter{
      name: :page, in: :query, required: false,
      description: "Page number (default: 1)",
      schema: %Schema{type: :integer, example: 1}
    }
  end

  defp per_page_param do
    %OpenApiSpex.Parameter{
      name: :per_page, in: :query, required: false,
      description: "Messages per page (default: 20)",
      schema: %Schema{type: :integer, example: 20}
    }
  end

  defp resp(desc, schema_name) do
    OpenApiSpex.Operation.response(desc, "application/json",
      %Reference{"$ref": "#/components/schemas/#{schema_name}"}
    )
  end

  defp build_responses(map) do
    Enum.into(map, %{})
  end
end
