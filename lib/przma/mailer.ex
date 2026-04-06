defmodule Przma.Mailer do
  @moduledoc "Stub mailer — email not used in PRZMA Phase 1."
  # Swoosh removed from deps as PRZMA does not send email.
  # Phase 2: implement transactional email via Req + SendGrid if needed.

  def deliver(_email), do: {:ok, %{}}
  def deliver_many(_emails), do: {:ok, []}
end
