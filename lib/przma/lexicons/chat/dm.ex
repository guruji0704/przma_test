defmodule Przma.Lexicons.Chat.DM do
  @moduledoc "Lexicons for 1:1 direct message operations."

  def all do
    %{
      "app.przma.chat.dm.send" => %{
        "lexicon"     => 1,
        "id"          => "app.przma.chat.dm.send",
        "type"        => "procedure",
        "description" => "Send a private DM. Stored in sender vault, delivered to recipient inbox.",
        "input"       => %{
          "type"       => "object",
          "required"   => ["sender_did", "recipient_did", "content"],
          "properties" => %{
            "sender_did"      => %{"type" => "string"},
            "recipient_did"   => %{"type" => "string"},
            "content"         => %{"type" => "string", "maxLength" => 5000},
            "media_cids"      => %{"type" => "array", "items" => %{"type" => "string"}, "maxItems" => 10},
            "reply_to_id"     => %{"type" => "string"},
            "light_signal"    => %{"type" => "string", "enum" => ["L","i","G","H","T"]},
            "idempotency_key" => %{"type" => "string", "maxLength" => 64}
          }
        },
        "output" => %{
          "type"       => "object",
          "required"   => ["message_id", "cas_cid", "thread_id"],
          "properties" => %{
            "message_id"      => %{"type" => "string"},
            "cas_cid"         => %{"type" => "string"},
            "thread_id"       => %{"type" => "string"},
            "delivery_status" => %{"type" => "string", "enum" => ["sent","delivered"]}
          }
        }
      },

      "app.przma.chat.dm.list" => %{
        "lexicon"     => 1,
        "id"          => "app.przma.chat.dm.list",
        "type"        => "query",
        "description" => "List messages in a DM thread.",
        "parameters"  => %{
          "type"       => "object",
          "required"   => ["did", "thread_id"],
          "properties" => %{
            "did"       => %{"type" => "string"},
            "thread_id" => %{"type" => "string"},
            "limit"     => %{"type" => "integer", "default" => 30, "maximum" => 100},
            "cursor"    => %{"type" => "string"},
            "direction" => %{"type" => "string", "enum" => ["before","after"], "default" => "before"}
          }
        },
        "output" => %{
          "type"       => "object",
          "required"   => ["messages"],
          "properties" => %{
            "messages" => %{"type" => "array"},
            "cursor"   => %{"type" => "string"},
            "thread"   => %{"type" => "object"}
          }
        }
      },

      "app.przma.chat.dm.threads" => %{
        "lexicon"     => 1,
        "id"          => "app.przma.chat.dm.threads",
        "type"        => "query",
        "description" => "List all DM threads for a user.",
        "parameters"  => %{
          "type"       => "object",
          "required"   => ["did"],
          "properties" => %{
            "did"         => %{"type" => "string"},
            "limit"       => %{"type" => "integer", "default" => 20},
            "cursor"      => %{"type" => "string"},
            "unread_only" => %{"type" => "boolean", "default" => false}
          }
        }
      },

      "app.przma.chat.dm.delete" => %{
        "lexicon"     => 1,
        "id"          => "app.przma.chat.dm.delete",
        "type"        => "procedure",
        "description" => "Retract a sent DM. Sends AP Delete to recipient.",
        "input"       => %{
          "type"       => "object",
          "required"   => ["sender_did", "message_id"],
          "properties" => %{
            "sender_did" => %{"type" => "string"},
            "message_id" => %{"type" => "string"}
          }
        }
      },

      "app.przma.chat.dm.react" => %{
        "lexicon"     => 1,
        "id"          => "app.przma.chat.dm.react",
        "type"        => "procedure",
        "description" => "React to a DM message.",
        "input"       => %{
          "type"       => "object",
          "required"   => ["sender_did", "message_id", "reaction"],
          "properties" => %{
            "sender_did" => %{"type" => "string"},
            "message_id" => %{"type" => "string"},
            "reaction"   => %{"type" => "string",
                               "enum" => ["like","heart","light","gratitude"]}
          }
        }
      }
    }
  end
end
