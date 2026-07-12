defmodule Valea.Mounts.Manifest do
  @moduledoc """
  `<icm_root>/icm.yaml` ⇄ `%Manifest{}` — the per-mount manifest that makes
  an ICM at `mounts/<name>/` a portable module (Plan A, "all mounts").

  `id` is provenance, not identity: it is minted once (scaffold/migration)
  and travels with the mount if it's copied or renamed, but nothing in this
  module — or elsewhere — treats it as a uniqueness key. Two mounts sharing
  an `id` is not an error this codec detects or cares about.

  `format` is a forward-compatible version tag for the manifest shape
  itself; today only `format: 1` exists, and it defaults to `1` when the
  key is absent (e.g. a hand-written manifest that predates the field).
  Unknown keys are ignored, matching `Valea.Mail.Settings`'s stance: a
  stray hand-edited key must never brick loading a mount.
  """

  alias __MODULE__
  alias Valea.Yaml

  defstruct format: 1, id: nil, name: nil, description: nil

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
  mapping or its `name` is absent, blank, or not a string. `format`
  defaults to `1` and `description` to `""` when absent; any other key is
  ignored.
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
  `format: 1`. String values are rendered through the injection-hardened
  `Valea.Yaml.escape/1`, so arbitrary user input (a mount name typed during
  create) can never inject a sibling key or break the YAML structure.
  """
  @spec render(%{id: String.t(), name: String.t(), description: String.t()}) :: String.t()
  def render(%{id: id, name: name, description: description})
      when is_binary(id) and is_binary(name) and is_binary(description) do
    """
    format: 1
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
    case fetch_name(doc) do
      {:ok, name} ->
        {:ok,
         %Manifest{
           format: Map.get(doc, "format", 1),
           id: Map.get(doc, "id"),
           name: name,
           description: fetch_description(doc)
         }}

      {:error, _} = error ->
        error
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
