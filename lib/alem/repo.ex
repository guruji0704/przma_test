defmodule Alem.Repo do
  use Ecto.Repo,
    otp_app: :alem,
    adapter: Ecto.Adapters.Postgres
end
