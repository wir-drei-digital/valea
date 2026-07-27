defmodule Valea.Agents.Env do
  @moduledoc """
  What Valea CONTRIBUTES to an agent adapter subprocess's environment: this
  fixed allowlist, and only the keys that are actually set.

  Contributes, not defines — both spawn mechanisms (erlexec's `{:env, …}` on
  unix, a Port's `{:env, …}` on windows) MERGE their list into the environment
  the backend itself inherited. So this is not a sandbox around the child; it
  is a rule about what Valea itself hands over. That is still the thing worth
  controlling: a key like SECRET_KEY_BASE must never be ADDED by us, and
  nothing here can add it. A caller that needs a genuinely sealed environment
  needs a different mechanism than an allowlist.

  One list per platform (windows-support spec B4). Same posture on both:
  fixed, never inherit-all, no Valea control-plane keys. The lists differ
  because the two systems name the same things differently (`HOME` vs
  `USERPROFILE`, `TMPDIR` vs `TEMP`/`TMP`) and because Windows programs —
  node included — fail in confusing ways without `SystemRoot`, `COMSPEC` or
  `PATHEXT`. The two auth tokens are on both lists; nothing else is.
  """

  @unix_allowlist ~w(HOME PATH USER LOGNAME LANG LC_ALL LC_CTYPE TMPDIR SHELL ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN)
  @windows_allowlist ~w(PATH USERPROFILE APPDATA LOCALAPPDATA PATHEXT COMSPEC SystemRoot SystemDrive TEMP TMP ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN)

  @spec allowlist(Valea.Paths.platform()) :: [String.t()]
  def allowlist(platform \\ Valea.Paths.host_platform())
  def allowlist(:windows), do: @windows_allowlist
  def allowlist(_), do: @unix_allowlist

  @spec minimal() :: %{String.t() => String.t()}
  def minimal do
    for key <- allowlist(), value = System.get_env(key), value != nil, into: %{} do
      {key, value}
    end
  end
end
