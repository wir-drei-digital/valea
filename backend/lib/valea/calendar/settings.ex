defmodule Valea.Calendar.Settings do
  @moduledoc """
  `config/calendar.yaml` v1 (calendar spec §Config and credentials) ⇄
  `%Settings{}`. Non-secret only — the feed URL IS a credential and never
  appears in config or any workspace file; it lives in the OS keychain
  (dev/browser fallback: the `env_var/1` environment variable), RAM-only
  in the engine.

  ## Per-entry validity

  `load/1` validates every source entry independently, the
  `Valea.Mail.Settings` valid/invalid split verbatim: a
  structurally-broken entry (bad slug grammar, malformed
  window/interval/name) lands in `invalid: %{slug => reason}` instead of
  failing the file. The ONE exception is the reserved `valea` source key
  — a config file carrying it is WHOLE-FILE `{:error, {:invalid, _}}`,
  never half-honored (spec §Storage layout: `valea` is the local
  calendar, structurally not an external source).

  ## Legacy placeholder convergence

  A legacy `account`/`caldav`/`ics_fallback`-shaped `calendar.yaml`
  predates this spec in the workspace template. `load/1`, on finding
  EXACTLY that known placeholder (an exact-value match against
  `@legacy_placeholder`, nothing looser), rewrites the file to v1-empty
  once with a logged notice. EVERY other non-v1 document — empty file,
  partial legacy keys, altered values, anything custom — is
  `{:error, {:invalid, reason}}` and is never rewritten by the read
  path.

  The convergence WRITE is itself a config mutation and participates in
  the same serialization as every other one: it runs inside
  `Valea.Calendar.Supervisor.lifecycle/1` whenever that serializer is up
  (directly otherwise — unit tests, pre-runtime) and RE-READS the file
  inside the serialized section, writing v1-empty only if the on-disk
  document is STILL the exact placeholder. A stale reader that saw the
  placeholder before a serialized `put_source/3` or
  `generate_feed_token/1` landed therefore no-ops instead of renaming
  empty bytes over the newer configuration (see `converge_legacy/1`).

  ## One canonical v1 rewrite path

  Each mutator reads the current state, applies its one change, and
  atomically writes the whole v1 document. On a VALID v1 file,
  `put_source/3` and `remove_source/2` preserve `feed.token_hash` and
  the other sources; `generate_feed_token/1` preserves sources. On an
  INVALID or legacy-shaped file, destructive convergence is authorized
  for EXACTLY the spec's two entry points and nothing else:
  `put_source/3` and `generate_feed_token/1` replace the file WHOLESALE
  with a fresh v1 carrying only their own change; `remove_source/2` is
  NON-destructive — `{:error, {:invalid, reason}}`, file byte-identical
  (there is no v1 source to remove in a non-v1 file). The mutators read
  through a non-convergent path, so even the exact legacy placeholder is
  "invalid" to them — only `load/1` converges it.
  """

  require Logger

  alias __MODULE__

  @default_past_days 30
  @default_future_days 365
  @default_interval_minutes 30
  @interval_floor_minutes 5

  @v1_empty "version: 1\nsources: {}\n"

  # `^[a-z0-9][a-z0-9-]{0,31}$` — the Valea.Mail.Settings slug grammar:
  # lowercase, digits, and internal dashes only; 1-32 chars total.
  # Directory-safe (keychain entries and `sources/calendar/<slug>/` key on
  # it) and safe to interpolate unquoted as a YAML mapping key.
  @slug_re ~r/^[a-z0-9][a-z0-9-]{0,31}$/

  # The RESERVED local-calendar name — valid per the grammar, never valid
  # as an external source slug.
  @reserved_slug "valea"

  # The exact parsed shape of the placeholder the workspace template
  # shipped before this spec (compare with `==`: top-level keys exactly
  # this set, every value exactly these). ONLY this document converges;
  # any deviation is a hand-edited file we must not destroy on read.
  @legacy_placeholder %{
    "account" => "mara@example.com",
    "caldav" => %{
      "url" => "https://caldav.example.com/",
      "username_env" => "CALDAV_USERNAME",
      "password_env" => "CALDAV_PASSWORD"
    },
    "ics_fallback" => %{"path" => "sources/calendar/import.ics"},
    "event_types" => %{
      "session" => ["coaching", "session", "client"],
      "admin" => ["admin", "review", "bookkeeping"],
      "deep_work" => ["deep work", "focus", "writing"]
    }
  }

  defstruct sources: %{}, invalid: %{}, feed_token_hash: nil

  @type source :: %{
          name: String.t(),
          past_days: pos_integer(),
          future_days: pos_integer(),
          interval_minutes: pos_integer()
        }

  @type t :: %__MODULE__{
          sources: %{String.t() => source()},
          invalid: %{String.t() => String.t()},
          feed_token_hash: String.t() | nil
        }

  @doc """
  Loads and validates `<root>/config/calendar.yaml`. `{:error, :absent}`
  when the file is missing; `{:error, {:invalid, reason}}` for any non-v1
  document except the exact legacy placeholder, which is converged to
  v1-empty once (logged notice) and loads as zero sources. The
  convergence write is serialized against the lifecycle mutations and
  re-checked on disk there — a load that raced a concurrent setup or
  token rotation no-ops and returns whatever configuration won (see the
  moduledoc).
  """
  @spec load(String.t()) :: {:ok, t()} | {:error, :absent} | {:error, {:invalid, String.t()}}
  def load(root) when is_binary(root) do
    case read_doc(root) do
      {:ok, doc} when doc == @legacy_placeholder ->
        converge_legacy(root)

      {:ok, doc} ->
        build(doc)

      {:error, _reason} = error ->
        error
    end
  end

  @doc "Slug grammar `^[a-z0-9][a-z0-9-]{0,31}$` AND not the reserved `valea`."
  @spec valid_slug?(String.t()) :: boolean()
  def valid_slug?(slug) when is_binary(slug),
    do: Regex.match?(@slug_re, slug) and slug != @reserved_slug

  def valid_slug?(_slug), do: false

  @doc """
  Adds or updates the source at `slug` with defaulted window/interval and
  atomically rewrites the whole file. An existing entry keeps its
  window/interval config (only `name` changes); other sources and
  `feed.token_hash` are preserved on a valid v1 file. On an absent,
  invalid, or legacy-shaped file the write is a WHOLESALE fresh v1
  carrying only this source (spec §Config: the first
  `setup_calendar_source` rewrites the file wholesale to v1).
  """
  @spec put_source(String.t(), String.t(), String.t()) ::
          :ok | {:error, :invalid_slug | :invalid_name}
  def put_source(root, slug, name) when is_binary(root) do
    cond do
      not valid_slug?(slug) ->
        {:error, :invalid_slug}

      not (is_binary(name) and name != "") ->
        {:error, :invalid_name}

      true ->
        state = current_state(root)

        entry =
          case state.sources[slug] do
            nil ->
              %{
                name: name,
                past_days: @default_past_days,
                future_days: @default_future_days,
                interval_minutes: @default_interval_minutes
              }

            existing ->
              %{existing | name: name}
          end

        write_state!(root, %{state | sources: Map.put(state.sources, slug, entry)})
        :ok
    end
  end

  @doc """
  Removes the source at `slug` and rewrites the file (a no-op `:ok` when
  the slug is absent, or when the whole file is absent — nothing is ever
  created by a remove). NON-destructive on any invalid or legacy-shaped
  file: `{:error, {:invalid, reason}}` with the file byte-identical.
  """
  @spec remove_source(String.t(), String.t()) ::
          :ok | {:error, :invalid_slug | {:invalid, String.t()}}
  def remove_source(root, slug) when is_binary(root) do
    cond do
      not valid_slug?(slug) ->
        {:error, :invalid_slug}

      true ->
        case load_no_converge(root) do
          {:ok, state} ->
            write_state!(root, %{state | sources: Map.delete(state.sources, slug)})
            :ok

          {:error, :absent} ->
            :ok

          {:error, {:invalid, _reason} = invalid} ->
            {:error, invalid}
        end
    end
  end

  @doc """
  Generates a fresh served-feed token: 32 bytes of
  `:crypto.strong_rand_bytes/1`, base64url without padding. ONLY the
  sha256 hex of the token is persisted (`feed.token_hash`); the plain
  token is returned exactly once and never again recoverable. Overwriting
  an existing hash IS the rotation. Sources are preserved on a valid v1
  file; on an absent, invalid, or legacy-shaped file the write is a
  wholesale fresh v1 carrying only the token hash.
  """
  @spec generate_feed_token(String.t()) :: {:ok, String.t()}
  def generate_feed_token(root) when is_binary(root) do
    token = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    hash = :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

    write_state!(root, %{current_state(root) | feed_token_hash: hash})
    {:ok, token}
  end

  @doc """
  The dev/browser fallback environment variable NAME for `slug`'s feed
  URL: `"VALEA_CAL_URL_" <> slug` upcased with every `-` turned into `_`
  (env var names can't contain `-`).
  """
  @spec env_var(String.t()) :: String.t()
  def env_var(slug) when is_binary(slug) do
    "VALEA_CAL_URL_" <> (slug |> String.upcase() |> String.replace("-", "_"))
  end

  # -- the mutators' read path ------------------------------------------------

  # NON-convergent: the exact legacy placeholder reads as invalid here, so
  # `remove_source/2` stays byte-identically non-destructive on it and the
  # two destructive entry points replace it in ONE write. Only `load/1`
  # converges.
  defp load_no_converge(root) do
    case read_doc(root) do
      {:ok, doc} when doc == @legacy_placeholder ->
        {:error, {:invalid, "legacy placeholder config (converges on load)"}}

      {:ok, doc} ->
        build(doc)

      {:error, _reason} = error ->
        error
    end
  end

  # Absent, invalid, and legacy-shaped files all start from a fresh empty
  # state — the destructive-convergence posture of the two sanctioned
  # writers. Already-invalid ENTRIES of a valid v1 file are dropped on
  # rewrite (this call fully re-renders the file — the Valea.Mail.Settings
  # posture).
  defp current_state(root) do
    case load_no_converge(root) do
      {:ok, state} -> state
      {:error, _reason} -> %Settings{}
    end
  end

  # -- legacy convergence -----------------------------------------------------

  # The convergence write must not race the serialized lifecycle
  # mutations: a `calendar_status` load that saw the placeholder could
  # otherwise rename stale v1-empty bytes over a `setup_calendar_source`
  # or `generate_feed_token` that landed in between (both run inside
  # `Valea.Calendar.Supervisor.lifecycle/1`). So the write runs inside
  # that same serializer whenever the supervisor process is up —
  # `lifecycle/1` is re-entrant, so `load/1` calls from within lifecycle'd
  # operations (rehash, purge, supervisor init) call straight through
  # without deadlocking — and the document is RE-READ inside the
  # serialized section: only if it is STILL the exact placeholder does
  # the v1-empty write happen. A stale reader becomes a no-op and loads
  # whatever actually won. Without a supervisor (unit tests, pre-runtime)
  # the same re-read-guarded write runs directly.
  defp converge_legacy(root) do
    case serialize_through_lifecycle(fn -> converge_if_still_placeholder(root) end) do
      # `lifecycle/1` degrades a raising fun to this typed error; a
      # convergence-write failure is a disk error and load's contract is
      # to raise on those (as the direct `atomic_write!/2` path does).
      {:error, {:lifecycle_failed, message}} ->
        raise "config/calendar.yaml legacy convergence failed: #{message}"

      result ->
        result
    end
  end

  defp converge_if_still_placeholder(root) do
    case read_doc(root) do
      {:ok, doc} when doc == @legacy_placeholder ->
        atomic_write!(yaml_path(root), @v1_empty)

        Logger.info(
          "config/calendar.yaml: exact legacy placeholder detected — converged to v1 (empty sources)"
        )

        {:ok, %Settings{}}

      # A serialized mutation replaced the placeholder between the first
      # read and acquiring the serializer — load what won instead.
      {:ok, doc} ->
        build(doc)

      {:error, _reason} = error ->
        error
    end
  end

  defp serialize_through_lifecycle(fun) do
    if is_pid(Process.whereis(Valea.Calendar.Supervisor)) do
      try do
        Valea.Calendar.Supervisor.lifecycle(fun)
      catch
        # The supervisor exited between the whereis check and the call
        # (workspace closing) — the direct re-read-guarded write is all
        # that's left, and nothing else is mutating during teardown.
        :exit, {:noproc, {GenServer, :call, _args}} -> fun.()
        :exit, {:shutdown, {GenServer, :call, _args}} -> fun.()
        :exit, {{:shutdown, _reason}, {GenServer, :call, _args}} -> fun.()
      end
    else
      fun.()
    end
  end

  # -- file I/O ---------------------------------------------------------------

  defp yaml_path(root), do: Path.join(root, "config/calendar.yaml")

  defp read_doc(root) do
    path = yaml_path(root)

    with true <- File.exists?(path),
         {:ok, doc} when is_map(doc) <- YamlElixir.read_from_file(path) do
      {:ok, doc}
    else
      false ->
        {:error, :absent}

      {:ok, _not_a_map} ->
        {:error, {:invalid, "config/calendar.yaml must be a YAML mapping"}}

      {:error, %YamlElixir.FileNotFoundError{}} ->
        {:error, :absent}

      {:error, %{message: message}} ->
        {:error, {:invalid, message}}
    end
  end

  defp write_state!(root, %Settings{} = state) do
    atomic_write!(yaml_path(root), render(state))
  end

  # Unique per-write temp name (the `Valea.Calendar.Source` pattern): a
  # shared fixed `.tmp` would let one writer rename another writer's
  # half-written bytes into place; with a unique name every rename
  # installs a fully written document wholesale.
  defp atomic_write!(path, bytes) do
    File.mkdir_p!(Path.dirname(path))
    tmp = path <> ".tmp-#{System.unique_integer([:positive])}"
    File.write!(tmp, bytes)
    File.rename!(tmp, path)
  end

  # -- parsing ----------------------------------------------------------------

  defp build(doc) do
    with :ok <- require_v1(doc),
         {:ok, sources_doc} <- require_sources_map(doc),
         :ok <- reject_reserved_key(sources_doc) do
      {valid, invalid} =
        Enum.reduce(sources_doc, {%{}, %{}}, fn {slug, attrs}, {valid_acc, invalid_acc} ->
          case build_source(slug, attrs) do
            {:ok, source} -> {Map.put(valid_acc, slug, source), invalid_acc}
            {:error, reason} -> {valid_acc, Map.put(invalid_acc, to_string(slug), reason)}
          end
        end)

      {:ok, %Settings{sources: valid, invalid: invalid, feed_token_hash: token_hash(doc)}}
    end
  end

  defp require_v1(doc) do
    if Map.get(doc, "version") == 1 do
      :ok
    else
      {:error, {:invalid, "config/calendar.yaml is not a version: 1 document"}}
    end
  end

  defp require_sources_map(doc) do
    case Map.get(doc, "sources") do
      sources when is_map(sources) ->
        {:ok, sources}

      _other ->
        {:error, {:invalid, "config/calendar.yaml must define a sources: mapping"}}
    end
  end

  # `valea` is reserved for the local calendar; a config file carrying it
  # is WHOLE-FILE invalid (spec §Storage layout), never half-honored.
  defp reject_reserved_key(sources_doc) do
    if Map.has_key?(sources_doc, @reserved_slug) do
      {:error, {:invalid, "source key \"valea\" is reserved for the local Valea calendar"}}
    else
      :ok
    end
  end

  # Engine-managed and lenient by design: a malformed feed block reads as
  # "no token configured" (the served feed simply stays disabled) rather
  # than invalidating user source config over an engine-owned value.
  defp token_hash(doc) do
    with %{} = feed <- Map.get(doc, "feed"),
         hash when is_binary(hash) and hash != "" <- Map.get(feed, "token_hash") do
      hash
    else
      _other -> nil
    end
  end

  defp build_source(slug, attrs) when is_map(attrs) do
    if valid_slug?(slug) do
      with {:ok, name} <- fetch_name(attrs),
           {:ok, past_days, future_days} <- fetch_window(attrs),
           {:ok, interval_minutes} <- fetch_interval(attrs) do
        {:ok,
         %{
           name: name,
           past_days: past_days,
           future_days: future_days,
           interval_minutes: interval_minutes
         }}
      end
    else
      {:error, "invalid slug #{inspect(slug)}"}
    end
  end

  defp build_source(slug, _attrs), do: {:error, "source #{inspect(slug)} must be a mapping"}

  defp fetch_name(attrs) do
    case Map.get(attrs, "name") do
      name when is_binary(name) and name != "" -> {:ok, name}
      _other -> {:error, "name must be a non-empty string"}
    end
  end

  defp fetch_window(attrs) do
    case Map.get(attrs, "window") do
      nil ->
        {:ok, @default_past_days, @default_future_days}

      window when is_map(window) ->
        with {:ok, past_days} <- fetch_days(window, "past_days", @default_past_days),
             {:ok, future_days} <- fetch_days(window, "future_days", @default_future_days) do
          {:ok, past_days, future_days}
        end

      _other ->
        {:error, "window must be a mapping"}
    end
  end

  defp fetch_days(window, key, default) do
    case Map.get(window, key) do
      nil -> {:ok, default}
      days when is_integer(days) and days > 0 -> {:ok, days}
      _other -> {:error, "window.#{key} must be a positive integer"}
    end
  end

  # Floor 5: a positive value below the floor is clamped up (the floor is
  # a rate limit, not a validity rule); zero/negative/non-integer values
  # are malformed — a floor on a nonsensical value would hide an error.
  defp fetch_interval(attrs) do
    case Map.get(attrs, "interval_minutes") do
      nil ->
        {:ok, @default_interval_minutes}

      minutes when is_integer(minutes) and minutes > 0 ->
        {:ok, max(minutes, @interval_floor_minutes)}

      _other ->
        {:error, "interval_minutes must be a positive integer"}
    end
  end

  # -- rendering --------------------------------------------------------------

  # `name` reaches here from the source-setup RPC, i.e. arbitrary user
  # input — `Valea.Yaml.escape/1` is the shared injection-hardened scalar
  # renderer. Slugs are grammar-validated before they can land in
  # `sources:` and are safe to interpolate unquoted as mapping keys; the
  # token hash is engine-generated hex but escaped anyway.
  defp render(%Settings{} = state) do
    "version: 1\n" <> render_sources(state.sources) <> render_feed(state.feed_token_hash)
  end

  defp render_sources(sources) when map_size(sources) == 0, do: "sources: {}\n"

  defp render_sources(sources) do
    "sources:\n" <>
      Enum.map_join(Enum.sort_by(sources, fn {slug, _source} -> slug end), fn {slug, source} ->
        """
          #{slug}:
            name: #{Valea.Yaml.escape(source.name)}
            window:
              past_days: #{source.past_days}
              future_days: #{source.future_days}
            interval_minutes: #{source.interval_minutes}
        """
      end)
  end

  defp render_feed(nil), do: ""
  defp render_feed(hash), do: "feed:\n  token_hash: #{Valea.Yaml.escape(hash)}\n"
end
