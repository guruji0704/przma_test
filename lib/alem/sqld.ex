defmodule Alem.Sqld do
  @moduledoc """
  sqld / libSQL HTTP client for PRZMA.

  ## Architecture

      Linode VPS (172.235.17.68)
        │
        └── sqld systemd service (port 8080)
              │  DB: /var/lib/sqld/data/przma.db
              │
              └── bottomless replication →  Linode Object Storage (perkeep)
                                            Real-time, automatic
                                            Recovery time: ~8 seconds
                                            Data loss: zero

  ## How writes work

  1. Your code calls Alem.Sqld.execute(sql, args, routing_key: user.id)
  2. The query hits sqld at 172.235.17.68:8080 over HTTP
  3. sqld writes to local SSD (0.1–1ms) AND replicates to Linode Object Storage
  4. If the server restarts, sqld restores from cloud automatically

  ## Usage

      # INSERT / UPDATE / DELETE
      Alem.Sqld.execute(sql, args, routing_key: user.id)

      # SELECT — returns list of maps
      {:ok, rows} = Alem.Sqld.query(sql, args, routing_key: user.id)

      # Schema bootstrap (run once per instance)
      Alem.Sqld.ensure_schema()

  ## Scaling (future)

  When you add more sqld instances, set:
    SQLD_URLS=http://sqld-1:8080,http://sqld-2:8080

  The routing_key ensures each user always goes to the same instance.
  No code changes needed here — Alem.Sqld.Router handles the routing.
  """

  require Logger
  alias Alem.Sqld.Router

  # ── Schema bootstrap ─────────────────────────────────────────────────────────

  @doc """
  Creates the documents table on all sqld instances in the pool.

  Called automatically 2 seconds after Phoenix starts (see application.ex).
  Safe to call multiple times — uses CREATE TABLE IF NOT EXISTS.

  With your current single-instance setup, this runs against
  http://172.235.17.68:8080 once at startup.
  """
  def ensure_schema do
    Logger.info("[sqld] Bootstrapping schema on #{Router.pool_size()} instance(s)…")

    sql = """
    CREATE TABLE IF NOT EXISTS documents (
      id               TEXT PRIMARY KEY,
      user_id          TEXT NOT NULL,
      filename         TEXT NOT NULL,
      automerge_state  BLOB,
      s3_content_key   TEXT,
      content_type     TEXT DEFAULT 'application/octet-stream',
      device_id        TEXT,
      last_modified_at TEXT,
      file_size        INTEGER DEFAULT 0,
      status           TEXT DEFAULT 'synced',
      inserted_at      TEXT NOT NULL,
      updated_at       TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_docs_user    ON documents(user_id);
    CREATE INDEX IF NOT EXISTS idx_docs_updated ON documents(updated_at);
    """

    # Run against every instance in the pool (currently just one)
    Enum.each(Router.all_urls(), fn url ->
      case do_execute(sql, [], url) do
        :ok              -> Logger.info("[sqld] ✅ Schema ready on #{url}")
        {:error, reason} -> Logger.error("[sqld] ❌ Schema failed on #{url}: #{inspect(reason)}")
      end
    end)
  end

  # ── execute/3 — INSERT / UPDATE / DELETE ─────────────────────────────────────

  @doc """
  Execute a write SQL statement (INSERT, UPDATE, DELETE).

  ## Options

      routing_key: user.id or namespace_key
        Routes to the correct sqld instance for this user.
        With a single instance, this is ignored.

      url: "http://sqld-2:8080"
        Override routing and go to a specific instance.

  ## Examples

      # Route by user ID (recommended)
      :ok = Alem.Sqld.execute(sql, args, routing_key: user.id)

      # Route by namespace key (same effect, more explicit)
      :ok = Alem.Sqld.execute(sql, args, routing_key: namespace_key)
  """
  def execute(sql, args \\ [], opts \\ []) do
    url = resolve_url(opts)
    do_execute(sql, args, url)
  end

  # ── query/3 — SELECT ─────────────────────────────────────────────────────────

  @doc """
  Execute a SELECT query and return rows as a list of maps.

  ## Options

  Same as execute/3 — routing_key or url.

  ## Returns

      {:ok, [%{"id" => "...", "filename" => "..."}, ...]}
      {:error, reason}

  ## Example

      {:ok, rows} = Alem.Sqld.query(
        "SELECT * FROM documents WHERE user_id = ?",
        [user.id],
        routing_key: user.id
      )
  """
  def query(sql, args \\ [], opts \\ []) do
    url = resolve_url(opts)
    do_query(sql, args, url)
  end

  # ── Lower-level functions ─────────────────────────────────────────────────────

  @doc "Execute on a specific URL — bypasses routing."
  def execute_on(sql, args \\ [], sqld_url), do: do_execute(sql, args, sqld_url)

  @doc "Query on a specific URL — bypasses routing."
  def query_on(sql, args \\ [], sqld_url), do: do_query(sql, args, sqld_url)

  # ── Private ───────────────────────────────────────────────────────────────────

  defp resolve_url(opts) do
    case Keyword.fetch(opts, :url) do
      {:ok, explicit_url} ->
        explicit_url
      :error ->
        routing_key = Keyword.get(opts, :routing_key)
        Router.url_for(routing_key)
    end
  end

  defp do_execute(sql, args, sqld_url) do
    body = build_body(sql, args)

    case post(sqld_url, body) do
      {:ok, %{status: 200, body: resp}} ->
        case resp do
          %{"results" => [%{"response" => %{"error" => error}} | _]} ->
            Logger.error("[sqld] SQL error on #{sqld_url}: #{inspect(error)}")
            {:error, {:sql_error, error}}
          _ ->
            :ok
        end

      {:ok, %{status: status, body: resp}} ->
        Logger.error("[sqld] HTTP #{status} on #{sqld_url}: #{inspect(resp)}")
        {:error, {:http, status}}

      {:error, reason} ->
        Logger.error("[sqld] Connection failed to #{sqld_url}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp do_query(sql, args, sqld_url) do
    body = build_body(sql, args)

    case post(sqld_url, body) do
      {:ok, %{status: 200, body: resp}} ->
        result    = resp["results"] |> List.first()
        cols      = get_in(result, ["response", "result", "cols"]) || []
        rows      = get_in(result, ["response", "result", "rows"]) || []
        col_names = Enum.map(cols, & &1["name"])

        mapped = Enum.map(rows, fn row ->
          col_names
          |> Enum.zip(row)
          |> Enum.map(fn {col, cell} -> {col, cell["value"]} end)
          |> Map.new()
        end)

        {:ok, mapped}

      {:ok, %{status: status, body: resp}} ->
        Logger.error("[sqld] HTTP #{status} on #{sqld_url}: #{inspect(resp)}")
        {:error, {:http, status}}

      {:error, reason} ->
        Logger.error("[sqld] Connection failed to #{sqld_url}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp post(sqld_url, body) do
    Req.post(
      "#{sqld_url}/v3/pipeline",
      body:            body,
      headers:         [{"content-type", "application/json"}],
      receive_timeout: 15_000,
      retry:           :transient,
      max_retries:     3
    )
  end

  defp build_body(sql, args) do
    Jason.encode!(%{
      requests: [
        %{type: "execute", stmt: %{sql: sql, args: Enum.map(args, &encode_arg/1)}},
        %{type: "close"}
      ]
    })
  end

  # sqld expects typed argument objects
  defp encode_arg(nil),                  do: %{"type" => "null",    "value" => nil}
  defp encode_arg(v) when is_integer(v), do: %{"type" => "integer", "value" => to_string(v)}
  defp encode_arg(v) when is_binary(v) do
    if String.valid?(v),
      do:   %{"type" => "text",  "value" => v},
      else: %{"type" => "blob",  "base64" => Base.encode64(v)}
  end
  defp encode_arg(v), do: %{"type" => "text", "value" => to_string(v)}
end
