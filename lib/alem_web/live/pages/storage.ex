defmodule AlemWeb.AdminLive.Pages.Storage do
  @moduledoc "Storage pages: CAS vault, duplicates, S3 browser, file catalog, SQL console."
  use Phoenix.Component
  import AlemWeb.AdminLive.Helpers
  alias Alem.Admin

  # ── CAS Vault ─────────────────────────────────────────────────────────────

  def vault(assigns) do
    ~H"""
    <div class="vault-layout">
      <div class="vault-sidebar">
        <div class="card-head"><span class="card-title">Namespaces</span></div>
        <button class="vault-all-btn" phx-click="filter_cas" phx-value-filter="all">◈ All Objects</button>
        <%= for ns <- @s3_tree do %>
          <div class="vault-ns">
            <div class="mono cell-sm"><%= String.slice(ns.namespace_key || "—", 0, 14) %></div>
            <div class="row-meta"><%= ns.file_count %> · <%= Admin.format_bytes(ns.total_bytes) %></div>
          </div>
        <% end %>
      </div>
      <div>
        <div class="toolbar" style="margin-bottom:12px">
          <div class="search-box">
            <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="11" cy="11" r="8"/><line x1="21" y1="21" x2="16.65" y2="16.65"/></svg>
            <input class="search-input" placeholder="Hash, path, type…" phx-keyup="search_cas" phx-debounce="300" name="search" phx-value-search={@cas_search} value={@cas_search}/>
          </div>
          <div class="filter-pills">
            <%= for {v,l} <- [{"all","All"},{"duplicates","Dupes"},{"large",">10MB"},{"images","Images"},{"docs","Docs"}] do %>
              <button class={["pill", @cas_filter == v && "active"]} phx-click="filter_cas" phx-value-filter={v}><%= l %></button>
            <% end %>
          </div>
        </div>
        <div class="table-wrap">
          <table class="data-table">
            <thead><tr><th>Hash</th><th>Type</th><th>Size</th><th>Refs</th><th>Namespace</th><th>Stored</th></tr></thead>
            <tbody>
              <%= for obj <- @cas_objects.items do %>
                <tr class="data-row">
                  <td class="mono cell-sm"><%= String.slice(obj.content_hash, 0, 16) %>…</td>
                  <td><%= ctic(obj.media_type) %> <%= sct(obj.media_type) %></td>
                  <td class="cell-num"><%= Admin.format_bytes(obj.file_size) %></td>
                  <td><span class={"ref-badge #{if obj.ref_count > 1, do: "dup", else: ""}"}><%= obj.ref_count %></span></td>
                  <td class="mono cell-sm"><%= String.slice(obj.namespace_key || "—", 0, 12) %></td>
                  <td class="cell-sm"><%= fd(obj.inserted_at) %></td>
                </tr>
              <% end %>
              <%= if @cas_objects.items == [] do %>
                <tr><td colspan="6" class="empty-row">No objects</td></tr>
              <% end %>
            </tbody>
          </table>
        </div>
        <.pagination d={@cas_objects} e="cas_page"/>
      </div>
    </div>
    """
  end

  # ── Duplicates ────────────────────────────────────────────────────────────

  def duplicates(assigns) do
    ~H"""
    <div>
      <div class="stat-strip" style="margin-bottom:16px">
        <div class="strip-stat">
          <div class="strip-val"><%= length(@duplicates.duplicates) %></div>
          <div class="strip-lbl">Duplicate Objects</div>
        </div>
        <div class="strip-stat green">
          <div class="strip-val"><%= Admin.format_bytes(@duplicates.total_wasted) %></div>
          <div class="strip-lbl">Saved by Dedup</div>
        </div>
      </div>
      <div class="table-wrap">
        <table class="data-table">
          <thead><tr><th>Hash</th><th>Type</th><th>Size</th><th>Refs</th><th>Saved</th><th>Namespace</th></tr></thead>
          <tbody>
            <%= for obj <- @duplicates.duplicates do %>
              <tr class="data-row">
                <td class="mono cell-sm"><%= String.slice(obj.content_hash, 0, 20) %>…</td>
                <td><%= ctic(obj.media_type) %> <%= sct(obj.media_type) %></td>
                <td class="cell-num"><%= Admin.format_bytes(obj.file_size) %></td>
                <td><span class="ref-badge dup"><%= obj.ref_count %>×</span></td>
                <td class="cell-num" style="color:var(--clr-green)"><%= Admin.format_bytes(obj.file_size * (obj.ref_count - 1)) %></td>
                <td class="mono cell-sm"><%= String.slice(obj.namespace_key || "—", 0, 12) %></td>
              </tr>
            <% end %>
            <%= if @duplicates.duplicates == [] do %>
              <tr><td colspan="6" class="empty-row">No duplicates — CAS is clean! ✓</td></tr>
            <% end %>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  # ── SQL Console ───────────────────────────────────────────────────────────

  @presets [
    {"All users",           "SELECT id, nickname, email, is_verified, is_active, is_admin, inserted_at\nFROM users ORDER BY inserted_at DESC LIMIT 20;"},
    {"Files per user",      "SELECT u.nickname, COUNT(d.id) AS files, MAX(d.inserted_at) AS last_upload\nFROM users u LEFT JOIN documents d ON d.user_id = u.id\nGROUP BY u.id, u.nickname ORDER BY files DESC;"},
    {"Storage by type",     "SELECT media_type, COUNT(*) AS count, SUM(file_size) AS bytes\nFROM cas_objects GROUP BY media_type ORDER BY bytes DESC;"},
    {"Duplicates",          "SELECT content_hash, media_type, file_size, ref_count,\n       file_size*(ref_count-1) AS saved\nFROM cas_objects WHERE ref_count>1 ORDER BY ref_count DESC LIMIT 50;"},
    {"Active sessions",     "SELECT s.id, u.nickname, s.ip_address, s.device, s.last_active_at\nFROM sessions s JOIN users u ON u.id=s.user_id\nWHERE s.revoked_at IS NULL ORDER BY s.last_active_at DESC LIMIT 30;"},
    {"Active tokens",       "SELECT t.id, u.nickname, t.scopes, t.valid_until\nFROM oauth_tokens t JOIN users u ON u.id=t.user_id\nWHERE t.revoked_at IS NULL AND t.valid_until>NOW()\nORDER BY t.valid_until DESC LIMIT 20;"},
    {"Namespace stats",     "SELECT id, status, document_count, storage_bytes, last_activity_at\nFROM namespaces ORDER BY storage_bytes DESC;"},
    {"Unverified users",    "SELECT id, nickname, email, inserted_at\nFROM users WHERE is_verified=false ORDER BY inserted_at DESC;"},
    {"Blocked users",       "SELECT id, nickname, email, inserted_at FROM users WHERE is_active=false;"},
    {"CAS today",           "SELECT content_hash, media_type, file_size, ref_count, inserted_at\nFROM cas_objects WHERE inserted_at::date=CURRENT_DATE ORDER BY inserted_at DESC;"},
    {"Large files",         "SELECT storage_key, media_type, file_size, ref_count\nFROM cas_objects ORDER BY file_size DESC LIMIT 25;"},
    {"User storage totals", "SELECT u.nickname, u.email, COUNT(d.id) AS files, COALESCE(SUM(c.file_size),0) AS bytes\nFROM users u\nLEFT JOIN documents d ON d.user_id=u.id\nLEFT JOIN cas_objects c ON c.content_hash=d.content_hash\nGROUP BY u.id, u.nickname, u.email\nORDER BY bytes DESC;"},
  ]

  def sql(assigns) do
    assigns = assign(assigns, :presets, @presets)

    ~H"""
    <div class="sql-layout">
      <div class="sql-left">
        <div class="card" style="margin-bottom:12px">
          <div class="card-head"><span class="card-title">Quick Queries</span></div>
          <div style="padding:0">
            <%= for {label, q} <- @presets do %>
              <button class="preset-btn" phx-click="sql_preset" phx-value-q={q}><%= label %></button>
            <% end %>
          </div>
        </div>
        <div class="card">
          <div class="card-head">
            <span class="card-title">SQL Editor</span>
            <span class="card-meta">SELECT only</span>
          </div>
          <textarea class="sql-editor" phx-change="sql_input" phx-debounce="80" name="sql" rows="9" placeholder="SELECT ..."><%= @sql_query %></textarea>
          <div class="sql-toolbar">
            <button class="btn-run" phx-click="sql_run">▶ Run Query</button>
            <button class="btn-clear" phx-click="sql_clear">✕ Clear</button>
            <span class="sql-hint">SELECT only · 10s timeout</span>
          </div>
        </div>
      </div>
      <div class="sql-right">
        <%= if @sql_error do %>
          <div class="error-block">
            <div class="error-title">⚠ Error</div>
            <pre class="error-body"><%= @sql_error %></pre>
          </div>
        <% end %>
        <%= if @sql_result do %>
          <div class="card">
            <div class="card-head">
              <span class="card-title">Result</span>
              <span class="card-meta"><strong><%= @sql_result.count %></strong> rows</span>
            </div>
            <div class="sql-scroll">
              <table class="data-table">
                <thead><tr><%= for col <- @sql_result.columns do %><th><%= col %></th><% end %></tr></thead>
                <tbody>
                  <%= for row <- @sql_result.rows do %>
                    <tr class="data-row"><%= for cell <- row do %><td class="sql-cell"><%= fmt_cell(cell) %></td><% end %></tr>
                  <% end %>
                  <%= if @sql_result.rows == [] do %>
                    <tr><td colspan={length(@sql_result.columns)} class="empty-row">0 rows returned</td></tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          </div>
        <% end %>
        <%= if !@sql_result && !@sql_error do %>
          <div class="sql-placeholder">
            <svg width="40" height="40" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1" opacity=".3"><polyline points="4 17 10 11 4 5"/><line x1="12" y1="19" x2="20" y2="19"/></svg>
            <div style="margin-top:12px">Pick a preset or write a query</div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # ── S3 Browser ────────────────────────────────────────────────────────────

  def s3(assigns) do
    ~H"""
    <div>
      <%= if @s3_prefix == "" do %>
        <div class="section-label" style="margin-bottom:16px">Scoped to platform storage paths</div>
        <div class="s3-root-grid">
          <%= for root <- @s3_roots do %>
            <button class="s3-card" phx-click="s3_browse" phx-value-prefix={root.prefix}>
              <div class="s3-card-icon"><%= if String.starts_with?(root.prefix, "user/"), do: "◎", else: "◈" %></div>
              <div class="s3-card-name mono"><%= root.prefix %></div>
              <div class="s3-card-meta"><%= root.object_count %> files · <%= root.subfolder_count %> subfolders</div>
              <div class="s3-card-cta">Browse →</div>
            </button>
          <% end %>
        </div>
      <% else %>
        <div class="s3-breadcrumb">
          <button class="btn-sm" phx-click="s3_back">← Back</button>
          <span class="breadcrumb-sep">Browsing:</span>
          <span class="breadcrumb-path mono"><%= @s3_prefix %></span>
          <button class="btn-sm" phx-click="s3_browse" phx-value-prefix={@s3_prefix}>⟳ Refresh</button>
        </div>

        <%= if @s3_error do %>
          <div class="error-block">
            <div class="error-title">S3 Error</div>
            <pre class="error-body"><%= @s3_error %></pre>
          </div>
        <% end %>

        <%= if @s3_result do %>
          <%= if @s3_result.prefixes != [] do %>
            <div class="section-label">Subfolders (<%= length(@s3_result.prefixes) %>)</div>
            <div class="s3-folder-grid">
              <%= for pfx <- @s3_result.prefixes, is_map(pfx), Map.has_key?(pfx, :prefix) do %>
                <button class="s3-folder" phx-click="s3_browse" phx-value-prefix={pfx.prefix}>
                  <span style="color:var(--clr-blue)">▸</span>
                  <span class="mono" style="font-size:12px"><%= pfx.prefix |> String.replace_prefix(@s3_prefix, "") |> String.trim_trailing("/") %></span>
                </button>
              <% end %>
            </div>
          <% end %>
          <%= if @s3_result.objects != [] do %>
            <div class="section-label" style="margin-top:20px">Files (<%= length(@s3_result.objects) %>)</div>
            <div class="table-wrap">
              <table class="data-table">
                <thead><tr><th>Key</th><th>Size</th><th>Modified</th><th></th></tr></thead>
                <tbody>
                  <%= for obj <- @s3_result.objects, is_map(obj) do %>
                    <% key = Map.get(obj, :key, "") %>
                    <tr class="data-row">
                      <td class="mono cell-sm" style="max-width:400px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title={key}><%= key %></td>
                      <td class="cell-num cell-sm"><%= Admin.format_bytes(parse_size(Map.get(obj, :size, 0))) %></td>
                      <td class="cell-sm"><%= Map.get(obj, :last_modified, "") %></td>
                      <td><button class="btn-sm" phx-click="s3_presign" phx-value-key={key}>⬇ Link</button></td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          <% end %>
          <%= if @s3_result.objects == [] && @s3_result.prefixes == [] do %>
            <div class="empty-state">Folder is empty</div>
          <% end %>
        <% end %>
      <% end %>
    </div>
    """
  end

  # ── File Catalog ──────────────────────────────────────────────────────────

  def catalog(%{catalog: nil} = assigns) do
    ~H"""
    <div class="empty-state">Loading catalog...</div>
    """
  end

  def catalog(assigns) do
    items_result =
      if Map.has_key?(assigns.catalog, :items_result) do
        assigns.catalog.items_result
      else
        Admin.list_catalog(%{
          group:   assigns.catalog_group,
          user_id: assigns.catalog_user_id,
          search:  assigns.catalog_search,
          page:    assigns.catalog_page
        })
      end

    assigns = assign(assigns, :items_result, items_result)

    ~H"""
    <div>
      <div class="catalog-tiles">
        <button class={["catalog-tile", @catalog_group == "all" && "tile-active"]}
          phx-click="catalog_group" phx-value-group="all">
          <div class="tile-count"><%= @catalog.total_files %></div>
          <div class="tile-label">All Files</div>
          <div class="tile-size"><%= Admin.format_bytes(@catalog.total_bytes) %></div>
        </button>
        <%= for g <- @catalog.groups do %>
          <button class={["catalog-tile", @catalog_group == g.group && "tile-active"]}
            phx-click="catalog_group" phx-value-group={g.group}>
            <div class="tile-count"><%= g.count %></div>
            <div class="tile-label"><%= String.capitalize(g.group) %></div>
            <div class="tile-size"><%= Admin.format_bytes(g.bytes) %></div>
          </button>
        <% end %>
      </div>

      <div class="toolbar" style="margin:12px 0 8px">
        <div class="search-wrap">
          <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="11" cy="11" r="8"/><line x1="21" y1="21" x2="16.65" y2="16.65"/></svg>
          <input class="search-in" placeholder="Search filenames..."
            phx-change="catalog_search" phx-debounce="300" name="search"
            value={@catalog_search}/>
        </div>
        <select class="filter-sel" phx-change="catalog_user_filter" name="user_id">
          <option value="">All Users</option>
          <%= for u <- @users.users do %>
            <option value={u.id} selected={@catalog_user_id == u.id}><%= u.nickname %></option>
          <% end %>
        </select>
        <span class="muted sm"><%= @items_result.total %> files</span>
      </div>

      <div class="tbl-wrap">
        <table class="data-table">
          <thead>
            <tr>
              <th>File</th><th>Type</th><th>User</th>
              <th class="ta-r">Size</th><th class="ta-r">Refs</th><th>Uploaded</th>
            </tr>
          </thead>
          <tbody>
            <%= for f <- @items_result.items do %>
              <tr class="data-row">
                <td>
                  <div style="display:flex;align-items:center;gap:7px">
                    <span class="file-icon"><%= ctic(f.content_type) %></span>
                    <span class="row-name" style="max-width:220px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title={f.filename}><%= f.filename %></span>
                  </div>
                </td>
                <td><span class="type-chip"><%= sct(f.content_type) %></span></td>
                <td>
                  <button class="link-btn" phx-click="catalog_user_filter" phx-value-user_id={f.user_id}>
                    <%= f.nickname %>
                  </button>
                </td>
                <td class="ta-r mono sm"><%= if f.file_size, do: Admin.format_bytes(f.file_size), else: "-" %></td>
                <td class="ta-r">
                  <%= if f.ref_count && f.ref_count > 1 do %>
                    <span class="dup-pill"><%= f.ref_count %>x</span>
                  <% else %>
                    <span class="muted sm">1x</span>
                  <% end %>
                </td>
                <td class="muted sm"><%= fd(f.inserted_at) %></td>
              </tr>
            <% end %>
            <%= if @items_result.items == [] do %>
              <tr><td colspan="6" class="empty-row">No files match filters</td></tr>
            <% end %>
          </tbody>
        </table>
      </div>
    </div>
    """
  end
end
