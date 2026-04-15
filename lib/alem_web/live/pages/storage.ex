defmodule AlemWeb.Admin.Pages.Storage do
  @moduledoc """
  Storage pages: CAS Vault, Duplicates, S3 Browser (read-only).

  S3 Browser has three views:
    :root           — shows "user/" and "analytics/" tiles
    :user_list      — shows all user namespaces as cards (DB + S3)
    :namespace_files — shows all files for a namespace from the DB (not S3 drilling)
  Filenames are NEVER shown. Only doc IDs, types, sizes, timestamps.
  """
  use Phoenix.Component
  import AlemWeb.Admin.Helpers
  import AlemWeb.Admin.Components
  alias Alem.Admin

  # ── CAS Vault ─────────────────────────────────────────────────────────────

  def vault(assigns) do
    ~H"""
    <div>
      <.back_button />
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
              <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                <circle cx="11" cy="11" r="8"/><line x1="21" y1="21" x2="16.65" y2="16.65"/>
              </svg>
              <input class="search-input" placeholder="Hash, path, type…"
                     phx-keyup="search_cas" phx-debounce="300"
                     name="search" phx-value-search={@cas_search} value={@cas_search}/>
            </div>
            <div class="filter-pills">
              <%= for {v,l} <- [{"all","All"},{"duplicates","Dupes"},{"large",">10MB"},{"images","Images"},{"docs","Docs"}] do %>
                <button class={["pill", @cas_filter == v && "active"]}
                        phx-click="filter_cas" phx-value-filter={v}><%= l %></button>
              <% end %>
            </div>
          </div>
          <div class="table-wrap">
            <table class="data-table">
              <thead>
                <tr><th>Hash</th><th>Type</th><th>Size</th><th>Refs</th><th>Namespace</th><th>Stored</th></tr>
              </thead>
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
    </div>
    """
  end

  # ── Duplicates ─────────────────────────────────────────────────────────────

  def duplicates(assigns) do
    ~H"""
    <div>
      <.back_button />
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
          <thead>
            <tr><th>Hash</th><th>Type</th><th>Size</th><th>Refs</th><th>Saved</th><th>Namespace</th></tr>
          </thead>
          <tbody>
            <%= for obj <- @duplicates.duplicates do %>
              <tr class="data-row">
                <td class="mono cell-sm"><%= String.slice(obj.content_hash, 0, 20) %>…</td>
                <td><%= ctic(obj.media_type) %> <%= sct(obj.media_type) %></td>
                <td class="cell-num"><%= Admin.format_bytes(obj.file_size) %></td>
                <td><span class="ref-badge dup"><%= obj.ref_count %>×</span></td>
                <td class="cell-num" style="color:var(--clr-green)">
                  <%= Admin.format_bytes(obj.file_size * (obj.ref_count - 1)) %>
                </td>
                <td class="mono cell-sm"><%= String.slice(obj.namespace_key || "—", 0, 12) %></td>
              </tr>
            <% end %>
            <%= if @duplicates.duplicates == [] do %>
              <tr><td colspan="6" class="empty-row">No duplicates — CAS is perfectly deduplicated ✓</td></tr>
            <% end %>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  # ── S3 Browser ─────────────────────────────────────────────────────────────
  # Three views: :root → :user_list → :namespace_files
  # Filenames are NEVER shown — only document UUIDs, types, sizes, timestamps.

  def s3(assigns) do
    ~H"""
    <div>

      <div class="s3-breadcrumb" style="margin-bottom:18px">
        <%= if @s3_view != :root do %>
          <button class="btn-sm" phx-click="s3_back">← Back</button>
        <% end %>
        <span style="color:var(--tx3);font-size:11px">Storage /</span>
        <span class={["breadcrumb-path", @s3_view == :root && "active"]} style="font-size:11px">
          Root
        </span>
        <%= if @s3_view in [:user_list, :namespace_files] do %>
          <span class="breadcrumb-sep">›</span>
          <span class="breadcrumb-path" style="font-size:11px">user/</span>
        <% end %>
        <%= if @s3_view == :namespace_files && @s3_ns_data do %>
          <span class="breadcrumb-sep">›</span>
          <span class="breadcrumb-path" style="font-size:11px">
            <%= @s3_ns_data.namespace_key %>
            <%= if @s3_ns_data.user do %>
              <span style="color:var(--tx2);font-family:sans-serif"> (<%= @s3_ns_data.user.nickname %>)</span>
            <% end %>
          </span>
        <% end %>
      </div>


      <%= if @s3_view == :root do %>
        <div class="page-header" style="margin-bottom:16px">
          <div>
            <h2 class="page-heading">S3 Browser</h2>
            <div class="page-sub">Read-only view of platform object storage</div>
          </div>
        </div>
        <div class="s3-root-grid">
          <%= for root <- @s3_roots do %>
            <button class="s3-card" phx-click="s3_browse" phx-value-prefix={root.prefix}>
              <div class="s3-card-icon">
                <%= if String.starts_with?(root.prefix, "user/"), do: "◎", else: "◈" %>
              </div>
              <div class="s3-card-name mono"><%= String.trim_trailing(root.prefix, "/") %></div>
              <div class="s3-card-meta">
                <%= root.subfolder_count %> namespaces · read-only
              </div>
              <div class="s3-card-cta">Browse →</div>
            </button>
          <% end %>
        </div>


      <% end %>
      <%= if @s3_view == :user_list do %>
        <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:14px">
          <div>
            <h2 class="page-heading">User Namespaces</h2>
            <div class="page-sub"><%= length(@s3_user_namespaces) %> users with storage</div>
          </div>
          <div class="search-box" style="max-width:220px">
            <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <circle cx="11" cy="11" r="8"/><line x1="21" y1="21" x2="16.65" y2="16.65"/>
            </svg>
            <input class="search-input" placeholder="Search user…"
                   phx-keyup="s3_ns_filter" phx-debounce="200"
                   name="nsq" value={@s3_ns_filter}
                   phx-value-search={@s3_ns_filter}/>
          </div>
        </div>

        <% ns_list = if @s3_ns_filter != "" do
            q = String.downcase(@s3_ns_filter)
            Enum.filter(@s3_user_namespaces, fn ns ->
              String.contains?(String.downcase(ns.nickname || ""), q) ||
              String.contains?(String.downcase(ns.namespace_key || ""), q) ||
              String.contains?(String.downcase(ns.email || ""), q)
            end)
          else
            @s3_user_namespaces
          end %>

        <%= if ns_list == [] do %>
          <div class="empty-state">No user namespaces found</div>
        <% else %>
          <div class="table-wrap">
            <table class="data-table">
              <thead>
                <tr>
                  <th>User</th>
                  <th>Namespace Key</th>
                  <th>Files</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <%= for ns <- ns_list do %>
                  <tr class="data-row">
                    <td>
                      <div class="user-info">
                        <div class="user-name"><%= ns.nickname %></div>
                        <div class="user-id mono"><%= ns.email %></div>
                      </div>
                    </td>
                    <td class="mono cell-sm"><%= ns.namespace_key %></td>
                    <td class="cell-num"><%= ns.file_count %></td>
                    <td>
                      <button class="btn-sm accent"
                              phx-click="s3_browse"
                              phx-value-prefix={"user/#{ns.namespace_key}/"}>
                        View Files →
                      </button>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        <% end %>


        <% s3_keys = (@s3_result && @s3_result.prefixes || [])
                     |> Enum.map(fn p -> p[:prefix] || "" end)
                     |> Enum.map(& String.trim_trailing(&1, "/") |> String.split("/") |> List.last())
           known_keys = Enum.map(@s3_user_namespaces, & &1.namespace_key)
           orphans = Enum.filter(s3_keys, & &1 not in known_keys) %>
        <%= if orphans != [] do %>
          <div class="section-label" style="margin-top:20px;margin-bottom:8px">
            Unlinked namespaces in S3 (<%= length(orphans) %>)
          </div>
          <div style="display:flex;gap:8px;flex-wrap:wrap">
            <%= for key <- orphans do %>
              <button class="s3-folder"
                      phx-click="s3_browse"
                      phx-value-prefix={"user/#{key}/"}>
                <span style="color:var(--clr-amber)">▸</span>
                <span class="mono" style="font-size:11px"><%= key %></span>
              </button>
            <% end %>
          </div>
        <% end %>


      <% end %>
      <%= if @s3_view == :namespace_files && @s3_ns_data do %>

        <%= if @s3_ns_data.user do %>
          <div class="profile-card" style="margin-bottom:16px;padding:16px">
            <div class="profile-avatar-lg">
              <%= String.first(@s3_ns_data.user.nickname || "?") |> String.upcase() %>
            </div>
            <div class="profile-info">
              <div class="profile-name"><%= @s3_ns_data.user.nickname %></div>
              <div class="profile-email"><%= @s3_ns_data.user.email %></div>
              <div class="profile-id mono"><%= @s3_ns_data.namespace_key %></div>
            </div>
            <div style="text-align:right">
              <div class="strip-val" style="font-size:22px"><%= @s3_ns_data.total %></div>
              <div class="strip-lbl">Total Files</div>
            </div>
          </div>
        <% else %>
          <div class="profile-card" style="margin-bottom:16px">
            <div>
              <div class="profile-name mono"><%= @s3_ns_data.namespace_key %></div>
              <div class="profile-email">No user linked to this namespace</div>
            </div>
          </div>
        <% end %>


        <div class="toolbar" style="margin-bottom:12px">
          <div class="search-box">
            <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <circle cx="11" cy="11" r="8"/><line x1="21" y1="21" x2="16.65" y2="16.65"/>
            </svg>
            <input class="search-input" placeholder="Search by document ID or type…"
                   phx-keyup="s3_search" phx-debounce="250"
                   name="s3q" value={@s3_search}
                   phx-value-search={@s3_search}/>
          </div>
          <div class="filter-pills">
            <%= for {v,l} <- [{"all","All"},{"image","Images"},{"pdf","PDF"},{"binary","Binary"},{"video","Video"}] do %>
              <button class={["pill", (@s3_type_filter || "all") == v && "active"]}
                      phx-click="s3_type_filter" phx-value-filter={v}><%= l %></button>
            <% end %>
          </div>
        </div>


        <% files = @s3_ns_data.files
                   |> then(fn f ->
                       q = @s3_search
                       if q && q != "" do
                         ql = String.downcase(q)
                         Enum.filter(f, fn doc ->
                           String.contains?(String.downcase(doc.id || ""), ql) ||
                           String.contains?(String.downcase(doc.content_type || ""), ql) ||
                           String.contains?(String.downcase(doc.content_hash || ""), ql)
                         end)
                       else f end
                     end)
                   |> then(fn f ->
                       tf = @s3_type_filter || "all"
                       if tf != "all" do
                         Enum.filter(f, fn doc ->
                           ct = String.downcase(doc.content_type || "")
                           cond do
                             tf == "image"  -> String.starts_with?(ct, "image/")
                             tf == "pdf"    -> ct == "application/pdf"
                             tf == "video"  -> String.starts_with?(ct, "video/")
                             tf == "binary" -> !String.starts_with?(ct, ["image/","video/","audio/","text/"]) && ct != "application/pdf"
                             true           -> true
                           end
                         end)
                       else f end
                     end) %>

        <div class="table-wrap">
          <table class="data-table">
            <thead>
              <tr>
                <th>Document ID</th>
                <th>Content Hash</th>
                <th>Type</th>
                <th>Size</th>
                <th>Refs</th>
                <th>Status</th>
                <th>Stored</th>
                <th>Updated</th>
              </tr>
            </thead>
            <tbody>
              <%= for doc <- files do %>
                <tr class="data-row">
                  <td class="mono cell-sm" style="max-width:180px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title={doc.id}>
                    <%= String.slice(doc.id || "—", 0, 20) %><%= if String.length(doc.id || "") > 20, do: "…" %>
                  </td>
                  <td class="mono cell-sm" style="color:var(--clr-blue)" title={doc.content_hash}>
                    <%= String.slice(doc.content_hash || "—", 0, 16) %>…
                  </td>
                  <td>
                    <span class="ref-badge"><%= ctic(doc.content_type) %> <%= sct(doc.content_type) %></span>
                  </td>
                  <td class="cell-num"><%= Admin.format_bytes(doc.file_size || 0) %></td>
                  <td>
                    <%= if doc.ref_count && doc.ref_count > 1 do %>
                      <span class="ref-badge dup"><%= doc.ref_count %>×</span>
                    <% else %>
                      <span class="ref-badge">1</span>
                    <% end %>
                  </td>
                  <td>
                    <span class={"badge #{if doc.status == "synced", do: "green", else: "gray"}"}>
                      <%= doc.status || "—" %>
                    </span>
                  </td>
                  <td class="cell-sm"><%= fd(doc.inserted_at) %></td>
                  <td class="cell-sm"><%= fd(doc.updated_at) %></td>
                </tr>
              <% end %>
              <%= if files == [] do %>
                <tr><td colspan="8" class="empty-row">No files match the filter</td></tr>
              <% end %>
            </tbody>
          </table>
        </div>

        <div style="margin-top:10px;padding:8px 12px;border-radius:7px;background:var(--bg3);border:1px solid var(--border);font-size:10px;color:var(--tx3)">
          ℹ Filenames are never shown. Showing document IDs and content hashes only. Data sourced from PostgreSQL — not S3 folder structure.
        </div>
      <% end %>
    </div>
    """
  end

  defp parse_size(s) when is_binary(s), do: String.to_integer(s)
  defp parse_size(i) when is_integer(i), do: i
  defp parse_size(%Decimal{} = d), do: Decimal.to_integer(d)
  defp parse_size(_), do: 0
end
