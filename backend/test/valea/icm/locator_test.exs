defmodule Valea.Icm.LocatorTest do
  use ExUnit.Case, async: false
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
    assert %{"kind" => "workspace", "path" => "sources/mail/messages/42.md"} =
             Locator.for_path(ws, Path.join(ws, "sources/mail/messages/42.md"))
  end
end
