defmodule Valea.ICM.ReferencesTest do
  use ExUnit.Case, async: false

  alias Valea.ICM.References
  alias Valea.Mounts.Manifest
  alias Valea.Workspace.Manager

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-app-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    System.put_env("VALEA_APP_DIR", dir)
    Manager.close()
    {:ok, ws} = Manager.create(Path.join(dir, "workspaces"), "W")

    write_mount!(ws.path, "a", "Mount A")

    write_page!(
      ws.path,
      "a",
      "Offers/Founder Coaching Package.md",
      "# Founder Coaching Package\n"
    )

    write_page!(ws.path, "a", "Tone & Voice/Email Tone Guide.md", "# Email Tone Guide\n")
    write_page!(ws.path, "a", "Clients/Lea Brunner.md", "# Lea Brunner\n")

    write_workflow!(ws.path, "a", "New Inquiry Triage.md", [
      "Offers/Founder Coaching Package.md",
      "Tone & Voice/Email Tone Guide.md"
    ])

    write_workflow!(ws.path, "a", "Post-Session Follow-up.md", [
      "Tone & Voice/Email Tone Guide.md"
    ])

    # Mount b has a SAME-NAMED page as mount a, and its own workflow
    # referencing it — proving that scanning mount a never leaks into mount
    # b's Workflows/, and vice versa (mount isolation is by directory, not
    # by the needle string matching).
    write_mount!(ws.path, "b", "Mount B")

    write_page!(
      ws.path,
      "b",
      "Offers/Founder Coaching Package.md",
      "# Founder Coaching Package\n"
    )

    write_workflow!(ws.path, "b", "B Triage.md", ["Offers/Founder Coaching Package.md"])

    on_exit(fn ->
      Manager.close()
      File.rm_rf!(dir)
      System.delete_env("VALEA_APP_DIR")
    end)

    %{ws: ws.path}
  end

  defp write_mount!(ws_path, name, title) do
    dir = Path.join([ws_path, "mounts", name])
    File.mkdir_p!(dir)
    Manifest.write!(dir, %{id: Ecto.UUID.generate(), name: title, description: ""})
  end

  defp write_page!(ws_path, mount, inner_rel, content) do
    abs = Path.join([ws_path, "mounts", mount, inner_rel])
    File.mkdir_p!(Path.dirname(abs))
    File.write!(abs, content)
  end

  # `sources` needles are ICM-relative to the workflow's own mount — no
  # `mounts/<name>` prefix, and (post T4) no legacy `icm/` prefix either.
  defp write_workflow!(ws_path, mount, filename, referenced_inner_paths) do
    sources =
      referenced_inner_paths
      |> Enum.with_index()
      |> Enum.map(fn {path, i} -> "  - { id: src#{i}, type: icm, path: \"#{path}\" }" end)
      |> Enum.join("\n")

    content = """
    ---
    sources:
    #{sources}
    ---
    # #{Path.rootname(filename)}
    """

    write_page!(ws_path, mount, Path.join("Workflows", filename), content)
  end

  defp workflows_dir(ws_path, mount), do: Path.join([ws_path, "mounts", mount, "Workflows"])

  test "finds workflows (within the owning mount) referencing a page" do
    {:ok, refs} = References.referencing_workflows("mounts/a/Offers/Founder Coaching Package.md")
    assert [%{file: "New Inquiry Triage.md", name: "New Inquiry Triage"}] = refs

    {:ok, []} = References.referencing_workflows("mounts/a/Clients/Lea Brunner.md")
  end

  test "a same-named page in a different mount is NOT matched (mount isolation)" do
    {:ok, refs_a} =
      References.referencing_workflows("mounts/a/Offers/Founder Coaching Package.md")

    assert Enum.map(refs_a, & &1.file) == ["New Inquiry Triage.md"]

    {:ok, refs_b} =
      References.referencing_workflows("mounts/b/Offers/Founder Coaching Package.md")

    assert Enum.map(refs_b, & &1.file) == ["B Triage.md"]
  end

  test "rewrite updates the ICM-relative needle literally and atomically, within the mount", %{
    ws: ws
  } do
    assert {:ok, ["New Inquiry Triage.md", "Post-Session Follow-up.md"]} =
             References.rewrite(
               "mounts/a/Tone & Voice/Email Tone Guide.md",
               "mounts/a/Tone & Voice/Voice Guide.md"
             )

    for file <- ["New Inquiry Triage.md", "Post-Session Follow-up.md"] do
      page = File.read!(Path.join(workflows_dir(ws, "a"), file))
      assert page =~ "Tone & Voice/Voice Guide.md"
      refute page =~ "Tone & Voice/Email Tone Guide.md"
    end

    # Mount b's own (same-shaped) reference is untouched.
    b_page = File.read!(Path.join(workflows_dir(ws, "b"), "B Triage.md"))
    assert b_page =~ "Offers/Founder Coaching Package.md"
  end

  test "rewrite returns empty list when no workflow references the path" do
    {:ok, []} =
      References.rewrite("mounts/a/Clients/Lea Brunner.md", "mounts/a/Clients/Someone Else.md")
  end

  test "rewrite rejects a cross-mount pair — a rename never crosses mounts", %{ws: ws} do
    assert {:error, :cross_mount_rename} =
             References.rewrite(
               "mounts/a/Offers/Founder Coaching Package.md",
               "mounts/b/Offers/Renamed.md"
             )

    # Neither mount's workflows were touched.
    a_page = File.read!(Path.join(workflows_dir(ws, "a"), "New Inquiry Triage.md"))
    assert a_page =~ "Offers/Founder Coaching Package.md"

    b_page = File.read!(Path.join(workflows_dir(ws, "b"), "B Triage.md"))
    assert b_page =~ "Offers/Founder Coaching Package.md"
  end

  test "rewrite returns error on write failure", %{ws: ws} do
    dir = workflows_dir(ws, "a")
    File.chmod!(dir, 0o555)

    on_exit(fn -> File.chmod!(dir, 0o755) end)

    result =
      References.rewrite(
        "mounts/a/Tone & Voice/Email Tone Guide.md",
        "mounts/a/Tone & Voice/Voice Guide.md"
      )

    assert {:error, {:rewrite_failed, filename, _reason}} = result
    assert filename in ["New Inquiry Triage.md", "Post-Session Follow-up.md"]
  end

  test "referencing_workflows rejects a path that doesn't name a real mount" do
    assert {:error, :outside_workspace} = References.referencing_workflows("Offers/Nope.md")

    assert {:error, :outside_workspace} =
             References.referencing_workflows("mounts/does-not-exist/Nope.md")
  end

  test "rewrite rejects a path that doesn't name a real mount" do
    assert {:error, :outside_workspace} =
             References.rewrite("Offers/Nope.md", "Offers/Also-Nope.md")
  end

  describe "anchored needle matching" do
    setup %{ws: ws} do
      write_page!(ws, "a", "Offers/X.md", "# X\n")
      write_page!(ws, "a", "Special Offers/X.md", "# Special X\n")
      write_page!(ws, "a", "MoreOffers/X.md", "# More X\n")
      :ok
    end

    test "a longer real path (Special Offers/X.md) is neither listed nor corrupted", %{ws: ws} do
      write_workflow!(ws, "a", "Special Ref.md", ["Special Offers/X.md"])
      before = File.read!(Path.join(workflows_dir(ws, "a"), "Special Ref.md"))

      {:ok, refs} = References.referencing_workflows("mounts/a/Offers/X.md")
      refute Enum.any?(refs, &(&1.file == "Special Ref.md"))

      {:ok, updated} = References.rewrite("mounts/a/Offers/X.md", "mounts/a/Offers/Y.md")
      refute "Special Ref.md" in updated
      assert File.read!(Path.join(workflows_dir(ws, "a"), "Special Ref.md")) == before
    end

    test "a no-space token continuation (MoreOffers/X.md) is not matched", %{ws: ws} do
      write_workflow!(ws, "a", "More Ref.md", ["MoreOffers/X.md"])
      before = File.read!(Path.join(workflows_dir(ws, "a"), "More Ref.md"))

      {:ok, refs} = References.referencing_workflows("mounts/a/Offers/X.md")
      refute Enum.any?(refs, &(&1.file == "More Ref.md"))

      {:ok, updated} = References.rewrite("mounts/a/Offers/X.md", "mounts/a/Offers/Y.md")
      refute "More Ref.md" in updated
      assert File.read!(Path.join(workflows_dir(ws, "a"), "More Ref.md")) == before
    end

    test "quoted, YAML-list, markdown-link, line-start, and prose-space forms all match and rewrite",
         %{ws: ws} do
      # `see Offers/X.md` is a space-preceded prose mention whose leftward
      # extension ("Offers/X.md) and see Offers/X.md", back to the nearest
      # opening delimiter) is NOT an existing path, so it still counts.
      content = """
      ---
      sources:
        - { id: quoted, type: icm, path: "Offers/X.md" }
        - Offers/X.md
      ---
      Offers/X.md
      A [link](Offers/X.md) and see Offers/X.md in prose.
      """

      write_page!(ws, "a", "Workflows/Anchor Forms.md", content)

      {:ok, refs} = References.referencing_workflows("mounts/a/Offers/X.md")
      assert Enum.any?(refs, &(&1.file == "Anchor Forms.md"))

      {:ok, updated} = References.rewrite("mounts/a/Offers/X.md", "mounts/a/Offers/Y.md")
      assert "Anchor Forms.md" in updated

      page = File.read!(Path.join(workflows_dir(ws, "a"), "Anchor Forms.md"))
      refute page =~ "Offers/X.md"
      assert page =~ ~s(path: "Offers/Y.md")
      assert page =~ "- Offers/Y.md"
      assert page =~ "(Offers/Y.md)"
      assert page =~ "\nOffers/Y.md"
      assert page =~ "see Offers/Y.md"
    end

    test "a wildcard reference to a longer real folder survives a folder rename", %{ws: ws} do
      # `Clients/` already exists in the outer setup; `My Clients/` is the
      # longer real folder whose wildcard reference must not be corrupted —
      # the candidate `My Clients/*` can never exist as a literal file, so
      # the probe must check the folder itself.
      write_page!(ws, "a", "My Clients/Special.md", "# Special\n")
      write_workflow!(ws, "a", "My Wildcard.md", ["My Clients/*"])
      write_workflow!(ws, "a", "Wildcard.md", ["Clients/*"])
      before = File.read!(Path.join(workflows_dir(ws, "a"), "My Wildcard.md"))

      {:ok, refs} = References.referencing_workflows("mounts/a/Clients/*")
      assert Enum.map(refs, & &1.file) == ["Wildcard.md"]

      {:ok, updated} = References.rewrite("mounts/a/Clients/*", "mounts/a/Customers/*")
      assert updated == ["Wildcard.md"]
      assert File.read!(Path.join(workflows_dir(ws, "a"), "My Wildcard.md")) == before

      page = File.read!(Path.join(workflows_dir(ws, "a"), "Wildcard.md"))
      assert page =~ ~s(path: "Customers/*")
      refute page =~ "Clients/*"
    end

    test "an opener character inside a longer real path does not truncate the probe", %{ws: ws} do
      # `Lea's Notes/X.md` contains a `'` — the left extension must not stop
      # at the first delimiter it meets (candidate `s Notes/X.md` doesn't
      # exist) but keep extending to `Lea's Notes/X.md`, which does.
      write_page!(ws, "a", "Notes/X.md", "# X\n")
      write_page!(ws, "a", "Lea's Notes/X.md", "# Lea's X\n")
      write_workflow!(ws, "a", "Lea Ref.md", ["Lea's Notes/X.md"])
      write_workflow!(ws, "a", "Notes Ref.md", ["Notes/X.md"])
      before = File.read!(Path.join(workflows_dir(ws, "a"), "Lea Ref.md"))

      {:ok, refs} = References.referencing_workflows("mounts/a/Notes/X.md")
      assert Enum.map(refs, & &1.file) == ["Notes Ref.md"]

      {:ok, updated} = References.rewrite("mounts/a/Notes/X.md", "mounts/a/Notes/Y.md")
      assert updated == ["Notes Ref.md"]
      assert File.read!(Path.join(workflows_dir(ws, "a"), "Lea Ref.md")) == before

      page = File.read!(Path.join(workflows_dir(ws, "a"), "Notes Ref.md"))
      assert page =~ ~s(path: "Notes/Y.md")
      refute page =~ "Notes/X.md"
    end
  end

  test "a bare mount-root path is invalid for both functions" do
    assert {:error, :invalid_path} = References.referencing_workflows("mounts/a")
    assert {:error, :invalid_path} = References.rewrite("mounts/a", "mounts/a/Offers/X.md")
    assert {:error, :invalid_path} = References.rewrite("mounts/a/Offers/X.md", "mounts/a")
  end

  test "errors without a workspace" do
    Manager.close()

    assert {:error, :no_workspace} =
             References.referencing_workflows("mounts/a/Offers/Founder Coaching Package.md")

    assert {:error, :no_workspace} =
             References.rewrite(
               "mounts/a/Offers/Founder Coaching Package.md",
               "mounts/a/Offers/Renamed.md"
             )
  end

  describe "external mounts (A2-T5b)" do
    alias Valea.Mounts

    defp declare_external!(ws_path, name, ref) do
      config_path = Path.join(ws_path, "config/workspace.yaml")
      {:ok, doc} = YamlElixir.read_from_file(config_path)

      mounts = Map.put(Map.get(doc, "mounts") || %{}, name, %{"kind" => "path", "ref" => ref})

      header = for key <- ["version", "id"], Map.has_key?(doc, key), do: "#{key}: #{doc[key]}"

      entries =
        Enum.flat_map(Enum.sort_by(mounts, &elem(&1, 0)), fn {n, entry} ->
          [
            "  #{n}:"
            | Enum.map(Enum.sort_by(entry, &elem(&1, 0)), fn {k, v} ->
                "    #{k}: #{inspect(v)}"
              end)
          ]
        end)

      File.write!(config_path, Enum.join(header ++ ["mounts:"] ++ entries, "\n") <> "\n")
    end

    defp external_icm!(name) do
      dir =
        Path.join(
          System.tmp_dir!(),
          "valea-ext-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      Manifest.write!(dir, %{
        id: "41d871cd-aadc-466f-a951-a5c47e197d47",
        name: name,
        description: ""
      })

      dir
    end

    setup %{ws: ws} do
      ext = external_icm!("Ext")

      File.mkdir_p!(Path.join(ext, "Offers"))
      File.write!(Path.join(ext, "Offers/X.md"), "# X\n")

      File.mkdir_p!(Path.join(ext, "Workflows"))

      File.write!(
        Path.join(ext, "Workflows/Ext Triage.md"),
        """
        ---
        sources:
          - { id: src0, type: icm, path: "Offers/X.md" }
        ---
        # Ext Triage
        """
      )

      declare_external!(ws, "ext", ext)
      [m] = Enum.filter(Mounts.enabled(ws), &(&1.name == "ext"))
      %{mount: m}
    end

    test "finds workflows referencing a page by its absolute physical path, needle is mount-relative",
         %{mount: m} do
      page_abs = Path.join(m.root, "Offers/X.md")

      assert {:ok, [%{file: "Ext Triage.md", name: "Ext Triage"}]} =
               References.referencing_workflows(page_abs)
    end

    test "rewrite updates the external mount's own workflow, embedded mount's workflows untouched",
         %{mount: m, ws: ws} do
      old_abs = Path.join(m.root, "Offers/X.md")
      new_abs = Path.join(m.root, "Offers/Y.md")

      assert {:ok, ["Ext Triage.md"]} = References.rewrite(old_abs, new_abs)

      page = File.read!(Path.join(m.root, "Workflows/Ext Triage.md"))
      assert page =~ ~s(path: "Offers/Y.md")
      refute page =~ "Offers/X.md"

      # Mount a's own workflows (embedded, from the outer setup) are untouched.
      a_page = File.read!(Path.join([ws, "mounts", "a", "Workflows", "New Inquiry Triage.md"]))
      assert a_page =~ "Offers/Founder Coaching Package.md"
    end

    test "cross-mount rename (embedded -> external, or vice versa) is rejected", %{mount: m} do
      assert {:error, :cross_mount_rename} =
               References.rewrite(
                 "mounts/a/Offers/Founder Coaching Package.md",
                 Path.join(m.root, "Offers/Renamed.md")
               )

      assert {:error, :cross_mount_rename} =
               References.rewrite(
                 Path.join(m.root, "Offers/X.md"),
                 "mounts/a/Offers/Renamed.md"
               )
    end

    test "a bare external mount-root path is invalid (empty needle)", %{mount: m} do
      assert {:error, :invalid_path} = References.referencing_workflows(m.root)

      assert {:error, :invalid_path} =
               References.rewrite(m.root, Path.join(m.root, "Offers/X.md"))
    end
  end
end
