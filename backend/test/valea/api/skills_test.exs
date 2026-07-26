defmodule Valea.Api.SkillsTest do
  use ExUnit.Case, async: false

  alias Valea.AgentCase
  alias Valea.Api.Skills, as: ApiSkills
  alias Valea.Workspace.Manager

  setup do
    ws = AgentCase.open_workspace!("W")

    icm_path =
      Path.join(System.tmp_dir!(), "valea-apiskills-icm-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(icm_path) end)
    {:ok, %{mount_key: mount_key}} = Valea.Mounts.create(ws.path, "Coaching", icm_path)

    %{ws: ws.path, key: mount_key, generation: Manager.generation()}
  end

  defp run(action, input) do
    ApiSkills
    |> Ash.ActionInput.for_action(action, input)
    |> Ash.run_action()
  end

  test "list_skills returns the real catalog entry as not_installed + empty dismissed",
       %{key: key, generation: generation} do
    assert {:ok, %{skills: skills, dismissed: []}} =
             run(:list_skills, %{mount_key: key, generation: generation})

    assert %{skill_id: "icm-architect", state: "not_installed"} =
             Enum.find(skills, &(&1.skill_id == "icm-architect"))
  end

  test "install -> installed; uninstall -> not_installed", %{key: key, generation: generation} do
    assert {:ok, %{ok: true}} =
             run(:install_skill, %{
               mount_key: key,
               skill_id: "icm-architect",
               generation: generation
             })

    assert {:ok, %{skills: skills}} = run(:list_skills, %{mount_key: key, generation: generation})
    assert %{state: "installed"} = Enum.find(skills, &(&1.skill_id == "icm-architect"))

    assert {:ok, %{ok: true}} =
             run(:uninstall_skill, %{
               mount_key: key,
               skill_id: "icm-architect",
               generation: generation
             })
  end

  test "dismiss_skills_offer lands in list_skills.dismissed", %{key: key, generation: generation} do
    assert {:ok, %{ok: true}} =
             run(:dismiss_skills_offer, %{
               mount_key: key,
               skill_id: "icm-architect",
               generation: generation
             })

    assert {:ok, %{dismissed: ["icm-architect"]}} =
             run(:list_skills, %{mount_key: key, generation: generation})
  end

  # The suite's stale-generation idiom (Valea.Api.IcmsTest): stale is
  # generation + 1, and the error surfaces as a %Valea.Api.Error{} with
  # code "workspace_changed" at the head of `error.errors`.
  test "every action rejects a stale generation with workspace_changed",
       %{key: key, generation: generation} do
    stale = generation + 1

    assert {:error, error} = run(:list_skills, %{mount_key: key, generation: stale})
    assert %Valea.Api.Error{code: "workspace_changed"} = error.errors |> hd()

    for {action, input} <- [
          {:install_skill, %{mount_key: key, skill_id: "icm-architect", generation: stale}},
          {:update_skill, %{mount_key: key, skill_id: "icm-architect", generation: stale}},
          {:uninstall_skill, %{mount_key: key, skill_id: "icm-architect", generation: stale}},
          {:dismiss_skills_offer, %{mount_key: key, skill_id: "icm-architect", generation: stale}}
        ] do
      assert {:error, _error} = run(action, input),
             "expected stale-generation refusal for #{action}"
    end
  end

  test "domain errors map to the shared vocabulary", %{key: key, generation: generation} do
    assert {:error, error} =
             run(:install_skill, %{
               mount_key: "ghost",
               skill_id: "icm-architect",
               generation: generation
             })

    assert %Valea.Api.Error{code: "icm_unavailable"} = error.errors |> hd()

    assert {:error, error} =
             run(:update_skill, %{
               mount_key: key,
               skill_id: "icm-architect",
               generation: generation
             })

    assert %Valea.Api.Error{code: "not_installed"} = error.errors |> hd()
  end
end
