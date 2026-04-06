defmodule PrzmaWeb.XRPCRouter do
  @moduledoc """
  Central XRPC dispatcher.

  Routes validated XRPC calls to the appropriate handler module.
  All requests here have already passed LexiconRegistry validation
  via the XRPCLexiconValidate plug.

  Handler lookup: lexicon_id → handler module + function.
  STUB: Most handlers return a placeholder response for Phase 1 testing.
  """
  use PrzmaWeb, :controller

  # ── HANDLER REGISTRY ──────────────────────────────────────────────────────
  # Maps lexicon_id → {Module, :function}
  @handlers %{
    # Inbox / Outbox
    "app.przma.inbox.list"           => {PrzmaWeb.XRPC.InboxHandler,   :list},
    "app.przma.inbox.markRead"       => {PrzmaWeb.XRPC.InboxHandler,   :mark_read},
    "app.przma.inbox.delete"         => {PrzmaWeb.XRPC.InboxHandler,   :delete},
    "app.przma.outbox.list"          => {PrzmaWeb.XRPC.OutboxHandler,  :list},
    "app.przma.outbox.retry"         => {PrzmaWeb.XRPC.OutboxHandler,  :retry},

    # DM chat
    "app.przma.chat.dm.send"         => {PrzmaWeb.XRPC.DMHandler,      :send_message},
    "app.przma.chat.dm.list"         => {PrzmaWeb.XRPC.DMHandler,      :list},
    "app.przma.chat.dm.threads"      => {PrzmaWeb.XRPC.DMHandler,      :threads},
    "app.przma.chat.dm.delete"       => {PrzmaWeb.XRPC.DMHandler,      :delete},
    "app.przma.chat.dm.react"        => {PrzmaWeb.XRPC.DMHandler,      :react},

    # Vault
    "app.przma.vault.put"            => {PrzmaWeb.XRPC.VaultHandler,   :put},
    "app.przma.vault.get"            => {PrzmaWeb.XRPC.VaultHandler,   :get},
    "app.przma.vault.list"           => {PrzmaWeb.XRPC.VaultHandler,   :list},
    "app.przma.vault.delete"         => {PrzmaWeb.XRPC.VaultHandler,   :delete},
    "app.przma.vault.grant"          => {PrzmaWeb.XRPC.VaultHandler,   :grant}
  }

  def handle(conn, _params) do
    lexicon_id = conn.assigns[:lexicon_id] || List.last(conn.path_info)
    params     = Map.merge(conn.params || %{}, conn.body_params || %{})

    case Map.get(@handlers, lexicon_id) do
      {module, function} ->
        apply(module, function, [conn, params])

      nil ->
        # Generic stub response for unimplemented handlers
        json(conn, %{
          lexicon: lexicon_id,
          status:  "stub",
          message: "Handler not yet implemented (Phase 2)",
          did:     conn.assigns[:current_did],
          params:  params
        })
    end
  end
end
