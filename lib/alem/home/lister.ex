defmodule Alem.Home.Lister do
  @moduledoc "Lists files in a home folder with optional filtering."

  import Ecto.Query
  alias Alem.{Repo, Schemas.Document}

  def run(user_id, folder, opts \\ []) do
    limit    = Keyword.get(opts, :limit, 200)
    category = Keyword.get(opts, :category)  # images|videos|audio|documents|nil
    search   = Keyword.get(opts, :search)
    sort     = Keyword.get(opts, :sort, "newest")

    query =
      from d in Document,
        where: d.user_id == ^user_id and d.folder == ^folder,
        select: %{
          id:             d.id,
          filename:       d.filename,
          content_type:   d.content_type,
          object_key:     d.object_key,
          content_hash:   d.content_hash,
          folder:         d.folder,
          media_category: d.media_category,
          is_encrypted:   d.is_encrypted,
          status:         d.status,
          inserted_at:    d.inserted_at
        },
        limit: ^limit

    query = if category, do: where(query, [d], d.media_category == ^category), else: query

    query =
      if search && search != "" do
        term = "%#{String.downcase(search)}%"
        where(query, [d], like(fragment("lower(?)", d.filename), ^term))
      else
        query
      end

    query =
      case sort do
        "oldest" -> order_by(query, [d], [asc:  d.inserted_at])
        "az"     -> order_by(query, [d], [asc:  d.filename])
        "za"     -> order_by(query, [d], [desc: d.filename])
        _        -> order_by(query, [d], [desc: d.inserted_at])
      end

    {:ok, Repo.all(query)}
  rescue e ->
    {:error, Exception.message(e)}
  end
end
