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

  # Every kind in the policy's `@write_kinds` as one item shape — the tool
  # name is immaterial to the path-based tiers, only `kind` is.
  defp write_kind(kind, path),
    do: %{"rawInput" => %{"file_path" => path}, "toolName" => "Write", "kind" => kind}

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

  # `protected_relative?/2` computes the top segment with
  # `Valea.Paths.relative_to/3` (case-FOLDED on Windows) rather than
  # `Path.relative_to/2`, so both halves of the deny — containment and
  # remainder — share one case rule. On Unix that migration must be a pure
  # no-op, and this pins BOTH halves of what "no-op" means here.
  test "unix: the protected top segment is case-folded, the ancestor path is not", %{
    ctx: ctx,
    ws: ws
  } do
    # Half one, unchanged: the explicit `String.downcase/1` on the TOP
    # segment is still the only case-insensitivity in the deny.
    File.mkdir_p!(Path.join(ws, "SECRETS"))
    File.write!(Path.join(ws, "SECRETS/x"), "s")
    assert {:deny, _} = P.decide(read(Path.join(ws, "SECRETS/x")), ctx)

    # Half two, unchanged: an ANCESTOR segment still compares byte-for-byte
    # on Unix, so a case-flipped root yields no remainder at all — exactly
    # what `Path.relative_to/2` did. (On :windows this is the C1 attack: the
    # flip is contained, and the remainder must still be `secrets/x`.)
    flipped = Path.join(Path.dirname(ws), String.upcase(Path.basename(ws)))
    candidate = Path.join(flipped, "secrets/x")
    refute candidate == Path.join(ws, "secrets/x")
    assert Valea.Paths.relative_to(candidate, ws, :unix) == candidate

    # ... whereas on :windows the same flip IS the same directory, and the
    # remainder the deny reads must still be `secrets/x`, not a drive letter.
    assert Valea.Paths.relative_to("C:/Users/Mara/ws/secrets/x", "C:/Users/mara/ws", :windows) ==
             "secrets/x"
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
      for rel <- ["maildir/cur/m1.eml", "views/note.md", "ops/done/op1.yaml", ".account"] do
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
            "views/note.md",
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

  # Spec F Task 5 (calendar-feeds spec §"Mounts and policy"): the calendar
  # deny tier — mail's exact semantics over ONE synthetic mount.
  # `ctx.calendar_in_scope?` (boolean, default false) says whether this
  # session's scope includes the calendar mount; the territory is ALWAYS
  # `<workspace_root>/sources/calendar` (blanket, like mail's
  # `sources/mail` — one mount, no per-slug lists). Precedence: denied tool
  # -> protected -> icm_secret -> mail -> CALENDAR -> escaped -> ask/allow.
  #
  #   1. Unmounted deny: any candidate under `sources/calendar` in a
  #      session WITHOUT the calendar mount is `{:deny, "reject_once"}`,
  #      never a prompt — casefolded (downcase + NFC) on both sides and
  #      symlink-resolved, exactly like the mail tier.
  #   2. Write surface: in scope, write kinds are allowed (grant/ask flow)
  #      ONLY under `valea/events/`; everything else — `.source`,
  #      `feed.ics`, `views/`, stray files, valea's own rendered feed — is
  #      engine-owned and denied, even against a broad write grant.
  #   3. Reads: in scope, EVERYTHING under the territory stays readable via
  #      the ordinary read-root allow (mirrors and views are exactly the
  #      calendar data the session was granted; no spool-like secret area).
  describe "calendar mount rules" do
    setup %{ctx: ctx, ws: ws} do
      cal = Path.join(ws, "sources/calendar")

      for d <- [
            Path.join(cal, "mara/views"),
            Path.join(cal, "valea/events")
          ],
          do: File.mkdir_p!(d)

      File.write!(Path.join(cal, "mara/.source"), "url-ref")
      File.write!(Path.join(cal, "mara/feed.ics"), "BEGIN:VCALENDAR")
      File.write!(Path.join(cal, "mara/views/ev-1.md"), "view")
      File.write!(Path.join(cal, "valea/feed.ics"), "BEGIN:VCALENDAR")
      File.write!(Path.join(cal, "stray.txt"), "stray")

      in_scope_ctx =
        ctx
        |> Map.put(:calendar_in_scope?, true)
        |> Map.update!(:read_roots, &(&1 ++ [cal]))

      out_ctx = Map.put(ctx, :calendar_in_scope?, false)

      %{in_scope: in_scope_ctx, out: out_ctx, cal: cal}
    end

    test "an unmounted session's calendar reads AND writes are denied, not asked", %{
      out: out,
      cal: cal
    } do
      for rel <- ["mara/views/ev-1.md", "mara/feed.ics", "valea/events/x.md", "stray.txt"] do
        assert {:deny, "reject_once"} = P.decide(read(Path.join(cal, rel)), out),
               "expected read deny for #{rel}"
      end

      assert {:deny, "reject_once"} = P.decide(write(Path.join(cal, "valea/events/x.md")), out)
    end

    test "a ctx without the calendar key at all is fail-closed (deny, not ask)", %{
      ctx: ctx,
      cal: cal
    } do
      refute Map.has_key?(ctx, :calendar_in_scope?)
      assert {:deny, "reject_once"} = P.decide(read(Path.join(cal, "mara/views/ev-1.md")), ctx)
    end

    test "case-variant spellings of unmounted calendar territory hit the same deny", %{
      out: out,
      ws: ws
    } do
      assert {:deny, "reject_once"} =
               P.decide(read(Path.join(ws, "sources/CALENDAR/mara/feed.ics")), out)

      assert {:deny, "reject_once"} =
               P.decide(read(Path.join(ws, "sources/calendar/MARA/views/ev-1.md")), out)
    end

    # APFS is normalization-insensitive: an NFD spelling of the same
    # workspace path names the same calendar territory and must hit the
    # same deny — mirrors the mail tier's NFD case.
    test "NFD-variant spellings resolved to the same territory are denied", %{ws: ws} do
      accented = Path.join(ws, "café")
      File.mkdir_p!(Path.join(accented, "sources/calendar/mara"))

      ctx = %{
        workspace_root: accented,
        cwd: accented,
        read_roots: [],
        session_kind: "chat",
        write_paths: [],
        write_roots: [],
        calendar_in_scope?: false
      }

      nfd = :unicode.characters_to_nfd_binary("café")
      candidate = Path.join([ws, nfd, "sources/calendar/mara/feed.ics"])
      assert {:deny, "reject_once"} = P.decide(read(candidate), ctx)
    end

    test "a symlink resolving INTO unmounted calendar territory is denied", %{
      out: out,
      icm: icm,
      cal: cal
    } do
      link = Path.join(icm, "cal-link.md")
      File.ln_s!(Path.join(cal, "mara/feed.ics"), link)

      # `icm` is a granted read_root, but the candidate RESOLVES into
      # calendar territory — the deny keys on the resolved path.
      assert {:deny, "reject_once"} = P.decide(read(link), out)
    end

    test "in-scope reads are allowed everywhere in the territory (views, feeds, events)", %{
      in_scope: in_scope,
      cal: cal
    } do
      for rel <- ["mara/views/ev-1.md", "mara/feed.ics", "valea/feed.ics", "valea/events/x.md"] do
        assert {:allow, "allow_once"} = P.decide(read(Path.join(cal, rel)), in_scope),
               "expected allow for #{rel}"
      end
    end

    test "in-scope writes outside valea/events/ are denied — even with a broad grant", %{
      in_scope: in_scope,
      cal: cal
    } do
      granted = %{in_scope | write_roots: [cal]}

      for rel <- [
            "mara/.source",
            "mara/feed.ics",
            "mara/views/x.md",
            "stray.txt",
            "valea/feed.ics"
          ] do
        assert {:deny, "reject_once"} = P.decide(write(Path.join(cal, rel)), in_scope),
               "expected deny for ungranted write to #{rel}"

        assert {:deny, "reject_once"} = P.decide(write(Path.join(cal, rel)), granted),
               "expected deny for granted write to #{rel}"
      end
    end

    test "in-scope writes under valea/events/ ask without a grant, allow with one", %{
      in_scope: in_scope,
      cal: cal
    } do
      target = Path.join(cal, "valea/events/team-sync.md")
      assert :ask = P.decide(write(target), in_scope)

      granted = %{in_scope | write_roots: [Path.join(cal, "valea/events")]}
      assert {:allow, "allow_once"} = P.decide(write(target), granted)
    end

    test "case-variant writes outside valea/events/ in scope are still denied", %{
      in_scope: in_scope,
      ws: ws
    } do
      assert {:deny, "reject_once"} =
               P.decide(write(Path.join(ws, "sources/calendar/mara/VIEWS/x.md")), in_scope)

      assert {:deny, "reject_once"} =
               P.decide(write(Path.join(ws, "sources/CALENDAR/stray2.txt")), in_scope)
    end

    # Spec F §"Mounts and policy" — EMPTY-WORKSPACE BOOTSTRAP: a fresh
    # template workspace (only `sources/calendar/valea/events/` exists, no
    # external sources, zero events yet) + an opted-in session can create
    # its FIRST `valea/events/` file through the normal write path — never
    # a deny.
    test "empty-workspace bootstrap: the first valea/events write is never denied" do
      tmp = Path.join(System.tmp_dir!(), "pp-cal-boot-#{System.unique_integer([:positive])}")
      ws = Path.join(tmp, "ws")
      icm = Path.join(tmp, "icm")
      events = Path.join(ws, "sources/calendar/valea/events")
      for d <- [events, icm], do: File.mkdir_p!(d)
      on_exit(fn -> File.rm_rf!(tmp) end)

      ctx = %{
        workspace_root: ws,
        cwd: icm,
        read_roots: [icm, Path.join(ws, "sources/calendar")],
        session_kind: "chat",
        write_paths: [],
        write_roots: [],
        calendar_in_scope?: true
      }

      first = Path.join(events, "first-event.md")
      assert :ask = P.decide(write(first), ctx)

      granted = %{ctx | write_roots: [events]}
      assert {:allow, "allow_once"} = P.decide(write(first), granted)
    end

    test "the mail tier is unaffected by an in-scope calendar", %{in_scope: in_scope, ws: ws} do
      # No mail keys in this ctx — mail territory (blanket sources/mail)
      # still denies exactly as before.
      assert {:deny, "reject_once"} =
               P.decide(read(Path.join(ws, "sources/mail/mara/maildir/cur/m1.eml")), in_scope)
    end

    test "non-calendar paths keep their decisions with calendar keys present", %{
      in_scope: in_scope,
      icm: icm
    } do
      assert {:allow, _} = P.decide(read(Path.join(icm, "AGENTS.md")), in_scope)
      assert :ask = P.decide(write(Path.join(icm, "Pricing/x.md")), in_scope)
    end
  end

  # Tasks/schedules spec §"Consent & containment posture" + §"`.valea/` —
  # Valea's namespace inside the ICM" (Task 5): two tiers keyed off
  # `ctx.icm_roots`, both deliberately ahead of the write-ALLOW tier.
  #
  #   1. `.valea/` write-DENY (deny, not ask): the materialized briefing is
  #      an instruction surface and `task-archive.jsonl` is Valea's ledger,
  #      so no agent write lands under `<icm_root>/.valea/` — a broad grant
  #      can never buy it back. Reads stay ordinary.
  #   2. `schedules.json` always-ASK: a write-kind candidate naming an ICM
  #      ROOT's `schedules.json` falls through to `:ask` EVEN when covered
  #      by `write_paths`/`write_roots` — "a broad grant can never buy
  #      schedule registration". Root-level only: `tasks.json` and a nested
  #      `sub/schedules.json` stay ordinary files.
  #
  # Precedence: denied tool -> protected -> icm_secret -> VALEA DIR -> mail
  # -> calendar -> escaped -> SCHEDULES ASK -> ask/allow.
  describe "tasks/schedules consent tiers" do
    @all_write_kinds ["write", "edit", "delete", "move"]

    setup %{ctx: ctx, icm: icm, rel: rel} do
      for d <- [Path.join(icm, ".valea"), Path.join(icm, "sub"), Path.join(rel, ".valea")],
          do: File.mkdir_p!(d)

      File.write!(Path.join(icm, "schedules.json"), "{}")
      File.write!(Path.join(icm, "tasks.json"), "{}")
      File.write!(Path.join(icm, "sub/schedules.json"), "{}")
      File.write!(Path.join(rel, "schedules.json"), "{}")

      # `icm` is the only ICM root here; `rel` stays a granted read_root that
      # is NOT an ICM root, so the "non-ICM roots unaffected" cases are real.
      ctx = Map.put(ctx, :icm_roots, [icm])
      %{ctx: ctx, granted: %{ctx | write_roots: [icm, rel]}}
    end

    test "schedules.json write asks even under a covering write_root grant", %{
      granted: granted,
      icm: icm
    } do
      item = %{
        "kind" => "write",
        "toolName" => "Write",
        "rawInput" => %{"file_path" => Path.join(icm, "schedules.json")}
      }

      assert P.decide(item, granted) == :ask
    end

    test "a case-variant SCHEDULES.JSON asks under the same grant", %{
      granted: granted,
      icm: icm
    } do
      assert :ask = P.decide(write(Path.join(icm, "SCHEDULES.JSON")), granted)
      assert :ask = P.decide(write(Path.join(icm, "Schedules.Json")), granted)
    end

    test "every write kind asks — granted or not", %{ctx: ctx, granted: granted, icm: icm} do
      target = Path.join(icm, "schedules.json")

      for kind <- @all_write_kinds do
        assert :ask = P.decide(write_kind(kind, target), ctx), "expected ask for #{kind}"
        assert :ask = P.decide(write_kind(kind, target), granted), "expected ask for #{kind}"
      end
    end

    test "reading schedules.json is an ordinary allowed read", %{ctx: ctx, icm: icm} do
      assert {:allow, "allow_once"} = P.decide(read(Path.join(icm, "schedules.json")), ctx)
    end

    # Control: the ledger is NOT gated — only schedule REGISTRATION is.
    test "tasks.json under the same grant still allows", %{granted: granted, icm: icm} do
      assert {:allow, "allow_once"} = P.decide(write(Path.join(icm, "tasks.json")), granted)
    end

    # Root-only rule (spec: "at an enabled ICM root") — a nested copy is an
    # ordinary file the grant covers.
    test "a nested sub/schedules.json is not special", %{granted: granted, icm: icm} do
      assert {:allow, "allow_once"} =
               P.decide(write(Path.join(icm, "sub/schedules.json")), granted)
    end

    test ".valea writes are denied for every write kind — even with a broad grant", %{
      ctx: ctx,
      granted: granted,
      icm: icm
    } do
      for rel_path <- [".valea/briefing.md", ".valea/task-archive.jsonl", ".valea/anything/x"] do
        target = Path.join(icm, rel_path)

        for kind <- @all_write_kinds do
          assert {:deny, "reject_once"} = P.decide(write_kind(kind, target), ctx),
                 "expected deny for ungranted #{kind} to #{rel_path}"

          assert {:deny, "reject_once"} = P.decide(write_kind(kind, target), granted),
                 "expected deny for granted #{kind} to #{rel_path}"
        end
      end
    end

    test "a case-variant .VALEA write is denied too", %{granted: granted, icm: icm} do
      assert {:deny, "reject_once"} =
               P.decide(write(Path.join(icm, ".VALEA/briefing.md")), granted)
    end

    test ".valea reads stay ordinary allowed reads", %{ctx: ctx, icm: icm} do
      File.write!(Path.join(icm, ".valea/briefing.md"), "contract")
      assert {:allow, "allow_once"} = P.decide(read(Path.join(icm, ".valea/briefing.md")), ctx)
    end

    # `rel` is a granted read_root/write_root but NOT an `icm_root`: neither
    # tier is scoped to it, so both files keep their ordinary behavior.
    test "the same names outside every icm_root are unaffected", %{granted: granted, rel: rel} do
      assert {:allow, "allow_once"} = P.decide(write(Path.join(rel, "schedules.json")), granted)

      assert {:allow, "allow_once"} =
               P.decide(write(Path.join(rel, ".valea/briefing.md")), granted)
    end

    # Regression pin (spec §"Opaque shell writes"): a `Bash` redirection onto
    # schedules.json yields no extractable candidate, so it lands on the
    # empty-candidates floor — `:ask`, never a vacuous allow.
    test "an item with no extractable candidates still asks", %{granted: granted} do
      bash = %{
        "kind" => "write",
        "toolName" => "Bash",
        "rawInput" => %{"command" => "echo '{}' > schedules.json"}
      }

      assert :ask = P.decide(bash, granted)
    end

    test "the ICM-secrets deny still wins inside .valea", %{granted: granted, icm: icm} do
      assert {:deny, "reject_once"} = P.decide(read(Path.join(icm, ".valea/.env")), granted)
    end

    # An unrecognized/missing `kind` is DENIED under `.valea`, not passed
    # through to a grant — the tier is gated `kind not in @read_kinds`, the
    # same fail-closed shape the mail/calendar territory denies use.
    test "an unknown kind under .valea fails closed", %{granted: granted, icm: icm} do
      target = Path.join(icm, ".valea/briefing.md")

      assert {:deny, "reject_once"} = P.decide(write_kind("some_future_kind", target), granted)
      assert {:deny, "reject_once"} = P.decide(write_kind(nil, target), granted)
    end

    # ORDERING INVARIANT (review fix F1). `icm_roots` deliberately keeps the
    # in-scope mail/calendar roots (`SessionServer.init/1`), so
    # `<mail_root>/schedules.json` is simultaneously an exact match for the
    # schedules ASK tier and a violation of the mail tier's write surface.
    # Deny must win: an ask there would turn a deny-only territory into one
    # generic-looking approval away. These pins fail if the ask tier is ever
    # hoisted above the deny tiers — the only thing that keeps the invariant
    # true is its POSITION in the cond.
    test "a deny still wins over the schedules ask inside a mail root", %{ctx: ctx, ws: ws} do
      mara = Path.join(ws, "sources/mail/mara")
      File.mkdir_p!(Path.join(mara, "drafts"))
      File.write!(Path.join(mara, "schedules.json"), "{}")

      ctx =
        ctx
        |> Map.put(:mail_roots_all, [mara])
        |> Map.put(:mail_roots_in_scope, [mara])
        # Exactly what SessionServer builds: the mail root is BOTH an
        # icm_root (so the secrets deny reaches inside it) and a mail root.
        |> Map.put(:icm_roots, [ctx.cwd, mara])
        |> Map.update!(:read_roots, &(&1 ++ [mara]))

      target = Path.join(mara, "schedules.json")
      assert {:deny, "reject_once"} = P.decide(write(target), ctx)
      assert {:deny, "reject_once"} = P.decide(write(target), %{ctx | write_roots: [mara]})
    end

    test "a deny still wins over the schedules ask inside the calendar territory", %{
      ctx: ctx,
      ws: ws
    } do
      cal = Path.join(ws, "sources/calendar")
      File.mkdir_p!(Path.join(cal, "valea/events"))
      File.write!(Path.join(cal, "schedules.json"), "{}")

      ctx =
        ctx
        |> Map.put(:calendar_in_scope?, true)
        |> Map.put(:icm_roots, [ctx.cwd, cal])
        |> Map.update!(:read_roots, &(&1 ++ [cal]))

      target = Path.join(cal, "schedules.json")
      assert {:deny, "reject_once"} = P.decide(write(target), ctx)
      assert {:deny, "reject_once"} = P.decide(write(target), %{ctx | write_roots: [cal]})
    end

    # The same collision one level in: `.valea/schedules.json` is inside the
    # write-denied namespace. (It is not an EXACT root-join match, so the ask
    # tier never claims it either way — this pins the deny outcome, not the
    # ordering.)
    test "a schedules.json inside .valea is denied", %{granted: granted, icm: icm} do
      assert {:deny, "reject_once"} =
               P.decide(write(Path.join(icm, ".valea/schedules.json")), granted)
    end

    # SYMLINK SHADOWING (review fix F3). Both tiers also test the merely
    # lexically-expanded candidate, so swapping the real path for a symlink
    # into already-granted territory can no longer turn the deny/ask into an
    # allow. Before the fix each of these decided {:allow, "allow_once"}.
    test "a symlinked .valea dir does not defeat the write deny", %{
      granted: granted,
      icm: icm,
      rel: rel
    } do
      shadow = Path.join(rel, "shadow")
      File.mkdir_p!(shadow)
      File.rm_rf!(Path.join(icm, ".valea"))
      File.ln_s!(shadow, Path.join(icm, ".valea"))

      # The symlink target is inside a granted write_root, so the RESOLVED
      # candidate alone would sail through the write-allow tier.
      assert {:deny, "reject_once"} =
               P.decide(write(Path.join(icm, ".valea/briefing.md")), granted)
    end

    test "a symlinked schedules.json does not defeat the ask", %{
      granted: granted,
      icm: icm,
      rel: rel
    } do
      shadow = Path.join(rel, "shadow-schedules.json")
      File.write!(shadow, "{}")
      File.rm!(Path.join(icm, "schedules.json"))
      File.ln_s!(shadow, Path.join(icm, "schedules.json"))

      assert :ask = P.decide(write(Path.join(icm, "schedules.json")), granted)
    end

    # The lexical spelling is additive, not a replacement: a relative
    # candidate that only NAMES the protected path after normalization is
    # caught too (`cwd` is the ICM root).
    test "a relative, dot-segment spelling is caught by both tiers", %{granted: granted} do
      assert {:deny, "reject_once"} = P.decide(write("sub/../.valea/briefing.md"), granted)
      assert :ask = P.decide(write("sub/../schedules.json"), granted)
    end
  end
end
