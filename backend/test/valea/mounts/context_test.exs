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
end
