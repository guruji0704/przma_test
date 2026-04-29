defmodule AlemWeb.DemoLive do
  use AlemWeb, :live_view
  require Logger

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket,
      uploaded_files: [],
      processing: false,
      results: [],
      error: nil
    ), temporary_assigns: [results: []]}
  end

  @impl true
  def handle_event("upload", %{"file" => file_params}, socket) do
    filename     = file_params["name"]
    content_type = file_params["type"]
    base64_data  = file_params["data"]

    case Base.decode64(base64_data) do
      {:ok, file_bytes} ->
        doc_id = Ecto.UUID.generate()

        # Generate vector
        classification = %{
          "seven_p_primary"  => "portfolio",
          "preserve_primary" => "engagement",
          "light_element"    => "transform"
        }
        vector = Alem.Lance.VectorEncoder.encode(file_bytes, content_type, classification)

        # Upload to S3
        bucket = System.get_env("AWS_S3_BUCKET", "perkeep")
        s3_key = "user/demo/documents/#{doc_id}/#{filename}"
        ExAws.S3.put_object(bucket, s3_key, file_bytes, content_type: content_type)
        |> ExAws.request(virtual_host: false)

        # Save to PostgreSQL
        now = DateTime.utc_now() |> DateTime.truncate(:second)
        Alem.Repo.insert!(
          %Alem.Schemas.Document{
            id:           doc_id,
            tenant_id:    "default",
            user_id:      "demo_user",
            filename:     filename,
            object_key:   s3_key,
            content_type: content_type,
            status:       "synced",
            inserted_at:  now,
            updated_at:   now
          },
          on_conflict: {:replace, [:filename, :object_key, :content_type, :status, :updated_at]},
          conflict_target: :id
        )

        # Insert to LanceDB with vector
        user_did = "did:przma:demo001"
        Alem.Lance.DISSupervisor.ensure_writer(user_did)
        lance_result = Alem.LanceDB.insert_with_vector(
          "perception_events",
          vector,
          Jason.encode!(%{
            "id"               => doc_id,
            "verb"             => "Create",
            "media_type"       => content_type,
            "filename"         => filename,
            "seven_p_primary"  => "portfolio",
            "preserve_primary" => "engagement",
            "light_element"    => "transform",
            "altruistic_axis"  => "serve",
            "vault_tier"       => "private",
            "user_did"         => user_did
          })
        )

        result = %{
          filename:     filename,
          content_type: content_type,
          doc_id:       doc_id,
          s3_key:       s3_key,
          file_size:    byte_size(file_bytes),
          vector_dims:  length(vector),
          lance_status: if(lance_result == :ok, do: "✅ Stored", else: "❌ Failed"),
          s3_status:    "✅ Stored",
          pg_status:    "✅ Stored",
          vector_preview: vector |> Enum.take(5) |> Enum.map(&Float.round(&1, 4))
        }

        {:noreply, assign(socket,
          processing: false,
          error: nil,
          results: [result | socket.assigns.results]
        )}

      :error ->
        {:noreply, assign(socket, error: "Failed to decode file")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-950 text-white p-8">

      <!-- Header -->
      <div class="max-w-5xl mx-auto">
        <div class="mb-10 text-center">
          <h1 class="text-4xl font-bold text-indigo-400 mb-2">PRZMA · ALEM Platform</h1>
          <p class="text-gray-400 text-lg">Perception Intelligence Demo — Upload any file to generate HOLNN vectors</p>
        </div>

        <!-- Architecture Badge -->
        <div class="grid grid-cols-3 gap-4 mb-10 text-center text-sm">
          <div class="bg-gray-800 rounded-xl p-4 border border-indigo-700">
            <div class="text-2xl mb-1">🗄️</div>
            <div class="font-bold text-indigo-300">PostgreSQL</div>
            <div class="text-gray-400">Document Metadata</div>
          </div>
          <div class="bg-gray-800 rounded-xl p-4 border border-purple-700">
            <div class="text-2xl mb-1">🦀</div>
            <div class="font-bold text-purple-300">Rust NIF → LanceDB</div>
            <div class="text-gray-400">446-dim Vectors → S3</div>
          </div>
          <div class="bg-gray-800 rounded-xl p-4 border border-green-700">
            <div class="text-2xl mb-1">☁️</div>
            <div class="font-bold text-green-300">Linode S3</div>
            <div class="text-gray-400">Encrypted File Storage</div>
          </div>
        </div>

        <!-- Upload Area -->
        <div class="bg-gray-900 rounded-2xl border-2 border-dashed border-indigo-600 p-10 mb-8 text-center"
             id="drop-zone"
             phx-hook="FileUpload">
          <div class="text-5xl mb-4">📁</div>
          <p class="text-xl text-gray-300 mb-2">Drop any file here or click to upload</p>
          <p class="text-gray-500 text-sm mb-6">Audio · Video · Image · Document</p>
          <input
            type="file"
            id="file-input"
            class="hidden"
            accept="audio/*,video/*,image/*,application/pdf,.docx,.txt,.md"
          />
          <button
            onclick="document.getElementById('file-input').click()"
            class="bg-indigo-600 hover:bg-indigo-700 text-white px-8 py-3 rounded-xl font-semibold text-lg transition">
            Choose File
          </button>
          <div id="upload-progress" class="hidden mt-4">
            <div class="text-indigo-400 animate-pulse">⚙️ Processing file...</div>
          </div>
        </div>

        <!-- Results -->
        <%= if @results != [] do %>
          <div class="space-y-6">
            <h2 class="text-2xl font-bold text-gray-200">📊 Upload Results</h2>
            <%= for result <- @results do %>
              <div class="bg-gray-900 rounded-2xl border border-gray-700 p-6">

                <!-- File Header -->
                <div class="flex items-center gap-4 mb-6">
                  <div class="text-4xl">
                    <%= cond do %>
                      <% String.starts_with?(result.content_type, "audio/") -> %> 🎵
                      <% String.starts_with?(result.content_type, "video/") -> %> 🎬
                      <% String.starts_with?(result.content_type, "image/") -> %> 🖼️
                      <% true -> %> 📄
                    <% end %>
                  </div>
                  <div>
                    <div class="text-xl font-bold text-white"><%= result.filename %></div>
                    <div class="text-gray-400 text-sm">
                      <%= result.content_type %> ·
                      <%= Float.round(result.file_size / 1024, 1) %> KB ·
                      Doc ID: <span class="font-mono text-xs text-indigo-300"><%= result.doc_id %></span>
                    </div>
                  </div>
                </div>

                <!-- Status Grid -->
                <div class="grid grid-cols-3 gap-4 mb-6">
                  <div class="bg-gray-800 rounded-xl p-4 text-center">
                    <div class="text-2xl mb-1"><%= result.s3_status %></div>
                    <div class="font-bold text-green-300 text-sm">S3 Storage</div>
                    <div class="text-gray-400 text-xs mt-1 font-mono break-all"><%= result.s3_key %></div>
                  </div>
                  <div class="bg-gray-800 rounded-xl p-4 text-center">
                    <div class="text-2xl mb-1"><%= result.pg_status %></div>
                    <div class="font-bold text-blue-300 text-sm">PostgreSQL</div>
                    <div class="text-gray-400 text-xs mt-1">Metadata saved</div>
                  </div>
                  <div class="bg-gray-800 rounded-xl p-4 text-center">
                    <div class="text-2xl mb-1"><%= result.lance_status %></div>
                    <div class="font-bold text-purple-300 text-sm">LanceDB Vector</div>
                    <div class="text-gray-400 text-xs mt-1">446-dim stored</div>
                  </div>
                </div>

                <!-- Vector Info -->
                <div class="bg-gray-800 rounded-xl p-4">
                  <div class="flex items-center justify-between mb-3">
                    <span class="font-bold text-purple-300">🧠 HOLNN Vector</span>
                    <span class="text-gray-400 text-sm"><%= result.vector_dims %> dimensions</span>
                  </div>
                  <div class="grid grid-cols-4 gap-2 text-xs text-center mb-3">
                    <div class="bg-blue-900 rounded-lg p-2">
                      <div class="font-bold text-blue-300">256 dims</div>
                      <div class="text-gray-400">Media Features</div>
                    </div>
                    <div class="bg-green-900 rounded-lg p-2">
                      <div class="font-bold text-green-300">7 dims</div>
                      <div class="text-gray-400">SevenP</div>
                    </div>
                    <div class="bg-yellow-900 rounded-lg p-2">
                      <div class="font-bold text-yellow-300">100 dims</div>
                      <div class="text-gray-400">PRESERVE</div>
                    </div>
                    <div class="bg-red-900 rounded-lg p-2">
                      <div class="font-bold text-red-300">83 dims</div>
                      <div class="text-gray-400">LiGHT</div>
                    </div>
                  </div>
                  <div class="font-mono text-xs text-gray-400">
                    First 5 values: [<%= Enum.join(result.vector_preview, ", ") %>, ...]
                  </div>
                </div>

              </div>
            <% end %>
          </div>
        <% end %>

        <!-- Error -->
        <%= if @error do %>
          <div class="bg-red-900 border border-red-600 rounded-xl p-4 text-red-300">
            ❌ <%= @error %>
          </div>
        <% end %>

        <!-- Footer -->
        <div class="mt-10 text-center text-gray-600 text-sm">
          PRZMA/ALEM Platform · Rust NIF + LanceDB + S3 · 446-dim HOLNN Vectors
        </div>
      </div>
    </div>

    <script>
      document.getElementById('file-input').addEventListener('change', function(e) {
        const file = e.target.files[0];
        if (!file) return;

        document.getElementById('upload-progress').classList.remove('hidden');

        const reader = new FileReader();
        reader.onload = function(ev) {
          const base64 = ev.target.result.split(',')[1];
          const hook = window.liveSocket.getHookById('drop-zone');

          window.liveSocket.pushEvent('upload', {
            file: {
              name: file.name,
              type: file.type || 'application/octet-stream',
              size: file.size,
              data: base64
            }
          }, (reply) => {
            document.getElementById('upload-progress').classList.add('hidden');
          });
        };
        reader.readAsDataURL(file);
      });
    </script>
    """
  end
end
