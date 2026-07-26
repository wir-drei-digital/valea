defmodule Valea.Skills.Catalog do
  @moduledoc """
  Parses + validates `priv/skills/catalog.yaml` — the repo-vendored skill
  catalog (ICM skills design spec, §Catalog). Read-only and side-effect
  free. Unknown keys are ignored (the `icm.yaml` forward-compat posture);
  an entry missing a required field is dropped; an entry whose snapshot
  directory is missing loads with `defect: :snapshot_missing` (doctor
  material, never a crash). No runtime fetching exists anywhere.
  """

  @required ~w(name description source_url license pinned)

  def dir do
    Application.get_env(:valea, :skills_catalog_dir) ||
      Path.join(:code.priv_dir(:valea), "skills")
  end

  @spec load() :: {:ok, %{String.t() => map()}} | {:error, term()}
  def load do
    path = Path.join(dir(), "catalog.yaml")

    with {:ok, %{"skills" => skills}} when is_map(skills) <-
           YamlElixir.read_from_file(path) do
      {:ok,
       skills
       |> Enum.flat_map(fn {id, raw} -> entry(id, raw) end)
       |> Map.new()}
    else
      {:ok, _shape} -> {:error, :invalid_catalog}
      {:error, reason} -> {:error, reason}
    end
  end

  defp entry(id, raw) when is_map(raw) do
    if Enum.all?(@required, &is_binary(raw[&1])) do
      snapshot_dir = Path.join(dir(), id)

      [
        {id,
         %{
           id: id,
           name: raw["name"],
           description: raw["description"],
           source_url: raw["source_url"],
           license: raw["license"],
           pinned: raw["pinned"],
           snapshot_dir: snapshot_dir,
           defect: if(File.dir?(snapshot_dir), do: nil, else: :snapshot_missing)
         }}
      ]
    else
      []
    end
  end

  defp entry(_id, _raw), do: []
end
