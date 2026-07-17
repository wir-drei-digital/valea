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
    version: 4
    accounts: {}
    safety:
      never_expunge: true
      outbound: push_drafts_only
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
    assert bytes =~ "outbound: push_drafts_only"
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
end
