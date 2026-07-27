defmodule Valea.Agents.EnvTest do
  use ExUnit.Case, async: true

  alias Valea.Agents.Env

  test "minimal env contains only the allowlist and never secrets" do
    previous = System.get_env("SECRET_KEY_BASE")

    on_exit(fn ->
      case previous do
        nil -> System.delete_env("SECRET_KEY_BASE")
        value -> System.put_env("SECRET_KEY_BASE", value)
      end
    end)

    System.put_env("SECRET_KEY_BASE", "supersecret")
    env = Env.minimal()
    refute Map.has_key?(env, "SECRET_KEY_BASE")
    assert env["PATH"] == System.get_env("PATH")

    # The home-directory key is one of the things that differs by platform
    # (spec B4), so which one to assert is a platform question too.
    case Valea.Paths.host_platform() do
      :windows -> assert env["USERPROFILE"] == System.get_env("USERPROFILE")
      :unix -> assert env["HOME"] == System.get_env("HOME")
    end

    assert Enum.all?(Map.keys(env), &(&1 in Env.allowlist()))
  end

  test "windows allowlist carries profile/appdata/pathext, unix stays unchanged" do
    assert "SystemRoot" in Env.allowlist(:windows)
    assert "USERPROFILE" in Env.allowlist(:windows)
    assert "APPDATA" in Env.allowlist(:windows)
    assert "PATHEXT" in Env.allowlist(:windows)
    refute "SystemRoot" in Env.allowlist(:unix)

    # Unix's list is the one that shipped — no drive-by edits with this change.
    assert Env.allowlist(:unix) ==
             ~w(HOME PATH USER LOGNAME LANG LC_ALL LC_CTYPE TMPDIR SHELL ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN)
  end

  test "neither platform's allowlist can carry a Valea control-plane secret" do
    for platform <- [:unix, :windows] do
      allowlist = Env.allowlist(platform)
      refute "SECRET_KEY_BASE" in allowlist
      refute Enum.any?(allowlist, &String.starts_with?(&1, "VALEA"))
      # PATH is the only thing both lists share besides the auth tokens.
      assert "PATH" in allowlist
    end
  end

  test "allowlist/0 follows the host" do
    assert Env.allowlist() == Env.allowlist(Valea.Paths.host_platform())
  end
end
