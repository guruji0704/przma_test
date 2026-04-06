defmodule Przma.Lexicons.Chat.Shout do
  @moduledoc "STUB lexicons for public shout broadcasts."
  def all do
    %{
      "app.przma.chat.shout.broadcast" => %{
        "lexicon" => 1, "id" => "app.przma.chat.shout.broadcast", "type" => "procedure",
        "description" => "Broadcast a public LiGHT-tagged shout.",
        "input" => %{
          "type" => "object", "required" => ["did","content"],
          "properties" => %{
            "did"          => %{"type" => "string"},
            "content"      => %{"type" => "string", "maxLength" => 500},
            "light_signal" => %{"type" => "string", "enum" => ["L","i","G","H","T"]}
          }
        }
      },
      "app.przma.chat.shout.feed" => %{
        "lexicon" => 1, "id" => "app.przma.chat.shout.feed", "type" => "query",
        "description" => "Fetch the public shout feed.",
        "parameters" => %{
          "type" => "object", "required" => [],
          "properties" => %{
            "limit"  => %{"type" => "integer", "default" => 20},
            "cursor" => %{"type" => "string"}
          }
        }
      }
    }
  end
end

defmodule Przma.Lexicons.Chat.Agent do
  @moduledoc "STUB lexicons for AI agent chat."
  def all do
    %{
      "app.przma.agent.message"      => stub_proc("app.przma.agent.message",      ["did","content"]),
      "app.przma.agent.draft.approve"=> stub_proc("app.przma.agent.draft.approve",["did","draft_id"]),
      "app.przma.agent.vault.read"   => stub_proc("app.przma.agent.vault.read",   ["did","path"]),
      "app.przma.agent.draft.stage"  => stub_proc("app.przma.agent.draft.stage",  ["did","content"])
    }
  end
  defp stub_proc(id, req), do: %{"lexicon"=>1,"id"=>id,"type"=>"procedure","input"=>%{"type"=>"object","required"=>req,"properties"=>Map.new(req,&{&1,%{"type"=>"string"}})}}
end

defmodule Przma.Lexicons.Memorial do
  @moduledoc "STUB lexicons for memorial agent."
  def all do
    %{
      "app.przma.memorial.query"    => stub("app.przma.memorial.query",    "procedure", ["did","query"]),
      "app.przma.memorial.activate" => stub("app.przma.memorial.activate", "procedure", ["did","heir_did"])
    }
  end
  defp stub(id, type, req), do: %{"lexicon"=>1,"id"=>id,"type"=>type,"input"=>%{"type"=>"object","required"=>req,"properties"=>Map.new(req,&{&1,%{"type"=>"string"}})}}
end

defmodule Przma.Lexicons.Vault do
  @moduledoc "STUB lexicons for vault CRUD operations."
  def all do
    %{
      "app.przma.vault.put"    => %{"lexicon"=>1,"id"=>"app.przma.vault.put",   "type"=>"procedure","input"   =>%{"type"=>"object","required"=>["did","path","content"],"properties"=>%{"did"=>%{"type"=>"string"},"path"=>%{"type"=>"string"},"content"=>%{"type"=>"string"},"tier"=>%{"type"=>"string","enum"=>["personal","private","social"]}}}},
      "app.przma.vault.get"    => %{"lexicon"=>1,"id"=>"app.przma.vault.get",   "type"=>"query",    "parameters"=>%{"type"=>"object","required"=>["did","path"],"properties"=>%{"did"=>%{"type"=>"string"},"path"=>%{"type"=>"string"}}}},
      "app.przma.vault.list"   => %{"lexicon"=>1,"id"=>"app.przma.vault.list",  "type"=>"query",    "parameters"=>%{"type"=>"object","required"=>["did"],"properties"=>%{"did"=>%{"type"=>"string"},"prefix"=>%{"type"=>"string"},"limit"=>%{"type"=>"integer","default"=>50}}}},
      "app.przma.vault.delete" => %{"lexicon"=>1,"id"=>"app.przma.vault.delete","type"=>"procedure","input"   =>%{"type"=>"object","required"=>["did","path"],"properties"=>%{"did"=>%{"type"=>"string"},"path"=>%{"type"=>"string"}}}},
      "app.przma.vault.grant"  => %{"lexicon"=>1,"id"=>"app.przma.vault.grant", "type"=>"procedure","input"   =>%{"type"=>"object","required"=>["did","grantee_did","path"],"properties"=>%{"did"=>%{"type"=>"string"},"grantee_did"=>%{"type"=>"string"},"path"=>%{"type"=>"string"}}}}
    }
  end
end

defmodule Przma.Lexicons.Studio do
  @moduledoc "STUB lexicons for studio media upload."
  def all do
    %{
      "app.przma.studio.upload.initiate" => %{"lexicon"=>1,"id"=>"app.przma.studio.upload.initiate","type"=>"procedure","input"=>%{"type"=>"object","required"=>["did","filename","size","mime_type"],"properties"=>%{"did"=>%{"type"=>"string"},"filename"=>%{"type"=>"string"},"size"=>%{"type"=>"integer"},"mime_type"=>%{"type"=>"string"}}}},
      "app.przma.studio.upload.status"   => %{"lexicon"=>1,"id"=>"app.przma.studio.upload.status",  "type"=>"query",    "parameters"=>%{"type"=>"object","required"=>["did","upload_id"],"properties"=>%{"did"=>%{"type"=>"string"},"upload_id"=>%{"type"=>"string"}}}}
    }
  end
end
