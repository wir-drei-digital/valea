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

  # --- realpath regression: symlinks resolve BEFORE the following ".." ---
  # A lexical pre-collapse of ".." would vet a DIFFERENT physical file than
  # the OS opens. These assert the OS-faithful (physical) resolution.

  test "symlink then .. stays inside secrets/ (not lexically icm/)", %{
    base: base,
    base_real: base_real
  } do
    # icm/L -> <ws>/secrets/ssl ; "icm/L/../master.key"
    # Lexical: <ws>/icm/master.key (WRONG). Physical: <ws>/secrets/master.key.
    File.mkdir_p!(Path.join(base, "secrets"))
    File.ln_s!(Path.join([base, "secrets", "ssl"]), Path.join([base, "icm", "L"]))

    assert {:ok, resolved} = Paths.resolve_real("icm/L/../master.key", base)
    assert resolved == Path.join([base_real, "secrets", "master.key"])
    refute resolved == Path.join([base_real, "icm", "master.key"])
  end

  test "symlink to host dir then .. escapes to a host file -> outside", %{base: base} do
    # icm/L -> /etc/ssl ; "icm/L/../passwd" -> OS realpath /etc/passwd.
    File.ln_s!("/etc/ssl", Path.join([base, "icm", "L"]))

    assert {:error, :outside} = Paths.resolve_real("icm/L/../passwd", base)
  end

  test "write remainder through a symlink to /tmp then .. lands outside base", %{base: base} do
    # queue/staging/r1/L -> /tmp ; "queue/staging/r1/L/../proposal.json".
    # Lexically equals the declared write target, physically it is in /tmp's
    # parent — must NOT resolve back inside base.
    File.mkdir_p!(Path.join([base, "queue", "staging", "r1"]))
    File.ln_s!("/tmp", Path.join([base, "queue", "staging", "r1", "L"]))

    assert {:error, :outside} =
             Paths.resolve_real("queue/staging/r1/L/../proposal.json", base)
  end

  describe "relative/2 (C4)" do
    test "same-mount sibling folder needs one level up" do
      assert Paths.relative("mounts/primary/Offers", "mounts/primary/Pricing/Rates.md") ==
               "../Pricing/Rates.md"
    end

    test "target in the same folder as the source needs no prefix" do
      assert Paths.relative("mounts/primary/Offers", "mounts/primary/Offers/Rates.md") ==
               "Rates.md"
    end

    test "target nested deeper under the source's own folder" do
      assert Paths.relative("mounts/primary", "mounts/primary/Pricing/Rates.md") ==
               "Pricing/Rates.md"
    end

    test "cross-mount (embedded <-> embedded) needs multiple levels up" do
      assert Paths.relative("mounts/second", "mounts/primary/Pricing/Rates.md") ==
               "../primary/Pricing/Rates.md"
    end

    test "several levels of nesting on both sides" do
      assert Paths.relative(
               "mounts/primary/Clients/Active",
               "mounts/primary/Offers/Deals/Rates.md"
             ) == "../../Offers/Deals/Rates.md"
    end

    test "both sides absolute (external mount vocabulary)" do
      assert Paths.relative("/Users/x/Notes/Offers", "/Users/x/Notes/Pricing/Rates.md") ==
               "../Pricing/Rates.md"
    end

    test "identical directories produce the bare basename" do
      assert Paths.relative("mounts/primary", "mounts/primary/Rates.md") == "Rates.md"
    end
  end

  # --- Windows-support Task 3 (spec D1-D3, D5) ---
  # These exercise the PURE platform API (classify/normalize/ancestor?/
  # resolve_lexical) with constructed Windows-shaped inputs, so they run on
  # every host — the classifier no longer delegates to host-dependent OTP
  # (spec §D testing split). resolve_real's filesystem walk on Windows is
  # covered by the native CI lane, not here.

  describe "classify/2 windows shapes (pure — runs on every host)" do
    test "drive and UNC absolutes" do
      assert Valea.Paths.classify("C:/Users/mara", :windows) == :absolute
      assert Valea.Paths.classify("C:\\Users\\mara", :windows) == :absolute
      assert Valea.Paths.classify("//srv/share/icm", :windows) == :absolute
      assert Valea.Paths.classify("\\\\srv\\share", :windows) == :absolute
    end

    test "rejected forms" do
      assert Valea.Paths.classify("C:foo", :windows) == :drive_relative
      assert Valea.Paths.classify("C:", :windows) == :drive_relative
      assert Valea.Paths.classify("\\\\.\\COM1", :windows) == :invalid
      assert Valea.Paths.classify("//srv", :windows) == :invalid
      assert Valea.Paths.classify("/rootless", :windows) == :invalid
    end

    test "unix unchanged" do
      assert Valea.Paths.classify("/a/b", :unix) == :absolute
      assert Valea.Paths.classify("C:/x", :unix) == :relative
    end
  end

  describe "normalize/2" do
    test "extended-length wrappers strip to plain forms" do
      assert Valea.Paths.normalize("\\\\?\\C:\\a\\b", :windows) == "C:/a/b"
      assert Valea.Paths.normalize("\\\\?\\UNC\\srv\\share\\x", :windows) == "//srv/share/x"
      assert Valea.Paths.normalize("c:\\a", :windows) == "C:/a"
    end
  end

  describe "ancestor?/3" do
    test "case-folded on windows, exact on unix" do
      assert Valea.Paths.ancestor?("C:/Work/ICM", "c:/work/icm/notes.md", :windows)
      refute Valea.Paths.ancestor?("/work/icm", "/work/ICM/notes.md", :unix)
      assert Valea.Paths.ancestor?("//SRV/Share/icm", "//srv/share/icm/a", :windows)
    end

    test "no prefix-collision false positives" do
      refute Valea.Paths.ancestor?("C:/work/icm", "C:/work/icm-private/x", :windows)
    end
  end

  describe "root-floor (pure helpers)" do
    test "`..` cannot pop above a UNC share or drive root" do
      assert Valea.Paths.resolve_lexical("../..", "//srv/share/icm", :windows) == "//srv/share"

      assert Valea.Paths.resolve_lexical("../../../../..", "//srv/share/icm", :windows) ==
               "//srv/share"

      assert Valea.Paths.resolve_lexical("../../../..", "C:/a/b", :windows) == "C:/"
    end
  end

  describe "resolve_lexical/3 base contract" do
    # The pure seam's `base` is a ROOT-anchored path by contract; callers
    # (Task 4/6/7 sites) always have one. A non-absolute base has no root to
    # floor `..` against, so it is a caller BUG — fail loud with a clear
    # error, never guess a root and never silently parse an ambiguous form.
    test "drive-relative base is rejected, not parsed" do
      assert_raise ArgumentError, fn ->
        Valea.Paths.resolve_lexical("..", "C:foo", :windows)
      end
    end

    test "device base is rejected, not mistaken for a UNC root" do
      # "//./dev" splits host="." share="dev" and would otherwise parse as a
      # UNC root; the classifier rejects device paths, so this must raise.
      assert_raise ArgumentError, fn ->
        Valea.Paths.resolve_lexical("..", "//./dev", :windows)
      end
    end

    test "bare-host and relative bases are rejected" do
      assert_raise ArgumentError, fn ->
        Valea.Paths.resolve_lexical("..", "//srv", :windows)
      end

      assert_raise ArgumentError, fn ->
        Valea.Paths.resolve_lexical("..", "relative/base", :windows)
      end

      assert_raise ArgumentError, fn ->
        Valea.Paths.resolve_lexical("..", "relative/base", :unix)
      end
    end
  end

  describe "8.3 short names (spec D5)" do
    test "8.3-style short-name aliases stay fail-closed (never resolved to long names)" do
      # DOCUME~1 is just a literal component to the walk; if the base is the
      # long-name form, containment must DENY, not alias. Pin it.
      refute Valea.Paths.ancestor?(
               "C:/Users/mara/Documents",
               "C:/Users/mara/DOCUME~1/x",
               :windows
             )
    end
  end
end
