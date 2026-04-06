defmodule PrzmaWeb.Presence do
  use Phoenix.Presence,
    otp_app: :przma,
    pubsub_server: Przma.PubSub
end
