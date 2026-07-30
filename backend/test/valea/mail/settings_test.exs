defmodule Valea.Mail.SettingsTest do
  use ExUnit.Case, async: true

  alias Valea.Mail.Settings

  setup do
    root = Path.join(System.tmp_dir!(), "vmail-#{System.os_time(:nanosecond)}")
    File.mkdir_p!(Path.join(root, "config"))
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  defp write_yaml!(root, contents) do
    File.write!(Path.join(root, "config/mail.yaml"), contents)
  end

  test "load/1 on the template file (accounts: {}) returns empty accounts and invalid maps", %{
    root: root
  } do
    write_yaml!(root, """
    version: 5
    accounts: {}
    safety:
      never_expunge: true
      outbound: human_send_and_push
    """)

    assert Settings.load(root) == {:ok, %{accounts: %{}, invalid: %{}}}
  end

  test "round-trip: upsert_account! then load returns one account with generic defaults", %{
    root: root
  } do
    assert :ok =
             Settings.upsert_account!(root, "wirdrei", %{
               host: "mail.example.com",
               port: 993,
               username: "d@w.d"
             })

    assert {:ok, %{accounts: accounts, invalid: %{}}} = Settings.load(root)
    assert map_size(accounts) == 1

    assert %Settings{
             slug: "wirdrei",
             provider: :generic,
             imap: %{host: "mail.example.com", port: 993, username: "d@w.d"},
             folders: %{drafts: "Drafts", sent: "Sent", archive: "Archive", trash: "Trash"},
             sync: %{
               window_days: 90,
               interval_minutes: 15,
               max_message_bytes: 26_214_400,
               exclude_folders: []
             }
           } = accounts["wirdrei"]
  end

  test "gmail detection: imap.gmail.com sets provider gmail with gmail folders/excludes", %{
    root: root
  } do
    assert :ok =
             Settings.upsert_account!(root, "personal", %{
               host: "imap.gmail.com",
               port: 993,
               username: "mara@gmail.com"
             })

    assert {:ok, %{accounts: accounts}} = Settings.load(root)
    account = accounts["personal"]

    assert account.provider == :gmail
    assert account.sync.exclude_folders == Settings.gmail_excludes()
    assert account.folders == Settings.gmail_folders()
    assert account.folders.archive == "[Gmail]/All Mail"
    refute account.folders.archive == "Archive"
  end

  test "load/1 with explicit provider: gmail in YAML uses gmail defaults (no folders:/sync: override)",
       %{
         root: root
       } do
    write_yaml!(root, """
    version: 4
    accounts:
      personal:
        provider: gmail
        imap:
          host: imap.gmail.com
          port: 993
          username: mara@gmail.com
    """)

    assert {:ok, %{accounts: accounts, invalid: %{}}} = Settings.load(root)
    account = accounts["personal"]

    assert account.provider == :gmail
    assert account.folders.archive == "[Gmail]/All Mail"
    assert account.sync.exclude_folders == Settings.gmail_excludes()
  end

  test "load/1 with provider absent but imap host detectable as gmail uses gmail defaults (detection fallback)",
       %{
         root: root
       } do
    write_yaml!(root, """
    version: 4
    accounts:
      personal:
        imap:
          host: imap.gmail.com
          port: 993
          username: mara@gmail.com
    """)

    assert {:ok, %{accounts: accounts, invalid: %{}}} = Settings.load(root)
    account = accounts["personal"]

    assert account.provider == :gmail
    assert account.folders.archive == "[Gmail]/All Mail"
    assert account.sync.exclude_folders == Settings.gmail_excludes()
  end

  test "slug grammar: invalid slugs are rejected by upsert_account!/valid_slug?, valid ones accepted",
       %{root: root} do
    invalid_slugs = ["../secrets", "a/b", "%2e%2e", "A", "", String.duplicate("a", 33)]

    for slug <- invalid_slugs do
      refute Settings.valid_slug?(slug)

      assert Settings.upsert_account!(root, slug, %{
               host: "mail.example.com",
               port: 993,
               username: "d@w.d"
             }) == {:error, :invalid_slug}
    end

    for slug <- ["personal", "a", "a-1"] do
      assert Settings.valid_slug?(slug)
    end
  end

  test "casefold-uniqueness: an uppercase variant is rejected by grammar; a hand-edited casefold collision is marked invalid on load",
       %{root: root} do
    assert :ok =
             Settings.upsert_account!(root, "personal", %{
               host: "mail.example.com",
               port: 993,
               username: "d@w.d"
             })

    # "Personal" already fails slug grammar (uppercase) before uniqueness is
    # ever considered.
    assert Settings.upsert_account!(root, "Personal", %{
             host: "mail.example.com",
             port: 993,
             username: "d2@w.d"
           }) == {:error, :invalid_slug}

    # A hand-edited file can still land two keys that collide case-foldedly
    # (one of which — "personaL" — is itself grammatically invalid). `load/1`
    # must isolate it under `invalid`, not raise, and still load the sibling.
    write_yaml!(root, """
    version: 4
    accounts:
      personal:
        provider: generic
        imap:
          host: "mail.example.com"
          port: 993
          username: "d@w.d"
        folders:
          drafts: "Drafts"
          sent: "Sent"
          archive: "Archive"
          trash: "Trash"
        sync:
          window_days: 90
          interval_minutes: 15
          max_message_bytes: 26214400
          exclude_folders: []
      personaL:
        provider: generic
        imap:
          host: "mail.example.com"
          port: 993
          username: "d2@w.d"
        folders:
          drafts: "Drafts"
          sent: "Sent"
          archive: "Archive"
          trash: "Trash"
        sync:
          window_days: 90
          interval_minutes: 15
          max_message_bytes: 26214400
          exclude_folders: []
    """)

    assert {:ok, %{accounts: accounts, invalid: invalid}} = Settings.load(root)
    assert Map.has_key?(accounts, "personal")
    assert Map.has_key?(invalid, "personaL")
  end

  test "hand-edited YAML with an invalid slug (\"../x\") isolates that account under invalid; nothing raises",
       %{root: root} do
    write_yaml!(root, """
    version: 4
    accounts:
      "../x":
        provider: generic
        imap:
          host: "mail.example.com"
          port: 993
          username: "d@w.d"
      wirdrei:
        provider: generic
        imap:
          host: "mail.example.com"
          port: 993
          username: "d@w.d"
    """)

    assert {:ok, %{accounts: accounts, invalid: invalid}} = Settings.load(root)
    assert Map.has_key?(invalid, "../x")
    assert Map.has_key?(accounts, "wirdrei")
  end

  test "a v3-shaped file (top-level account:/imap: keys) is rejected — no compatibility", %{
    root: root
  } do
    write_yaml!(root, """
    account: mara@example.com
    imap:
      host: imap.fastmail.com
      port: 993
      username: mara@example.com
    folders:
      review: "AI/Review"
      processed: "AI/Processed"
      drafts: "Drafts"
    sync:
      interval_minutes: 5
      max_message_bytes: 10485760
      inbox_index_limit: 200
    safety:
      send_directly: false
      create_drafts_only: true
    """)

    assert {:error, {:invalid, _reason}} = Settings.load(root)
  end

  test "env_credential/1 reads VALEA_MAIL_PASSWORD_<SLUG upcased, dashes to underscores>" do
    System.put_env("VALEA_MAIL_PASSWORD_MY_ACCT", "hunter2")
    on_exit(fn -> System.delete_env("VALEA_MAIL_PASSWORD_MY_ACCT") end)

    assert Settings.env_credential("my-acct") == "hunter2"
  end

  test "env_credential/1 returns nil when the env var is unset" do
    System.delete_env("VALEA_MAIL_PASSWORD_GHOST_ACCT")
    assert Settings.env_credential("ghost-acct") == nil
  end

  test "render/1 emits the fixed safety block and applies port defaults", %{root: root} do
    assert :ok =
             Settings.upsert_account!(root, "wirdrei", %{
               host: "mail.example.com",
               port: 993,
               username: "d@w.d"
             })

    assert {:ok, %{accounts: accounts}} = Settings.load(root)
    bytes = Settings.render(accounts)

    assert bytes =~ "never_expunge: true"
    assert bytes =~ "outbound: human_send_and_push"
    assert bytes =~ "port: 993"
  end

  test "remove_account!/2 drops the account; the sibling survives", %{root: root} do
    :ok =
      Settings.upsert_account!(root, "one", %{
        host: "mail.example.com",
        port: 993,
        username: "one@w.d"
      })

    :ok =
      Settings.upsert_account!(root, "two", %{
        host: "mail.example.com",
        port: 993,
        username: "two@w.d"
      })

    assert :ok = Settings.remove_account!(root, "one")

    assert {:ok, %{accounts: accounts}} = Settings.load(root)
    assert Map.keys(accounts) == ["two"]
  end

  # -- the per-account notifications flag (M5 task 13) --------------------------

  test "notifications default off: an upsert that doesn't state it round-trips false", %{
    root: root
  } do
    assert :ok =
             Settings.upsert_account!(root, "wirdrei", %{
               host: "mail.example.com",
               port: 993,
               username: "d@w.d"
             })

    assert {:ok, %{accounts: %{"wirdrei" => account}}} = Settings.load(root)
    assert account.notifications == false
    assert File.read!(Path.join(root, "config/mail.yaml")) =~ "notifications: false"
  end

  test "notifications: true round-trips through upsert, render, and load", %{root: root} do
    assert :ok =
             Settings.upsert_account!(root, "wirdrei", %{
               host: "mail.example.com",
               port: 993,
               username: "d@w.d",
               notifications: true
             })

    assert File.read!(Path.join(root, "config/mail.yaml")) =~ "notifications: true"
    assert {:ok, %{accounts: %{"wirdrei" => account}}} = Settings.load(root)
    assert account.notifications == true

    # And back off again — the flag is not sticky across edits.
    assert :ok =
             Settings.upsert_account!(root, "wirdrei", %{
               host: "mail.example.com",
               port: 993,
               username: "d@w.d",
               notifications: false
             })

    assert {:ok, %{accounts: %{"wirdrei" => account}}} = Settings.load(root)
    assert account.notifications == false
  end

  test "a file written before the flag existed loads every account with notifications off", %{
    root: root
  } do
    write_yaml!(root, """
    version: 5
    accounts:
      wirdrei:
        provider: generic
        imap:
          host: "mail.example.com"
          port: 993
          username: "d@w.d"
    safety:
      never_expunge: true
      outbound: human_send_and_push
    """)

    assert {:ok, %{accounts: %{"wirdrei" => account}, invalid: %{}}} = Settings.load(root)
    assert account.notifications == false
  end

  test "a non-boolean notifications: value loads as off rather than invalidating the account", %{
    root: root
  } do
    write_yaml!(root, """
    version: 5
    accounts:
      wirdrei:
        provider: generic
        notifications: "yes"
        imap:
          host: "mail.example.com"
          port: 993
          username: "d@w.d"
    safety:
      never_expunge: true
      outbound: human_send_and_push
    """)

    assert {:ok, %{accounts: %{"wirdrei" => account}, invalid: %{}}} = Settings.load(root)
    assert account.notifications == false
  end

  test "the flag is per-account: one account's opt-in leaves its sibling alone", %{root: root} do
    assert :ok =
             Settings.upsert_account!(root, "aaa", %{
               host: "mail.example.com",
               port: 993,
               username: "a@w.d",
               notifications: true
             })

    assert :ok =
             Settings.upsert_account!(root, "bbb", %{
               host: "mail.example.com",
               port: 993,
               username: "b@w.d"
             })

    assert {:ok, %{accounts: accounts}} = Settings.load(root)
    assert accounts["aaa"].notifications == true
    assert accounts["bbb"].notifications == false
  end

  # -- the per-account auth mode (M6 task 15) -----------------------------------

  test "auth defaults to :password: an upsert that doesn't state it round-trips password", %{
    root: root
  } do
    assert :ok =
             Settings.upsert_account!(root, "wirdrei", %{
               host: "mail.example.com",
               port: 993,
               username: "d@w.d"
             })

    assert {:ok, %{accounts: %{"wirdrei" => account}}} = Settings.load(root)
    assert account.auth == :password
    assert File.read!(Path.join(root, "config/mail.yaml")) =~ "auth: password"
  end

  test "auth: :oauth2 round-trips through upsert, render, and load", %{root: root} do
    assert :ok =
             Settings.upsert_account!(root, "wirdrei", %{
               host: "mail.example.com",
               port: 993,
               username: "d@w.d",
               auth: :oauth2
             })

    assert File.read!(Path.join(root, "config/mail.yaml")) =~ "auth: oauth2"
    assert {:ok, %{accounts: %{"wirdrei" => account}}} = Settings.load(root)
    assert account.auth == :oauth2

    # And back to password again — the mode is not sticky across edits, exactly
    # like every other whole-entry field this call re-renders.
    assert :ok =
             Settings.upsert_account!(root, "wirdrei", %{
               host: "mail.example.com",
               port: 993,
               username: "d@w.d"
             })

    assert {:ok, %{accounts: %{"wirdrei" => account}}} = Settings.load(root)
    assert account.auth == :password
  end

  test "upsert refuses an auth mode it cannot render, rather than writing it", %{root: root} do
    assert {:error, :invalid_auth} =
             Settings.upsert_account!(root, "wirdrei", %{
               host: "mail.example.com",
               port: 993,
               username: "d@w.d",
               auth: :kerberos
             })

    refute File.exists?(Path.join(root, "config/mail.yaml"))
  end

  test "a file written before the key existed loads every account as :password", %{root: root} do
    write_yaml!(root, """
    version: 5
    accounts:
      wirdrei:
        provider: generic
        imap:
          host: "mail.example.com"
          port: 993
          username: "d@w.d"
    safety:
      never_expunge: true
      outbound: human_send_and_push
    """)

    assert {:ok, %{accounts: %{"wirdrei" => account}, invalid: %{}}} = Settings.load(root)
    assert account.auth == :password
  end

  test "an unusable auth: value INVALIDATES its account — it never falls back to password", %{
    root: root
  } do
    # The one override in this file that must not degrade to its default: a
    # silent fall back to `password` would have the engine send an access token
    # as a LOGIN password. Its SIBLING must still load.
    write_yaml!(root, """
    version: 5
    accounts:
      broken:
        provider: generic
        auth: oath2
        imap:
          host: "mail.example.com"
          port: 993
          username: "typo@w.d"
      healthy:
        provider: generic
        auth: oauth2
        imap:
          host: "mail.example.com"
          port: 993
          username: "ok@w.d"
    safety:
      never_expunge: true
      outbound: human_send_and_push
    """)

    assert {:ok, %{accounts: accounts, invalid: invalid}} = Settings.load(root)

    refute Map.has_key?(accounts, "broken")
    assert invalid["broken"] =~ "auth"
    assert accounts["healthy"].auth == :oauth2
  end

  test "a non-string auth: value is equally invalidating", %{root: root} do
    write_yaml!(root, """
    version: 5
    accounts:
      broken:
        provider: generic
        auth: true
        imap:
          host: "mail.example.com"
          port: 993
          username: "d@w.d"
    safety:
      never_expunge: true
      outbound: human_send_and_push
    """)

    assert {:ok, %{accounts: %{}, invalid: invalid}} = Settings.load(root)
    assert invalid["broken"] =~ "auth"
  end

  test "a PRESENT but empty auth: invalidates too — only an ABSENT key means password", %{
    root: root
  } do
    # `auth:` and `auth: ~` both parse to `nil`, which is exactly the value a
    # `Map.get/2` lookup could not tell from an absent key — and reading it as
    # `password` is the degradation this field forbids.
    for empty <- ["auth:", "auth: ~"] do
      write_yaml!(root, """
      version: 5
      accounts:
        broken:
          provider: generic
          #{empty}
          imap:
            host: "mail.example.com"
            port: 993
            username: "d@w.d"
      safety:
        never_expunge: true
        outbound: human_send_and_push
      """)

      assert {:ok, %{accounts: %{}, invalid: invalid}} = Settings.load(root)
      assert invalid["broken"] =~ "auth"
    end
  end

  test "imap_config/1 and smtp_config/1 carry the mode to the transports", %{root: root} do
    assert :ok =
             Settings.upsert_account!(root, "wirdrei", %{
               host: "mail.example.com",
               port: 993,
               username: "d@w.d",
               auth: :oauth2,
               smtp: %{host: "smtp.example.com", port: 587, username: "d@w.d"}
             })

    assert {:ok, %{accounts: %{"wirdrei" => account}}} = Settings.load(root)

    assert Settings.imap_config(account) == %{
             host: "mail.example.com",
             port: 993,
             username: "d@w.d",
             auth: :oauth2
           }

    assert Settings.smtp_config(account) == %{
             host: "smtp.example.com",
             port: 587,
             security: :starttls,
             username: "d@w.d",
             from: "d@w.d",
             from_name: nil,
             auth: :oauth2
           }
  end

  test "smtp_config/1 is nil for a push-only account", %{root: root} do
    assert :ok =
             Settings.upsert_account!(root, "wirdrei", %{
               host: "mail.example.com",
               port: 993,
               username: "d@w.d"
             })

    assert {:ok, %{accounts: %{"wirdrei" => account}}} = Settings.load(root)
    assert Settings.smtp_config(account) == nil
    assert Settings.imap_config(account).auth == :password
  end

  # -- v5: the optional smtp block ---------------------------------------------

  defp write_smtp_yaml!(root, smtp_block) do
    write_yaml!(root, """
    version: 5
    accounts:
      wirdrei:
        imap:
          host: "mail.example.com"
          port: 993
          username: "d@w.d"
        smtp:
    #{smtp_block}
    """)
  end

  test "a v4 file (no smtp: blocks anywhere) loads unchanged, with smtp nil and not configured",
       %{
         root: root
       } do
    write_yaml!(root, """
    version: 4
    accounts:
      wirdrei:
        provider: generic
        imap:
          host: "mail.example.com"
          port: 993
          username: "d@w.d"
    safety:
      never_expunge: true
      outbound: push_drafts_only
    """)

    assert {:ok, %{accounts: %{"wirdrei" => account}, invalid: %{}}} = Settings.load(root)
    assert account.smtp == nil
    refute Settings.smtp_configured?(account)
  end

  test "upsert with an smtp block: port 587 defaults to starttls, from defaults to the username, and it round-trips",
       %{root: root} do
    assert :ok =
             Settings.upsert_account!(root, "wirdrei", %{
               host: "mail.example.com",
               port: 993,
               username: "d@w.d",
               smtp: %{host: "mail.example.com", port: 587, username: "d@w.d"}
             })

    assert {:ok, %{accounts: %{"wirdrei" => account}, invalid: %{}}} = Settings.load(root)

    assert account.smtp == %{
             host: "mail.example.com",
             port: 587,
             security: :starttls,
             username: "d@w.d",
             from: "d@w.d",
             from_name: nil
           }

    assert Settings.smtp_configured?(account)

    bytes = File.read!(Path.join(root, "config/mail.yaml"))
    assert bytes =~ "version: 5"
    assert bytes =~ "outbound: human_send_and_push"

    # render/1 of the loaded accounts is byte-identical to what upsert wrote —
    # the smtp block survives a full write/parse/write cycle.
    assert Settings.render(%{"wirdrei" => account}) == bytes
  end

  test "upsert with from/from_name carries them through the round-trip", %{root: root} do
    assert :ok =
             Settings.upsert_account!(root, "wirdrei", %{
               host: "mail.example.com",
               port: 993,
               username: "d@w.d",
               smtp: %{
                 host: "smtp.example.com",
                 port: 465,
                 username: "d@w.d",
                 from: "daniel@w.d",
                 from_name: "Daniel Milenkovic"
               }
             })

    assert {:ok, %{accounts: %{"wirdrei" => account}}} = Settings.load(root)

    assert account.smtp == %{
             host: "smtp.example.com",
             port: 465,
             security: :tls,
             username: "d@w.d",
             from: "daniel@w.d",
             from_name: "Daniel Milenkovic"
           }
  end

  test "port 465 defaults to implicit tls", %{root: root} do
    write_smtp_yaml!(root, """
          host: "mail.example.com"
          port: 465
          username: "d@w.d"
    """)

    assert {:ok, %{accounts: %{"wirdrei" => account}, invalid: %{}}} = Settings.load(root)
    assert account.smtp.security == :tls
  end

  test "a non-conventional port with no explicit security marks the account invalid", %{
    root: root
  } do
    write_smtp_yaml!(root, """
          host: "mail.example.com"
          port: 2525
          username: "d@w.d"
    """)

    assert {:ok, %{accounts: accounts, invalid: invalid}} = Settings.load(root)
    assert accounts == %{}
    assert invalid["wirdrei"] =~ "security"
  end

  test "an explicit security contradicting the port convention marks the account invalid", %{
    root: root
  } do
    write_smtp_yaml!(root, """
          host: "mail.example.com"
          port: 587
          security: tls
          username: "d@w.d"
    """)

    assert {:ok, %{accounts: accounts, invalid: invalid}} = Settings.load(root)
    assert accounts == %{}
    assert invalid["wirdrei"] =~ "security"
  end

  test "an explicit security on a non-conventional port is accepted", %{root: root} do
    write_smtp_yaml!(root, """
          host: "mail.example.com"
          port: 2525
          security: starttls
          username: "d@w.d"
    """)

    assert {:ok, %{accounts: %{"wirdrei" => account}, invalid: %{}}} = Settings.load(root)
    assert account.smtp.security == :starttls
    assert account.smtp.port == 2525
  end

  test "an smtp.from that isn't a single addr-spec marks the account invalid", %{root: root} do
    write_smtp_yaml!(root, """
          host: "mail.example.com"
          port: 587
          username: "d@w.d"
          from: "not an addr"
    """)

    assert {:ok, %{accounts: accounts, invalid: invalid}} = Settings.load(root)
    assert accounts == %{}
    assert invalid["wirdrei"] =~ "from"
  end

  test "CR/LF in smtp.from_name marks the account invalid (header injection)", %{root: root} do
    write_smtp_yaml!(root, """
          host: "mail.example.com"
          port: 587
          username: "d@w.d"
          from_name: "a\\nb"
    """)

    assert {:ok, %{accounts: accounts, invalid: invalid}} = Settings.load(root)
    assert accounts == %{}
    assert invalid["wirdrei"] =~ "from_name"
  end

  test "a broken smtp block invalidates only its own account; the sibling still loads", %{
    root: root
  } do
    write_yaml!(root, """
    version: 5
    accounts:
      broken:
        imap:
          host: "mail.example.com"
          port: 993
          username: "d@w.d"
        smtp:
          host: "mail.example.com"
          port: 2525
          username: "d@w.d"
      fine:
        imap:
          host: "mail.example.com"
          port: 993
          username: "e@w.d"
    """)

    assert {:ok, %{accounts: accounts, invalid: invalid}} = Settings.load(root)
    assert Map.keys(accounts) == ["fine"]
    assert Map.has_key?(invalid, "broken")
  end

  test "upsert_account! refuses an invalid smtp block rather than writing an unloadable account",
       %{root: root} do
    assert Settings.upsert_account!(root, "wirdrei", %{
             host: "mail.example.com",
             port: 993,
             username: "d@w.d",
             smtp: %{host: "mail.example.com", port: 587, username: "d@w.d", from: "not an addr"}
           }) == {:error, :invalid_smtp}

    refute File.exists?(Path.join(root, "config/mail.yaml"))
  end

  test "smtp_fingerprint/1 is nil without smtp, deterministic with it, and tracks from_name", %{
    root: root
  } do
    :ok =
      Settings.upsert_account!(root, "push-only", %{
        host: "mail.example.com",
        port: 993,
        username: "d@w.d"
      })

    :ok =
      Settings.upsert_account!(root, "sender", %{
        host: "mail.example.com",
        port: 993,
        username: "d@w.d",
        smtp: %{host: "mail.example.com", port: 587, username: "d@w.d"}
      })

    assert {:ok, %{accounts: accounts}} = Settings.load(root)
    assert Settings.smtp_fingerprint(accounts["push-only"]) == nil

    fingerprint = Settings.smtp_fingerprint(accounts["sender"])
    assert is_binary(fingerprint)
    assert String.match?(fingerprint, ~r/^[0-9a-f]{64}$/)

    # Deterministic across an independent load of the same file.
    assert {:ok, %{accounts: reloaded}} = Settings.load(root)
    assert Settings.smtp_fingerprint(reloaded["sender"]) == fingerprint

    # A display-name edit is an identity change — the fingerprint must move.
    :ok =
      Settings.upsert_account!(root, "sender", %{
        host: "mail.example.com",
        port: 993,
        username: "d@w.d",
        smtp: %{
          host: "mail.example.com",
          port: 587,
          username: "d@w.d",
          from_name: "Daniel Milenkovic"
        }
      })

    assert {:ok, %{accounts: renamed}} = Settings.load(root)
    assert Settings.smtp_fingerprint(renamed["sender"]) != fingerprint
  end

  test "smtp_fingerprint/1 is unchanged by a non-identity settings edit (sync.window_days)", %{
    root: root
  } do
    smtp = %{host: "mail.example.com", port: 587, username: "d@w.d"}

    :ok =
      Settings.upsert_account!(root, "sender", %{
        host: "mail.example.com",
        port: 993,
        username: "d@w.d",
        smtp: smtp
      })

    assert {:ok, %{accounts: before}} = Settings.load(root)

    :ok =
      Settings.upsert_account!(root, "sender", %{
        host: "mail.example.com",
        port: 993,
        username: "d@w.d",
        smtp: smtp,
        sync: %{window_days: 30}
      })

    assert {:ok, %{accounts: after_edit}} = Settings.load(root)
    assert after_edit["sender"].sync.window_days == 30

    assert Settings.smtp_fingerprint(after_edit["sender"]) ==
             Settings.smtp_fingerprint(before["sender"])
  end

  test "smtp_env_credential/1 reads VALEA_MAIL_SMTP_PASSWORD_<SLUG upcased, dashes to underscores>" do
    System.put_env("VALEA_MAIL_SMTP_PASSWORD_MY_ACCT", "smtp-hunter2")
    on_exit(fn -> System.delete_env("VALEA_MAIL_SMTP_PASSWORD_MY_ACCT") end)

    assert Settings.smtp_env_credential("my-acct") == "smtp-hunter2"
    # The IMAP fallback is a DIFFERENT variable — never the same secret.
    assert Settings.env_credential("my-acct") == nil
  end

  test "smtp_env_credential/1 returns nil when the env var is unset" do
    System.delete_env("VALEA_MAIL_SMTP_PASSWORD_GHOST_ACCT")
    assert Settings.smtp_env_credential("ghost-acct") == nil
  end

  # -- M6 task 16: provider detection + the oauth_client_id override ----------

  test "detect_provider/1 knows Gmail, the three Microsoft hosts, and nothing else" do
    for host <- ["imap.gmail.com", "IMAP.GMAIL.COM", "imap.googlemail.com"] do
      assert Settings.detect_provider(host) == :gmail
    end

    for host <- [
          "outlook.office365.com",
          "Outlook.Office365.COM",
          "outlook.office.com",
          "imap-mail.outlook.com"
        ] do
      assert Settings.detect_provider(host) == :microsoft
    end

    for host <- ["imap.fastmail.com", "mail.example.com", "outlook.example.com", ""] do
      assert Settings.detect_provider(host) == :generic
    end

    assert Settings.detect_provider(nil) == :generic
  end

  test "a new Microsoft account gets Exchange's folder names, not the generic ones", %{root: root} do
    assert :ok =
             Settings.upsert_account!(root, "work", %{
               host: "outlook.office365.com",
               port: 993,
               username: "mara@contoso.com"
             })

    {:ok, %{accounts: %{"work" => account}}} = Settings.load(root)

    assert account.provider == :microsoft
    # "Sent"/"Trash" do not exist on Exchange: with the generic defaults every
    # archive/trash op would file into folders Valea had created itself beside
    # the real ones.
    assert account.folders == %{
             drafts: "Drafts",
             sent: "Sent Items",
             archive: "Archive",
             trash: "Deleted Items"
           }

    # Nothing to exclude — Exchange has no virtual mirror folders.
    assert account.sync.exclude_folders == []
    assert Settings.microsoft_folders().trash == "Deleted Items"
  end

  test "an explicit folders override still wins over the Microsoft defaults", %{root: root} do
    assert :ok =
             Settings.upsert_account!(root, "work", %{
               host: "outlook.office365.com",
               port: 993,
               username: "mara@contoso.com",
               folders: %{sent: "Gesendete Elemente"}
             })

    {:ok, %{accounts: %{"work" => account}}} = Settings.load(root)
    assert account.folders.sent == "Gesendete Elemente"
    assert account.folders.trash == "Deleted Items"
  end

  test "oauth_client_id round-trips through upsert and load, and is rendered only when set", %{
    root: root
  } do
    assert :ok =
             Settings.upsert_account!(root, "mara", %{
               host: "imap.gmail.com",
               port: 993,
               username: "mara@gmail.com",
               auth: :oauth2,
               oauth_client_id: "123-abc.apps.googleusercontent.com"
             })

    {:ok, %{accounts: %{"mara" => account}}} = Settings.load(root)
    assert account.oauth_client_id == "123-abc.apps.googleusercontent.com"
    assert account.auth == :oauth2

    bytes = File.read!(Path.join(root, "config/mail.yaml"))
    assert bytes =~ ~s(oauth_client_id: "123-abc.apps.googleusercontent.com")

    # Re-rendering an account that has one keeps it (the load→render round trip
    # a `remove_account!` of a SIBLING performs).
    assert :ok =
             Settings.upsert_account!(root, "other", %{
               host: "imap.fastmail.com",
               port: 993,
               username: "o@example.com"
             })

    {:ok, %{accounts: accounts}} = Settings.load(root)
    assert accounts["mara"].oauth_client_id == "123-abc.apps.googleusercontent.com"
    # ...and an account without one emits no key at all, so a file for a
    # password account is byte-identical to what it was before this key existed.
    assert accounts["other"].oauth_client_id == nil

    refute File.read!(Path.join(root, "config/mail.yaml")) =~ "\n    oauth_client_id: \"\"\n"
  end

  test "an omitted oauth_client_id on upsert means NO override (the whole-entry rule)", %{
    root: root
  } do
    assert :ok =
             Settings.upsert_account!(root, "mara", %{
               host: "imap.gmail.com",
               port: 993,
               username: "mara@gmail.com",
               auth: :oauth2,
               oauth_client_id: "first-id"
             })

    assert :ok =
             Settings.upsert_account!(root, "mara", %{
               host: "imap.gmail.com",
               port: 993,
               username: "mara@gmail.com",
               auth: :oauth2
             })

    {:ok, %{accounts: %{"mara" => account}}} = Settings.load(root)
    assert account.oauth_client_id == nil
  end

  test "an unusable oauth_client_id DEGRADES to no override, unlike auth:", %{root: root} do
    for value <- ["", "   ", "~", "1234"] do
      write_yaml!(root, """
      version: 5
      accounts:
        mara:
          auth: oauth2
          oauth_client_id: #{value}
          imap:
            host: "imap.gmail.com"
            port: 993
            username: "mara@gmail.com"
      safety:
        never_expunge: true
        outbound: human_send_and_push
      """)

      # The account still LOADS — a wrong public client id cannot misroute a
      # secret, it only makes the sign-in visibly refuse. (`auth:` is the one
      # key in this file that invalidates instead; see its own tests above.)
      assert {:ok, %{accounts: %{"mara" => account}, invalid: invalid}} = Settings.load(root),
             "expected #{inspect(value)} to load"

      assert invalid == %{}
      assert account.auth == :oauth2
      assert account.oauth_client_id == nil
    end
  end

  test "a hand-written oauth_client_id is trimmed, not taken verbatim", %{root: root} do
    write_yaml!(root, """
    version: 5
    accounts:
      mara:
        auth: oauth2
        oauth_client_id: "  padded-id  "
        imap:
          host: "imap.gmail.com"
          port: 993
          username: "mara@gmail.com"
    safety:
      never_expunge: true
      outbound: human_send_and_push
    """)

    {:ok, %{accounts: %{"mara" => account}}} = Settings.load(root)
    assert account.oauth_client_id == "padded-id"
  end

  test "an account written before oauth_client_id existed loads with none", %{root: root} do
    write_yaml!(root, """
    version: 5
    accounts:
      mara:
        auth: oauth2
        imap:
          host: "imap.gmail.com"
          port: 993
          username: "mara@gmail.com"
    safety:
      never_expunge: true
      outbound: human_send_and_push
    """)

    {:ok, %{accounts: %{"mara" => account}}} = Settings.load(root)
    assert account.oauth_client_id == nil
  end

  test "an explicit provider: microsoft in the file is honored", %{root: root} do
    write_yaml!(root, """
    version: 5
    accounts:
      mara:
        provider: microsoft
        imap:
          host: "mail.contoso.example"
          port: 993
          username: "mara@contoso.example"
    safety:
      never_expunge: true
      outbound: human_send_and_push
    """)

    {:ok, %{accounts: %{"mara" => account}}} = Settings.load(root)
    assert account.provider == :microsoft
    assert account.folders.sent == "Sent Items"
  end
end
