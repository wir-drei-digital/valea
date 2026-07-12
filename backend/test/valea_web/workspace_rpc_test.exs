defmodule ValeaWeb.WorkspaceRpcTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Plug.Conn

  @endpoint ValeaWeb.Endpoint

  alias Valea.Mounts.Manifest
  alias Valea.Workspace.Manager
  alias Valea.Workspace.Scaffold

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-app-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    System.put_env("VALEA_APP_DIR", dir)
    Manager.close()

    on_exit(fn ->
      Manager.close()
      File.rm_rf!(dir)
      System.delete_env("VALEA_APP_DIR")
    end)

    %{parent: Path.join(dir, "workspaces")}
  end

  defp rpc(action, input, fields \\ []) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-valea-token", "valea-dev-token")
    |> post("/rpc/run", %{"action" => action, "input" => input, "fields" => fields})
    |> json_response(200)
  end

  defp write_manifest!(dir, attrs) do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "icm.yaml"), Manifest.render(attrs))
  end

  defp tmp_dir(prefix) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "#{prefix}-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  # -- inspect_path -----------------------------------------------------

  describe "inspect_path" do
    test "classifies a scaffolded workspace dir as \"workspace\"", %{parent: parent} do
      target = tmp_dir("valea-ws")
      :ok = Scaffold.create(target, "Acme")

      assert %{"success" => true, "data" => %{"kind" => "workspace"}} =
               rpc("inspect_path", %{"path" => target})

      # sanity: the tmp helper's own parent dir isn't accidentally reused
      refute target == parent
    end

    test "classifies a dir with a parseable icm.yaml as \"icm\", surfacing its manifest name/description" do
      dir = tmp_dir("valea-icm")
      write_manifest!(dir, %{id: "id-1", name: "Client Notes", description: "Old client work"})

      assert %{
               "success" => true,
               "data" => %{
                 "kind" => "icm",
                 "name" => "Client Notes",
                 "description" => "Old client work"
               }
             } = rpc("inspect_path", %{"path" => dir})
    end

    test "classifies a plain dir with no icm.yaml as \"other\"" do
      dir = tmp_dir("valea-plain")
      File.mkdir_p!(dir)

      assert %{"success" => true, "data" => %{"kind" => "other"}} =
               rpc("inspect_path", %{"path" => dir})
    end
  end

  # -- adopt_workspace ----------------------------------------------------

  describe "adopt_workspace" do
    test "happy path: moves the folder in, mints a manifest, opens the new workspace", %{
      parent: parent
    } do
      source = tmp_dir("valea-source")
      File.mkdir_p!(source)
      File.write!(Path.join(source, "Notes.md"), "# hello")

      assert %{"success" => true, "data" => %{"open" => true, "name" => "Acme Coaching"}} =
               rpc("adopt_workspace", %{
                 "parentDir" => parent,
                 "name" => "Acme Coaching",
                 "icmSourcePath" => source
               })

      refute File.exists?(source)

      target = Path.join(parent, "Acme Coaching")
      slug = Scaffold.slugify(Path.basename(source))
      assert File.exists?(Path.join([target, "mounts", slug, "Notes.md"]))

      assert %{"success" => true, "data" => %{"open" => true, "name" => "Acme Coaching"}} =
               rpc("get_workspace", %{})
    end

    test "rejects a source that is a workspace itself", %{parent: parent} do
      source = tmp_dir("valea-source-ws")
      :ok = Scaffold.create(source, "Already A Workspace")

      assert %{"success" => false, "errors" => errors} =
               rpc("adopt_workspace", %{
                 "parentDir" => parent,
                 "name" => "X",
                 "icmSourcePath" => source
               })

      assert inspect(errors) =~ "source_is_workspace"
      assert File.dir?(source)
    end

    test "rejects a source nested inside an existing workspace", %{parent: parent} do
      existing_ws = tmp_dir("valea-existing-ws")
      :ok = Scaffold.create(existing_ws, "Existing")
      nested_mount = Path.join(existing_ws, "mounts/existing")

      assert %{"success" => false, "errors" => errors} =
               rpc("adopt_workspace", %{
                 "parentDir" => parent,
                 "name" => "X",
                 "icmSourcePath" => nested_mount
               })

      assert inspect(errors) =~ "source_in_workspace"
    end

    test "rejects a source equal to the currently-open workspace's dir", %{parent: parent} do
      rpc("create_workspace", %{"parentDir" => parent, "name" => "Open Me"})
      open_path = Path.join(parent, "Open Me")

      assert %{"success" => false, "errors" => errors} =
               rpc("adopt_workspace", %{
                 "parentDir" => parent,
                 "name" => "X",
                 "icmSourcePath" => open_path
               })

      assert inspect(errors) =~ "source_is_open_workspace"
    end

    test "rejects a cycle where parent_dir is inside the source", %{parent: parent} do
      source = tmp_dir("valea-cycle-source")
      nested_parent = Path.join(source, "nested")
      File.mkdir_p!(nested_parent)

      assert %{"success" => false, "errors" => errors} =
               rpc("adopt_workspace", %{
                 "parentDir" => nested_parent,
                 "name" => "X",
                 "icmSourcePath" => source
               })

      assert inspect(errors) =~ "cycle"
      refute parent == nested_parent
    end

    test "a missing source surfaces source_not_found", %{parent: parent} do
      missing =
        Path.join(System.tmp_dir!(), "does-not-exist-#{System.unique_integer([:positive])}")

      assert %{"success" => false, "errors" => errors} =
               rpc("adopt_workspace", %{
                 "parentDir" => parent,
                 "name" => "X",
                 "icmSourcePath" => missing
               })

      assert inspect(errors) =~ "source_not_found"
    end

    test "target == source surfaces target_is_source" do
      source = tmp_dir("valea-target-eq-source")
      File.mkdir_p!(source)
      File.write!(Path.join(source, "Notes.md"), "# hello")

      assert %{"success" => false, "errors" => errors} =
               rpc("adopt_workspace", %{
                 "parentDir" => Path.dirname(source),
                 "name" => Path.basename(source),
                 "icmSourcePath" => source
               })

      assert inspect(errors) =~ "target_is_source"
      assert File.exists?(Path.join(source, "Notes.md"))
    end

    test "a real rename failure surfaces the move_failed wire string (source intact)", %{
      parent: parent
    } do
      source_parent = tmp_dir("valea-source-parent")
      source = Path.join(source_parent, "knowledge")
      File.mkdir_p!(source)
      File.write!(Path.join(source, "Notes.md"), "# hello")

      # Same deterministic non-EXDEV rename failure as the Adopt unit suite:
      # a read-only source parent makes File.rename/2 fail with :eacces.
      File.chmod!(source_parent, 0o555)
      on_exit(fn -> File.chmod!(source_parent, 0o755) end)

      assert %{"success" => false, "errors" => errors} =
               rpc("adopt_workspace", %{
                 "parentDir" => parent,
                 "name" => "CleansUp",
                 "icmSourcePath" => source
               })

      # The exact code, not a substring: without the explicit
      # `error_message({:move_failed, _})` clause the fallthrough would emit
      # `inspect({:move_failed, :eacces})` — a wire string no frontend case
      # matches (and one that still CONTAINS "move_failed", so a =~ here
      # would pass vacuously).
      assert Enum.any?(errors, &(&1["type"] == "move_failed"))
      assert File.exists?(Path.join(source, "Notes.md"))
      refute File.exists?(Path.join(parent, "CleansUp"))
    end
  end
end
