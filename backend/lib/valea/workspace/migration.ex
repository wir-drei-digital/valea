defmodule Valea.Workspace.Migration do
  @moduledoc """
  Idempotent, versioned workspace upgrades, run by the Manager on every
  open/create before the workspace runtime starts. Never deletes or
  overwrites user files; converted sources are left in place.
  """

  alias Valea.Markdown.ProseMirror

  @current_version 2

  @spec migrate(String.t()) :: {:ok, integer()} | {:error, String.t()}
  def migrate(root) do
    with {:ok, _} <- ensure_v2(root, read_version(root)) do
      # Managed settings are regenerated on every open (and per session start).
      Valea.Agents.ClaudeSettings.write!(root)
      {:ok, @current_version}
    end
  rescue
    e -> {:error, "migration failed: #{Exception.message(e)}"}
  end

  defp read_version(root) do
    path = Path.join(root, "config/workspace.yaml")

    with true <- File.exists?(path),
         {:ok, %{"version" => v}} when is_integer(v) <- YamlElixir.read_from_file(path) do
      v
    else
      _ -> 1
    end
  end

  defp ensure_v2(_root, v) when v >= 2, do: {:ok, v}

  defp ensure_v2(root, _v) do
    copy_missing!(root, "AGENTS.md")
    copy_missing!(root, "CLAUDE.md")
    File.mkdir_p!(Path.join(root, "queue/staging"))
    File.mkdir_p!(Path.join(root, "queue/processing"))
    File.mkdir_p!(Path.join(root, "icm/Workflows"))
    convert_workflows!(root)
    ensure_gitignore_claude!(root)
    File.mkdir_p!(Path.join(root, "config"))
    File.write!(Path.join(root, "config/workspace.yaml"), "version: 2\n")
    {:ok, 2}
  end

  defp copy_missing!(root, rel) do
    target = Path.join(root, rel)

    unless File.exists?(target) do
      File.cp!(Path.join(template_dir(), rel), target)
    end
  end

  defp template_dir, do: Application.app_dir(:valea, "priv/workspace_template")

  defp convert_workflows!(root) do
    root
    |> Path.join("workflows/*.yaml")
    |> Path.wildcard()
    |> Enum.each(fn yaml_path ->
      case YamlElixir.read_from_file(yaml_path) do
        {:ok, wf} when is_map(wf) ->
          name = wf["name"] || Path.basename(yaml_path, ".yaml")
          target = Path.join(root, "icm/Workflows/#{name}.md")
          unless File.exists?(target), do: File.write!(target, workflow_page(wf, name))

        _ ->
          :ok
      end
    end)
  end

  # Builds a canonical icm/Workflows page: `frontmatter_block <> body` where
  # `frontmatter_block` is exactly `---\n...\n---\n` (no blank line after,
  # matching `Valea.ICM.split_frontmatter/1`'s shape) and `body` is run
  # through the ProseMirror round-trip (from_markdown |> to_markdown) so it
  # is byte-identical to what the editor would produce for the same content
  # — one line per block, a blank line between blocks, no manual line-wrap,
  # no trailing newline. This keeps the determinism contract: opening and
  # saving an untouched generated page must write nothing.
  defp workflow_page(wf, name) do
    frontmatter =
      %{
        "enabled" => wf["enabled"] || false,
        "trigger" => wf["trigger"] || %{},
        "sources" => wf["sources"] || [],
        "risk_level" => wf["risk_level"] || "medium",
        "approval" => wf["approval"] || %{"required" => true},
        "audit" => wf["audit"] || %{}
      }

    frontmatter_block =
      "---\n" <> (frontmatter |> yaml_encode() |> String.trim_trailing()) <> "\n---\n"

    steps =
      (wf["steps"] || [])
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {step, i} ->
        "#{i}. #{String.trim(step["instruction"] || step["id"] || "")}"
      end)

    raw_body = """
    # #{name}

    #{String.trim(wf["description"] || "")}

    ## Inputs

    | Input | Where |
    | --- | --- |
    | Run input | named by the run |
    | Reference pages | listed under `sources` above |

    ## Process

    #{steps}

    ## Outputs

    One `proposal/v1` file at the exact path the run names. Do not send anything.
    """

    {:ok, pm} = ProseMirror.from_markdown(raw_body)
    {:ok, body} = ProseMirror.to_markdown(pm)

    frontmatter_block <> body
  end

  # Minimal YAML emitter for the known frontmatter shape (maps, lists,
  # scalars). yaml_elixir has no encoder; keep this private and dumb.
  # `sources` is the only key that nests a list at the top level, so it gets
  # block style; every other list (e.g. `approval.actions`) only ever
  # appears nested inside a flow map, so `yaml_value/1` emits lists in flow
  # style (`[a, b]`) to stay valid YAML there.
  defp yaml_encode(map) when is_map(map) do
    Enum.map_join(map, "\n", fn
      {"sources", v} when is_list(v) ->
        "sources:\n" <> Enum.map_join(v, "\n", fn item -> "  - #{yaml_value(item)}" end)

      {k, v} ->
        "#{k}: #{yaml_value(v)}"
    end)
  end

  defp yaml_value(v) when is_map(v) do
    inner = Enum.map_join(v, ", ", fn {k, val} -> "#{k}: #{yaml_value(val)}" end)
    "{ #{inner} }"
  end

  defp yaml_value(v) when is_list(v), do: "[" <> Enum.map_join(v, ", ", &yaml_value/1) <> "]"

  defp yaml_value(v) when is_binary(v) do
    if String.contains?(v, [":", "#", "*"]), do: ~s("#{v}"), else: v
  end

  defp yaml_value(v), do: to_string(v)

  defp ensure_gitignore_claude!(root) do
    path = Path.join(root, ".gitignore")
    current = if File.exists?(path), do: File.read!(path), else: ""

    unless String.contains?(current, ".claude/") do
      File.write!(path, current <> ".claude/\n")
    end
  end
end
