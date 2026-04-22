defmodule AlemWeb.Admin.LanceDBLive do
  use AlemWeb, :live_view
  alias Alem.LanceDB

  @impl true
  def mount(_params, _session, socket) do
    tables = LanceDB.list_tables()
    
    {:ok, 
     socket 
     |> assign(tables: tables)
     |> assign(current_table: List.first(tables))
     |> assign(rows: [])
     |> assign(search: "")
     |> fetch_data()}
  end

  @impl true
  def handle_params(%{"table" => table}, _uri, socket) do
    if table in socket.assigns.tables do
      {:noreply, socket |> assign(current_table: table) |> fetch_data()}
    else
      {:noreply, socket}
    end
  end
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("select-table", %{"table" => table}, socket) do
    {:noreply, push_patch(socket, to: ~p"/dev/lancedb?table=#{table}")}
  end

  @impl true
  def handle_event("search", %{"value" => value}, socket) do
    {:noreply, socket |> assign(search: value) |> fetch_data()}
  end

  defp fetch_data(socket) do
    case socket.assigns.current_table do
      nil -> assign(socket, rows: [])
      table ->
        # Simple query for the dashboard
        # If search is present, we filter (Note: very basic SQL-like filter for demo)
        filter = if socket.assigns.search != "", do: "filename LIKE '%#{socket.assigns.search}%' OR id LIKE '%#{socket.assigns.search}%'", else: ""
        
        json_str = LanceDB.query(table, filter, 50)
        rows = case Jason.decode(json_str) do
          {:ok, data} -> data
          _ -> []
        end
        
        assign(socket, rows: rows)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen bg-gray-900 text-gray-100 font-sans">
      <!-- Sidebar -->
      <div class="w-64 bg-gray-800 border-r border-gray-700 flex flex-col">
        <div class="p-6 border-b border-gray-700">
          <h1 class="text-xl font-bold text-white flex items-center gap-2">
            <span class="text-blue-500">przma</span> LanceDB
          </h1>
        </div>
        <nav class="flex-1 overflow-y-auto p-4 space-y-2">
          <%= for table <- @tables do %>
            <button 
              phx-click="select-table" 
              phx-value-table={table}
              class={"w-full text-left px-4 py-2 rounded-lg transition-all #{if @current_table == table, do: "bg-blue-600 text-white shadow-lg shadow-blue-900/50", else: "text-gray-400 hover:bg-gray-700 hover:text-white"}"}
            >
              <%= table %>
            </button>
          <% end %>
        </nav>
      </div>

      <!-- Main Content -->
      <div class="flex-1 flex flex-col overflow-hidden">
        <!-- Header -->
        <header class="bg-gray-800 border-b border-gray-700 px-8 py-4 flex items-center justify-between">
          <div class="flex items-center gap-4">
            <h2 class="text-lg font-semibold text-white">Table: <span class="text-blue-400"><%= @current_table %></span></h2>
            <span class="px-2 py-0.5 rounded text-xs font-mono bg-gray-700 text-gray-400">arrow-native</span>
          </div>
          
          <div class="relative w-96">
            <input 
              type="text" 
              phx-keyup="search" 
              phx-debounce="300"
              placeholder="Filter by ID or Filename..." 
              class="w-full bg-gray-700 border-gray-600 rounded-lg pl-10 pr-4 py-2 text-sm focus:ring-2 focus:ring-blue-500 focus:border-transparent transition-all outline-none"
            />
            <div class="absolute left-3 top-2.5 text-gray-500">
              <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z" />
              </svg>
            </div>
          </div>
        </header>

        <!-- Table View -->
        <main class="flex-1 overflow-auto p-8">
          <div class="bg-gray-800 border border-gray-700 rounded-xl overflow-hidden shadow-2xl">
            <%# Get columns from first row if exists %>
            <% cols = if length(@rows) > 0, do: Map.keys(hd(@rows)), else: [] %>
            
            <table class="w-full text-left border-collapse">
              <thead class="bg-gray-700/50 border-b border-gray-700">
                <tr>
                  <%= for col <- cols do %>
                    <th class="px-4 py-3 text-xs font-bold uppercase tracking-wider text-gray-400">
                      <%= col %>
                    </th>
                  <% end %>
                </tr>
              </thead>
              <tbody class="divide-y divide-gray-700">
                <%= for row <- @rows do %>
                  <tr class="hover:bg-gray-700/30 transition-colors">
                    <%= for col <- cols do %>
                      <td class="px-4 py-3 text-sm font-mono text-gray-300 truncate max-w-xs" title={inspect(row[col])}>
                        <%= format_cell(row[col]) %>
                      </td>
                    <% end %>
                  </tr>
                <% end %>
                <%= if Enum.empty?(@rows) do %>
                  <tr>
                    <td colspan={length(cols) + 1} class="px-4 py-20 text-center text-gray-500">
                      <div class="flex flex-col items-center gap-2">
                        <svg xmlns="http://www.w3.org/2000/svg" class="h-10 w-10 text-gray-600" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z" />
                        </svg>
                        <p>No records found in this table.</p>
                      </div>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        </main>
      </div>
    </div>
    """
  end

  defp format_cell(val) when is_map(val) or is_list(val), do: Jason.encode!(val)
  defp format_cell(val), do: to_string(val)
end
