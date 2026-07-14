defmodule Valea.Api.IcmsTest do
  @moduledoc """
  Direct Ash-action coverage for `Valea.Api.Icms` (task 3.4) — calls each
  generic action straight through `Ash.ActionInput.for_action/3` +
  `Ash.run_action/1`, bypassing the RPC/channel transport entirely (that
  layer is exercised by the codegen'd client + `bun run check`, not this
  suite). Mirrors `Valea.AgentCase.open_workspace!/1`'s workspace setup.
  """
  use ExUnit.Case, async: false

  alias Valea.AgentCase
  alias Valea.Api.Icms
  alias Valea.Workspace.Manager

  setup do
    ws = AgentCase.open_workspace!("W")
    %{ws: ws.path, generation: Manager.generation()}
  end

  defp run(action, input) do
    Icms
    |> Ash.ActionInput.for_action(action, input)
    |> Ash.run_action()
  end

  defp icm_dir!(home, name) do
    Path.join(home, "valea-icms-test-#{name}-#{System.unique_integer([:positive])}")
  end

  test "list_icms is empty for a fresh workspace", %{generation: generation} do
    assert {:ok, %{icms: []}} = run(:list_icms, %{generation: generation})
  end

  test "create_icm mints a new external ICM, list_icms shows it healthy, enable/unmount reflect through",
       %{generation: generation} do
    path = icm_dir!(System.tmp_dir!(), "coaching")
    on_exit(fn -> File.rm_rf!(path) end)

    assert {:ok, %{mount_key: mount_key, id: id}} =
             run(:create_icm, %{name: "Coaching", path: path, generation: generation})

    assert mount_key == "coaching"
    assert is_binary(id)

    assert {:ok, %{icms: [icm]}} = run(:list_icms, %{generation: generation})

    assert %{
             mount_key: "coaching",
             id: ^id,
             name: "Coaching",
             description: "",
             enabled: true,
             degraded: nil
           } = icm

    assert icm.root =~ path

    assert {:ok, %{"saved" => true}} =
             run(:set_icm_enabled, %{mount_key: mount_key, enabled: false, generation: generation})

    assert {:ok, %{icms: [%{enabled: false}]}} = run(:list_icms, %{generation: generation})

    assert {:ok, %{"unmounted" => true}} =
             run(:unmount_icm, %{mount_key: mount_key, generation: generation})

    assert {:ok, %{icms: []}} = run(:list_icms, %{generation: generation})
  end

  test "mount_icm registers an already-existing healthy ICM folder", %{
    ws: ws,
    generation: generation
  } do
    icm = AgentCase.mount_test_icm!(ws, name: "Existing")

    assert {:ok, %{"unmounted" => true}} =
             run(:unmount_icm, %{mount_key: icm.mount_key, generation: generation})

    assert {:ok, %{icms: []}} = run(:list_icms, %{generation: generation})

    assert {:ok, %{mount_key: mount_key, id: id}} =
             run(:mount_icm, %{path: icm.root, generation: generation})

    assert mount_key == icm.mount_key
    assert id == icm.id

    assert {:ok, %{icms: [%{mount_key: ^mount_key, degraded: nil}]}} =
             run(:list_icms, %{generation: generation})
  end

  test "icm_doctor scopes checks to the requested mount_key", %{ws: ws, generation: generation} do
    icm = AgentCase.mount_test_icm!(ws, name: "Solo")

    assert {:ok, %{"ok" => ok, "checks" => checks}} =
             run(:icm_doctor, %{mount_key: icm.mount_key, generation: generation})

    assert is_boolean(ok)
    assert checks != []
    assert Enum.all?(checks, &String.ends_with?(&1["id"], ":#{icm.mount_key}"))
    assert ok == Enum.all?(checks, &(&1["status"] == "ok"))
  end

  test "every action rejects a stale generation with workspace_changed", %{generation: generation} do
    stale = generation + 1

    assert {:error, error} = run(:list_icms, %{generation: stale})
    assert %Valea.Api.Error{code: "workspace_changed"} = error.errors |> hd()

    assert {:error, _} = run(:mount_icm, %{path: "/tmp/nope", generation: stale})
    assert {:error, _} = run(:create_icm, %{name: "X", path: "/tmp/nope", generation: stale})

    assert {:error, _} =
             run(:set_icm_enabled, %{mount_key: "nope", enabled: true, generation: stale})

    assert {:error, _} = run(:unmount_icm, %{mount_key: "nope", generation: stale})
    assert {:error, _} = run(:icm_doctor, %{mount_key: "nope", generation: stale})
  end
end
