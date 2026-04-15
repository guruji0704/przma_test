defmodule AlemWeb.Admin.Pages.Documents do
  @moduledoc """
  Admin page for viewing user-uploaded documents.

  Shows all documents with metadata:
  - Document ID
  - Filename (sanitized)
  - File size
  - Content type
  - User/Namespace
  - Upload date
  - Status
  """
  use Phoenix.Component
  import AlemWeb.Admin.Helpers
  import AlemWeb.Admin.Components
  alias Alem.Admin

  def render(assigns) do
    ~H"""
    <div>
      <.back_button />
      <div class="toolbar" style="margin-bottom:16px">
        <div class="search-box">
          <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <circle cx="11" cy="11" r="8"/><line x1="21" y1="21" x2="16.65" y2="16.65"/>
          </svg>
          <input class="search-input" placeholder="Filename, doc ID, user…"
                 phx-keyup="search_documents" phx-debounce="300"
                 name="search" value={@doc_search}/>
        </div>
        <div class="filter-pills">
          <%= for {v,l} <- [{"all","All"},{"processing","Processing"},{"synced","Synced"},{"errors","Errors"}] do %>
            <button class={["pill", @doc_filter == v && "active"]}
                    phx-click="filter_documents" phx-value-filter={v}><%= l %></button>
          <% end %>
        </div>
      </div>

      <div class="stat-strip" style="margin-bottom:16px">
        <div class="strip-stat">
          <div class="strip-val"><%= @documents.total %></div>
          <div class="strip-lbl">Total Documents</div>
        </div>
        <div class="strip-stat">
          <div class="strip-val"><%= Admin.format_bytes(@documents.total_bytes || 0) %></div>
          <div class="strip-lbl">Storage Used</div>
        </div>
        <div class="strip-stat">
          <div class="strip-val"><%= @documents.avg_size || "—" %></div>
          <div class="strip-lbl">Average Size</div>
        </div>
      </div>

      <div class="table-wrap">
        <table class="data-table">
          <thead>
            <tr>
              <th>Doc ID</th>
              <th>Filename</th>
              <th>Type</th>
              <th>Size</th>
              <th>User/Namespace</th>
              <th>Status</th>
              <th>Uploaded</th>
            </tr>
          </thead>
          <tbody>
            <%= for doc <- @documents.items do %>
              <tr class="data-row">
                <td class="mono cell-sm"><%= String.slice(doc.id, 0, 12) %>…</td>
                <td class="cell-filename" title={doc.filename}>
                  <%= String.slice(doc.filename, 0, 30) %><%= if String.length(doc.filename) > 30, do: "…", else: "" %>
                </td>
                <td><%= ctic(doc.content_type) %></td>
                <td class="cell-num"><%= if doc.file_size, do: Admin.format_bytes(doc.file_size), else: "—" %></td>
                <td class="mono cell-sm"><%= String.slice(doc.user_id || "—", 0, 12) %></td>
                <td>
                  <span class={["status-badge", "status-#{doc.status}"]}>
                    <%= doc.status %>
                  </span>
                </td>
                <td class="cell-sm"><%= fd(doc.inserted_at) %></td>
              </tr>
            <% end %>
            <%= if @documents.items == [] do %>
              <tr><td colspan="7" class="empty-row">No documents found</td></tr>
            <% end %>
          </tbody>
        </table>
      </div>

      <.pagination d={@documents} e="doc_page"/>
    </div>
    """
  end
end
