defmodule AlemWeb.Presence do
  use Phoenix.Presence,
    otp_app: :alem,
    pubsub_server: Alem.PubSub
end
