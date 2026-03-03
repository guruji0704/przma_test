defmodule Alem.Session do
  @moduledoc """
  Session tracking — one record per login.
  Stores device, IP, and user_agent so users can see and revoke active sessions.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  alias Alem.Repo

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :naive_datetime_usec]

  schema "sessions" do
    field :device,         :string
    field :ip_address,     :string
    field :user_agent,     :string
    field :last_active_at, :naive_datetime_usec
    field :revoked_at,     :naive_datetime_usec

    belongs_to :user, Alem.Pleroma.User, type: :string

    timestamps()
  end

  # ---------------------------------------------------------------------------
  # Create a session after successful login
  # call: Session.create(user.id, Session.conn_info(conn))
  # ---------------------------------------------------------------------------
  def create(user_id, conn_info) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:microsecond)

    %Alem.Session{}
    |> cast(%{
      id:             generate_id(),
      user_id:        user_id,
      device:         conn_info[:device],
      ip_address:     conn_info[:ip_address],
      user_agent:     conn_info[:user_agent],
      last_active_at: now
    }, [:id, :user_id, :device, :ip_address, :user_agent, :last_active_at])
    |> Repo.insert()
  end

  # ---------------------------------------------------------------------------
  # List all active (non-revoked) sessions for a user
  # ---------------------------------------------------------------------------
  def list_active(user_id) do
    from(s in Alem.Session,
      where: s.user_id == ^user_id,
      where: is_nil(s.revoked_at),
      order_by: [desc: s.last_active_at]
    )
    |> Repo.all()
  end

  # ---------------------------------------------------------------------------
  # Revoke a single session (only if it belongs to this user)
  # ---------------------------------------------------------------------------
  def revoke(session_id, user_id) do
    case Repo.get_by(Alem.Session, id: session_id, user_id: user_id) do
      nil ->
        {:error, :not_found}

      session ->
        now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:microsecond)
        session |> change(revoked_at: now) |> Repo.update()
    end
  end

  # ---------------------------------------------------------------------------
  # Revoke ALL sessions for a user (logout from every device)
  # ---------------------------------------------------------------------------
  def revoke_all(user_id) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:microsecond)

    from(s in Alem.Session,
      where: s.user_id == ^user_id,
      where: is_nil(s.revoked_at)
    )
    |> Repo.update_all(set: [revoked_at: now])
  end

  # ---------------------------------------------------------------------------
  # Extract device/IP/user_agent from a Plug.Conn
  # ---------------------------------------------------------------------------
  def conn_info(conn) do
    ip =
      case Plug.Conn.get_req_header(conn, "x-forwarded-for") do
        [forwarded | _] ->
          forwarded |> String.split(",") |> List.first() |> String.trim()
        [] ->
          conn.remote_ip |> :inet.ntoa() |> List.to_string()
      end

    ua = Plug.Conn.get_req_header(conn, "user-agent") |> List.first("")

    device =
      cond do
        String.contains?(ua, "Mobile")  -> "mobile"
        String.contains?(ua, "Tablet")  -> "tablet"
        String.contains?(ua, "curl")    -> "api_client"
        String.contains?(ua, "python")  -> "api_client"
        ua == ""                        -> "unknown"
        true                            -> "desktop"
      end

    %{ip_address: ip, user_agent: ua, device: device}
  end

  # ---------------------------------------------------------------------------

  defp generate_id do
    :crypto.strong_rand_bytes(15) |> Base.url_encode64(padding: false)
  end
end
