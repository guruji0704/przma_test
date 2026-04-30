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
       |> assign(:user, user)
       |> assign(:doc, nil)
       |> assign(:tool, :document)
       |> assign(:save_status, :idle)
       |> assign(:save_msg, "Ready")
       |> assign(:page_title, "PRZMA Studio")}
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
      Repo.one(
        from d in Document,
        where: d.id == ^doc_id and d.user_id == ^user.id,
        select: %{id: d.id, filename: d.filename, content_type: d.content_type,
                  object_key: d.object_key, status: d.status, inserted_at: d.inserted_at}
      )
    rescue _ -> nil end

    if is_nil(doc) do
      {:ok, redirect(socket, to: "/panel")}
    else
      url = presign(doc.object_key)
      {:ok,
       socket
       |> assign(:user, user)
       |> assign(:doc, Map.put(doc, :url, url))
       |> assign(:tool, detect_tool(doc.content_type))
       |> assign(:save_status, :idle)
       |> assign(:save_msg, "Ready")
       |> assign(:page_title, "PRZMA Studio — #{doc.filename}")}
    end
  end

  defp detect_tool(ct) when is_binary(ct) do
    cond do
      String.starts_with?(ct, "image/") -> :image
      ct == "application/pdf" or String.contains?(ct, "pdf") -> :pdf
      true -> :document
    end
  end
  defp detect_tool(_), do: :document

  # ── Events ─────────────────────────────────────────────────────────────────

  @impl true
  def handle_event("switch_tool", %{"tool" => t}, socket) do
    {:noreply, assign(socket, :tool, String.to_existing_atom(t))}
  rescue _ -> {:noreply, socket}
  end

  def handle_event("save_content", %{"content" => content, "format" => fmt}, socket) do
    user = socket.assigns.user
    doc  = socket.assigns.doc

    socket = assign(socket, save_status: :saving, save_msg: "Saving...")
    {:noreply, socket |> start_async(:do_save, fn ->
      do_save(user, doc, content, fmt)
    end)}
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
        new_doc_with_url = Map.put(new_doc, :url, url)
        {:noreply,
         socket
         |> assign(:doc, new_doc_with_url)
         |> assign(:save_status, :saved)
         |> assign(:save_msg, "✓ Saved to S3 + PostgreSQL + LanceDB")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:save_status, :error)
         |> assign(:save_msg, "✕ Save failed: #{reason}")}
    end
  end

  def handle_async(:do_save, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:save_status, :error)
     |> assign(:save_msg, "✕ Save error: #{inspect(reason)}")}
  end

  defp do_save(user, existing_doc, content, fmt) do
    try do
      # Convert content to bytes
      {file_bytes, content_type, filename} = build_file(content, fmt, existing_doc)

      doc_id   = Ecto.UUID.generate()
      bucket   = System.get_env("AWS_S3_BUCKET", "perkeep")
      s3_key   = "user/#{user.id}/documents/#{doc_id}/#{filename}"

      # Upload to S3
      case ExAws.S3.put_object(bucket, s3_key, file_bytes, content_type: content_type)
           |> ExAws.request(virtual_host: false) do
        {:ok, _} -> :ok
        {:error, e} -> throw({:s3_error, inspect(e)})
      end

      # Save to PostgreSQL
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      new_doc = Repo.insert!(%Document{
        id:           doc_id,
        tenant_id:    "default",
        user_id:      user.id,
        filename:     filename,
        object_key:   s3_key,
        content_type: content_type,
        status:       "synced",
        inserted_at:  now,
        updated_at:   now
      })

      # LanceDB vector
      try do
        cls = %{
          "seven_p_primary"  => "product",
          "preserve_primary" => "engagement",
          "light_element"    => "transform"
        }
        vec = Alem.Lance.VectorEncoder.encode(file_bytes, content_type, cls)
        did = user.did_id || user.id
        Alem.Lance.DISSupervisor.ensure_writer(did)
        Alem.LanceDB.insert_with_vector("perception_events", vec,
          Jason.encode!(%{
            "id" => doc_id, "verb" => "Edit",
            "media_type" => content_type, "filename" => filename,
            "seven_p_primary" => "product",
            "preserve_primary" => "engagement",
            "light_element" => "transform",
            "user_did" => did
          }))
      rescue e ->
        Logger.warning("[Studio] LanceDB save failed: #{Exception.message(e)}")
      end

      {:ok, %{id: new_doc.id, filename: new_doc.filename,
              content_type: new_doc.content_type,
              object_key: new_doc.object_key,
              status: new_doc.status,
              inserted_at: new_doc.inserted_at}}
    rescue e ->
      {:error, Exception.message(e)}
    catch
      {:s3_error, reason} -> {:error, "S3: #{reason}"}
    end
  end

  defp build_file(content, "html", existing_doc) do
    base = if existing_doc, do: Path.rootname(existing_doc.filename), else: "edited-document"
    filename = "#{base}-edited.html"
    html = """
    <!DOCTYPE html>
    <html><head>
    <meta charset="utf-8">
    <title>#{base}</title>
    <style>
      body { font-family: Georgia, serif; max-width: 800px; margin: 40px auto;
             padding: 0 24px; line-height: 1.8; color: #111; }
      table { border-collapse: collapse; width: 100%; }
      td, th { border: 1px solid #ccc; padding: 6px 10px; }
      img { max-width: 100%; height: auto; }
      h1,h2,h3 { margin: 20px 0 10px; } p { margin: 8px 0; }
    </style>
    </head><body>#{content}</body></html>
    """
    {html, "text/html", filename}
  end

  defp build_file(content, "text", existing_doc) do
    base = if existing_doc, do: Path.rootname(existing_doc.filename), else: "edited"
    {content, "text/plain", "#{base}-edited.txt"}
  end

  defp build_file(content, "image_base64", existing_doc) do
    # Convert base64 data URL to PNG bytes
    base = if existing_doc, do: Path.rootname(existing_doc.filename), else: "edited-image"
    filename = "#{base}-edited.png"
    case String.split(content, ",", parts: 2) do
      [_header, data] ->
        bytes = Base.decode64!(data)
        {bytes, "image/png", filename}
      _ ->
        {content, "image/png", filename}
    end
  end

  defp build_file(content, _, existing_doc) do
    build_file(content, "html", existing_doc)
  end

  defp presign(nil), do: nil
  defp presign(object_key) do
    bucket = System.get_env("AWS_S3_BUCKET", "perkeep")
    host   = System.get_env("AWS_S3_ENDPOINT", "in-maa-1.linodeobjects.com")
             |> String.replace(~r/^https?:\/\//, "")
             |> String.trim_trailing("/")
    region = System.get_env("AWS_DEFAULT_REGION", "in-maa-1")
    config = ExAws.Config.new(:s3, scheme: "https://", host: host, region: region, port: 443)
    case ExAws.S3.presigned_url(config, :get, bucket, object_key, expires_in: 3600) do
      {:ok, url} -> String.replace(url, ~r/^http:\/\//, "https://")
      _ -> nil
    end
  end

  # ── Render ─────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <style>
      :root, [data-theme="dark"] {
        --bg: #0c0e13; --bg-2: #13161e; --bg-3: #1a1e29; --bg-4: #222737;
        --border: rgba(255,255,255,0.07); --border-2: rgba(255,255,255,0.13);
        --text: #f0f2f8; --text-2: #8b92a9; --text-3: #4e566b;
        --primary: #5c73f2; --primary-d: rgba(92,115,242,0.15);
        --green: #10b981; --green-d: rgba(16,185,129,0.12);
        --amber: #f59e0b; --red: #ef4444; --red-d: rgba(239,68,68,0.12);
        --purple: #a78bfa; --r: 10px; --r-sm: 6px;
        --shadow: 0 1px 3px rgba(0,0,0,0.5), 0 4px 16px rgba(0,0,0,0.25);
        color-scheme: dark;
      }
      [data-theme="light"] {
        --bg: #f2f4f8; --bg-2: #fff; --bg-3: #f8f9fc; --bg-4: #eef0f6;
        --border: rgba(0,0,0,0.07); --border-2: rgba(0,0,0,0.13);
        --text: #0f1117; --text-2: #5a6172; --text-3: #9ca3b4;
        --primary: #4f63e8; --primary-d: rgba(79,99,232,0.1);
        --green: #059669; --green-d: rgba(5,150,105,0.1);
        --amber: #d97706; --red: #dc2626; --red-d: rgba(220,38,38,0.1);
        --purple: #7c3aed;
        color-scheme: light;
      }
      *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
      html, body { height: 100%; overflow: hidden; }
      body { font-family: 'DM Sans', system-ui, sans-serif; background: var(--bg); color: var(--text); }
      ::-webkit-scrollbar { width: 4px; height: 4px; }
      ::-webkit-scrollbar-thumb { background: var(--bg-4); border-radius: 99px; }

      /* ── Shell ── */
      .studio { display: flex; flex-direction: column; height: 100vh; overflow: hidden; }

      /* ── Top Bar ── */
      .studio-topbar {
        height: 48px; background: var(--bg-2); border-bottom: 1px solid var(--border);
        display: flex; align-items: center; padding: 0 14px; gap: 10px; flex-shrink: 0;
        z-index: 10;
      }
      .studio-logo { display: flex; align-items: center; gap: 8px; }
      .studio-logo-mark {
        width: 24px; height: 24px; border-radius: 5px;
        background: linear-gradient(135deg, var(--primary), var(--purple));
        display: flex; align-items: center; justify-content: center;
        font-size: 11px; color: #fff; font-weight: 700;
      }
      .studio-logo-name { font-size: 13px; font-weight: 700; color: var(--text); }
      .studio-divider { width: 1px; height: 20px; background: var(--border-2); margin: 0 4px; }
      .studio-filename { font-size: 13px; color: var(--text-2); max-width: 260px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      .studio-spacer { flex: 1; }
      .studio-status-chip {
        font-size: 11px; padding: 3px 10px; border-radius: 99px; font-weight: 500;
        transition: all 0.3s;
      }
      .sc-idle   { background: var(--bg-3); color: var(--text-3); }
      .sc-saving { background: var(--amber); color: #fff; animation: pulse 1s infinite; }
      .sc-saved  { background: var(--green-d); color: var(--green); }
      .sc-error  { background: var(--red-d); color: var(--red); }
      @keyframes pulse { 0%,100%{opacity:1} 50%{opacity:.6} }
      .topbar-btn {
        height: 30px; padding: 0 12px; border-radius: var(--r-sm);
        font-size: 12px; font-weight: 600; cursor: pointer;
        border: none; font-family: inherit; transition: all 0.15s;
        display: flex; align-items: center; gap: 5px;
      }
      .tb-primary { background: var(--primary); color: #fff; }
      .tb-primary:hover { filter: brightness(1.1); }
      .tb-ghost { background: transparent; color: var(--text-2); border: 1px solid var(--border-2); }
      .tb-ghost:hover { background: var(--bg-3); color: var(--text); }
      .tb-theme {
        width: 30px; height: 30px; border-radius: var(--r-sm);
        background: var(--bg-3); border: 1px solid var(--border);
        display: flex; align-items: center; justify-content: center;
        cursor: pointer; font-size: 14px; color: var(--text-2);
        transition: all 0.15s;
      }
      .tb-theme:hover { background: var(--bg-4); color: var(--text); }

      /* ── Body ── */
      .studio-body { display: flex; flex: 1; overflow: hidden; }

      /* ── Sidebar ── */
      .studio-sb {
        width: 180px; background: var(--bg-2); border-right: 1px solid var(--border);
        display: flex; flex-direction: column; flex-shrink: 0;
      }
      .sb-section { padding: 8px 8px 4px; }
      .sb-label { font-size: 9px; font-weight: 700; color: var(--text-3); text-transform: uppercase; letter-spacing: 1px; padding: 0 6px; }
      .sb-item {
        display: flex; align-items: center; gap: 8px;
        padding: 7px 10px; border-radius: var(--r-sm);
        font-size: 12px; color: var(--text-2); cursor: pointer;
        border: none; background: none; width: 100%; text-align: left;
        font-family: inherit; font-weight: 500; transition: all 0.15s;
      }
      .sb-item:hover { background: var(--bg-3); color: var(--text); }
      .sb-item.on { background: var(--primary-d); color: var(--primary); }
      .sb-icon { font-size: 13px; width: 16px; text-align: center; }
      .sb-foot { margin-top: auto; padding: 8px; border-top: 1px solid var(--border); }
      .sb-file-info { padding: 10px 12px; margin: 8px; background: var(--bg-3); border-radius: var(--r-sm); border: 1px solid var(--border); }
      .sb-file-name { font-size: 11px; font-weight: 600; color: var(--text); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      .sb-file-type { font-size: 10px; color: var(--text-3); margin-top: 2px; }

      /* ── Toolbar ── */
      .studio-toolbar {
        background: var(--bg-2); border-bottom: 1px solid var(--border);
        padding: 5px 10px; display: flex; align-items: center;
        gap: 3px; flex-wrap: wrap; flex-shrink: 0; min-height: 40px;
      }
      .tb { padding: 4px 7px; border-radius: 4px; border: 1px solid transparent; background: transparent; color: var(--text); font-size: 12px; cursor: pointer; font-family: inherit; transition: all 0.12s; min-width: 26px; text-align: center; }
      .tb:hover { background: var(--bg-3); border-color: var(--border); }
      .tb.on { background: var(--primary-d); color: var(--primary); border-color: var(--primary); }
      .tb-sep { width: 1px; height: 18px; background: var(--border-2); margin: 0 3px; flex-shrink: 0; }
      .tb-sel {
        padding: 3px 6px; border-radius: 4px; border: 1px solid var(--border);
        background: var(--bg-3); color: var(--text); font-size: 11px;
        cursor: pointer; font-family: inherit; outline: none;
      }
      .tb-color {
        width: 26px; height: 26px; border-radius: 4px; cursor: pointer;
        border: 1px solid var(--border); padding: 2px;
      }

      /* ── Canvas ── */
      .studio-canvas {
        flex: 1; overflow: auto; background: var(--bg);
        display: flex; justify-content: center;
        padding: 24px 20px;
      }

      /* Document editor */
      .doc-wrap { width: 100%; max-width: 820px; }
      .doc-page {
        background: #fff; color: #111;
        min-height: 1060px; padding: 72px 80px;
        box-shadow: 0 4px 32px rgba(0,0,0,0.2);
        border-radius: 2px; outline: none;
        font-family: Georgia, 'Times New Roman', serif;
        font-size: 14px; line-height: 1.85;
        caret-color: #333;
      }
      .doc-page:focus { box-shadow: 0 4px 32px rgba(0,0,0,0.25), 0 0 0 2px var(--primary-d); }
      [data-theme="light"] .doc-page { background: #fff; }
      [data-theme="dark"]  .doc-page { background: #fff; color: #111; }
      @media (max-width: 700px) { .doc-page { padding: 24px 20px; } }

      /* Image editor */
      .img-wrap { width: 100%; max-width: 800px; display: flex; flex-direction: column; align-items: center; gap: 16px; }
      #img-canvas { max-width: 100%; border-radius: var(--r); box-shadow: 0 4px 32px rgba(0,0,0,0.2); display: none; }
      .img-controls { display: flex; gap: 8px; flex-wrap: wrap; justify-content: center; }
      .img-slider { display: flex; align-items: center; gap: 8px; font-size: 11px; color: var(--text-2); }
      .img-slider input { width: 80px; }

      /* PDF viewer */
      .pdf-wrap { width: 100%; max-width: 860px; }
      .pdf-frame { width: 100%; height: calc(100vh - 200px); border: none; border-radius: var(--r); box-shadow: 0 4px 32px rgba(0,0,0,0.2); }

      /* Empty state */
      .studio-empty { text-align: center; padding: 60px 24px; color: var(--text-3); }
      .studio-empty-icon { font-size: 48px; margin-bottom: 16px; opacity: .6; }
      .studio-empty-title { font-size: 16px; font-weight: 600; color: var(--text-2); margin-bottom: 8px; }
      .studio-empty-sub { font-size: 13px; }

      /* Status bar */
      .studio-statusbar {
        height: 24px; background: var(--primary); color: rgba(255,255,255,.8);
        display: flex; align-items: center; padding: 0 14px; gap: 16px;
        font-size: 10px; flex-shrink: 0; font-weight: 500;
      }
      .statusbar-pill { opacity: .7; }
      .statusbar-accent { opacity: 1; color: #fff; font-weight: 600; }
    </style>

    <div class="studio">
      <!-- Top Bar -->
      <header class="studio-topbar">
        <div class="studio-logo">
          <div class="studio-logo-mark">✏</div>
          <span class="studio-logo-name">PRZMA Studio</span>
        </div>
        <div class="studio-divider"></div>
        <span class="studio-filename"><%= if @doc, do: @doc.filename, else: "New Document" %></span>
        <span class="studio-spacer"></span>

        <!-- Status chip -->
        <span class={"studio-status-chip #{status_class(@save_status)}"} id="save-status-chip">
          <%= @save_msg %>
        </span>

        <!-- Save button -->
        <!-- Hidden save form - reliable LiveView bridge -->
        <form id="save-form" phx-submit="save_content" style="display:none">
          <textarea id="save-input" name="content"></textarea>
          <input type="hidden" name="format" value="html" id="save-format"/>
        </form>
        <button class="topbar-btn tb-primary" id="btn-save" onclick="studioSave()" type="button">
          💾 Save
        </button>

        <!-- Theme toggle -->
        <button class="tb-theme" onclick="toggleTheme()" id="theme-btn" title="Toggle theme">◑</button>

        <!-- Back to panel -->
        <a href="/panel" class="topbar-btn tb-ghost">← Panel</a>
      </header>

      <div class="studio-body">
        <!-- Sidebar -->
        <nav class="studio-sb">
          <div class="sb-section">
            <div class="sb-label">Editor</div>
          </div>
          <button class={"sb-item #{if @tool == :document, do: "on"}"} phx-click="switch_tool" phx-value-tool="document">
            <span class="sb-icon">📝</span> Document
          </button>
          <button class={"sb-item #{if @tool == :image, do: "on"}"} phx-click="switch_tool" phx-value-tool="image">
            <span class="sb-icon">🖼️</span> Image
          </button>
          <button class={"sb-item #{if @tool == :pdf, do: "on"}"} phx-click="switch_tool" phx-value-tool="pdf">
            <span class="sb-icon">📕</span> PDF
          </button>

          <%= if @doc do %>
            <div class="sb-file-info" style="margin-top:12px">
              <div style="font-size:9px;font-weight:700;color:var(--text-3);text-transform:uppercase;letter-spacing:.5px;margin-bottom:6px">File</div>
              <div class="sb-file-name"><%= @doc.filename %></div>
              <div class="sb-file-type"><%= @doc.content_type %></div>
              <div style="margin-top:8px">
                <span style="font-size:9px;font-weight:700;color:var(--text-3);text-transform:uppercase;letter-spacing:.5px">Version</span>
                <span style="font-family:monospace;font-size:11px;color:var(--primary);margin-left:6px">v1</span>
              </div>
            </div>
          <% end %>

          <div class="sb-section" style="margin-top:8px">
            <div class="sb-label">Pipeline</div>
          </div>
          <div style="padding:4px 12px;display:flex;flex-direction:column;gap:4px">
            <div style="font-size:10px;color:var(--text-2);display:flex;align-items:center;gap:6px">
              <span style="color:var(--green)">●</span> S3 Storage
            </div>
            <div style="font-size:10px;color:var(--text-2);display:flex;align-items:center;gap:6px">
              <span style="color:var(--green)">●</span> PostgreSQL
            </div>
            <div style="font-size:10px;color:var(--text-2);display:flex;align-items:center;gap:6px">
              <span style="color:var(--green)">●</span> LanceDB Vector
            </div>
          </div>
        </nav>

        <!-- Main Editor Area -->
        <div style="flex:1;display:flex;flex-direction:column;overflow:hidden">

          <!-- Document Toolbar -->
          <div class="studio-toolbar" id="toolbar-document" style={"display:#{if @tool == :document, do: "flex", else: "none"}"}>
            <select class="tb-sel" onchange="execCmd('fontName',this.value)" title="Font">
              <option value="Georgia">Georgia</option>
              <option value="Arial">Arial</option>
              <option value="'Times New Roman'">Times NR</option>
              <option value="'Courier New'">Courier</option>
              <option value="Verdana">Verdana</option>
            </select>
            <select class="tb-sel" onchange="setFontSize(this.value)" title="Size">
              <option value="1">8</option><option value="2">10</option>
              <option value="3" selected>12</option><option value="4">14</option>
              <option value="5">18</option><option value="6">24</option>
              <option value="7">36</option>
            </select>
            <div class="tb-sep"></div>
            <button class="tb" onclick="execCmd('bold')" title="Bold (Ctrl+B)"><b>B</b></button>
            <button class="tb" onclick="execCmd('italic')" title="Italic (Ctrl+I)"><i>I</i></button>
            <button class="tb" onclick="execCmd('underline')" title="Underline (Ctrl+U)"><u>U</u></button>
            <button class="tb" onclick="execCmd('strikeThrough')" title="Strikethrough"><s>S</s></button>
            <div class="tb-sep"></div>
            <button class="tb" onclick="execCmd('justifyLeft')" title="Align Left">⇤</button>
            <button class="tb" onclick="execCmd('justifyCenter')" title="Center">≡</button>
            <button class="tb" onclick="execCmd('justifyRight')" title="Align Right">⇥</button>
            <button class="tb" onclick="execCmd('justifyFull')" title="Justify">☰</button>
            <div class="tb-sep"></div>
            <button class="tb" onclick="execCmd('insertUnorderedList')" title="Bullet List">• –</button>
            <button class="tb" onclick="execCmd('insertOrderedList')" title="Numbered List">1.</button>
            <div class="tb-sep"></div>
            <button class="tb" onclick="fmtBlock('h1')" title="Heading 1" style="font-weight:700">H1</button>
            <button class="tb" onclick="fmtBlock('h2')" title="Heading 2" style="font-weight:700">H2</button>
            <button class="tb" onclick="fmtBlock('h3')" title="Heading 3" style="font-weight:700">H3</button>
            <button class="tb" onclick="fmtBlock('p')"  title="Paragraph">¶</button>
            <div class="tb-sep"></div>
            <input class="tb-color" type="color" title="Text Color" onchange="execCmd('foreColor',this.value)" value="#000000"/>
            <input class="tb-color" type="color" title="Highlight" onchange="execCmd('hiliteColor',this.value)" value="#ffff00" style="background:#ffff00"/>
            <div class="tb-sep"></div>
            <button class="tb" onclick="insertTable()" title="Insert Table">⊞ Table</button>
            <button class="tb" onclick="insertLink()" title="Insert Link">🔗</button>
            <button class="tb" onclick="insertHR()" title="Horizontal Rule">—</button>
            <div class="tb-sep"></div>
            <button class="tb" onclick="execCmd('undo')" title="Undo">↩</button>
            <button class="tb" onclick="execCmd('redo')" title="Redo">↪</button>
            <div class="tb-sep"></div>
            <button class="tb" onclick="exportHTML()" title="Export as HTML" style="font-size:11px;padding:4px 8px">↓ HTML</button>
            <button class="tb" onclick="printDoc()" title="Print / Save as PDF" style="font-size:11px;padding:4px 8px">🖨 PDF</button>
          </div>

          <!-- Image Toolbar -->
          <div class="studio-toolbar" id="toolbar-image" style={"display:#{if @tool == :image, do: "flex", else: "none"}"}>
            <button class="tb" onclick="imgRotate(-90)" title="Rotate Left">↺ -90°</button>
            <button class="tb" onclick="imgRotate(90)"  title="Rotate Right">↻ +90°</button>
            <button class="tb" onclick="imgFlip('h')"   title="Flip Horizontal">⇔</button>
            <button class="tb" onclick="imgFlip('v')"   title="Flip Vertical">⇕</button>
            <div class="tb-sep"></div>
            <span style="font-size:10px;color:var(--text-3)">Brightness</span>
            <input type="range" id="sl-b" min="-100" max="100" value="0" oninput="applyFilters()" style="width:70px"/>
            <span style="font-size:10px;color:var(--text-3)">Contrast</span>
            <input type="range" id="sl-c" min="-100" max="100" value="0" oninput="applyFilters()" style="width:70px"/>
            <span style="font-size:10px;color:var(--text-3)">Saturate</span>
            <input type="range" id="sl-s" min="0" max="200" value="100" oninput="applyFilters()" style="width:70px"/>
            <div class="tb-sep"></div>
            <button class="tb" onclick="imgFilter('grayscale(1)')">Grayscale</button>
            <button class="tb" onclick="imgFilter('sepia(1)')">Sepia</button>
            <button class="tb" onclick="imgFilter('invert(1)')">Invert</button>
            <button class="tb" onclick="resetFilters()">Reset</button>
            <div class="tb-sep"></div>
            <button class="tb" onclick="downloadImg()" style="background:var(--primary);color:#fff;font-size:11px">↓ Download PNG</button>
          </div>

          <!-- PDF Toolbar -->
          <div class="studio-toolbar" id="toolbar-pdf" style={"display:#{if @tool == :pdf, do: "flex", else: "none"}"}>
            <span style="font-size:12px;color:var(--text-2)">📕 PDF Viewer</span>
            <div class="tb-sep"></div>
            <%= if @doc && @doc.url do %>
              <a href={@doc.url} target="_blank" class="tb" style="text-decoration:none">↗ Open full screen</a>
              <a href={@doc.url} download={if @doc, do: @doc.filename} class="tb" style="text-decoration:none">↓ Download</a>
            <% end %>
          </div>

          <!-- Canvas -->
          <div class="studio-canvas" id="studio-canvas">

            <!-- Document Panel -->
            <div class="doc-wrap" id="panel-document" style={"display:#{if @tool == :document, do: "block", else: "none"}"}>
              <div id="doc-editor"
                   class="doc-page"
                   contenteditable="true"
                   spellcheck="true"
                   data-file-url={if @doc, do: (@doc.url || ""), else: ""}
                   data-content-type={if @doc, do: (@doc.content_type || ""), else: ""}
                   onkeyup="markDirty()"
                   oninput="markDirty()">
                <%= if @doc do %>
                  <p style="color:#999;font-style:italic" id="doc-init-msg">⏳ Loading file...</p>
                <% else %>
                  <h1>Untitled Document</h1>
                  <p>Start writing your document here. Use the toolbar to format text.</p>
                <% end %>
              </div>
            </div>

            <!-- Image Panel -->
            <div class="img-wrap" id="panel-image" style={"display:#{if @tool == :image, do: "flex", else: "none"}"}>
              <canvas id="img-canvas"></canvas>
              <div id="img-empty" class="studio-empty">
                <div class="studio-empty-icon">🖼️</div>
                <div class="studio-empty-title">No image loaded</div>
                <div class="studio-empty-sub">Open an image file from My Files and click Edit</div>
              </div>
            </div>

            <!-- PDF Panel -->
            <div class="pdf-wrap" id="panel-pdf" style={"display:#{if @tool == :pdf, do: "block", else: "none"}"}>
              <%= if @doc && @doc.url && is_pdf(@doc.content_type) do %>
                <iframe src={@doc.url} class="pdf-frame" title={@doc.filename}></iframe>
              <% else %>
                <div class="studio-empty">
                  <div class="studio-empty-icon">📕</div>
                  <div class="studio-empty-title">No PDF loaded</div>
                  <div class="studio-empty-sub">Open a PDF file from My Files and click Edit</div>
                </div>
              <% end %>
            </div>

          </div><!-- /canvas -->
        </div><!-- /main -->
      </div><!-- /body -->

      <!-- Status Bar -->
      <div class="studio-statusbar">
        <span class="statusbar-accent">PRZMA Studio v1.0</span>
        <span class="statusbar-pill">|</span>
        <span id="sb-words" class="statusbar-pill">0 words</span>
        <span class="statusbar-pill">|</span>
        <span id="sb-chars" class="statusbar-pill">0 chars</span>
        <span class="statusbar-pill" style="margin-left:auto">
          S3 · PostgreSQL · LanceDB 446-dim
        </span>
      </div>
    </div><!-- /studio -->

    <script>
      // ── Theme ──
      function getTheme() { return document.documentElement.getAttribute('data-theme') || 'dark'; }
      function toggleTheme() {
        var t = getTheme() === 'dark' ? 'light' : 'dark';
        document.documentElement.setAttribute('data-theme', t);
        localStorage.setItem('przma-theme', t);
        var btn = document.getElementById('theme-btn');
        if (btn) btn.textContent = t === 'dark' ? '☀' : '◑';
      }
      (function() {
        var t = localStorage.getItem('przma-theme') ||
                (window.matchMedia('(prefers-color-scheme: light)').matches ? 'light' : 'dark');
        document.documentElement.setAttribute('data-theme', t);
        var btn = document.getElementById('theme-btn');
        if (btn) btn.textContent = t === 'dark' ? '☀' : '◑';
      })();

      // ── Document editor commands ──
      var editorDirty = false;
      var saveTimer   = null;

      function execCmd(cmd, val) {
        var ed = document.getElementById('doc-editor');
        ed.focus();
        document.execCommand(cmd, false, val || null);
        markDirty();
      }
      function setFontSize(v) { execCmd('fontSize', v); }
      function fmtBlock(tag) { execCmd('formatBlock', tag); }
      function insertTable() {
        var r = parseInt(prompt('Rows?','3') || '3');
        var c = parseInt(prompt('Columns?','3') || '3');
        var html = '<table border="1" style="border-collapse:collapse;width:100%;margin:12px 0">';
        for (var i=0;i<r;i++) { html+='<tr>'; for(var j=0;j<c;j++) html+='<td style="padding:8px 12px;border:1px solid #ccc;min-width:80px">&nbsp;</td>'; html+='</tr>'; }
        html += '</table><p></p>';
        execCmd('insertHTML', html);
      }
      function insertLink() {
        var url = prompt('URL:','https://');
        if (url) execCmd('createLink', url);
      }
      function insertHR() { execCmd('insertHTML', '<hr style="border:none;border-top:1px solid #ccc;margin:16px 0"/><p></p>'); }

      function markDirty() {
        editorDirty = true;
        var chip = document.getElementById('save-status-chip');
        if (chip) { chip.textContent = '● Unsaved'; chip.className = 'studio-status-chip sc-saving'; }
        clearTimeout(saveTimer);
        saveTimer = setTimeout(autoSave, 3000);
        updateStats();
      }
      function updateStats() {
        var text = (document.getElementById('doc-editor').innerText || '').trim();
        var words = text ? text.split(/\s+/).length : 0;
        var chars = text.length;
        var w = document.getElementById('sb-words');
        var c = document.getElementById('sb-chars');
        if (w) w.textContent = words + ' words';
        if (c) c.textContent = chars + ' chars';
      }
      function autoSave() { if (editorDirty) studioSave(); }

      // Keyboard shortcuts for editor
      function handleEditorKey(e) {
        if (e.ctrlKey || e.metaKey) {
          switch(e.key.toLowerCase()) {
            case 'b': e.preventDefault(); execCmd('bold'); break;
            case 'i': e.preventDefault(); execCmd('italic'); break;
            case 'u': e.preventDefault(); execCmd('underline'); break;
            case 's': e.preventDefault(); studioSave(); break;
            case 'z': e.preventDefault(); execCmd(e.shiftKey ? 'redo' : 'undo'); break;
          }
        }
      }

      // ── PRZMA Save (reliable hidden form → LiveView) ──
      function studioSave() {
        var ed = document.getElementById('doc-editor');
        if (!ed) return;

        var chip = document.getElementById('save-status-chip');
        if (chip) { chip.textContent = '⏳ Saving...'; chip.className = 'studio-status-chip sc-saving'; }

        // Determine format and content based on active tool
        var fmt = 'html';
        var content = ed.innerHTML;

        // For image tool, bake CSS filters into pixels then export
        if (document.getElementById('panel-image') &&
            document.getElementById('panel-image').style.display !== 'none') {
          var canvas = document.getElementById('img-canvas');
          if (canvas && canvas.style.display !== 'none') {
            var baked = getBakedCanvas();
            content = baked.toDataURL('image/png');
            fmt = 'image_base64';
          }
        }

        // Write content to hidden form and submit via LiveView
        var input = document.getElementById('save-input');
        var fmtInput = document.getElementById('save-format');
        var form = document.getElementById('save-form');
        if (!input || !form) {
          console.error('[Studio] Save form not found');
          if (chip) { chip.textContent = '✕ Save failed'; chip.className = 'studio-status-chip sc-error'; }
          return;
        }
        input.value = content;
        if (fmtInput) fmtInput.value = fmt;

        // Submit via LiveView form mechanism
        form.dispatchEvent(new Event('submit', {bubbles: true, cancelable: true}));
        editorDirty = false;
      }

      // ── Export ──
      function exportHTML() {
        var content = document.getElementById('doc-editor').innerHTML;
        var html = '<!DOCTYPE html><html><head><meta charset="utf-8"><title>Document</title><style>body{font-family:Georgia,serif;max-width:800px;margin:40px auto;padding:0 20px;line-height:1.8}table{border-collapse:collapse;width:100%}td,th{border:1px solid #ccc;padding:6px 10px}hr{border:none;border-top:1px solid #ccc}</style></head><body>'+content+'</body></html>';
        var blob = new Blob([html], {type:'text/html'});
        var a = document.createElement('a'); a.href = URL.createObjectURL(blob);
        a.download = 'document.html'; a.click();
      }
      function printDoc() { window.print(); }

      // ── Image Editor ──
      var imgData = { rotation:0, flipH:false, flipV:false, img:null, extraFilter:'' };

      function loadImage(src) {
        var img = new Image();
        img.crossOrigin = 'anonymous';
        img.onload = function() {
          imgData.img = img;
          imgData.rotation = 0; imgData.flipH = false; imgData.flipV = false;
          renderImage();
          document.getElementById('img-empty').style.display = 'none';
          document.getElementById('img-canvas').style.display = 'block';
        };
        img.onerror = function() { document.getElementById('img-empty').style.display = 'flex'; };
        img.src = src;
      }
      function renderImage() {
        if (!imgData.img) return;
        var img = imgData.img;
        var canvas = document.getElementById('img-canvas');
        var rad = imgData.rotation * Math.PI / 180;
        var sw = Math.abs(Math.cos(rad))*img.naturalWidth + Math.abs(Math.sin(rad))*img.naturalHeight;
        var sh = Math.abs(Math.sin(rad))*img.naturalWidth + Math.abs(Math.cos(rad))*img.naturalHeight;
        canvas.width = sw; canvas.height = sh;
        var ctx = canvas.getContext('2d');
        ctx.save();
        ctx.translate(sw/2, sh/2); ctx.rotate(rad);
        ctx.scale(imgData.flipH?-1:1, imgData.flipV?-1:1);
        ctx.drawImage(img, -img.naturalWidth/2, -img.naturalHeight/2);
        ctx.restore();
        applyFilters();
      }
      function imgRotate(deg) { imgData.rotation=(imgData.rotation+deg+360)%360; renderImage(); }
      function imgFlip(d) { if(d==='h') imgData.flipH=!imgData.flipH; else imgData.flipV=!imgData.flipV; renderImage(); }
      function applyFilters() {
        var b=document.getElementById('sl-b').value;
        var c=document.getElementById('sl-c').value;
        var s=document.getElementById('sl-s').value;
        var f='brightness('+(1+b/100)+') contrast('+(1+c/100)+') saturate('+(s/100)+')';
        if(imgData.extraFilter) f+=' '+imgData.extraFilter;
        document.getElementById('img-canvas').style.filter=f;
      }
      function imgFilter(f) { imgData.extraFilter=f; applyFilters(); }
      function resetFilters() {
        imgData.extraFilter='';
        ['sl-b','sl-c'].forEach(function(id){ document.getElementById(id).value=0; });
        document.getElementById('sl-s').value=100;
        document.getElementById('img-canvas').style.filter='none';
      }
      function getBakedCanvas() {
        // Bake CSS filters into actual pixels for export
        var src = document.getElementById('img-canvas');
        var b = document.getElementById('sl-b').value;
        var c = document.getElementById('sl-c').value;
        var s = document.getElementById('sl-s').value;
        var f = 'brightness('+(1+b/100)+') contrast('+(1+c/100)+') saturate('+(s/100)+')';
        if (imgData.extraFilter) f += ' ' + imgData.extraFilter;
        var out = document.createElement('canvas');
        out.width = src.width; out.height = src.height;
        var ctx = out.getContext('2d');
        ctx.filter = f;
        ctx.drawImage(src, 0, 0);
        return out;
      }
      function downloadImg() {
        var out = getBakedCanvas();
        var a = document.createElement('a');
        a.download = 'edited-image.png';
        a.href = out.toDataURL('image/png');
        a.click();
      }

      // ── Init: load file content ──
      document.addEventListener('DOMContentLoaded', function() {
        var ed = document.getElementById('doc-editor');
        if (!ed) return;
        var url = ed.getAttribute('data-file-url');
        var ct  = ed.getAttribute('data-content-type') || '';
        var initMsg = document.getElementById('doc-init-msg');

        if (!url) { updateStats(); return; }

        if (ct.indexOf('text') !== -1) {
          fetch(url)
            .then(function(r) { if(!r.ok) throw new Error(r.status); return r.text(); })
            .then(function(t) {
              if(initMsg) initMsg.remove();
              ed.innerText = t;
              updateStats();
            })
            .catch(function() { if(initMsg) initMsg.textContent = '⚠ Could not load file content'; });

        } else if (ct.indexOf('wordprocessingml') !== -1 || ct.indexOf('msword') !== -1) {
          if (window.mammoth) {
            fetch(url)
              .then(function(r) { if(!r.ok) throw new Error(r.status); return r.arrayBuffer(); })
              .then(function(buf) { return mammoth.convertToHtml({arrayBuffer:buf}); })
              .then(function(result) {
                if(initMsg) initMsg.remove();
                ed.innerHTML = result.value;
                updateStats();
              })
              .catch(function() { if(initMsg) initMsg.textContent = '⚠ Could not render DOCX'; });
          } else {
            if(initMsg) initMsg.textContent = 'DOCX renderer loading...';
          }

        } else if (ct.indexOf('image') !== -1) {
          if(initMsg) initMsg.remove();
          ed.innerHTML = '<p style="color:#999;font-size:12px">Switch to Image Editor in sidebar to edit this image.</p>';
          loadImage(url);

        } else if (ct.indexOf('pdf') !== -1) {
          if(initMsg) initMsg.remove();
          ed.innerHTML = '<p style="color:#999;font-size:12px">Switch to PDF Viewer in sidebar to view this PDF.</p>';

        } else {
          if(initMsg) initMsg.textContent = 'This file type has limited editing support.';
          updateStats();
        }
      });

      // ── Cross-tab panel refresh on save ──


      // ── Cross-tab notification ──
      var _ch = null;
      try { _ch = new BroadcastChannel('przma-studio'); } catch(e) {}
      function notifyPanelSaved() {
        var msg = {type:'file_saved',ts:Date.now()};
        if (_ch) _ch.postMessage(msg);
        localStorage.setItem('przma-file-saved', JSON.stringify(msg));
      }
      window.addEventListener('phx:update', function() {
        var chip = document.getElementById('save-status-chip');
        if (chip && chip.textContent.indexOf('Saved to S3') !== -1 && !chip._notified) {
          chip._notified = true;
          notifyPanelSaved();
          setTimeout(function(){ chip._notified = false; }, 5000);
        }
      });
      // ── Auto-save draft to localStorage ──
      window.addEventListener('beforeunload', function() {
        var ed = document.getElementById('doc-editor');
        if (ed && editorDirty) {
          localStorage.setItem('przma-studio-draft-backup', ed.innerHTML);
        }
      });
    </script>
    """
  end

  defp status_class(:idle),   do: "sc-idle"
  defp status_class(:saving), do: "sc-saving"
  defp status_class(:saved),  do: "sc-saved"
  defp status_class(:error),  do: "sc-error"
  defp status_class(_),       do: "sc-idle"

  defp is_pdf(t) when is_binary(t), do: t == "application/pdf" or String.contains?(t, "pdf")
  defp is_pdf(_), do: false
end