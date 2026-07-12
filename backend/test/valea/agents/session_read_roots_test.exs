# Session-start integration coverage for A-T10: read_roots is computed ONCE,
# centrally, in `SessionServer.init/1` — both construction sites
# (`Valea.Api.Agents.create_session` for chat, `Valea.Workflows.Runner.run`
# for workflows) route through `Valea.Agents.start_session/1` and land here,
# so this suite exercises the single real call path rather than re-deriving
# the expected roots by hand at each site.
defmodule Valea.Agents.SessionReadRootsTest do
  use ExUnit.Case, async: false

  alias Valea.AgentCase

  # A fresh scaffold (T8) mints its own real, ENABLED mount at
  # `mounts/<slug-of-name>` from the template — naming the workspace
  # "Primary" lands it at exactly `mounts/primary`.
  setup do
    ws = AgentCase.open_workspace!("Primary")
    %{workspace: ws.path}
  end

  defp policy_ctx_for(id) do
    pid = GenServer.whereis({:via, Registry, {Valea.Agents.SessionRegistry, id}})
    :sys.get_state(pid).policy_ctx
  end

  # Declares an external (kind: "path") mount in the workspace's existing
  # config/workspace.yaml, preserving version/id and every existing mount
  # entry.
  defp declare_external!(ws_path, name, ref) do
    config_path = Path.join(ws_path, "config/workspace.yaml")
    {:ok, doc} = YamlElixir.read_from_file(config_path)

    mounts =
      (Map.get(doc, "mounts") || %{})
      |> Map.put(name, %{"kind" => "path", "ref" => ref})

    header = for key <- ["version", "id"], Map.has_key?(doc, key), do: "#{key}: #{doc[key]}"

    entries =
      Enum.flat_map(Enum.sort_by(mounts, &elem(&1, 0)), fn {n, entry} ->
        [
          "  #{n}:"
          | Enum.map(Enum.sort_by(entry, &elem(&1, 0)), fn {k, v} ->
              "    #{k}: #{render_scalar(v)}"
            end)
        ]
      end)

    File.write!(config_path, Enum.join(header ++ ["mounts:"] ++ entries, "\n") <> "\n")
  end

  defp render_scalar(v) when is_binary(v), do: inspect(v)
  defp render_scalar(v), do: to_string(v)

  defp external_icm!(name) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-ext-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    Valea.Mounts.Manifest.write!(dir, %{id: "ext-id", name: name, description: ""})
    dir
  end

  test "a started chat session's read_roots is [\"sources\", \"mounts/primary\"] — computed from Mounts.enabled",
       %{workspace: workspace} do
    {:ok, %{id: id}} = AgentCase.start_session(workspace, "happy")
    on_exit(fn -> AgentCase.kill_session(id) end)

    assert %{read_roots: read_roots} = policy_ctx_for(id)
    assert Enum.sort(read_roots) == Enum.sort(["sources", "mounts/primary"])
  end

  test "disabling the mount BEFORE a session starts excludes it from that session's read_roots — its reads then ask-gate, not deny",
       %{workspace: workspace} do
    :ok = Valea.Mounts.set_enabled("primary", false)

    {:ok, %{id: id}} = AgentCase.start_session(workspace, "happy")
    on_exit(fn -> AgentCase.kill_session(id) end)

    assert %{read_roots: ["sources"]} = policy_ctx_for(id)
  end

  test "external mounts stay OUT of read_roots but join extra_roots (A2-T3) — the workspace-relative and absolute read surfaces are tracked separately",
       %{workspace: workspace} do
    ext = external_icm!("Ext")
    declare_external!(workspace, "ext", ext)

    # Sanity: the external mount IS effective — it's excluded from
    # read_roots deliberately (rel_root: nil has no workspace-relative
    # form; PermissionPolicy would crash on it), not because it failed to
    # resolve. Its real root is what extra_roots carries instead.
    enabled = Valea.Mounts.enabled(workspace)
    assert "ext" in Enum.map(enabled, & &1.name)
    assert %{root: ext_root} = Enum.find(enabled, &(&1.name == "ext"))

    {:ok, %{id: id}} = AgentCase.start_session(workspace, "happy")
    on_exit(fn -> AgentCase.kill_session(id) end)

    assert %{read_roots: read_roots, extra_roots: extra_roots} = policy_ctx_for(id)
    refute nil in read_roots
    assert Enum.sort(read_roots) == ["mounts/primary", "sources"]
    assert extra_roots == [ext_root]
  end

  test "disabling the external mount BEFORE a session starts excludes its root from that session's extra_roots — its reads then ask-gate, not deny",
       %{workspace: workspace} do
    ext = external_icm!("Ext")
    declare_external!(workspace, "ext", ext)
    :ok = Valea.Mounts.set_enabled("ext", false)

    {:ok, %{id: id}} = AgentCase.start_session(workspace, "happy")
    on_exit(fn -> AgentCase.kill_session(id) end)

    assert %{extra_roots: []} = policy_ctx_for(id)
  end

  test "an explicit policy_ctx extra_roots is NOT clobbered by the computed default",
       %{workspace: workspace} do
    {:ok, %{id: id}} =
      AgentCase.start_session(workspace, "happy", %{
        policy_ctx: %{
          workspace: workspace,
          session_kind: "chat",
          write_paths: [],
          extra_roots: ["/some/explicit/root"]
        }
      })

    on_exit(fn -> AgentCase.kill_session(id) end)

    assert %{extra_roots: ["/some/explicit/root"]} = policy_ctx_for(id)
  end

  test "an explicit policy_ctx read_roots is NOT clobbered by the computed default",
       %{workspace: workspace} do
    {:ok, %{id: id}} =
      AgentCase.start_session(workspace, "happy", %{
        policy_ctx: %{
          workspace: workspace,
          session_kind: "chat",
          write_paths: [],
          read_roots: ["queue"]
        }
      })

    on_exit(fn -> AgentCase.kill_session(id) end)

    assert %{read_roots: ["queue"]} = policy_ctx_for(id)
  end

  test "a workflow session (via Valea.Workflows.Runner) also gets read_roots from Mounts.enabled",
       %{workspace: _workspace} do
    Valea.App.Config.set_harness_command(AgentCase.fake_cmd("workflow_happy"))

    assert {:ok, %{session_id: id}} =
             Valea.Workflows.Runner.run(
               "mounts/primary/Workflows/New Inquiry Triage.md",
               "sources/mail/messages/2026-07-09-priya-nair-seed0001.md"
             )

    on_exit(fn -> AgentCase.kill_session(id) end)

    assert %{read_roots: read_roots} = policy_ctx_for(id)
    assert Enum.sort(read_roots) == Enum.sort(["sources", "mounts/primary"])
  end
end
