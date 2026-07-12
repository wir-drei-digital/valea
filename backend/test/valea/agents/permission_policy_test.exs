defmodule Valea.Agents.PermissionPolicyTest do
  use ExUnit.Case, async: true

  alias Valea.Agents.PermissionPolicy

  setup do
    ws =
      Path.join(
        System.tmp_dir!(),
        "valea-policy-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(ws, "sources"))
    File.mkdir_p!(Path.join(ws, "secrets"))
    File.mkdir_p!(Path.join(ws, "logs"))
    File.mkdir_p!(Path.join(ws, "queue/pending"))
    File.mkdir_p!(Path.join(ws, "queue/staging/r1"))
    File.mkdir_p!(Path.join(ws, "mounts/a/Offers"))
    File.mkdir_p!(Path.join(ws, "mounts/ab"))
    File.write!(Path.join([ws, "sources", "note.md"]), "hi")
    File.write!(Path.join([ws, "secrets", "notes.txt"]), "shh")
    File.write!(Path.join([ws, "mounts", "a", "note.md"]), "hi")
    File.write!(Path.join([ws, "mounts", "a", "Offers", "X.md"]), "hi")
    File.write!(Path.join([ws, "mounts", "ab", "X.md"]), "hi")

    on_exit(fn -> File.rm_rf!(ws) end)

    chat = %{workspace: ws, session_kind: "chat", write_paths: []}
    {:ok, ws: ws, chat: chat}
  end

  defp item(kind, raw_input, title \\ "Tool call") do
    %{"id" => "perm1", "kind" => kind, "rawInput" => raw_input, "title" => title}
  end

  test "read inside sources/ -> allow (default read_roots, no override)", %{ws: ws, chat: chat} do
    it = item("read", %{"file_path" => Path.join([ws, "sources", "note.md"])})
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

  test "read via symlink sources/link.md -> /etc/passwd -> deny (outside)", %{ws: ws, chat: chat} do
    File.ln_s!("/etc/passwd", Path.join([ws, "sources", "link.md"]))
    it = item("read", %{"file_path" => Path.join([ws, "sources", "link.md"])})
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
    it = item("execute", %{"file_path" => Path.join([ws, "sources", "note.md"])})
    assert :ask = PermissionPolicy.decide(it, chat)
  end

  test "no rawInput paths, kind read -> ask", %{chat: chat} do
    it = item("read", %{"command" => "ls"})
    assert :ask = PermissionPolicy.decide(it, chat)
  end

  # Pre-A2-T3, ANY absolute path outside the workspace hit the same
  # `{:error, :outside}` -> hard-deny path as a genuine workspace escape,
  # because a fixed single root had no way to distinguish "unrecognized
  # location" from "actively escaping a trusted root". Now that containment
  # is a ROOT SET, an absolute path that never nominally claimed to be under
  # any enabled root (workspace or extra_roots) is merely unrecognized ->
  # ask-gate. A path that DID nominally claim an enabled root but resolves
  # elsewhere (a symlink escape) is the one that stays hard-denied — see the
  # extra_roots section below.
  test "read of an absolute path under NO root (no extra_roots, not workspace) -> ask", %{
    chat: chat
  } do
    it = item("read", %{"file_path" => "/etc/passwd"})
    assert :ask = PermissionPolicy.decide(it, chat)
  end

  # --- realpath regression at the policy level ---
  # resolve_real resolves symlinks before ".", so these adversarial inputs
  # can no longer masquerade as a benign in-workspace path.

  test "read via symlink sources/L -> secrets/ssl then .. -> deny (lands in secrets/)", %{
    ws: ws,
    chat: chat
  } do
    File.mkdir_p!(Path.join([ws, "secrets", "ssl"]))
    File.ln_s!(Path.join([ws, "secrets", "ssl"]), Path.join([ws, "sources", "L"]))
    it = item("read", %{"file_path" => Path.join([ws, "sources", "L", "..", "master.key"])})
    assert {:deny, "reject_once"} = PermissionPolicy.decide(it, chat)
  end

  test "read via symlink sources/L -> /etc/ssl then .. -> deny (outside host file)", %{
    ws: ws,
    chat: chat
  } do
    File.ln_s!("/etc/ssl", Path.join([ws, "sources", "L"]))
    it = item("read", %{"file_path" => Path.join([ws, "sources", "L", "..", "passwd"])})
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

  # --- per-mount read_roots (A-T10) ---

  defp mount_ctx(ws, roots) do
    %{workspace: ws, session_kind: "chat", write_paths: [], read_roots: ["sources" | roots]}
  end

  test "read under mounts/a/... -> allow when mounts/a is an enabled read root", %{ws: ws} do
    ctx = mount_ctx(ws, ["mounts/a"])
    it = item("read", %{"file_path" => Path.join([ws, "mounts", "a", "note.md"])})
    assert {:allow, "allow_once"} = PermissionPolicy.decide(it, ctx)
  end

  test "read under mounts/a/Offers/... (nested) -> allow when mounts/a is a read root", %{ws: ws} do
    ctx = mount_ctx(ws, ["mounts/a"])
    it = item("read", %{"file_path" => Path.join([ws, "mounts", "a", "Offers", "X.md"])})
    assert {:allow, "allow_once"} = PermissionPolicy.decide(it, ctx)
  end

  test "read under mounts/b/... -> ask when b is disabled/absent from read_roots", %{ws: ws} do
    ctx = mount_ctx(ws, ["mounts/a"])
    it = item("read", %{"file_path" => Path.join([ws, "mounts", "b", "note.md"])})
    assert :ask = PermissionPolicy.decide(it, ctx)
  end

  test "mounts/a matches mounts/a/... but NOT mounts/ab/... — segment boundary, not string prefix",
       %{ws: ws} do
    ctx = mount_ctx(ws, ["mounts/a"])

    a = item("read", %{"file_path" => Path.join([ws, "mounts", "a", "note.md"])})
    assert {:allow, "allow_once"} = PermissionPolicy.decide(a, ctx)

    ab = item("read", %{"file_path" => Path.join([ws, "mounts", "ab", "X.md"])})
    assert :ask = PermissionPolicy.decide(ab, ctx)
  end

  test "deny-list wins over an allowed mount root: mounts/a/../../secrets/x -> deny", %{ws: ws} do
    ctx = mount_ctx(ws, ["mounts/a"])

    it =
      item("read", %{
        "file_path" => Path.join([ws, "mounts", "a", "..", "..", "secrets", "notes.txt"])
      })

    assert {:deny, "reject_once"} = PermissionPolicy.decide(it, ctx)
  end

  test "a symlink inside an allowed mount escaping outside the workspace -> deny", %{ws: ws} do
    ctx = mount_ctx(ws, ["mounts/a"])
    File.ln_s!("/etc/passwd", Path.join([ws, "mounts", "a", "escape"]))
    it = item("read", %{"file_path" => Path.join([ws, "mounts", "a", "escape"])})
    assert {:deny, "reject_once"} = PermissionPolicy.decide(it, ctx)
  end

  # --- root-set containment: extra_roots (A2-T3, by-reference/external mounts) ---
  #
  # `ctx[:extra_roots]` is a list of ABSOLUTE, already-resolved-real external
  # mount roots (mirroring `Valea.Mounts.enabled/1`'s `root` for a
  # `rel_root: nil` mount). The read surface PermissionPolicy grants is the
  # workspace root (existing read_roots logic, unchanged) UNION every
  # extra_roots member. Write containment never consults extra_roots — reads
  # only.

  defp external_root! do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-policy-ext-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    # Realpath-resolve exactly like `Valea.Mounts.External` resolves a
    # declared mount's own root (`Path.expand/1` then the `resolve_real(p, p)`
    # self-base trick), so these tests exercise the same absolute strings
    # production code would put in `ctx[:extra_roots]`.
    expanded = Path.expand(dir)

    case Valea.Paths.resolve_real(expanded, expanded) do
      {:ok, real} -> real
      {:error, _} -> expanded
    end
  end

  defp extra_ctx(ws, extra_roots) do
    %{workspace: ws, session_kind: "chat", write_paths: [], extra_roots: extra_roots}
  end

  test "read under an extra_roots member -> allow", %{ws: ws} do
    ext = external_root!()
    File.write!(Path.join(ext, "note.md"), "hi")
    ctx = extra_ctx(ws, [ext])

    it = item("read", %{"file_path" => Path.join(ext, "note.md")})
    assert {:allow, "allow_once"} = PermissionPolicy.decide(it, ctx)
  end

  test "read under the same external root -> ask when its mount is disabled (absent from extra_roots)",
       %{ws: ws} do
    ext = external_root!()
    File.write!(Path.join(ext, "note.md"), "hi")
    ctx = extra_ctx(ws, [])

    it = item("read", %{"file_path" => Path.join(ext, "note.md")})
    assert :ask = PermissionPolicy.decide(it, ctx)
  end

  test "a symlink inside an enabled extra_root escaping to an unenrolled location -> deny", %{
    ws: ws
  } do
    ext = external_root!()
    File.ln_s!("/etc/hosts", Path.join(ext, "escape"))
    ctx = extra_ctx(ws, [ext])

    it = item("read", %{"file_path" => Path.join(ext, "escape")})
    assert {:deny, "reject_once"} = PermissionPolicy.decide(it, ctx)
  end

  test "a symlink inside an enabled extra_root INTO workspace sources/ -> allow (lands in another enabled root)",
       %{ws: ws} do
    ext = external_root!()
    File.ln_s!(Path.join([ws, "sources", "note.md"]), Path.join(ext, "into_ws"))
    ctx = extra_ctx(ws, [ext])

    it = item("read", %{"file_path" => Path.join(ext, "into_ws")})
    assert {:allow, "allow_once"} = PermissionPolicy.decide(it, ctx)
  end

  test "workspace deny-list still wins with extra_roots configured: secrets/ -> deny", %{ws: ws} do
    ext = external_root!()
    ctx = extra_ctx(ws, [ext])

    it = item("read", %{"file_path" => Path.join([ws, "secrets", "notes.txt"])})
    assert {:deny, "reject_once"} = PermissionPolicy.decide(it, ctx)
  end

  test "prefix-boundary: an extra_roots member does not match a sibling dir sharing its prefix",
       %{ws: ws} do
    ext = external_root!()
    sibling = ext <> "-other"
    File.mkdir_p!(sibling)
    on_exit(fn -> File.rm_rf!(sibling) end)
    File.write!(Path.join(sibling, "file.md"), "hi")
    ctx = extra_ctx(ws, [ext])

    it = item("read", %{"file_path" => Path.join(sibling, "file.md")})
    assert :ask = PermissionPolicy.decide(it, ctx)
  end

  test "a deny-listed workspace path reached VIA an external symlink -> deny (walks into workspace secrets/)",
       %{ws: ws} do
    ext = external_root!()
    File.ln_s!(Path.join([ws, "secrets", "notes.txt"]), Path.join(ext, "to_secrets"))
    ctx = extra_ctx(ws, [ext])

    it = item("read", %{"file_path" => Path.join(ext, "to_secrets")})
    assert {:deny, "reject_once"} = PermissionPolicy.decide(it, ctx)
  end

  test "write under an extra_roots member -> NOT allowed (write containment stays staging-only)",
       %{ws: ws} do
    ext = external_root!()
    File.write!(Path.join(ext, "file.md"), "hi")
    staging = Path.join([ws, "queue", "staging", "r1", "proposal.json"])

    ctx = %{
      workspace: ws,
      session_kind: "workflow",
      write_paths: [staging],
      extra_roots: [ext]
    }

    it = item("edit", %{"file_path" => Path.join(ext, "file.md")})
    refute match?({:allow, _}, PermissionPolicy.decide(it, ctx))
    assert :ask = PermissionPolicy.decide(it, ctx)
  end

  # --- write_roots dir grants (B2) ---
  #
  # `ctx[:write_roots]` grants a whole DIRECTORY, not a single exact path —
  # every write under it (segment boundary, like `read_roots`/`extra_roots`
  # above) auto-allows in a workflow session, alongside the existing exact
  # `write_paths` list. This is how the memory-update flow (B3's Runner)
  # grants a run's `queue/staging/<run_id>/proposals/` dir without knowing
  # every proposal filename up front, while `run.json` (the trusted sidecar
  # one level up) stays untouched by the grant.

  describe "write_roots dir grants" do
    test "workflow write inside a write_root is allowed", %{ws: ws} do
      root = Path.join(ws, "queue/staging/r1/proposals")
      File.mkdir_p!(root)
      ctx = %{workspace: ws, session_kind: "workflow", write_paths: [], write_roots: [root]}
      it = item("write", %{"file_path" => Path.join(root, "a.json")})
      assert {:allow, "allow_once"} = PermissionPolicy.decide(it, ctx)
    end

    test "workflow write to the staging sidecar outside the root asks", %{ws: ws} do
      root = Path.join(ws, "queue/staging/r1/proposals")
      File.mkdir_p!(root)
      ctx = %{workspace: ws, session_kind: "workflow", write_paths: [], write_roots: [root]}
      it = item("write", %{"file_path" => Path.join(ws, "queue/staging/r1/run.json")})
      assert :ask = PermissionPolicy.decide(it, ctx)
    end

    test "chat sessions get no write_roots allowance", %{ws: ws} do
      root = Path.join(ws, "queue/staging/r1/proposals")
      File.mkdir_p!(root)
      ctx = %{workspace: ws, session_kind: "chat", write_paths: [], write_roots: [root]}
      it = item("write", %{"file_path" => Path.join(root, "a.json")})
      assert :ask = PermissionPolicy.decide(it, ctx)
    end

    test "prefix trick does not escape the root", %{ws: ws} do
      root = Path.join(ws, "queue/staging/r1/proposals")
      File.mkdir_p!(root)
      File.mkdir_p!(Path.join(ws, "queue/staging/r1/proposals-evil"))

      ctx = %{workspace: ws, session_kind: "workflow", write_paths: [], write_roots: [root]}

      it =
        item("write", %{
          "file_path" => Path.join(ws, "queue/staging/r1/proposals-evil/a.json")
        })

      assert :ask = PermissionPolicy.decide(it, ctx)
    end
  end
end
