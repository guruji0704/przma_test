defmodule PrzmaWeb.ActivityPub.ActorController do
  use PrzmaWeb, :controller

  def show(conn, %{"did" => did}) do
    base = PrzmaWeb.Endpoint.url()
    json(conn, %{
      "@context"         => ["https://www.w3.org/ns/activitystreams", "https://w3id.org/security/v1"],
      "id"               => "#{base}/users/#{URI.encode(did)}",
      "type"             => "Person",
      "preferredUsername"=> did,
      "inbox"            => "#{base}/users/#{URI.encode(did)}/inbox",
      "outbox"           => "#{base}/users/#{URI.encode(did)}/outbox",
      "followers"        => "#{base}/users/#{URI.encode(did)}/followers",
      "following"        => "#{base}/users/#{URI.encode(did)}/following"
    })
  end
end

defmodule PrzmaWeb.ActivityPub.InboxController do
  use PrzmaWeb, :controller

  def create(conn, _params) do
    raw_body = conn.assigns[:raw_body] || ""

    case Przma.Federation.HttpSignature.verify(conn, raw_body) do
      {:ok, key_id} ->
        require Logger
        Logger.info("[InboxController] Verified activity from #{key_id}")
        conn |> put_status(202) |> json(%{status: "accepted"})

      {:error, reason} ->
        conn |> put_status(401) |> json(%{error: inspect(reason)})
    end
  end
end

defmodule PrzmaWeb.ActivityPub.OutboxController do
  use PrzmaWeb, :controller

  def index(conn, %{"did" => did}) do
    base = PrzmaWeb.Endpoint.url()
    json(conn, %{
      "@context"   => "https://www.w3.org/ns/activitystreams",
      "id"         => "#{base}/users/#{URI.encode(did)}/outbox",
      "type"       => "OrderedCollection",
      "totalItems" => 0,
      "orderedItems" => []
    })
  end
end

defmodule PrzmaWeb.ActivityPub.SharedInboxController do
  use PrzmaWeb, :controller
  def create(conn, _params), do: conn |> put_status(202) |> json(%{status: "accepted"})
end

defmodule PrzmaWeb.ActivityPub.CircleActorController do
  use PrzmaWeb, :controller
  def show(conn, %{"circle_did" => circle_did}), do: json(conn, %{id: circle_did, type: "Group"})
end

defmodule PrzmaWeb.ActivityPub.CircleInboxController do
  use PrzmaWeb, :controller
  def create(conn, _params), do: conn |> put_status(202) |> json(%{status: "accepted"})
end

defmodule PrzmaWeb.ActivityPub.MemorialActorController do
  use PrzmaWeb, :controller
  def show(conn, %{"did" => did}), do: json(conn, %{id: did, type: "Service", name: "Memorial Agent"})
end

defmodule PrzmaWeb.ActivityPub.ObjectController do
  use PrzmaWeb, :controller
  def show(conn, %{"cid" => cid}), do: json(conn, %{id: cid, type: "Object"})
end

defmodule PrzmaWeb.ActivityPub.FollowersController do
  use PrzmaWeb, :controller
  def index(conn, %{"did" => did}) do
    base = PrzmaWeb.Endpoint.url()
    json(conn, %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id"       => "#{base}/users/#{URI.encode(did)}/followers",
      "type"     => "OrderedCollection",
      "totalItems" => 0,
      "orderedItems" => []
    })
  end
end

defmodule PrzmaWeb.ActivityPub.FollowingController do
  use PrzmaWeb, :controller
  def index(conn, %{"did" => did}) do
    base = PrzmaWeb.Endpoint.url()
    json(conn, %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id"       => "#{base}/users/#{URI.encode(did)}/following",
      "type"     => "OrderedCollection",
      "totalItems" => 0,
      "orderedItems" => []
    })
  end
end
