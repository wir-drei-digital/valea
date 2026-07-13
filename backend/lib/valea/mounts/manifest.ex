defmodule Valea.Mounts.Manifest do
  @moduledoc """
  `<icm_root>/icm.yaml` ⇄ `%Manifest{}` — the per-mount manifest that makes
  an ICM at `mounts/<name>/` a portable module (Plan A, "all mounts").

  Format 2: `id` is a stable, validated identity, not mere provenance —
  `load/1` requires it to be present and a well-formed UUID (rejecting a
  missing, blank, or non-UUID `id` as `{:invalid, _}`), rather than the
  format-1 codec's tolerance of any value. Nothing in THIS module enforces
  uniqueness across mounts (that's `Valea.Mounts.list`'s concern), only
  that the id, whatever it is, is a real UUID.

  `format` is a forward-compatible version tag for the manifest shape
  itself; it defaults to `2` when the key is absent (e.g. a hand-written
  manifest that predates the field), but a present value — including a
  legacy `format: 1` — is preserved as-is rather than rewritten on load.
  Unknown keys are ignored, matching `Valea.Mail.Settings`'s stance: a
  stray hand-edited key must never brick loading a mount.
  """

  alias __MODULE__
  alias Valea.Yaml

  defstruct format: 2, id: nil, name: nil, description: nil

  @type t :: %__MODULE__{
          format: pos_integer(),
          id: String.t() | nil,
          name: String.t() | nil,
          description: String.t() | nil
        }

  @doc """
  Loads and validates `<icm_root>/icm.yaml`.

  Returns `{:error, :missing}` when the file doesn't exist, and
  `{:error, {:invalid, reason}}` when it exists but isn't a valid YAML
  mapping, its `id` is absent, blank, or not a UUID, or its `name` is
  absent, blank, or not a string. `format` defaults to `2` (a present
  value is preserved) and `description` to `""` when absent; any other key
  is ignored.
  """
  @spec load(String.t()) :: {:ok, t()} | {:error, :missing | {:invalid, String.t()}}
  def load(icm_root) when is_binary(icm_root) do
    path = Path.join(icm_root, "icm.yaml")

    with true <- File.exists?(path),
         {:ok, doc} when is_map(doc) <- YamlElixir.read_from_file(path) do
      build(doc)
    else
      false ->
        {:error, :missing}

      {:ok, _not_a_map} ->
        {:error, {:invalid, "icm.yaml must be a YAML mapping"}}

      {:error, %YamlElixir.FileNotFoundError{}} ->
        {:error, :missing}

      {:error, %{message: message}} ->
        {:error, {:invalid, message}}
    end
  end

  @doc """
  Renders a fresh `icm.yaml` document from `id`/`name`/`description` — used
  by scaffold/create/migration to mint a mount's manifest. Always emits
  `format: 2`. String values are rendered through the injection-hardened
  `Valea.Yaml.escape/1`, so arbitrary user input (a mount name typed during
  create) can never inject a sibling key or break the YAML structure.
  """
  @spec render(%{id: String.t(), name: String.t(), description: String.t()}) :: String.t()
  def render(%{id: id, name: name, description: description})
      when is_binary(id) and is_binary(name) and is_binary(description) do
    """
    format: 2
    id: #{Yaml.escape(id)}
    name: #{Yaml.escape(name)}
    description: #{Yaml.escape(description)}
    """
  end

  @doc """
  Renders and atomically writes `<icm_root>/icm.yaml` (write to a `.tmp`
  sibling then `File.rename!`, so a reader never observes a partial file).
  """
  @spec write!(String.t(), %{id: String.t(), name: String.t(), description: String.t()}) :: :ok
  def write!(icm_root, attrs) when is_binary(icm_root) do
    path = Path.join(icm_root, "icm.yaml")
    atomic_write!(path, render(attrs))
    :ok
  end

  defp atomic_write!(path, bytes) do
    tmp = path <> ".tmp"
    File.write!(tmp, bytes)
    File.rename!(tmp, path)
  end

  defp build(doc) do
    with {:ok, id} <- fetch_id(doc),
         {:ok, name} <- fetch_name(doc) do
      {:ok,
       %Manifest{
         format: Map.get(doc, "format", 2),
         id: id,
         name: name,
         description: fetch_description(doc)
       }}
    end
  end

  defp fetch_id(doc) do
    case doc |> Map.get("id") |> to_string() |> String.trim() do
      "" ->
        {:error, {:invalid, "id is required"}}

      id ->
        case Ecto.UUID.cast(id) do
          {:ok, id} -> {:ok, id}
          :error -> {:error, {:invalid, "id must be a UUID"}}
        end
    end
  end

  defp fetch_name(doc) do
    case Map.get(doc, "name") do
      name when is_binary(name) ->
        if blank?(name) do
          {:error, {:invalid, "name must not be blank"}}
        else
          {:ok, name}
        end

      _other ->
        {:error, {:invalid, "name is required and must be a string"}}
    end
  end

  defp fetch_description(doc) do
    case Map.get(doc, "description", "") do
      description when is_binary(description) -> description
      _other -> ""
    end
  end

  defp blank?(s), do: String.trim(s) == ""
end
