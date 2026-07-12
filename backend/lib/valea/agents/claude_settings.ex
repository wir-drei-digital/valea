defmodule Valea.Agents.ClaudeSettings do
  @moduledoc """
  Writes the MANAGED `.claude/settings.json` into a workspace. ACP agents
  only *may* ask permission — Claude Code auto-approves anything its own
  rules allow before Valea's callback ever fires. This file forces
  writes/Bash to `ask` (so they reach the ACP permission request), SCOPES
  the read auto-allow to the workspace tree only, and hard-denies the
  protected paths. Regenerated at every session start; the workspace
  gitignore excludes `.claude/`.

  Claude Code applies rules in the order deny > ask > allow, and every
  Read/Edit/Write rule is a path glob rooted at the session cwd (the
  workspace root). That precedence is why the `Read(./secrets/**)` etc.
  deny globs still win over the `Read(./**)` allow below.

  ## External (by-reference) mounts

  `Read(./**)` only auto-allows reads INSIDE the workspace tree — an
  enabled EXTERNAL mount (`Valea.Mounts.enabled/1` entry with `rel_root:
  nil`; Plan A2) lives outside it entirely, so without an additional entry
  every read under it would fall through to `ask` even though
  `PermissionPolicy`'s `extra_roots` (A2-T3) already trusts it. `content/1`
  ADDITIONALLY allows `Read(<resolved-abs-root>/**)` — an absolute glob,
  which Claude Code accepts alongside the relative `./**` form — for every
  enabled external mount's already-realpath-resolved `root`. Embedded
  mounts need no such entry; they're under `./**` already. The allow set
  is computed FRESH from `Mounts.enabled/1` on every `write!/1` call, never
  cached, so a disabled external mount's entry disappears the next time
  settings regenerate (session start, or the `set_mount_enabled`/
  `create_mount` RPC mutations in `Valea.Api.Mounts`, which regenerate this
  file the same way they already regenerate MOUNTS.md).
  """

  alias Valea.Mounts

  @protected ["secrets", "logs", ".claude", ".git"]
  @db_globs ["app.sqlite", "app.sqlite-wal", "app.sqlite-shm"]

  def content(workspace_root) do
    deny =
      Enum.flat_map(@protected, fn dir ->
        ["Read(./#{dir}/**)", "Edit(./#{dir}/**)", "Write(./#{dir}/**)"]
      end) ++
        Enum.flat_map(@db_globs, fn f -> ["Read(./#{f})", "Edit(./#{f})", "Write(./#{f})"] end) ++
        ["WebFetch", "WebSearch"]

    %{
      "permissions" => %{
        "deny" => deny,
        "ask" => ["Write", "Edit", "Bash"],
        # LOAD-BEARING scoping: `Read(./**)` auto-allows reads only under the
        # workspace cwd. An UNSCOPED `Read` would auto-approve reads of ANY
        # path the OS user can reach (~/.ssh, ~/.aws, sibling projects) BEFORE
        # the ACP permission callback fires — making PermissionPolicy's
        # outside-workspace deny and read-roots allowlist dead code for reads.
        # With this glob, an out-of-workspace read has no matching allow, falls
        # through to `ask`, and reaches session/request_permission →
        # PermissionPolicy (deny/ask/audit). Reads inside the workspace but
        # outside the policy's read-roots also ask — that is the correct,
        # audited behavior, not a regression.
        "allow" => ["Read(./**)" | external_read_allows(workspace_root)]
      }
    }
  end

  def write!(workspace_root) do
    dir = Path.join(workspace_root, ".claude")
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "settings.json"),
      Jason.encode!(content(workspace_root), pretty: true) <> "\n"
    )

    :ok
  end

  # One absolute `Read(<root>/**)` allow per enabled external mount
  # (`rel_root: nil`), sorted by name (`Mounts.enabled/1`'s own order) for a
  # deterministic, diff-stable file. Embedded mounts (`rel_root` set) are
  # skipped — already covered by the `Read(./**)` allow above.
  defp external_read_allows(workspace_root) do
    workspace_root
    |> Mounts.enabled()
    |> Enum.filter(&(&1.rel_root == nil))
    |> Enum.map(&"Read(#{&1.root}/**)")
  end
end
