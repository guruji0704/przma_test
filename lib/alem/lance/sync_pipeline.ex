defmodule Alem.Lance.SyncPipeline do
  @moduledoc "Broadway pipeline that batches perception events and writes to LanceDB."

  use Broadway
  require Logger

  alias Alem.Lance.{DISSupervisor, LanceWriter}
  alias Alem.Przma.{Types, VerbRegistry}

  def start_link(_opts) do
    Broadway.start_link(__MODULE__,
      name: __MODULE__,
      producer: [
        module: {Broadway.DummyProducer, []},
        concurrency: 1,
      ],
      processors: [
        default: [concurrency: 5],
      ],
      batchers: [
        lance_write: [
          concurrency:   2,
          batch_size:    50,
          batch_timeout: 500,
          partition_by:  &partition_by_did/1,
        ],
      ]
    )
  end

  @doc "Push an event payload into the pipeline. Called from controllers/channels."
  def push(user_did, payload, table \\ :perception) do
    Broadway.push_messages(__MODULE__, [
      %Broadway.Message{
        data:         payload,
        metadata:     %{user_did: user_did, table: table},
        acknowledger: Broadway.NoopAcknowledger.init(),
      }
    ])
  end

  @impl true
  def handle_message(_processor, message, _context) do
    %{user_did: user_did} = message.metadata
    case DISSupervisor.ensure_writer(user_did) do
      :ok              -> Broadway.Message.put_batcher(message, :lance_write)
      {:error, reason} -> Broadway.Message.failed(message, reason)
    end
  end

  @impl true
  def handle_batch(:lance_write, messages, _batch_info, _context) do
    case messages do
      [] -> messages
      [first | _] ->
        user_did = first.metadata.user_did
        table    = first.metadata.table

        Enum.each(messages, fn msg ->
          case table do
            :perception -> LanceWriter.insert_perception(user_did, msg.data)
            :preserve   -> LanceWriter.insert_preserve(user_did, msg.data)
            _           -> Logger.warning("[SyncPipeline] unknown table #{table}")
          end
        end)

        Logger.debug("[SyncPipeline] wrote #{length(messages)} events for #{user_did}")
        messages
    end
  end

  defp partition_by_did(%Broadway.Message{metadata: %{user_did: did}}) do
    :erlang.phash2(did)
  end
end
