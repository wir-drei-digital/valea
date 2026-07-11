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

  describe "load/1 — not configured" do
    test "file missing", %{root: root} do
      assert Settings.load(root) == {:error, :not_configured}
    end

    test "placeholder host (imap.example.com)", %{root: root} do
      write_yaml!(root, """
      account: mara@example.com
      imap:
        host: imap.example.com
        port: 993
        username: mara@example.com
      """)

      assert Settings.load(root) == {:error, :not_configured}
    end

    test "blank host", %{root: root} do
      write_yaml!(root, """
      account: mara@example.com
      imap:
        host: ""
        port: 993
        username: mara@example.com
      """)

      assert Settings.load(root) == {:error, :not_configured}
    end

    test "blank username", %{root: root} do
      write_yaml!(root, """
      account: mara@example.com
      imap:
        host: imap.fastmail.com
        port: 993
        username: ""
      """)

      assert Settings.load(root) == {:error, :not_configured}
    end
  end

  describe "load/1 — invalid" do
    test "missing host key", %{root: root} do
      write_yaml!(root, """
      account: mara@example.com
      imap:
        port: 993
        username: mara@example.com
      """)

      assert {:error, {:invalid, reason}} = Settings.load(root)
      assert reason =~ "host"
    end

    test "non-string host", %{root: root} do
      write_yaml!(root, """
      account: mara@example.com
      imap:
        host: 12345
        port: 993
        username: mara@example.com
      """)

      assert {:error, {:invalid, reason}} = Settings.load(root)
      assert reason =~ "host"
    end

    test "missing username key", %{root: root} do
      write_yaml!(root, """
      account: mara@example.com
      imap:
        host: imap.fastmail.com
        port: 993
      """)

      assert {:error, {:invalid, reason}} = Settings.load(root)
      assert reason =~ "username"
    end

    test "non-string username", %{root: root} do
      write_yaml!(root, """
      account: mara@example.com
      imap:
        host: imap.fastmail.com
        port: 993
        username: true
      """)

      assert {:error, {:invalid, reason}} = Settings.load(root)
      assert reason =~ "username"
    end

    test "non-integer port", %{root: root} do
      write_yaml!(root, """
      account: mara@example.com
      imap:
        host: imap.fastmail.com
        port: "993"
        username: mara@example.com
      """)

      assert {:error, {:invalid, reason}} = Settings.load(root)
      assert reason =~ "port"
    end

    test "zero port", %{root: root} do
      write_yaml!(root, """
      account: mara@example.com
      imap:
        host: imap.fastmail.com
        port: 0
        username: mara@example.com
      """)

      assert {:error, {:invalid, reason}} = Settings.load(root)
      assert reason =~ "port"
    end

    test "negative port", %{root: root} do
      write_yaml!(root, """
      account: mara@example.com
      imap:
        host: imap.fastmail.com
        port: -1
        username: mara@example.com
      """)

      assert {:error, {:invalid, reason}} = Settings.load(root)
      assert reason =~ "port"
    end
  end

  describe "load/1 — success" do
    test "defaults applied for folders/sync and default port when omitted", %{root: root} do
      write_yaml!(root, """
      account: mara@example.com
      imap:
        host: imap.fastmail.com
        username: mara@example.com
      """)

      assert {:ok, settings} = Settings.load(root)

      assert settings == %Settings{
               account: "mara@example.com",
               imap: %{host: "imap.fastmail.com", port: 993, username: "mara@example.com"},
               folders: %{review: "AI/Review", processed: "AI/Processed", drafts: "Drafts"},
               sync: %{
                 interval_minutes: 5,
                 max_message_bytes: 10_485_760,
                 inbox_index_limit: 200
               }
             }
    end

    test "explicit values (including a non-default port) are honored", %{root: root} do
      write_yaml!(root, """
      account: mara@example.com
      imap:
        host: imap.fastmail.com
        port: 143
        username: mara@example.com
      folders:
        review: "Inbox/Review"
        processed: "Inbox/Processed"
        drafts: "Inbox/Drafts"
      sync:
        interval_minutes: 10
        max_message_bytes: 5000000
        inbox_index_limit: 50
      """)

      assert {:ok, settings} = Settings.load(root)
      assert settings.imap.port == 143

      assert settings.folders == %{
               review: "Inbox/Review",
               processed: "Inbox/Processed",
               drafts: "Inbox/Drafts"
             }

      assert settings.sync == %{
               interval_minutes: 10,
               max_message_bytes: 5_000_000,
               inbox_index_limit: 50
             }
    end

    test "hand-edited v2 leftovers (ssl:/smtp: keys) do not brick loading", %{root: root} do
      write_yaml!(root, """
      account: mara@example.com
      imap:
        host: imap.fastmail.com
        port: 993
        ssl: true
        username: mara@example.com
        username_env: MAIL_USERNAME
        password_env: MAIL_APP_PASSWORD
      smtp:
        host: smtp.fastmail.com
        port: 587
        starttls: true
        username_env: MAIL_USERNAME
        password_env: MAIL_APP_PASSWORD
      folders:
        review: "AI/Review"
        processed: "AI/Processed"
        drafted: "AI/Drafted"
      safety:
        send_directly: false
        create_drafts_only: true
      """)

      assert {:ok, settings} = Settings.load(root)
      assert settings.account == "mara@example.com"

      assert settings.imap == %{
               host: "imap.fastmail.com",
               port: 993,
               username: "mara@example.com"
             }

      # v2's "drafted" key is not v3's "drafts" key, so it's ignored — default wins
      assert settings.folders.drafts == "Drafts"
    end

    test "non-positive sync overrides fall back to defaults (same as wrong type)", %{root: root} do
      write_yaml!(root, """
      account: mara@example.com
      imap:
        host: imap.fastmail.com
        port: 993
        username: mara@example.com
      sync:
        interval_minutes: -5
        max_message_bytes: -999999
        inbox_index_limit: 0
      """)

      assert {:ok, settings} = Settings.load(root)

      assert settings.sync == %{
               interval_minutes: 5,
               max_message_bytes: 10_485_760,
               inbox_index_limit: 200
             }
    end
  end

  describe "write!/2" do
    test "round-trips through load/1", %{root: root} do
      assert :ok =
               Settings.write!(root, %{
                 account: "mara@example.com",
                 host: "imap.fastmail.com",
                 port: 993,
                 username: "mara@example.com"
               })

      assert {:ok, settings} = Settings.load(root)

      assert settings == %Settings{
               account: "mara@example.com",
               imap: %{host: "imap.fastmail.com", port: 993, username: "mara@example.com"},
               folders: %{review: "AI/Review", processed: "AI/Processed", drafts: "Drafts"},
               sync: %{
                 interval_minutes: 5,
                 max_message_bytes: 10_485_760,
                 inbox_index_limit: 200
               }
             }
    end

    test "written file contains no ssl: and no smtp: keys", %{root: root} do
      :ok =
        Settings.write!(root, %{
          account: "mara@example.com",
          host: "imap.fastmail.com",
          port: 993,
          username: "mara@example.com"
        })

      bytes = File.read!(Path.join(root, "config/mail.yaml"))
      refute bytes =~ "ssl:"
      refute bytes =~ "smtp:"
      refute bytes =~ "_env:"
    end

    test "written file never contains a credential-looking key", %{root: root} do
      :ok =
        Settings.write!(root, %{
          account: "mara@example.com",
          host: "imap.fastmail.com",
          port: 993,
          username: "mara@example.com"
        })

      bytes = File.read!(Path.join(root, "config/mail.yaml"))
      refute bytes =~ "password"
      refute bytes =~ "secret"
    end

    test "creates config/ if it doesn't exist yet", %{root: root} do
      nested_root = Path.join(root, "fresh-workspace")
      File.mkdir_p!(nested_root)

      assert :ok =
               Settings.write!(nested_root, %{
                 account: "mara@example.com",
                 host: "imap.fastmail.com",
                 port: 993,
                 username: "mara@example.com"
               })

      assert File.exists?(Path.join(nested_root, "config/mail.yaml"))
    end

    test "is atomic: no stray .tmp file left behind", %{root: root} do
      :ok =
        Settings.write!(root, %{
          account: "mara@example.com",
          host: "imap.fastmail.com",
          port: 993,
          username: "mara@example.com"
        })

      refute File.exists?(Path.join(root, "config/mail.yaml.tmp"))
    end

    test "overwrites a previous v2 file, dropping ssl:/smtp: on rewrite", %{root: root} do
      write_yaml!(root, """
      account: old@example.com
      imap:
        host: imap.example.com
        port: 993
        ssl: true
        username_env: MAIL_USERNAME
        password_env: MAIL_APP_PASSWORD
      smtp:
        host: smtp.example.com
        port: 587
        starttls: true
      folders:
        review: "AI/Review"
        processed: "AI/Processed"
        drafted: "AI/Drafted"
      safety:
        send_directly: false
        create_drafts_only: true
      """)

      :ok =
        Settings.write!(root, %{
          account: "mara@example.com",
          host: "imap.fastmail.com",
          port: 993,
          username: "mara@example.com"
        })

      bytes = File.read!(Path.join(root, "config/mail.yaml"))
      refute bytes =~ "ssl:"
      refute bytes =~ "smtp:"
      assert {:ok, settings} = Settings.load(root)
      assert settings.account == "mara@example.com"
    end

    test "escapes a value that would otherwise break the YAML structure", %{root: root} do
      :ok =
        Settings.write!(root, %{
          account: "mara@example.com",
          host: "imap.fastmail.com",
          port: 993,
          username: ~s(evil"user\nssl: false)
        })

      assert {:ok, settings} = Settings.load(root)
      assert settings.imap.username == ~s(evil"user ssl: false)
    end

    test "does not crash on invalid UTF-8 input; scrubs to U+FFFD and round-trips", %{root: root} do
      :ok =
        Settings.write!(root, %{
          account: "mara@example.com",
          host: "imap.fastmail.com",
          port: 993,
          username: "abc" <> <<0xFF, 0xFE>> <> "def"
        })

      assert {:ok, settings} = Settings.load(root)
      assert String.valid?(settings.imap.username)
      assert settings.imap.username == "abc��def"
    end

    test "rejects a non-positive port with a FunctionClauseError", %{root: root} do
      for bad_port <- [0, -1] do
        assert_raise FunctionClauseError, fn ->
          Settings.write!(root, %{
            account: "mara@example.com",
            host: "imap.fastmail.com",
            port: bad_port,
            username: "mara@example.com"
          })
        end
      end

      refute File.exists?(Path.join(root, "config/mail.yaml"))
    end
  end
end
