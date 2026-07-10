defmodule Valea.Agents.EnvTest do
  use ExUnit.Case, async: true

  test "minimal env contains only the allowlist and never secrets" do
    System.put_env("SECRET_KEY_BASE", "supersecret")
    env = Valea.Agents.Env.minimal()
    refute Map.has_key?(env, "SECRET_KEY_BASE")
    assert env["HOME"] == System.get_env("HOME")
    assert env["PATH"] == System.get_env("PATH")
    assert Enum.all?(Map.keys(env), &(&1 in Valea.Agents.Env.allowlist()))
  end
end
