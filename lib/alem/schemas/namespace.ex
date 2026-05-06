defmodule Alem.Schemas.Namespace do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime]

  @folder_types ~w(personal private public platform)
  @statuses     ~w(active suspended deleted)

  schema "namespaces" do
    field :tenant_id,         :string
    field :config,            :map,     default: %{}
    field :status,            :string,  default: "active"
    field :document_count,    :integer, default: 0
    field :vector_count,      :integer, default: 0
    field :storage_bytes,     :integer, default: 0
    field :did,               :string
    field :identity_type,     :string,  default: "did"
    field :last_activity_at,  :utc_datetime
    # ── Home Folder Fields ──────────────────────────────────────────
    field :folder_type,       :string,  default: "personal"
    # personal | private | public | platform
    field :parent_did,        :string
    # DID of the owning user — null for platform namespaces

    timestamps()
  end

  def changeset(namespace, attrs) do
    namespace
    |> cast(attrs, [:id, :tenant_id, :config, :status, :document_count,
                    :vector_count, :storage_bytes, :last_activity_at,
                    :did, :identity_type, :folder_type, :parent_did])
    |> validate_required([:id, :tenant_id])
    |> validate_inclusion(:status,      @statuses)
    |> validate_inclusion(:folder_type, @folder_types)
  end

  @doc """
  Builds the namespace key for a given user DID and folder type.
    personal → {16-char prefix}-personal
    private  → {16-char prefix}-private
    public   → {16-char prefix}-public
  """
  def namespace_key(did, folder) when folder in @folder_types do
    prefix = Alem.DID.namespace_key(did)
    "#{prefix}-#{folder}"
  end

  @doc "Returns the S3 prefix for this namespace."
  def s3_prefix(namespace_key, folder) do
    # Extract the DID prefix part (before the dash-folder suffix)
    base = namespace_key |> String.split("-") |> hd()
    "user/#{base}/#{folder}/"
  end
end
