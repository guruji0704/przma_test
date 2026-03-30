defmodule AlemWeb.Resolvers.Cas do
  @moduledoc "Resolver for CAS object queries."

  alias Alem.Repo
  alias Alem.Cas.CasObject

  def get(_parent, %{hash: hash}, _ctx) do
    case Repo.get(CasObject, hash) do
      nil    -> {:error, "CAS object not found"}
      cas_obj -> {:ok, cas_obj}
    end
  end
end
