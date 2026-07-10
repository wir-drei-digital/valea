defmodule Valea.PathsTest do
  use ExUnit.Case, async: true

  alias Valea.Paths

  setup do
    base =
      Path.join(
        System.tmp_dir!(),
        "valea-paths-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    outside =
      Path.join(
        System.tmp_dir!(),
        "valea-outside-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(base, "icm"))
    File.mkdir_p!(outside)

    on_exit(fn ->
      File.rm_rf!(base)
      File.rm_rf!(outside)
    end)

    # resolve_real returns symlink-resolved absolutes, so compare against the
    # symlink-resolved base (macOS /var -> /private/var).
    {:ok, base_real} = Paths.resolve_real(base, base)
    {:ok, base: base, base_real: base_real, outside: outside}
  end

  test "resolves a relative path against base", %{base: base, base_real: base_real} do
    File.write!(Path.join([base, "icm", "note.md"]), "hi")
    assert {:ok, resolved} = Paths.resolve_real("icm/note.md", base)
    assert resolved == Path.join([base_real, "icm", "note.md"])
  end

  test "rejects a ../ escape", %{base: base} do
    assert {:error, :outside} = Paths.resolve_real("../elsewhere/secret", base)
  end

  test "resolves a symlink pointing inside base", %{base: base, base_real: base_real} do
    target = Path.join([base, "icm", "real.md"])
    File.write!(target, "x")
    link = Path.join(base, "inside_link")
    File.ln_s!(target, link)

    assert {:ok, resolved} = Paths.resolve_real("inside_link", base)
    assert resolved == Path.join([base_real, "icm", "real.md"])
  end

  test "rejects a symlink pointing OUTSIDE base", %{base: base, outside: outside} do
    target = Path.join(outside, "loot.txt")
    File.write!(target, "secret")
    link = Path.join(base, "escape_link")
    File.ln_s!(target, link)

    assert {:error, :outside} = Paths.resolve_real("escape_link", base)
  end

  test "rejects a symlinked DIRECTORY midway through the path", %{base: base, outside: outside} do
    File.mkdir_p!(Path.join(outside, "sub"))
    File.write!(Path.join([outside, "sub", "file.txt"]), "x")
    File.ln_s!(outside, Path.join(base, "dirlink"))

    assert {:error, :outside} = Paths.resolve_real("dirlink/sub/file.txt", base)
  end

  test "allows a non-existent target file inside an existing dir (write target)", %{
    base: base,
    base_real: base_real
  } do
    assert {:ok, resolved} = Paths.resolve_real("icm/does-not-exist-yet.md", base)
    assert resolved == Path.join([base_real, "icm", "does-not-exist-yet.md"])
  end

  test "rejects a non-existent remainder that traverses out with ..", %{base: base} do
    # Path.expand normalizes ".." lexically before resolution, so a traversal
    # through non-existent segments surfaces as :outside (still rejected). The
    # :invalid branch is a defence-in-depth guard for any residual "..".
    assert {:error, reason} = Paths.resolve_real("icm/nope/../../../etc/x", base)
    assert reason in [:outside, :invalid]
  end

  test "rejects an absolute path outside base", %{base: base} do
    assert {:error, :outside} = Paths.resolve_real("/etc/passwd", base)
  end
end
