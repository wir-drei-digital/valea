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

    * a symlink inside a mounted ICM pointing outside that mount's own
      root is rejected by page/save/rename/delete, and the target is
      never touched — same for a SECOND, independently mounted ICM (every
      mount is external/by-reference now, so there is only one mechanism
      to prove, exercised twice against two different mount roots);
    * a symlinked directory used as a create/create_folder PARENT (a
      not-yet-existing target) is rejected the same way — the escape is
      caught via the parent, before any file is minted outside;
    * a symlink pointing WITHIN the same mount is unaffected — legitimate
      internal links (and ordinary, non-symlink ops) keep working exactly
      as before.
  """

  use ExUnit.Case, async: false

  alias Valea.AgentCase
  alias Valea.ICM
  alias Valea.Markdown.ProseMirror

  # -- fixtures ------------------------------------------------------------

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

  defp zero_hash, do: String.duplicate("0", 64)

  # Post-3.2, `Valea.Mounts.list/1` is config truth over `icms:` only, so a
  # fresh workspace seeds no mount at all — `AgentCase.mount_test_icm!/2`
  # mounts a REAL EXTERNAL ICM ("primary") this whole suite plants its
  # symlinks inside, addressed by `icm.root` (never a
  # `mounts/primary/...` workspace-relative literal).
  setup do
    ws = AgentCase.open_workspace!("Primary")
    icm = AgentCase.mount_test_icm!(ws.path, name: "Primary")
    %{ws: ws.path, icm: icm}
  end

  # -- a mounted ICM: symlink escaping its own root -------------------------

  describe "a mounted ICM with a symlink pointing outside its own root" do
    setup %{icm: icm} do
      outside = tmp_dir!("valea-symlink-outside")
      secret_path = Path.join(outside, "secret.md")
      File.write!(secret_path, "TOP SECRET\n")

      link_abs = Path.join(icm.root, "EscapeLink.md")
      File.ln_s!(secret_path, link_abs)

      %{outside: outside, secret_path: secret_path, link_abs: link_abs}
    end

    test "page/save_page/rename/delete all reject it as :outside_workspace, target and link untouched",
         %{icm: icm, secret_path: secret_path, link_abs: link_abs} do
      assert {:error, :outside_workspace} = ICM.page(link_abs)

      {:ok, pm} = ProseMirror.from_markdown("# hijacked\n")
      assert {:error, :outside_workspace} = ICM.save_page(link_abs, pm, zero_hash())

      assert {:error, :outside_workspace} = ICM.rename(link_abs, "Renamed")
      assert {:error, :outside_workspace} = ICM.delete(link_abs)

      # Neither the symlink target nor the symlink itself was touched.
      assert File.read!(secret_path) == "TOP SECRET\n"
      assert File.exists?(link_abs)
      refute File.exists?(Path.join(icm.root, "Renamed.md"))
    end
  end

  # -- a second, independently mounted external ICM: symlink escaping it ---

  describe "a second, independently mounted external ICM with a symlink escaping it" do
    setup %{ws: ws} do
      ext = AgentCase.mount_test_icm!(ws, name: "Ext")

      outside = tmp_dir!("valea-symlink-ext-outside")
      secret_path = Path.join(outside, "secret.md")
      File.write!(secret_path, "EXTERNAL SECRET\n")

      link_abs = Path.join(ext.root, "EscapeLink.md")
      File.ln_s!(secret_path, link_abs)

      %{outside: outside, secret_path: secret_path, link_abs: link_abs}
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
    setup %{icm: icm} do
      outside = tmp_dir!("valea-symlink-createdir-outside")
      dirlink_abs = Path.join(icm.root, "EscapeDir")
      File.ln_s!(outside, dirlink_abs)

      %{outside: outside, dirlink_abs: dirlink_abs}
    end

    test "create_page/create_folder into it are rejected, nothing is minted outside", %{
      outside: outside,
      dirlink_abs: dirlink_abs
    } do
      assert {:error, :outside_workspace} = ICM.create_page(dirlink_abs, "Intruder")
      assert {:error, :outside_workspace} = ICM.create_folder(dirlink_abs, "IntruderFolder")

      refute File.exists?(Path.join(outside, "Intruder.md"))
      refute File.exists?(Path.join(outside, "IntruderFolder"))
    end
  end

  # -- symlink pointing WITHIN the same mount: still works ------------------

  describe "a symlink pointing within the same mount" do
    setup %{icm: icm} do
      real_path = Path.join(icm.root, "Realm.md")
      File.write!(real_path, "# Real\n")

      link_path = Path.join(icm.root, "InternalLink.md")
      File.ln_s!(real_path, link_path)

      %{real_path: real_path, link_path: link_path}
    end

    test "page reads through it fine", %{link_path: link_path} do
      assert {:ok, page} = ICM.page(link_path)
      assert page.content == "# Real\n"
    end

    test "rename operates on the link entry itself, target stays intact", %{
      icm: icm,
      real_path: real_path,
      link_path: link_path
    } do
      assert {:ok, %{path: renamed_path}} = ICM.rename(link_path, "RenamedLink")
      assert renamed_path == Path.join(icm.root, "RenamedLink.md")
      refute File.exists?(link_path)
      assert File.read!(real_path) == "# Real\n"
    end
  end

  # -- sanity: ordinary, non-symlink ops are unaffected by the hardening ---

  test "ordinary create/rename/delete/page/save_page still work with no symlinks involved", %{
    icm: icm
  } do
    assert {:ok, %{path: plain_path}} = ICM.create_page(icm.root, "Plain")
    assert plain_path == Path.join(icm.root, "Plain.md")
    assert {:ok, page} = ICM.page(plain_path)

    {:ok, pm} = ProseMirror.from_markdown("# Plain\n\nEdited.\n")
    assert {:ok, %{hash: new_hash}} = ICM.save_page(page.path, pm, page.hash)
    refute new_hash == page.hash

    assert {:ok, %{path: renamed_path}} = ICM.rename(plain_path, "Renamed")
    assert renamed_path == Path.join(icm.root, "Renamed.md")

    assert {:ok, %{deleted: true}} = ICM.delete(renamed_path)
    refute File.exists?(renamed_path)
  end
end
