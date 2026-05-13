defmodule Alem.Events.FileUploaded do
  @moduledoc "Emitted after successful vault CAS upload"
  defstruct [:doc_id, :user_id, :did, :vault, :filename, :content_type,
             :content_hash, :file_size, :namespace_key, :s3_key, :occurred_at]
  def new(attrs), do: struct!(__MODULE__, Map.put(attrs, :occurred_at, DateTime.utc_now()))
end

defmodule Alem.Events.VectorGenerated do
  defstruct [:doc_id, :did, :vault, :content_hash, :dims, :occurred_at]
  def new(attrs), do: struct!(__MODULE__, Map.put(attrs, :occurred_at, DateTime.utc_now()))
end

defmodule Alem.Events.VaultCreated do
  defstruct [:did, :vault, :namespace_key, :occurred_at]
  def new(attrs), do: struct!(__MODULE__, Map.put(attrs, :occurred_at, DateTime.utc_now()))
end

defmodule Alem.Events.FileShared do
  defstruct [:doc_id, :owner_did, :link_id, :conversation_id, :expires_at, :occurred_at]
  def new(attrs), do: struct!(__MODULE__, Map.put(attrs, :occurred_at, DateTime.utc_now()))
end

defmodule Alem.Events.ActivityCreated do
  defstruct [:actor_did, :action, :object_type, :object_id, :vault, :metadata, :occurred_at]
  def new(attrs), do: struct!(__MODULE__, Map.put(attrs, :occurred_at, DateTime.utc_now()))
end

defmodule Alem.Events do
  @moduledoc "Central event bus — publish events, dispatch workers, broadcast realtime"
  alias Alem.Events.FileUploaded

  def publish(%FileUploaded{vault: vault} = event) do
    Phoenix.PubSub.broadcast(Alem.PubSub, "vault:#{event.did}", {:file_uploaded, event})
    # Enqueue vector generation for non-private vaults
    if vault in [:personal, :public] do
      Alem.Workers.VectorWorker.new(%{
        "doc_id"       => event.doc_id,
        "did"          => event.did,
        "vault"        => to_string(event.vault),
        "content_hash" => event.content_hash,
        "content_type" => event.content_type
      })
    end
    :ok
  end

  def publish(%Alem.Events.FileShared{} = e) do
    Phoenix.PubSub.broadcast(Alem.PubSub, "conversation:#{e.conversation_id}",
      {:file_shared, e})
    :ok
  end

  def publish(%Alem.Events.ActivityCreated{} = e) do
    Phoenix.PubSub.broadcast(Alem.PubSub, "activity:#{e.actor_did}", {:activity, e})
    :ok
  end

  def publish(_), do: :ok
end
