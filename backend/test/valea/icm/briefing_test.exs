defmodule Valea.ICM.BriefingTest do
  use ExUnit.Case, async: true

  alias Valea.ICM.Briefing

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-briefing-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    icm = Path.join(dir, "icm")
    File.mkdir_p!(icm)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{icm: icm}
  end

  describe "path/1" do
    test "is `.valea/briefing.md` at the ICM root", %{icm: icm} do
      assert Briefing.path(icm) == Path.join([icm, ".valea", "briefing.md"])
    end
  end

  describe "materialize!/1" do
    test "writes the template to `.valea/briefing.md`, creating the dir", %{icm: icm} do
      assert :ok = Briefing.materialize!(icm)

      assert File.read!(Briefing.path(icm)) == File.read!(Briefing.template_path())
    end

    # The header is the whole reason a hand edit is safe to overwrite: it says
    # so, and it says the one thing an agent must not try (writing here).
    test "the briefing announces itself as regenerated and `.valea/` as read-only", %{icm: icm} do
      :ok = Briefing.materialize!(icm)
      content = File.read!(Briefing.path(icm))

      assert content =~ "Managed by Valea"
      assert content =~ "regenerated on activation"
      assert content =~ "edits will be overwritten"
      assert content =~ "Agents cannot write in `.valea/`"
    end

    test "teaches both file contracts and the load-bearing invariants", %{icm: icm} do
      :ok = Briefing.materialize!(icm)
      content = File.read!(Briefing.path(icm))

      assert content =~ "tasks.json"
      assert content =~ "schedules.json"
      # "set status, never delete" — Valea owns archival.
      assert content =~ "never delete"
      # Writing schedules.json is the consent moment.
      assert content =~ "consent moment"
      # Paused semantics, spelled the way the spec spells them.
      assert content =~ "slots missed while paused are skipped for good"
      # Strict execution fields, and the case that rule exists for.
      assert content =~ "fail closed"
      # The unattended-run convention.
      assert content =~ "record what's needed in `tasks.json` and end the session"
      # The worked example carries a real before/after for both files.
      assert content =~ "s-morning-brief"
    end

    test "is idempotent: a second call leaves the file's mtime untouched", %{icm: icm} do
      :ok = Briefing.materialize!(icm)

      path = Briefing.path(icm)
      old = 1_577_836_800
      File.touch!(path, old)

      :ok = Briefing.materialize!(icm)

      assert File.stat!(path, time: :posix).mtime == old
    end

    test "a hand-edited (or stale) briefing IS rewritten", %{icm: icm} do
      path = Briefing.path(icm)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "# an older app's briefing\n")

      :ok = Briefing.materialize!(icm)

      assert File.read!(path) == File.read!(Briefing.template_path())
    end

    # tmp + rename replaces the directory ENTRY, so a planted symlink is
    # swapped out rather than written through (`Valea.Mail.AgentsFile` posture).
    test "replaces a symlinked briefing instead of writing through it", %{icm: icm} do
      path = Briefing.path(icm)
      File.mkdir_p!(Path.dirname(path))
      target = Path.join(Path.dirname(path), "elsewhere.md")
      File.write!(target, "untouched")
      File.ln_s!("elsewhere.md", path)

      :ok = Briefing.materialize!(icm)

      assert File.read_link(path) == {:error, :einval}
      assert File.read!(path) =~ "Managed by Valea"
      assert File.read!(target) == "untouched"
    end

    # The scheduler's hook is what keeps a vanished ICM root from being
    # resurrected; here the honest behavior of the write itself is an error, not
    # a half-materialized tree.
    test "raises when `.valea` cannot be created", %{icm: icm} do
      File.write!(Path.join(icm, ".valea"), "not a directory")

      assert_raise File.Error, fn -> Briefing.materialize!(icm) end
    end
  end
end
