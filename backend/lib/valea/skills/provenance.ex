defmodule Valea.Skills.Provenance do
  @moduledoc """
  The `.provenance.yaml` sidecar inside an installed skill folder (ICM
  skills design spec, §On-disk contract): skill id, installed version,
  source URL, and a content-hash manifest of every installed file. The
  sidecar travels with the portable ICM, so any Valea instance recognizes
  the install and — by re-hashing — whether the user edited it.

  Written as pretty-printed JSON, a strict YAML subset (the
  `Valea.Mail.OpsFile` sidecar precedent): agent-readable `.yaml` without
  a hand-rolled YAML encoder. `hash_tree/1` refuses symlinks — a link
  inside a skill tree is never hashed or copied.
  """

  @sidecar ".provenance.yaml"

  @spec hash_tree(String.t()) ::
          {:ok, %{String.t() => String.t()}} | {:error, {:symlink, String.t()}}
  def hash_tree(dir) do
    walk(dir, ".", %{})
  end

  defp walk(base, rel, acc) do
    abs = Path.join(base, rel)

    Enum.reduce_while(File.ls!(abs), {:ok, acc}, fn name, {:ok, acc} ->
      rel_child = if rel == ".", do: name, else: Path.join(rel, name)
      abs_child = Path.join(base, rel_child)
      stat = File.lstat!(abs_child)

      cond do
        rel_child == @sidecar ->
          {:cont, {:ok, acc}}

        stat.type == :symlink ->
          {:halt, {:error, {:symlink, rel_child}}}

        stat.type == :directory ->
          case walk(base, rel_child, acc) do
            {:ok, acc} -> {:cont, {:ok, acc}}
            err -> {:halt, err}
          end

        stat.type == :regular ->
          hash =
            :crypto.hash(:sha256, File.read!(abs_child)) |> Base.encode16(case: :lower)

          {:cont, {:ok, Map.put(acc, rel_child, hash)}}

        true ->
          {:cont, {:ok, acc}}
      end
    end)
  end

  @spec write!(String.t(), %{skill: String.t(), version: String.t(), source_url: String.t()}) ::
          :ok
  def write!(dir, %{skill: skill, version: version, source_url: source_url}) do
    {:ok, files} = hash_tree(dir)

    doc = %{
      "format" => 1,
      "skill" => skill,
      "version" => version,
      "source_url" => source_url,
      "installed_by" => "valea",
      "files" => files
    }

    path = Path.join(dir, @sidecar)
    tmp = path <> ".tmp"
    File.write!(tmp, Jason.encode!(doc, pretty: true))
    File.rename!(tmp, path)
  end

  @spec read(String.t()) :: {:ok, map()} | :error
  def read(dir) do
    with {:ok, doc} <- YamlElixir.read_from_file(Path.join(dir, @sidecar)),
         %{"skill" => skill, "version" => version, "files" => files}
         when is_binary(skill) and is_binary(version) and is_map(files) <- doc do
      {:ok,
       %{
         skill: skill,
         version: version,
         source_url: doc["source_url"],
         files: files
       }}
    else
      _missing_or_invalid -> :error
    end
  end
end
