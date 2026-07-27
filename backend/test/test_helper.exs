# Platform-bound tests are tagged, not branched (windows-support spec B5):
# `:unix_only` for an assertion that only a unix host can make (`pgrep -g`
# process-group kill, `exec -a` argv renaming), `:windows_only` for its
# Windows twin (`tasklist`). Everything else must pass on BOTH lanes —
# portable fixtures come from `Valea.PlatformFixtures`.
excluded =
  case :os.type() do
    {:win32, _} -> [:unix_only]
    _ -> [:windows_only]
  end

ExUnit.start(exclude: excluded)
