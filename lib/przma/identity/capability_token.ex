defmodule Przma.Identity.CapabilityToken do
  @moduledoc """
  STUB: Scoped capability tokens for AI agents.

  TODO Phase 2: Issue short-lived tokens that grant an agent
  specific permissions on a subset of vault paths. Uses
  the same JWT format as DID auth but with a "cap" claim.
  """

  @doc "Issue a capability token for an agent."
  def issue(owner_did, capabilities) do
    {:ok, token} = Przma.Identity.JWT.issue(owner_did)
    {:ok, %{token: token, owner_did: owner_did, capabilities: capabilities}}
  end

  @doc "Verify an agent capability token."
  def verify_agent(token) do
    case Przma.Identity.JWT.verify(token) do
      {:ok, claims} ->
        {:ok, %{
          owner_did:    claims["sub"],
          capabilities: claims["cap"] || []
        }}
      err -> err
    end
  end
end
