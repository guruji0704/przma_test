defmodule AlemWeb.StudioLive do
  use AlemWeb, :live_view
  import Ecto.Query
  alias Alem.Schemas.Document
  alias Alem.Repo
  require Logger

  @impl true
  def mount(%{"id" => doc_id}, session, socket) do
    user = get_user(session)
    if is_nil(user), do: {:ok, redirect(socket, to: "/panel/login")}, else: load_doc(socket, user, doc_id)
  end

  def mount(_params, session, socket) do
    user = get_user(session)
    if is_nil(user) do
      {:ok, redirect(socket, to: "/panel/login")}
    else
      {:ok,
       socket
       |> assign(:user,        user)
       |> assign(:doc,         nil)
       |> assign(:tool,        :document)
       |> assign(:save_status, :idle)
       |> assign(:save_msg,    "Ready")
       |> assign(:zoom,        100)
       |> assign(:page_title,  "PRZMA Studio")}
    end
  end

  defp get_user(session) do
    case session["user_id"] do
      nil -> nil
      uid -> try do Repo.get(Alem.Pleroma.User, uid) rescue _ -> nil end
    end
  end

  defp load_doc(socket, user, doc_id) do
    doc = try do
      Repo.one(from d in Document,
        where: d.id == ^doc_id and d.user_id == ^user.id,
        select: %{id: d.id, filename: d.filename, content_type: d.content_type,
                  object_key: d.object_key, status: d.status, inserted_at: d.inserted_at})
    rescue _ -> nil end

    if is_nil(doc) do
      {:ok, redirect(socket, to: "/panel")}
    else
      url = presign(doc.object_key)
      {:ok,
       socket
       |> assign(:user,        user)
       |> assign(:doc,         Map.put(doc, :url, url))
       |> assign(:tool,        detect_tool(doc.content_type))
       |> assign(:save_status, :idle)
       |> assign(:save_msg,    "Ready")
       |> assign(:zoom,        100)
       |> assign(:page_title,  "PRZMA Studio — #{doc.filename}")}
    end
  end

  defp detect_tool(ct) when is_binary(ct) do
    cond do
      String.starts_with?(ct, "image/")           -> :image
      String.starts_with?(ct, "video/")           -> :video
      String.starts_with?(ct, "audio/")           -> :audio
      ct == "application/pdf" or String.contains?(ct, "pdf") -> :pdf
      true -> :document
    end
  end
  defp detect_tool(_), do: :document

  # ── Events ─────────────────────────────────────────────────────────────────

  @impl true
  def handle_event("switch_tool", %{"tool" => t}, socket) do
    {:noreply, assign(socket, :tool, String.to_existing_atom(t))}
  rescue _ -> {:noreply, socket} end

  def handle_event("zoom", %{"dir" => dir}, socket) do
    z = socket.assigns.zoom
    new_z = case dir do
      "in"    -> min(z + 10, 200)
      "out"   -> max(z - 10, 50)
      "reset" -> 100
      _       -> z
    end
    {:noreply, assign(socket, :zoom, new_z)}
  end

  def handle_event("save_content", %{"content" => content, "format" => fmt}, socket) do
    user = socket.assigns.user
    doc  = socket.assigns.doc
    socket = assign(socket, save_status: :saving, save_msg: "Saving...")
    {:noreply, socket |> start_async(:do_save, fn -> do_save(user, doc, content, fmt) end)}
  end

  def handle_event("save_content", params, socket) do
    content = Map.get(params, "content", "")
    fmt     = Map.get(params, "format", "html")
    handle_event("save_content", %{"content" => content, "format" => fmt}, socket)
  end

  @impl true
  def handle_async(:do_save, {:ok, result}, socket) do
    case result do
      {:ok, new_doc} ->
        url = presign(new_doc.object_key)
        {:noreply,
         socket
         |> assign(:doc,         Map.put(new_doc, :url, url))
         |> assign(:save_status, :saved)
         |> assign(:save_msg,    "✓ Saved to S3 · PostgreSQL · LanceDB")}
      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:save_status, :error)
         |> assign(:save_msg,    "✕ #{reason}")}
    end
  end

  def handle_async(:do_save, {:exit, reason}, socket) do
    {:noreply, socket |> assign(:save_status, :error) |> assign(:save_msg, "✕ #{inspect(reason)}")}
  end

  defp do_save(user, existing_doc, content, fmt) do
    try do
      {bytes, content_type, filename} = build_file(content, fmt, existing_doc)
      doc_id = Ecto.UUID.generate()
      bucket = System.get_env("AWS_S3_BUCKET", "perkeep")
      s3_key = "user/#{user.id}/documents/#{doc_id}/#{filename}"

      case ExAws.S3.put_object(bucket, s3_key, bytes, content_type: content_type)
           |> ExAws.request(virtual_host: false) do
        {:ok, _} -> :ok
        {:error, e} -> throw({:s3_error, inspect(e)})
      end

      now = DateTime.utc_now() |> DateTime.truncate(:second)
      new_doc = Repo.insert!(%Document{
        id: doc_id, tenant_id: "default", user_id: user.id,
        filename: filename, object_key: s3_key,
        content_type: content_type, status: "synced",
        inserted_at: now, updated_at: now
      })

      try do
        cls = %{"seven_p_primary" => "product", "preserve_primary" => "engagement", "light_element" => "transform"}
        vec = Alem.Lance.VectorEncoder.encode(bytes, content_type, cls)
        did = user.did_id || user.id
        Alem.Lance.DISSupervisor.ensure_writer(did)
        Alem.LanceDB.insert_with_vector("perception_events", vec,
          Jason.encode!(%{"id" => doc_id, "verb" => "Edit", "media_type" => content_type,
            "filename" => filename, "seven_p_primary" => "product",
            "preserve_primary" => "engagement", "light_element" => "transform", "user_did" => did}))
      rescue e -> Logger.warning("[Studio] LanceDB: #{Exception.message(e)}") end

      {:ok, %{id: new_doc.id, filename: new_doc.filename, content_type: new_doc.content_type,
              object_key: new_doc.object_key, status: new_doc.status, inserted_at: new_doc.inserted_at}}
    rescue e -> {:error, Exception.message(e)}
    catch {:s3_error, r} -> {:error, "S3: #{r}"}
    end
  end

  defp build_file(content, "html", doc) do
    base = if doc, do: Path.rootname(doc.filename), else: "document"
    html = """
    <!DOCTYPE html><html><head><meta charset="utf-8"><title>#{base}</title>
    <style>body{font-family:Georgia,serif;max-width:820px;margin:48px auto;padding:0 28px;line-height:1.85;color:#111;font-size:14px}
    h1{font-size:26px;font-weight:700;margin:24px 0 12px}h2{font-size:20px;font-weight:600;margin:20px 0 10px}
    h3{font-size:16px;font-weight:600;margin:16px 0 8px}p{margin:9px 0}
    table{border-collapse:collapse;width:100%;margin:16px 0}td,th{border:1px solid #ddd;padding:8px 12px}
    blockquote{border-left:3px solid #5c73f2;margin:16px 0;padding:8px 16px;background:#f5f7ff;color:#444}
    code{background:#f1f3f9;padding:2px 6px;border-radius:3px;font-family:monospace;font-size:13px}
    pre{background:#1e1e2e;color:#cdd6f4;padding:16px;border-radius:6px;overflow:auto}
    img{max-width:100%;height:auto}hr{border:none;border-top:1px solid #e0e0e0;margin:20px 0}</style>
    </head><body>#{content}</body></html>
    """
    {html, "text/html", "#{base}-edited.html"}
  end

  defp build_file(content, "text", doc) do
    base = if doc, do: Path.rootname(doc.filename), else: "text"
    {content, "text/plain", "#{base}-edited.txt"}
  end

  defp build_file(content, "image_base64", doc) do
    base = if doc, do: Path.rootname(doc.filename), else: "image"
    case String.split(content, ",", parts: 2) do
      [_h, data] -> {Base.decode64!(data), "image/png", "#{base}-edited.png"}
      _          -> {content, "image/png", "#{base}-edited.png"}
    end
  end

  defp build_file(c, _, doc), do: build_file(c, "html", doc)

  defp presign(nil), do: nil
  defp presign(key) do
    bucket = System.get_env("AWS_S3_BUCKET", "perkeep")
    host   = System.get_env("AWS_S3_ENDPOINT", "in-maa-1.linodeobjects.com")
             |> String.replace(~r/^https?:\/\//, "") |> String.trim_trailing("/")
    region = System.get_env("AWS_DEFAULT_REGION", "in-maa-1")
    cfg    = ExAws.Config.new(:s3, scheme: "https://", host: host, region: region, port: 443)
    case ExAws.S3.presigned_url(cfg, :get, bucket, key, expires_in: 3600) do
      {:ok, u} -> String.replace(u, ~r/^http:\/\//, "https://")
      _ -> nil
    end
  end

  defp is_pdf(t) when is_binary(t), do: String.contains?(t, "pdf")
  defp is_pdf(_), do: false

  # ── Render ─────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <style>
      /* ══ TOKENS ══ */
      :root,[data-theme="dark"]{
        --bg:#0d0f17;--bg-2:#12151f;--bg-3:#191d2a;--bg-4:#1f2435;--bg-5:#252b3d;
        --border:rgba(255,255,255,.06);--border-2:rgba(255,255,255,.11);
        --text:#eef0f8;--text-2:#8892aa;--text-3:#454e63;
        --primary:#5c6ef5;--primary-d:rgba(92,110,245,.15);--primary-g:rgba(92,110,245,.3);
        --accent:#a78bfa;--accent-d:rgba(167,139,250,.15);
        --green:#10b981;--green-d:rgba(16,185,129,.12);
        --amber:#f59e0b;--red:#ef4444;--red-d:rgba(239,68,68,.12);
        --shadow:0 2px 8px rgba(0,0,0,.5),0 8px 32px rgba(0,0,0,.3);
        --r:8px;--r-sm:5px;--r-lg:12px;
        color-scheme:dark;
      }
      [data-theme="light"]{
        --bg:#f0f2f8;--bg-2:#fff;--bg-3:#f6f7fc;--bg-4:#eef0f8;--bg-5:#e8eaf4;
        --border:rgba(0,0,0,.07);--border-2:rgba(0,0,0,.12);
        --text:#0e1017;--text-2:#555e75;--text-3:#9aa1b4;
        --primary:#4a5ee8;--primary-d:rgba(74,94,232,.1);--primary-g:rgba(74,94,232,.25);
        --accent:#7c3aed;--accent-d:rgba(124,58,237,.1);
        --green:#059669;--green-d:rgba(5,150,105,.1);
        --amber:#d97706;--red:#dc2626;--red-d:rgba(220,38,38,.1);
        --shadow:0 2px 8px rgba(0,0,0,.08),0 8px 32px rgba(0,0,0,.06);
        color-scheme:light;
      }

      *,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
      html,body{height:100%;overflow:hidden;-webkit-font-smoothing:antialiased}
      body{font-family:'DM Sans',system-ui,sans-serif;background:var(--bg);color:var(--text)}
      ::-webkit-scrollbar{width:5px;height:5px}
      ::-webkit-scrollbar-thumb{background:var(--bg-5);border-radius:99px}
      ::selection{background:var(--primary);color:#fff}

      /* ══ SHELL ══ */
      .studio{display:flex;flex-direction:column;height:100vh;overflow:hidden}

      /* ══ TOP BAR ══ */
      .topbar{
        height:46px;background:var(--bg-2);border-bottom:1px solid var(--border);
        display:flex;align-items:center;padding:0 12px;gap:8px;flex-shrink:0;
        z-index:50;
      }
      .logo-wrap{display:flex;align-items:center;gap:8px;margin-right:4px}
      .logo-gem{
        width:26px;height:26px;border-radius:6px;flex-shrink:0;
        background:linear-gradient(135deg,var(--primary),var(--accent));
        display:flex;align-items:center;justify-content:center;
        font-size:13px;color:#fff;font-weight:700;
        box-shadow:0 2px 8px var(--primary-g);
      }
      .logo-name{font-size:13px;font-weight:700;color:var(--text)}
      .topbar-sep{width:1px;height:18px;background:var(--border-2);margin:0 4px;flex-shrink:0}
      .topbar-file{
        font-size:12px;color:var(--text-2);max-width:240px;
        overflow:hidden;text-overflow:ellipsis;white-space:nowrap;
      }
      .topbar-sp{flex:1}

      /* Save chip */
      .save-chip{
        font-size:11px;padding:3px 10px;border-radius:99px;
        font-weight:500;transition:all .25s;white-space:nowrap;
      }
      .sc-idle   {background:var(--bg-3);color:var(--text-3)}
      .sc-saving {background:var(--amber);color:#fff;animation:pulse 1s infinite}
      .sc-saved  {background:var(--green-d);color:var(--green)}
      .sc-error  {background:var(--red-d);color:var(--red)}
      @keyframes pulse{0%,100%{opacity:1}50%{opacity:.6}}

      /* Topbar buttons */
      .tb{
        height:28px;padding:0 10px;border-radius:var(--r-sm);
        font-size:11px;font-weight:600;cursor:pointer;
        border:none;font-family:inherit;transition:all .15s;
        display:flex;align-items:center;gap:4px;flex-shrink:0;
      }
      .tb-save{background:var(--primary);color:#fff}
      .tb-save:hover{filter:brightness(1.12);box-shadow:0 0 0 3px var(--primary-g)}
      .tb-ghost{background:transparent;color:var(--text-2);border:1px solid var(--border-2)}
      .tb-ghost:hover{background:var(--bg-3);color:var(--text)}
      .tb-icon{
        width:28px;height:28px;border-radius:var(--r-sm);
        background:var(--bg-3);border:1px solid var(--border);
        display:flex;align-items:center;justify-content:center;
        cursor:pointer;font-size:13px;color:var(--text-2);transition:all .15s;
      }
      .tb-icon:hover{background:var(--bg-4);color:var(--text)}

      /* ══ BODY ══ */
      .body{display:flex;flex:1;overflow:hidden}

      /* ══ SIDEBAR ══ */
      .sidebar{
        width:180px;background:var(--bg-2);border-right:1px solid var(--border);
        display:flex;flex-direction:column;flex-shrink:0;overflow:hidden;
      }
      .sb-sec{padding:10px 8px 3px}
      .sb-sec-lbl{font-size:9px;font-weight:700;color:var(--text-3);text-transform:uppercase;letter-spacing:1.1px;padding:0 6px}
      .sb-btn{
        display:flex;align-items:center;gap:8px;padding:7px 10px;
        border-radius:var(--r-sm);font-size:12px;color:var(--text-2);
        cursor:pointer;border:none;background:none;width:100%;text-align:left;
        font-family:inherit;font-weight:500;transition:all .12s;
        white-space:nowrap;overflow:hidden;
      }
      .sb-btn:hover{background:var(--bg-3);color:var(--text)}
      .sb-btn.on{background:var(--primary-d);color:var(--primary)}
      .sb-icon{font-size:13px;width:16px;text-align:center;flex-shrink:0}

      .sb-filecard{
        margin:8px;padding:11px 12px;background:var(--bg-3);
        border:1px solid var(--border);border-radius:var(--r-sm);
      }
      .sb-file-lbl{font-size:9px;font-weight:700;color:var(--text-3);text-transform:uppercase;letter-spacing:.5px;margin-bottom:6px}
      .sb-file-name{font-size:11px;font-weight:600;color:var(--text);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
      .sb-file-type{font-size:10px;color:var(--text-3);margin-top:2px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
      .sb-badge{
        display:inline-flex;align-items:center;padding:2px 7px;
        border-radius:99px;font-size:9px;font-weight:700;margin-top:7px;
      }
      .sb-pipeline{padding:8px 14px;display:flex;flex-direction:column;gap:5px}
      .pipe-dot{font-size:10px;color:var(--text-2);display:flex;align-items:center;gap:6px}
      .dot-green{color:var(--green);font-size:8px}

      .sb-foot{margin-top:auto;border-top:1px solid var(--border);padding:6px}
      .sb-back{display:flex;align-items:center;gap:7px;padding:7px 10px;border-radius:var(--r-sm);font-size:12px;color:var(--text-2);text-decoration:none;transition:all .12s;font-weight:500}
      .sb-back:hover{background:var(--bg-3);color:var(--text)}

      /* ══ MAIN EDITOR ══ */
      .main{flex:1;display:flex;flex-direction:column;overflow:hidden;min-width:0}

      /* ── Toolbar ── */
      .toolbar{
        background:var(--bg-2);border-bottom:1px solid var(--border);
        padding:5px 10px;display:flex;align-items:center;
        gap:3px;flex-wrap:wrap;flex-shrink:0;min-height:40px;
      }
      .t{
        padding:4px 7px;border-radius:4px;border:1px solid transparent;
        background:transparent;color:var(--text);font-size:12px;cursor:pointer;
        font-family:inherit;transition:all .1s;min-width:26px;text-align:center;
        height:26px;display:flex;align-items:center;justify-content:center;gap:3px;
      }
      .t:hover{background:var(--bg-3);border-color:var(--border)}
      .t.on{background:var(--primary-d);color:var(--primary);border-color:var(--primary)}
      .t-sep{width:1px;height:18px;background:var(--border-2);margin:0 2px;flex-shrink:0}
      .t-sel{
        padding:3px 7px;border-radius:4px;border:1px solid var(--border);
        background:var(--bg-3);color:var(--text);font-size:11px;
        cursor:pointer;font-family:inherit;outline:none;height:26px;
      }
      .t-color{width:26px;height:26px;border-radius:4px;cursor:pointer;border:1px solid var(--border);padding:2px}

      /* Zoom controls */
      .zoom-row{display:flex;align-items:center;gap:2px;margin-left:auto;flex-shrink:0}
      .zoom-lbl{font-size:11px;color:var(--text-3);min-width:36px;text-align:center}

      /* ── Canvas Area ── */
      .canvas-area{flex:1;overflow:auto;background:var(--bg);position:relative}

      /* ── Doc Editor ── */
      .doc-outer{display:flex;justify-content:center;padding:32px 20px;min-height:100%}
      .doc-page{
        background:#fff;color:#111;
        min-height:1056px;padding:72px 88px;
        box-shadow:0 4px 40px rgba(0,0,0,.25);
        border-radius:3px;outline:none;
        font-family:Georgia,'Times New Roman',serif;
        font-size:13.5px;line-height:1.9;
        caret-color:#333;word-wrap:break-word;
        transition:box-shadow .2s;
      }
      .doc-page:focus{box-shadow:0 4px 40px rgba(0,0,0,.3),0 0 0 2px var(--primary-g)}
      .doc-page h1{font-size:26px;font-weight:700;margin:20px 0 12px;line-height:1.25}
      .doc-page h2{font-size:20px;font-weight:600;margin:18px 0 10px;line-height:1.3}
      .doc-page h3{font-size:16px;font-weight:600;margin:14px 0 8px}
      .doc-page p{margin:8px 0}
      .doc-page blockquote{border-left:3px solid var(--primary);margin:16px 0;padding:10px 18px;background:#f5f7ff;color:#444;border-radius:0 4px 4px 0}
      .doc-page pre{background:#1e1e2e;color:#cdd6f4;padding:16px;border-radius:6px;overflow:auto;font-size:12px}
      .doc-page code{background:#f0f2fa;padding:2px 6px;border-radius:3px;font-family:monospace;font-size:12px}
      .doc-page table{border-collapse:collapse;width:100%;margin:14px 0}
      .doc-page td,.doc-page th{border:1px solid #ddd;padding:8px 12px}
      .doc-page img{max-width:100%;border-radius:4px}
      .doc-page a{color:#5c6ef5}
      @media (max-width:700px){.doc-page{padding:24px 18px;min-height:auto}}

      /* ── Image Editor ── */
      .img-stage{display:flex;justify-content:center;align-items:flex-start;padding:24px;min-height:100%}
      #img-canvas{
        max-width:100%;border-radius:var(--r);
        box-shadow:0 8px 40px rgba(0,0,0,.35);
        display:none;cursor:crosshair;
      }
      .img-empty{text-align:center;padding:64px 24px;color:var(--text-3)}
      .img-empty-icon{font-size:52px;margin-bottom:16px;opacity:.5}

      /* Text overlay on canvas */
      #img-text-overlay{
        position:absolute;top:0;left:0;width:100%;height:100%;
        pointer-events:none;z-index:10;
      }

      /* ── Audio Editor ── */
      .audio-stage{
        display:flex;flex-direction:column;align-items:center;
        justify-content:center;padding:40px 24px;gap:24px;min-height:400px;
      }
      .audio-art{
        width:180px;height:180px;border-radius:50%;flex-shrink:0;
        background:linear-gradient(135deg,var(--primary-d),var(--accent-d));
        border:2px solid var(--border-2);
        display:flex;flex-direction:column;align-items:center;justify-content:center;
        box-shadow:0 8px 32px var(--primary-g);
      }
      .audio-title{font-size:14px;font-weight:600;color:var(--text);text-align:center;max-width:400px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
      .audio-sub{font-size:12px;color:var(--text-3);margin-top:6px}
      #studio-audio{width:100%;max-width:520px}
      .waveform-wrap{width:100%;max-width:520px;height:64px;background:var(--bg-3);border-radius:var(--r);overflow:hidden;border:1px solid var(--border);position:relative}
      #waveform{width:100%;height:100%}

      /* ── Video ── */
      .video-stage{display:flex;flex-direction:column;align-items:center;padding:24px;gap:12px}
      #studio-video{max-width:100%;max-height:calc(100vh - 250px);border-radius:var(--r);box-shadow:0 8px 40px rgba(0,0,0,.4);background:#000}
      .video-name{font-size:13px;font-weight:600;color:var(--text-2)}

      /* ── PDF ── */
      .pdf-wrap{width:100%;height:100%}
      #pdf-frame{width:100%;height:calc(100vh - 170px);border:none;display:block}

      /* ── Text/Code Editor ── */
      .code-wrap{height:100%;display:flex;flex-direction:column}
      #code-editor{
        flex:1;width:100%;border:none;outline:none;resize:none;
        font-family:'DM Mono','Fira Code',monospace;font-size:13px;line-height:1.7;
        background:var(--bg);color:var(--text);padding:20px 24px;
        tab-size:2;
      }

      /* ── Empty ── */
      .studio-empty{text-align:center;padding:60px 24px;color:var(--text-3)}
      .studio-empty-icon{font-size:48px;margin-bottom:16px;opacity:.55}
      .studio-empty-title{font-size:16px;font-weight:600;color:var(--text-2);margin-bottom:8px}
      .studio-empty-sub{font-size:13px}

      /* ══ STATUS BAR ══ */
      .statusbar{
        height:22px;background:var(--primary);color:rgba(255,255,255,.75);
        display:flex;align-items:center;padding:0 14px;gap:14px;
        font-size:10px;font-weight:500;flex-shrink:0;
      }
      .sb-accent{color:#fff;font-weight:700;opacity:1}
      .sb-pipe{opacity:.4}
    </style>

    <div class="studio">

      <!-- ══ TOP BAR ══ -->
      <header class="topbar">
        <div class="logo-wrap">
          <div class="logo-gem">✏</div>
          <span class="logo-name">PRZMA Studio</span>
        </div>
        <div class="topbar-sep"></div>
        <span class="topbar-file"><%= if @doc, do: @doc.filename, else: "New Document" %></span>
        <span class="topbar-sp"></span>

        <!-- Save status -->
        <span class={"save-chip #{save_cls(@save_status)}"} id="save-status-chip">
          <%= @save_msg %>
        </span>

        <!-- Hidden save form -->
        <form id="save-form" phx-submit="save_content" style="display:none">
          <textarea id="save-input" name="content"></textarea>
          <input type="hidden" name="format" value="html" id="save-format"/>
        </form>

        <button class="tb tb-save" onclick="studioSave()" type="button">💾 Save</button>
        <button class="tb-icon" onclick="toggleTheme()" id="theme-btn" title="Toggle theme">◑</button>
        <a href="/panel" class="tb tb-ghost" style="text-decoration:none">← Panel</a>
      </header>

      <div class="body">

        <!-- ══ SIDEBAR ══ -->
        <nav class="sidebar">
          <div class="sb-sec"><div class="sb-sec-lbl">Tools</div></div>
          <button class={"sb-btn #{if @tool == :document, do: "on"}"} phx-click="switch_tool" phx-value-tool="document">
            <span class="sb-icon">📝</span> Document
          </button>
          <button class={"sb-btn #{if @tool == :image, do: "on"}"} phx-click="switch_tool" phx-value-tool="image">
            <span class="sb-icon">🎨</span> Image
          </button>
          <button class={"sb-btn #{if @tool == :audio, do: "on"}"} phx-click="switch_tool" phx-value-tool="audio">
            <span class="sb-icon">🎵</span> Audio
          </button>
          <button class={"sb-btn #{if @tool == :video, do: "on"}"} phx-click="switch_tool" phx-value-tool="video">
            <span class="sb-icon">🎬</span> Video
          </button>
          <button class={"sb-btn #{if @tool == :pdf, do: "on"}"} phx-click="switch_tool" phx-value-tool="pdf">
            <span class="sb-icon">📕</span> PDF
          </button>
          <button class={"sb-btn #{if @tool == :code, do: "on"}"} phx-click="switch_tool" phx-value-tool="code">
            <span class="sb-icon">⌨</span> Code / Text
          </button>

          <%= if @doc do %>
            <div class="sb-filecard" style="margin-top:12px">
              <div class="sb-file-lbl">File</div>
              <div class="sb-file-name"><%= @doc.filename %></div>
              <div class="sb-file-type"><%= @doc.content_type || "unknown" %></div>
              <div>
                <span class="sb-badge" style="background:var(--primary-d);color:var(--primary)">v1 current</span>
              </div>
            </div>
            <div class="sb-sec"><div class="sb-sec-lbl">Pipeline</div></div>
            <div class="sb-pipeline">
              <div class="pipe-dot"><span class="dot-green">●</span> S3 Object Storage</div>
              <div class="pipe-dot"><span class="dot-green">●</span> PostgreSQL</div>
              <div class="pipe-dot"><span class="dot-green">●</span> LanceDB 446-dim</div>
            </div>
          <% end %>

          <div class="sb-foot">
            <a href="/panel" class="sb-back">← Back to Panel</a>
          </div>
        </nav>

        <!-- ══ MAIN ══ -->
        <div class="main">

          <!-- ── Doc Toolbar ── -->
          <div class="toolbar" id="toolbar-document" style={"display:#{if @tool == :document, do: "flex", else: "none"}"}>
            <select class="t-sel" onchange="execCmd('fontName',this.value)" title="Font Family">
              <option value="Georgia">Georgia</option>
              <option value="Arial">Arial</option>
              <option value="'Times New Roman'">Times NR</option>
              <option value="'Courier New'">Courier</option>
              <option value="Verdana">Verdana</option>
              <option value="Helvetica">Helvetica</option>
            </select>
            <select class="t-sel" onchange="setFontSize(this.value)" title="Font Size">
              <option value="1">8</option><option value="2">10</option>
              <option value="3" selected>12</option><option value="4">14</option>
              <option value="5">18</option><option value="6">24</option><option value="7">36</option>
            </select>
            <div class="t-sep"></div>
            <button class="t" onclick="execCmd('bold')" title="Bold Ctrl+B"><b>B</b></button>
            <button class="t" onclick="execCmd('italic')" title="Italic Ctrl+I"><i>I</i></button>
            <button class="t" onclick="execCmd('underline')" title="Underline Ctrl+U"><u>U</u></button>
            <button class="t" onclick="execCmd('strikeThrough')" title="Strikethrough"><s>S</s></button>
            <button class="t" onclick="execCmd('superscript')" title="Superscript" style="font-size:10px">x²</button>
            <button class="t" onclick="execCmd('subscript')" title="Subscript" style="font-size:10px">x₂</button>
            <div class="t-sep"></div>
            <button class="t" onclick="execCmd('justifyLeft')" title="Left">⇤</button>
            <button class="t" onclick="execCmd('justifyCenter')" title="Center">≡</button>
            <button class="t" onclick="execCmd('justifyRight')" title="Right">⇥</button>
            <button class="t" onclick="execCmd('justifyFull')" title="Justify">☰</button>
            <div class="t-sep"></div>
            <button class="t" onclick="execCmd('insertUnorderedList')" title="Bullets">• —</button>
            <button class="t" onclick="execCmd('insertOrderedList')" title="Numbers">1.</button>
            <button class="t" onclick="execCmd('outdent')" title="Outdent">⇐</button>
            <button class="t" onclick="execCmd('indent')" title="Indent">⇒</button>
            <div class="t-sep"></div>
            <button class="t" onclick="fmtBlock('h1')" title="Heading 1" style="font-weight:800;font-size:11px">H1</button>
            <button class="t" onclick="fmtBlock('h2')" title="Heading 2" style="font-weight:700;font-size:11px">H2</button>
            <button class="t" onclick="fmtBlock('h3')" title="Heading 3" style="font-weight:600;font-size:11px">H3</button>
            <button class="t" onclick="fmtBlock('p')"  title="Paragraph" style="font-size:11px">¶</button>
            <button class="t" onclick="fmtBlock('blockquote')" title="Blockquote" style="font-size:11px">"</button>
            <div class="t-sep"></div>
            <input class="t-color" type="color" title="Text Color" onchange="execCmd('foreColor',this.value)" value="#000000"/>
            <input class="t-color" type="color" title="Highlight" onchange="execCmd('hiliteColor',this.value)" value="#fff176" style="background:#fff176"/>
            <div class="t-sep"></div>
            <button class="t" onclick="insertTable()" title="Insert Table" style="font-size:11px">⊞ Table</button>
            <button class="t" onclick="insertLink()" title="Insert Link" style="font-size:11px">🔗</button>
            <button class="t" onclick="insertImg()" title="Insert Image" style="font-size:11px">🖼</button>
            <button class="t" onclick="insertCode()" title="Code Block" style="font-size:11px">⌨</button>
            <button class="t" onclick="insertHR()" title="Divider" style="font-size:11px">—</button>
            <div class="t-sep"></div>
            <button class="t" onclick="execCmd('undo')" title="Undo Ctrl+Z">↩</button>
            <button class="t" onclick="execCmd('redo')" title="Redo Ctrl+Shift+Z">↪</button>
            <div class="t-sep"></div>
            <button class="t" onclick="exportHTML()" style="font-size:10px;color:var(--text-2)" title="Export HTML">↓ HTML</button>
            <button class="t" onclick="window.print()" style="font-size:10px;color:var(--text-2)" title="Print / Save PDF">🖨 PDF</button>
            <!-- Zoom -->
            <div class="zoom-row">
              <button class="t" phx-click="zoom" phx-value-dir="out" title="Zoom Out">−</button>
              <span class="zoom-lbl"><%= @zoom %>%</span>
              <button class="t" phx-click="zoom" phx-value-dir="in" title="Zoom In">+</button>
              <button class="t" phx-click="zoom" phx-value-dir="reset" title="Reset Zoom" style="font-size:10px">⊙</button>
            </div>
          </div>

          <!-- ── Image Toolbar ── -->
          <div class="toolbar" id="toolbar-image" style={"display:#{if @tool == :image, do: "flex", else: "none"}"}>
            <button class="t" onclick="imgRotate(-90)" title="Rotate Left 90°">↺ -90°</button>
            <button class="t" onclick="imgRotate(90)"  title="Rotate Right 90°">↻ +90°</button>
            <button class="t" onclick="imgFlip('h')"   title="Flip Horizontal">⇔</button>
            <button class="t" onclick="imgFlip('v')"   title="Flip Vertical">⇕</button>
            <div class="t-sep"></div>
            <span style="font-size:10px;color:var(--text-3)">Brightness</span>
            <input type="range" id="sl-b" min="-100" max="100" value="0" oninput="applyFilters()" style="width:70px"/>
            <span style="font-size:10px;color:var(--text-3)">Contrast</span>
            <input type="range" id="sl-c" min="-100" max="100" value="0" oninput="applyFilters()" style="width:70px"/>
            <span style="font-size:10px;color:var(--text-3)">Saturate</span>
            <input type="range" id="sl-s" min="0" max="200" value="100" oninput="applyFilters()" style="width:70px"/>
            <span style="font-size:10px;color:var(--text-3)">Blur</span>
            <input type="range" id="sl-blur" min="0" max="10" value="0" step="0.5" oninput="applyFilters()" style="width:60px"/>
            <div class="t-sep"></div>
            <button class="t" onclick="imgFilter('grayscale(1)')" style="font-size:10px">Grayscale</button>
            <button class="t" onclick="imgFilter('sepia(1)')"     style="font-size:10px">Sepia</button>
            <button class="t" onclick="imgFilter('invert(1)')"    style="font-size:10px">Invert</button>
            <button class="t" onclick="imgFilter('hue-rotate(90deg)')" style="font-size:10px">Hue+90</button>
            <button class="t" onclick="resetFilters()"            style="font-size:10px;color:var(--red)">Reset</button>
            <div class="t-sep"></div>
            <button class="t" onclick="addTextToImage()" title="Add text to image" style="font-size:10px">T Text</button>
            <button class="t" onclick="cropImage()" title="Crop (select area)" style="font-size:10px">✂ Crop</button>
            <div class="t-sep"></div>
            <button class="t" onclick="downloadImg()" style="font-size:10px;background:var(--primary-d);color:var(--primary)">↓ Download PNG</button>
          </div>

          <!-- ── Audio Toolbar ── -->
          <div class="toolbar" id="toolbar-audio" style={"display:#{if @tool == :audio, do: "flex", else: "none"}"}>
            <span style="font-size:12px;color:var(--text-2)">🎵 Audio Player</span>
            <div class="t-sep"></div>
            <span style="font-size:11px;color:var(--text-3)">Playback:</span>
            <button class="t" onclick="setPlayRate(0.5)" style="font-size:10px">0.5×</button>
            <button class="t" onclick="setPlayRate(1.0)" style="font-size:10px">1×</button>
            <button class="t" onclick="setPlayRate(1.5)" style="font-size:10px">1.5×</button>
            <button class="t" onclick="setPlayRate(2.0)" style="font-size:10px">2×</button>
            <div class="t-sep"></div>
            <%= if @doc && @doc.url do %>
              <a href={@doc.url} download={if @doc, do: @doc.filename} class="t" style="font-size:10px;text-decoration:none;color:var(--primary)">↓ Download</a>
            <% end %>
          </div>

          <!-- ── Video Toolbar ── -->
          <div class="toolbar" id="toolbar-video" style={"display:#{if @tool == :video, do: "flex", else: "none"}"}>
            <span style="font-size:12px;color:var(--text-2)">🎬 Video Player</span>
            <div class="t-sep"></div>
            <button class="t" onclick="setVidRate(0.5)" style="font-size:10px">0.5×</button>
            <button class="t" onclick="setVidRate(1.0)" style="font-size:10px">1×</button>
            <button class="t" onclick="setVidRate(1.5)" style="font-size:10px">1.5×</button>
            <button class="t" onclick="setVidRate(2.0)" style="font-size:10px">2×</button>
            <div class="t-sep"></div>
            <button class="t" onclick="vidPip()" title="Picture in Picture" style="font-size:10px">⧉ PiP</button>
            <button class="t" onclick="vidFullscreen()" title="Fullscreen" style="font-size:10px">⛶ Full</button>
            <%= if @doc && @doc.url do %>
              <a href={@doc.url} download={if @doc, do: @doc.filename} class="t" style="font-size:10px;text-decoration:none;color:var(--primary)">↓ Download</a>
            <% end %>
          </div>

          <!-- ── Code Toolbar ── -->
          <div class="toolbar" id="toolbar-code" style={"display:#{if @tool == :code, do: "flex", else: "none"}"}>
            <span style="font-size:12px;color:var(--text-2)">⌨ Code / Text Editor</span>
            <div class="t-sep"></div>
            <select class="t-sel" id="code-lang" style="font-size:11px">
              <option value="plain">Plain Text</option>
              <option value="elixir">Elixir</option>
              <option value="javascript">JavaScript</option>
              <option value="python">Python</option>
              <option value="json">JSON</option>
              <option value="html">HTML</option>
              <option value="css">CSS</option>
            </select>
            <div class="t-sep"></div>
            <button class="t" onclick="codeFormat()" style="font-size:10px">⚡ Format</button>
            <button class="t" onclick="codeCopy()" style="font-size:10px">📋 Copy</button>
            <button class="t" onclick="codeLineNums()" style="font-size:10px" id="ln-btn">## Lines</button>
            <div class="t-sep"></div>
            <span style="font-size:10px;color:var(--text-3)" id="code-stats">0 lines · 0 chars</span>
          </div>

          <!-- ── PDF Toolbar ── -->
          <div class="toolbar" id="toolbar-pdf" style={"display:#{if @tool == :pdf, do: "flex", else: "none"}"}>
            <span style="font-size:12px;color:var(--text-2)">📕 PDF Viewer</span>
            <div class="t-sep"></div>
            <%= if @doc && @doc.url do %>
              <a href={@doc.url} target="_blank" class="t" style="font-size:10px;text-decoration:none">↗ Open Full</a>
              <a href={@doc.url} download={if @doc, do: @doc.filename} class="t" style="font-size:10px;text-decoration:none;color:var(--primary)">↓ Download</a>
            <% end %>
          </div>

          <!-- ── Canvas Area ── -->
          <div class="canvas-area" id="studio-canvas">

            <!-- Document Panel -->
            <div class="doc-outer" id="panel-document" style={"display:#{if @tool == :document, do: "flex", else: "none"}"}>
              <div style={"width:100%;max-width:#{min(820, round(820 * @zoom / 100))}px"}>
                <div id="doc-editor" class="doc-page"
                     contenteditable="true" spellcheck="true"
                     data-file-url={if @doc, do: (@doc.url || ""), else: ""}
                     data-content-type={if @doc, do: (@doc.content_type || ""), else: ""}
                     onkeyup="markDirty()" oninput="markDirty()"
                     onkeydown="handleEditorKey(event)">
                  <%= if @doc do %>
                    <p style="color:#aaa;font-style:italic" id="doc-init">⏳ Loading...</p>
                  <% else %>
                    <h1>Untitled Document</h1>
                    <p>Start writing here. Use the toolbar or keyboard shortcuts:</p>
                    <p><strong>Ctrl+B</strong> Bold &nbsp;&nbsp; <strong>Ctrl+I</strong> Italic &nbsp;&nbsp; <strong>Ctrl+S</strong> Save &nbsp;&nbsp; <strong>Ctrl+Z</strong> Undo</p>
                  <% end %>
                </div>
              </div>
            </div>

            <!-- Image Panel -->
            <div class="img-stage" id="panel-image" style={"display:#{if @tool == :image, do: "flex", else: "none"}"}>
              <div style="position:relative;display:inline-block">
                <canvas id="img-canvas"></canvas>
                <canvas id="img-draw-layer" style="position:absolute;top:0;left:0;display:none"></canvas>
              </div>
              <div id="img-empty" class="img-empty">
                <div class="img-empty-icon">🎨</div>
                <div style="font-size:16px;font-weight:600;color:var(--text-2);margin-bottom:8px">Image Editor</div>
                <div style="font-size:13px">Open an image from My Files → click ✏ Edit</div>
              </div>
            </div>

            <!-- Audio Panel -->
            <div class="audio-stage" id="panel-audio" style={"display:#{if @tool == :audio, do: "flex", else: "none"}"}>
              <div class="audio-art">
                <span style="font-size:64px;opacity:.8">🎵</span>
              </div>
              <div class="audio-title"><%= if @doc, do: @doc.filename, else: "No audio loaded" %></div>
              <div class="audio-sub">Switch to Audio tool from My Files → click ✏ Edit</div>
              <div class="waveform-wrap">
                <canvas id="waveform"></canvas>
              </div>
              <%= if @doc && @doc.url && String.starts_with?(@doc.content_type || "", "audio/") do %>
                <audio id="studio-audio" controls preload="metadata" style="width:100%;max-width:520px">
                  <source src={@doc.url} type={@doc.content_type}/>
                </audio>
              <% end %>
            </div>

            <!-- Video Panel -->
            <div class="video-stage" id="panel-video" style={"display:#{if @tool == :video, do: "flex", else: "none"}"}>
              <%= if @doc && @doc.url && String.starts_with?(@doc.content_type || "", "video/") do %>
                <video id="studio-video" controls preload="metadata" autoplay>
                  <source src={@doc.url} type={@doc.content_type}/>
                </video>
                <div class="video-name"><%= @doc.filename %></div>
              <% else %>
                <div class="studio-empty">
                  <div class="studio-empty-icon">🎬</div>
                  <div class="studio-empty-title">Video Player</div>
                  <div class="studio-empty-sub">Open a video from My Files → click ✏ Edit</div>
                </div>
              <% end %>
            </div>

            <!-- Code/Text Panel -->
            <div class="code-wrap" id="panel-code" style={"display:#{if @tool == :code, do: "flex", else: "none"}"}>
              <textarea id="code-editor"
                data-file-url={if @doc, do: (@doc.url || ""), else: ""}
                placeholder="Start typing or load a text/code file..."
                oninput="codeStats()" onkeydown="handleCodeKey(event)"
                spellcheck="false"></textarea>
            </div>

            <!-- PDF Panel -->
            <div class="pdf-wrap" id="panel-pdf" style={"display:#{if @tool == :pdf, do: "block", else: "none"}"}>
              <%= if @doc && @doc.url && is_pdf(@doc.content_type) do %>
                <iframe id="pdf-frame" src={@doc.url} title={@doc.filename}></iframe>
              <% else %>
                <div class="studio-empty">
                  <div class="studio-empty-icon">📕</div>
                  <div class="studio-empty-title">PDF Viewer</div>
                  <div class="studio-empty-sub">Open a PDF from My Files → click ✏ Edit</div>
                </div>
              <% end %>
            </div>

          </div><!-- /canvas-area -->
        </div><!-- /main -->
      </div><!-- /body -->

      <!-- ══ STATUS BAR ══ -->
      <div class="statusbar">
        <span class="sb-accent">PRZMA Studio v2.0</span>
        <span class="sb-pipe">|</span>
        <span id="sb-words">0 words</span>
        <span class="sb-pipe">|</span>
        <span id="sb-chars">0 chars</span>
        <span class="sb-pipe">|</span>
        <span id="sb-cursor">Ln 1, Col 1</span>
        <span style="margin-left:auto;opacity:.6">S3 · PostgreSQL · LanceDB 446-dim HOLNN</span>
      </div>

    </div><!-- /studio -->

    <script>
      /* ══════════════════════════════════════════
         THEME
      ══════════════════════════════════════════ */
      function getTheme() { return document.documentElement.getAttribute('data-theme')||'dark'; }
      function toggleTheme() {
        var t = getTheme()==='dark' ? 'light' : 'dark';
        document.documentElement.setAttribute('data-theme', t);
        localStorage.setItem('przma-theme', t);
        document.getElementById('theme-btn').textContent = t==='dark' ? '☀' : '◑';
      }
      (function(){
        var t = localStorage.getItem('przma-theme') ||
                (window.matchMedia('(prefers-color-scheme:light)').matches ? 'light' : 'dark');
        document.documentElement.setAttribute('data-theme', t);
        var b = document.getElementById('theme-btn');
        if(b) b.textContent = t==='dark' ? '☀' : '◑';
      })();

      /* ══════════════════════════════════════════
         SAVE
      ══════════════════════════════════════════ */
      var editorDirty = false, saveTimer = null;

      function studioSave() {
        var chip = document.getElementById('save-status-chip');
        if(chip){ chip.textContent='⏳ Saving...'; chip.className='save-chip sc-saving'; }

        var fmt='html', content='';
        var tool = getCurrentTool();

        if(tool==='document'){
          var ed = document.getElementById('doc-editor');
          content = ed ? ed.innerHTML : '';
          fmt = 'html';
        } else if(tool==='image'){
          var c = document.getElementById('img-canvas');
          if(c && c.style.display!=='none'){
            var baked = getBakedCanvas();
            content = baked.toDataURL('image/png');
            fmt = 'image_base64';
          }
        } else if(tool==='code'){
          var ce = document.getElementById('code-editor');
          content = ce ? ce.value : '';
          fmt = 'text';
        } else {
          if(chip){ chip.textContent='Nothing to save'; chip.className='save-chip sc-idle'; }
          return;
        }

        var inp = document.getElementById('save-input');
        var fmtInp = document.getElementById('save-format');
        var form = document.getElementById('save-form');
        if(!inp || !form) return;
        inp.value = content;
        if(fmtInp) fmtInp.value = fmt;
        form.dispatchEvent(new Event('submit', {bubbles:true, cancelable:true}));
        editorDirty = false;
      }

      function getCurrentTool() {
        var panels = ['document','image','audio','video','code','pdf'];
        for(var i=0;i<panels.length;i++){
          var p = document.getElementById('panel-'+panels[i]);
          if(p && p.style.display!=='none') return panels[i];
        }
        return 'document';
      }

      function autoSave() { if(editorDirty) studioSave(); }
      function markDirty() {
        editorDirty = true;
        var chip = document.getElementById('save-status-chip');
        if(chip && !chip.textContent.includes('Saving')){ chip.textContent='● Unsaved'; chip.className='save-chip sc-saving'; }
        clearTimeout(saveTimer);
        saveTimer = setTimeout(autoSave, 4000);
        updateStats();
      }

      // Notify panel on save
      var _ch = null;
      try { _ch = new BroadcastChannel('przma-studio'); } catch(e){}
      window.addEventListener('phx:update', function() {
        var chip = document.getElementById('save-status-chip');
        if(chip && chip.textContent.indexOf('Saved to S3')!==-1 && !chip._done){
          chip._done = true;
          if(_ch) _ch.postMessage({type:'file_saved',ts:Date.now()});
          localStorage.setItem('przma-file-saved', Date.now().toString());
          setTimeout(function(){ if(chip) chip._done=false; }, 5000);
        }
      });

      /* ══════════════════════════════════════════
         DOCUMENT EDITOR
      ══════════════════════════════════════════ */
      function execCmd(cmd, val) {
        var ed = document.getElementById('doc-editor');
        if(!ed) return;
        ed.focus();
        document.execCommand(cmd, false, val||null);
        markDirty();
      }
      function setFontSize(v) { execCmd('fontSize',v); }
      function fmtBlock(t)    { execCmd('formatBlock',t); }

      function insertTable() {
        var r=parseInt(prompt('Rows:','3')||'3');
        var c=parseInt(prompt('Columns:','3')||'3');
        var h='<table border="1" style="border-collapse:collapse;width:100%;margin:14px 0">';
        for(var i=0;i<r;i++){h+='<tr>';for(var j=0;j<c;j++)h+='<td style="padding:8px 12px;border:1px solid #ddd;min-width:80px">&nbsp;</td>';h+='</tr>';}
        h+='</table><p></p>';
        execCmd('insertHTML',h);
      }
      function insertLink() {
        var u=prompt('URL:','https://'); if(u) execCmd('createLink',u);
      }
      function insertImg() {
        var u=prompt('Image URL:','https://'); if(u) execCmd('insertHTML','<img src="'+u+'" style="max-width:100%;border-radius:4px"/>');
      }
      function insertCode() {
        execCmd('insertHTML','<pre style="background:#1e1e2e;color:#cdd6f4;padding:14px;border-radius:6px;font-family:monospace">// code here</pre><p></p>');
      }
      function insertHR() { execCmd('insertHTML','<hr style="border:none;border-top:1px solid #ddd;margin:18px 0"/><p></p>'); }

      function exportHTML() {
        var c=document.getElementById('doc-editor').innerHTML;
        var h='<!DOCTYPE html><html><head><meta charset="utf-8"><title>Document</title><style>body{font-family:Georgia,serif;max-width:820px;margin:48px auto;padding:0 28px;line-height:1.85;color:#111}table{border-collapse:collapse;width:100%}td,th{border:1px solid #ddd;padding:8px 12px}blockquote{border-left:3px solid #5c6ef5;padding:10px 18px;background:#f5f7ff}pre{background:#1e1e2e;color:#cdd6f4;padding:14px;border-radius:6px}img{max-width:100%}</style></head><body>'+c+'</body></html>';
        var b=new Blob([h],{type:'text/html'});
        var a=document.createElement('a');a.href=URL.createObjectURL(b);a.download='document.html';a.click();
      }

      function handleEditorKey(e) {
        if(e.ctrlKey||e.metaKey){
          switch(e.key.toLowerCase()){
            case 'b':e.preventDefault();execCmd('bold');break;
            case 'i':e.preventDefault();execCmd('italic');break;
            case 'u':e.preventDefault();execCmd('underline');break;
            case 's':e.preventDefault();studioSave();break;
            case 'z':e.preventDefault();execCmd(e.shiftKey?'redo':'undo');break;
            case 'k':e.preventDefault();insertLink();break;
          }
        }
      }

      function updateStats() {
        var ed=document.getElementById('doc-editor');
        if(!ed) return;
        var t=(ed.innerText||'').trim();
        var w=t?t.split(/\s+/).length:0;
        var sw=document.getElementById('sb-words');
        var sc=document.getElementById('sb-chars');
        if(sw)sw.textContent=w+' words';
        if(sc)sc.textContent=t.length+' chars';
      }

      /* ══════════════════════════════════════════
         IMAGE EDITOR
      ══════════════════════════════════════════ */
      var imgState={rotation:0,flipH:false,flipV:false,img:null,extraFilter:'',drawing:false,textMode:false};

      function loadImage(src) {
        var img=new Image();
        img.crossOrigin='anonymous';
        img.onload=function(){
          imgState.img=img; imgState.rotation=0; imgState.flipH=false; imgState.flipV=false;
          renderImage();
          document.getElementById('img-empty').style.display='none';
          document.getElementById('img-canvas').style.display='block';
        };
        img.onerror=function(){ document.getElementById('img-empty').style.display='block'; };
        img.src=src;
      }

      function renderImage() {
        if(!imgState.img) return;
        var img=imgState.img;
        var canvas=document.getElementById('img-canvas');
        var rad=imgState.rotation*Math.PI/180;
        var sw=Math.abs(Math.cos(rad))*img.naturalWidth+Math.abs(Math.sin(rad))*img.naturalHeight;
        var sh=Math.abs(Math.sin(rad))*img.naturalWidth+Math.abs(Math.cos(rad))*img.naturalHeight;
        canvas.width=sw; canvas.height=sh;
        var ctx=canvas.getContext('2d');
        ctx.save();
        ctx.translate(sw/2,sh/2); ctx.rotate(rad);
        ctx.scale(imgState.flipH?-1:1, imgState.flipV?-1:1);
        ctx.drawImage(img,-img.naturalWidth/2,-img.naturalHeight/2);
        ctx.restore();
        applyFilters();
      }

      function getBakedCanvas() {
        var src=document.getElementById('img-canvas');
        var b=document.getElementById('sl-b').value;
        var c=document.getElementById('sl-c').value;
        var s=document.getElementById('sl-s').value;
        var bl=document.getElementById('sl-blur').value;
        var f='brightness('+(1+b/100)+') contrast('+(1+c/100)+') saturate('+(s/100)+') blur('+bl+'px)';
        if(imgState.extraFilter) f+=' '+imgState.extraFilter;
        var out=document.createElement('canvas');
        out.width=src.width; out.height=src.height;
        var ctx=out.getContext('2d');
        ctx.filter=f;
        ctx.drawImage(src,0,0);
        // Merge draw layer
        var dl=document.getElementById('img-draw-layer');
        if(dl && dl.style.display!=='none'){ ctx.filter='none'; ctx.drawImage(dl,0,0); }
        return out;
      }

      function imgRotate(d){ imgState.rotation=(imgState.rotation+d+360)%360; renderImage(); }
      function imgFlip(dir){ if(dir==='h')imgState.flipH=!imgState.flipH; else imgState.flipV=!imgState.flipV; renderImage(); }
      function applyFilters(){
        var b=document.getElementById('sl-b').value;
        var c=document.getElementById('sl-c').value;
        var s=document.getElementById('sl-s').value;
        var bl=document.getElementById('sl-blur').value;
        var f='brightness('+(1+b/100)+') contrast('+(1+c/100)+') saturate('+(s/100)+') blur('+bl+'px)';
        if(imgState.extraFilter) f+=' '+imgState.extraFilter;
        document.getElementById('img-canvas').style.filter=f;
      }
      function imgFilter(f){ imgState.extraFilter=f; applyFilters(); }
      function resetFilters(){
        imgState.extraFilter='';
        ['sl-b','sl-c'].forEach(function(id){document.getElementById(id).value=0;});
        document.getElementById('sl-s').value=100;
        document.getElementById('sl-blur').value=0;
        document.getElementById('img-canvas').style.filter='none';
      }
      function downloadImg(){
        var b=getBakedCanvas();
        var a=document.createElement('a');a.download='edited.png';a.href=b.toDataURL('image/png');a.click();
      }
      function addTextToImage(){
        var txt=prompt('Text to add:',''); if(!txt) return;
        var canvas=document.getElementById('img-canvas');
        var dl=document.getElementById('img-draw-layer');
        dl.width=canvas.width; dl.height=canvas.height;
        dl.style.display='block'; dl.style.width=canvas.width+'px'; dl.style.height=canvas.height+'px';
        var ctx=dl.getContext('2d');
        ctx.clearRect(0,0,dl.width,dl.height);
        ctx.font='bold '+Math.max(24,Math.round(canvas.height/20))+'px Arial';
        ctx.fillStyle='rgba(255,255,255,0.9)';
        ctx.strokeStyle='rgba(0,0,0,0.5)'; ctx.lineWidth=2;
        var x=40, y=canvas.height-40;
        ctx.strokeText(txt,x,y); ctx.fillText(txt,x,y);
      }
      function cropImage(){
        alert('Crop: Click and drag on the image to select area (coming soon). Use Download to export current view.');
      }

      /* ══════════════════════════════════════════
         AUDIO
      ══════════════════════════════════════════ */
      function setPlayRate(r){
        var a=document.getElementById('studio-audio');
        if(a) a.playbackRate=r;
      }
      function drawWaveform(audio){
        var canvas=document.getElementById('waveform');
        if(!canvas||!window.AudioContext) return;
        var ctx=canvas.getContext('2d');
        canvas.width=canvas.offsetWidth||500; canvas.height=64;
        // Simple animated waveform during playback
        audio.addEventListener('timeupdate',function(){
          var w=canvas.width,h=canvas.height;
          ctx.clearRect(0,0,w,h);
          ctx.fillStyle='var(--bg-3)'; ctx.fillRect(0,0,w,h);
          var pct=audio.duration?audio.currentTime/audio.duration:0;
          // Progress line
          ctx.fillStyle='rgba(92,110,245,0.3)'; ctx.fillRect(0,0,w*pct,h);
          ctx.fillStyle='var(--primary)'; ctx.fillRect(w*pct-1,0,2,h);
          // Pseudo-waveform bars
          ctx.fillStyle='rgba(92,110,245,0.6)';
          for(var i=0;i<w;i+=4){
            var amp=Math.sin(i*0.05+audio.currentTime)*0.3+0.5+Math.random()*0.2;
            var bh=Math.round(h*amp*0.8);
            ctx.fillRect(i,h/2-bh/2,2,bh);
          }
        });
      }

      /* ══════════════════════════════════════════
         VIDEO
      ══════════════════════════════════════════ */
      function setVidRate(r){
        var v=document.getElementById('studio-video');
        if(v) v.playbackRate=r;
      }
      function vidPip(){
        var v=document.getElementById('studio-video');
        if(v&&document.pictureInPictureEnabled) v.requestPictureInPicture().catch(function(){});
      }
      function vidFullscreen(){
        var v=document.getElementById('studio-video');
        if(v){if(v.requestFullscreen)v.requestFullscreen();else if(v.webkitRequestFullscreen)v.webkitRequestFullscreen();}
      }

      /* ══════════════════════════════════════════
         CODE / TEXT EDITOR
      ══════════════════════════════════════════ */
      var showLineNums=false;
      function codeStats(){
        var ce=document.getElementById('code-editor');
        if(!ce) return;
        var v=ce.value;
        var lines=v.split('\n').length;
        var chars=v.length;
        var el=document.getElementById('code-stats');
        if(el) el.textContent=lines+' lines · '+chars+' chars';
        // cursor
        var cur=document.getElementById('sb-cursor');
        if(cur){
          var s=ce.selectionStart;
          var before=v.substring(0,s);
          var ln=before.split('\n').length;
          var col=s-before.lastIndexOf('\n');
          cur.textContent='Ln '+ln+', Col '+col;
        }
        markDirty();
      }
      function handleCodeKey(e){
        if(e.key==='Tab'){
          e.preventDefault();
          var ce=document.getElementById('code-editor');
          var s=ce.selectionStart, end=ce.selectionEnd;
          ce.value=ce.value.substring(0,s)+'  '+ce.value.substring(end);
          ce.selectionStart=ce.selectionEnd=s+2;
          codeStats();
        }
        if((e.ctrlKey||e.metaKey)&&e.key.toLowerCase()==='s'){e.preventDefault();studioSave();}
      }
      function codeFormat(){
        var ce=document.getElementById('code-editor');
        if(!ce) return;
        var lang=document.getElementById('code-lang').value;
        if(lang==='json'){
          try{ ce.value=JSON.stringify(JSON.parse(ce.value),null,2); codeStats(); }
          catch(e){ alert('Invalid JSON: '+e.message); }
        } else {
          alert('Auto-format available for JSON. For other languages, use Ctrl+S to save.');
        }
      }
      function codeCopy(){
        var ce=document.getElementById('code-editor');
        if(ce){ navigator.clipboard.writeText(ce.value).then(function(){ alert('Copied to clipboard!'); }); }
      }
      function codeLineNums(){
        showLineNums=!showLineNums;
        var ce=document.getElementById('code-editor');
        if(showLineNums){
          ce.style.paddingLeft='52px';
          var btn=document.getElementById('ln-btn');
          if(btn) btn.classList.add('on');
        } else {
          ce.style.paddingLeft='24px';
          var btn=document.getElementById('ln-btn');
          if(btn) btn.classList.remove('on');
        }
      }

      /* ══════════════════════════════════════════
         FILE LOADER (on mount)
      ══════════════════════════════════════════ */
      document.addEventListener('DOMContentLoaded', function(){
        var ed=document.getElementById('doc-editor');
        if(!ed) return;
        var url=ed.getAttribute('data-file-url');
        var ct=ed.getAttribute('data-content-type')||'';
        var init=document.getElementById('doc-init');

        if(!url){ updateStats(); return; }

        if(ct.indexOf('text')!==-1 || ct.indexOf('json')!==-1 || ct.indexOf('xml')!==-1){
          // Load into code editor too
          fetch(url)
            .then(function(r){return r.text();})
            .then(function(t){
              if(init)init.remove();
              ed.innerText=t;
              var ce=document.getElementById('code-editor');
              if(ce) ce.value=t;
              updateStats(); codeStats();
            }).catch(function(){ if(init)init.textContent='⚠ Could not load'; });

        } else if(ct.indexOf('wordprocessingml')!==-1||ct.indexOf('msword')!==-1){
          if(window.mammoth){
            fetch(url)
              .then(function(r){return r.arrayBuffer();})
              .then(function(b){return mammoth.convertToHtml({arrayBuffer:b});})
              .then(function(res){
                if(init)init.remove();
                ed.innerHTML=res.value;
                updateStats();
              }).catch(function(){if(init)init.textContent='⚠ Could not render DOCX';});
          }

        } else if(ct.indexOf('image')!==-1){
          if(init)init.remove();
          ed.innerHTML='<p style="color:#aaa;font-size:12px">Image loaded in Image Editor →</p>';
          loadImage(url);
          updateStats();

        } else if(ct.indexOf('audio')!==-1){
          if(init)init.remove();
          ed.innerHTML='<p style="color:#aaa;font-size:12px">Audio loaded in Audio Player →</p>';
          var a=document.getElementById('studio-audio');
          if(a) drawWaveform(a);

        } else if(ct.indexOf('video')!==-1){
          if(init)init.remove();
          ed.innerHTML='<p style="color:#aaa;font-size:12px">Video loaded in Video Player →</p>';

        } else {
          if(init)init.textContent='File loaded. Switch to appropriate editor from the sidebar.';
        }
        updateStats();
      });

      // Save keyboard shortcut globally
      document.addEventListener('keydown', function(e){
        if((e.ctrlKey||e.metaKey)&&e.key.toLowerCase()==='s'){ e.preventDefault(); studioSave(); }
      });
    </script>
    """
  end

  defp save_cls(:idle),   do: "sc-idle"
  defp save_cls(:saving), do: "sc-saving"
  defp save_cls(:saved),  do: "sc-saved"
  defp save_cls(:error),  do: "sc-error"
  defp save_cls(_),       do: "sc-idle"
end