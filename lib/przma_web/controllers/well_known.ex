defmodule PrzmaWeb.WebFingerController do
  use PrzmaWeb, :controller

  def show(conn, %{"resource" => resource}) do
    json(conn, %{
      subject: resource,
      links: [
        %{
          rel:  "self",
          type: "application/activity+json",
          href: "#{PrzmaWeb.Endpoint.url()}/users/#{URI.encode(resource)}"
        }
      ]
    })
  end

  def show(conn, _params) do
    conn |> put_status(400) |> json(%{error: "resource param required"})
  end
end

defmodule PrzmaWeb.NodeInfoController do
  use PrzmaWeb, :controller

  def show(conn, _params) do
    json(conn, %{
      links: [
        %{rel: "http://nodeinfo.diaspora.software/ns/schema/2.1",
          href: "#{PrzmaWeb.Endpoint.url()}/nodeinfo/2.1"}
      ]
    })
  end

  def v21(conn, _params) do
    json(conn, %{
      version: "2.1",
      software: %{name: "przma", version: "0.4.0"},
      protocols: ["activitypub"],
      usage: %{users: %{total: 0, activeMonth: 0}},
      openRegistrations: false
    })
  end
end

defmodule PrzmaWeb.HostMetaController do
  use PrzmaWeb, :controller

  def show(conn, _params) do
    base = PrzmaWeb.Endpoint.url()
    conn
    |> put_resp_content_type("application/xrd+xml")
    |> send_resp(200, """
    <?xml version="1.0" encoding="UTF-8"?>
    <XRD xmlns="http://docs.oasis-open.org/ns/xri/xrd-1.0">
      <Link rel="lrdd" template="#{base}/.well-known/webfinger?resource={uri}"/>
    </XRD>
    """)
  end
end

defmodule PrzmaWeb.DIDController do
  use PrzmaWeb, :controller

  def well_known(conn, _params) do
    json(conn, %{
      "@context"         => "https://www.w3.org/ns/did/v1",
      "id"               => "did:przma:server",
      "verificationMethod" => []
    })
  end
end

defmodule PrzmaWeb.HealthController do
  use PrzmaWeb, :controller

  def check(conn, _params) do
    json(conn, %{
      status:  "ok",
      version: "0.4.0",
      time:    DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end
end
