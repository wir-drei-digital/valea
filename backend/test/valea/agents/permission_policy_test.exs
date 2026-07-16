# The `workspace_root` / `cwd` / `read_roots` (absolute) split contract is
# the ONLY contract `PermissionPolicy.decide/2` implements (the legacy,
# workspace-relative `ctx.workspace`/`ctx.extra_roots` shape and its
# dedicated dispatch branch were deleted in Task 6 of Spec D, once
# `SessionServer` — the only caller — was confirmed to always build this
# shape). `read_roots` is an absolute list (primary root + related roots +
# exact task inputs), `cwd` is the absolute primary ICM root relative
# candidates resolve against, and `workspace_root` is the absolute base the
# protected-dir deny-list checks against.
defmodule Valea.Agents.PermissionPolicySplitTest do
  use ExUnit.Case, async: true
  alias Valea.Agents.PermissionPolicy, as: P

  setup do
    tmp = Path.join(System.tmp_dir!(), "pp-#{System.unique_integer([:positive])}")
    ws = Path.join(tmp, "ws")
    icm = Path.join(tmp, "icm")
    rel = Path.join(tmp, "related")

    for d <- [Path.join(ws, "logs"), Path.join(ws, "secrets"), icm, rel, Path.join(ws, "sources")],
        do: File.mkdir_p!(d)

    File.write!(Path.join(icm, "AGENTS.md"), "x")
    File.write!(Path.join(rel, "CONTEXT.md"), "x")
    on_exit(fn -> File.rm_rf!(tmp) end)

    %{
      ctx: %{
        workspace_root: ws,
        cwd: icm,
        read_roots: [icm, rel],
        session_kind: "chat",
        write_paths: [],
        write_roots: []
      },
      ws: ws,
      icm: icm,
      rel: rel
    }
  end

  defp read(path),
    do: %{"rawInput" => %{"file_path" => path}, "toolName" => "Read", "kind" => "read"}

  defp write(path),
    do: %{"rawInput" => %{"file_path" => path}, "toolName" => "Write", "kind" => "write"}

  test "relative read resolves against the primary ICM cwd, not the workspace", %{ctx: ctx} do
    # resolves under cwd == icm
    assert {:allow, _} = P.decide(read("AGENTS.md"), ctx)
  end

  test "reads in a related root are allowed", %{ctx: ctx, rel: rel} do
    assert {:allow, _} = P.decide(read(Path.join(rel, "CONTEXT.md")), ctx)
  end

  test "workspace operational state is denied", %{ctx: ctx, ws: ws} do
    assert {:deny, _} = P.decide(read(Path.join(ws, "logs/audit.jsonl")), ctx)
    assert {:deny, _} = P.decide(read(Path.join(ws, "secrets/x")), ctx)
  end

  test "workspace app.sqlite* files are still hard-denied", %{ctx: ctx, ws: ws} do
    assert {:deny, _} = P.decide(read(Path.join(ws, "app.sqlite")), ctx)
    assert {:deny, _} = P.decide(read(Path.join(ws, "app.sqlite-wal")), ctx)
  end

  # Regression: `split_protected?/2`'s db-prefix clause used to run on the
  # basename regardless of whether the resolved candidate was actually under
  # `workspace_root` — so ANY file whose basename started with `app.sqlite`
  # was hard-denied, even inside a legitimately-granted `read_root` outside
  # the workspace entirely. The spec scopes that deny to
  # `<workspace_root>/app.sqlite*` only; a related-root file merely named
  # `app.sqlite*` must fall through to the ordinary read-root allow instead.
  test "a related read_root file merely named app.sqlite* is not hard-denied", %{
    ctx: ctx,
    rel: rel
  } do
    File.write!(Path.join(rel, "app.sqlite.md"), "hi")
    File.write!(Path.join(rel, "app.sqlite"), "hi")

    refute match?({:deny, _}, P.decide(read(Path.join(rel, "app.sqlite.md")), ctx))
    refute match?({:deny, _}, P.decide(read(Path.join(rel, "app.sqlite")), ctx))
    assert {:allow, _} = P.decide(read(Path.join(rel, "app.sqlite.md")), ctx)
    assert {:allow, _} = P.decide(read(Path.join(rel, "app.sqlite")), ctx)
  end

  test "reading the workspace sources is not auto-allowed for a chat", %{ctx: ctx, ws: ws} do
    assert :ask = P.decide(read(Path.join(ws, "sources/mail/messages/1.md")), ctx)
  end

  test "chat writes ask without a grant; a populated grant allows the contained write", %{
    ctx: ctx,
    icm: icm
  } do
    assert :ask = P.decide(write(Path.join(icm, "Pricing/x.md")), ctx)
    # `ctx` is already `session_kind: "chat"` — write grants are honored for
    # ANY session kind now (Task 6: the `session_kind == "workflow"` conjunct
    # was dropped from the write-allow cond clause), not just "workflow".
    grant = %{ctx | write_paths: [Path.join(icm, "out.json")]}
    assert {:allow, "allow_once"} = P.decide(write(Path.join(icm, "out.json")), grant)
  end

  test "a write outside every grant still asks even when other grants exist", %{
    ctx: ctx,
    icm: icm
  } do
    grant = %{ctx | write_paths: [Path.join(icm, "out.json")]}
    assert :ask = P.decide(write(Path.join(icm, "other.json")), grant)
  end

  # Regression (Task 6, Spec D §A/§B): write grants are minted only by
  # Valea's own SessionScope callers — never by the agent — so honoring them
  # for any `session_kind` cannot widen what an agent can reach; it only
  # drops a redundant, no-longer-meaningful kind check now that nothing
  # creates `kind: "workflow"` sessions.
  test "write grants are honored regardless of session kind", %{ctx: ctx, icm: icm} do
    grant = %{ctx | session_kind: "some_future_kind", write_paths: [Path.join(icm, "out.json")]}
    assert {:allow, "allow_once"} = P.decide(write(Path.join(icm, "out.json")), grant)
  end

  test "a related root that is not granted is denied on symlink escape", %{ctx: ctx} do
    assert {:deny, _} = P.decide(read("/etc/passwd"), ctx)
  end

  test "root instruction files resolve against the primary ICM cwd, not the workspace", %{
    ctx: ctx
  } do
    # @root_files, now cwd == ICM-relative
    assert {:allow, _} = P.decide(read("CLAUDE.md"), ctx)
  end
end
