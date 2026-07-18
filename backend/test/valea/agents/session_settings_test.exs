defmodule Valea.Agents.SessionSettingsTest do
  use ExUnit.Case, async: true

  alias Valea.Agents.SessionSettings

  defp scope(overrides) do
    Map.merge(
      %{
        workspace: %{id: "ws", root: "/ws", name: "W", generation: 1},
        primary_icm: %{mount_key: "coaching", id: "icm-1", root: "/icms/coaching", manifest: nil},
        related_icms: [
          %{
            mount_key: "legal",
            id: "icm-2",
            root: "/icms/legal",
            entrypoint: "CONTEXT.md",
            manifest: nil
          }
        ],
        cwd: "/icms/coaching",
        read_paths: [],
        write_paths: [],
        write_roots: [],
        managed_settings: nil,
        managed_context: nil,
        kind: "chat"
      },
      overrides
    )
  end

  test "allows reads in primary and related ICM roots as absolute globs" do
    perms = SessionSettings.content(scope(%{}))["permissions"]
    assert "Read(/icms/coaching/**)" in perms["allow"]
    assert "Read(/icms/legal/**)" in perms["allow"]
  end

  test "asks for edit/write/bash" do
    perms = SessionSettings.content(scope(%{}))["permissions"]
    assert "Write" in perms["ask"]
    assert "Edit" in perms["ask"]
    assert "Bash" in perms["ask"]
  end

  test "denies workspace operational state and web tools" do
    perms = SessionSettings.content(scope(%{}))["permissions"]

    for glob <- [
          "Read(/ws/logs/**)",
          "Read(/ws/config/**)",
          "Read(/ws/secrets/**)",
          "Read(/ws/runtime/**)",
          "Read(/ws/.git/**)",
          "Read(/ws/app.sqlite)"
        ] do
      assert glob in perms["deny"], "expected deny to include #{glob}"
    end

    assert "WebFetch" in perms["deny"]
    assert "WebSearch" in perms["deny"]
  end

  # Spec D §D5: the managedSettings mirror of PermissionPolicy's ICM-internal
  # secrets deny (Task 8). Globs can't express the `.env.example` exception,
  # so `.env.*` is denied wholesale here — strictly more restrictive than
  # the policy layer, by design (see the comment in `content/1`).
  test "denies ICM-internal secret patterns for both primary and related roots" do
    perms = SessionSettings.content(scope(%{}))["permissions"]

    for root <- ["/icms/coaching", "/icms/legal"] do
      for glob <- [
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
          ] do
        for op <- ["Read", "Edit", "Write"] do
          entry = "#{op}(#{glob})"
          assert entry in perms["deny"], "expected deny to include #{entry}"
        end
      end
    end
  end

  test "grants exact task input reads and exact workflow write paths/roots" do
    perms =
      SessionSettings.content(
        scope(%{
          read_paths: ["/ws/sources/notes/messages/42.md"],
          write_paths: ["/ws/queue/staging/r1/proposal.json"],
          write_roots: ["/ws/queue/staging/r1/proposals"]
        })
      )["permissions"]

    assert "Read(/ws/sources/notes/messages/42.md)" in perms["allow"]
    assert "Write(/ws/queue/staging/r1/proposal.json)" in perms["allow"]
    assert "Write(/ws/queue/staging/r1/proposals/**)" in perms["allow"]
  end

  test "context.md lists primary and related roots" do
    md = SessionSettings.context(scope(%{}))
    assert md =~ "/icms/coaching"
    assert md =~ "/icms/legal"
    assert md =~ "CONTEXT.md"
  end

  # Task 14 (mail-maildir spec §"Mount & containment"): the managedSettings
  # mirror of PermissionPolicy's mail deny tier. Globs are case-SENSITIVE
  # here — the authoritative, casefolded enforcement is PermissionPolicy's
  # mail tier; this mirror is defense-in-depth on top of it, exactly like
  # the ICM-secrets mirror above.
  describe "mail mount mirror" do
    defp mail_scope do
      scope(%{
        related_icms: [
          %{
            mount_key: "mail-mara",
            id: nil,
            root: "/ws/sources/mail/mara",
            entrypoint: nil,
            manifest: nil,
            kind: :mail
          }
        ],
        mail_roots_all: ["/ws/sources/mail/mara", "/ws/sources/mail/work"],
        mail_roots_in_scope: ["/ws/sources/mail/mara"]
      })
    end

    test "an in-scope mail root gets the narrowed write surface and a spool read+write deny" do
      perms = SessionSettings.content(mail_scope())["permissions"]

      # In scope: readable at all (the related-root allow)...
      assert "Read(/ws/sources/mail/mara/**)" in perms["allow"]

      # ...but spool/ is denied outright, read and write.
      for op <- ["Read", "Edit", "Write"] do
        assert "#{op}(/ws/sources/mail/mara/spool/**)" in perms["deny"]
      end

      # Engine-owned subtrees + identity + audit trail: write-denied,
      # readable (no Read deny).
      for pattern <- ["maildir/**", "views/**", "quarantine/**", ".account", "ops/done/**"] do
        for op <- ["Edit", "Write"] do
          entry = "#{op}(/ws/sources/mail/mara/#{pattern})"
          assert entry in perms["deny"], "expected deny to include #{entry}"
        end

        refute "Read(/ws/sources/mail/mara/#{pattern})" in perms["deny"]
      end

      # The agent-writable surface carries NO deny globs.
      refute Enum.any?(perms["deny"], &String.contains?(&1, "mara/ops/pending"))
      refute Enum.any?(perms["deny"], &String.contains?(&1, "mara/drafts"))
    end

    test "a NOT-in-scope mail root is denied wholesale over Read+Edit+Write" do
      perms = SessionSettings.content(mail_scope())["permissions"]

      for op <- ["Read", "Edit", "Write"] do
        assert "#{op}(/ws/sources/mail/work/**)" in perms["deny"]
      end

      refute "Read(/ws/sources/mail/work/**)" in perms["allow"]
    end

    test "the ICM-secrets mirror covers an in-scope mail root too (drafts/.env)" do
      perms = SessionSettings.content(mail_scope())["permissions"]
      assert "Read(/ws/sources/mail/mara/**/.env)" in perms["deny"]
    end

    test "a scope without mail keys renders exactly as before" do
      assert SessionSettings.content(scope(%{})) |> is_map()

      refute Enum.any?(
               SessionSettings.content(scope(%{}))["permissions"]["deny"],
               &String.contains?(&1, "sources/mail")
             )
    end

    test "context.md renders a mail related entry without a nil entrypoint" do
      md = SessionSettings.context(mail_scope())
      assert md =~ "mail-mara"
      refute md =~ "entrypoint \n"
      refute md =~ "— entrypoint\n"
    end
  end

  # Spec F Task 5 (calendar spec §"Mounts and policy"): the managedSettings
  # mirror of PermissionPolicy's calendar tier. Same defense-in-depth
  # posture as the mail mirror above (case-sensitive globs; the casefolded,
  # authoritative gate is the policy). Out of scope: `sources/calendar/**`
  # denied over Read+Edit+Write. In scope: "everything except
  # `valea/events/**` is write-denied" is mirrored by ENUMERATION at
  # settings-build time — deny always beats allow in the settings model, so
  # the exception cannot be carved with an allow rule: one Edit+Write deny
  # per (configured slug ∪ on-disk dir/file) except `valea`, plus
  # NON-recursive denies on `sources/calendar/*` and
  # `sources/calendar/valea/*` (stray top-level files and valea's own
  # engine-owned files; `valea/events/*` matches neither glob).
  describe "calendar mount mirror" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "vss-cal-#{System.unique_integer([:positive])}")
      ws = Path.join(tmp, "ws")
      cal = Path.join(ws, "sources/calendar")

      File.mkdir_p!(Path.join(ws, "config"))

      # `mara` is configured AND on disk (with a crash-leftover views dir);
      # `ghost` is configured but has no directory yet; `oldacct` was
      # removed from config but its directory was never purged; `stray.txt`
      # is a stray top-level file.
      File.write!(Path.join(ws, "config/calendar.yaml"), """
      version: 1
      sources:
        mara:
          name: "Mara"
        ghost:
          name: "Ghost"
      """)

      for d <- [
            Path.join(cal, "mara/views/events"),
            Path.join(cal, "mara/views.tmp-crash/events"),
            Path.join(cal, "oldacct/views"),
            Path.join(cal, "valea/events")
          ],
          do: File.mkdir_p!(d)

      File.write!(Path.join(cal, "stray.txt"), "stray")
      on_exit(fn -> File.rm_rf!(tmp) end)

      %{ws: ws, cal: cal}
    end

    defp calendar_scope(ws, cal, in_scope?) do
      related =
        if in_scope? do
          [
            %{
              mount_key: "calendar",
              id: nil,
              root: cal,
              entrypoint: nil,
              manifest: nil,
              kind: :calendar
            }
          ]
        else
          []
        end

      scope(%{
        workspace: %{id: "ws", root: ws, name: "W", generation: 1},
        related_icms: related,
        calendar_in_scope: in_scope?
      })
    end

    test "in scope: every enumerated name except valea is write-denied wholesale", %{
      ws: ws,
      cal: cal
    } do
      perms = SessionSettings.content(calendar_scope(ws, cal, true))["permissions"]

      # Readable at all (the related-root allow), and NO read deny in scope.
      assert "Read(#{cal}/**)" in perms["allow"]
      refute "Read(#{cal}/**)" in perms["deny"]

      # Configured slugs (present or not) AND on-disk leftovers — the
      # per-directory glob covers `.source`, `feed.ics`, `views/**`, crash
      # leftovers like `views.tmp-*`, everything.
      for name <- ["mara", "ghost", "oldacct"], op <- ["Edit", "Write"] do
        entry = "#{op}(#{cal}/#{name}/**)"
        assert entry in perms["deny"], "expected deny to include #{entry}"
      end

      # Stray top-level files + valea's own engine-owned files: the two
      # NON-recursive denies.
      for pattern <- ["*", "valea/*"], op <- ["Edit", "Write"] do
        entry = "#{op}(#{cal}/#{pattern})"
        assert entry in perms["deny"], "expected deny to include #{entry}"
      end

      # The agent-writable surface: nothing denies valea/events, and no
      # wholesale valea/** deny sneaks in.
      refute Enum.any?(perms["deny"], &String.contains?(&1, "valea/events"))
      refute "Edit(#{cal}/valea/**)" in perms["deny"]
      refute "Write(#{cal}/valea/**)" in perms["deny"]
    end

    test "out of scope: the whole territory is denied over Read+Edit+Write", %{
      ws: ws,
      cal: cal
    } do
      perms = SessionSettings.content(calendar_scope(ws, cal, false))["permissions"]

      for op <- ["Read", "Edit", "Write"] do
        assert "#{op}(#{cal}/**)" in perms["deny"]
      end

      refute "Read(#{cal}/**)" in perms["allow"]
    end

    test "a scope with no calendar keys at all still carries the out-of-scope territory deny" do
      perms = SessionSettings.content(scope(%{}))["permissions"]
      assert "Read(/ws/sources/calendar/**)" in perms["deny"]
      assert "Write(/ws/sources/calendar/**)" in perms["deny"]
    end

    test "context.md renders a calendar related entry naming the write surface", %{
      ws: ws,
      cal: cal
    } do
      md = SessionSettings.context(calendar_scope(ws, cal, true))
      assert md =~ "calendar"
      assert md =~ "valea/events/"
      refute md =~ "entrypoint \n"
    end
  end

  # Spec §"Safety invariants" — the RPC trust boundary: agent sessions speak
  # ACP only. Beyond the launch-directive assertions in
  # `session_scope_test.exs`, grep-assert that neither the session server
  # nor the harness adapter ever references the loopback RPC path — nothing
  # to leak into the child process env even by accident.
  test "session_server and the harness adapter never reference the /rpc/run surface" do
    for source <- [
          "lib/valea/agents/session_server.ex",
          "lib/valea/harnesses/claude_code.ex",
          "lib/valea/agents/env.ex"
        ] do
      content = File.read!(Path.expand(source))
      refute content =~ "/rpc/run", "#{source} must not reference the RPC endpoint"
      refute content =~ "x-valea-token", "#{source} must not reference the control token header"
      refute content =~ "control_token", "#{source} must not reference the control token"
    end

    # The env allowlist is fixed and carries no Valea control-plane keys.
    refute Enum.any?(Valea.Agents.Env.allowlist(), &String.starts_with?(&1, "VALEA"))
  end

  test "materialize! writes only context.md (posture is in-memory), never inside an ICM root" do
    tmp = Path.join(System.tmp_dir!(), "vss-#{System.unique_integer([:positive])}")
    icm = Path.join(tmp, "icm")
    File.mkdir_p!(icm)
    context = Path.join([tmp, "ws", "runtime", "sessions", "s1", "context.md"])

    :ok =
      SessionSettings.materialize!(
        scope(%{
          primary_icm: %{mount_key: "c", id: "i", root: icm, manifest: nil},
          cwd: icm,
          related_icms: [],
          managed_context: context
        })
      )

    assert File.exists?(context)
    refute File.exists?(Path.join([tmp, "ws", "runtime", "sessions", "s1", "settings.json"]))
    assert File.dir?(Path.join(icm, ".claude")) == false
    on_exit(fn -> File.rm_rf!(tmp) end)
  end
end
