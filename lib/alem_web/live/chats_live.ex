defmodule AlemWeb.ChatsLive do
  use AlemWeb, :live_view
  alias Alem.{Repo, Chat}
  alias Alem.Pleroma.User

  @impl true
  def mount(_params, session, socket) do
    user = case session["user_id"] do
      nil -> nil
      uid -> Repo.get(User, uid)
    end
    if is_nil(user), do: {:ok, redirect(socket, to: "/panel/login")}

    convs = Chat.list_conversations(user.did_id)

    {:ok,
     socket
     |> assign(:user,           user)
     |> assign(:conversations,  convs)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <style>
      :root,[data-theme="dark"]{--bg:#0c0e13;--bg-2:#13161e;--bg-3:#1a1e29;--bg-4:#222737;--border:rgba(255,255,255,0.07);--border-2:rgba(255,255,255,0.13);--text:#f0f2f8;--text-2:#8b92a9;--text-3:#4e566b;--primary:#5c73f2;--primary-d:rgba(92,115,242,0.15);--primary-glow:rgba(92,115,242,0.3);--green:#10b981;--green-d:rgba(16,185,129,0.12);--purple:#a78bfa;--shadow:0 1px 3px rgba(0,0,0,0.5),0 4px 16px rgba(0,0,0,0.25);--r:10px;--r-sm:6px;--r-lg:14px;color-scheme:dark}
      [data-theme="light"]{--bg:#f2f4f8;--bg-2:#ffffff;--bg-3:#f8f9fc;--bg-4:#eef0f6;--border:rgba(0,0,0,0.07);--border-2:rgba(0,0,0,0.13);--text:#0f1117;--text-2:#5a6172;--text-3:#9ca3b4;--primary:#4f63e8;--primary-d:rgba(79,99,232,0.1);--green:#059669;--green-d:rgba(5,150,105,0.1);--purple:#7c3aed;--shadow:0 1px 3px rgba(0,0,0,0.08),0 4px 16px rgba(0,0,0,0.06);color-scheme:light}
      *,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
      body{font-family:'DM Sans',system-ui,sans-serif;background:var(--bg);color:var(--text)}
    </style>
    <div style="padding:20px;max-width:600px">
      <div style="display:flex;align-items:center;gap:10px;margin-bottom:20px">
        <a href="/panel" style="color:var(--text-2);text-decoration:none;font-size:18px">←</a>
        <h2 style="font-size:18px;font-weight:700;color:var(--text)">Messages</h2>
      </div>

      <%= if @conversations == [] do %>
        <div style="text-align:center;color:var(--text-3);padding:40px 0">
          <div style="font-size:32px;margin-bottom:12px">💬</div>
          <div style="font-size:14px;font-weight:600;color:var(--text-2);margin-bottom:8px">No conversations yet</div>
          <div style="font-size:12px;margin-bottom:16px">Connect with someone to start chatting</div>
          <a href="/social" style="background:var(--primary);color:#fff;padding:8px 16px;border-radius:8px;text-decoration:none;font-size:13px;font-weight:600">
            Find People →
          </a>
        </div>
      <% else %>
        <%= for conv <- @conversations do %>
          <a href={"/chat/#{conv.id}"} style="display:flex;align-items:center;gap:12px;
            padding:12px;border-radius:var(--r);border:1px solid var(--border);
            background:var(--bg-2);margin-bottom:8px;text-decoration:none;
            transition:background .15s" onmouseover="this.style.background='var(--bg-3)'"
            onmouseout="this.style.background='var(--bg-2)'">
            <div style="width:40px;height:40px;border-radius:50%;
              background:linear-gradient(135deg,var(--primary),var(--purple));
              display:flex;align-items:center;justify-content:center;
              font-size:16px;font-weight:700;color:#fff;flex-shrink:0">
              <%= if conv.type == "group", do: "👥", else: "💬" %>
            </div>
            <div>
              <div style="font-size:14px;font-weight:600;color:var(--text)">
                <%= conv.name || "Direct Message" %>
              </div>
              <div style="font-size:11px;color:var(--text-3)">
                <%= conv.type %> · <%= conv.member_count %> members
              </div>
            </div>
          </a>
        <% end %>
      <% end %>
    </div>
    """
  end
end
