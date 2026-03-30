defmodule AlemWeb.Resolvers.Document do
  @moduledoc "Resolvers for document queries and mutations."

  alias Alem.{DID, Namespace}

  def list(_parent, args, %{context: ctx}) do
    ns_key = DID.namespace_key(ctx.current_user.did_id)
    Namespace.list_documents(ns_key, %{
      limit:  args[:limit]  || 20,
      offset: args[:offset] || 0,
      status: args[:status]
    })
  end

  def get(_parent, %{id: id}, %{context: ctx}) do
    ns_key = DID.namespace_key(ctx.current_user.did_id)
    Namespace.get_document(ns_key, id)
  end

  def search(_parent, %{query: query} = args, %{context: ctx}) do
    ns_key = DID.namespace_key(ctx.current_user.did_id)
    Namespace.search_documents(ns_key, query, %{limit: args[:limit] || 20})
  end

  def delete(_parent, %{id: id}, %{context: ctx}) do
    ns_key = DID.namespace_key(ctx.current_user.did_id)
    case Namespace.delete_document(ns_key, id) do
      :ok          -> {:ok, %{success: true, id: id}}
      {:error, _r} -> {:ok, %{success: false, id: id}}
    end
  end
end
