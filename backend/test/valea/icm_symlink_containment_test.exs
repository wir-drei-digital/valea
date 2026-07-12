defmodule Valea.ICMSymlinkContainmentTest do
  @moduledoc """
  Final-review finding #2: `Valea.ICM`'s editor containment chokepoint
  (`contain/2`) used to be purely lexical (`Path.expand/2` + a string
  prefix check) — a symlink planted INSIDE a mount, pointing anywhere on
  disk, lexically resolves to a path under the mount root and sailed
  through unchallenged, silently granting editor authority (read, write,
  rename, delete) over whatever the symlink's target actually was, even
  when that target sits outside the workspace entirely. `rename`/`delete`
  going through such a link is destructive (`File.rm_rf!` on the resolved
  target).

  `contain/2` now ALSO resolves the physical path (`Valea.Paths.resolve_real/2`,
  the same primitive the agent policy boundary already uses) and requires
  it to stay inside the mount root's own resolved form. This suite proves,
  with REAL symlinks on disk (no mocking):

    * a symlink inside an EMBEDDED mount pointing outside the workspace is
      rejected by page/save/rename/delete, and the target is never touched;
    * same for a symlink inside an EXTERNAL (by-reference) mount escaping
      that mount's own root;
    * a symlinked directory used as a create/create_folder PARENT (a
      not-yet-existing target) is rejected the same way — the escape is
      caught via the parent, before any file is minted outside;
    * a symlink pointing WITHIN the same mount is unaffected — legitimate
      internal links (and ordinary, non-symlink ops) keep working exactly
      as before.
  """

  use ExUnit.Case, async: false

  alias Valea.Mounts
  alias Valea.Mounts.Manifest
  alias Valea.Workspace.Manager
  alias Valea.ICM
  alias Valea.Markdown.ProseMirror

  # -- fixtures, mirroring Valea.ICMTest's own (kept local — small and
  # self-contained, same rationale as every other per-file copy of these
  # helpers in this test suite) ------------------------------------------

  defp tmp_dir!(prefix) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "#{prefix}-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp external_icm!(name) do
    dir = tmp_dir!("valea-symlink-ext")
    Manifest.write!(dir, %{id: "ext-id", name: name, description: ""})
    dir
  end

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
              "    #{k}: #{render_scalar(v)}"
            end)
        ]
      end)

    File.write!(config_path, Enum.join(header ++ ["mounts:"] ++ entries, "\n") <> "\n")
  end

  defp render_scalar(v) when is_binary(v), do: inspect(v)
  defp render_scalar(v), do: to_string(v)

  defp zero_hash, do: String.duplicate("0", 64)

  setup do
    dir = tmp_dir!("valea-app-symlink")

    System.put_env("VALEA_APP_DIR", dir)
    Manager.close()
    {:ok, ws} = Manager.create(Path.join(dir, "workspaces"), "Primary")

    on_exit(fn ->
      Manager.close()
      System.delete_env("VALEA_APP_DIR")
    end)

    %{ws: ws.path}
  end

  # -- embedded mount: symlink escaping the workspace ----------------------

  describe "an embedded mount with a symlink pointing outside the workspace" do
    setup %{ws: ws} do
      outside = tmp_dir!("valea-symlink-outside")
      secret_path = Path.join(outside, "secret.md")
      File.write!(secret_path, "TOP SECRET\n")

      link_rel = "mounts/primary/EscapeLink.md"
      link_abs = Path.join(ws, link_rel)
      File.ln_s!(secret_path, link_abs)

      %{outside: outside, secret_path: secret_path, link_rel: link_rel, link_abs: link_abs}
    end

    test "page/save_page/rename/delete all reject it as :outside_workspace, target and link untouched",
         %{ws: ws, secret_path: secret_path, link_rel: link_rel, link_abs: link_abs} do
      assert {:error, :outside_workspace} = ICM.page(link_rel)

      {:ok, pm} = ProseMirror.from_markdown("# hijacked\n")
      assert {:error, :outside_workspace} = ICM.save_page(link_rel, pm, zero_hash())

      assert {:error, :outside_workspace} = ICM.rename(link_rel, "Renamed")
      assert {:error, :outside_workspace} = ICM.delete(link_rel)

      # Neither the symlink target nor the symlink itself was touched.
      assert File.read!(secret_path) == "TOP SECRET\n"
      assert File.exists?(link_abs)
      refute File.exists?(Path.join(ws, "mounts/primary/Renamed.md"))
    end
  end

  # -- external mount: symlink escaping that mount's own root --------------

  describe "an external (by-reference) mount with a symlink escaping it" do
    setup %{ws: ws} do
      ext = external_icm!("Ext")
      declare_external!(ws, "ext", ext)
      [m] = Enum.filter(Mounts.enabled(ws), &(&1.name == "ext"))

      outside = tmp_dir!("valea-symlink-ext-outside")
      secret_path = Path.join(outside, "secret.md")
      File.write!(secret_path, "EXTERNAL SECRET\n")

      link_abs = Path.join(m.root, "EscapeLink.md")
      File.ln_s!(secret_path, link_abs)

      %{mount_root: m.root, outside: outside, secret_path: secret_path, link_abs: link_abs}
    end

    test "page/save_page/rename/delete all reject it as :outside_workspace, target and link untouched",
         %{secret_path: secret_path, link_abs: link_abs} do
      assert {:error, :outside_workspace} = ICM.page(link_abs)

      {:ok, pm} = ProseMirror.from_markdown("# hijacked\n")
      assert {:error, :outside_workspace} = ICM.save_page(link_abs, pm, zero_hash())

      assert {:error, :outside_workspace} = ICM.rename(link_abs, "Renamed")
      assert {:error, :outside_workspace} = ICM.delete(link_abs)

      assert File.read!(secret_path) == "EXTERNAL SECRET\n"
      assert File.exists?(link_abs)
    end
  end

  # -- symlinked PARENT directory (not-yet-existing create/create_folder
  # target) escaping the mount ----------------------------------------------

  describe "a symlinked directory used as a create/create_folder parent" do
    setup %{ws: ws} do
      outside = tmp_dir!("valea-symlink-createdir-outside")
      dirlink_rel = "mounts/primary/EscapeDir"
      dirlink_abs = Path.join(ws, dirlink_rel)
      File.ln_s!(outside, dirlink_abs)

      %{outside: outside, dirlink_rel: dirlink_rel}
    end

    test "create_page/create_folder into it are rejected, nothing is minted outside", %{
      outside: outside,
      dirlink_rel: dirlink_rel
    } do
      assert {:error, :outside_workspace} = ICM.create_page(dirlink_rel, "Intruder")
      assert {:error, :outside_workspace} = ICM.create_folder(dirlink_rel, "IntruderFolder")

      refute File.exists?(Path.join(outside, "Intruder.md"))
      refute File.exists?(Path.join(outside, "IntruderFolder"))
    end
  end

  # -- symlink pointing WITHIN the same mount: still works ------------------

  describe "a symlink pointing within the same (embedded) mount" do
    setup %{ws: ws} do
      real_rel = "mounts/primary/Realm.md"
      File.write!(Path.join(ws, real_rel), "# Real\n")

      link_rel = "mounts/primary/InternalLink.md"
      File.ln_s!(Path.join(ws, real_rel), Path.join(ws, link_rel))

      %{real_rel: real_rel, link_rel: link_rel}
    end

    test "page reads through it fine", %{link_rel: link_rel} do
      assert {:ok, page} = ICM.page(link_rel)
      assert page.content == "# Real\n"
    end

    test "rename operates on the link entry itself, target stays intact", %{
      ws: ws,
      real_rel: real_rel,
      link_rel: link_rel
    } do
      assert {:ok, %{path: "mounts/primary/RenamedLink.md"}} = ICM.rename(link_rel, "RenamedLink")
      refute File.exists?(Path.join(ws, link_rel))
      assert File.read!(Path.join(ws, real_rel)) == "# Real\n"
    end
  end

  # -- sanity: ordinary, non-symlink ops are unaffected by the hardening ---

  test "ordinary create/rename/delete/page/save_page still work with no symlinks involved", %{
    ws: ws
  } do
    assert {:ok, %{path: "mounts/primary/Plain.md"}} = ICM.create_page("mounts/primary", "Plain")
    assert {:ok, page} = ICM.page("mounts/primary/Plain.md")

    {:ok, pm} = ProseMirror.from_markdown("# Plain\n\nEdited.\n")
    assert {:ok, %{hash: new_hash}} = ICM.save_page(page.path, pm, page.hash)
    refute new_hash == page.hash

    assert {:ok, %{path: "mounts/primary/Renamed.md"}} =
             ICM.rename("mounts/primary/Plain.md", "Renamed")

    assert {:ok, %{deleted: true}} = ICM.delete("mounts/primary/Renamed.md")
    refute File.exists?(Path.join(ws, "mounts/primary/Renamed.md"))
  end
end
