defmodule Valea.Agents.Env do
  @moduledoc """
  The minimal environment handed to an agent adapter subprocess. Never the
  backend's own env (which may carry SECRET_KEY_BASE and friends) — only
  this fixed allowlist, and only the keys that are actually set.
  """

  @allowlist ~w(HOME PATH USER LOGNAME LANG LC_ALL LC_CTYPE TMPDIR SHELL ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN)

  @spec allowlist() :: [String.t()]
  def allowlist, do: @allowlist

  @spec minimal() :: %{String.t() => String.t()}
  def minimal do
    for key <- @allowlist, value = System.get_env(key), value != nil, into: %{} do
      {key, value}
    end
  end
end
