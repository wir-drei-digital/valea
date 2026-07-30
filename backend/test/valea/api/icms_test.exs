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
  alias Valea.Mounts.Manifest
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

  describe "inspect_icm/1" do
    test "a healthy format-2 ICM folder returns ok: true with its manifest name/description" do
      dir = icm_dir!(System.tmp_dir!(), "healthy")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      File.write!(
        Path.join(dir, "icm.yaml"),
        Manifest.render(%{id: Ecto.UUID.generate(), name: "Coaching", description: "Notes"})
      )

      assert {:ok,
              %{"ok" => true, "name" => "Coaching", "description" => "Notes", "reason" => nil}} =
               run(:inspect_icm, %{path: dir})
    end

    test "a non-ICM folder (no icm.yaml) returns ok: false with a human-readable reason" do
      dir = icm_dir!(System.tmp_dir!(), "plain")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      assert {:ok, %{"ok" => false, "name" => nil, "description" => nil, "reason" => reason}} =
               run(:inspect_icm, %{path: dir})

      assert is_binary(reason)
    end

    test "a nonexistent path returns ok: false" do
      missing =
        Path.join(
          System.tmp_dir!(),
          "valea-icms-test-missing-#{System.unique_integer([:positive])}"
        )

      assert {:ok, %{"ok" => false, "reason" => reason}} = run(:inspect_icm, %{path: missing})
      assert is_binary(reason)
    end

    test "a legacy format-1 manifest is accepted — aligned with mounting (Task 12)" do
      dir = icm_dir!(System.tmp_dir!(), "legacy")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      File.write!(
        Path.join(dir, "icm.yaml"),
        "format: 1\nid: #{Ecto.UUID.generate()}\nname: Legacy\n"
      )

      assert {:ok, %{"ok" => true, "name" => "Legacy", "adoptable" => false}} =
               run(:inspect_icm, %{path: dir})
    end

    test "an invalid (non-uuid) id is rejected" do
      dir = icm_dir!(System.tmp_dir!(), "badid")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      File.write!(Path.join(dir, "icm.yaml"), "id: not-a-uuid\nname: X\n")

      assert {:ok, %{"ok" => false, "reason" => reason}} = run(:inspect_icm, %{path: dir})
      assert is_binary(reason)
    end

    test "a relative path is rejected" do
      assert {:ok, %{"ok" => false, "reason" => reason}} =
               run(:inspect_icm, %{path: "relative/path"})

      assert is_binary(reason)
    end

    test "the home directory is rejected as a boundary violation" do
      assert {:ok, %{"ok" => false, "reason" => reason}} =
               run(:inspect_icm, %{path: System.user_home!()})

      assert reason =~ "home"
    end

    test "the filesystem root is rejected as a boundary violation" do
      assert {:ok, %{"ok" => false, "reason" => reason}} = run(:inspect_icm, %{path: "/"})
      assert reason =~ "root"
    end

    test "requires no generation argument and works with no workspace open at all" do
      Manager.close()
      assert {:error, :no_workspace} = Manager.current()

      dir = icm_dir!(System.tmp_dir!(), "noworkspace")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      File.write!(
        Path.join(dir, "icm.yaml"),
        Manifest.render(%{id: Ecto.UUID.generate(), name: "Solo", description: ""})
      )

      assert {:ok, %{"ok" => true, "name" => "Solo"}} = run(:inspect_icm, %{path: dir})
    end
  end

  describe "inspect_icm adoptable (Task 12, Spec D §D4)" do
    test "manifest-less folder inside boundaries → ok false, adoptable true" do
      dir = icm_dir!(System.tmp_dir!(), "adoptable")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      assert {:ok, %{"ok" => false, "adoptable" => true, "reason" => reason}} =
               run(:inspect_icm, %{path: dir})

      assert reason =~ "no icm.yaml"
    end

    test "boundary-rejected folder is NOT adoptable" do
      assert {:ok, %{"ok" => false, "adoptable" => false}} =
               run(:inspect_icm, %{path: System.user_home!()})
    end

    test "format-1 manifest now inspects ok (aligned with mounting)" do
      dir = icm_dir!(System.tmp_dir!(), "legacy-adoptable")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      File.write!(
        Path.join(dir, "icm.yaml"),
        "format: 1\nid: #{Ecto.UUID.generate()}\nname: Legacy\n"
      )

      assert {:ok, %{"ok" => true, "adoptable" => false, "name" => _}} =
               run(:inspect_icm, %{path: dir})
    end

    test "invalid manifest is neither ok nor adoptable" do
      dir = icm_dir!(System.tmp_dir!(), "invalid-adoptable")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      File.write!(Path.join(dir, "icm.yaml"), "id: not-a-uuid\nname: X\n")

      assert {:ok, %{"ok" => false, "adoptable" => false}} = run(:inspect_icm, %{path: dir})
    end
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

    assert {:error, _} = run(:list_icm_mail_access, %{generation: stale})

    assert {:error, _} =
             run(:set_icm_mail_access, %{
               mount_key: "nope",
               account: "mara",
               enabled: true,
               generation: stale
             })
  end

  # The Mail settings UI's per-project access toggles — over the CONTEXT.md
  # `related_icms:` grammar, which stays the single source of truth.
  describe "icm mail access" do
    defp write_mail_yaml!(ws, slug) do
      path = Path.join(ws, "config/mail.yaml")
      File.mkdir_p!(Path.dirname(path))

      File.write!(path, """
      version: 4
      accounts:
        #{slug}:
          imap:
            host: imap.example.com
            port: 993
            username: #{slug}@example.com
      """)
    end

    test "set adds/removes the CONTEXT.md entry and list reflects it", %{
      ws: ws,
      generation: generation
    } do
      icm = AgentCase.mount_test_icm!(ws, name: "Primary")
      write_mail_yaml!(ws, "mara")

      assert {:ok, %{access: [%{mount_key: mount_key, accounts: []}]}} =
               run(:list_icm_mail_access, %{generation: generation})

      assert mount_key == icm.mount_key

      assert {:ok, %{saved: true, accounts: ["mara"]}} =
               run(:set_icm_mail_access, %{
                 mount_key: icm.mount_key,
                 account: "mara",
                 enabled: true,
                 generation: generation
               })

      assert File.read!(Path.join(icm.root, "CONTEXT.md")) =~ "- mail-mara"

      assert {:ok, %{access: [%{accounts: ["mara"]}]}} =
               run(:list_icm_mail_access, %{generation: generation})

      assert {:ok, %{saved: true, accounts: []}} =
               run(:set_icm_mail_access, %{
                 mount_key: icm.mount_key,
                 account: "mara",
                 enabled: false,
                 generation: generation
               })

      refute File.read!(Path.join(icm.root, "CONTEXT.md")) =~ "mail-mara"
    end

    test "enabling requires a configured account; disabling a stale entry does not", %{
      ws: ws,
      generation: generation
    } do
      icm = AgentCase.mount_test_icm!(ws, name: "Primary")

      assert {:error, error} =
               run(:set_icm_mail_access, %{
                 mount_key: icm.mount_key,
                 account: "ghost",
                 enabled: true,
                 generation: generation
               })

      assert %Valea.Api.Error{code: "account_unknown"} = error.errors |> hd()

      # A stale entry whose account is gone may still be cleaned up.
      File.write!(
        Path.join(icm.root, "CONTEXT.md"),
        "---\nrelated_icms:\n  - mail-ghost\n---\n"
      )

      assert {:ok, %{saved: true, accounts: []}} =
               run(:set_icm_mail_access, %{
                 mount_key: icm.mount_key,
                 account: "ghost",
                 enabled: false,
                 generation: generation
               })
    end

    test "an unknown or disabled ICM earns no toggle", %{ws: ws, generation: generation} do
      icm = AgentCase.mount_test_icm!(ws, name: "Primary")
      write_mail_yaml!(ws, "mara")

      assert {:ok, %{"saved" => true}} =
               run(:set_icm_enabled, %{
                 mount_key: icm.mount_key,
                 enabled: false,
                 generation: generation
               })

      assert {:ok, %{access: []}} = run(:list_icm_mail_access, %{generation: generation})

      for key <- [icm.mount_key, "nope"] do
        assert {:error, error} =
                 run(:set_icm_mail_access, %{
                   mount_key: key,
                   account: "mara",
                   enabled: true,
                   generation: generation
                 })

        assert %Valea.Api.Error{code: "icm_unavailable"} = error.errors |> hd()
      end
    end
  end
end
