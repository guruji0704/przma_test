defmodule Przma.Lexicons.Chat.Circle do
  @moduledoc "STUB lexicons for Circle (group) chat."
  def all do
    %{
      "app.przma.chat.circle.send"   => stub("app.przma.chat.circle.send",   "procedure", ["circle_did","sender_did","content"]),
      "app.przma.chat.circle.list"   => stub("app.przma.chat.circle.list",   "query",     ["did","circle_did"]),
      "app.przma.chat.circle.join"   => stub("app.przma.chat.circle.join",   "procedure", ["did","circle_did"]),
      "app.przma.chat.circle.accept" => stub("app.przma.chat.circle.accept", "procedure", ["did","circle_did","invitee_did"]),
      "app.przma.chat.circle.leave"  => stub("app.przma.chat.circle.leave",  "procedure", ["did","circle_did"])
    }
  end

  defp stub(id, type, required) do
    key = if type == "query", do: "parameters", else: "input"
    %{
      "lexicon" => 1, "id" => id, "type" => type,
      key => %{
        "type" => "object", "required" => required,
        "properties" => Map.new(required, &{&1, %{"type" => "string"}})
      }
    }
  end
end
