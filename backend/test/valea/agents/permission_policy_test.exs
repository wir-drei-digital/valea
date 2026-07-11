defmodule Valea.Agents.PermissionPolicyTest do
  use ExUnit.Case, async: true

  alias Valea.Agents.PermissionPolicy

  setup do
    ws =
      Path.join(
        System.tmp_dir!(),
        "valea-policy-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(ws, "icm"))
    File.mkdir_p!(Path.join(ws, "secrets"))
    File.mkdir_p!(Path.join(ws, "logs"))
    File.mkdir_p!(Path.join(ws, "queue/pending"))
    File.mkdir_p!(Path.join(ws, "queue/staging/r1"))
    File.write!(Path.join([ws, "icm", "note.md"]), "hi")
    File.write!(Path.join([ws, "secrets", "notes.txt"]), "shh")

    on_exit(fn -> File.rm_rf!(ws) end)

    chat = %{workspace: ws, session_kind: "chat", write_paths: []}
    {:ok, ws: ws, chat: chat}
  end

  defp item(kind, raw_input, title \\ "Tool call") do
    %{"id" => "perm1", "kind" => kind, "rawInput" => raw_input, "title" => title}
  end

  test "read inside icm/ -> allow", %{ws: ws, chat: chat} do
    it = item("read", %{"file_path" => Path.join([ws, "icm", "note.md"])})
    assert {:allow, "allow_once"} = PermissionPolicy.decide(it, chat)
  end

  test "read of a root reference file (CLAUDE.md) -> allow", %{ws: ws, chat: chat} do
    it = item("read", %{"file_path" => Path.join(ws, "CLAUDE.md")})
    assert {:allow, "allow_once"} = PermissionPolicy.decide(it, chat)
  end

  test "read of secrets/notes.txt -> deny", %{ws: ws, chat: chat} do
    it = item("read", %{"file_path" => Path.join([ws, "secrets", "notes.txt"])})
    assert {:deny, "reject_once"} = PermissionPolicy.decide(it, chat)
  end

  test "read of SECRETS/x (uppercased) -> deny (case-insensitive hard-deny)", %{
    ws: ws,
    chat: chat
  } do
    it = item("read", %{"file_path" => Path.join([ws, "SECRETS", "x"])})
    assert {:deny, "reject_once"} = PermissionPolicy.decide(it, chat)
  end

  test "write of Logs/y (mixed case) -> deny (case-insensitive hard-deny)", %{ws: ws} do
    target = Path.join([ws, "Logs", "y"])
    ctx = %{workspace: ws, session_kind: "workflow", write_paths: [target]}
    it = item("edit", %{"file_path" => target})
    assert {:deny, "reject_once"} = PermissionPolicy.decide(it, ctx)
  end

  test "write of APP.SQLITE (uppercased) -> deny (case-insensitive db-prefix)", %{ws: ws} do
    target = Path.join(ws, "APP.SQLITE")
    ctx = %{workspace: ws, session_kind: "workflow", write_paths: [target]}
    it = item("edit", %{"file_path" => target})
    assert {:deny, "reject_once"} = PermissionPolicy.decide(it, ctx)
  end

  test "read via symlink icm/link.md -> /etc/passwd -> deny (outside)", %{ws: ws, chat: chat} do
    File.ln_s!("/etc/passwd", Path.join([ws, "icm", "link.md"]))
    it = item("read", %{"file_path" => Path.join([ws, "icm", "link.md"])})
    assert {:deny, "reject_once"} = PermissionPolicy.decide(it, chat)
  end

  test "read of queue/pending/x.json -> ask (not a declared read root)", %{ws: ws, chat: chat} do
    it = item("read", %{"file_path" => Path.join([ws, "queue", "pending", "x.json"])})
    assert :ask = PermissionPolicy.decide(it, chat)
  end

  test "write to the exact staging path, workflow ctx -> allow", %{ws: ws} do
    staging = Path.join([ws, "queue", "staging", "r1", "proposal.json"])
    ctx = %{workspace: ws, session_kind: "workflow", write_paths: [staging]}
    it = item("edit", %{"file_path" => staging})
    assert {:allow, "allow_once"} = PermissionPolicy.decide(it, ctx)
  end

  test "write to a DIFFERENT staging path -> ask", %{ws: ws} do
    allowed = Path.join([ws, "queue", "staging", "r1", "proposal.json"])
    other = Path.join([ws, "queue", "staging", "r1", "other.json"])
    ctx = %{workspace: ws, session_kind: "workflow", write_paths: [allowed]}
    it = item("edit", %{"file_path" => other})
    assert :ask = PermissionPolicy.decide(it, ctx)
  end

  test "any write in chat ctx -> ask", %{ws: ws, chat: chat} do
    staging = Path.join([ws, "queue", "staging", "r1", "proposal.json"])
    it = item("edit", %{"file_path" => staging})
    assert :ask = PermissionPolicy.decide(it, chat)
  end

  test "write targeting logs/audit.jsonl -> deny (deny precedence over ask)", %{ws: ws} do
    logs = Path.join([ws, "logs", "audit.jsonl"])
    # Even in workflow ctx that lists it as writable, deny wins.
    ctx = %{workspace: ws, session_kind: "workflow", write_paths: [logs]}
    it = item("edit", %{"file_path" => logs})
    assert {:deny, "reject_once"} = PermissionPolicy.decide(it, ctx)
  end

  test "write targeting app.sqlite -> deny", %{ws: ws} do
    db = Path.join(ws, "app.sqlite")
    ctx = %{workspace: ws, session_kind: "workflow", write_paths: [db]}
    it = item("edit", %{"file_path" => db})
    assert {:deny, "reject_once"} = PermissionPolicy.decide(it, ctx)
  end

  test "kind execute (Bash) -> ask even with workspace paths in rawInput", %{ws: ws, chat: chat} do
    it = item("execute", %{"file_path" => Path.join([ws, "icm", "note.md"])})
    assert :ask = PermissionPolicy.decide(it, chat)
  end

  test "no rawInput paths, kind read -> ask", %{chat: chat} do
    it = item("read", %{"command" => "ls"})
    assert :ask = PermissionPolicy.decide(it, chat)
  end

  test "read of an absolute path outside the workspace -> deny", %{chat: chat} do
    it = item("read", %{"file_path" => "/etc/passwd"})
    assert {:deny, "reject_once"} = PermissionPolicy.decide(it, chat)
  end

  # --- realpath regression at the policy level ---
  # resolve_real resolves symlinks before ".", so these adversarial inputs
  # can no longer masquerade as a benign in-workspace path.

  test "read via symlink icm/L -> secrets/ssl then .. -> deny (lands in secrets/)", %{
    ws: ws,
    chat: chat
  } do
    File.mkdir_p!(Path.join([ws, "secrets", "ssl"]))
    File.ln_s!(Path.join([ws, "secrets", "ssl"]), Path.join([ws, "icm", "L"]))
    it = item("read", %{"file_path" => Path.join([ws, "icm", "L", "..", "master.key"])})
    assert {:deny, "reject_once"} = PermissionPolicy.decide(it, chat)
  end

  test "read via symlink icm/L -> /etc/ssl then .. -> deny (outside host file)", %{
    ws: ws,
    chat: chat
  } do
    File.ln_s!("/etc/ssl", Path.join([ws, "icm", "L"]))
    it = item("read", %{"file_path" => Path.join([ws, "icm", "L", "..", "passwd"])})
    assert {:deny, "reject_once"} = PermissionPolicy.decide(it, chat)
  end

  test "write via symlink staging/L -> /tmp then .. -> NOT allow (escapes write target)", %{
    ws: ws
  } do
    staging = Path.join([ws, "queue", "staging", "r1", "proposal.json"])
    File.ln_s!("/tmp", Path.join([ws, "queue", "staging", "r1", "L"]))
    ctx = %{workspace: ws, session_kind: "workflow", write_paths: [staging]}

    it =
      item("edit", %{
        "file_path" => Path.join([ws, "queue", "staging", "r1", "L", "..", "proposal.json"])
      })

    decision = PermissionPolicy.decide(it, ctx)
    refute match?({:allow, _}, decision)
    assert decision == {:deny, "reject_once"}
  end

  test "ctx[:read_roots] override extends what auto-allows", %{ws: ws} do
    ctx = %{
      workspace: ws,
      session_kind: "chat",
      write_paths: [],
      read_roots: ["queue"]
    }

    it = item("read", %{"file_path" => Path.join([ws, "queue", "pending", "x.json"])})
    assert {:allow, "allow_once"} = PermissionPolicy.decide(it, ctx)
  end
end
