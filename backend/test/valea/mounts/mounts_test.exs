defmodule Valea.MountsTest do
  use ExUnit.Case, async: false
  alias Valea.Mounts
  alias Valea.Workspace.Manager

  setup do
    dir = Path.join(System.tmp_dir!(), "valea-mnt-#{System.unique_integer([:positive])}")
    System.put_env("VALEA_APP_DIR", dir)
    Manager.close()
    {:ok, ws} = Manager.create("W")

    on_exit(fn ->
      Manager.close()
      File.rm_rf!(dir)
    end)

    %{ws: ws.path, home: dir}
  end

  # Build a real external ICM folder with a format-2 manifest.
  defp icm!(base, name, id) do
    root = Path.join(base, name)
    File.mkdir_p!(root)
    File.write!(Path.join(root, "icm.yaml"), "format: 2\nid: #{id}\nname: \"#{name}\"\n")
    root
  end

  defp write_icms(ws, yaml_block) do
    path = Path.join(ws, "config/workspace.yaml")
    base = File.read!(path) |> String.split("icms:") |> hd()
    File.write!(path, base <> "icms:\n" <> yaml_block)
  end

  # `Valea.Paths.resolve_real/2` fully symlink-resolves and is publicly
  # available; passing the same path as both `path` and `base` resolves it
  # against itself (trivially "contained"), giving the REALPATH form
  # `Mounts.list/1` itself produces (e.g. macOS's `/var` -> `/private/var`)
  # to assert against — same trick `mounts/external_test.exs`'s own
  # `real!/1` uses for the identical reason.
  defp real!(path) do
    expanded = Path.expand(path)
    {:ok, resolved} = Valea.Paths.resolve_real(expanded, expanded)
    resolved
  end

  test "an icms: entry becomes a healthy external mount", %{ws: ws, home: home} do
    root = icm!(home, "Coaching", "6f9f0c9e-3ccd-4fa5-a219-113a70618b55")
    write_icms(ws, "  coaching:\n    path: #{root}\n    enabled: true\n")
    real_root = real!(root)

    assert [
             %{name: "coaching", root: ^real_root, degraded: nil, enabled: true} = m
           ] = Mounts.list(ws)

    assert m.manifest.id == "6f9f0c9e-3ccd-4fa5-a219-113a70618b55"
    assert Mounts.mount_by_key(ws, "coaching").root == real_root
    assert Mounts.mount_by_id(ws, "6f9f0c9e-3ccd-4fa5-a219-113a70618b55").name == "coaching"
  end

  test "two entries sharing an ICM id are both degraded", %{ws: ws, home: home} do
    a = icm!(home, "A", "31201697-cff8-4d99-9dc5-b140e4178716")
    b = icm!(home, "B", "31201697-cff8-4d99-9dc5-b140e4178716")
    write_icms(ws, "  a:\n    path: #{a}\n  b:\n    path: #{b}\n")
    assert Enum.all?(Mounts.list(ws), &(&1.degraded != nil))
  end

  test "a path inside the workspace is degraded, not mounted", %{ws: ws} do
    write_icms(ws, "  bad:\n    path: #{Path.join(ws, "sources")}\n")
    assert [%{name: "bad", degraded: reason}] = Mounts.list(ws)
    assert reason =~ "inside" or reason =~ "boundary"
  end

  test "two entries resolving to the same physical root are both degraded", %{ws: ws, home: home} do
    a = icm!(home, "A", "31201697-cff8-4d99-9dc5-b140e4178716")
    write_icms(ws, "  a:\n    path: #{a}\n  same:\n    path: #{a}\n")
    assert Enum.all?(Mounts.list(ws), &(&1.degraded != nil))
  end

  test "list/1 is sorted by mount key, and enabled/1 excludes disabled + degraded", %{
    ws: ws,
    home: home
  } do
    z = icm!(home, "Z", "0f1e2d3c-4b5a-4978-8a6b-7c8d9e0f1a2b")
    a = icm!(home, "AA", "1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d")
    missing = Path.join(home, "does-not-exist")

    write_icms(
      ws,
      "  zeta:\n    path: #{z}\n  alpha:\n    path: #{a}\n    enabled: false\n  gone:\n    path: #{missing}\n"
    )

    assert Enum.map(Mounts.list(ws), & &1.name) == ["alpha", "gone", "zeta"]
    assert Enum.map(Mounts.enabled(ws), & &1.name) == ["zeta"]
  end

  test "mount_for/2 attributes an absolute path to the enabled, non-degraded mount that owns it",
       %{
         ws: ws,
         home: home
       } do
    root = icm!(home, "Coaching", "6f9f0c9e-3ccd-4fa5-a219-113a70618b55")
    write_icms(ws, "  coaching:\n    path: #{root}\n")

    page = Path.join(real!(root), "Offers/X.md")
    assert %{name: "coaching"} = Mounts.mount_for(ws, page)
    assert Mounts.mount_for(ws, "/definitely/not/a/mount/path") == nil
  end

  test "mount_by_key/2 and mount_by_id/2 return nil for an unknown key/id", %{ws: ws} do
    assert Mounts.mount_by_key(ws, "nope") == nil
    assert Mounts.mount_by_id(ws, "00000000-0000-0000-0000-000000000000") == nil
  end
end
