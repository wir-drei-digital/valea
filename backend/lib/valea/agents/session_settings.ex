defmodule Valea.Agents.SessionSettings do
  @moduledoc """
  Renders and materializes the Valea-owned harness settings + context for one
  session, under `<workspace>/runtime/sessions/<id>/`. Unlike the old
  `Valea.Agents.ClaudeSettings` (which wrote `<workspace>/.claude/settings.json`
  and relied on `./**` globs being anchored to cwd == workspace), every rule
  here is an ABSOLUTE-path glob so it stays correct when the cwd is an external
  ICM root that is NOT the workspace. Deny wins over allow. Valea never writes a
  settings file inside a user-owned ICM.

  See docs/notes/acp-launch-contract.md for how the harness is pointed at the
  materialized settings file and the additional read roots.
  """

  @protected ~w(logs config secrets runtime .git)
  @db_files ~w(app.sqlite app.sqlite-wal app.sqlite-shm)

  # Valea's queue vocabulary (proposal/v1 + memory_update/v1), lifted verbatim
  # from backend/priv/workspace_template/AGENTS.md ("The proposal contract"
  # through "The memory-update contract"). That template file carries no root
  # AGENTS.md once Phase 2 removes it, so this is now the only place a
  # workflow session is taught these schemas. Preserve verbatim.
  @workflow_contract """
  ## The proposal contract

  A workflow run names one output path. Write a single JSON file there:

  ```json
  {
    "schema": "proposal/v1",
    "kind": "email_draft",
    "title": "Reply to <name> — <one-line summary>",
    "summary": "One or two sentences on what this is and why.",
    "sources": [
      "sources/mail/messages/<the-message-file>.md",
      "mounts/<mount>/<the-pages-you-read>.md"
    ],
    "proposed_action": {
      "type": "create_email_draft",
      "to": "<recipient>",
      "subject": "<subject>",
      "body_markdown": "<the complete draft>"
    },
    "reasoning": "One or two plain sentences the owner will read."
  }
  ```

  - `sources` lists every file you actually read, workspace-relative.
  - `body_markdown` is the complete draft, ready to review.
  - `reasoning` is one or two plain sentences the owner will read.

  ## The memory-update contract

  You never edit mount pages directly during a workflow run. To propose a
  change to business memory, write a PAIR of files under the run's staging
  `proposals/` folder:

  - `<name>.md` — the complete new content of the target page.
  - `<name>.json` — a manifest:

      {
        "schema": "memory_update/v1",
        "target_path": "mounts/<mount>/Pricing/Current Pricing.md",
        "base_sha256": "<sha256 hex of the target page exactly as you read it, or null to create a new page>",
        "reason": "one line: why this change",
        "sources": ["paths you read"]
      }

  The `base_sha256` must be lowercase hex, exactly 64 characters. Page content is capped at 1 MB — split anything larger.

  Target paths use the same form you read them by: workspace-relative for
  mounts under `mounts/`, absolute for mounts listed with a real location
  in MOUNTS.md. The app verifies the target and shows the user a diff;
  nothing changes without their approval.
  """

  @spec content(map()) :: map()
  def content(scope) do
    read_root_allows =
      ([scope.primary_icm.root] ++ Enum.map(scope.related_icms, & &1.root))
      |> Enum.map(&"Read(#{&1}/**)")

    input_allows = Enum.map(scope.read_paths, &"Read(#{&1})")
    write_path_allows = Enum.map(scope.write_paths, &"Write(#{&1})")
    write_root_allows = Enum.map(scope.write_roots, &"Write(#{&1}/**)")

    ws = scope.workspace.root

    deny =
      Enum.flat_map(@protected, fn d ->
        ["Read(#{ws}/#{d}/**)", "Edit(#{ws}/#{d}/**)", "Write(#{ws}/#{d}/**)"]
      end) ++
        Enum.map(@db_files, &"Read(#{ws}/#{&1})") ++
        ["WebFetch", "WebSearch"]

    %{
      "permissions" => %{
        "deny" => deny,
        "ask" => ["Write", "Edit", "Bash"],
        "allow" => read_root_allows ++ input_allows ++ write_path_allows ++ write_root_allows
      }
    }
  end

  @spec context(map()) :: String.t()
  def context(scope) do
    related =
      scope.related_icms
      |> Enum.map(fn r -> "- #{r.mount_key} (#{r.root}) — entrypoint #{r.entrypoint}" end)
      |> Enum.join("\n")

    related = if related == "", do: "(none)", else: related

    base = """
    # Session context (Valea-managed)

    Primary ICM: #{scope.primary_icm.mount_key} — #{scope.primary_icm.root}
    Your working directory IS this ICM's root. Relative paths resolve here.

    Related ICMs available to this session (read their entrypoint only when your
    routing calls for it; they do not load automatically):
    #{related}
    """

    if scope.kind == "workflow" do
      base <> "\n" <> @workflow_contract
    else
      base
    end
  end

  @spec materialize!(map()) :: :ok
  def materialize!(scope) do
    # Only context.md is written to disk (session bootstrap: related-ICM map + injected
    # contract). The permission posture is NOT written as a file — it is rendered by
    # content/1 and passed in-memory to the harness as managedSettings (--managed-settings
    # <json>), so nothing lands in or near the ICM. Enforcement: the posture forces sensitive
    # calls to "ask", and PermissionPolicy on the ACP request_permission callback answers them.
    write_atomic!(scope.managed_context, context(scope))
    :ok
  end

  defp write_atomic!(path, data) do
    File.mkdir_p!(Path.dirname(path))
    tmp = path <> ".tmp"
    File.write!(tmp, data)
    File.rename!(tmp, path)
  end
end
