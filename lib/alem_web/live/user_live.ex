defmodule AlemWeb.UserLive do
  use AlemWeb, :live_view
  import Ecto.Query
  alias Alem.Schemas.Document
  alias Alem.Repo
  require Logger

  @impl true
  def mount(_params, session, socket) do
    user = case session["user_id"] do
      nil -> nil
      uid -> try do Repo.get(Alem.Pleroma.User, uid) rescue _ -> nil end
    end

    if is_nil(user) do
      {:ok, redirect(socket, to: "/panel/login")}
    else
      {:ok,
       socket
       |> assign(:page_title,     "Dashboard")
       |> assign(:user,           user)
       |> assign(:page,           :home)
       |> assign(:stats,          load_stats(user.id))
       |> assign(:files,          load_files(user.id))
       |> assign(:files_filter,   "all")
       |> assign(:files_search,   "")
       |> assign(:files_sort,     "newest")
       |> assign(:sessions,       load_sessions(user.id))
       |> assign(:upload_results, [])
       |> assign(:viewer,         nil)
       |> assign(:viewer_loading, false)
       |> assign(:sidebar_open,   false)
       |> assign(:flash_msg,      nil)
       |> assign(:flash_type,     :success)
       |> assign(:active_folder,  "personal")
       |> assign(:random_vault,    nil)
       |> assign(:folder_stats,   load_folder_stats(user.id))
       |> allow_upload(:file,
           accept: ~w(.mp3 .wav .mp4 .mov .jpg .jpeg .png .gif .pdf .txt .docx),
           max_entries: 5,
           max_file_size: 50_000_000,
           auto_upload: false)}
    end
  end

  # ── Data ───────────────────────────────────────────────────────────────────

  defp load_stats(uid) do
    try do
      total = Repo.aggregate(from(d in Document, where: d.user_id == ^uid), :count, :id)
      by_type = Repo.all(from d in Document, where: d.user_id == ^uid,
        group_by: d.content_type, select: {d.content_type, count(d.id)}) |> Enum.into(%{})
      by_month = Repo.all(from d in Document, where: d.user_id == ^uid,
        group_by: fragment("DATE_TRUNC('month', ?)", d.inserted_at),
        order_by: [asc: fragment("DATE_TRUNC('month', ?)", d.inserted_at)],
        select: {fragment("DATE_TRUNC('month', ?)", d.inserted_at), count(d.id)}, limit: 6)
      %{total: total, audio: ct(by_type,"audio/"), video: ct(by_type,"video/"),
        image: ct(by_type,"image/"), document: cdoc(by_type), by_month: by_month}
    rescue _ ->
      %{total: 0, audio: 0, video: 0, image: 0, document: 0, by_month: []}
    end
  end

  defp load_files(uid) do
    # Default: load personal folder on initial mount
    load_files_by_folder(uid, "personal")
  end

  defp load_files_by_folder(uid, folder) do
    case Alem.Home.list_files(uid, folder) do
      {:ok, files} -> files
      _            -> []
    end
  end

  defp load_folder_stats(uid) do
    try do
      Repo.all(
        from d in Document,
        where: d.user_id == ^uid,
        group_by: d.folder,
        select: {d.folder, count(d.id)}
      ) |> Map.new()
    rescue _ -> %{"personal" => 0, "private" => 0, "public" => 0}
    end
  end

  defp load_sessions(uid) do
    try do
      Repo.all(from s in Alem.Session,
        where: s.user_id == ^uid and is_nil(s.revoked_at),
        order_by: [desc: s.last_active_at], limit: 10,
        select: %{id: s.id, device: s.device,
                  last_active_at: s.last_active_at, inserted_at: s.inserted_at})
    rescue _ -> [] end
  end

  defp ct(m, p), do: m |> Enum.filter(fn {k,_} -> String.starts_with?(k||"",p) end)
                       |> Enum.reduce(0, fn {_,v},a -> a+v end)
  defp cdoc(m),  do: m |> Enum.filter(fn {k,_} ->
                       k=k||""; Enum.any?(["pdf","document","text","word"], &String.contains?(k,&1))
                     end) |> Enum.reduce(0, fn {_,v},a -> a+v end)

  # ── Events ─────────────────────────────────────────────────────────────────


  def handle_event("save_provider", params, socket) do
    user = socket.assigns.user
    case Alem.Api.ProviderApi.create_provider(user, params) do
      {:ok, _} ->
        {:noreply, socket
          |> assign(:providers, Alem.Api.ProviderApi.list_providers(user))
          |> assign(:flash_msg, "✅ Provider saved")
          |> assign(:flash_type, :success)}
      {:error, cs} ->
        {:noreply, assign(socket, :flash_msg, "❌ Save failed: #{inspect(cs.errors)}")}
    end
  end

  def handle_event("delete_provider", %{"id" => id}, socket) do
    user = socket.assigns.user
    Alem.Api.ProviderApi.delete_provider(user, id)
    {:noreply, socket
      |> assign(:providers, Alem.Api.ProviderApi.list_providers(user))
      |> assign(:flash_msg, "Provider removed")}
  end

  def handle_event("set_active_provider", %{"id" => id}, socket) do
    user = socket.assigns.user
    Alem.Api.ProviderApi.set_active(user, id)
    {:noreply, socket
      |> assign(:providers, Alem.Api.ProviderApi.list_providers(user))
      |> assign(:flash_msg, "✅ Provider activated")}
  end

  def handle_event("use_managed", _, socket) do
    user = socket.assigns.user
    Alem.Api.ProviderApi.set_managed(user)
    {:noreply, socket
      |> assign(:providers, Alem.Api.ProviderApi.list_providers(user))
      |> assign(:flash_msg, "✅ Using PRZMA managed storage")}
  end

  def handle_event("test_provider", %{"id" => id}, socket) do
    user = socket.assigns.user
    case Alem.Api.ProviderApi.test_connection(user, id) do
      {:ok, :connected} ->
        {:noreply, socket
          |> assign(:providers, Alem.Api.ProviderApi.list_providers(user))
          |> assign(:flash_msg, "✅ Connection verified!")}
      {:error, {:connection_failed, r}} ->
        {:noreply, assign(socket, :flash_msg, "❌ Failed: #{r}")}
    end
  end

  @impl true
  def handle_event("nav", %{"page" => page}, socket) do
    {:noreply, socket |> assign(:page, String.to_existing_atom(page)) |> assign(:sidebar_open, false)}
  rescue _ -> {:noreply, socket} end

  def handle_event("toggle_sidebar", _, socket) do
    {:noreply, assign(socket, :sidebar_open, !socket.assigns.sidebar_open)}
  end

  def handle_event("close_sidebar", _, socket) do
    {:noreply, assign(socket, :sidebar_open, false)}
  end

  def handle_event("filter", %{"filter" => f}, socket) do
    {:noreply, assign(socket, :files_filter, f)}
  end

  def handle_event("sort", %{"sort" => s}, socket) do
    {:noreply, assign(socket, :files_sort, s)}
  end

  def handle_event("search", params, socket) do
    q = Map.get(params, "value", Map.get(params, "q", ""))
    {:noreply, assign(socket, :files_search, q)}
  end

  def handle_event("validate_upload", _params, socket), do: {:noreply, socket}

  def handle_event("do_upload", params, socket) do
    user   = socket.assigns.user
    folder = Map.get(params, "folder", socket.assigns[:active_folder] || "personal")

    results = consume_uploaded_entries(socket, :file, fn %{path: path}, entry ->
      bytes = File.read!(path)
      file_params = %{
        path:         path,
        filename:     entry.client_name,
        content_type: detect_type(entry.client_name, bytes, entry.client_type),
        size:         entry.client_size
      }
      case Alem.Api.UploadApi.upload(user, folder, file_params) do
        {:ok, %{doc: doc}} ->
          {:ok, %{filename: entry.client_name, size: entry.client_size,
                  folder: folder, doc_id: doc.id, s3: true, pg: true, lance: true}}
        {:error, reason} ->
          {:ok, %{filename: entry.client_name, error: inspect(reason)}}
      end
    end)

    {:noreply,
     socket
     |> assign(:files,          load_files_by_folder(user.id, folder))
     |> assign(:stats,          load_stats(user.id))
     |> assign(:folder_stats,   load_folder_stats(user.id))
     |> assign(:upload_results, results)}
  end

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :file, ref)}
  end

  def handle_event("clear_results", _, socket) do
    {:noreply, assign(socket, :upload_results, [])}
  end

  def handle_event("revoke_session", %{"id" => id}, socket) do
    try do
      Repo.get(Alem.Session, id)
      |> Ecto.Changeset.change(%{revoked_at: DateTime.utc_now()})
      |> Repo.update()
    rescue _ -> :ok end
    {:noreply,
     socket
     |> assign(:sessions, load_sessions(socket.assigns.user.id))
     |> assign(:flash_msg, "Session revoked")
     |> assign(:flash_type, :success)}
  end

  def handle_event("logout", _, socket), do: {:noreply, redirect(socket, to: "/panel/logout")}
  def handle_event("dismiss_flash", _, socket), do: {:noreply, assign(socket, :flash_msg, nil)}

  def handle_event("random_upload", _params, socket) do
    vault_num  = :rand.uniform(3) - 1
    vault_name = %{0 => "personal", 1 => "private", 2 => "public"}[vault_num]
    user = socket.assigns.user
    {:noreply, socket
      |> assign(:active_folder, vault_name)
      |> assign(:random_vault, vault_num)
      |> assign(:files, load_files_by_folder(user.id, vault_name))}
  end

  def handle_event("set_folder", %{"folder" => f}, socket)
      when f in ~w(personal private public) do
    user = socket.assigns.user
    {:noreply,
     socket
     |> assign(:active_folder, f)
     |> assign(:files, load_files_by_folder(user.id, f))}
  end
  def handle_event("set_folder", _, socket), do: {:noreply, socket}

  def handle_event("open_viewer", %{"id" => doc_id}, socket) do
    import Ecto.Query
    user_id = socket.assigns.user.id
    doc = try do
      Alem.Repo.one(
        from d in Alem.Schemas.Document,
        where: d.id == ^doc_id and d.user_id == ^user_id,
        select: %{id: d.id, filename: d.filename, content_type: d.content_type,
                  object_key: d.object_key, status: d.status, inserted_at: d.inserted_at}
      )
    rescue _ -> nil end

    if doc do
      url = try do
        bucket = System.get_env("AWS_S3_BUCKET", "perkeep")
        host   = System.get_env("AWS_S3_ENDPOINT", "in-maa-1.linodeobjects.com")
                 |> String.replace(~r/^https?:\/\//, "") |> String.trim_trailing("/")
        region = System.get_env("AWS_DEFAULT_REGION", "in-maa-1")
        config = ExAws.Config.new(:s3, scheme: "https://", host: host, region: region, port: 443)
        case ExAws.S3.presigned_url(config, :get, bucket, doc.object_key, expires_in: 3600) do
          {:ok, u} -> String.replace(u, ~r/^http:\/\//, "https://")
          _ -> nil
        end
      rescue _ -> nil end
      {:noreply, assign(socket, viewer: Map.put(doc, :url, url), viewer_loading: false)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("close_viewer", _, socket) do
    {:noreply, assign(socket, viewer: nil, viewer_loading: false)}
  end

  defp detect_type(n, b, t) when t in [nil, "", "application/octet-stream"] do
    magic = case b do
      <<0x89,0x50,0x4E,0x47,_::binary>> -> "image/png"
      <<0xFF,0xD8,0xFF,_::binary>>       -> "image/jpeg"
      <<0x25,0x50,0x44,0x46,_::binary>>  -> "application/pdf"
      <<0x49,0x44,0x33,_::binary>>       -> "audio/mpeg"
      _ -> nil
    end
    magic || ext_type(Path.extname(String.downcase(n))) || "application/octet-stream"
  end
  defp detect_type(_, _, t), do: t

  defp ext_type(".mp3"), do: "audio/mpeg";   defp ext_type(".wav"), do: "audio/wav"
  defp ext_type(".mp4"), do: "video/mp4";    defp ext_type(".mov"), do: "video/quicktime"
  defp ext_type(".jpg"), do: "image/jpeg";   defp ext_type(".jpeg"), do: "image/jpeg"
  defp ext_type(".png"), do: "image/png";    defp ext_type(".gif"), do: "image/gif"
  defp ext_type(".pdf"), do: "application/pdf"
  defp ext_type(".txt"), do: "text/plain"
  defp ext_type(".docx"), do: "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
  defp ext_type(_), do: nil



  # ── Render ─────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    files    = assigns.files
    search   = assigns.files_search
    filter   = assigns.files_filter
    sort_key = assigns.files_sort || "newest"

    filtered = files
      |> Enum.filter(fn f ->
        ms = search == "" or String.contains?(String.downcase(f.filename || ""), String.downcase(search))
        mt = case filter do
          "audio"    -> String.starts_with?(f.content_type || "", "audio/")
          "image"    -> String.starts_with?(f.content_type || "", "image/")
          "video"    -> String.starts_with?(f.content_type || "", "video/")
          "document" -> Enum.any?(["pdf","document","text","word"],
                          &String.contains?(f.content_type || "", &1))
          _ -> true
        end
        ms and mt
      end)
      |> do_sort(sort_key)

    month_labels = assigns.stats.by_month |> Enum.map(fn {dt,_} ->
      case dt do
        %NaiveDateTime{} -> Calendar.strftime(dt, "%b")
        %DateTime{}      -> Calendar.strftime(dt, "%b")
        _                -> "?"
      end
    end)
    month_values = assigns.stats.by_month |> Enum.map(fn {_,c} -> c end)

    assigns = assigns
      |> assign(:filtered,      filtered)
      |> assign(:month_labels,  Jason.encode!(month_labels))
      |> assign(:month_values,  Jason.encode!(month_values))
      |> assign(:folder_stats,  assigns[:folder_stats] || %{})
      |> assign(:active_folder,  assigns[:active_folder] || "personal")
      |> assign(:random_vault,     assigns[:random_vault])
      |> assign(:providers,        Alem.Api.ProviderApi.list_providers(assigns.user))
      |> assign(:type_values,   Jason.encode!([
           assigns.stats.audio, assigns.stats.video,
           assigns.stats.image, assigns.stats.document
         ]))

    ~H"""
    <style>
      /* ══════════════════════════════════════════════
         DESIGN TOKENS
      ══════════════════════════════════════════════ */
      :root, [data-theme="dark"] {
        --bg:           #0c0e13;
        --bg-2:         #13161e;
        --bg-3:         #1a1e29;
        --bg-4:         #222737;
        --border:       rgba(255,255,255,0.07);
        --border-2:     rgba(255,255,255,0.13);
        --text:         #f0f2f8;
        --text-2:       #8b92a9;
        --text-3:       #4e566b;
        --primary:      #5c73f2;
        --primary-d:    rgba(92,115,242,0.15);
        --primary-glow: rgba(92,115,242,0.3);
        --green:        #10b981; --green-d: rgba(16,185,129,0.12);
        --amber:        #f59e0b; --amber-d: rgba(245,158,11,0.12);
        --red:          #ef4444; --red-d:   rgba(239,68,68,0.12);
        --purple:       #a78bfa; --purple-d:rgba(167,139,250,0.12);
        --shadow:       0 1px 3px rgba(0,0,0,0.5),0 4px 16px rgba(0,0,0,0.25);
        --shadow-lg:    0 8px 32px rgba(0,0,0,0.45);
        --r:  10px; --r-sm: 6px; --r-lg: 14px;
        --sb-w:   220px;
        --sb-icon: 56px;
        color-scheme: dark;
      }
      [data-theme="light"] {
        --bg:           #f2f4f8;
        --bg-2:         #ffffff;
        --bg-3:         #f8f9fc;
        --bg-4:         #eef0f6;
        --border:       rgba(0,0,0,0.07);
        --border-2:     rgba(0,0,0,0.13);
        --text:         #0f1117;
        --text-2:       #5a6172;
        --text-3:       #9ca3b4;
        --primary:      #4f63e8;
        --primary-d:    rgba(79,99,232,0.1);
        --primary-glow: rgba(79,99,232,0.25);
        --green:        #059669; --green-d: rgba(5,150,105,0.1);
        --amber:        #d97706; --amber-d: rgba(217,119,6,0.1);
        --red:          #dc2626; --red-d:   rgba(220,38,38,0.1);
        --purple:       #7c3aed; --purple-d:rgba(124,58,237,0.1);
        --shadow:       0 1px 3px rgba(0,0,0,0.08),0 4px 16px rgba(0,0,0,0.06);
        --shadow-lg:    0 8px 32px rgba(0,0,0,0.12);
        color-scheme: light;
      }

      /* ══════════════════════════════════════════════
         RESET + BASE
      ══════════════════════════════════════════════ */
      *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
      html { font-size: 14px; -webkit-font-smoothing: antialiased; }
      body {
        font-family: 'DM Sans', system-ui, sans-serif;
        background: var(--bg);
        color: var(--text);
        transition: background 0.25s, color 0.25s;
        overflow: hidden;
      }
      ::-webkit-scrollbar { width: 4px; height: 4px; }
      ::-webkit-scrollbar-thumb { background: var(--bg-4); border-radius: 99px; }
      ::selection { background: var(--primary); color: #fff; }

      /* ══════════════════════════════════════════════
         SHELL
      ══════════════════════════════════════════════ */
      .shell { display: flex; height: 100vh; position: relative; overflow: hidden; }

      /* ══════════════════════════════════════════════
         SIDEBAR
      ══════════════════════════════════════════════ */
      .sidebar {
        width: var(--sb-w);
        min-width: var(--sb-w);
        background: var(--bg-2);
        border-right: 1px solid var(--border);
        display: flex;
        flex-direction: column;
        flex-shrink: 0;
        transition: width 0.25s cubic-bezier(0.4,0,0.2,1),
                    min-width 0.25s cubic-bezier(0.4,0,0.2,1),
                    transform 0.3s cubic-bezier(0.4,0,0.2,1);
        overflow: hidden;
        z-index: 100;
      }

      /* Collapsed (icon-only) on tablet */
      .sidebar.collapsed {
        width: var(--sb-icon);
        min-width: var(--sb-icon);
      }

      /* Mobile: slide-in drawer */
      @media (max-width: 767px) {
        .sidebar {
          position: fixed;
          top: 0; left: 0; bottom: 0;
          width: var(--sb-w) !important;
          min-width: var(--sb-w) !important;
          transform: translateX(-100%);
          box-shadow: var(--shadow-lg);
        }
        .sidebar.open {
          transform: translateX(0);
        }
      }

      /* ── Sidebar Header ── */
      .sb-logo {
        padding: 16px 14px 12px;
        border-bottom: 1px solid var(--border);
        display: flex; align-items: center; gap: 10px;
        min-height: 56px; overflow: hidden;
        flex-shrink: 0;
      }
      .sb-logo-mark {
        width: 28px; height: 28px; flex-shrink: 0;
        background: linear-gradient(135deg, var(--primary), var(--purple));
        border-radius: 7px; display: flex; align-items: center; justify-content: center;
        font-size: 13px; color: #fff; font-weight: 700;
        box-shadow: 0 2px 8px var(--primary-glow);
      }
      .sb-logo-text { font-size: 13px; font-weight: 700; color: var(--text); white-space: nowrap; }
      .sb-logo-badge {
        margin-left: auto; font-size: 9px; font-weight: 600;
        background: var(--primary-d); color: var(--primary);
        padding: 2px 6px; border-radius: 99px; white-space: nowrap; flex-shrink: 0;
      }

      /* Hide text labels when collapsed */
      .sidebar.collapsed .sb-logo-text,
      .sidebar.collapsed .sb-logo-badge,
      .sidebar.collapsed .sb-user-info,
      .sidebar.collapsed .nav-label,
      .sidebar.collapsed .nav-badge,
      .sidebar.collapsed .nav-section-label {
        display: none;
      }

      /* ── Sidebar User ── */
      .sb-user {
        padding: 10px 14px; border-bottom: 1px solid var(--border);
        display: flex; align-items: center; gap: 10px; overflow: hidden;
        flex-shrink: 0;
      }
      .sb-avatar {
        width: 28px; height: 28px; flex-shrink: 0; border-radius: 50%;
        background: linear-gradient(135deg, var(--primary), var(--purple));
        display: flex; align-items: center; justify-content: center;
        font-size: 11px; font-weight: 700; color: #fff;
      }
      .sb-user-info { overflow: hidden; }
      .sb-user-name { font-size: 12px; font-weight: 600; color: var(--text); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
      .sb-user-email { font-size: 10px; color: var(--text-3); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }

      /* ── Navigation ── */
      .sb-nav { flex: 1; padding: 6px; overflow-y: auto; overflow-x: hidden; }
      .nav-section { padding: 10px 8px 3px; overflow: hidden; }
      .nav-section-label {
        font-size: 9px; font-weight: 700; color: var(--text-3);
        text-transform: uppercase; letter-spacing: 1.2px; white-space: nowrap;
      }
      .nav-item {
        display: flex; align-items: center; gap: 8px;
        padding: 8px 10px; border-radius: var(--r-sm);
        font-size: 13px; color: var(--text-2); cursor: pointer;
        border: none; background: none; width: 100%; text-align: left;
        font-family: inherit; font-weight: 500;
        transition: all 0.15s; white-space: nowrap; overflow: hidden;
        min-height: 36px; position: relative;
      }
      .nav-item:hover  { background: var(--bg-3); color: var(--text); }
      .nav-item.active { background: var(--primary-d); color: var(--primary); }
      .nav-icon { font-size: 14px; width: 16px; text-align: center; flex-shrink: 0; }
      .nav-label { flex: 1; overflow: hidden; text-overflow: ellipsis; }
      .nav-badge {
        background: var(--primary); color: #fff;
        font-size: 9px; padding: 1px 5px; border-radius: 99px; font-weight: 700;
        flex-shrink: 0;
      }

      /* Tooltip for collapsed sidebar */
      .sidebar.collapsed .nav-item { justify-content: center; padding: 8px; }
      .sidebar.collapsed .nav-item:hover::after {
        content: attr(data-label);
        position: absolute; left: calc(var(--sb-icon) + 4px); top: 50%;
        transform: translateY(-50%);
        background: var(--bg-4); color: var(--text);
        padding: 4px 10px; border-radius: var(--r-sm);
        font-size: 12px; font-weight: 500; white-space: nowrap;
        box-shadow: var(--shadow); z-index: 200;
        border: 1px solid var(--border-2);
      }

      /* ── Sidebar Footer ── */
      .sb-footer { padding: 6px; border-top: 1px solid var(--border); flex-shrink: 0; }
      .nav-item-danger { color: var(--red) !important; }
      .nav-item-danger:hover { background: var(--red-d) !important; }

      /* Collapse toggle button (tablet only) */
      .sb-toggle-btn {
        display: none;
        align-items: center; justify-content: center;
        width: 100%; padding: 8px; border-radius: var(--r-sm);
        background: none; border: 1px solid var(--border);
        color: var(--text-2); cursor: pointer; font-size: 14px;
        margin-bottom: 4px; transition: all 0.15s;
      }
      .sb-toggle-btn:hover { background: var(--bg-3); color: var(--text); }
      @media (min-width: 768px) and (max-width: 1023px) {
        .sb-toggle-btn { display: flex; }
      }

      /* ══════════════════════════════════════════════
         BACKDROP (mobile)
      ══════════════════════════════════════════════ */
      .backdrop {
        display: none;
        position: fixed; inset: 0;
        background: rgba(0,0,0,0.5);
        z-index: 90; cursor: pointer;
        backdrop-filter: blur(2px);
        animation: fadeIn 0.2s;
      }
      @keyframes fadeIn { from { opacity: 0; } to { opacity: 1; } }
      @media (max-width: 767px) {
        .backdrop.visible { display: block; }
      }

      /* ══════════════════════════════════════════════
         MAIN AREA
      ══════════════════════════════════════════════ */
      .main { flex: 1; display: flex; flex-direction: column; overflow: hidden; min-width: 0; }

      /* ── Topbar ── */
      .topbar {
        height: 52px; background: var(--bg-2);
        border-bottom: 1px solid var(--border);
        display: flex; align-items: center;
        padding: 0 16px; gap: 10px; flex-shrink: 0;
        transition: background 0.25s;
      }
      .topbar-hamburger {
        width: 36px; height: 36px; border-radius: var(--r-sm);
        background: var(--bg-3); border: 1px solid var(--border);
        display: flex; align-items: center; justify-content: center;
        cursor: pointer; font-size: 16px; color: var(--text-2);
        transition: all 0.15s; flex-shrink: 0;
      }
      .topbar-hamburger:hover { background: var(--bg-4); color: var(--text); }
      /* Hide hamburger on large desktop */
      @media (min-width: 1024px) { .topbar-hamburger { display: none; } }

      .topbar-title { font-size: 15px; font-weight: 600; color: var(--text); white-space: nowrap; }
      .topbar-spacer { flex: 1; }
      .topbar-actions { display: flex; align-items: center; gap: 8px; }

      .theme-btn {
        width: 36px; height: 36px; border-radius: var(--r-sm);
        background: var(--bg-3); border: 1px solid var(--border-2);
        display: flex; align-items: center; justify-content: center;
        cursor: pointer; font-size: 15px; color: var(--text-2);
        transition: all 0.15s; flex-shrink: 0;
      }
      .theme-btn:hover { background: var(--bg-4); color: var(--text); }

      /* ── Content ── */
      .content { flex: 1; overflow-y: auto; padding: 16px; }
      @media (min-width: 768px) { .content { padding: 20px; } }
      @media (min-width: 1280px) { .content { padding: 24px 28px; } }

      /* ══════════════════════════════════════════════
         COMPONENTS
      ══════════════════════════════════════════════ */

      /* ── Card ── */
      .card {
        background: var(--bg-2); border: 1px solid var(--border);
        border-radius: var(--r-lg); overflow: hidden;
        box-shadow: var(--shadow); margin-bottom: 14px;
        transition: border-color 0.2s;
      }
      .card-hdr {
        padding: 12px 16px; border-bottom: 1px solid var(--border);
        display: flex; align-items: center; gap: 10px; flex-wrap: wrap;
      }
      .card-title { font-size: 13px; font-weight: 600; color: var(--text); }
      .card-sub { font-size: 11px; color: var(--text-3); }
      .card-spacer { flex: 1; }
      .card-body { padding: 16px; }

      /* ── Stat Grid ── */
      .stat-grid {
        display: grid;
        grid-template-columns: repeat(2, 1fr);
        gap: 10px; margin-bottom: 14px;
      }
      @media (min-width: 640px)  { .stat-grid { grid-template-columns: repeat(3, 1fr); } }
      @media (min-width: 1024px) { .stat-grid { grid-template-columns: repeat(5, 1fr); } }

      .stat-card {
        background: var(--bg-2); border: 1px solid var(--border);
        border-radius: var(--r-lg); padding: 12px 14px;
        display: flex; align-items: center; gap: 10px;
        box-shadow: var(--shadow); transition: all 0.2s; cursor: default;
      }
      .stat-card:hover { border-color: var(--border-2); transform: translateY(-1px); box-shadow: var(--shadow-lg); }
      .stat-ico {
        width: 34px; height: 34px; border-radius: 9px; flex-shrink: 0;
        display: flex; align-items: center; justify-content: center; font-size: 16px;
      }
      .ico-blue   { background: var(--primary-d); }
      .ico-green  { background: var(--green-d); }
      .ico-purple { background: var(--purple-d); }
      .ico-amber  { background: var(--amber-d); }
      .ico-red    { background: var(--red-d); }
      .stat-lbl { font-size: 10px; color: var(--text-3); font-weight: 600; text-transform: uppercase; letter-spacing: .5px; margin-bottom: 3px; }
      .stat-val { font-size: 20px; font-weight: 700; color: var(--text); line-height: 1; font-variant-numeric: tabular-nums; }

      /* ── Charts ── */
      .charts-row {
        display: grid;
        grid-template-columns: 1fr;
        gap: 12px; margin-bottom: 14px;
      }
      @media (min-width: 768px) { .charts-row { grid-template-columns: 190px 1fr; } }

      /* ── Buttons ── */
      .btn {
        display: inline-flex; align-items: center; justify-content: center; gap: 6px;
        padding: 0 14px; height: 36px; border-radius: var(--r-sm);
        font-size: 12px; font-weight: 600; cursor: pointer;
        border: none; font-family: inherit; transition: all 0.15s;
        white-space: nowrap; min-height: 36px; flex-shrink: 0;
      }
      @media (max-width: 767px) { .btn { min-height: 44px; } }
      .btn-primary { background: var(--primary); color: #fff; }
      .btn-primary:hover { filter: brightness(1.1); box-shadow: 0 0 0 3px var(--primary-glow); }
      .btn-ghost  { background: transparent; color: var(--text-2); border: 1px solid var(--border-2); }
      .btn-ghost:hover { background: var(--bg-3); color: var(--text); }
      .btn-danger { background: transparent; color: var(--red); border: 1px solid rgba(239,68,68,0.25); }
      .btn-danger:hover { background: var(--red-d); }
      .btn-sm { height: 30px; padding: 0 10px; font-size: 11px; min-height: 30px; }
      @media (max-width: 767px) { .btn-sm { min-height: 36px; } }

      /* ── Badges ── */
      .badge {
        display: inline-flex; align-items: center;
        padding: 2px 8px; border-radius: 99px;
        font-size: 10px; font-weight: 600;
      }
      .badge-blue   { background: var(--primary-d); color: var(--primary); }
      .badge-green  { background: var(--green-d);   color: var(--green); }
      .badge-amber  { background: var(--amber-d);   color: var(--amber); }
      .badge-gray   { background: var(--bg-4);      color: var(--text-2); }

      /* ── Filter Tabs ── */
      .filter-row {
        display: flex; align-items: center; gap: 6px;
        flex-wrap: wrap; width: 100%;
      }
      .ftab {
        padding: 4px 11px; border-radius: 99px;
        font-size: 11px; font-weight: 500; cursor: pointer;
        border: 1px solid var(--border); background: transparent;
        color: var(--text-2); font-family: inherit; transition: all 0.15s;
        min-height: 28px;
      }
      .ftab:hover { background: var(--bg-3); color: var(--text); }
      .ftab.on { background: var(--primary); color: #fff; border-color: var(--primary); }

      /* ── Form Controls ── */
      .input {
        background: var(--bg-3); border: 1px solid var(--border);
        border-radius: var(--r-sm); padding: 0 11px; height: 34px;
        font-size: 12px; color: var(--text); font-family: inherit;
        transition: all 0.15s; outline: none;
      }
      .input:focus { border-color: var(--primary); box-shadow: 0 0 0 3px var(--primary-glow); background: var(--bg-2); }
      .input::placeholder { color: var(--text-3); }
      select.input { cursor: pointer; }
      @media (max-width: 767px) { .input { height: 40px; } }

      .controls-row {
        display: flex; align-items: center; gap: 8px;
        flex-wrap: wrap; padding-top: 8px;
      }
      .controls-row .input { flex: 1; min-width: 140px; }

      /* ── Table ── */
      .table-scroll { overflow-x: auto; -webkit-overflow-scrolling: touch; }
      table { width: 100%; border-collapse: collapse; min-width: 420px; }
      thead th {
        padding: 8px 14px; text-align: left;
        font-size: 10px; font-weight: 700; color: var(--text-3);
        text-transform: uppercase; letter-spacing: .6px;
        border-bottom: 1px solid var(--border); background: var(--bg-3);
        white-space: nowrap;
      }
      tbody td {
        padding: 10px 14px; font-size: 12px; color: var(--text);
        border-bottom: 1px solid var(--border); transition: background 0.1s;
      }
      tbody tr:last-child td { border-bottom: none; }
      tbody tr:hover td { background: var(--primary-d); }

      /* ── Upload Zone ── */
      .upload-zone {
        border: 2px dashed var(--border-2); border-radius: var(--r-lg);
        padding: 28px 20px; text-align: center; transition: all 0.2s; cursor: pointer;
      }
      .upload-zone:hover { border-color: var(--primary); background: var(--primary-d); }
      .uz-icon { font-size: 36px; margin-bottom: 10px; opacity: .8; }
      .uz-title { font-size: 15px; font-weight: 600; color: var(--text); margin-bottom: 5px; }
      .uz-sub { font-size: 12px; color: var(--text-2); margin-bottom: 14px; }

      .up-entry {
        display: flex; align-items: center; gap: 10px;
        padding: 9px 12px; background: var(--bg-3);
        border: 1px solid var(--border); border-radius: var(--r-sm); margin-bottom: 6px;
      }
      .up-name { font-size: 12px; font-weight: 500; flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      .up-size { font-size: 11px; color: var(--text-3); white-space: nowrap; }
      .prog-wrap { width: 70px; background: var(--bg-4); border-radius: 99px; height: 4px; overflow: hidden; flex-shrink: 0; }
      .prog-fill { height: 100%; background: var(--primary); border-radius: 99px; transition: width 0.3s; }

      .res-card {
        padding: 10px 12px; border-radius: var(--r-sm);
        border: 1px solid var(--border); background: var(--bg-3); margin-bottom: 6px;
      }
      .res-name { font-size: 12px; font-weight: 600; color: var(--text); margin-bottom: 5px; }
      .res-row { display: flex; gap: 10px; flex-wrap: wrap; align-items: center; }
      .res-dot { font-size: 11px; color: var(--text-2); }

      /* ── Sessions ── */
      .sess-card {
        display: flex; align-items: center; justify-content: space-between;
        padding: 11px 14px; border: 1px solid var(--border);
        border-radius: var(--r-sm); margin-bottom: 6px;
        background: var(--bg-3); transition: border-color 0.15s;
        gap: 12px; flex-wrap: wrap;
      }
      .sess-card:hover { border-color: var(--border-2); }
      .sess-device { font-size: 13px; font-weight: 600; color: var(--text); }
      .sess-meta { font-size: 11px; color: var(--text-3); margin-top: 2px; }

      /* ── DID ── */
      .did-box {
        background: linear-gradient(135deg, var(--primary-d), var(--purple-d));
        border: 1px solid var(--primary-glow); border-radius: var(--r-lg);
        padding: 16px; margin-bottom: 14px;
      }
      .did-val {
        font-family: 'DM Mono', 'Fira Code', monospace;
        font-size: 11px; color: var(--primary); word-break: break-all;
        background: var(--bg-2); border: 1px solid var(--border);
        border-radius: var(--r-sm); padding: 10px 12px; margin: 8px 0; line-height: 1.6;
      }

      /* ── Info table ── */
      td.inf-label { color: var(--text-3); font-size: 11px; font-weight: 500; width: 130px; padding: 6px 14px; }

      /* ── Flash ── */
      .flash {
        position: fixed; top: 14px; right: 14px; z-index: 9999;
        display: flex; align-items: center; gap: 10px;
        padding: 10px 16px; border-radius: var(--r);
        font-size: 13px; font-weight: 500;
        box-shadow: var(--shadow-lg); max-width: 320px;
        animation: slideIn 0.25s cubic-bezier(0.34,1.56,0.64,1);
      }
      .flash-success { background: var(--bg-2); color: var(--green); border: 1px solid rgba(16,185,129,0.3); }
      .flash-error   { background: var(--bg-2); color: var(--red);   border: 1px solid rgba(239,68,68,0.3); }
      @keyframes slideIn { from { transform: translateX(20px) scale(0.95); opacity: 0; } to { transform: none; opacity: 1; } }

      /* ── Empty ── */
      .empty { text-align: center; padding: 40px 20px; color: var(--text-3); }
      .empty-icon { font-size: 32px; margin-bottom: 10px; opacity: .6; }
      .empty-title { font-size: 14px; font-weight: 600; color: var(--text-2); margin-bottom: 5px; }
      .empty-sub { font-size: 12px; margin-bottom: 18px; }

      /* ── Page animation ── */
      .page-wrap { animation: fadeUp 0.18s ease both; }
      @keyframes fadeUp { from { opacity:0; transform: translateY(6px); } to { opacity:1; transform: none; } }

      /* ── Misc ── */
      .flex { display: flex; } .flex-col { flex-direction: column; }
      .items-center { align-items: center; }
      .gap-2 { gap: 8px; } .gap-3 { gap: 12px; }
      .spacer { flex: 1; }
      .mono { font-family: 'DM Mono','Fira Code',monospace; font-size: 11px; }
      .text-sm { font-size: 11px; color: var(--text-3); }

      /* ── File Viewer Modal ── */
      .fv-overlay { position:fixed;inset:0;z-index:1000;display:flex;align-items:center;justify-content:center;padding:16px;animation:fadeIn .2s ease; }
      .fv-backdrop { position:absolute;inset:0;background:rgba(0,0,0,0.78);backdrop-filter:blur(4px);cursor:pointer; }
      .fv-modal { position:relative;z-index:1;background:var(--bg-2);border:1px solid var(--border-2);border-radius:var(--r-lg);display:flex;flex-direction:column;width:100%;max-width:920px;max-height:90vh;box-shadow:var(--shadow-lg);animation:scaleIn .2s cubic-bezier(0.34,1.56,0.64,1);overflow:hidden; }
      @keyframes scaleIn { from{transform:scale(0.94);opacity:0} to{transform:none;opacity:1} }
      .fv-header { display:flex;align-items:center;gap:12px;padding:12px 16px;border-bottom:1px solid var(--border);flex-shrink:0; }
      .fv-file-icon { font-size:22px;flex-shrink:0; }
      .fv-file-name { font-size:13px;font-weight:600;color:var(--text);overflow:hidden;text-overflow:ellipsis;white-space:nowrap; }
      .fv-file-meta { display:flex;align-items:center;gap:6px;font-size:11px;color:var(--text-3);margin-top:3px;flex-wrap:wrap; }
      .fv-close { width:30px;height:30px;border-radius:var(--r-sm);background:var(--bg-3);border:1px solid var(--border);color:var(--text-2);cursor:pointer;font-size:13px;display:flex;align-items:center;justify-content:center;flex-shrink:0;transition:all .15s;margin-left:auto; }
      .fv-close:hover { background:var(--red-d);color:var(--red);border-color:var(--red); }
      .fv-body { flex:1;overflow:auto;min-height:0;display:flex;align-items:center;justify-content:center;background:var(--bg); }
      .fv-img-wrap { width:100%;height:100%;min-height:300px;display:flex;align-items:center;justify-content:center;padding:20px; }
      .fv-img { max-width:100%;max-height:68vh;object-fit:contain;border-radius:var(--r-sm);opacity:0;transition:opacity .3s;box-shadow:var(--shadow); }
      .fv-img.loaded { opacity:1; }
      .fv-video-wrap { width:100%;background:#000; }
      .fv-video { width:100%;max-height:68vh;display:block; }
      .fv-audio-wrap { width:100%;padding:36px 28px;display:flex;flex-direction:column;align-items:center;gap:20px; }
      .fv-audio-art { text-align:center;width:140px;height:140px;border-radius:50%;background:linear-gradient(135deg,var(--primary-d),var(--purple-d));border:2px solid var(--border-2);display:flex;flex-direction:column;align-items:center;justify-content:center; }
      .fv-audio { width:100%;max-width:500px; }
      .fv-doc-wrap { width:100%;height:68vh; }
      .fv-iframe { width:100%;height:100%;border:none;display:block; }
      .fv-text-wrap { width:100%;padding:24px;height:68vh;overflow:auto; }
      .fv-text-loading { display:flex;align-items:center;gap:12px;color:var(--text-2);font-size:13px; }
      .fv-unsupported,.fv-error { padding:48px 32px;text-align:center;color:var(--text-3); }
      .fv-footer { padding:10px 16px;border-top:1px solid var(--border);display:flex;gap:8px;justify-content:flex-end;flex-shrink:0;background:var(--bg-2); }
      .fv-spinner { width:18px;height:18px;border-radius:50%;border:2px solid var(--border-2);border-top-color:var(--primary);animation:spin .7s linear infinite; }
      @keyframes spin { to{transform:rotate(360deg)} }
      @media(max-width:640px){.fv-modal{max-height:95vh;border-radius:var(--r) var(--r) 0 0;align-self:flex-end}.fv-overlay{padding:0;align-items:flex-end}}


    </style>

    <!-- Flash -->
    <%= if @flash_msg do %>
      <div class={"flash flash-#{if @flash_type == :success, do: "success", else: "error"}"}>
        <span><%= if @flash_type == :success, do: "✓", else: "✕" %></span>
        <%= @flash_msg %>
        <button phx-click="dismiss_flash" style="background:none;border:none;color:inherit;cursor:pointer;margin-left:6px;font-size:16px;line-height:1">×</button>
      </div>
    <% end %>


    <!-- ── File Viewer Modal ── -->
    <%= if @viewer do %>
      <div class="fv-overlay">
        <div class="fv-backdrop" phx-click="close_viewer"></div>
        <div class="fv-modal">
          <div class="fv-header">
            <span class="fv-file-icon"><%= ico(@viewer.content_type) %></span>
            <div style="overflow:hidden;flex:1;min-width:0">
              <div class="fv-file-name"><%= @viewer.filename %></div>
              <div class="fv-file-meta">
                <span><%= ftype(@viewer.content_type) %></span>
                <span>·</span>
                <span><%= fdate(@viewer.inserted_at) %></span>
                <span>·</span>
                <span class={"badge #{file_status_badge(@viewer.status)}"}><%= file_status_label(@viewer.status) %></span>
              </div>
            </div>
            <button class="fv-close" phx-click="close_viewer">✕</button>
          </div>
          <div class="fv-body">
            <%= if is_nil(@viewer.url) do %>
              <div class="fv-error">
                <div style="font-size:36px;margin-bottom:12px">⚠️</div>
                <div style="font-weight:600;margin-bottom:6px">File unavailable</div>
                <div style="font-size:12px;color:var(--text-3)">Could not generate a download link.</div>
              </div>
            <% else %>
              <%= cond do %>
                <% String.starts_with?(@viewer.content_type || "", "image/") -> %>
                  <div class="fv-img-wrap">
                    <img src={@viewer.url} alt={@viewer.filename} class="fv-img"
                         onload="this.classList.add('loaded')"
                         onerror="this.parentNode.innerHTML='<div class=fv-error>⚠️ Image could not be loaded</div>'"/>
                  </div>
                <% String.starts_with?(@viewer.content_type || "", "video/") -> %>
                  <div class="fv-video-wrap">
                    <video controls autoplay class="fv-video" preload="metadata">
                      <source src={@viewer.url} type={@viewer.content_type}/>
                    </video>
                  </div>
                <% String.starts_with?(@viewer.content_type || "", "audio/") -> %>
                  <div class="fv-audio-wrap">
                    <div class="fv-audio-art">
                      <span style="font-size:52px;opacity:.7">🎵</span>
                    </div>
                    <audio controls class="fv-audio" preload="metadata" autoplay>
                      <source src={@viewer.url} type={@viewer.content_type}/>
                    </audio>
                  </div>
                <% (@viewer.content_type || "") == "application/pdf" or String.contains?(@viewer.content_type || "", "pdf") -> %>
                  <div class="fv-doc-wrap">
                    <iframe src={@viewer.url} class="fv-iframe" title={@viewer.filename}></iframe>
                  </div>
                <% String.contains?(@viewer.content_type || "", "wordprocessingml") or String.contains?(@viewer.content_type || "", "msword") -> %>
                  <div class="fv-doc-wrap" id="fv-docx-wrap" data-url={@viewer.url}>
                    <div id="fv-docx-loading" class="fv-text-loading" style="padding:24px">
                      <div class="fv-spinner"></div><span>Rendering document...</span>
                    </div>
                    <div id="fv-docx-output" style="display:none;width:100%;height:100%;overflow:auto;padding:28px 36px;font-family:Georgia,serif;font-size:13px;line-height:1.8;color:var(--text);background:var(--bg-2)"></div>
                  </div>
                <% String.starts_with?(@viewer.content_type || "", "text/") -> %>
                  <div class="fv-text-wrap" data-url={@viewer.url}>
                    <div class="fv-text-loading" id="fv-text-loading" style="padding:12px"><div class="fv-spinner"></div><span>Loading...</span></div>
                    <pre id="fv-text-content" style="display:none;font-family:monospace;font-size:12px;line-height:1.6;color:var(--text);white-space:pre-wrap;word-break:break-word"></pre>
                  </div>
                <% true -> %>
                  <div class="fv-unsupported">
                    <div style="font-size:48px;margin-bottom:16px"><%= ico(@viewer.content_type) %></div>
                    <div style="font-size:14px;font-weight:600;color:var(--text);margin-bottom:8px"><%= @viewer.filename %></div>
                    <div style="font-size:12px;color:var(--text-2);margin-bottom:20px">Preview not available for this file type</div>
                    <a href={@viewer.url} target="_blank" class="btn btn-primary" download={@viewer.filename}>↓ Download File</a>
                  </div>
              <% end %>
            <% end %>
          </div>
          <%= if @viewer.url do %>
            <div class="fv-footer">
              <a href={@viewer.url} target="_blank" class="btn btn-ghost btn-sm">↗ Open in new tab</a>
              <a href={"/studio/#{@viewer.id}"} target="_blank" class="btn btn-ghost btn-sm">✏ Edit in Studio</a>
              <a href={@viewer.url} download={@viewer.filename} class="btn btn-primary btn-sm">↓ Download</a>
            </div>
          <% end %>
        </div>
      </div>
    <% end %>

    <!-- Mobile Backdrop -->
    <div class={"backdrop #{if @sidebar_open, do: "visible"}"} phx-click="close_sidebar"></div>

    <div class="shell">

      <!-- ══ SIDEBAR ══ -->
      <nav class={"sidebar #{if @sidebar_open, do: "open"}"} id="sidebar">

        <div class="sb-logo">
          <div class="sb-logo-mark">⬡</div>
          <span class="sb-logo-text">PRZMA</span>
          <span class="sb-logo-badge">Beta</span>
        </div>

        <div class="sb-user">
          <div class="sb-avatar"><%= String.first(@user.nickname || "U") |> String.upcase() %></div>
          <div class="sb-user-info">
            <div class="sb-user-name"><%= @user.nickname %></div>
            <div class="sb-user-email"><%= @user.email %></div>
          </div>
        </div>

        <div class="sb-nav">
          <div class="nav-section">
            <span class="nav-section-label">Workspace</span>
          </div>
          <button class={"nav-item #{if @page == :home, do: "active"}"} phx-click="nav" phx-value-page="home" data-label="Dashboard">
            <span class="nav-icon">▦</span><span class="nav-label">Dashboard</span>
          </button>
          <button class={"nav-item #{if @page == :files, do: "active"}"} phx-click="nav" phx-value-page="files" data-label="My Files">
            <span class="nav-icon">◫</span><span class="nav-label">My Files</span>
            <%= if @stats.total > 0 do %><span class="nav-badge"><%= @stats.total %></span><% end %>
          </button>
          <button class={"nav-item #{if @page == :upload, do: "active"}"} phx-click="nav" phx-value-page="upload" data-label="Upload">
            <span class="nav-icon">↑</span><span class="nav-label">Upload</span>
          </button>
        <button class={"ftab #{if @page == :settings, do: "on"}"}
          phx-click="nav" phx-value-page="settings"
          style="font-size:11px;">⚙️ Settings</button>
          <button class="nav-item" onclick="window.open('/studio','_blank')" data-label="PRZMA Studio">
            <span class="nav-icon">✏</span><span class="nav-label">PRZMA Studio</span>
          </button>

          <button class="nav-item" onclick="window.location='/social'" data-label="Social">
            <span class="nav-icon">🌐</span><span class="nav-label">Social</span>
          </button>

          <button class="nav-item" onclick="window.location='/chats'" data-label="Messages">
            <span class="nav-icon">💬</span><span class="nav-label">Messages</span>
          </button>

          <div class="nav-section">
            <span class="nav-section-label">Account</span>
          </div>
          <button class={"nav-item #{if @page == :profile, do: "active"}"} phx-click="nav" phx-value-page="profile" data-label="Profile">
            <span class="nav-icon">◈</span><span class="nav-label">Profile</span>
          </button>
          <button class={"nav-item #{if @page == :devices, do: "active"}"} phx-click="nav" phx-value-page="devices" data-label="Devices">
            <span class="nav-icon">◉</span><span class="nav-label">Devices</span>
          </button>
        </div>

        <div class="sb-footer">
          <button class="sb-toggle-btn" id="sb-collapse-btn" title="Collapse sidebar">
            ⇐
          </button>
          <%= if @user.is_admin do %>
            <a href="/admin" class="nav-item" style="text-decoration:none" data-label="Admin">
              <span class="nav-icon">⬡</span><span class="nav-label">Admin Panel</span>
            </a>
          <% end %>
          <button class="nav-item nav-item-danger" phx-click="logout" data-label="Sign Out">
            <span class="nav-icon">←</span><span class="nav-label">Sign Out</span>
          </button>
        </div>
      </nav>

      <!-- ══ MAIN ══ -->
      <div class="main">
        <header class="topbar">
          <!-- Hamburger -->
          <button class="topbar-hamburger" id="hamburger-btn" aria-label="Toggle sidebar">
            ☰
          </button>

          <span class="topbar-title"><%= page_title(@page) %></span>
          <span class="topbar-spacer"></span>

          <div class="topbar-actions">
            <button class="theme-btn" id="theme-btn" title="Toggle theme">◑</button>
            <button class="btn btn-primary btn-sm" phx-click="nav" phx-value-page="upload">+ Upload</button>
          </div>
        </header>

        <main class="content">
          <div class="page-wrap">
            <%= render_page(assigns) %>
          </div>
        </main>
      </div>
    </div>

    <script>
      /* ── Theme System ── */
      function getTheme() {
        return document.documentElement.getAttribute('data-theme') || 'dark';
      }
      function setTheme(t) {
        document.documentElement.setAttribute('data-theme', t);
        localStorage.setItem('przma-theme', t);
        var icon = document.getElementById('theme-icon');
        if (icon) icon.textContent = t === 'dark' ? '☀' : '◑';
        var btn = document.getElementById('theme-btn');
        if (btn) btn.textContent = t === 'dark' ? '☀' : '◑';
        setTimeout(drawCharts, 60);
      }
      (function() {
        var saved = localStorage.getItem('przma-theme');
        var sys = window.matchMedia('(prefers-color-scheme: light)').matches ? 'light' : 'dark';
        setTheme(saved || sys);
      })();
      document.getElementById('theme-btn').addEventListener('click', function() {
        setTheme(getTheme() === 'dark' ? 'light' : 'dark');
      });

      /* ── Sidebar: Tablet collapse / Mobile drawer ── */
      var sidebar = document.getElementById('sidebar');
      var hamburger = document.getElementById('hamburger-btn');
      var collapseBtn = document.getElementById('sb-collapse-btn');

      function isMobile() { return window.innerWidth < 768; }
      function isTablet() { return window.innerWidth >= 768 && window.innerWidth < 1024; }

      // Tablet: toggle collapsed (icon-only)
      if (collapseBtn) {
        var collapsed = localStorage.getItem('przma-sb-collapsed') === '1';
        if (collapsed && isTablet()) sidebar.classList.add('collapsed');
        collapseBtn.addEventListener('click', function() {
          if (sidebar.classList.toggle('collapsed')) {
            collapseBtn.textContent = '⇒';
            localStorage.setItem('przma-sb-collapsed', '1');
          } else {
            collapseBtn.textContent = '⇐';
            localStorage.setItem('przma-sb-collapsed', '0');
          }
        });
      }

      // Hamburger: mobile drawer open, tablet collapse toggle
      if (hamburger) {
        hamburger.addEventListener('click', function() {
          if (isMobile()) {
            // Let Phoenix handle mobile via phx-click toggle_sidebar
            // But we need to push the event - use JS directly
            sidebar.classList.toggle('open');
          } else if (isTablet()) {
            if (collapseBtn) collapseBtn.click();
          }
        });
      }

      // Close sidebar on mobile when clicking nav (handled by Phoenix phx-click)
      // Close on resize
      window.addEventListener('resize', function() {
        if (!isMobile()) sidebar.classList.remove('open');
        if (!isTablet()) sidebar.classList.remove('collapsed');
      });

      /* ── Charts ── */
      var charts = {};

      function chartColors() {
        var dark = getTheme() === 'dark';
        return {
          grid:   dark ? 'rgba(255,255,255,0.05)' : 'rgba(0,0,0,0.05)',
          tick:   dark ? '#4e566b' : '#9ca3b4',
          border: dark ? '#13161e' : '#ffffff'
        };
      }

      function drawDonut() {
        var el = document.getElementById('chart-types');
        if (!el || !window.Chart) return;
        if (charts.donut) charts.donut.destroy();
        var v = JSON.parse(el.dataset.v || '[0,0,0,0]');
        var c = chartColors();
        charts.donut = new Chart(el, {
          type: 'doughnut',
          data: {
            labels: ['Audio','Video','Images','Docs'],
            datasets: [{ data: v,
              backgroundColor: ['#5c73f2','#a78bfa','#10b981','#f59e0b'],
              borderWidth: 2, borderColor: c.border }]
          },
          options: {
            responsive: true, maintainAspectRatio: false, cutout: '70%',
            plugins: { legend: { position: 'bottom',
              labels: { font: {size:10,family:'DM Sans'}, padding:8, boxWidth:8, color: c.tick }
            }}
          }
        });
      }

      function drawBar() {
        var el = document.getElementById('chart-monthly');
        if (!el || !window.Chart) return;
        if (charts.bar) charts.bar.destroy();
        var labels = JSON.parse(el.dataset.l || '[]');
        var vals   = JSON.parse(el.dataset.v || '[]');
        var c = chartColors();
        charts.bar = new Chart(el, {
          type: 'bar',
          data: {
            labels: labels,
            datasets: [{ label: 'Uploads', data: vals,
              backgroundColor: 'rgba(92,115,242,0.8)',
              borderRadius: 5, borderSkipped: false }]
          },
          options: {
            responsive: true, maintainAspectRatio: false,
            plugins: { legend: { display: false } },
            scales: {
              y: { beginAtZero: true, ticks: { stepSize:1, font:{size:10}, color: c.tick },
                   grid: { color: c.grid }, border: { display: false } },
              x: { ticks: { font:{size:10}, color: c.tick },
                   grid: { display: false }, border: { display: false } }
            }
          }
        });
      }

      function drawCharts() { drawDonut(); drawBar(); }
      document.addEventListener('DOMContentLoaded', drawCharts);
      window.addEventListener('phx:update', drawCharts);
      window.addEventListener('phx:page-loading-stop', drawCharts);

      // ── Auto-reload panel files when Studio saves ──
      (function() {
        // BroadcastChannel listener
        try {
          var ch = new BroadcastChannel('przma-studio');
          ch.addEventListener('message', function(e) {
            if (e.data && e.data.type === 'file_saved') {
              window.location.reload();
            }
          });
        } catch(err) {}
        // localStorage fallback
        window.addEventListener('storage', function(e) {
          if (e.key === 'przma-file-saved') {
            window.location.reload();
          }
        });
      })();

      // ── Viewer content loaders ──
      function loadViewerContent() {
        // DOCX via mammoth
        var docxWrap = document.getElementById('fv-docx-wrap');
        if (docxWrap && window.mammoth) {
          var url = docxWrap.getAttribute('data-url');
          fetch(url)
            .then(function(r){ return r.arrayBuffer(); })
            .then(function(buf){ return mammoth.convertToHtml({arrayBuffer: buf}); })
            .then(function(res){
              var out = document.getElementById('fv-docx-output');
              var ldr = document.getElementById('fv-docx-loading');
              if(out){ out.innerHTML = res.value; out.style.display = 'block'; }
              if(ldr) ldr.style.display = 'none';
            }).catch(function(){ document.getElementById('fv-docx-loading').textContent = 'Could not render DOCX'; });
        }
        // Plain text
        var textPre = document.getElementById('fv-text-content');
        if (textPre) {
          var srcEl = textPre.previousElementSibling;
          var url = srcEl ? srcEl.getAttribute('data-url') : null;
          var audioEl = document.querySelector('audio[src]');
          // Find the URL from iframe or audio src on page
          var iframeEl = document.querySelector('.fv-doc-wrap iframe');
          if (!url && iframeEl) url = iframeEl.src;
          if (!url) {
            // fallback: find text loader via data-url on parent
            var wrap = textPre.parentElement;
            if (wrap) url = wrap.getAttribute('data-url');
          }
          if (url) {
            fetch(url).then(function(r){ return r.text(); })
              .then(function(t){
                textPre.textContent = t;
                textPre.style.display = 'block';
                var ldr = document.getElementById('fv-text-loading');
                if (ldr) ldr.style.display = 'none';
              }).catch(function(e){ console.error(e); });
          }
        }
      }
      document.addEventListener('DOMContentLoaded', loadViewerContent);
      window.addEventListener('phx:update', function(){ setTimeout(loadViewerContent, 80); });
    </script>
    """
  end

  defp page_title(:home),     do: "Dashboard"
  defp page_title(:files),    do: "My Files"
  defp page_title(:upload),   do: "Upload Files"
  defp page_title(:profile),  do: "Profile"
  defp page_title(:devices),  do: "Devices"
  defp page_title(_),         do: "PRZMA"

  # ── Pages ──────────────────────────────────────────────────────────────────

  defp render_page(%{page: :home} = assigns) do
    ~H"""
    <div class="stat-grid">
      <div class="stat-card"><div class="stat-ico ico-blue">📄</div><div><div class="stat-lbl">Total</div><div class="stat-val"><%= @stats.total %></div></div></div>
      <div class="stat-card"><div class="stat-ico ico-green">🎵</div><div><div class="stat-lbl">Audio</div><div class="stat-val"><%= @stats.audio %></div></div></div>
      <div class="stat-card"><div class="stat-ico ico-purple">🎬</div><div><div class="stat-lbl">Video</div><div class="stat-val"><%= @stats.video %></div></div></div>
      <div class="stat-card"><div class="stat-ico ico-amber">🖼️</div><div><div class="stat-lbl">Images</div><div class="stat-val"><%= @stats.image %></div></div></div>
      <div class="stat-card"><div class="stat-ico ico-red">📕</div><div><div class="stat-lbl">Docs</div><div class="stat-val"><%= @stats.document %></div></div></div>
    </div>

    <div class="charts-row">
      <div class="card">
        <div class="card-hdr"><span class="card-title">By Type</span></div>
        <div class="card-body" style="height:180px;position:relative">
          <canvas id="chart-types" data-v={@type_values}></canvas>
        </div>
      </div>
      <div class="card">
        <div class="card-hdr"><span class="card-title">Monthly Uploads</span></div>
        <div class="card-body" style="height:180px;position:relative">
          <canvas id="chart-monthly" data-l={@month_labels} data-v={@month_values}></canvas>
        </div>
      </div>
    </div>

    <div class="card">
      <div class="card-hdr">
        <span class="card-title">Recent Files</span>
        <span class="card-spacer"></span>
        <button class="btn btn-ghost btn-sm" phx-click="nav" phx-value-page="files">View All →</button>
      </div>
      <%= if @stats.total == 0 do %>
        <div class="empty">
          <div class="empty-icon">📂</div>
          <div class="empty-title">No files yet</div>
          <div class="empty-sub">Upload your first file to get started</div>
          <button class="btn btn-primary" phx-click="nav" phx-value-page="upload">Upload File</button>
        </div>
      <% else %>
        <div class="table-scroll">
          <table>
            <thead><tr><th>File</th><th>Type</th><th>Status</th><th>Date</th></tr></thead>
            <tbody>
              <%= for f <- Enum.take(@files, 8) do %>
                <tr>
                  <td>
                    <div style="display:flex;align-items:center;gap:8px">
                      <span style="font-size:15px"><%= ico(f.content_type) %></span>
                      <span style="font-weight:500;font-size:12px"><%= f.filename %></span>
                    </div>
                  </td>
                  <td><span class="badge badge-gray"><%= ftype(f.content_type) %></span></td>
                  <td><span class={"badge #{sbadge(f.status)}"}><%= fstatus(f.status) %></span></td>
                  <td class="text-sm"><%= fdate(f.inserted_at) %></td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      <% end %>
    </div>
    """
  end

  defp render_page(%{page: :files} = assigns) do
    ~H"""
    <div class="card">
      <div class="card-hdr" style="flex-direction:column;align-items:stretch;gap:10px">
        <!-- Folder tabs -->
        <div style="display:flex;gap:6px;margin-bottom:8px;flex-wrap:wrap">
          <button class={"ftab #{if @active_folder=="personal", do: "on"}"}
            phx-click="set_folder" phx-value-folder="personal"
            style={"font-size:11px;#{if @active_folder=="personal", do: "background:#fef3c7;color:#92400e;border-color:#fbbf24", else: ""}"}>
            🔐 Personal (<%= Map.get(@folder_stats, "personal", 0) %>)</button>
          <button class={"ftab #{if @active_folder=="private", do: "on"}"}
            phx-click="set_folder" phx-value-folder="private"
            style={"font-size:11px;#{if @active_folder=="private", do: "background:#ede9fe;color:#4c1d95;border-color:#7c3aed", else: ""}"}>
            🔒 Private (<%= Map.get(@folder_stats, "private", 0) %>)</button>
          <button class={"ftab #{if @active_folder=="public", do: "on"}"}
            phx-click="set_folder" phx-value-folder="public"
            style={"font-size:11px;#{if @active_folder=="public", do: "background:#d1fae5;color:#064e3b;border-color:#059669", else: ""}"}>
            🌍 Public (<%= Map.get(@folder_stats, "public", 0) %>)</button>
          <button class={"ftab #{if @random_vault != nil, do: "on"}"}
            phx-click="random_upload"
            style={"font-size:11px;#{if @random_vault != nil, do: "background:#fce7f3;color:#831843;border-color:#db2777", else: ""}"}>
            🎲 Random <%= if @random_vault != nil, do: "(→ #{@active_folder})", else: "" %></button>
        </div>
        <!-- Filter tabs -->
        <div class="filter-row">
          <button class={"ftab #{if @files_filter=="all",      do: "on"}"} phx-click="filter" phx-value-filter="all">All (<%= @stats.total %>)</button>
          <button class={"ftab #{if @files_filter=="audio",    do: "on"}"} phx-click="filter" phx-value-filter="audio">🎵 Audio (<%= @stats.audio %>)</button>
          <button class={"ftab #{if @files_filter=="video",    do: "on"}"} phx-click="filter" phx-value-filter="video">🎬 Video (<%= @stats.video %>)</button>
          <button class={"ftab #{if @files_filter=="image",    do: "on"}"} phx-click="filter" phx-value-filter="image">🖼️ Images (<%= @stats.image %>)</button>
          <button class={"ftab #{if @files_filter=="document", do: "on"}"} phx-click="filter" phx-value-filter="document">📄 Docs (<%= @stats.document %>)</button>
        </div>
        <!-- Sort + Search -->
        <div class="controls-row">
          <div style="display:flex;gap:4px;flex-shrink:0">
            <button class={"ftab #{if @files_sort == "newest", do: "on"}"} phx-click="sort" phx-value-sort="newest">↓ Newest</button>
            <button class={"ftab #{if @files_sort == "oldest", do: "on"}"} phx-click="sort" phx-value-sort="oldest">↑ Oldest</button>
            <button class={"ftab #{if @files_sort == "az", do: "on"}"} phx-click="sort" phx-value-sort="az">A→Z</button>
            <button class={"ftab #{if @files_sort == "za", do: "on"}"} phx-click="sort" phx-value-sort="za">Z→A</button>
          </div>
          <input class="input" placeholder="Search files…"
            value={@files_search}
            phx-keyup="search"
            phx-debounce="150"/>
        </div>
      </div>

      <%= if @filtered == [] do %>
        <div class="empty">
          <div class="empty-icon">🔍</div>
          <div class="empty-title">No files found</div>
          <div class="empty-sub">Try a different search or filter</div>
        </div>
      <% else %>
        <div class="table-scroll">
          <table>
            <thead><tr><th>File</th><th>Type</th><th>Folder</th><th>Status</th><th>Uploaded</th><th style="width:80px">Actions</th></tr></thead>
            <tbody>
              <%= for f <- @filtered do %>
                <tr style="cursor:pointer" phx-click="open_viewer" phx-value-id={f.id}>
                  <td>
                    <div style="display:flex;align-items:center;gap:8px">
                      <span style="font-size:15px"><%= ico(f.content_type) %></span>
                      <span style="font-weight:500"><%= f.filename %></span>
                    </div>
                  </td>
                  <td><span class="badge badge-gray"><%= ftype(f.content_type) %></span></td>
                  <td><span class={"badge #{file_status_badge(f.status)}"}><%= file_status_label(f.status) %></span></td>
                  <td class="text-sm"><%= fdate(f.inserted_at) %></td>
                  <td><span style={"font-size:10px;font-weight:700;padding:2px 7px;border-radius:99px;#{folder_badge_style(f[:folder])}"}>
                    <%= folder_icon(f[:folder]) %> <%= String.capitalize(f[:folder] || "personal") %>
                  </span></td>
                  <td onclick="event.stopPropagation()">
                    <a href={"/studio/#{f.id}"} target="_blank" class="btn btn-ghost btn-sm"
                      style="font-size:11px;padding:3px 8px;text-decoration:none">
                      ✏ Edit
                    </a>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      <% end %>
    </div>
    """
  end

  defp render_page(%{page: :upload} = assigns) do
    ~H"""
    <style>
      .folder-grid{display:grid;grid-template-columns:repeat(3,1fr);gap:12px;margin-bottom:20px}
      @media(max-width:640px){.folder-grid{grid-template-columns:1fr}}
      .folder-card{padding:16px;border:2px solid var(--border);border-radius:var(--r-lg);
        cursor:pointer;transition:all .2s;background:var(--bg-3);
        display:flex;flex-direction:column;gap:6px;user-select:none}
      .folder-card:hover{border-color:var(--border-2);transform:translateY(-2px);box-shadow:var(--shadow)}
      .fc-personal.active{border-color:#f59e0b!important;background:rgba(245,158,11,.08)!important;box-shadow:0 0 0 3px rgba(245,158,11,.2)!important}
      .fc-private.active{border-color:#7c3aed!important;background:rgba(124,58,237,.08)!important;box-shadow:0 0 0 3px rgba(124,58,237,.2)!important}
      .fc-public.active{border-color:#059669!important;background:rgba(5,150,105,.08)!important;box-shadow:0 0 0 3px rgba(5,150,105,.2)!important}
      .fc-icon{font-size:26px;line-height:1}
      .fc-name{font-size:15px;font-weight:700;color:var(--text)}
      .fc-tags{font-size:9px;font-weight:700;text-transform:uppercase;letter-spacing:.8px;color:var(--text-3);margin-top:2px}
      .fc-desc{font-size:12px;color:var(--text-2);line-height:1.5;font-style:italic;margin-top:4px}
      .fc-count{font-size:10px;color:var(--text-3);margin-top:4px}
      .fc-personal .fc-tags{color:#d97706}
      .fc-private  .fc-tags{color:#7c3aed}
      .fc-public   .fc-tags{color:#059669}
      .fc-personal.active .fc-tags{color:#d97706}
      .fc-private.active  .fc-tags{color:#7c3aed}
      .fc-public.active   .fc-tags{color:#059669}
    </style>

    <div class="card" style="max-width:680px">
      <div class="card-hdr">
        <span class="card-title">Upload Files</span>
        <span class="card-sub" style="margin-left:8px">MP3 · WAV · MP4 · JPG · PNG · PDF · DOCX (max 50 MB)</span>
      </div>
      <div class="card-body">

        <!-- ── Folder Selector ── -->
        <div style="margin-bottom:20px">
          <div style="font-size:11px;font-weight:700;color:var(--text-3);
                      text-transform:uppercase;letter-spacing:.8px;margin-bottom:10px">
            Choose Folder
          </div>
          <div class="folder-grid">
            <div class={"folder-card fc-personal #{if @active_folder=="personal", do: "active"}"}
                 phx-click="set_folder" phx-value-folder="personal">
              <div class="fc-icon">🔐</div>
              <div class="fc-name">Personal</div>
              <div class="fc-tags">Private · Sovereign · Yours</div>
              <div class="fc-desc">Your daily entries and reflections. Nothing leaves without your explicit choice.</div>
              <div class="fc-count"><%= Map.get(@folder_stats || %{}, "personal", 0) %> files</div>
            </div>
            <div class={"folder-card fc-private #{if @active_folder=="private", do: "active"}"}
                 phx-click="set_folder" phx-value-folder="private">
              <div class="fc-icon">🔒</div>
              <div class="fc-name">Private</div>
              <div class="fc-tags">Encrypted · Local-First · Zero Server Access</div>
              <div class="fc-desc">Notes, drafts, and local data. Encrypted on your device. Server stores only ciphertext.</div>
              <div class="fc-count"><%= Map.get(@folder_stats || %{}, "private", 0) %> files</div>
            </div>
            <div class={"folder-card fc-public #{if @active_folder=="public", do: "active"}"}
                 phx-click="set_folder" phx-value-folder="public">
              <div class="fc-icon">🌍</div>
              <div class="fc-name">Public</div>
              <div class="fc-tags">Open · Tended · Everyone's</div>
              <div class="fc-desc">What you choose to share with the world. PRZMA Commons can read this.</div>
              <div class="fc-count"><%= Map.get(@folder_stats || %{}, "public", 0) %> files</div>
            </div>
            <div class={"folder-card #{if @random_vault != nil, do: "active"}"}
                 phx-click="random_upload"
                 style="border-color:#db2777;cursor:pointer">
              <div class="fc-icon">🎲</div>
              <div class="fc-name">Random</div>
              <div class="fc-tags">0=Personal · 1=Private · 2=Public</div>
              <div class="fc-desc">System picks a vault randomly on each click. Used for testing vault distribution across S3.</div>
              <div class="fc-count" style="color:#db2777;font-weight:700">
                <%= if @random_vault != nil, do: "→ vault #{@random_vault} (#{@active_folder})", else: "Click to pick" %>
              </div>
            </div>
          </div>

          <div style="font-size:12px;color:var(--text-2);padding:8px 12px;
                      background:var(--bg-3);border-radius:var(--r-sm);border:1px solid var(--border)">
            <%= case @active_folder do %>
              <% "personal" -> %>
                🔐 <strong>Personal</strong> — stored encrypted, accessible only by you. Share with anyone using a time-limited token.
              <% "private" -> %>
                🔒 <strong>Private</strong> — encrypted on your device before upload. Server cannot read this content. No sharing possible.
              <% "public" -> %>
                🌍 <strong>Public</strong> — visible to everyone. PRZMA platform can use this for collective intelligence. You can un-public any file at any time.
              <% _ -> %>
                🎲 <strong>Random</strong> — vault <%= @random_vault || "?" %> selected (<%= String.capitalize(@active_folder) %>). File will go to <strong><%= @active_folder %>/ab/cd/hash</strong> in Linode S3.
            <% end %>
          </div>
        </div>

        <!-- ── Upload Form ── -->
        <form phx-submit="do_upload" phx-change="validate_upload">
          <input type="hidden" name="folder" value={@active_folder}/>
          <div class="upload-zone" phx-drop-target={@uploads.file.ref}>
            <div class="uz-icon">☁</div>
            <div class="uz-title">Drop files here or click Browse</div>
            <div class="uz-sub">
              Uploading to: <strong><%= String.capitalize(@active_folder) %></strong> folder
              · S3 · PostgreSQL · LanceDB 446-dim HOLNN
            </div>
            <label class="btn btn-primary" style="cursor:pointer">
              Browse Files
              <.live_file_input upload={@uploads.file} style="display:none"/>
            </label>
          </div>

          <%= if @uploads.file.entries != [] do %>
            <div style="margin-top:12px">
              <%= for entry <- @uploads.file.entries do %>
                <div class="up-entry">
                  <span style="font-size:14px"><%= ico(entry.client_type) %></span>
                  <span class="up-name"><%= entry.client_name %></span>
                  <span class="up-size"><%= fmtb(entry.client_size) %></span>
                  <div class="prog-wrap">
                    <div class="prog-fill" style={"width:#{entry.progress}%"}></div>
                  </div>
                  <button type="button" phx-click="cancel_upload" phx-value-ref={entry.ref}
                    style="background:none;border:none;color:var(--text-3);cursor:pointer;font-size:16px;line-height:1;padding:0">×</button>
                </div>
                <%= for err <- upload_errors(@uploads.file, entry) do %>
                  <div style="color:var(--red);font-size:11px;padding:2px 8px"><%= err %></div>
                <% end %>
              <% end %>
              <button type="submit" class="btn btn-primary"
                style="margin-top:10px;width:100%;height:42px">
                Upload <%= length(@uploads.file.entries) %> file(s) to <%= String.capitalize(@active_folder) %>
              </button>
            </div>
          <% end %>
        </form>

        <!-- ── Results ── -->
        <%= if @upload_results != [] do %>
          <div style="margin-top:16px;padding-top:16px;border-top:1px solid var(--border)">
            <div style="display:flex;align-items:center;margin-bottom:10px">
              <span style="font-size:13px;font-weight:600">Results</span>
              <span class="spacer"></span>
              <button class="btn btn-ghost btn-sm" phx-click="clear_results">Clear</button>
            </div>
            <%= for r <- @upload_results do %>
              <div class="res-card">
                <div class="res-name"><%= ico(r[:type]) %> <%= r[:filename] %></div>
                <%= if r[:error] do %>
                  <div style="color:var(--red);font-size:11px">❌ <%= r[:error] %></div>
                <% else %>
                  <div class="res-row">
                    <span class="res-dot"><%= if r[:s3],    do: "✅", else: "❌" %> S3</span>
                    <span class="res-dot"><%= if r[:pg],    do: "✅", else: "❌" %> PostgreSQL</span>
                    <span class="res-dot"><%= if r[:lance], do: "✅", else: "❌" %> LanceDB</span>
                    <span class="text-sm" style="margin-left:auto"><%= fmtb(r[:size]) %></span>
                  </div>
                  <div style="font-size:10px;color:var(--text-3);margin-top:4px">
                    <span style={"#{folder_badge_style(r[:folder])}padding:2px 7px;border-radius:99px;font-weight:700"}>
                      <%= folder_icon(r[:folder]) %> <%= String.capitalize(r[:folder] || "personal") %>
                    </span>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>
        <% end %>

      </div>
    </div>
    """
  end

  defp render_page(%{page: :profile} = assigns) do
    ~H"""
    <div class="did-box">
      <div style="font-size:13px;font-weight:600;color:var(--text);margin-bottom:4px">Decentralized Identifier (DID)</div>
      <div style="font-size:12px;color:var(--text-2);margin-bottom:8px">Your sovereign identity — safe to share publicly</div>
      <div class="did-val"><%= @user.did_id || "Not assigned" %></div>
      <%= if @user.did_id do %>
        <button class="btn btn-ghost btn-sm" onclick={"navigator.clipboard.writeText('#{@user.did_id}').then(()=>alert('DID copied!'))"}>📋 Copy</button>
      <% end %>
    </div>
    <div class="card" style="max-width:480px">
      <div class="card-hdr"><span class="card-title">Identity Details</span></div>
      <div class="card-body">
        <table><tbody>
          <tr><td class="inf-label">DID Method</td><td class="mono">przma</td></tr>
          <tr><td class="inf-label">Fingerprint</td><td class="mono"><%= if @user.did_id, do: String.slice(@user.did_id,-8,8), else: "-" %></td></tr>
          <tr><td class="inf-label">Namespace Key</td><td class="text-sm">Hidden — internal only</td></tr>
          <tr><td class="inf-label">Encryption</td><td style="color:var(--green);font-size:12px">✓ AES-256-GCM</td></tr>
          <tr><td class="inf-label">Epoch Key ID</td><td class="mono">228</td></tr>
          <tr><td class="inf-label">Verified</td>
            <td><span class={"badge #{if @user.is_verified, do: "badge-green", else: "badge-amber"}"}><%= if @user.is_verified, do: "Verified", else: "Unverified" %></span></td>
          </tr>
        </tbody></table>
      </div>
    </div>
    """
  end

  defp render_page(%{page: :devices} = assigns) do
    ~H"""
    <div class="card" style="max-width:560px">
      <div class="card-hdr">
        <span class="card-title">Active Sessions</span>
        <span class="badge badge-gray" style="margin-left:6px"><%= length(@sessions) %></span>
      </div>
      <div class="card-body">
        <%= if @sessions == [] do %>
          <div class="empty" style="padding:24px">
            <div class="empty-icon">🔐</div>
            <div class="empty-title">No active sessions</div>
          </div>
        <% else %>
          <%= for s <- @sessions do %>
            <div class="sess-card">
              <div>
                <div class="sess-device"><%= devico(s[:device]) %> <%= devnm(s[:device]) %></div>
                <div class="sess-meta">Last: <%= ago(s[:last_active_at]) %> · Since: <%= fdate(s[:inserted_at]) %></div>
              </div>
              <button class="btn btn-danger btn-sm" phx-click="revoke_session" phx-value-id={s.id}>← Logout</button>
            </div>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  defp render_page(%{page: :settings} = assigns) do
    ~H"""
    <div style="padding:24px;max-width:780px;margin:0 auto;">
      <h2 style="font-size:20px;font-weight:700;margin-bottom:4px;color:var(--text);">⚙️ Settings</h2>
      <p style="color:var(--text-2);font-size:13px;margin-bottom:24px;">Manage your storage providers (BYOS — Bring Your Own Storage).</p>

      <div style="background:var(--bg-2);border:1px solid var(--border);border-radius:12px;padding:20px;margin-bottom:20px;">
        <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:16px;">
          <div>
            <div style="font-weight:600;font-size:15px;color:var(--text);">🗄️ Storage Providers</div>
            <div style="font-size:12px;color:var(--text-2);margin-top:2px;">Connect your own S3, MinIO, Cloudflare R2, or Backblaze.</div>
          </div>
          <button phx-click="use_managed"
            style="padding:6px 14px;background:var(--bg-3);border:1px solid var(--border);border-radius:8px;font-size:12px;cursor:pointer;color:var(--text);">
            ☁️ Use PRZMA Managed
          </button>
        </div>

        <%= for p <- @providers do %>
        <div style={"background:var(--bg-3);border:2px solid #{if p.is_active, do: "#22c55e", else: "var(--border)"};border-radius:8px;padding:12px;margin-bottom:8px;display:flex;justify-content:space-between;align-items:center;"}>
          <div>
            <div style="font-weight:600;font-size:13px;color:var(--text);"><%= if p.is_active, do: "✅ " %><%= p.label || p.adapter %></div>
            <div style="font-size:11px;color:var(--text-2);margin-top:2px;"><%= p.adapter %> · bucket: <strong><%= p.bucket %></strong><%= if p.region, do: " · #{p.region}" %></div>
            <%= if p.is_verified do %>
              <div style="font-size:11px;color:#22c55e;margin-top:2px;">● Verified</div>
            <% end %>
          </div>
          <div style="display:flex;gap:6px;">
            <button phx-click="test_provider" phx-value-id={p.id}
              style="padding:4px 10px;background:var(--bg-4);border:1px solid var(--border);border-radius:6px;font-size:11px;cursor:pointer;color:var(--text);">🔌 Test</button>
            <%= unless p.is_active do %>
            <button phx-click="set_active_provider" phx-value-id={p.id}
              style="padding:4px 10px;background:#f0fdf4;border:1px solid #bbf7d0;border-radius:6px;font-size:11px;cursor:pointer;color:#064e3b;">⚡ Activate</button>
            <% end %>
            <button phx-click="delete_provider" phx-value-id={p.id}
              data-confirm="Remove this provider?"
              style="padding:4px 10px;background:#fef2f2;border:1px solid #fecaca;border-radius:6px;font-size:11px;cursor:pointer;color:#991b1b;">🗑️</button>
          </div>
        </div>
        <% end %>

        <%= if @providers == [] do %>
        <div style="text-align:center;padding:24px;color:var(--text-2);font-size:13px;border:1px dashed var(--border);border-radius:8px;margin-bottom:16px;">
          <div style="font-size:28px;margin-bottom:8px;">☁️</div>
          Using PRZMA managed Linode S3. Add your own provider below.
        </div>
        <% end %>

        <div style="border-top:1px solid var(--border);padding-top:16px;margin-top:4px;">
          <div style="font-size:13px;font-weight:600;color:var(--text);margin-bottom:12px;">➕ Add Provider</div>
          <form phx-submit="save_provider" style="display:grid;grid-template-columns:1fr 1fr;gap:10px;">
            <div>
              <label style="font-size:11px;color:var(--text-2);display:block;margin-bottom:3px;">Provider Type *</label>
              <select name="adapter" style="width:100%;padding:8px;border:1px solid var(--border);border-radius:6px;font-size:12px;background:var(--bg-3);color:var(--text);">
                <option value="s3">AWS S3</option>
                <option value="minio">MinIO</option>
                <option value="r2">Cloudflare R2</option>
                <option value="backblaze">Backblaze B2</option>
              </select>
            </div>
            <div>
              <label style="font-size:11px;color:var(--text-2);display:block;margin-bottom:3px;">Display Label</label>
              <input name="label" placeholder="My Linode S3"
                style="width:100%;padding:8px;border:1px solid var(--border);border-radius:6px;font-size:12px;background:var(--bg-3);color:var(--text);" />
            </div>
            <div>
              <label style="font-size:11px;color:var(--text-2);display:block;margin-bottom:3px;">Bucket Name *</label>
              <input name="bucket" placeholder="my-bucket" required
                style="width:100%;padding:8px;border:1px solid var(--border);border-radius:6px;font-size:12px;background:var(--bg-3);color:var(--text);" />
            </div>
            <div>
              <label style="font-size:11px;color:var(--text-2);display:block;margin-bottom:3px;">Region</label>
              <input name="region" placeholder="us-east-1"
                style="width:100%;padding:8px;border:1px solid var(--border);border-radius:6px;font-size:12px;background:var(--bg-3);color:var(--text);" />
            </div>
            <div style="grid-column:1/-1;">
              <label style="font-size:11px;color:var(--text-2);display:block;margin-bottom:3px;">Endpoint URL (MinIO / R2 / Backblaze / Linode)</label>
              <input name="endpoint" placeholder="https://in-maa-1.linodeobjects.com"
                style="width:100%;padding:8px;border:1px solid var(--border);border-radius:6px;font-size:12px;background:var(--bg-3);color:var(--text);" />
            </div>
            <div>
              <label style="font-size:11px;color:var(--text-2);display:block;margin-bottom:3px;">Access Key ID</label>
              <input name="access_key" type="password" placeholder="AKIA..."
                style="width:100%;padding:8px;border:1px solid var(--border);border-radius:6px;font-size:12px;background:var(--bg-3);color:var(--text);" />
            </div>
            <div>
              <label style="font-size:11px;color:var(--text-2);display:block;margin-bottom:3px;">Secret Access Key</label>
              <input name="secret_key" type="password" placeholder="wJalr..."
                style="width:100%;padding:8px;border:1px solid var(--border);border-radius:6px;font-size:12px;background:var(--bg-3);color:var(--text);" />
            </div>
            <input type="hidden" name="provider_type" value="storage" />
            <div style="grid-column:1/-1;display:flex;align-items:center;gap:12px;">
              <button type="submit"
                style="padding:9px 22px;background:#1e40af;color:white;border:none;border-radius:8px;font-size:13px;font-weight:600;cursor:pointer;">
                💾 Save Provider
              </button>
              <span style="font-size:11px;color:var(--text-2);">🔒 Keys encrypted before storage. PRZMA never sees plaintext credentials.</span>
            </div>
          </form>
        </div>
      </div>

      <div style="background:var(--bg-2);border:1px solid #3b82f6;border-radius:10px;padding:14px;">
        <div style="font-size:13px;font-weight:600;color:var(--text);margin-bottom:6px;">📡 Active Storage</div>
        <%= if Enum.any?(@providers, & &1.is_active) do %>
          <% active = Enum.find(@providers, & &1.is_active) %>
          <div style="font-size:13px;color:var(--text);">Using: <strong><%= active.label || active.adapter %></strong> · <%= active.bucket %><%= if active.region, do: " · #{active.region}" %></div>
        <% else %>
          <div style="font-size:13px;color:var(--text);">Using: <strong>PRZMA Managed</strong> — Linode Object Storage · in-maa-1 · bucket: perkeep</div>
        <% end %>
      </div>
    </div>
    """
  end

  defp render_page(assigns) do
    ~H"""
    <div class="card">
      <div class="empty"><div class="empty-icon">📌</div><div class="empty-title">Select a page from the sidebar</div></div>
    </div>
    """
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp do_sort(f, "newest"), do: f
  defp do_sort(f, "oldest"), do: Enum.reverse(f)
  defp do_sort(f, "az"),     do: Enum.sort_by(f, &String.downcase(&1.filename || ""))
  defp do_sort(f, "za"),     do: Enum.sort_by(f, &String.downcase(&1.filename || ""), :desc)
  defp do_sort(f, _),        do: f

  defp ico(t) when is_binary(t) do
    cond do
      String.starts_with?(t, "audio/") -> "🎵"
      String.starts_with?(t, "video/") -> "🎬"
      String.starts_with?(t, "image/") -> "🖼️"
      String.contains?(t, "pdf")       -> "📕"
      String.contains?(t, "word")      -> "📝"
      String.contains?(t, "text")      -> "📄"
      true -> "📁"
    end
  end
  defp ico(_), do: "📁"

  defp ftype(t) when is_binary(t) do
    cond do
      String.starts_with?(t, "audio/") -> "Audio"
      String.starts_with?(t, "video/") -> "Video"
      String.starts_with?(t, "image/") -> "Image"
      String.contains?(t, "pdf")       -> "PDF"
      String.contains?(t, "document")  -> "Document"
      String.contains?(t, "text")      -> "Text"
      true -> "File"
    end
  end
  defp ftype(_), do: "File"

  defp fstatus("synced"),     do: "Uploaded"
  defp fstatus("indexed"),    do: "Ready"
  defp fstatus("processing"), do: "Processing"
  defp fstatus(s),            do: s || "Unknown"

  defp file_status_label("synced"),     do: "✓ Uploaded"
  defp file_status_label("indexed"),    do: "✓ Ready"
  defp file_status_label("processing"), do: "⏳ Processing"
  defp file_status_label(nil),          do: "Unknown"
  defp file_status_label(s),            do: s

  defp file_status_badge("indexed"),    do: "badge-green"
  defp file_status_badge("synced"),     do: "badge-blue"
  defp file_status_badge("processing"), do: "badge-amber"
  defp file_status_badge(_),            do: "badge-gray"

  defp sbadge("indexed"),    do: "badge-green"
  defp sbadge("synced"),     do: "badge-blue"
  defp sbadge("processing"), do: "badge-amber"
  defp sbadge(_),            do: "badge-gray"

  defp devico(d) when is_binary(d) do
    cond do
      String.contains?(d, "mobile") -> "📱"
      String.contains?(d, "tablet") -> "📟"
      true -> "💻"
    end
  end
  defp devico(_), do: "💻"

  defp devnm(nil), do: "Desktop"
  defp devnm(d),   do: String.capitalize(d)

  defp fdate(nil), do: "-"
  defp fdate(%NaiveDateTime{} = dt), do: NaiveDateTime.to_date(dt) |> Date.to_string()
  defp fdate(%DateTime{} = dt),      do: DateTime.to_date(dt) |> Date.to_string()
  defp fdate(_), do: "-"

  defp ago(nil), do: "Never"
  defp ago(%NaiveDateTime{} = dt) do
    d = NaiveDateTime.diff(NaiveDateTime.utc_now(), dt, :minute)
    cond do
      d < 1    -> "Just now"
      d < 60   -> "#{d}m ago"
      d < 1440 -> "#{div(d,60)}h ago"
      true     -> "#{div(d,1440)}d ago"
    end
  end
  defp ago(%DateTime{} = dt), do: ago(DateTime.to_naive(dt))
  defp ago(_), do: "-"

  defp fmtb(nil), do: ""
  defp fmtb(b) when b > 1_000_000, do: "#{Float.round(b/1_000_000,1)} MB"
  defp fmtb(b) when b > 1_000,     do: "#{Float.round(b/1_000,1)} KB"
  defp fmtb(b), do: "#{b} B"

  defp folder_icon("personal"), do: "🔐"
  defp folder_icon("private"),  do: "🔒"
  defp folder_icon("public"),   do: "🌍"
  defp folder_icon(_),          do: "🔐"

  defp folder_badge_style("personal"), do: "background:#fef3c7;color:#92400e;"
  defp folder_badge_style("private"),  do: "background:#ede9fe;color:#4c1d95;"
  defp folder_badge_style("public"),   do: "background:#d1fae5;color:#064e3b;"
  defp folder_badge_style(_),          do: "background:var(--bg-4);color:var(--text-2);"
end
