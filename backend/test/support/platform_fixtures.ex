defmodule Valea.PlatformFixtures do
  @moduledoc """
  Executable script fixtures that exist on BOTH CI lanes (windows-support
  spec B5). The agent-runtime and doctor suites spawn real OS processes, so
  their fixtures were `#!/bin/sh` + `chmod` — which is not a portable way to
  say "a program that prints this and exits 1".

  `script!/4` takes both bodies and writes whichever one the host can run.
  Callers keep their assertions platform-neutral; only the two bodies differ.
  Anything whose ASSERTION mechanism is platform-bound (`pgrep -g` for
  process-group kill, `tasklist` for the Windows twin) stays tagged
  `:unix_only` / `:windows_only` instead — see `test_helper.exs`.
  """

  @doc """
  Writes an executable script fixture — `.sh` on unix, `.cmd` on windows —
  and returns its absolute path.

  The unix body is prefixed with a `#!/bin/sh` shebang and the file is made
  executable; the windows body is written verbatim (`.cmd` is executable by
  extension). Bodies are the caller's problem: they must be equivalent
  programs, not translations.
  """
  @spec script!(Path.t(), String.t(), String.t(), String.t()) :: Path.t()
  def script!(dir, name, unix_body, windows_body) do
    File.mkdir_p!(dir)

    case :os.type() do
      {:win32, _} ->
        path = Path.join(dir, name <> ".cmd")
        File.write!(path, windows_body)
        path

      _ ->
        path = Path.join(dir, name <> ".sh")
        File.write!(path, "#!/bin/sh\n" <> unix_body)
        File.chmod!(path, 0o755)
        path
    end
  end

  @doc """
  Absolute path to an executable that is present on any host of this
  platform — for tests that need "some real program", not a specific one
  (command-resolution gates, "an absolute cmd is taken as named").
  """
  @spec host_executable!() :: Path.t()
  def host_executable! do
    candidates =
      case :os.type() do
        {:win32, _} -> ["cmd.exe", "where.exe"]
        _ -> ["cat", "true"]
      end

    Enum.find_value(candidates, &System.find_executable/1) ||
      raise "no host executable found among #{inspect(candidates)}"
  end
end
