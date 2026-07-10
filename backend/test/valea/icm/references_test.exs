defmodule Valea.ICM.ReferencesTest do
  use ExUnit.Case, async: false

  alias Valea.ICM.References
  alias Valea.Workspace.Manager

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-app-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    System.put_env("VALEA_APP_DIR", dir)
    Manager.close()
    {:ok, _} = Manager.create(Path.join(dir, "workspaces"), "W")

    on_exit(fn ->
      Manager.close()
      File.rm_rf!(dir)
      System.delete_env("VALEA_APP_DIR")
    end)

    :ok
  end

  defp ws_path do
    {:ok, %{path: path}} = Manager.current()
    path
  end

  test "finds workflows referencing a page" do
    {:ok, refs} = References.referencing_workflows("Offers/Founder Coaching Package.md")
    assert [%{file: "new_inquiry_triage.yaml", name: "New Inquiry Triage"}] = refs

    {:ok, []} = References.referencing_workflows("Clients/Lea Brunner.md")
  end

  test "rewrite updates the yaml literally and atomically" do
    # Both new_inquiry_triage.yaml and post_session_followup.yaml reference
    # the Email Tone Guide in the seeded workspace template.
    {:ok, ["new_inquiry_triage.yaml", "post_session_followup.yaml"]} =
      References.rewrite("Tone & Voice/Email Tone Guide.md", "Tone & Voice/Voice Guide.md")

    for file <- ["new_inquiry_triage.yaml", "post_session_followup.yaml"] do
      yaml = File.read!(Path.join(ws_path(), "workflows/#{file}"))
      assert yaml =~ "icm/Tone & Voice/Voice Guide.md"
      refute yaml =~ "icm/Tone & Voice/Email Tone Guide.md"
    end
  end

  test "rewrite returns empty list when no workflow references the path" do
    {:ok, []} = References.rewrite("Clients/Lea Brunner.md", "Clients/Someone Else.md")
  end
end
