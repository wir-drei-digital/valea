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

  defp item_for("read", path), do: read(path)
  defp item_for("write", path), do: write(path)

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

  # Task 14: this case used to point at `sources/mail/...` — that whole area
  # is now covered by the mail deny tier (deny-not-ask, see the "mail mount
  # rules" describe below), so the non-mail sources path carries the
  # original "not auto-allowed, falls to ask" intent.
  test "reading the workspace sources is not auto-allowed for a chat", %{ctx: ctx, ws: ws} do
    assert :ask = P.decide(read(Path.join(ws, "sources/notes/1.md")), ctx)
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

  # Regression (Task 6 review, Spec D): the write-allow clause (step 4) was
  # widened to be kind-agnostic, but deny (step 1, `split_protected?/2`)
  # still runs BEFORE write-allow in `decide_split/2`'s `cond`, so an
  # explicit write grant pointing INTO a protected workspace dir (or an
  # `app.sqlite*` db file) must still be denied — a grant can never buy its
  # way past the hard-deny. The deleted legacy suite covered this; nothing
  # in the split suite asserted it, so lock it here.
  test "deny wins over an explicit write grant into a protected path", %{ctx: ctx, ws: ws} do
    protected_log = Path.join(ws, "logs/audit.jsonl")
    db_file = Path.join(ws, "app.sqlite")

    grant = %{ctx | write_paths: [protected_log, db_file]}
    assert {:deny, "reject_once"} = P.decide(write(protected_log), grant)
    assert {:deny, "reject_once"} = P.decide(write(db_file), grant)

    root_grant = %{ctx | write_roots: [Path.join(ws, "logs")]}
    assert {:deny, "reject_once"} = P.decide(write(protected_log), root_grant)
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

  # Spec D §D5: ICM-internal secret material is deny-by-default, checked
  # against `ctx.icm_roots` (primary + related ICM roots) independently of
  # `read_roots`/`write_roots` membership -- deny wins before either
  # allow tier is reached, and before the write-grant/kind checks too.
  describe "ICM-internal secrets deny" do
    setup %{ctx: ctx, icm: icm} do
      %{ctx: Map.put(ctx, :icm_roots, [icm])}
    end

    test "reads and writes under a secrets/ dir are denied at any depth", %{ctx: ctx, icm: icm} do
      for path <- [
            Path.join(icm, "secrets/api_key.txt"),
            Path.join(icm, "clients/kita/secrets/token")
          ] do
        for kind <- ["read", "write"] do
          assert {:deny, "reject_once"} = P.decide(item_for(kind, path), ctx)
        end
      end
    end

    test ".env variants are denied; .env.example is not", %{ctx: ctx, icm: icm} do
      for path <- [Path.join(icm, ".env"), Path.join(icm, "deploy/.env.production")] do
        assert {:deny, "reject_once"} = P.decide(item_for("read", path), ctx)
      end

      refute match?(
               {:deny, _},
               P.decide(item_for("read", Path.join(icm, ".env.example")), ctx)
             )
    end

    test "key material and credentials basenames are denied", %{ctx: ctx, icm: icm} do
      for path <- [
            Path.join(icm, "certs/server.pem"),
            Path.join(icm, "id.key"),
            Path.join(icm, "ops/aws-credentials.json"),
            Path.join(icm, "CREDENTIALS.md")
          ] do
        assert {:deny, "reject_once"} = P.decide(item_for("write", path), ctx)
      end
    end

    test "segment boundaries: lookalike names are not denied", %{ctx: ctx, icm: icm} do
      for path <- [
            Path.join(icm, "mysecrets/notes.md"),
            Path.join(icm, "secretsfoo/x.md"),
            Path.join(icm, "env/.envrc.sample.md")
          ] do
        refute match?({:deny, _}, P.decide(item_for("read", path), ctx))
      end
    end

    test "creating a NEW file under secrets/ is denied (target does not exist yet)", %{
      ctx: ctx,
      icm: icm
    } do
      assert {:deny, "reject_once"} =
               P.decide(item_for("write", Path.join(icm, "secrets/new_key.txt")), ctx)
    end

    # Case-insensitive: on this project's own platform (macOS/APFS,
    # case-insensitive filesystem), `SECRETS/api_key.txt`, `.ENV`,
    # `SERVER.PEM`, `ID.KEY` name the same files the lowercase forms would —
    # the deny must catch them, mirroring `protected_relative?/2`'s
    # case-insensitive dir/basename comparison.
    test "case-variant segments and basenames are denied the same as lowercase", %{
      ctx: ctx,
      icm: icm
    } do
      for path <- [
            Path.join(icm, "SECRETS/api_key.txt"),
            Path.join(icm, "clients/kita/SECRETS/token"),
            Path.join(icm, ".ENV"),
            Path.join(icm, "deploy/.ENV.PRODUCTION"),
            Path.join(icm, "certs/SERVER.PEM"),
            Path.join(icm, "ID.KEY"),
            Path.join(icm, "CREDENTIALS.md")
          ] do
        assert {:deny, "reject_once"} = P.decide(item_for("read", path), ctx)
      end
    end

    test "case-variant .ENV.EXAMPLE is not denied", %{ctx: ctx, icm: icm} do
      refute match?(
               {:deny, _},
               P.decide(item_for("read", Path.join(icm, ".ENV.EXAMPLE")), ctx)
             )
    end

    # `rel` is a granted read_root (present in `read_roots`) but is NOT part
    # of `icm_roots` in this ctx (only the primary `icm` root is) -- the new
    # secrets clause is scoped to `icm_roots`, not to every read_root, so a
    # `.env` basename there keeps its pre-Task-8 behavior: an ordinary
    # allowed read.
    test "the same basenames outside any icm_root keep their old behavior", %{
      ctx: ctx,
      rel: rel
    } do
      assert {:allow, _} = P.decide(item_for("read", Path.join(rel, ".env")), ctx)
    end
  end

  # Task 14 (mail-maildir spec §"Mount & containment" / §"Safety
  # invariants"): the mail deny tier. `ctx.mail_roots_all` is every
  # `sources/mail/<slug>` root; `ctx.mail_roots_in_scope` is the subset this
  # session's scope actually includes. Precedence: denied tool -> protected
  # -> icm_secret -> MAIL RULES -> escaped -> ask/allow.
  #
  #   1. Unmounted deny: any candidate under mail territory (a
  #      `mail_roots_all` root, or anything else under
  #      `<workspace_root>/sources/mail` — spec: "covering all of
  #      sources/mail/") that is NOT under an in-scope root is
  #      `{:deny, "reject_once"}` — never a prompt. Matching is casefolded
  #      (downcase + NFC) on BOTH sides: APFS is case- and
  #      normalization-insensitive, so `sources/MAIL/...` and NFD-variant
  #      spellings name the same mailbox.
  #   2. Write surface: within an in-scope mail root, writes are allowed
  #      (grant/ask flow) ONLY under `ops/pending/` and `drafts/`; anywhere
  #      else in the mail root they are denied. Reads: `spool/` is denied;
  #      everything else in scope stays readable.
  describe "mail mount rules" do
    setup %{ctx: ctx, ws: ws} do
      mara = Path.join(ws, "sources/mail/mara")
      work = Path.join(ws, "sources/mail/work")

      for d <- [
            Path.join(mara, "maildir/cur"),
            Path.join(mara, "ops/pending"),
            Path.join(mara, "drafts"),
            Path.join(mara, "spool"),
            Path.join(work, "maildir/cur")
          ],
          do: File.mkdir_p!(d)

      ctx =
        ctx
        |> Map.put(:mail_roots_all, [mara, work])
        |> Map.put(:mail_roots_in_scope, [mara])
        |> Map.update!(:read_roots, &(&1 ++ [mara]))

      %{ctx: ctx, mara: mara, work: work}
    end

    test "reading an unmounted account is denied, not asked", %{ctx: ctx, work: work} do
      assert {:deny, "reject_once"} =
               P.decide(read(Path.join(work, "maildir/cur/m1.eml")), ctx)

      assert {:deny, "reject_once"} = P.decide(write(Path.join(work, "drafts/x.md")), ctx)
    end

    test "case-variant spellings of an unmounted account hit the same deny", %{
      ctx: ctx,
      ws: ws
    } do
      assert {:deny, "reject_once"} =
               P.decide(read(Path.join(ws, "sources/MAIL/work/maildir/cur/m1.eml")), ctx)

      assert {:deny, "reject_once"} =
               P.decide(read(Path.join(ws, "sources/mail/WORK/maildir/cur/m1.eml")), ctx)
    end

    # APFS is normalization-insensitive: an NFD spelling of the same
    # workspace path names the same mailbox and must hit the same deny.
    test "NFD-variant spellings resolved to the same root are denied", %{ws: ws} do
      accented = Path.join(ws, "café")
      mail_root = Path.join(accented, "sources/mail/work")
      File.mkdir_p!(mail_root)

      ctx = %{
        workspace_root: accented,
        cwd: accented,
        read_roots: [],
        session_kind: "chat",
        write_paths: [],
        write_roots: [],
        mail_roots_all: [mail_root],
        mail_roots_in_scope: []
      }

      nfd = :unicode.characters_to_nfd_binary("café")
      candidate = Path.join([ws, nfd, "sources/mail/work/maildir/cur/m1.eml"])
      assert {:deny, "reject_once"} = P.decide(read(candidate), ctx)
    end

    test "anything else under sources/mail (no configured account) is denied too", %{
      ctx: ctx,
      ws: ws
    } do
      assert {:deny, "reject_once"} =
               P.decide(read(Path.join(ws, "sources/mail/stale-account/maildir/x")), ctx)
    end

    test "in-scope reads of maildir/views/ops/done/.account are allowed", %{
      ctx: ctx,
      mara: mara
    } do
      for rel <- ["maildir/cur/m1.eml", "views/inbox.md", "ops/done/op1.yaml", ".account"] do
        assert {:allow, "allow_once"} = P.decide(read(Path.join(mara, rel)), ctx),
               "expected allow for #{rel}"
      end
    end

    test "in-scope spool/ reads are denied", %{ctx: ctx, mara: mara} do
      assert {:deny, "reject_once"} = P.decide(read(Path.join(mara, "spool/m.eml")), ctx)
    end

    test "in-scope writes to ops/pending and drafts ask without a grant, allow with one", %{
      ctx: ctx,
      mara: mara
    } do
      assert :ask = P.decide(write(Path.join(mara, "ops/pending/cleanup.yaml")), ctx)
      assert :ask = P.decide(write(Path.join(mara, "drafts/reply.md")), ctx)

      granted = %{ctx | write_roots: [Path.join(mara, "ops/pending"), Path.join(mara, "drafts")]}

      assert {:allow, "allow_once"} =
               P.decide(write(Path.join(mara, "ops/pending/cleanup.yaml")), granted)

      assert {:allow, "allow_once"} = P.decide(write(Path.join(mara, "drafts/reply.md")), granted)
    end

    test "in-scope writes anywhere else in the mail root are denied — even with a broad grant", %{
      ctx: ctx,
      mara: mara
    } do
      granted = %{ctx | write_roots: [mara]}

      for rel <- [
            "maildir/cur/f.eml",
            "views/inbox.md",
            "ops/done/op1.yaml",
            "quarantine/x",
            ".account",
            "spool/m.eml"
          ] do
        assert {:deny, "reject_once"} = P.decide(write(Path.join(mara, rel)), ctx),
               "expected deny for ungranted write to #{rel}"

        assert {:deny, "reject_once"} = P.decide(write(Path.join(mara, rel)), granted),
               "expected deny for granted write to #{rel}"
      end
    end

    test "the ICM-secrets deny still wins inside a mail root", %{ctx: ctx, mara: mara} do
      ctx = Map.put(ctx, :icm_roots, [mara])
      assert {:deny, "reject_once"} = P.decide(read(Path.join(mara, "drafts/.env")), ctx)
      assert {:deny, "reject_once"} = P.decide(write(Path.join(mara, "drafts/.env")), ctx)
    end

    test "a ctx without mail keys keeps non-mail decisions unchanged", %{icm: icm} do
      ctx = %{
        workspace_root: "/nonexistent-ws",
        cwd: icm,
        read_roots: [icm],
        session_kind: "chat",
        write_paths: [],
        write_roots: []
      }

      assert {:allow, _} = P.decide(read(Path.join(icm, "AGENTS.md")), ctx)
    end
  end
end
