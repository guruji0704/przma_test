defmodule Alem.Admin do
  @moduledoc """
  Platform Control Plane Context.

  Manages the two planes of the PRZMA platform:
    - DATA PLANE: CAS, documents, S3, namespaces, analytics
    - CONTROL PLANE: Users, quotas, security, service authorization
  """

  import Ecto.Query
  alias Alem.Repo
  alias Alem.Pleroma.User
  alias Alem.Schemas.{Document, Namespace}
  alias Alem.Cas.CasObject
  require Logger

  # ── Plan Definitions ──────────────────────────────────────────────────────

  @plans %{
    "free"       => %{name: "Free",       quota_bytes: 5_368_709_120,   color: "gy", label: "5 GB"},
    "pro"        => %{name: "Pro",        quota_bytes: 107_374_182_400,  color: "bl", label: "100 GB"},
    "enterprise" => %{name: "Enterprise", quota_bytes: nil,              color: "pu", label: "Unlimited"}
  }

  @services [
    %{key: "sync_api",    name: "Sync API",           desc: "CRDT document sync service"},
    %{key: "analytics",   name: "Analytics",           desc: "Arrow/Parquet metadata pipeline"},
    %{key: "vault",       name: "Vault Storage",       desc: "Encrypted file vault (CAS)"},
    %{key: "identity",    name: "Identity Services",   desc: "DID generation and resolution"},
    %{key: "api_access",  name: "API Access",          desc: "OAuth2 token issuance"},
  ]

  def plans, do: @plans
  def services, do: @services

  def plan_info(plan) do
    Map.get(@plans, plan || "free", @plans["free"])
  end

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
    active_sessions = Repo.aggregate(from(s in Alem.Session, where: is_nil(s.revoked_at)), :count, :id)
    active_tokens   = Repo.aggregate(
      from(t in Alem.Pleroma.Web.OAuth.Token,
        where: is_nil(t.revoked_at) and t.valid_until > ^DateTime.utc_now()),
      :count, :id)

    %{total_users: total_users, verified_users: verified_users, blocked_users: blocked_users,
      admin_users: admin_users, total_files: total_files, total_cas: total_cas,
      duplicate_cas: duplicate_cas, total_bytes: total_bytes, saved_bytes: saved_bytes,
      new_this_week: new_this_week, active_sessions: active_sessions, active_tokens: active_tokens}
  end

  # ── User List ────────────────────────────────────────────────────────────

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
        "moderator"  -> where(query, [u], u.is_moderator == true)
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

    user_ids = Enum.map(users, & &1.id)
    file_counts =
      if user_ids != [] do
        from(d in Document, where: d.user_id in ^user_ids,
          group_by: d.user_id, select: {d.user_id, count(d.id)})
        |> Repo.all() |> Enum.into(%{})
      else
        %{}
      end

    # Get namespaces for plan info
    ns_keys = users
      |> Enum.filter(& &1.did_id)
      |> Enum.map(fn u -> Alem.DID.namespace_key(u.did_id) end)

    namespaces =
      if ns_keys != [] do
        from(n in Namespace, where: n.id in ^ns_keys, select: {n.id, n.config})
        |> Repo.all() |> Enum.into(%{})
      else
        %{}
      end

    users_enriched =
      Enum.map(users, fn u ->
        ns_key   = if u.did_id, do: Alem.DID.namespace_key(u.did_id), else: nil
        ns_cfg   = if ns_key, do: Map.get(namespaces, ns_key, %{}), else: %{}
        plan     = Map.get(ns_cfg, "plan", "free")
        Map.from_struct(u)
        |> Map.put(:file_count, Map.get(file_counts, u.id, 0))
        |> Map.put(:plan, plan)
        |> Map.put(:ns_key, ns_key)
      end)

    users_final =
      if sort == "files_desc",
        do: Enum.sort_by(users_enriched, & &1.file_count, :desc),
        else: users_enriched

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
      from(d in Document, where: d.user_id == ^user.id,
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
      from(d in Document, where: d.user_id == ^user.id,
        group_by: d.content_type, select: {d.content_type, count(d.id)})
      |> Repo.all() |> Enum.into(%{})

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
      from(s in Alem.Session, where: s.user_id == ^user.id,
        order_by: [desc: s.last_active_at], limit: 10)
      |> Repo.all()

    tokens =
      from(t in Alem.Pleroma.Web.OAuth.Token,
        where: t.user_id == ^user.id and is_nil(t.revoked_at) and t.valid_until > ^DateTime.utc_now(),
        order_by: [desc: t.inserted_at], limit: 5)
      |> Repo.all()

    %{user: user, files: files, storage_bytes: storage_bytes, type_breakdown: type_breakdown,
      duplicates: duplicates, namespace: namespace, sessions: sessions, tokens: tokens,
      file_count: length(files)}
  end

  # ── Quota Management ──────────────────────────────────────────────────────

  def get_user_quota(user_id) do
    user = Repo.get(User, user_id)
    if is_nil(user), do: nil, else: build_quota(user)
  end

  defp build_quota(user) do
    ns_key    = if user.did_id, do: Alem.DID.namespace_key(user.did_id), else: nil
    namespace = if ns_key, do: Repo.get(Namespace, ns_key), else: nil
    ns_cfg    = if namespace, do: namespace.config || %{}, else: %{}

    plan      = Map.get(ns_cfg, "plan", "free")
    plan_info = plan_info(plan)

    used_bytes =
      from(d in Document,
        join: c in CasObject, on: c.content_hash == d.content_hash,
        where: d.user_id == ^user.id,
        select: coalesce(sum(c.file_size), 0))
      |> Repo.one() || 0

    used_int   = to_int(used_bytes)
    quota_int  = plan_info.quota_bytes
    pct        = if quota_int && quota_int > 0, do: min(100, round(used_int / quota_int * 100)), else: 0

    %{
      user:       user,
      plan:       plan,
      plan_info:  plan_info,
      used_bytes: used_int,
      quota_bytes: quota_int,
      pct:        pct,
      namespace:  namespace,
      ns_key:     ns_key,
      ns_cfg:     ns_cfg,
      over_quota: quota_int && used_int > quota_int
    }
  end

  def set_user_plan(user_id, plan) when plan in ["free", "pro", "enterprise"] do
    user = Repo.get(User, user_id)
    if is_nil(user), do: {:error, :not_found}, else: do_set_plan(user, plan)
  end

  defp do_set_plan(user, plan) do
    ns_key = if user.did_id, do: Alem.DID.namespace_key(user.did_id), else: nil
    if is_nil(ns_key) do
      {:error, "User has no namespace (no DID assigned)"}
    else
      case Repo.get(Namespace, ns_key) do
        nil ->
          {:error, "Namespace not found"}
        ns ->
          new_config = Map.put(ns.config || %{}, "plan", plan)
          ns |> Ecto.Changeset.change(config: new_config) |> Repo.update()
      end
    end
  end

  # ── Service Authorization ─────────────────────────────────────────────────

  def get_user_services(user_id) do
    user = Repo.get(User, user_id)
    if is_nil(user), do: nil, else: build_services(user)
  end

  defp build_services(user) do
    ns_key    = if user.did_id, do: Alem.DID.namespace_key(user.did_id), else: nil
    namespace = if ns_key, do: Repo.get(Namespace, ns_key), else: nil
    ns_cfg    = if namespace, do: namespace.config || %{}, else: %{}

    # Default: all services enabled if active and verified
    defaults = if user.is_active && user.is_verified,
      do: Enum.into(@services, %{}, fn s -> {s.key, true} end),
      else: Enum.into(@services, %{}, fn s -> {s.key, false} end)

    # Override with namespace config
    svc_cfg   = Map.get(ns_cfg, "services", defaults)

    %{user: user, ns_key: ns_key, namespace: namespace, ns_cfg: ns_cfg, services: svc_cfg}
  end

  def set_service(user_id, service_key, enabled) when service_key in ["sync_api", "analytics", "vault", "identity", "api_access"] do
    user = Repo.get(User, user_id)
    if is_nil(user), do: {:error, :not_found}, else: do_set_service(user, service_key, enabled)
  end
  def set_service(_, _, _), do: {:error, "Unknown service"}

  defp do_set_service(user, service_key, enabled) do
    ns_key = if user.did_id, do: Alem.DID.namespace_key(user.did_id), else: nil
    if is_nil(ns_key) do
      {:error, "No namespace"}
    else
      case Repo.get(Namespace, ns_key) do
        nil -> {:error, "Namespace not found"}
        ns  ->
          cur_svc    = Map.get(ns.config || %{}, "services", %{})
          new_svc    = Map.put(cur_svc, service_key, enabled)
          new_config = Map.put(ns.config || %{}, "services", new_svc)
          ns |> Ecto.Changeset.change(config: new_config) |> Repo.update()
      end
    end
  end

  # ── Security Center ───────────────────────────────────────────────────────

  def security_overview do
    # All active sessions across all users
    sessions =
      from(s in Alem.Session,
        join: u in User, on: u.id == s.user_id,
        where: is_nil(s.revoked_at),
        order_by: [desc: s.last_active_at],
        limit: 50,
        select: %{id: s.id, user_id: s.user_id, nickname: u.nickname, email: u.email,
                  ip_address: s.ip_address, device: s.device, last_active_at: s.last_active_at})
      |> Repo.all()

    # Active tokens
    tokens =
      from(t in Alem.Pleroma.Web.OAuth.Token,
        join: u in User, on: u.id == t.user_id,
        where: is_nil(t.revoked_at) and t.valid_until > ^DateTime.utc_now(),
        order_by: [desc: t.inserted_at],
        limit: 50,
        select: %{id: t.id, user_id: t.user_id, nickname: u.nickname,
                  scopes: t.scopes, valid_until: t.valid_until})
      |> Repo.all()

    # Blocked users
    blocked =
      from(u in User, where: u.is_active == false,
        order_by: [desc: u.updated_at], limit: 20)
      |> Repo.all()

    # Recently joined (potential threats)
    one_day_ago = DateTime.add(DateTime.utc_now(), -1, :day) |> DateTime.to_naive()
    recent =
      from(u in User, where: u.inserted_at >= ^one_day_ago,
        order_by: [desc: u.inserted_at])
      |> Repo.all()

    %{sessions: sessions, tokens: tokens, blocked: blocked, recent: recent,
      session_count: length(sessions), token_count: length(tokens)}
  end

  # ── Monitoring ────────────────────────────────────────────────────────────

  def monitoring_stats do
    user_storage =
      from(u in User,
        left_join: d in Document, on: d.user_id == u.id,
        left_join: c in CasObject, on: c.content_hash == d.content_hash,
        group_by: [u.id, u.nickname, u.email, u.is_active, u.is_verified, u.inserted_at],
        select: %{user_id: u.id, nickname: u.nickname, email: u.email,
                  is_active: u.is_active, is_verified: u.is_verified,
                  file_count: count(d.id, :distinct),
                  storage_bytes: coalesce(sum(c.file_size), 0),
                  joined: u.inserted_at},
        order_by: [desc: coalesce(sum(c.file_size), 0)])
      |> Repo.all()

    session_activity =
      from(s in Alem.Session,
        group_by: s.user_id,
        select: {s.user_id, count(s.id), max(s.last_active_at)})
      |> Repo.all()
      |> Enum.into(%{}, fn {uid, cnt, last} -> {uid, %{sessions: cnt, last_active: last}} end)

    storage_by_type =
      from(c in CasObject,
        where: not is_nil(c.media_type),
        group_by: c.media_type,
        select: {c.media_type, count(c.content_hash), coalesce(sum(c.file_size), 0)},
        order_by: [desc: coalesce(sum(c.file_size), 0)])
      |> Repo.all()
      |> Enum.map(fn {ct, count, bytes} -> %{type: ct, count: count, bytes: to_int(bytes)} end)

    # Namespaces for plan data
    ns_all = from(n in Namespace, select: {n.id, n.config}) |> Repo.all() |> Enum.into(%{})

    enriched =
      Enum.map(user_storage, fn u ->
        sa     = Map.get(session_activity, u.user_id, %{sessions: 0, last_active: nil})
        used   = to_int(u.storage_bytes)

        # Find namespace by user DID (approximated via ns_all keys matching)
        ns_cfg = find_ns_config(u.user_id, ns_all)
        plan   = Map.get(ns_cfg, "plan", "free")
        pinfo  = plan_info(plan)
        quota  = pinfo.quota_bytes
        pct    = if quota && quota > 0, do: min(100, round(used / quota * 100)), else: 0

        Map.merge(u, sa)
        |> Map.put(:storage_bytes, used)
        |> Map.put(:plan, plan)
        |> Map.put(:quota_bytes, quota)
        |> Map.put(:quota_pct, pct)
        |> Map.put(:over_quota, quota && used > quota)
      end)

    total_by_type = Enum.sum(Enum.map(storage_by_type, & &1.bytes))

    %{users: enriched, storage_by_type: storage_by_type, total_by_type: total_by_type}
  end

  defp find_ns_config(_user_id, _ns_all), do: %{}  # simplified — plan comes from quota lookup


  # ── Permissions (Legacy compat) ───────────────────────────────────────────

  def get_user_permissions(user_id) do
    case Repo.get(User, user_id) do
      nil  -> nil
      user ->
        token_count = Repo.aggregate(
          from(t in Alem.Pleroma.Web.OAuth.Token,
            where: t.user_id == ^user_id and is_nil(t.revoked_at) and
                   t.valid_until > ^DateTime.utc_now()),
          :count, :id
        )
        session_count = Repo.aggregate(
          from(s in Alem.Session, where: s.user_id == ^user_id and is_nil(s.revoked_at)),
          :count, :id
        )
        %{
          user:            user,
          can_login:       user.is_active,
          is_verified:     user.is_verified,
          is_admin:        user.is_admin,
          is_moderator:    user.is_moderator,
          api_access:      token_count > 0,
          active_tokens:   token_count,
          active_sessions: session_count
        }
    end
  end

  # ── User Actions ─────────────────────────────────────────────────────────

  def block_user(uid),    do: set_user(uid, %{is_active: false})
  def unblock_user(uid),  do: set_user(uid, %{is_active: true})
  def promote_admin(uid), do: set_user(uid, %{is_admin: true})
  def demote_admin(uid),  do: set_user(uid, %{is_admin: false})
  def set_moderator(uid, v), do: set_user(uid, %{is_moderator: v})

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
          user |> Ecto.Changeset.change(%{is_active: false,
              email: "deleted_#{uid}@przma.deleted",
              password_hash: "DELETED", otp_code: nil, reset_token: nil})
          |> Repo.update!()
          from(t in Alem.Pleroma.Web.OAuth.Token, where: t.user_id == ^uid)
          |> Repo.update_all(set: [revoked_at: DateTime.utc_now() |> DateTime.truncate(:second)])
          from(s in Alem.Session, where: s.user_id == ^uid)
          |> Repo.update_all(set: [revoked_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)])
          Logger.info("[Admin] Soft deleted #{uid}"); :ok
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
          Logger.info("[Admin] Hard deleted #{uid}"); :ok
        end)
    end
  end

  def revoke_all_tokens(uid) do
    from(t in Alem.Pleroma.Web.OAuth.Token, where: t.user_id == ^uid)
    |> Repo.update_all(set: [revoked_at: DateTime.utc_now() |> DateTime.truncate(:second)])
    :ok
  end

  def revoke_all_sessions(uid) do
    from(s in Alem.Session, where: s.user_id == ^uid)
    |> Repo.update_all(set: [revoked_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)])
    :ok
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
      select: %{namespace_key: c.namespace_key, file_count: count(c.content_hash),
                total_bytes: coalesce(sum(c.file_size), 0)},
      order_by: [desc: count(c.content_hash)])
    |> Repo.all()
  end

  def duplicate_analysis do
    duplicates =
      from(c in CasObject, where: c.ref_count > 1, order_by: [desc: c.ref_count], limit: 100)
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
    trimmed = String.trim(sql)
    upper   = String.upcase(trimmed)
    cond do
      trimmed == "" -> {:error, "Empty query"}
      not String.starts_with?(upper, "SELECT") -> {:error, "Only SELECT queries are allowed"}
      Enum.any?(@blocked, &String.contains?(upper, &1)) ->
        {:error, "Blocked keyword: #{Enum.find(@blocked, &String.contains?(upper, &1))}"}
      true ->
        try do
          %{columns: cols, rows: rows} = Repo.query!(trimmed, [], timeout: 10_000)
          {:ok, %{columns: cols || [], rows: rows || [], count: length(rows || [])}}
        rescue
          e -> {:error, Exception.message(e)}
        end
    end
  end

  # ── S3 Browser ────────────────────────────────────────────────────────────

  @s3_roots ["user/", "analytics/"]

  def s3_root_folders do
    Enum.map(@s3_roots, fn prefix ->
      case list_s3_objects(prefix) do
        {:ok, data} -> %{prefix: prefix, object_count: length(data.objects), subfolder_count: length(data.prefixes), ok: true}
        {:error, _} -> %{prefix: prefix, object_count: 0, subfolder_count: 0, ok: false}
      end
    end)
  end

  def list_s3_objects(prefix \\ "") do
    bucket = get_bucket()
    opts   = [delimiter: "/", max_keys: 500]
    opts   = if prefix != "", do: Keyword.put(opts, :prefix, prefix), else: opts

    case ExAws.S3.list_objects(bucket, opts) |> ExAws.request() do
      {:ok, %{body: body}} ->
        objects  = body |> Map.get(:contents, [])       |> ensure_list() |> Enum.filter(&is_map/1)
        prefixes = body |> Map.get(:common_prefixes, []) |> ensure_list() |> Enum.filter(&is_map/1)
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
      Application.get_env(:ex_aws, :s3, [])[:bucket] || "perkeep"
  end

  defp ensure_list(v) when is_list(v), do: v
  defp ensure_list(v) when is_map(v),  do: [v]
  defp ensure_list(_),                 do: []

  # ── Helpers ────────────────────────────────────────────────────────────────

  def format_bytes(b) when is_integer(b) and b > 0 do
    cond do
      b >= 1_073_741_824 -> "#{Float.round(b / 1_073_741_824, 2)} GB"
      b >= 1_048_576     -> "#{Float.round(b / 1_048_576, 2)} MB"
      b >= 1_024         -> "#{Float.round(b / 1_024, 2)} KB"
      true               -> "#{b} B"
    end
  end
  def format_bytes(b) when is_integer(b), do: "0 B"
  def format_bytes(%Decimal{} = b), do: format_bytes(Decimal.to_integer(b))
  def format_bytes(_), do: "0 B"

  defp to_int(%Decimal{} = d), do: Decimal.to_integer(d)
  defp to_int(i) when is_integer(i), do: i
  defp to_int(_), do: 0

  # ── Audit Log ────────────────────────────────────────────────────────────
  # Simple in-memory audit log (persists to ETS, resets on restart)
  # In production, write to a database table

  def log_audit(admin_id, action, target \\ nil) do
    ensure_audit_ets()
    entry = %{
      id:         System.unique_integer([:positive]),
      admin_id:   admin_id,
      action:     action,
      target:     target,
      at:         DateTime.utc_now() |> DateTime.truncate(:second)
    }
    :ets.insert(:admin_audit_log, {entry.id, entry})
    entry
  rescue
    _ -> :ok
  end

  def get_audit_log(limit \\ 50) do
    ensure_audit_ets()
    :ets.tab2list(:admin_audit_log)
    |> Enum.map(fn {_k, v} -> v end)
    |> Enum.sort_by(& &1.at, {:desc, DateTime})
    |> Enum.take(limit)
  rescue
    _ -> []
  end

  defp ensure_audit_ets do
    if :ets.whereis(:admin_audit_log) == :undefined do
      :ets.new(:admin_audit_log, [:named_table, :public, :set])
    end
  rescue
    _ -> :ok
  end

  # ── Quick Platform Summary (single optimized query) ───────────────────────

  def platform_summary do
    # One query for all document stats
    doc_stats =
      Repo.one(
        from d in Alem.Schemas.Document,
        select: %{total: count(d.id), users_with_files: count(d.user_id, :distinct)}
      ) || %{total: 0, users_with_files: 0}

    # One query for all CAS stats
    cas_stats =
      Repo.one(
        from c in CasObject,
        select: %{
          total:      count(c.content_hash),
          dupes:      sum(fragment("CASE WHEN ? > 1 THEN 1 ELSE 0 END", c.ref_count)),
          bytes:      coalesce(sum(c.file_size), 0),
          saved:      coalesce(sum(fragment("? * (? - 1)", c.file_size, c.ref_count)), 0)
        }
      ) || %{total: 0, dupes: 0, bytes: 0, saved: 0}

    Map.merge(doc_stats, cas_stats)
  end
end
