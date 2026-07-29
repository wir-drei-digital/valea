defmodule Valea.Schedules.Entry do
  @moduledoc """
  One `schedules.json` entry, read through the spec's two-regime leniency
  contract (tasks+schedules spec §Leniency contract — lenient display, strict
  execution).

  `build/1` never fails. It returns a struct for **every** map in the array,
  carrying a `disposition` that says what the scheduler may do with it:

    * `:executable` — validated, not paused. This is the only disposition that
      ever fires.
    * `:paused` — validated, and the file says paused. Slots elapse silently.
    * `:not_executable` — with a `reason` sentence for the row ("missing id",
      "invalid cron: …", "unknown timezone …", "`paused` is not a boolean",
      "context_doc escapes the ICM", "duplicate id" — the last one stamped by
      `Valea.Schedules.File` once it can see the whole array).

  ## Two regimes, on purpose

  **Display fields are lenient**: a missing or wrong-typed `title` degrades to
  `"untitled"` and a wrong-typed `created_by` to `nil`, because a bad label is
  no reason to hide a row the user needs to repair.

  **Execution-control fields are strict and fail closed, per entry**: `id`,
  `cron`, `timezone` (when present), `payload` (shape *and* kind), `paused` and
  `catchup` (JSON booleans when present). Anything invalid, missing or
  wrong-typed makes the entry non-executable rather than "close enough" — and
  the case that rule exists for is `"paused": "true"`, a *string*: a malformed
  pause attempt must never leave a schedule running. Absent is the one
  forgiving case, and only where the spec gives a default (`paused`/`catchup`
  default to `false`, an absent `timezone` to the host zone); a `null` is
  present and wrong-typed, not absent.

  `paused` and `catchup` are filled in for display straight off the raw value
  (`=== true`), independently of the validation chain, so an entry refused for
  *another* reason still shows the pause the file asked for. Only a real JSON
  `true` counts: `"paused": "true"` reads as `false` **and** refuses the entry,
  with the reason naming the field — the row is stopped and says why, which is
  the outcome that matters.

  ## Fingerprint

  `fingerprint/1` hashes **exactly** `catchup`, `cron`, `payload` and
  `timezone` — the fields whose change means "this is a different schedule
  now", which is what resets the scheduler's anchors (spec §Firing rule step
  2). Renaming a schedule, pausing it, or adding a field Valea has never heard
  of leaves the fingerprint alone, so none of those back-fire a slot or lose an
  anchor. It is computed for every disposition: it identifies content, it does
  not grant permission.

  ## Payload

  A validated payload is normalized to atom keys, so consumers pattern-match a
  shape that has already been checked rather than re-reading strings:

      %{kind: :prompt, prompt: binary(), context_doc: binary() | nil}
      %{kind: :command, command: binary(), args: [binary()]}

  `context_doc` is checked **lexically** here — relative, no `..` segment —
  which is the earliest place a containment escape can be refused. The
  `resolve_real/2` check that catches a symlink escape belongs to the launch
  (spec §Leniency contract), and so does the "the file isn't there" failure.
  """

  alias Valea.Ledger.Canonical
  alias Valea.Paths
  alias Valea.Schedules.Cron

  @fingerprint_fields ~w(catchup cron payload timezone)

  defstruct [
    :id,
    :title,
    :cron,
    :cron_raw,
    :timezone,
    :payload,
    :paused,
    :catchup,
    :created_by,
    :disposition,
    :reason,
    :fingerprint,
    :raw
  ]

  @type disposition :: :executable | :paused | :not_executable

  @type payload ::
          %{kind: :prompt, prompt: String.t(), context_doc: String.t() | nil}
          | %{kind: :command, command: String.t(), args: [String.t()]}

  @type t :: %__MODULE__{
          id: String.t() | nil,
          title: String.t(),
          cron: Cron.t() | nil,
          cron_raw: String.t() | nil,
          timezone: String.t() | nil,
          payload: payload() | nil,
          paused: boolean(),
          catchup: boolean(),
          created_by: String.t() | nil,
          disposition: disposition(),
          reason: String.t() | nil,
          fingerprint: String.t(),
          raw: map()
        }

  @doc """
  Reads one raw entry into a `t:t/0` with a disposition. See the moduledoc for
  the leniency split; the validation order is `id`, `cron`, `timezone`,
  `payload`, then the boolean flags, so the reason a row shows is the first
  thing wrong with it.
  """
  @spec build(map()) :: t()
  def build(raw) when is_map(raw) do
    entry = %__MODULE__{
      id: id(raw["id"]),
      title: title(raw["title"]),
      cron_raw: string(raw["cron"]),
      created_by: string(raw["created_by"]),
      paused: raw["paused"] == true,
      catchup: raw["catchup"] == true,
      fingerprint: fingerprint(raw),
      raw: raw
    }

    case validate(raw) do
      {:ok, cron, zone, payload} ->
        %{
          entry
          | cron: cron,
            timezone: zone,
            payload: payload,
            disposition: if(entry.paused, do: :paused, else: :executable)
        }

      {:error, reason} ->
        %{entry | disposition: :not_executable, reason: reason}
    end
  end

  @doc """
  The execution fingerprint: lowercase hex SHA-256 over the canonical
  (key-sorted) JSON of `catchup`, `cron`, `payload` and `timezone`.
  """
  @spec fingerprint(map()) :: String.t()
  def fingerprint(raw) when is_map(raw) do
    raw |> Map.take(@fingerprint_fields) |> Canonical.hash()
  end

  # -- strict execution fields ------------------------------------------------

  defp validate(raw) do
    with :ok <- validate_id(raw["id"]),
         {:ok, cron} <- validate_cron(raw["cron"]),
         {:ok, zone} <- validate_zone(raw),
         {:ok, payload} <- validate_payload(raw["payload"]),
         :ok <- validate_flag(raw, "paused"),
         :ok <- validate_flag(raw, "catchup") do
      {:ok, cron, zone, payload}
    end
  end

  # An entry without an id is not executable AND not addressable: there is no
  # way to name it in an RPC, so there is no way to pause or repair it either.
  defp validate_id(id) when is_binary(id) do
    if String.trim(id) == "", do: {:error, "missing id"}, else: :ok
  end

  defp validate_id(_missing_or_wrong_typed), do: {:error, "missing id"}

  defp validate_cron(cron) do
    case Cron.parse(cron) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, detail} -> {:error, "invalid cron: " <> detail}
    end
  end

  # An absent `timezone` resolves to the host zone here rather than at launch,
  # so the row can say where it fires. The file is re-read every tick, which is
  # exactly the spec's "host-zone-default schedules follow the new zone from the
  # next tick" — and the fingerprint stays over the RAW fields, so the host
  # changing zone is not mistaken for the schedule being redefined.
  defp validate_zone(raw) do
    case Map.fetch(raw, "timezone") do
      :error -> {:ok, Valea.Calendar.Engine.host_zone()}
      {:ok, zone} when is_binary(zone) -> known_zone(zone)
      {:ok, _wrong_typed} -> {:error, "`timezone` is not a string"}
    end
  end

  defp known_zone(zone) do
    case DateTime.now(zone) do
      {:ok, _now} -> {:ok, zone}
      {:error, _unknown} -> {:error, ~s(unknown timezone "#{zone}")}
    end
  end

  defp validate_payload(%{"kind" => "prompt"} = payload) do
    with {:ok, prompt} <- required_string(payload, "prompt"),
         {:ok, context_doc} <- context_doc(payload) do
      {:ok, %{kind: :prompt, prompt: prompt, context_doc: context_doc}}
    end
  end

  defp validate_payload(%{"kind" => "command"} = payload) do
    with {:ok, command} <- required_string(payload, "command"),
         {:ok, args} <- args(payload) do
      {:ok, %{kind: :command, command: command, args: args}}
    end
  end

  defp validate_payload(%{} = payload) do
    {:error, "invalid payload: unknown kind #{inspect(payload["kind"])}"}
  end

  defp validate_payload(_absent_or_wrong_typed), do: {:error, "invalid payload: not an object"}

  defp required_string(payload, field) do
    case Map.fetch(payload, field) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _missing_or_wrong_typed -> {:error, "invalid payload: `#{field}` is not a non-empty string"}
    end
  end

  # Exec-style spawn, never a shell string: `args` is a list of plain strings or
  # the payload is refused (spec §Payload kinds).
  defp args(payload) do
    case Map.fetch(payload, "args") do
      :error -> {:ok, []}
      {:ok, args} when is_list(args) -> checked_args(args)
      {:ok, _wrong_typed} -> {:error, bad_args()}
    end
  end

  defp checked_args(args) do
    if Enum.all?(args, &is_binary/1), do: {:ok, args}, else: {:error, bad_args()}
  end

  defp bad_args, do: "invalid payload: `args` is not a list of strings"

  defp context_doc(payload) do
    case Map.fetch(payload, "context_doc") do
      :error -> {:ok, nil}
      {:ok, doc} when is_binary(doc) -> contained(doc)
      {:ok, _wrong_typed} -> {:error, "`context_doc` is not a string"}
    end
  end

  # Lexical containment only: a relative path with no `..` segment. `..` is
  # refused even where it would resolve back inside (`a/../b`) — the point is a
  # rule the user can check by eye, not a walk they have to simulate.
  defp contained(doc) do
    cond do
      String.trim(doc) == "" -> {:error, "`context_doc` is blank"}
      Paths.classify(doc) != :relative -> {:error, escapes()}
      ".." in String.split(Paths.normalize(doc), "/") -> {:error, escapes()}
      true -> {:ok, doc}
    end
  end

  defp escapes, do: "context_doc escapes the ICM"

  defp validate_flag(raw, field) do
    case Map.fetch(raw, field) do
      :error -> :ok
      {:ok, value} when is_boolean(value) -> :ok
      {:ok, _wrong_typed} -> {:error, "`#{field}` is not a boolean"}
    end
  end

  # -- lenient display fields -------------------------------------------------

  # Trimmed on accept, so `"s-1 "` and `"s-1"` are the same id and cannot slip
  # past the duplicate gate as two distinct rows. The struct's `id` is therefore
  # the addressing key; a writer patching the file has to match it trimmed too.
  defp id(id) when is_binary(id) do
    case String.trim(id) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp id(_missing_or_wrong_typed), do: nil

  defp title(title) when is_binary(title) do
    if String.trim(title) == "", do: "untitled", else: title
  end

  defp title(_missing_or_wrong_typed), do: "untitled"

  defp string(value) when is_binary(value), do: value
  defp string(_missing_or_wrong_typed), do: nil
end
