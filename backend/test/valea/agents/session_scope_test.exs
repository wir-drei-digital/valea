defmodule Valea.Agents.SessionScopeTest do
  use ExUnit.Case, async: false

  alias Valea.Agents.SessionScope
  alias Valea.Workspace.Manager

  setup do
    dir = Path.join(System.tmp_dir!(), "valea-scope-#{System.unique_integer([:positive])}")
    System.put_env("VALEA_APP_DIR", dir)
    Manager.close()
    {:ok, ws} = Manager.create("W")
    generation = Manager.generation()

    on_exit(fn ->
      Manager.close()
      File.rm_rf!(dir)
    end)

    %{ws: ws.path, home: dir, generation: generation}
  end

  # Build a real external ICM folder with a format-2 manifest — mirrors
  # `Valea.MountsTest`'s own `icm!/3`.
  defp icm!(base, name, id) do
    root = Path.join(base, name)
    File.mkdir_p!(root)
    File.write!(Path.join(root, "icm.yaml"), "format: 2\nid: #{id}\nname: \"#{name}\"\n")
    root
  end

  defp write_icms(ws, yaml_block) do
    path = Path.join(ws, "config/workspace.yaml")
    base = File.read!(path) |> String.split("icms:") |> hd()
    File.write!(path, base <> "icms:\n" <> yaml_block)
  end

  defp real!(path) do
    expanded = Path.expand(path)
    {:ok, resolved} = Valea.Paths.resolve_real(expanded, expanded)
    resolved
  end

  test "a chat scope's cwd is the primary ICM root, context.md materializes, no settings.json lands on disk, and read_paths defaults to []",
       %{ws: ws, home: home, generation: generation} do
    root = icm!(home, "Coaching", "6f9f0c9e-3ccd-4fa5-a219-113a70618b55")
    write_icms(ws, "  coaching:\n    path: #{root}\n")
    real_root = real!(root)

    assert {:ok, scope} =
             SessionScope.resolve(%{
               kind: "chat",
               mount_key: "coaching",
               generation: generation,
               session_id: "s1"
             })

    assert scope.cwd == real_root
    assert scope.primary_icm.root == real_root
    assert scope.workspace.root == ws
    assert scope.workspace.generation == generation
    assert scope.read_paths == []
    assert scope.write_paths == []
    assert scope.write_roots == []
    assert scope.kind == "chat"

    context_path = Path.join([ws, "runtime", "sessions", "s1", "context.md"])
    assert File.exists?(context_path)
    refute File.exists?(Path.join([ws, "runtime", "sessions", "s1", "settings.json"]))
    assert is_binary(scope.managed_settings)
  end

  test "a stale generation is rejected before any lookup", %{
    ws: ws,
    home: home,
    generation: generation
  } do
    root = icm!(home, "Coaching", "6f9f0c9e-3ccd-4fa5-a219-113a70618b55")
    write_icms(ws, "  coaching:\n    path: #{root}\n")

    assert SessionScope.resolve(%{
             kind: "chat",
             mount_key: "coaching",
             generation: generation + 1,
             session_id: "s2"
           }) == {:error, :workspace_changed}
  end

  test "an unknown mount_key is icm_unavailable", %{generation: generation} do
    assert SessionScope.resolve(%{
             kind: "chat",
             mount_key: "nope",
             generation: generation,
             session_id: "s3"
           }) == {:error, :icm_unavailable}
  end

  test "a disabled mount_key is icm_unavailable", %{ws: ws, home: home, generation: generation} do
    root = icm!(home, "Coaching", "6f9f0c9e-3ccd-4fa5-a219-113a70618b55")
    write_icms(ws, "  coaching:\n    path: #{root}\n    enabled: false\n")

    assert SessionScope.resolve(%{
             kind: "chat",
             mount_key: "coaching",
             generation: generation,
             session_id: "s4"
           }) == {:error, :icm_unavailable}
  end

  test "a degraded mount_key is icm_unavailable", %{ws: ws, home: home, generation: generation} do
    a = icm!(home, "A", "31201697-cff8-4d99-9dc5-b140e4178716")
    b = icm!(home, "B", "31201697-cff8-4d99-9dc5-b140e4178716")

    write_icms(ws, """
      a:
        path: #{a}
      b:
        path: #{b}
    """)

    assert SessionScope.resolve(%{
             kind: "chat",
             mount_key: "a",
             generation: generation,
             session_id: "s5"
           }) == {:error, :icm_unavailable}
  end

  test "a declared related ICM appears in scope.related_icms and its issues surface separately",
       %{
         ws: ws,
         home: home,
         generation: generation
       } do
    primary_root = icm!(home, "Coaching", "6f9f0c9e-3ccd-4fa5-a219-113a70618b55")
    related_root = icm!(home, "Legal", "31201697-cff8-4d99-9dc5-b140e4178716")

    write_icms(ws, """
      coaching:
        path: #{primary_root}
      legal:
        path: #{related_root}
    """)

    File.write!(Path.join(primary_root, "CONTEXT.md"), """
    ---
    format: 1
    related_icms:
      - id: 31201697-cff8-4d99-9dc5-b140e4178716
        name: "Legal & Administration"
    ---
    """)

    assert {:ok, scope} =
             SessionScope.resolve(%{
               kind: "chat",
               mount_key: "coaching",
               generation: generation,
               session_id: "s6"
             })

    assert [%{mount_key: "legal"}] = scope.related_icms
    assert scope.context_issues == []
    assert real!(related_root) in scope.additional_roots
  end

  test "a granted session accepts explicit read_paths/write_paths/write_roots grants", %{
    ws: ws,
    home: home,
    generation: generation
  } do
    root = icm!(home, "Coaching", "6f9f0c9e-3ccd-4fa5-a219-113a70618b55")
    write_icms(ws, "  coaching:\n    path: #{root}\n")

    input = Path.join([ws, "sources", "mail", "messages", "42.md"])
    write_path = Path.join([ws, "queue", "staging", "r1", "proposal.json"])
    write_root = Path.join([ws, "queue", "staging", "r1", "proposals"])

    assert {:ok, scope} =
             SessionScope.resolve(%{
               kind: "workflow",
               mount_key: "coaching",
               generation: generation,
               session_id: "s7",
               read_paths: [input],
               write_paths: [write_path],
               write_roots: [write_root]
             })

    assert scope.read_paths == [input]
    assert scope.write_paths == [write_path]
    assert scope.write_roots == [write_root]
  end

  # -- Task 14: mail mounts in scope (spec §"Mount & containment") ----------

  defp write_mail_yaml!(ws) do
    path = Path.join(ws, "config/mail.yaml")
    File.mkdir_p!(Path.dirname(path))

    File.write!(path, """
    version: 4
    accounts:
      mara:
        imap:
          host: imap.fastmail.com
          port: 993
          username: mara@example.com
    """)
  end

  defp mounted_primary!(ws, home) do
    root = icm!(home, "Coaching", "6f9f0c9e-3ccd-4fa5-a219-113a70618b55")
    write_icms(ws, "  coaching:\n    path: #{root}\n")
    root
  end

  test "a related_icms bare-string mail entry resolves into scope.related_icms and mail_roots_in_scope",
       %{ws: ws, home: home, generation: generation} do
    primary_root = mounted_primary!(ws, home)
    write_mail_yaml!(ws)

    File.write!(Path.join(primary_root, "CONTEXT.md"), """
    ---
    format: 1
    related_icms:
      - mail-mara
    ---
    """)

    assert {:ok, scope} =
             SessionScope.resolve(%{
               kind: "chat",
               mount_key: "coaching",
               generation: generation,
               session_id: "sm1"
             })

    mail_root = real!(Path.join([ws, "sources", "mail", "mara"]))

    assert [%{mount_key: "mail-mara", id: nil, root: ^mail_root, kind: :mail}] =
             scope.related_icms

    assert scope.mail_roots_in_scope == [mail_root]
    assert scope.mail_roots_all == [mail_root]
    assert mail_root in scope.additional_roots
  end

  test "include_mounts appends the mail mount to related_icms without a CONTEXT.md declaration",
       %{ws: ws, home: home, generation: generation} do
    mounted_primary!(ws, home)
    write_mail_yaml!(ws)

    assert {:ok, scope} =
             SessionScope.resolve(%{
               kind: "chat",
               mount_key: "coaching",
               generation: generation,
               session_id: "sm2",
               include_mounts: ["mail-mara"]
             })

    mail_root = real!(Path.join([ws, "sources", "mail", "mara"]))
    assert [%{mount_key: "mail-mara", kind: :mail}] = scope.related_icms
    assert scope.mail_roots_in_scope == [mail_root]
    assert mail_root in scope.additional_roots
  end

  test "include_mounts naming a declared mail account dedupes against the grammar entry",
       %{ws: ws, home: home, generation: generation} do
    primary_root = mounted_primary!(ws, home)
    write_mail_yaml!(ws)

    File.write!(Path.join(primary_root, "CONTEXT.md"), """
    ---
    format: 1
    related_icms:
      - mail-mara
    ---
    """)

    assert {:ok, scope} =
             SessionScope.resolve(%{
               kind: "chat",
               mount_key: "coaching",
               generation: generation,
               session_id: "sm3",
               include_mounts: ["mail-mara"]
             })

    assert Enum.count(scope.related_icms, &(&1.mount_key == "mail-mara")) == 1
  end

  test "an ICM key in include_mounts is rejected include_not_mail", %{
    ws: ws,
    home: home,
    generation: generation
  } do
    mounted_primary!(ws, home)
    write_mail_yaml!(ws)

    assert SessionScope.resolve(%{
             kind: "chat",
             mount_key: "coaching",
             generation: generation,
             session_id: "sm4",
             include_mounts: ["coaching"]
           }) == {:error, :include_not_mail}
  end

  test "an unknown account in include_mounts is rejected mail_unavailable", %{
    ws: ws,
    home: home,
    generation: generation
  } do
    mounted_primary!(ws, home)
    write_mail_yaml!(ws)

    assert SessionScope.resolve(%{
             kind: "chat",
             mount_key: "coaching",
             generation: generation,
             session_id: "sm5",
             include_mounts: ["mail-nope"]
           }) == {:error, :mail_unavailable}
  end

  test "a mail mount can never be the session primary", %{
    ws: ws,
    home: home,
    generation: generation
  } do
    mounted_primary!(ws, home)
    write_mail_yaml!(ws)

    assert SessionScope.resolve(%{
             kind: "chat",
             mount_key: "mail-mara",
             generation: generation,
             session_id: "sm6"
           }) == {:error, :icm_unavailable}
  end

  test "an unconfigured mail declaration surfaces as a :mail_unavailable context issue, and mail_roots stay empty",
       %{ws: ws, home: home, generation: generation} do
    primary_root = mounted_primary!(ws, home)

    File.write!(Path.join(primary_root, "CONTEXT.md"), """
    ---
    format: 1
    related_icms:
      - mail-nope
    ---
    """)

    assert {:ok, scope} =
             SessionScope.resolve(%{
               kind: "chat",
               mount_key: "coaching",
               generation: generation,
               session_id: "sm7"
             })

    assert scope.related_icms == []
    assert [%{name: "mail-nope", reason: :mail_unavailable}] = scope.context_issues
    assert scope.mail_roots_all == []
    assert scope.mail_roots_in_scope == []
  end

  # Spec §"Safety invariants" — the RPC trust boundary: agent sessions speak
  # ACP only. Nothing in the launch directives (env, managedSettings JSON,
  # extra argv) may carry the loopback RPC endpoint or the control token
  # that authenticates it.
  test "launch directives expose no RPC endpoint or control token to the agent process", %{
    ws: ws,
    home: home,
    generation: generation
  } do
    mounted_primary!(ws, home)

    previous = Application.get_env(:valea, :control_token)
    Application.put_env(:valea, :control_token, "task14-secret-token")
    on_exit(fn -> Application.put_env(:valea, :control_token, previous) end)

    assert {:ok, scope} =
             SessionScope.resolve(%{
               kind: "chat",
               mount_key: "coaching",
               generation: generation,
               session_id: "sm8"
             })

    refute scope.managed_settings =~ "task14-secret-token"
    refute scope.managed_settings =~ "/rpc/"
    refute Enum.any?(scope.argv_extra, &(&1 =~ "task14-secret-token" or &1 =~ "/rpc/"))

    for {key, value} <- scope.env do
      assert key in Valea.Agents.Env.allowlist()
      refute value =~ "task14-secret-token"
      refute String.contains?(value, "/rpc/")
    end
  end
end
