defmodule PrzmaWeb.XRPC.InboxHandler do
  use PrzmaWeb, :controller

  def list(conn, params) do
    did = params["did"] || conn.assigns[:current_did]
    json(conn, %{
      activities:   [],
      cursor:       nil,
      unread_count: 0,
      did:          did
    })
  end

  def mark_read(conn, params) do
    json(conn, %{marked: length(params["activity_ids"] || [])})
  end

  def delete(conn, _params) do
    json(conn, %{status: "deleted"})
  end
end

defmodule PrzmaWeb.XRPC.OutboxHandler do
  use PrzmaWeb, :controller

  def list(conn, params) do
    did = params["did"] || conn.assigns[:current_did]
    json(conn, %{activities: [], cursor: nil, did: did})
  end

  def retry(conn, _params) do
    json(conn, %{status: "queued"})
  end
end

defmodule PrzmaWeb.XRPC.DMHandler do
  use PrzmaWeb, :controller

  def send_message(conn, params) do
    sender_did    = params["sender_did"] || conn.assigns[:current_did]
    recipient_did = params["recipient_did"]
    content       = params["content"]

    # Compute deterministic thread_id from sorted DID pair
    thread_id = compute_thread_id(sender_did, recipient_did)
    message_id = Uniq.UUID.uuid7()

    # Compute CID for the content
    cid = Przma.Vault.ContentStore.compute_cid(content)

    json(conn, %{
      message_id:      message_id,
      cas_cid:         cid,
      thread_id:       thread_id,
      delivery_status: "sent"
    })
  end

  def list(conn, params) do
    json(conn, %{messages: [], cursor: nil, thread: %{id: params["thread_id"]}})
  end

  def threads(conn, params) do
    did = params["did"] || conn.assigns[:current_did]
    json(conn, %{threads: [], cursor: nil, did: did})
  end

  def delete(conn, _params) do
    json(conn, %{status: "deleted"})
  end

  def react(conn, params) do
    json(conn, %{status: "reacted", reaction: params["reaction"]})
  end

defp compute_thread_id(did_a, did_b) when is_binary(did_a) and is_binary(did_b) do
  sorted = Enum.sort([did_a, did_b]) |> Enum.join(":")
  hash = :crypto.hash(:sha256, sorted)
  "sha256:" <> Base.url_encode64(hash, padding: false)
end

  defp compute_thread_id(_, _), do: "thread_unknown"
end

defmodule PrzmaWeb.XRPC.VaultHandler do
  use PrzmaWeb, :controller

  def put(conn, params) do
    did     = params["did"] || conn.assigns[:current_did]
    path    = params["path"]
    content = params["content"]
    tier    = String.to_atom(params["tier"] || "personal")

    ns_path = "przma://#{did}/vault/#{tier}/#{path}"

    case Przma.Vault.ContentStore.store(content, did, ns_path, tier: tier, mime_type: "text/plain") do
      {:ok, cid} ->
        json(conn, %{cid: cid, path: path, tier: tier})
      {:error, reason} ->
        conn |> put_status(500) |> json(%{error: inspect(reason)})
    end
  end

  def get(conn, params) do
    did = params["did"] || conn.assigns[:current_did]
    json(conn, %{did: did, path: params["path"], content: nil, status: "stub"})
  end

  def list(conn, params) do
    did = params["did"] || conn.assigns[:current_did]
    json(conn, %{items: [], did: did, prefix: params["prefix"]})
  end

  def delete(conn, _params) do
    json(conn, %{status: "deleted"})
  end

  def grant(conn, _params) do
    json(conn, %{status: "granted"})
  end
end
