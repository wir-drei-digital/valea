defmodule Valea.Mounts.ContextTest do
  use ExUnit.Case, async: false

  alias Valea.Mounts
  alias Valea.Mounts.Context
  alias Valea.Workspace.Manager

  setup do
    dir = Path.join(System.tmp_dir!(), "valea-ctx-#{System.unique_integer([:positive])}")
    System.put_env("VALEA_APP_DIR", dir)
    Manager.close()
    {:ok, ws} = Manager.create("W")

    on_exit(fn ->
      Manager.close()
      File.rm_rf!(dir)
    end)

    %{ws: ws.path, home: dir}
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

  defp write_context!(root, body) do
    File.write!(Path.join(root, "CONTEXT.md"), body)
  end

  defp real!(path) do
    expanded = Path.expand(path)
    {:ok, resolved} = Valea.Paths.resolve_real(expanded, expanded)
    resolved
  end

  test "resolves a directly-declared, enabled, healthy related ICM with the default entrypoint",
       %{ws: ws, home: home} do
    primary_root = icm!(home, "Coaching", "6f9f0c9e-3ccd-4fa5-a219-113a70618b55")
    related_root = icm!(home, "Legal", "31201697-cff8-4d99-9dc5-b140e4178716")

    write_icms(ws, """
      coaching:
        path: #{primary_root}
      legal:
        path: #{related_root}
    """)

    write_context!(primary_root, """
    ---
    format: 1
    related_icms:
      - id: 31201697-cff8-4d99-9dc5-b140e4178716
        name: "Legal & Administration"
    ---
    # Coaching context
    """)

    primary = Mounts.mount_by_key(ws, "coaching")
    result = Context.resolve(ws, primary)
    related_real = real!(related_root)

    assert result.issues == []

    assert [
             %{
               mount_key: "legal",
               id: "31201697-cff8-4d99-9dc5-b140e4178716",
               root: ^related_real,
               entrypoint: entrypoint,
               manifest: %Valea.Mounts.Manifest{}
             }
           ] = result.related

    assert entrypoint == Path.join(related_real, "CONTEXT.md")
  end

  test "an explicit non-default entrypoint resolves relative to the related ICM's root", %{
    ws: ws,
    home: home
  } do
    primary_root = icm!(home, "Coaching", "6f9f0c9e-3ccd-4fa5-a219-113a70618b55")
    related_root = icm!(home, "Legal", "31201697-cff8-4d99-9dc5-b140e4178716")
    File.mkdir_p!(Path.join(related_root, "Intake"))

    write_icms(ws, """
      coaching:
        path: #{primary_root}
      legal:
        path: #{related_root}
    """)

    write_context!(primary_root, """
    ---
    format: 1
    related_icms:
      - id: 31201697-cff8-4d99-9dc5-b140e4178716
        name: "Legal"
        entrypoint: Intake/START.md
    ---
    """)

    primary = Mounts.mount_by_key(ws, "coaching")
    result = Context.resolve(ws, primary)
    related_real = real!(related_root)

    assert [%{entrypoint: entrypoint}] = result.related
    assert entrypoint == Path.join([related_real, "Intake", "START.md"])
  end

  test "a declared id that isn't mounted anywhere yields a :not_mounted issue", %{
    ws: ws,
    home: home
  } do
    primary_root = icm!(home, "Coaching", "6f9f0c9e-3ccd-4fa5-a219-113a70618b55")
    write_icms(ws, "  coaching:\n    path: #{primary_root}\n")

    write_context!(primary_root, """
    ---
    format: 1
    related_icms:
      - id: "00000000-0000-0000-0000-000000000000"
        name: "Ghost"
    ---
    """)

    primary = Mounts.mount_by_key(ws, "coaching")
    result = Context.resolve(ws, primary)

    assert result.related == []

    assert [
             %{
               id: "00000000-0000-0000-0000-000000000000",
               name: "Ghost",
               reason: :not_mounted
             }
           ] = result.issues
  end

  test "an entrypoint escaping the related ICM root is rejected, never granted", %{
    ws: ws,
    home: home
  } do
    primary_root = icm!(home, "Coaching", "6f9f0c9e-3ccd-4fa5-a219-113a70618b55")
    related_root = icm!(home, "Legal", "31201697-cff8-4d99-9dc5-b140e4178716")

    write_icms(ws, """
      coaching:
        path: #{primary_root}
      legal:
        path: #{related_root}
    """)

    write_context!(primary_root, """
    ---
    format: 1
    related_icms:
      - id: 31201697-cff8-4d99-9dc5-b140e4178716
        name: "Legal"
        entrypoint: "../escape/CONTEXT.md"
    ---
    """)

    primary = Mounts.mount_by_key(ws, "coaching")
    result = Context.resolve(ws, primary)

    assert result.related == []

    assert [
             %{
               id: "31201697-cff8-4d99-9dc5-b140e4178716",
               name: "Legal",
               reason: :entrypoint_escapes
             }
           ] = result.issues
  end

  test "a declared id whose only mount is disabled yields a :disabled issue", %{
    ws: ws,
    home: home
  } do
    primary_root = icm!(home, "Coaching", "6f9f0c9e-3ccd-4fa5-a219-113a70618b55")
    related_root = icm!(home, "Legal", "31201697-cff8-4d99-9dc5-b140e4178716")

    write_icms(ws, """
      coaching:
        path: #{primary_root}
      legal:
        path: #{related_root}
        enabled: false
    """)

    write_context!(primary_root, """
    ---
    format: 1
    related_icms:
      - id: 31201697-cff8-4d99-9dc5-b140e4178716
        name: "Legal"
    ---
    """)

    primary = Mounts.mount_by_key(ws, "coaching")
    result = Context.resolve(ws, primary)

    assert result.related == []
    assert [%{reason: :disabled}] = result.issues
  end

  test "a declared id whose only mount is degraded (duplicate physical root) yields a :degraded issue",
       %{ws: ws, home: home} do
    primary_root = icm!(home, "Coaching", "6f9f0c9e-3ccd-4fa5-a219-113a70618b55")
    related_root = icm!(home, "Legal", "31201697-cff8-4d99-9dc5-b140e4178716")

    write_icms(ws, """
      coaching:
        path: #{primary_root}
      legal:
        path: #{related_root}
      legal-dup:
        path: #{related_root}
    """)

    write_context!(primary_root, """
    ---
    format: 1
    related_icms:
      - id: 31201697-cff8-4d99-9dc5-b140e4178716
        name: "Legal"
    ---
    """)

    primary = Mounts.mount_by_key(ws, "coaching")
    result = Context.resolve(ws, primary)

    assert result.related == []
    assert [%{reason: :degraded}] = result.issues
  end

  test "a declared id ambiguous across two mounts yields a :duplicate_id issue", %{
    ws: ws,
    home: home
  } do
    primary_root = icm!(home, "Coaching", "6f9f0c9e-3ccd-4fa5-a219-113a70618b55")
    a = icm!(home, "Legal-A", "31201697-cff8-4d99-9dc5-b140e4178716")
    b = icm!(home, "Legal-B", "31201697-cff8-4d99-9dc5-b140e4178716")

    write_icms(ws, """
      coaching:
        path: #{primary_root}
      legal-a:
        path: #{a}
      legal-b:
        path: #{b}
    """)

    write_context!(primary_root, """
    ---
    format: 1
    related_icms:
      - id: 31201697-cff8-4d99-9dc5-b140e4178716
        name: "Legal"
    ---
    """)

    primary = Mounts.mount_by_key(ws, "coaching")
    result = Context.resolve(ws, primary)

    assert result.related == []
    assert [%{reason: :duplicate_id}] = result.issues
  end

  test "a missing CONTEXT.md yields %{related: [], issues: []}", %{ws: ws, home: home} do
    primary_root = icm!(home, "Coaching", "6f9f0c9e-3ccd-4fa5-a219-113a70618b55")
    write_icms(ws, "  coaching:\n    path: #{primary_root}\n")

    primary = Mounts.mount_by_key(ws, "coaching")
    assert Context.resolve(ws, primary) == %{related: [], issues: []}
  end

  test "a CONTEXT.md with no related_icms declaration yields %{related: [], issues: []}", %{
    ws: ws,
    home: home
  } do
    primary_root = icm!(home, "Coaching", "6f9f0c9e-3ccd-4fa5-a219-113a70618b55")
    write_icms(ws, "  coaching:\n    path: #{primary_root}\n")
    write_context!(primary_root, "# Coaching context\n\nNo frontmatter here.\n")

    primary = Mounts.mount_by_key(ws, "coaching")
    assert Context.resolve(ws, primary) == %{related: [], issues: []}
  end

  test "resolution is direct-only: a related ICM's own related_icms are never followed (cycle-safe)",
       %{ws: ws, home: home} do
    primary_root = icm!(home, "Coaching", "6f9f0c9e-3ccd-4fa5-a219-113a70618b55")
    related_root = icm!(home, "Legal", "31201697-cff8-4d99-9dc5-b140e4178716")

    write_icms(ws, """
      coaching:
        path: #{primary_root}
      legal:
        path: #{related_root}
    """)

    # A -> B and B -> A: a naive recursive resolver would loop forever.
    write_context!(primary_root, """
    ---
    format: 1
    related_icms:
      - id: 31201697-cff8-4d99-9dc5-b140e4178716
        name: "Legal"
    ---
    """)

    write_context!(related_root, """
    ---
    format: 1
    related_icms:
      - id: 6f9f0c9e-3ccd-4fa5-a219-113a70618b55
        name: "Coaching"
    ---
    """)

    primary = Mounts.mount_by_key(ws, "coaching")
    result = Context.resolve(ws, primary)

    assert result.issues == []
    assert [%{mount_key: "legal"}] = result.related
  end

  # -- bare-string mail entries (Task 14, spec §"Mount & containment") ------
  #
  # `related_icms: [mail-<slug>]` — a bare STRING list entry — is the mail
  # opt-in grammar. It resolves via `Mounts.mount_by_key/2` and requires an
  # enabled, non-degraded `kind: :mail` mount; anything else surfaces as a
  # `:mail_unavailable` issue. Map entries keep the ICM id semantics
  # untouched (covered above).

  describe "bare-string mail-<slug> entries" do
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

    setup %{ws: ws, home: home} do
      primary_root = icm!(home, "Coaching", "6f9f0c9e-3ccd-4fa5-a219-113a70618b55")
      write_icms(ws, "  coaching:\n    path: #{primary_root}\n")
      %{primary_root: primary_root}
    end

    test "a configured, healthy account resolves to a kind: :mail related entry", %{
      ws: ws,
      primary_root: primary_root
    } do
      write_mail_yaml!(ws)

      write_context!(primary_root, """
      ---
      format: 1
      related_icms:
        - mail-mara
      ---
      """)

      primary = Mounts.mount_by_key(ws, "coaching")
      result = Context.resolve(ws, primary)
      mail_root = Path.join([real!(ws), "sources", "mail", "mara"])

      assert result.issues == []

      assert [
               %{
                 mount_key: "mail-mara",
                 id: nil,
                 root: ^mail_root,
                 entrypoint: nil,
                 manifest: nil,
                 kind: :mail
               }
             ] = result.related
    end

    test "an unconfigured account surfaces :mail_unavailable, never a grant", %{
      ws: ws,
      primary_root: primary_root
    } do
      write_context!(primary_root, """
      ---
      format: 1
      related_icms:
        - mail-nope
      ---
      """)

      primary = Mounts.mount_by_key(ws, "coaching")
      result = Context.resolve(ws, primary)

      assert result.related == []
      assert [%{id: nil, name: "mail-nope", reason: :mail_unavailable}] = result.issues
    end

    test "a bare string naming an ICM mount (not kind: :mail) is :mail_unavailable", %{
      ws: ws,
      home: home,
      primary_root: primary_root
    } do
      # A legacy/hand-edited `icms:` key inside the mail-* namespace: the
      # grammar requires `kind: :mail`, so it must NOT resolve — fail closed.
      shadow_root = icm!(home, "Shadow", "31201697-cff8-4d99-9dc5-b140e4178716")

      write_icms(ws, """
        coaching:
          path: #{primary_root}
        mail-shadow:
          path: #{shadow_root}
      """)

      write_context!(primary_root, """
      ---
      format: 1
      related_icms:
        - mail-shadow
      ---
      """)

      primary = Mounts.mount_by_key(ws, "coaching")
      result = Context.resolve(ws, primary)

      assert result.related == []
      assert [%{name: "mail-shadow", reason: :mail_unavailable}] = result.issues
    end

    test "a bare string outside the mail-* namespace is dropped silently (not an issue)", %{
      ws: ws,
      primary_root: primary_root
    } do
      write_context!(primary_root, """
      ---
      format: 1
      related_icms:
        - coaching
      ---
      """)

      primary = Mounts.mount_by_key(ws, "coaching")
      result = Context.resolve(ws, primary)

      assert result.related == []
      assert result.issues == []
    end
  end

  # -- the bare-string calendar entry (Spec F Task 5, calendar spec
  # §"Mounts and policy") — same grammar as `mail-<slug>`, over the ONE
  # reserved key `calendar`. Requires an enabled, non-degraded
  # `kind: :calendar` mount (i.e. `config/calendar.yaml` exists and no
  # `icms:` entry shadows the key); anything else is an issue, never a
  # grant.

  describe "bare-string calendar entries" do
    setup %{ws: ws, home: home} do
      primary_root = icm!(home, "Coaching", "6f9f0c9e-3ccd-4fa5-a219-113a70618b55")
      write_icms(ws, "  coaching:\n    path: #{primary_root}\n")
      %{primary_root: primary_root}
    end

    test "a workspace with calendar.yaml resolves to a kind: :calendar related entry", %{
      ws: ws,
      primary_root: primary_root
    } do
      # Manager.create seeded the template's v1-empty calendar.yaml.
      write_context!(primary_root, """
      ---
      format: 1
      related_icms:
        - calendar
      ---
      """)

      primary = Mounts.mount_by_key(ws, "coaching")
      result = Context.resolve(ws, primary)
      cal_root = Path.join([real!(ws), "sources", "calendar"])

      assert result.issues == []

      assert [
               %{
                 mount_key: "calendar",
                 id: nil,
                 root: ^cal_root,
                 entrypoint: nil,
                 manifest: nil,
                 kind: :calendar
               }
             ] = result.related
    end

    test "no calendar.yaml surfaces an issue, never a grant", %{
      ws: ws,
      primary_root: primary_root
    } do
      File.rm!(Path.join(ws, "config/calendar.yaml"))

      write_context!(primary_root, """
      ---
      format: 1
      related_icms:
        - calendar
      ---
      """)

      primary = Mounts.mount_by_key(ws, "coaching")
      result = Context.resolve(ws, primary)

      assert result.related == []
      assert [%{id: nil, name: "calendar", reason: :mail_unavailable}] = result.issues
    end

    test "an icms: entry shadowing the calendar key must NOT resolve through the grammar", %{
      ws: ws,
      home: home,
      primary_root: primary_root
    } do
      shadow_root = icm!(home, "Shadow", "31201697-cff8-4d99-9dc5-b140e4178716")

      write_icms(ws, """
        coaching:
          path: #{primary_root}
        calendar:
          path: #{shadow_root}
      """)

      write_context!(primary_root, """
      ---
      format: 1
      related_icms:
        - calendar
      ---
      """)

      primary = Mounts.mount_by_key(ws, "coaching")
      result = Context.resolve(ws, primary)

      assert result.related == []
      assert [%{name: "calendar", reason: :mail_unavailable}] = result.issues
    end

    test "near-miss bare strings are still dropped silently", %{
      ws: ws,
      primary_root: primary_root
    } do
      write_context!(primary_root, """
      ---
      format: 1
      related_icms:
        - calendars
        - Calendar
      ---
      """)

      primary = Mounts.mount_by_key(ws, "coaching")
      result = Context.resolve(ws, primary)

      assert result.related == []
      assert result.issues == []
    end
  end

  # The settings UI's mail-access toggles: line surgery over the user-owned
  # CONTEXT.md — everything the editor doesn't understand must pass through
  # byte-identical.
  describe "mail_optins/1 + set_mail_optin/3" do
    setup do
      root = Path.join(System.tmp_dir!(), "valea-optin-#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)
      %{root: root}
    end

    defp context!(root, content), do: File.write!(Path.join(root, "CONTEXT.md"), content)
    defp context(root), do: File.read!(Path.join(root, "CONTEXT.md"))

    test "adds an entry under an existing related_icms list, preserving everything else", %{
      root: root
    } do
      context!(root, """
      ---
      format: 1
      # my own comment
      related_icms:
        - id: abc-123
          name: "Legal"
      ---

      # Router

      | task | place |
      """)

      assert :ok = Context.set_mail_optin(root, "mara", true)

      assert context(root) == """
             ---
             format: 1
             # my own comment
             related_icms:
               - mail-mara
               - id: abc-123
                 name: "Legal"
             ---

             # Router

             | task | place |
             """

      assert Context.mail_optins(root) == ["mara"]
    end

    test "creates the key when the frontmatter lacks it, inside the fence", %{root: root} do
      context!(root, "---\nformat: 1\n---\nBody stays.\n")
      assert :ok = Context.set_mail_optin(root, "work", true)

      assert context(root) ==
               "---\nformat: 1\nrelated_icms:\n  - mail-work\n---\nBody stays.\n"
    end

    test "prepends a minimal block when the file has no frontmatter; mints the file when absent",
         %{root: root} do
      context!(root, "# Just prose\n")
      assert :ok = Context.set_mail_optin(root, "mara", true)
      assert context(root) == "---\nrelated_icms:\n  - mail-mara\n---\n# Just prose\n"

      other = Path.join(root, "fresh")
      File.mkdir_p!(other)
      assert :ok = Context.set_mail_optin(other, "mara", true)
      assert Context.mail_optins(other) == ["mara"]
    end

    test "is idempotent in both directions", %{root: root} do
      context!(root, "---\nrelated_icms:\n  - mail-mara\n---\nBody.\n")
      before = context(root)

      assert :ok = Context.set_mail_optin(root, "mara", true)
      assert context(root) == before

      assert :ok = Context.set_mail_optin(root, "other", false)
      assert context(root) == before
    end

    test "removes an entry and drops the key (and block) when they empty out", %{root: root} do
      context!(root, """
      ---
      format: 1
      related_icms:
        - mail-mara
        - id: abc
          name: "Legal"
      ---
      Body.
      """)

      assert :ok = Context.set_mail_optin(root, "mara", false)
      refute context(root) =~ "mail-mara"
      assert context(root) =~ "name: \"Legal\""

      # Key with only the mail entry: key line goes too.
      context!(root, "---\nformat: 1\nrelated_icms:\n  - mail-mara\n---\nBody.\n")
      assert :ok = Context.set_mail_optin(root, "mara", false)
      assert context(root) == "---\nformat: 1\n---\nBody.\n"

      # Block with only that key: the whole block goes.
      context!(root, "---\nrelated_icms:\n  - mail-mara\n---\nBody.\n")
      assert :ok = Context.set_mail_optin(root, "mara", false)
      assert context(root) == "Body.\n"

      # No file at all: disable is a no-op, not a minted file.
      other = Path.join(root, "none")
      File.mkdir_p!(other)
      assert :ok = Context.set_mail_optin(other, "mara", false)
      refute File.exists?(Path.join(other, "CONTEXT.md"))
    end

    test "matches quoted entries and respects existing indentation", %{root: root} do
      context!(root, "---\nrelated_icms:\n    - \"mail-mara\"\n    - calendar\n---\n")
      assert :ok = Context.set_mail_optin(root, "mara", false)
      assert context(root) == "---\nrelated_icms:\n    - calendar\n---\n"

      assert :ok = Context.set_mail_optin(root, "work", true)
      assert context(root) == "---\nrelated_icms:\n    - mail-work\n    - calendar\n---\n"
    end

    test "refuses a flow-style list instead of mangling it", %{root: root} do
      context!(root, "---\nrelated_icms: [calendar]\n---\n")
      before = context(root)

      assert {:error, :context_unsupported} = Context.set_mail_optin(root, "mara", true)
      assert context(root) == before
    end

    test "a slug is never a regex: metacharacters match literally", %{root: root} do
      context!(root, "---\nrelated_icms:\n  - mail-a.b\n---\n")
      # ".": a regex dot would also match "a-b" — the escape keeps it literal.
      assert :ok = Context.set_mail_optin(root, "a-b", false)
      assert context(root) =~ "mail-a.b"
    end

    test "mail_optins reads slugs off the same grammar resolve/2 uses", %{root: root} do
      context!(root, """
      ---
      related_icms:
        - mail-mara
        - calendar
        - id: abc
          name: "Legal"
        - mail-work
      ---
      """)

      assert Context.mail_optins(root) == ["mara", "work"]
      assert Context.mail_optins(Path.join(root, "missing")) == []
    end
  end
end
