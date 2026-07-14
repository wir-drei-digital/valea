defmodule Valea.Icm.LocatorTest do
  use ExUnit.Case, async: false
  alias Valea.AgentCase
  alias Valea.Icm.Locator
  alias Valea.Workspace.Manager
  alias Valea.Mounts
  alias Valea.Paths

  # `Valea.Paths.resolve_real/2` fully symlink-resolves and is publicly
  # available; passing the same path as both `path` and `base` resolves it
  # against itself (trivially "contained"), giving the REALPATH form
  # `Mounts.list/1` itself produces (e.g. macOS's `/var` -> `/private/var`)
  # to assert against — same trick `mounts_test.exs`/`external_test.exs`'s
  # own `real!/1` uses for the identical reason. `Mounts.mount_for/2` also
  # documents that it "assumes the caller already resolved `path` to its
  # real, physical form" — so a `for_path` test needs this too.
  defp real!(path) do
    expanded = Path.expand(path)
    {:ok, resolved} = Paths.resolve_real(expanded, expanded)
    resolved
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "valea-loc-#{System.unique_integer([:positive])}")
    System.put_env("VALEA_APP_DIR", dir)
    Manager.close()
    {:ok, ws} = Manager.create("W")
    id = "6f9f0c9e-3ccd-4fa5-a219-113a70618b55"
    root = Path.join(dir, "coaching")
    File.mkdir_p!(Path.join(root, "Pricing"))
    File.write!(Path.join(root, "icm.yaml"), "format: 2\nid: #{id}\nname: \"Coaching\"\n")
    File.write!(Path.join(root, "Pricing/Current Pricing.md"), "# p\n")
    {:ok, _} = Mounts.mount(ws.path, root)

    on_exit(fn ->
      Manager.close()
      File.rm_rf!(dir)
      System.delete_env("VALEA_APP_DIR")
    end)

    %{ws: ws.path, id: id, root: root}
  end

  test "resolves an icm locator to the current physical path", %{ws: ws, id: id, root: root} do
    loc = Locator.icm(id, "Pricing/Current Pricing.md")
    assert {:ok, abs} = Locator.resolve(ws, loc)
    assert abs == Path.join(real!(root), "Pricing/Current Pricing.md")
  end

  test "icm locator for an unmounted id errors", %{ws: ws} do
    assert {:error, :icm_not_mounted} =
             Locator.resolve(ws, Locator.icm("00000000-0000-0000-0000-000000000000", "x.md"))
  end

  test "for_path attributes an in-ICM path to an icm locator", %{ws: ws, id: id, root: root} do
    assert %{"kind" => "icm", "icm_id" => ^id, "path" => "Pricing/Current Pricing.md"} =
             Locator.for_path(ws, Path.join(real!(root), "Pricing/Current Pricing.md"))
  end

  test "for_path attributes a workspace path to a workspace locator", %{ws: ws} do
    # `physical_abs` is built from the RESOLVED workspace root (`real!/1`),
    # matching the moduledoc's contract that it is already a known-good,
    # physical path — not the raw, possibly-unresolved `ws` string itself.
    assert %{"kind" => "workspace", "path" => "sources/mail/messages/42.md"} =
             Locator.for_path(ws, Path.join(real!(ws), "sources/mail/messages/42.md"))
  end

  # Regression for the bug fixed alongside this test: `for_path/2`'s
  # workspace branch used to feed `workspace` straight into
  # `Path.relative_to/2` without symlink-resolving it first. That's fine
  # when `physical_abs` was built lexically from the same unresolved
  # `workspace` string (the test above), but `Path.relative_to/2` is purely
  # lexical — when `workspace` is an unresolved ancestor (e.g. a symlink)
  # and `physical_abs` is already symlink-resolved, there is no common
  # lexical prefix and it silently returns `physical_abs` UNCHANGED
  # (absolute), violating the workspace-locator contract. This test builds
  # an explicit symlinked ancestor so the divergence is guaranteed
  # regardless of platform (not relying on an incidental macOS
  # `/var` -> `/private/var` ambient symlink the way `real!/1` normally
  # does).
  test "for_path resolves a symlinked workspace root so the path stays workspace-relative" do
    base_dir =
      Path.join(System.tmp_dir!(), "valea-loc-symlink-#{System.unique_integer([:positive])}")

    real_dir = Path.join(base_dir, "real")
    link_dir = Path.join(base_dir, "link")
    File.mkdir_p!(Path.join(real_dir, "sub"))
    File.ln_s!(real_dir, link_dir)
    on_exit(fn -> File.rm_rf!(base_dir) end)

    physical_abs = Path.join(real!(real_dir), "sub/file.md")

    assert %{"kind" => "workspace", "path" => path} = Locator.for_path(link_dir, physical_abs)
    refute String.starts_with?(path, "/")
    refute String.contains?(path, "/private")
    assert path == "sub/file.md"
  end

  test "resolve rejects a workspace locator that tries to escape via ..", %{ws: ws} do
    assert {:error, :outside} = Locator.resolve(ws, Locator.workspace("../../etc/passwd"))
  end

  test "resolve rejects an icm locator that tries to escape via ..", %{ws: ws, id: id} do
    assert {:error, :outside} = Locator.resolve(ws, Locator.icm(id, "../../etc/passwd"))
  end

  test "resolve errors :icm_disabled for a disabled mount", %{ws: ws} do
    %{id: id, mount_key: mount_key} = AgentCase.mount_test_icm!(ws, name: "Disabled")
    :ok = Mounts.set_enabled(ws, mount_key, false)

    assert {:error, :icm_disabled} = Locator.resolve(ws, Locator.icm(id, "x.md"))
  end

  test "resolve errors :invalid for a locator with an unrecognized kind", %{ws: ws} do
    assert {:error, :invalid} = Locator.resolve(ws, %{"kind" => "nonsense"})
  end
end
