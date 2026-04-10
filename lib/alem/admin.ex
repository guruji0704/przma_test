defmodule Alem.Admin do
  @moduledoc "Admin context — all queries for the admin panel LiveView."

  import Ecto.Query
  alias Alem.Repo
  alias Alem.Pleroma.User
  alias Alem.Schemas.{Document, Namespace}
  alias Alem.Cas.CasObject
  require Logger

  # ── Dashboard Stats ──────────────────────────────────────────────────────

  def dashboard_stats do
    total_users    = Repo.aggregate(User, :count, :id)
    verified_users = Repo.aggregate(from(u in User, where: u.is_verified == true), :count, :id)
    blocked_users  = Repo.aggregate(from(u in User, where: u.is_active == false), :count, :id)
    admin_users    = Repo.aggregate(from(u in User, where: u.is_admin == true), :count, :id)
    total_files    = Repo.aggregate(Document, :count, :id)
    total_cas      = Repo.aggregate(CasObject, :count, :content_hash)
    duplicate_cas  = Repo.aggregate(from(c in CasObject, where: c.ref_count > 1), :count, :content_hash)
    total_bytes    = Repo.one(from c in CasObject, select: coalesce(sum(c.file_size), 0)) || 0
    saved_bytes    = Repo.one(from c in CasObject, where: c.ref_count > 1,
                       select: coalesce(sum(c.file_size * (c.ref_count - 1)), 0)) || 0
    seven_days_ago = DateTime.add(DateTime.utc_now(), -7, :day) |> DateTime.to_naive()
    new_this_week  = Repo.aggregate(from(u in User, where: u.inserted_at >= ^seven_days_ago), :count, :id)

    %{total_users: total_users, verified_users: verified_users, blocked_users: blocked_users,
      admin_users: admin_users, total_files: total_files, total_cas: total_cas,
      duplicate_cas: duplicate_cas, total_bytes: total_bytes, saved_bytes: saved_bytes,
      new_this_week: new_this_week}
  end

  # ── User List ────────────────────────────────────────────────────────────
  # Simple query + separate file_count — avoids Ecto group_by/order_by binding issues.

  def list_users(opts \\ %{}) do
    search = Map.get(opts, :search, "")
    filter = Map.get(opts, :filter, "all")
    sort   = Map.get(opts, :sort, "newest")
    page   = Map.get(opts, :page, 1)
    per    = 20

    query = from u in User

    query =
      if search != "" do
        term = "%#{search}%"
        where(query, [u], ilike(u.nickname, ^term) or ilike(u.email, ^term) or ilike(u.id, ^term))
      else
        query
      end

    query =
      case filter do
        "verified"   -> where(query, [u], u.is_verified == true)
        "unverified" -> where(query, [u], u.is_verified == false)
        "blocked"    -> where(query, [u], u.is_active == false)
        "active"     -> where(query, [u], u.is_active == true)
        "admin"      -> where(query, [u], u.is_admin == true)
        _            -> query
      end

    total = Repo.aggregate(query, :count, :id)

    query =
      case sort do
        "newest"   -> order_by(query, [u], desc: u.inserted_at)
        "oldest"   -> order_by(query, [u], asc:  u.inserted_at)
        "name_asc" -> order_by(query, [u], asc:  u.nickname)
        _          -> order_by(query, [u], desc: u.inserted_at)
      end

    users = query |> limit(^per) |> offset(^((page - 1) * per)) |> Repo.all()

    # File counts via separate query (no group_by binding issues)
    user_ids = Enum.map(users, & &1.id)
    file_counts =
      if user_ids != [] do
        from(d in Document,
          where: d.user_id in ^user_ids,
          group_by: d.user_id,
          select: {d.user_id, count(d.id)})
        |> Repo.all()
        |> Enum.into(%{})
      else
        %{}
      end

    users_enriched =
      Enum.map(users, fn u ->
        Map.from_struct(u)
        |> Map.put(:file_count, Map.get(file_counts, u.id, 0))
      end)

    users_final =
      if sort == "files_desc" do
        Enum.sort_by(users_enriched, & &1.file_count, :desc)
      else
        users_enriched
      end

    %{users: users_final, total: total, page: page, per: per, pages: ceil(total / per)}
  end

  # ── User Detail ──────────────────────────────────────────────────────────

  def get_user_detail(user_id) do
    case Repo.get(User, user_id) do
      nil  -> nil
      user -> build_user_detail(user)
    end
  end

  defp build_user_detail(user) do
    files =
      from(d in Document,
        where: d.user_id == ^user.id,
        order_by: [desc: d.inserted_at],
        select: %{id: d.id, filename: d.filename, content_type: d.content_type,
                  status: d.status, inserted_at: d.inserted_at})
      |> Repo.all()

    storage_bytes =
      from(d in Document,
        join: c in CasObject, on: c.content_hash == d.content_hash,
        where: d.user_id == ^user.id,
        select: coalesce(sum(c.file_size), 0))
      |> Repo.one() || 0

    type_breakdown =
      from(d in Document,
        where: d.user_id == ^user.id,
        group_by: d.content_type,
        select: {d.content_type, count(d.id)})
      |> Repo.all()
      |> Enum.into(%{})

    duplicates =
      from(d in Document,
        join: c in CasObject, on: c.content_hash == d.content_hash,
        where: d.user_id == ^user.id and c.ref_count > 1,
        select: %{filename: d.filename, content_hash: d.content_hash,
                  ref_count: c.ref_count, file_size: c.file_size})
      |> Repo.all()

    namespace_key = if user.did_id, do: Alem.DID.namespace_key(user.did_id), else: nil
    namespace     = if namespace_key, do: Repo.get(Namespace, namespace_key), else: nil

    sessions =
      from(s in Alem.Session,
        where: s.user_id == ^user.id,
        order_by: [desc: s.last_active_at],
        limit: 5)
      |> Repo.all()

    %{user: user, files: files, storage_bytes: storage_bytes,
      type_breakdown: type_breakdown, duplicates: duplicates,
      namespace: namespace, sessions: sessions, file_count: length(files)}
  end

  # ── User Actions ─────────────────────────────────────────────────────────

  def block_user(uid),    do: set_user(uid, %{is_active: false})
  def unblock_user(uid),  do: set_user(uid, %{is_active: true})
  def promote_admin(uid), do: set_user(uid, %{is_admin: true})
  def demote_admin(uid),  do: set_user(uid, %{is_admin: false})

  defp set_user(uid, changes) do
    case Repo.get(User, uid) do
      nil  -> {:error, :not_found}
      user -> user |> Ecto.Changeset.change(changes) |> Repo.update()
    end
  end

  def soft_delete_user(uid) do
    case Repo.get(User, uid) do
      nil  -> {:error, :not_found}
      user ->
        Repo.transaction(fn ->
          user
          |> Ecto.Changeset.change(%{is_active: false,
              email: "deleted_#{uid}@przma.deleted",
              password_hash: "DELETED", otp_code: nil, reset_token: nil})
          |> Repo.update!()
          from(t in Alem.Pleroma.Web.OAuth.Token, where: t.user_id == ^uid)
          |> Repo.update_all(set: [revoked_at: DateTime.utc_now() |> DateTime.truncate(:second)])
          Logger.info("[Admin] Soft deleted #{uid}")
          :ok
        end)
    end
  end

  def hard_delete_user(uid) do
    case Repo.get(User, uid) do
      nil  -> {:error, :not_found}
      user ->
        Repo.transaction(fn ->
          from(s in Alem.Session, where: s.user_id == ^uid) |> Repo.delete_all()
          from(t in Alem.Pleroma.Web.OAuth.Token, where: t.user_id == ^uid) |> Repo.delete_all()
          from(d in Document, where: d.user_id == ^uid) |> Repo.delete_all()
          Repo.delete!(user)
          Logger.info("[Admin] Hard deleted #{uid}")
          :ok
        end)
    end
  end

  # ── CAS Vault ────────────────────────────────────────────────────────────

  def list_cas_objects(opts \\ %{}) do
    search = Map.get(opts, :search, "")
    filter = Map.get(opts, :filter, "all")
    page   = Map.get(opts, :page, 1)
    per    = 25

    query = from c in CasObject, order_by: [desc: c.inserted_at]

    query =
      if search != "" do
        term = "%#{search}%"
        where(query, [c], ilike(c.storage_key, ^term) or ilike(c.media_type, ^term) or ilike(c.content_hash, ^term))
      else
        query
      end

    query =
      case filter do
        "duplicates" -> where(query, [c], c.ref_count > 1)
        "large"      -> where(query, [c], c.file_size > 10_485_760)
        "images"     -> where(query, [c], ilike(c.media_type, "image/%"))
        "docs"       -> where(query, [c], ilike(c.media_type, "%document%") or ilike(c.media_type, "%pdf%"))
        _            -> query
      end

    total = Repo.aggregate(query, :count, :content_hash)
    items = query |> limit(^per) |> offset(^((page - 1) * per)) |> Repo.all()
    %{items: items, total: total, page: page, per: per, pages: ceil(total / per)}
  end

  def s3_folder_tree do
    from(c in CasObject,
      group_by: c.namespace_key,
      select: %{namespace_key: c.namespace_key,
                file_count: count(c.content_hash),
                total_bytes: coalesce(sum(c.file_size), 0)},
      order_by: [desc: count(c.content_hash)])
    |> Repo.all()
  end

  def duplicate_analysis do
    duplicates =
      from(c in CasObject,
        where: c.ref_count > 1,
        order_by: [desc: c.ref_count], limit: 100)
      |> Repo.all()

    total_wasted =
      from(c in CasObject, where: c.ref_count > 1,
        select: coalesce(sum(c.file_size * (c.ref_count - 1)), 0))
      |> Repo.one() || 0

    %{duplicates: duplicates, total_wasted: total_wasted}
  end

  # ── SQL Console ──────────────────────────────────────────────────────────

  @blocked ~w(INSERT UPDATE DELETE DROP TRUNCATE ALTER CREATE GRANT REVOKE EXEC EXECUTE)

  def run_sql(sql) do
    trimmed  = String.trim(sql)
    upper    = String.upcase(trimmed)

    cond do
      trimmed == "" ->
        {:error, "Empty query"}

      not String.starts_with?(upper, "SELECT") ->
        {:error, "Only SELECT queries are allowed in the admin console"}

      Enum.any?(@blocked, &String.contains?(upper, &1)) ->
        bad = Enum.find(@blocked, &String.contains?(upper, &1))
        {:error, "Blocked keyword detected: #{bad}"}

      true ->
        try do
          %{columns: cols, rows: rows} = Repo.query!(trimmed, [], timeout: 10_000)
          {:ok, %{columns: cols || [], rows: rows || [], count: length(rows || [])}}
        rescue
          e -> {:error, Exception.message(e)}
        end
    end
  end

  # ── S3 Browser ───────────────────────────────────────────────────────────

  def list_s3_objects(prefix \\ "") do
    bucket = get_bucket()

    opts =
      [delimiter: "/", max_keys: 500]
      |> then(fn o -> if prefix != "", do: Keyword.put(o, :prefix, prefix), else: o end)

    case ExAws.S3.list_objects(bucket, opts) |> ExAws.request() do
      {:ok, %{body: body}} ->
        objects  = Map.get(body, :contents, [])
        prefixes = Map.get(body, :common_prefixes, [])
        {:ok, %{bucket: bucket, prefix: prefix, objects: objects, prefixes: prefixes}}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  def s3_presigned_url(key) do
    config = ExAws.Config.new(:s3)
    ExAws.S3.presigned_url(config, :get, get_bucket(), key, expires_in: 900)
  end

  defp get_bucket do
    Application.get_env(:alem, :file_storage, [])[:bucket] ||
      Application.get_env(:ex_aws, :s3, [])[:bucket] ||
      "perkeep"
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  def format_bytes(b) when is_integer(b) and b > 0 do
    cond do
      b >= 1_073_741_824 -> "#{Float.round(b / 1_073_741_824, 2)} GB"
      b >= 1_048_576     -> "#{Float.round(b / 1_048_576, 2)} MB"
      b >= 1_024         -> "#{Float.round(b / 1_024, 2)} KB"
      true               -> "#{b} B"
    end
  end
  def format_bytes(_), do: "0 B"
end
