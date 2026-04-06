defmodule Przma.Lexicons.Collab do
  @moduledoc "STUB lexicons for Circle collaboration (doc sharing, OT ops)."
  def all do
    %{
      "app.przma.collab.circle.share" => stub_proc("app.przma.collab.circle.share", ["did","circle_did","cid"]),
      "app.przma.collab.circle.docOp" => stub_proc("app.przma.collab.circle.docOp", ["did","circle_did","op"])
    }
  end
  defp stub_proc(id, req) do
    %{
      "lexicon" => 1, "id" => id, "type" => "procedure",
      "input"   => %{"type" => "object", "required" => req,
                     "properties" => Map.new(req, &{&1, %{"type" => "string"}})}
    }
  end
end

defmodule Przma.Lexicons.Perception do
  @moduledoc "STUB lexicons for scans, signals, reflections."
  def all do
    %{
      "app.przma.scan.create" => %{
        "lexicon" => 1, "id" => "app.przma.scan.create", "type" => "procedure",
        "description" => "Create a filter scan entry.",
        "input" => %{
          "type" => "object", "required" => ["did","filters"],
          "properties" => %{
            "did"          => %{"type" => "string"},
            "filters"      => %{"type" => "array", "items" => %{"type" => "object"}},
            "light_signal" => %{"type" => "string", "enum" => ["L","i","G","H","T"]},
            "note"         => %{"type" => "string", "maxLength" => 2000}
          }
        }
      },
      "app.przma.scan.list" => %{
        "lexicon" => 1, "id" => "app.przma.scan.list", "type" => "query",
        "parameters" => %{
          "type" => "object", "required" => ["did"],
          "properties" => %{
            "did"    => %{"type" => "string"},
            "limit"  => %{"type" => "integer", "default" => 20},
            "cursor" => %{"type" => "string"}
          }
        }
      },
      "app.przma.signal.emit" => %{
        "lexicon" => 1, "id" => "app.przma.signal.emit", "type" => "procedure",
        "input" => %{
          "type" => "object", "required" => ["did","signal"],
          "properties" => %{
            "did"    => %{"type" => "string"},
            "signal" => %{"type" => "string", "enum" => ["L","i","G","H","T"]}
          }
        }
      },
      "app.przma.reflection.create" => %{
        "lexicon" => 1, "id" => "app.przma.reflection.create", "type" => "procedure",
        "input" => %{
          "type" => "object", "required" => ["did","content"],
          "properties" => %{
            "did"          => %{"type" => "string"},
            "content"      => %{"type" => "string", "maxLength" => 10000},
            "light_signal" => %{"type" => "string", "enum" => ["L","i","G","H","T"]},
            "media_cids"   => %{"type" => "array", "items" => %{"type" => "string"}}
          }
        }
      }
    }
  end
end

defmodule Przma.Lexicons.Circles do
  @moduledoc "STUB lexicons for circle management."
  def all do
    %{
      "app.przma.circle.create" => %{
        "lexicon" => 1, "id" => "app.przma.circle.create", "type" => "procedure",
        "input" => %{
          "type" => "object", "required" => ["did","name"],
          "properties" => %{
            "did"         => %{"type" => "string"},
            "name"        => %{"type" => "string", "maxLength" => 100},
            "description" => %{"type" => "string", "maxLength" => 500},
            "visibility"  => %{"type" => "string", "enum" => ["private","invite_only","public"]}
          }
        }
      },
      "app.przma.circle.members" => %{
        "lexicon" => 1, "id" => "app.przma.circle.members", "type" => "query",
        "parameters" => %{
          "type" => "object", "required" => ["did","circle_did"],
          "properties" => %{
            "did"        => %{"type" => "string"},
            "circle_did" => %{"type" => "string"},
            "limit"      => %{"type" => "integer", "default" => 50}
          }
        }
      },
      "app.przma.circle.invite" => %{
        "lexicon" => 1, "id" => "app.przma.circle.invite", "type" => "procedure",
        "input" => %{
          "type" => "object", "required" => ["did","circle_did","invitee_did"],
          "properties" => %{
            "did"         => %{"type" => "string"},
            "circle_did"  => %{"type" => "string"},
            "invitee_did" => %{"type" => "string"}
          }
        }
      }
    }
  end
end

defmodule Przma.Lexicons.Analytics do
  @moduledoc "STUB lexicons for perception analytics queries."
  def all do
    %{
      "app.przma.analytics.filterTrend"        => stub_query("app.przma.analytics.filterTrend",        ["did"]),
      "app.przma.analytics.signalDistribution" => stub_query("app.przma.analytics.signalDistribution", ["did"]),
      "app.przma.analytics.foggedFilters"      => stub_query("app.przma.analytics.foggedFilters",      ["did"]),
      "app.przma.analytics.collectivePattern"  => stub_query("app.przma.analytics.collectivePattern",  []),
      "app.przma.analytics.circleInsight"      => stub_query("app.przma.analytics.circleInsight",      ["circle_did"])
    }
  end
  defp stub_query(id, req) do
    %{
      "lexicon"    => 1, "id" => id, "type" => "query",
      "parameters" => %{
        "type" => "object", "required" => req,
        "properties" => Map.merge(
          Map.new(req, &{&1, %{"type" => "string"}}),
          %{"limit" => %{"type" => "integer", "default" => 20}}
        )
      }
    }
  end
end
