defmodule Valea.ICM.ReferencesTest do
  use ExUnit.Case, async: false

  alias Valea.AgentCase
  alias Valea.ICM.References
  alias Valea.Workspace.Manager

  # Post-task-3.2, `Valea.Mounts.list/1` is config truth over `icms:` ONLY —
  # every mount is external (by-reference), so `setup` mounts TWO real
  # external ICMs (`AgentCase.mount_test_icm!/2`) instead of hand-writing
  # manifests under a workspace-embedded `mounts/<name>/` directory. Task
  # 4.2 re-key: `referencing_workflows/2`/`rewrite/3` take `mount_key` + an
  # ICM-relative path — never a hand-written `"mounts/<name>/..."` literal,
  # never an absolute `icm.root`-joined one.
  setup do
    ws = AgentCase.open_workspace!("W")

    a =
      AgentCase.mount_test_icm!(ws.path,
        name: "Mount A",
        pages: %{
          "Offers/Founder Coaching Package.md" => "# Founder Coaching Package\n",
          "Tone & Voice/Email Tone Guide.md" => "# Email Tone Guide\n",
          "Clients/Lea Brunner.md" => "# Lea Brunner\n",
          "Workflows/New Inquiry Triage.md" =>
            workflow_content(
              ["Offers/Founder Coaching Package.md", "Tone & Voice/Email Tone Guide.md"],
              "New Inquiry Triage"
            ),
          "Workflows/Post-Session Follow-up.md" =>
            workflow_content(["Tone & Voice/Email Tone Guide.md"], "Post-Session Follow-up")
        }
      )

    # Mount b has a SAME-NAMED page as mount a, and its own workflow
    # referencing it — proving that scanning mount a never leaks into mount
    # b's Workflows/, and vice versa (mount isolation is by directory, not
    # by the needle string matching).
    b =
      AgentCase.mount_test_icm!(ws.path,
        name: "Mount B",
        pages: %{
          "Offers/Founder Coaching Package.md" => "# Founder Coaching Package\n",
          "Workflows/B Triage.md" =>
            workflow_content(["Offers/Founder Coaching Package.md"], "B Triage")
        }
      )

    %{ws: ws.path, a: a, b: b}
  end

  defp write_page!(icm, inner_rel, content) do
    abs = Path.join(icm.root, inner_rel)
    File.mkdir_p!(Path.dirname(abs))
    File.write!(abs, content)
  end

  # `sources` needles are ICM-relative to the workflow's own mount — no
  # `mounts/<name>` prefix, and (post T4) no legacy `icm/` prefix either.
  defp workflow_content(referenced_inner_paths, title) do
    sources =
      referenced_inner_paths
      |> Enum.with_index()
      |> Enum.map(fn {path, i} -> "  - { id: src#{i}, type: icm, path: \"#{path}\" }" end)
      |> Enum.join("\n")

    """
    ---
    sources:
    #{sources}
    ---
    # #{title}
    """
  end

  defp write_workflow!(icm, filename, referenced_inner_paths) do
    content = workflow_content(referenced_inner_paths, Path.rootname(filename))
    write_page!(icm, Path.join("Workflows", filename), content)
  end

  defp workflows_dir(icm), do: Path.join(icm.root, "Workflows")

  test "finds workflows (within the owning mount) referencing a page", %{a: a} do
    {:ok, refs} =
      References.referencing_workflows(a.mount_key, "Offers/Founder Coaching Package.md")

    assert [%{file: "New Inquiry Triage.md", name: "New Inquiry Triage"}] = refs

    {:ok, []} = References.referencing_workflows(a.mount_key, "Clients/Lea Brunner.md")
  end

  test "a same-named page in a different mount is NOT matched (mount isolation)", %{a: a, b: b} do
    {:ok, refs_a} =
      References.referencing_workflows(a.mount_key, "Offers/Founder Coaching Package.md")

    assert Enum.map(refs_a, & &1.file) == ["New Inquiry Triage.md"]

    {:ok, refs_b} =
      References.referencing_workflows(b.mount_key, "Offers/Founder Coaching Package.md")

    assert Enum.map(refs_b, & &1.file) == ["B Triage.md"]
  end

  test "rewrite updates the ICM-relative needle literally and atomically, within the mount", %{
    a: a,
    b: b
  } do
    assert {:ok, ["New Inquiry Triage.md", "Post-Session Follow-up.md"]} =
             References.rewrite(
               a.mount_key,
               "Tone & Voice/Email Tone Guide.md",
               "Tone & Voice/Voice Guide.md"
             )

    for file <- ["New Inquiry Triage.md", "Post-Session Follow-up.md"] do
      page = File.read!(Path.join(workflows_dir(a), file))
      assert page =~ "Tone & Voice/Voice Guide.md"
      refute page =~ "Tone & Voice/Email Tone Guide.md"
    end

    # Mount b's own (same-shaped) reference is untouched.
    b_page = File.read!(Path.join(workflows_dir(b), "B Triage.md"))
    assert b_page =~ "Offers/Founder Coaching Package.md"
  end

  test "rewrite returns empty list when no workflow references the path", %{a: a} do
    {:ok, []} =
      References.rewrite(a.mount_key, "Clients/Lea Brunner.md", "Clients/Someone Else.md")
  end

  test "rewrite never crosses mounts — only one mount_key is ever addressable per call", %{
    a: a,
    b: b
  } do
    # There is no signature under the (mount_key, old_rel, new_rel) shape
    # that could even NAME a cross-mount pair any more — a rename is
    # structurally confined to the one mount_key given. Confirm both
    # mounts' workflows stay exactly as seeded.
    a_page = File.read!(Path.join(workflows_dir(a), "New Inquiry Triage.md"))
    assert a_page =~ "Offers/Founder Coaching Package.md"

    b_page = File.read!(Path.join(workflows_dir(b), "B Triage.md"))
    assert b_page =~ "Offers/Founder Coaching Package.md"
  end

  test "rewrite returns error on write failure", %{a: a} do
    dir = workflows_dir(a)
    File.chmod!(dir, 0o555)

    on_exit(fn -> File.chmod!(dir, 0o755) end)

    result =
      References.rewrite(
        a.mount_key,
        "Tone & Voice/Email Tone Guide.md",
        "Tone & Voice/Voice Guide.md"
      )

    assert {:error, {:rewrite_failed, filename, _reason}} = result
    assert filename in ["New Inquiry Triage.md", "Post-Session Follow-up.md"]
  end

  test "referencing_workflows rejects an unknown/disabled mount key" do
    assert {:error, :outside_workspace} =
             References.referencing_workflows("does-not-exist", "Nope.md")
  end

  test "rewrite rejects an unknown/disabled mount key" do
    assert {:error, :outside_workspace} =
             References.rewrite("does-not-exist", "Offers/Nope.md", "Offers/Also-Nope.md")
  end

  describe "anchored needle matching" do
    setup %{a: a} do
      write_page!(a, "Offers/X.md", "# X\n")
      write_page!(a, "Special Offers/X.md", "# Special X\n")
      write_page!(a, "MoreOffers/X.md", "# More X\n")
      :ok
    end

    test "a longer real path (Special Offers/X.md) is neither listed nor corrupted", %{a: a} do
      write_workflow!(a, "Special Ref.md", ["Special Offers/X.md"])
      before = File.read!(Path.join(workflows_dir(a), "Special Ref.md"))

      {:ok, refs} = References.referencing_workflows(a.mount_key, "Offers/X.md")
      refute Enum.any?(refs, &(&1.file == "Special Ref.md"))

      {:ok, updated} = References.rewrite(a.mount_key, "Offers/X.md", "Offers/Y.md")

      refute "Special Ref.md" in updated
      assert File.read!(Path.join(workflows_dir(a), "Special Ref.md")) == before
    end

    test "a no-space token continuation (MoreOffers/X.md) is not matched", %{a: a} do
      write_workflow!(a, "More Ref.md", ["MoreOffers/X.md"])
      before = File.read!(Path.join(workflows_dir(a), "More Ref.md"))

      {:ok, refs} = References.referencing_workflows(a.mount_key, "Offers/X.md")
      refute Enum.any?(refs, &(&1.file == "More Ref.md"))

      {:ok, updated} = References.rewrite(a.mount_key, "Offers/X.md", "Offers/Y.md")

      refute "More Ref.md" in updated
      assert File.read!(Path.join(workflows_dir(a), "More Ref.md")) == before
    end

    test "quoted, YAML-list, markdown-link, line-start, and prose-space forms all match and rewrite",
         %{a: a} do
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

      write_page!(a, "Workflows/Anchor Forms.md", content)

      {:ok, refs} = References.referencing_workflows(a.mount_key, "Offers/X.md")
      assert Enum.any?(refs, &(&1.file == "Anchor Forms.md"))

      {:ok, updated} = References.rewrite(a.mount_key, "Offers/X.md", "Offers/Y.md")

      assert "Anchor Forms.md" in updated

      page = File.read!(Path.join(workflows_dir(a), "Anchor Forms.md"))
      refute page =~ "Offers/X.md"
      assert page =~ ~s(path: "Offers/Y.md")
      assert page =~ "- Offers/Y.md"
      assert page =~ "(Offers/Y.md)"
      assert page =~ "\nOffers/Y.md"
      assert page =~ "see Offers/Y.md"
    end

    test "a wildcard reference to a longer real folder survives a folder rename", %{a: a} do
      # `Clients/` already exists in the outer setup; `My Clients/` is the
      # longer real folder whose wildcard reference must not be corrupted —
      # the candidate `My Clients/*` can never exist as a literal file, so
      # the probe must check the folder itself.
      write_page!(a, "My Clients/Special.md", "# Special\n")
      write_workflow!(a, "My Wildcard.md", ["My Clients/*"])
      write_workflow!(a, "Wildcard.md", ["Clients/*"])
      before = File.read!(Path.join(workflows_dir(a), "My Wildcard.md"))

      {:ok, refs} = References.referencing_workflows(a.mount_key, "Clients/*")
      assert Enum.map(refs, & &1.file) == ["Wildcard.md"]

      {:ok, updated} = References.rewrite(a.mount_key, "Clients/*", "Customers/*")

      assert updated == ["Wildcard.md"]
      assert File.read!(Path.join(workflows_dir(a), "My Wildcard.md")) == before

      page = File.read!(Path.join(workflows_dir(a), "Wildcard.md"))
      assert page =~ ~s(path: "Customers/*")
      refute page =~ "Clients/*"
    end

    test "an opener character inside a longer real path does not truncate the probe", %{a: a} do
      # `Lea's Notes/X.md` contains a `'` — the left extension must not stop
      # at the first delimiter it meets (candidate `s Notes/X.md` doesn't
      # exist) but keep extending to `Lea's Notes/X.md`, which does.
      write_page!(a, "Notes/X.md", "# X\n")
      write_page!(a, "Lea's Notes/X.md", "# Lea's X\n")
      write_workflow!(a, "Lea Ref.md", ["Lea's Notes/X.md"])
      write_workflow!(a, "Notes Ref.md", ["Notes/X.md"])
      before = File.read!(Path.join(workflows_dir(a), "Lea Ref.md"))

      {:ok, refs} = References.referencing_workflows(a.mount_key, "Notes/X.md")
      assert Enum.map(refs, & &1.file) == ["Notes Ref.md"]

      {:ok, updated} = References.rewrite(a.mount_key, "Notes/X.md", "Notes/Y.md")

      assert updated == ["Notes Ref.md"]
      assert File.read!(Path.join(workflows_dir(a), "Lea Ref.md")) == before

      page = File.read!(Path.join(workflows_dir(a), "Notes Ref.md"))
      assert page =~ ~s(path: "Notes/Y.md")
      refute page =~ "Notes/X.md"
    end
  end

  test "a bare mount-root path (\"\") is invalid for both functions", %{a: a} do
    assert {:error, :invalid_path} = References.referencing_workflows(a.mount_key, "")
    assert {:error, :invalid_path} = References.rewrite(a.mount_key, "", "Offers/X.md")
    assert {:error, :invalid_path} = References.rewrite(a.mount_key, "Offers/X.md", "")
  end

  test "errors without a workspace", %{a: a} do
    mount_key = a.mount_key

    Manager.close()

    assert {:error, :no_workspace} =
             References.referencing_workflows(mount_key, "Offers/Founder Coaching Package.md")

    assert {:error, :no_workspace} =
             References.rewrite(
               mount_key,
               "Offers/Founder Coaching Package.md",
               "Offers/Renamed.md"
             )
  end

  describe "external mounts (A2-T5b)" do
    setup %{ws: ws} do
      ext =
        AgentCase.mount_test_icm!(ws,
          name: "Ext",
          id: "41d871cd-aadc-466f-a951-a5c47e197d47",
          pages: %{
            "Offers/X.md" => "# X\n",
            "Workflows/Ext Triage.md" => """
            ---
            sources:
              - { id: src0, type: icm, path: "Offers/X.md" }
            ---
            # Ext Triage
            """
          }
        )

      %{mount: ext}
    end

    test "finds workflows referencing a page by (mount_key, ICM-relative path)",
         %{mount: m} do
      assert {:ok, [%{file: "Ext Triage.md", name: "Ext Triage"}]} =
               References.referencing_workflows(m.mount_key, "Offers/X.md")
    end

    test "rewrite updates the external mount's own workflow, another mount's workflows untouched",
         %{mount: m, a: a} do
      assert {:ok, ["Ext Triage.md"]} =
               References.rewrite(m.mount_key, "Offers/X.md", "Offers/Y.md")

      page = File.read!(Path.join(m.root, "Workflows/Ext Triage.md"))
      assert page =~ ~s(path: "Offers/Y.md")
      refute page =~ "Offers/X.md"

      # Mount a's own workflows (a distinct external mount, from the outer
      # setup) are untouched.
      a_page = File.read!(Path.join(workflows_dir(a), "New Inquiry Triage.md"))
      assert a_page =~ "Offers/Founder Coaching Package.md"
    end

    test "a bare external mount-root path (\"\") is invalid (empty needle)", %{mount: m} do
      assert {:error, :invalid_path} = References.referencing_workflows(m.mount_key, "")
      assert {:error, :invalid_path} = References.rewrite(m.mount_key, "", "Offers/X.md")
    end
  end
end
