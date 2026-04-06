defmodule Przma.Lexicons.Inbox do
  @moduledoc "Lexicons for inbox and outbox operations."

  def all, do: Map.merge(inbox(), outbox())

  defp inbox do
    %{
      "app.przma.inbox.list" => %{
        "lexicon"     => 1,
        "id"          => "app.przma.inbox.list",
        "type"        => "query",
        "description" => "Fetch paginated inbox. Returns received AP activities.",
        "parameters"  => %{
          "type"       => "object",
          "required"   => ["did"],
          "properties" => %{
            "did"           => %{"type" => "string"},
            "limit"         => %{"type" => "integer", "minimum" => 1, "maximum" => 100, "default" => 20},
            "cursor"        => %{"type" => "string"},
            "unread_only"   => %{"type" => "boolean", "default" => false},
            "activity_type" => %{"type" => "string",
                                  "enum" => ["Create","Delete","Like","Follow","Announce","Read"]},
            "vault_tier"    => %{"type" => "string", "enum" => ["private","social"]}
          }
        },
        "output" => %{
          "type"       => "object",
          "required"   => ["activities"],
          "properties" => %{
            "activities"   => %{"type" => "array"},
            "cursor"       => %{"type" => "string"},
            "unread_count" => %{"type" => "integer"}
          }
        }
      },

      "app.przma.inbox.markRead" => %{
        "lexicon"     => 1,
        "id"          => "app.przma.inbox.markRead",
        "type"        => "procedure",
        "description" => "Mark one or more inbox activities as read.",
        "input"       => %{
          "type"       => "object",
          "required"   => ["did", "activity_ids"],
          "properties" => %{
            "did"          => %{"type" => "string"},
            "activity_ids" => %{"type" => "array", "items" => %{"type" => "string"}, "maxItems" => 100}
          }
        },
        "output" => %{
          "type"       => "object",
          "properties" => %{"marked" => %{"type" => "integer"}}
        }
      },

      "app.przma.inbox.delete" => %{
        "lexicon"     => 1,
        "id"          => "app.przma.inbox.delete",
        "type"        => "procedure",
        "description" => "Remove an activity from inbox. Sovereign right.",
        "input"       => %{
          "type"     => "object",
          "required" => ["did", "activity_id"],
          "properties" => %{
            "did"         => %{"type" => "string"},
            "activity_id" => %{"type" => "string"}
          }
        }
      }
    }
  end

  defp outbox do
    %{
      "app.przma.outbox.list" => %{
        "lexicon"     => 1,
        "id"          => "app.przma.outbox.list",
        "type"        => "query",
        "description" => "Fetch paginated outbox. Returns sent AP activities.",
        "parameters"  => %{
          "type"       => "object",
          "required"   => ["did"],
          "properties" => %{
            "did"             => %{"type" => "string"},
            "limit"           => %{"type" => "integer", "default" => 20, "maximum" => 100},
            "cursor"          => %{"type" => "string"},
            "delivery_status" => %{"type" => "string",
                                    "enum" => ["pending","sent","delivered","failed"]}
          }
        },
        "output" => %{
          "type"       => "object",
          "required"   => ["activities"],
          "properties" => %{
            "activities" => %{"type" => "array"},
            "cursor"     => %{"type" => "string"}
          }
        }
      },

      "app.przma.outbox.retry" => %{
        "lexicon"     => 1,
        "id"          => "app.przma.outbox.retry",
        "type"        => "procedure",
        "description" => "Retry delivery of a failed outbox activity.",
        "input"       => %{
          "type"     => "object",
          "required" => ["did", "outbox_id"],
          "properties" => %{
            "did"       => %{"type" => "string"},
            "outbox_id" => %{"type" => "string"}
          }
        }
      }
    }
  end
end
