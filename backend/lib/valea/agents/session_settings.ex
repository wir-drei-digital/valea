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

    icm_roots = [scope.primary_icm.root | Enum.map(scope.related_icms, & &1.root)]

    # Spec D §D5 mirror of PermissionPolicy.secret_relative?/1. Globs cannot
    # express the `.env.example` exception, so this layer denies `.env.*`
    # wholesale — strictly more restrictive than the authoritative policy
    # layer, accepted by design. This glob mirror is also case-SENSITIVE
    # (unlike `secret_relative?/1`): the authoritative, case-insensitive
    # enforcement is PermissionPolicy's deny tier, and this mirror is
    # defense-in-depth on top of it, not the security boundary itself.
    secret_denies =
      Enum.flat_map(icm_roots, fn root ->
        patterns = [
          "#{root}/secrets/**",
          "#{root}/**/secrets/**",
          "#{root}/.env",
          "#{root}/.env.*",
          "#{root}/**/.env",
          "#{root}/**/.env.*",
          "#{root}/**/*.pem",
          "#{root}/**/*.key",
          "#{root}/**/*credentials*",
          "#{root}/*credentials*"
        ]

        for pattern <- patterns, op <- ["Read", "Edit", "Write"], do: "#{op}(#{pattern})"
      end)

    %{
      "permissions" => %{
        "deny" => deny ++ secret_denies ++ mail_denies(scope),
        "ask" => ["Write", "Edit", "Bash"],
        "allow" => read_root_allows ++ input_allows ++ write_path_allows ++ write_root_allows
      }
    }
  end

  # Task 14 (mail spec §"Mount & containment") — the managedSettings mirror
  # of PermissionPolicy's mail tier. For each IN-SCOPE mail root: `spool/**`
  # is denied outright (Read+Edit+Write — engine-owned outbound payloads),
  # and the engine-owned/audit subtrees (`maildir/**`, `views/**`,
  # `quarantine/**`, `.account`, `ops/done/**`) are write-denied but stay
  # readable — the agent-writable surface is exactly `ops/pending/` and
  # `drafts/`. Each NOT-in-scope account's whole root is denied over
  # Read+Edit+Write.
  #
  # Like the secrets mirror above, these globs are case-SENSITIVE
  # defense-in-depth: the authoritative, casefolded (case- AND
  # normalization-insensitive) enforcement is PermissionPolicy's mail deny
  # tier, not this layer.
  @mail_write_denied ~w(maildir/** views/** quarantine/** .account ops/done/**)

  defp mail_denies(scope) do
    in_scope = Map.get(scope, :mail_roots_in_scope, [])
    out_of_scope = Map.get(scope, :mail_roots_all, []) -- in_scope

    in_scope_denies =
      Enum.flat_map(in_scope, fn root ->
        spool = for op <- ["Read", "Edit", "Write"], do: "#{op}(#{root}/spool/**)"

        engine_owned =
          for pattern <- @mail_write_denied, op <- ["Edit", "Write"] do
            "#{op}(#{root}/#{pattern})"
          end

        spool ++ engine_owned
      end)

    out_of_scope_denies =
      Enum.flat_map(out_of_scope, fn root ->
        for op <- ["Read", "Edit", "Write"], do: "#{op}(#{root}/**)"
      end)

    in_scope_denies ++ out_of_scope_denies
  end

  @spec context(map()) :: String.t()
  def context(scope) do
    related =
      scope.related_icms
      |> Enum.map(&related_line/1)
      |> Enum.join("\n")

    related = if related == "", do: "(none)", else: related

    """
    # Session context (Valea-managed)

    Primary ICM: #{scope.primary_icm.mount_key} — #{scope.primary_icm.root}
    Your working directory IS this ICM's root. Relative paths resolve here.

    Related ICMs available to this session (read their entrypoint only when your
    routing calls for it; they do not load automatically):
    #{related}
    """
  end

  # A mail mount (Task 14) has no entrypoint/manifest — its line names the
  # account and the narrowed write surface instead of an entrypoint.
  defp related_line(%{kind: :mail} = r) do
    "- #{r.mount_key} (#{r.root}) — mail account mount; writable only under ops/pending/ and drafts/"
  end

  defp related_line(r), do: "- #{r.mount_key} (#{r.root}) — entrypoint #{r.entrypoint}"

  @spec materialize!(map()) :: :ok
  def materialize!(scope) do
    # Only context.md is written to disk (session bootstrap: the related-ICM
    # map). The permission posture is NOT written as a file — it is rendered by
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
