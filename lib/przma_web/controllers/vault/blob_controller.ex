defmodule PrzmaWeb.Vault.BlobController do
  use PrzmaWeb, :controller

  def presign(conn, params) do
    did      = conn.assigns[:current_did]
    filename = params["filename"] || "unnamed"
    cid      = "blake3:" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    json(conn, %{
      upload_id:   Uniq.UUID.uuid7(),
      cid:         cid,
      upload_url:  "https://stub-s3.example.com/#{cid}",
      method:      "PUT",
      expires_at:  DateTime.utc_now() |> DateTime.add(900, :second) |> DateTime.to_iso8601(),
      did:         did,
      filename:    filename
    })
  end

  def confirm(conn, params) do
    json(conn, %{status: "confirmed", cid: params["cid"], upload_id: params["upload_id"]})
  end

  def inline(conn, params) do
    did     = conn.assigns[:current_did]
    content = params["content"] || ""
    cid     = Przma.Vault.ContentStore.compute_cid(content)
    json(conn, %{cid: cid, did: did, size: byte_size(content)})
  end
end
